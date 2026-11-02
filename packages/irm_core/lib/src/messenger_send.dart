part of 'messenger.dart';

/// Sending: the outbox, encryption per device and delivery to the server.
extension MessengerSend on Messenger {
  // ------------------------------------------------------------------
  // Sending
  // ------------------------------------------------------------------

  Future<void> sendText(
    String chat,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final body = text.trim();
    if (body.isEmpty) return;
    await _insertOutgoing(
      chat,
      'text',
      body,
      null,
      reply: replyTo?.clientMsgId == null
          ? null
          : ReplyRef(replyTo!.clientMsgId!, replyTo.sender, previewOf(replyTo)),
    );
  }

  /// Queues an attachment. [data] is copied into private storage first,
  /// so the caller may discard its source.
  Future<void> sendMedia(
    String chat,
    Uint8List data, {
    required String name,
    required String kind,
    required String mime,
    String caption = '',
    int? durationMs,
  }) async {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final local = files.newPath('media', '${Messenger.newId()}_$safe');
    await files.write(local, data);
    final info = MediaInfo(
      kind: kind,
      mime: mime,
      // The real name is shown to the recipient (whose app makes its own
      // safe copy for the disk); only separators and control characters go.
      name: String.fromCharCodes(
        name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_').runes.take(120),
      ),
      size: data.length,
      durationMs: durationMs,
      path: local,
      plainSha: MediaTransfer.reusable(kind)
          ? await MediaTransfer.plainHash(data)
          : null,
    );
    if (info.plainSha != null) media.remember(info.plainSha!, local);
    await _insertOutgoing(chat, 'media', caption.trim(), info);
  }

  Future<void> _insertOutgoing(
    String chat,
    String kind,
    String body,
    MediaInfo? info, {
    ReplyRef? reply,
    String? poll,
  }) async {
    await db.tx(
      () async => db.raw.execute(
        'INSERT INTO messages (chat, sender, outgoing, kind, body, media, reply, client_msg_id, status, created_at, poll) '
        'VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          chat,
          myIdentity,
          kind,
          body,
          info == null ? null : jsonEncode(info.toJson()),
          reply == null ? null : jsonEncode(reply.toJson()),
          Messenger.newId(),
          MsgStatus.pending,
          DateTime.now().millisecondsSinceEpoch,
          poll,
        ],
      ),
    );
    notify();
    // Whoever is written to for the first time also gets our picture.
    unawaited(_shareAvatar(_audience(chat)).catchError((_) {}));
    if (chat.startsWith('g:')) {
      unawaited(_shareGroupAvatar(chat.substring(2)).catchError((_) {}));
    }
    unawaited(syncOnce().catchError((_) => false));
  }

  /// Puts a failed message back in the queue.
  Future<void> retry(int messageId) async {
    await db.tx(
      () async => db.raw.execute(
        'UPDATE messages SET status = ?, error = NULL, payload = NULL WHERE id = ? AND outgoing = 1 AND status = ? AND kind IN (?, ?, ?, ?)',
        [
          MsgStatus.pending,
          messageId,
          MsgStatus.failed,
          'text',
          'media',
          'poll',
          'buzz',
        ],
      ),
    );
    notify();
    unawaited(syncOnce().catchError((_) => false));
  }

  /// Everyone a message in [chat] is encrypted for. Bots are never among
  /// them: they may post, but receive nothing anyone writes (only group
  /// membership, which [updateGroup] sends to every member itself).
  List<int> _audience(String chat) {
    if (chat.startsWith('u:')) {
      final peer = int.parse(chat.substring(2));
      return isBot(peer) ? const [] : [peer];
    }
    final g = group(chat.substring(2));
    if (g == null || g.left) throw StateError('not a member of this group');
    return g.members.where((m) => m != myIdentity && !isBot(m)).toList();
  }

  /// Accounts the server marks as bots.
  Set<int> get bots => {
    for (final id in (jsonDecode(db.kvString('bots') ?? '[]') as List))
      (id as num).toInt(),
  };

  bool isBot(int identity) => bots.contains(identity);

  void _markBot(int identity) {
    if (isBot(identity)) return;
    db.kvPutString('bots', jsonEncode([...bots, identity]));
  }

  /// Device ids of [identity], fetching key bundles and starting sessions
  /// the first time. Each fetch consumes one of the peer's one-time prekeys.
  Future<List<int>> devicesOf(int identity) async {
    List<int> known() => [
      for (final r in db.raw.select(
        'SELECT device_id FROM peer_devices WHERE identity_id = ?',
        [identity],
      ))
        r['device_id'] as int,
    ];
    final have = known();
    if (have.isNotEmpty) return have;
    final res = await api.get('/keys/$identity') as Map;
    await db.tx(() async {
      for (final d in res['devices'] as List) {
        final b = RemoteBundle.fromJson((d as Map).cast<String, dynamic>());
        await crypto.startSession('$identity', b);
        db.raw.execute(
          'INSERT OR IGNORE INTO peer_devices (identity_id, device_id) VALUES (?, ?)',
          [identity, b.deviceId],
        );
      }
    });
    return known();
  }

  /// Sends what is queued, short messages first so a text never waits
  /// behind a large file, and keeps going until nothing new was queued in
  /// the meantime. With [smallOnly] (between the pieces of a file upload)
  /// only messages without an attachment are sent.
  Future<void> _flushOutbox({bool smallOnly = false}) async {
    final tried = <int>{};
    while (true) {
      final row = db.raw
          .select(
            'SELECT * FROM messages WHERE outgoing = 1 AND status = ? '
            '${smallOnly ? 'AND media IS NULL ' : ''}'
            'ORDER BY (media IS NOT NULL), id',
            [MsgStatus.pending],
          )
          .where((r) => !tried.contains(r['id']))
          .firstOrNull;
      if (row == null) return;
      tried.add(row['id'] as int);
      touchLease();
      final id = row['id'] as int;
      try {
        await _sendRow(Map<String, dynamic>.from(row));
      } on UntrustedIdentityException {
        _fail(id, 'identity_changed');
      } on ApiError catch (e) {
        if (e.code == 'irm_stale_devices') {
          // A recipient signed in on a new device. Forget the old one, tell
          // the user (their keys changed), and let the next pass re-encrypt.
          await db.tx(() async {
            for (final m in _rowAudience(row)) {
              db.raw.execute('DELETE FROM peer_devices WHERE identity_id = ?', [
                m,
              ]);
              await store.deleteAllSessions('$m');
              db.raw.execute(
                'INSERT INTO messages (chat, sender, outgoing, kind, body, status, created_at) '
                'VALUES (?, ?, 0, ?, ?, ?, ?)',
                [
                  'u:$m',
                  m,
                  'system',
                  'دستگاه ${nameOf(m)} عوض شده است؛ بهتر است هویت را دوباره تایید کنید',
                  MsgStatus.received,
                  DateTime.now().millisecondsSinceEpoch,
                ],
              );
            }
            db.raw.execute('UPDATE messages SET payload = NULL WHERE id = ?', [
              id,
            ]);
          });
          notify();
          _staleRetry = true;
          continue;
        }
        if (e.status == 401 || e.status == 429 || e.status >= 500) rethrow;
        _fail(id, e.code);
      } on StateError catch (e) {
        _fail(id, e.message);
      }
    }
  }

  /// Between the pieces of a file upload: sends any short message queued
  /// meanwhile, so it does not wait for the whole file.
  Future<void> _sendWaiting() async {
    if (_sendingWaiting) return;
    _sendingWaiting = true;
    try {
      await _flushOutbox(smallOnly: true);
    } catch (_) {
      // The file upload goes on; the next round retries these.
    } finally {
      _sendingWaiting = false;
    }
  }

  void _fail(int id, String error) {
    db.raw.execute('DELETE FROM messages WHERE id = ? AND kind = ?', [
      id,
      'control',
    ]);
    db.raw.execute('UPDATE messages SET status = ?, error = ? WHERE id = ?', [
      MsgStatus.failed,
      error,
      id,
    ]);
    notify();
  }

  /// Extra wire fields of polls and BUZZes. Their "body" is what older
  /// apps display instead.
  Map<String, dynamic> _funWire(Map<String, dynamic> row) {
    if (row['kind'] == 'buzz') return {'body': '📳 BUZZ!'};
    if (row['kind'] != 'poll' || row['poll'] == null) return const {};
    final p = (jsonDecode(row['poll'] as String) as Map)
        .cast<String, dynamic>();
    final options = [for (final o in p['o'] as List) '$o'];
    final q = row['body'] as String;
    return {
      'body': MessengerFun.pollFallback(q, options),
      'poll': {'q': q, 'o': options, 'm': p['m'] == true},
    };
  }

  static bool _stashed(Map<String, dynamic> row) =>
      row['kind'] == 'system' || row['kind'] == 'control';

  List<int> _rowAudience(Map<String, dynamic> row) => _stashed(row)
      ? ((jsonDecode(row['error'] as String) as Map)['to'] as List)
            .cast<int>()
            .where((m) => m != myIdentity)
            .toList()
      : _audience(row['chat'] as String);

  Future<void> _sendRow(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    var payload = row['payload'] as String?;

    if (payload == null) {
      final audience = _rowAudience(row);
      final targets = <int, List<int>>{
        for (final m in audience) m: await devicesOf(m),
      };

      MediaInfo? info;
      if (row['media'] != null) {
        info = MediaInfo.fromJson(
          jsonDecode(row['media'] as String) as Map<String, dynamic>,
        );
        if (info.serverId == null) {
          await media.upload(id, info, [
            for (final d in targets.values) ...d,
          ], between: _sendWaiting);
        }
      }

      final chat = row['chat'] as String;
      final Map<String, dynamic> wire = _stashed(row)
          ? {
              ...((jsonDecode(row['error'] as String) as Map)['wire'] as Map)
                  .cast<String, dynamic>(),
              // A profile picture travels with its control message.
              if (info != null) 'media': info.toWire(),
            }
          : {
              'v': 1,
              'cv': Messenger.capability,
              't': row['kind'],
              'id': row['client_msg_id'],
              'fn': myName,
              if (myUsername != null) 'fu': myUsername,
              'ts': row['created_at'],
              if (chat.startsWith('g:')) 'gid': chat.substring(2),
              'body': row['body'],
              if (row['reply'] != null)
                're': jsonDecode(row['reply'] as String),
              if (info != null) 'media': info.toWire(),
              ..._funWire(row),
            };
      final plain = utf8Bytes(jsonEncode(wire));

      // Ratchet steps and the prepared envelopes commit together: a retry
      // after a crash resends these exact envelopes instead of re-encrypting.
      payload = await db.tx(() async {
        final envelopes = <Map<String, dynamic>>[];
        for (final entry in targets.entries) {
          for (final device in entry.value) {
            final e = await crypto.encrypt('${entry.key}', device, plain);
            envelopes.add({
              'to_device': device,
              'type': e.type,
              'body': base64Encode(e.body),
            });
          }
        }
        final p = jsonEncode({
          'client_msg_id': row['client_msg_id'],
          'envelopes': envelopes,
          // Reactions and edits should not ring anyone's phone.
          if (row['kind'] == 'control') 'quiet': true,
        });
        db.raw.execute('UPDATE messages SET payload = ? WHERE id = ?', [p, id]);
        return p;
      });
    }

    final decoded = jsonDecode(payload!) as Map;
    if ((decoded['envelopes'] as List).isNotEmpty) {
      await api.post('/envelopes', decoded);
    }
    if (row['kind'] == 'control') {
      // Reactions and edits leave no row of their own once delivered.
      db.raw.execute('DELETE FROM messages WHERE id = ?', [id]);
      return;
    }
    db.raw.execute(
      'UPDATE messages SET status = ?, payload = NULL, error = CASE WHEN kind = ? THEN error ELSE NULL END WHERE id = ?',
      [MsgStatus.sent, 'system', id],
    );
    notify();
  }
}
