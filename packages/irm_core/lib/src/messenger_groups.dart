part of 'messenger.dart';

/// Directory, groups and identity verification.
///
/// Groups exist only on the clients: membership travels in E2EE control
/// messages signed off by the admin's session, so the server never learns
/// who is in which group and cannot add a member on its own.
extension MessengerGroups on Messenger {
  // ------------------------------------------------------------------
  // Directory and groups
  // ------------------------------------------------------------------

  /// Same canonical form the server uses; Iranian numbers -> 989xxxxxxxxx.
  static String normalizeMobile(String raw) {
    var d = raw.replaceAll(RegExp(r'\D+'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.length == 11 && d.startsWith('09')) {
      d = '98${d.substring(1)}';
    } else if (d.length == 10 && d.startsWith('9')) {
      d = '98$d';
    }
    return d;
  }

  Future<String> _contactSalt() async {
    final cached = db.kvString('contact_salt');
    if (cached != null) return cached;
    await _loadAuthKey();
    final salt = (await api.get('/config') as Map)['contact_salt'] as String;
    db.kvPutString('contact_salt', salt);
    return salt;
  }

  /// Finds which address-book numbers belong to members of this server.
  ///
  /// The numbers never leave the device. Only the first 24 bits of a salted
  /// hash of each are sent, which many unrelated numbers share; candidates
  /// the server returns are confirmed here against the full hash. Returns
  /// how many contacts were found.
  Future<int> matchContacts(Iterable<String> phoneNumbers) async {
    final salt = await _contactSalt();
    final full = <String>{};
    for (final raw in phoneNumbers) {
      final n = normalizeMobile(raw);
      if (n.length < 10 || n.length > 15) continue;
      final digest = await Sha256().hash(utf8.encode('$salt:$n'));
      full.add(
        digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      );
    }
    if (full.isEmpty) return 0;
    final prefixes = {for (final h in full) h.substring(0, 6)}.toList();
    var found = 0;
    for (var i = 0; i < prefixes.length; i += 5000) {
      final end = i + 5000 > prefixes.length ? prefixes.length : i + 5000;
      final res =
          await api.post('/contacts/match', {
                'prefixes': prefixes.sublist(i, end),
              })
              as Map;
      await db.tx(() async {
        for (final m in res['matches'] as List) {
          // A shared prefix alone is not a match.
          if (!full.contains(m['hash'])) continue;
          _remember(
            m['identity_id'] as int,
            m['display_name'] as String,
            m['username'] as String?,
          );
          found++;
        }
      });
    }
    notify();
    return found;
  }

  /// Exact username lookup. Returns null if nobody has that username.
  Future<Contact?> lookupUsername(String username) async {
    await _loadAuthKey();
    final u = username.trim().toLowerCase().replaceFirst('@', '');
    if (u == myUsername) return null;
    try {
      final r = await api.get('/users/lookup', query: {'username': u}) as Map;
      _remember(
        r['identity_id'] as int,
        r['display_name'] as String,
        r['username'] as String?,
      );
      if (r['bot'] == true) _markBot(r['identity_id'] as int);
      notify();
      return contact(r['identity_id'] as int);
    } on ApiError catch (e) {
      if (e.status == 404 || e.status == 400) return null;
      rethrow;
    }
  }

  /// Pulls the account's username from the server. Returns false when the
  /// account predates usernames and still has to choose one.
  Future<bool> syncProfile() async {
    await _loadAuthKey();
    final me = await api.get('/me') as Map;
    // Also repairs the display name on installs that stored it wrongly.
    db.kvPutString('display_name', '${me['display_name']}');
    final before = db.kvString('status');
    db.kvPutString('status', '${me['status'] ?? 'active'}');
    if (before != db.kvString('status')) notify();
    final u = me['username'] as String?;
    if (u == null) return false;
    db.kvPutString('username', u);
    return true;
  }

  /// Changes the display name and/or the optional phone number that lets
  /// friends find this account from their address book. An empty [mobile]
  /// removes the number.
  Future<void> updateProfile({String? displayName, String? mobile}) async {
    await _loadAuthKey();
    final res =
        await api.post('/me/profile', {
              if (displayName != null) 'display_name': displayName.trim(),
              if (mobile != null) 'mobile': mobile.trim(),
            })
            as Map;
    db.kvPutString('display_name', '${res['display_name']}');
    if (mobile != null) {
      db.kvPutString('has_mobile', mobile.trim().isEmpty ? '0' : '1');
    }
    notify();
  }

  bool get hasMobile => db.kvString('has_mobile') == '1';

  /// Changes the account password. The current one is required, so a
  /// borrowed unlocked phone is not enough to take the account over.
  Future<void> changePassword(String current, String next) async {
    await _loadAuthKey();
    await api.post('/me/password', {'current': current, 'new': next});
  }

  // ---- wake-up alerts for browsers (web push) ----

  /// Key a browser needs to subscribe to this server's alerts, if any.
  String? get vapidKey {
    final k = db.kvString('vapid_key');
    return k == null || k.isEmpty ? null : k;
  }

  /// Registers this browser's push subscription with the server.
  Future<void> pushSubscribe(
    String endpoint,
    String p256dh,
    String auth,
  ) async {
    await _loadAuthKey();
    await api.post('/push/subscribe', {
      'endpoint': endpoint,
      'p256dh': p256dh,
      'auth': auth,
    });
  }

  /// Registers this phone's Google push token, or removes it when empty.
  /// Returns whether the server has a wake-up gateway configured.
  Future<bool> registerPhonePush(String token) async {
    await _loadAuthKey();
    final res = await api.post('/push/fcm', {'token': token}) as Map;
    return res['gateway'] == true;
  }

  Future<void> pushUnsubscribe() async {
    await _loadAuthKey();
    await api.post('/push/unsubscribe', {});
  }

  /// Tells the server the app left the screen, so the next message raises
  /// an alert instead of waiting to be fetched.
  Future<void> pushIdle() async {
    await _loadAuthKey();
    await api.post('/push/idle', {});
  }

  Future<void> setUsername(String username) async {
    await _loadAuthKey();
    final res =
        await api.post('/me/username', {
              'username': username.trim().toLowerCase().replaceFirst('@', ''),
            })
            as Map;
    db.kvPutString('username', res['username'] as String);
    notify();
  }

  Future<String> createGroup(String title, List<int> members) async {
    final gid = Messenger.newId();
    final all = {...members, myIdentity}.toList()..sort();
    await db.tx(() async => _applyGroup(gid, title.trim(), myIdentity, 1, all));
    await _queueControl('g:$gid', all, 'گروه «${title.trim()}» ساخته شد');
    unawaited(_shareAvatar(all).catchError((_) {}));
    return gid;
  }

  /// Admins only: replaces title and member list, bumping the epoch. The
  /// creator may also pass [admins] to choose who else is an admin.
  Future<void> updateGroup(
    String gid,
    String title,
    List<int> members, {
    List<int>? admins,
  }) async {
    final g = group(gid)!;
    if (!g.admins.contains(myIdentity)) {
      throw StateError('only an admin can edit');
    }
    // The creator stays in unless they left the group themselves.
    final all = {
      ...members,
      myIdentity,
      if (g.members.contains(g.admin)) g.admin,
    }.toList()..sort();
    final nextAdmins = g.admin == myIdentity && admins != null
        ? admins
        : g.admins;
    // Removed members are told too, so their copy shows they are out.
    final notifyIds = {...g.members, ...all}.toList();
    final added = all.where((m) => !g.members.contains(m)).toList();
    await db.tx(
      () async => _applyGroup(
        gid,
        title.trim(),
        g.admin,
        g.epoch + 1,
        all,
        admins: nextAdmins,
      ),
    );
    await _queueControl('g:$gid', notifyIds, 'اعضا یا نام گروه تغییر کرد');
    unawaited(_shareAvatar(added).catchError((_) {}));
    // Newcomers have not seen the group's picture yet.
    unawaited(_shareGroupAvatar(gid).catchError((_) {}));
  }

  void _applyGroup(
    String gid,
    String title,
    int admin,
    int epoch,
    List<int> members, {
    List<int>? admins,
  }) {
    final left = members.contains(myIdentity) ? 0 : 1;
    final adminList = {admin, ...?admins}.where(members.contains).toList()
      ..sort();
    db.raw.execute(
      'INSERT INTO groups (id, title, admin, epoch, left, admins) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET title = excluded.title, admin = excluded.admin, '
      'epoch = excluded.epoch, left = excluded.left, admins = excluded.admins',
      [gid, title, admin, epoch, left, jsonEncode(adminList)],
    );
    db.raw.execute('DELETE FROM group_members WHERE group_id = ?', [gid]);
    for (final m in members) {
      db.raw.execute(
        'INSERT INTO group_members (group_id, identity_id) VALUES (?, ?)',
        [gid, m],
      );
    }
  }

  Future<void> _queueControl(String chat, List<int> to, String note) async {
    final g = group(chat.substring(2))!;
    final id = Messenger.newId();
    final wire = {
      'v': 1,
      'cv': Messenger.capability,
      't': 'group',
      'id': id,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'gid': g.id,
      'title': g.title,
      'admin': g.admin,
      'admins': g.admins,
      'epoch': g.epoch,
      'members': g.members,
      // Members may not know each other; carry names so everyone can
      // show and mention them without asking the server.
      'names': {
        for (final id in g.members)
          '$id': id == myIdentity
              ? [myName, myUsername]
              : [nameOf(id), contact(id)?.username],
      },
      'fn': myName,
      if (myUsername != null) 'fu': myUsername,
    };
    await db.tx(
      () async => db.raw.execute(
        'INSERT INTO messages (chat, sender, outgoing, kind, body, client_msg_id, status, created_at, error) '
        'VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?)',
        [
          chat,
          myIdentity,
          'system',
          note,
          id,
          MsgStatus.pending,
          wire['ts'],
          // Stash the exact wire form and audience for the outbox.
          jsonEncode({'wire': wire, 'to': to}),
        ],
      ),
    );
    notify();
    unawaited(syncOnce().catchError((_) => false));
  }

  // ------------------------------------------------------------------
  // Identity verification
  // ------------------------------------------------------------------

  /// Short comparable code for a peer, derived from both identity keys.
  /// Both sides compute the same digits; a mismatch means a key was swapped.
  Future<String> safetyNumber(int peer) async {
    final mine = (await store.getIdentityKeyPair()).getPublicKey().serialize();
    final theirs = store.peerKeys('$peer').values.toList();
    if (theirs.isEmpty) return '';
    final parts = <Uint8List>[mine, ...theirs]
      ..sort((a, b) => base64Encode(a).compareTo(base64Encode(b)));
    final digest = (await Sha256().hash([for (final p in parts) ...p])).bytes;
    final out = StringBuffer();
    for (var i = 0; i < 12; i += 2) {
      final n = ((digest[i] << 8) | digest[i + 1]) % 100000;
      out.write(n.toString().padLeft(5, '0'));
      if (i < 10) out.write(' ');
    }
    return out.toString();
  }

  /// The user confirmed out of band that the peer really changed devices.
  Future<void> acceptNewIdentity(int peer) async {
    await db.tx(() async {
      store.forgetIdentity('$peer');
      db.raw.execute('DELETE FROM peer_devices WHERE identity_id = ?', [peer]);
      db.raw.execute(
        'UPDATE messages SET status = ?, error = NULL, payload = NULL WHERE outgoing = 1 AND status = ? AND error = ?',
        [MsgStatus.pending, MsgStatus.failed, 'identity_changed'],
      );
    });
    notify();
  }
}
