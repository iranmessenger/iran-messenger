part of 'messenger.dart';

/// Replies, reactions, edits and typing indicators.
///
/// All of them travel as ordinary end-to-end encrypted envelopes, so the
/// server cannot read them. It is told only that an envelope is "quiet"
/// (a reaction or an edit) or short-lived (typing), so that it does not
/// raise a new-message alert for it. Reactions and edits are queued like
/// messages so they survive being offline. Typing indicators are
/// best-effort and short-lived.
extension MessengerExtras on Messenger {
  /// One-line description of a message, used inside quotes.
  String previewOf(ChatMessage m) {
    final text = m.kind == 'media'
        ? switch (m.media?.kind) {
            'image' => 'عکس',
            'video' => 'ویدیو',
            'voice' => 'پیام صوتی',
            'gif' => 'GIF',
            'sticker' => 'استیکر',
            _ => 'فایل',
          }
        : m.kind == 'buzz'
        ? '📳 BUZZ!'
        : m.kind == 'poll'
        ? '📊 ${m.body.replaceAll('\n', ' ')}'
        : m.body.replaceAll('\n', ' ');
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  Future<void> _queueControl2(
    String chat,
    Map<String, dynamic> wire, {
    bool newClientsOnly = false,
    int? minCapability,
  }) async {
    final level = minCapability ?? (newClientsOnly ? 2 : 1);
    if (level > 1) await _learnCapabilities(_audience(chat), level);
    final to = _audience(chat).where((m) => _capable(m, level)).toList();
    if (to.isEmpty) return;
    final id = Messenger.newId();
    await db.tx(
      () async => db.raw.execute(
        'INSERT INTO messages (chat, sender, outgoing, kind, body, client_msg_id, status, created_at, error) '
        'VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?)',
        [
          chat,
          myIdentity,
          'control',
          '',
          id,
          MsgStatus.pending,
          DateTime.now().millisecondsSinceEpoch,
          jsonEncode({
            'wire': {
              'v': 1,
              'cv': Messenger.capability,
              'id': id,
              'ts': DateTime.now().millisecondsSinceEpoch,
              if (chat.startsWith('g:')) 'gid': chat.substring(2),
              'fn': myName,
              if (myUsername != null) 'fu': myUsername,
              ...wire,
            },
            'to': to,
          }),
        ],
      ),
    );
    notify();
    unawaited(syncOnce().catchError((_) => false));
  }

  void _setReaction(int rowId, int who, String emoji) {
    final rows = db.raw.select('SELECT reactions FROM messages WHERE id = ?', [
      rowId,
    ]);
    if (rows.isEmpty) return;
    final map = rows.first['reactions'] == null
        ? <String, dynamic>{}
        : (jsonDecode(rows.first['reactions'] as String) as Map)
              .cast<String, dynamic>();
    if (emoji.isEmpty) {
      map.remove('$who');
    } else {
      map['$who'] = emoji;
    }
    db.raw.execute('UPDATE messages SET reactions = ? WHERE id = ?', [
      map.isEmpty ? null : jsonEncode(map),
      rowId,
    ]);
  }

  /// Sets this user's reaction on [msg]; the same emoji again removes it.
  /// Returns false for messages that predate message ids.
  /// Nobody reacts to their own messages.
  Future<bool> react(ChatMessage msg, String emoji) async {
    final target = msg.clientMsgId;
    if (target == null || msg.outgoing || msg.sender == myIdentity) {
      return false;
    }
    final next = msg.reactions['$myIdentity'] == emoji ? '' : emoji;
    _setReaction(msg.id, myIdentity, next);
    await _queueControl2(msg.chat, {
      't': 'react',
      'target': target,
      'emoji': next,
    });
    return true;
  }

  /// Replaces the text of one of this user's own sent messages.
  Future<bool> editMessage(ChatMessage msg, String text) async {
    final body = text.trim();
    if (!msg.outgoing ||
        msg.kind != 'text' ||
        msg.clientMsgId == null ||
        body.isEmpty ||
        body == msg.body) {
      return false;
    }
    db.raw.execute('UPDATE messages SET body = ?, edited = 1 WHERE id = ?', [
      body,
      msg.id,
    ]);
    await _queueControl2(msg.chat, {
      't': 'edit',
      'target': msg.clientMsgId,
      'body': body,
    });
    return true;
  }

  /// Applies an incoming typing/react/edit. Runs inside the caller's
  /// transaction; unknown targets are ignored.
  void _applyControl(String chat, int from, Map<String, dynamic> wire, int ts) {
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (wire['t']) {
      case 'typing':
        // Stale indicators (delivered late) say nothing about right now.
        if ((now - ts).abs() > 15000) return;
        _typingSeen[chat] = (from, now + 6000);
        Timer(const Duration(milliseconds: 6100), notify);
        notify();
      case 'react':
        final rows = db.raw.select(
          'SELECT id, sender FROM messages WHERE client_msg_id = ? AND chat = ?',
          [wire['target'], chat],
        );
        // Reactions to one's own message are not shown.
        if (rows.isEmpty || rows.first['sender'] == from) return;
        final emoji = '${wire['emoji'] ?? ''}';
        _setReaction(
          rows.first['id'] as int,
          from,
          emoji.length > 16 ? '' : emoji,
        );
        notify();
      case 'vote':
        _applyVote(chat, from, wire);
      case 'pollclose':
        _applyPollClose(chat, from, wire);
      case 'read':
        _applyRead(chat, from, wire, ts);
      case 'del':
        _applyDelete(chat, from, wire);
      case 'edit':
        // Only the original sender may change a message.
        final body = '${wire['body'] ?? ''}'.trim();
        if (body.isEmpty) return;
        db.raw.execute(
          'UPDATE messages SET body = ?, edited = 1 WHERE client_msg_id = ? AND chat = ? AND sender = ? AND outgoing = 0 AND kind = ?',
          [body, wire['target'], chat, from, 'text'],
        );
        notify();
    }
  }

  /// Name of whoever is typing in [chat] right now, or null.
  String? typingIn(String chat) {
    final seen = _typingSeen[chat];
    if (seen == null) return null;
    if (seen.$2 < DateTime.now().millisecondsSinceEpoch) {
      _typingSeen.remove(chat);
      return null;
    }
    return nameOf(seen.$1);
  }

  /// Tells the other side we are typing. Throttled, never queued, and
  /// silently dropped on any failure. Only goes to devices we already
  /// have a session with, and expires on the server after 20 seconds.
  Future<void> sendTyping(String chat) async {
    if (!isRegistered || isPending) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_typingSent[chat] ?? 0) < 4000) return;
    _typingSent[chat] = now;
    try {
      await _loadAuthKey();
      final plain = utf8Bytes(
        jsonEncode({
          'v': 1,
          't': 'typing',
          'ts': now,
          if (chat.startsWith('g:')) 'gid': chat.substring(2),
        }),
      );
      final envelopes = await db.tx(() async {
        final out = <Map<String, dynamic>>[];
        for (final m in _audience(chat)) {
          for (final r in db.raw.select(
            'SELECT device_id FROM peer_devices WHERE identity_id = ?',
            [m],
          )) {
            final device = r['device_id'] as int;
            if (!await crypto.hasSession('$m', device)) continue;
            final e = await crypto.encrypt('$m', device, plain);
            out.add({
              'to_device': device,
              'type': e.type,
              'body': base64Encode(e.body),
            });
          }
        }
        return out;
      });
      if (envelopes.isEmpty) return;
      await api.post('/envelopes', {
        'client_msg_id': Messenger.newId(),
        'ttl': 20,
        'envelopes': envelopes,
      });
    } catch (_) {
      // Best effort only.
    }
  }

  // ---- saved GIFs and stickers (local only) ----

  List<Favorite> favorites(String kind) => [
    for (final r in db.raw.select(
      'SELECT * FROM favorites WHERE kind = ? ORDER BY id DESC',
      [kind],
    ))
      if (files.existsSync(r['path'] as String))
        Favorite(
          r['id'] as int,
          r['kind'] as String,
          r['mime'] as String,
          r['path'] as String,
        ),
  ];

  /// Copies [bytes] into the collection. Adding the same file twice keeps
  /// one copy. Returns false if it was already there.
  Future<bool> addFavorite(
    Uint8List bytes, {
    required String name,
    required String kind,
    required String mime,
  }) async {
    final sha = (await Sha256().hash(
      bytes,
    )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (db.raw.select('SELECT 1 FROM favorites WHERE sha = ? AND kind = ?', [
      sha,
      kind,
    ]).isNotEmpty) {
      return false;
    }
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
    final safeExt = RegExp(r'^\.[A-Za-z0-9]{1,5}$').hasMatch(ext) ? ext : '';
    final out = files.newPath('favorites', '${Messenger.newId()}$safeExt');
    await files.write(out, bytes);
    // A saved GIF that someone sends later is taken from here.
    media.remember(sha, out);
    db.raw.execute(
      'INSERT INTO favorites (kind, mime, path, sha, added_at) VALUES (?, ?, ?, ?, ?)',
      [kind, mime, out, sha, DateTime.now().millisecondsSinceEpoch],
    );
    notify();
    return true;
  }

  /// Saves the GIF or sticker of a message someone sent (or we sent).
  Future<bool> addFavoriteFromMessage(ChatMessage msg) async {
    final info = msg.media;
    if (info == null ||
        info.path == null ||
        (info.kind != 'gif' && info.kind != 'sticker') ||
        !files.existsSync(info.path!)) {
      return false;
    }
    return addFavorite(
      await files.read(info.path!),
      name: info.name,
      kind: info.kind,
      mime: info.mime,
    );
  }

  void removeFavorite(int id) {
    final rows = db.raw.select('SELECT path FROM favorites WHERE id = ?', [id]);
    if (rows.isEmpty) return;
    unawaited(files.delete(rows.first['path'] as String));
    db.raw.execute('DELETE FROM favorites WHERE id = ?', [id]);
    notify();
  }

  Future<void> sendFavorite(String chat, Favorite f) async => sendMedia(
    chat,
    await files.read(f.path),
    name: f.path.substring(f.path.lastIndexOf('/') + 1),
    kind: f.kind,
    mime: f.mime,
  );
}
