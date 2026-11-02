part of 'messenger.dart';

/// Deleting whole chats, leaving groups and deleting a group for everyone.
///
/// A wiped chat leaves nothing on this device: messages, their files, the
/// read mark and, for a group, its members, name and picture. Only a
/// pending leave/clear notice stays until it has been sent; it is never
/// shown. Nothing can take back what another device already saw or copied.
extension MessengerWipe on Messenger {
  /// The other side of [chat] understands chat-wide deletes (app 2.8+).
  bool canClearForBoth(String chat) {
    if (chat.startsWith('u:')) return _capable(int.parse(chat.substring(2)), 3);
    final g = group(chat.substring(2));
    return g != null && g.members.any((m) => m != myIdentity && _capable(m, 3));
  }

  /// Deletes [chat] from this device. For a person, [forBoth] also asks
  /// their app to delete it. For a group, this user leaves it first; if
  /// they created it and pass [forBoth], it is deleted for every member.
  Future<void> deleteChat(String chat, {bool forBoth = false}) async {
    if (forBoth) {
      // Own files in this chat go from the server too.
      for (final m in sharedMedia(chat, const {
        'image',
        'video',
        'gif',
        'sticker',
        'voice',
        'file',
      })) {
        if (m.outgoing) _takeBackFile(m.media?.serverId);
      }
    }
    if (chat.startsWith('u:')) {
      if (forBoth && canClearForBoth(chat)) {
        await _queueControl2(chat, {'t': 'clear'}, minCapability: 3);
      }
      await db.tx(() async => _wipeChat(chat));
      notify();
      return;
    }
    final gid = chat.substring(2);
    final g = group(gid);
    if (g != null && !g.left) {
      final everyone = forBoth && g.admin == myIdentity;
      try {
        await _queueControl2(chat, {
          't': everyone ? 'gdel' : 'leave',
        }, minCapability: 3);
      } on StateError {
        // Already out of the group; nothing to tell anyone.
      }
    }
    await db.tx(() async {
      _wipeChat(chat);
      // Old invitations still in flight must not bring the group back.
      db.kvPutInt('left:$gid', DateTime.now().millisecondsSinceEpoch);
    });
    notify();
    unawaited(syncOnce().catchError((_) => false));
  }

  void _wipeChat(String chat) {
    for (final r in db.raw.select(
      'SELECT id FROM messages WHERE chat = ? AND NOT (outgoing = 1 AND kind = ? AND status = ?)',
      [chat, 'control', MsgStatus.pending],
    )) {
      _removeMessage(r['id'] as int);
    }
    db.raw.execute('DELETE FROM kv WHERE k = ?', ['read:$chat']);
    if (chat.startsWith('g:')) {
      final gid = chat.substring(2);
      final avatar = group(gid)?.avatar;
      if (avatar != null) unawaited(files.delete(avatar).catchError((_) {}));
      db.raw.execute('DELETE FROM group_members WHERE group_id = ?', [gid]);
      db.raw.execute('DELETE FROM groups WHERE id = ?', [gid]);
    }
  }

  /// Whether a group invitation or update dated [ts] predates this user
  /// leaving the group, so it must not re-create it.
  bool _leftAfter(String gid, int ts) => ts < (db.kvInt('left:$gid') ?? 0);

  /// Incoming clear/leave/gdel. Runs inside the caller's transaction.
  void _applyWipe(String chat, int from, String type) {
    switch (type) {
      case 'clear':
        // Only the person this chat is with can clear it.
        if (chat == 'u:$from') _wipeChat(chat);
      case 'gdel':
        final g = group(chat.substring(2));
        if (g != null && from == g.admin) _wipeChat(chat);
      case 'leave':
        _removeMember(chat.substring(2), from);
    }
    notify();
  }

  /// Takes [who] out of the group on this device. If no admin is left,
  /// every device promotes the same member (the lowest id), so they stay
  /// in agreement without a message from anyone.
  void _removeMember(String gid, int who) {
    final g = group(gid);
    if (g == null || !g.members.contains(who)) return;
    final members = g.members.where((m) => m != who).toList();
    var admins = g.admins.where((a) => a != who).toList();
    if (admins.isEmpty && members.isNotEmpty) admins = [members.reduce(min)];
    _applyGroup(gid, g.title, g.admin, g.epoch, members, admins: admins);
    db.raw.execute(
      'INSERT INTO messages (chat, sender, outgoing, kind, body, status, created_at) '
      'VALUES (?, ?, 0, ?, ?, ?, ?)',
      [
        'g:$gid',
        who,
        'system',
        '${nameOf(who)} از گروه خارج شد',
        MsgStatus.received,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }
}
