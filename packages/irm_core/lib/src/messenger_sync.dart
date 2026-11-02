part of 'messenger.dart';

/// Pulling, decrypting and acknowledging incoming envelopes.
extension MessengerSync on Messenger {
  // ------------------------------------------------------------------
  // Receiving
  // ------------------------------------------------------------------

  /// One full round: send what is queued, fetch, store, acknowledge.
  /// Concurrent calls share the same round. Returns true if anything
  /// was received.
  Future<bool> syncOnce() {
    if (!isRegistered) return Future.value(false);
    final running = _running;
    if (running == null) {
      return _running = _syncRound().whenComplete(() => _running = null);
    }
    // A round is under way and may already be past the outbox. Run one more
    // right after it; every caller meanwhile waits for that one, so what
    // they queued has been sent when their future completes.
    return _nextRound ??= running.then<void>((_) {}, onError: (_) {}).then((_) {
      _nextRound = null;
      return syncOnce();
    });
  }

  /// Only one isolate (UI or background service) may sync at a time:
  /// both share the database, and two senders preparing the same queued
  /// message would advance the ratchet twice. The lease expires on its own
  /// if its holder is killed.
  Future<bool> _acquireLease() => db.tx(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final v = db.kvString('sync_lease');
    if (v != null) {
      final parts = v.split('|');
      if (parts[0] != _instance && int.parse(parts[1]) > now) return false;
    }
    db.kvPutString('sync_lease', '$_instance|${now + _leaseMs}');
    return true;
  });

  /// A lease left by a killed isolate blocks the other one this long at
  /// most. Long work renews it after every request.
  static const _leaseMs = 45000;

  /// Extends the lease during long transfers.
  void touchLease() => db.kvPutString(
    'sync_lease',
    '$_instance|${DateTime.now().millisecondsSinceEpoch + _leaseMs}',
  );

  Future<bool> _syncRound() async {
    if (!await _acquireLease()) return false;
    try {
      return await _syncBody();
    } finally {
      if ((db.kvString('sync_lease') ?? '').startsWith('$_instance|')) {
        db.kvPutString('sync_lease', '$_instance|0');
      }
    }
  }

  Future<bool> _syncBody() async {
    await _loadAuthKey();
    if (isPending) {
      // Only /me answers until the administrator approves the account.
      await syncProfile();
      if (isPending) return false;
    }
    await _flushOutbox();
    // A file the user took back offline; never holds up the round.
    await _sendTakeBacks().catchError((_) {});
    if (_staleRetry) {
      _staleRetry = false;
      await _flushOutbox();
    }
    var gotAny = false;
    var sawPreKeyMessage = false;

    while (true) {
      final res = await api.get('/sync') as Map;
      final stored = <int>[];
      final seen = <int>[];

      for (final raw in res['envelopes'] as List) {
        final e = (raw as Map).cast<String, dynamic>();
        if (e['type'] == CiphertextMessage.prekeyType) sawPreKeyMessage = true;
        final msg = await _storeIncoming(e);
        stored.add(e['delivery_id'] as int);
        if (msg != null) {
          gotAny = true;
          if (!_incoming.isClosed) _incoming.add(msg);
        }
      }
      for (final raw in res['receipts'] as List) {
        db.raw.execute(
          'UPDATE messages SET status = ? WHERE client_msg_id = ? AND status = ?',
          [MsgStatus.delivered, raw['client_msg_id'], MsgStatus.sent],
        );
        seen.add(raw['receipt_id'] as int);
      }
      if (stored.isNotEmpty || seen.isNotEmpty) {
        // Acknowledged only after the rows above are durably committed.
        await api.post('/receipts', {'stored': stored, 'receipts_seen': seen});
        notify();
      }
      if (res['more'] != true) break;
      touchLease();
    }

    await _fetchAvatars();
    if (_newlyCapable.isNotEmpty) {
      final who = _newlyCapable.toList();
      _newlyCapable.clear();
      await _greet(who);
      await _flushOutbox();
    }
    if (sawPreKeyMessage) await _topUpPreKeys();
    return gotAny;
  }

  /// Decrypts and stores one envelope atomically. Returns the visible
  /// message, or null for duplicates and control messages.
  Future<ChatMessage?> _storeIncoming(Map<String, dynamic> e) async {
    final deliveryId = e['delivery_id'] as int;
    final from = e['from_identity'] as int;
    return db.tx(() async {
      if (db.raw.select('SELECT 1 FROM messages WHERE delivery_id = ?', [
        deliveryId,
      ]).isNotEmpty) {
        return null;
      }
      Map<String, dynamic> wire;
      try {
        final plain = await crypto.decrypt(
          '$from',
          e['from_device'] as int,
          Envelope(e['type'] as int, base64Decode(e['body'] as String)),
        );
        wire = (jsonDecode(utf8.decode(plain)) as Map).cast<String, dynamic>();
        db.raw.execute(
          'INSERT OR IGNORE INTO peer_devices (identity_id, device_id) VALUES (?, ?)',
          [from, e['from_device']],
        );
      } on DuplicateMessageException {
        return null;
      } catch (err) {
        return _insertIncoming(
          'u:$from',
          from,
          'text',
          '',
          null,
          deliveryId,
          MsgStatus.undecryptable,
          DateTime.now().millisecondsSinceEpoch,
          error: err.runtimeType.toString(),
        );
      }

      _remember(from, wire['fn'] as String?, wire['fu'] as String?);
      if (wire['cv'] is int) {
        if (!_capable(from) && (wire['cv'] as int) >= 2) {
          _newlyCapable.add(from);
        }
        db.kvPutInt('cap:$from', wire['cv'] as int);
      }
      final ts =
          (wire['ts'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      final gid = wire['gid'] as String?;

      if (wire['t'] == 'group') {
        final current = group(gid!);
        final admin = (wire['admin'] as num).toInt();
        final epoch = (wire['epoch'] as num).toInt();
        final declared = wire['admins'] is List
            ? (wire['admins'] as List).map((e) => (e as num).toInt()).toList()
            : [admin];
        // Only an admin may change the group, and only forwards. The
        // creator stays the creator, and only the creator names admins.
        // An invitation sent before this user left must not bring the
        // group back; a later one (being added again) does.
        if (current == null && _leftAfter(gid, ts)) return null;
        final allowed = current == null
            ? from == admin || declared.contains(from)
            : current.admins.contains(from) &&
                  admin == current.admin &&
                  epoch > current.epoch;
        if (!allowed) return null;
        final admins = current == null || from == current.admin
            ? declared
            : current.admins;
        final names = wire['names'];
        if (names is Map) {
          names.forEach((id, v) {
            if (v is List && v.isNotEmpty) {
              _remember(
                int.parse('$id'),
                v[0] as String?,
                v.length > 1 ? v[1] as String? : null,
              );
            }
          });
        }
        _applyGroup(
          gid,
          '${wire['title']}',
          admin,
          epoch,
          (wire['members'] as List).map((m) => (m as num).toInt()).toList(),
          admins: admins,
        );
        return _insertIncoming(
          'g:$gid',
          from,
          'system',
          current == null ? 'به گروه اضافه شدید' : 'گروه به‌روز شد',
          null,
          deliveryId,
          MsgStatus.received,
          ts,
        );
      }

      // A bot keeps nothing anyone writes (not even reactions or receipts);
      // it only needs to know which groups it is in.
      if (botMode) return null;

      if (gid != null) {
        final g = group(gid);
        // Drop group messages from anyone who is not a current member.
        if (g == null || !g.members.contains(from)) return null;
      }
      final chat = gid == null ? 'u:$from' : 'g:$gid';
      if (wire['t'] == 'avatar') {
        _receiveAvatar(from, gid, wire, deliveryId, ts);
        return null;
      }
      if (const {
        'typing',
        'react',
        'edit',
        'read',
        'del',
        'vote',
        'pollclose',
      }.contains(wire['t'])) {
        _applyControl(chat, from, wire, ts);
        return null;
      }
      if (const {'clear', 'leave', 'gdel'}.contains(wire['t'])) {
        _applyWipe(chat, from, wire['t'] as String);
        return null;
      }
      // Keep the sender's message id so replies, reactions and edits can
      // point at this message. A reused id is ignored rather than trusted.
      final wireId = wire['id'] as String?;
      final fresh =
          wireId != null &&
          db.raw.select('SELECT 1 FROM messages WHERE client_msg_id = ?', [
            wireId,
          ]).isEmpty;
      if (wire['t'] == 'buzz') {
        return _receiveBuzz(chat, from, deliveryId, ts, fresh ? wireId : null);
      }
      final poll = wire['t'] == 'poll'
          ? MessengerFun._pollJson(wire['poll'])
          : null;
      if (poll != null) {
        return _insertIncoming(
          chat,
          from,
          'poll',
          '${(wire['poll'] as Map)['q']}'.trim(),
          null,
          deliveryId,
          MsgStatus.received,
          ts,
          wireId: fresh ? wireId : null,
          poll: poll,
        );
      }
      final info = wire['media'] == null
          ? null
          : MediaInfo.fromJson((wire['media'] as Map).cast<String, dynamic>());
      return _insertIncoming(
        chat,
        from,
        info == null ? 'text' : 'media',
        '${wire['body'] ?? ''}',
        info,
        deliveryId,
        MsgStatus.received,
        ts,
        wireId: fresh ? wireId : null,
        reply: wire['re'] is Map ? jsonEncode(wire['re']) : null,
      );
    });
  }

  ChatMessage _insertIncoming(
    String chat,
    int sender,
    String kind,
    String body,
    MediaInfo? info,
    int deliveryId,
    int status,
    int ts, {
    String? error,
    String? wireId,
    String? reply,
    String? poll,
  }) {
    db.raw.execute(
      'INSERT INTO messages (chat, sender, outgoing, kind, body, media, delivery_id, status, created_at, error, client_msg_id, reply, poll) '
      'VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        chat,
        sender,
        kind,
        body,
        info == null ? null : jsonEncode(info.toJson()),
        deliveryId,
        status,
        ts,
        error,
        wireId,
        reply,
        poll,
      ],
    );
    return ChatMessage.fromRow(
      db.raw.select('SELECT * FROM messages WHERE delivery_id = ?', [
        deliveryId,
      ]).first,
    );
  }

  Future<void> _topUpPreKeys() async {
    final me = await api.get('/me') as Map;
    if ((me['prekey_count'] as int) >= 20) return;
    final ids = await db.tx(() => crypto.addPreKeys(40));
    await api.post('/keys/prekeys', {'prekeys': await crypto.preKeyList(ids)});
  }
}
