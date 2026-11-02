part of 'messenger.dart';

/// What the interface reads: contacts, groups, chats and messages.
extension MessengerReads on Messenger {
  // ------------------------------------------------------------------
  // Reads for the UI
  // ------------------------------------------------------------------

  /// People this device has learned about: address-book matches, exact
  /// username lookups, and anyone who has written to us.
  List<Contact> contacts() => [
    for (final r in db.raw.select(
      'SELECT identity_id, display_name, username, avatar FROM contacts WHERE identity_id != ? ORDER BY display_name',
      [myIdentity],
    ))
      Contact(
        r['identity_id'] as int,
        r['display_name'] as String,
        r['username'] as String?,
        r['avatar'] as String?,
      ),
  ];

  Contact? contact(int identityId) {
    final rows = db.raw.select(
      'SELECT display_name, username, avatar FROM contacts WHERE identity_id = ?',
      [identityId],
    );
    return rows.isEmpty
        ? null
        : Contact(
            identityId,
            rows.first['display_name'] as String,
            rows.first['username'] as String?,
            rows.first['avatar'] as String?,
          );
  }

  void _remember(int identityId, String? name, String? username) {
    if (identityId == myIdentity || name == null || name.isEmpty) return;
    db.raw.execute(
      'INSERT INTO contacts (identity_id, display_name, username) VALUES (?, ?, ?) '
      'ON CONFLICT(identity_id) DO UPDATE SET display_name = excluded.display_name, '
      'username = COALESCE(excluded.username, contacts.username)',
      [identityId, name, username],
    );
  }

  int unread(String chat) {
    final last = db.kvInt('read:$chat') ?? 0;
    return db.raw.select(
          'SELECT COUNT(*) AS n FROM messages WHERE chat = ? AND outgoing = 0 AND id > ? AND kind IN (?, ?, ?, ?)',
          [chat, last, 'text', 'media', 'poll', 'buzz'],
        ).first['n']
        as int;
  }

  void markRead(String chat) {
    final rows = db.raw.select(
      'SELECT MAX(id) AS m FROM messages WHERE chat = ?',
      [chat],
    );
    final max = rows.first['m'] as int?;
    if (max != null && max != db.kvInt('read:$chat')) {
      db.kvPutInt('read:$chat', max);
      notify();
      unawaited(sendReadReceipts(chat).catchError((_) {}));
    }
  }

  /// Removes a message from this device only.
  void deleteLocal(int messageId) {
    _removeMessage(messageId);
    notify();
  }

  /// True if [body] contains @myusername as a whole word.
  bool mentionsMe(String body) {
    final u = myUsername;
    if (u == null || u.isEmpty) return false;
    return RegExp(
      '(^|[^A-Za-z0-9_])@$u([^A-Za-z0-9_])',
      caseSensitive: false,
    ).hasMatch('$body ');
  }

  String nameOf(int identityId) {
    if (identityId == myIdentity) return myName;
    final rows = db.raw.select(
      'SELECT display_name FROM contacts WHERE identity_id = ?',
      [identityId],
    );
    return rows.isEmpty ? '#$identityId' : rows.first['display_name'] as String;
  }

  GroupInfo? group(String gid) {
    final rows = db.raw.select('SELECT * FROM groups WHERE id = ?', [gid]);
    if (rows.isEmpty) return null;
    final g = rows.first;
    final members = [
      for (final m in db.raw.select(
        'SELECT identity_id FROM group_members WHERE group_id = ? ORDER BY identity_id',
        [gid],
      ))
        m['identity_id'] as int,
    ];
    final admin = g['admin'] as int;
    return GroupInfo(
      gid,
      g['title'] as String,
      admin,
      g['epoch'] as int,
      members,
      left: g['left'] == 1,
      admins: {
        admin,
        if (g['admins'] != null)
          ...(jsonDecode(g['admins'] as String) as List)
              .map((e) => (e as num).toInt())
              .where(members.contains),
      }.toList(),
      avatar: g['avatar'] as String?,
    );
  }

  String chatTitle(String chat) => chat.startsWith('g:')
      ? (group(chat.substring(2))?.title ?? 'گروه')
      : nameOf(int.parse(chat.substring(2)));

  List<ChatMessage> messages(String chat, {int limit = 300}) => [
    for (final r in db.raw.select(
      'SELECT * FROM (SELECT * FROM messages WHERE chat = ? AND kind != ? ORDER BY id DESC LIMIT ?) ORDER BY id',
      [chat, 'control', limit],
    ))
      ChatMessage.fromRow(r),
  ];

  /// Attachments shared in [chat] whose kind is in [kinds] (image, video,
  /// gif, sticker, voice, file), newest first.
  List<ChatMessage> sharedMedia(String chat, Set<String> kinds) => [
    for (final r in db.raw.select(
      'SELECT * FROM messages WHERE chat = ? AND kind = ? AND media IS NOT NULL ORDER BY id DESC LIMIT 1000',
      [chat, 'media'],
    ))
      ChatMessage.fromRow(r),
  ].where((m) => kinds.contains(m.media?.kind)).toList();

  /// Text messages in [chat] that contain a web address, newest first.
  List<ChatMessage> sharedLinks(String chat) => [
    for (final r in db.raw.select(
      "SELECT * FROM messages WHERE chat = ? AND kind IN ('text', 'media') "
      "AND (body LIKE '%http://%' OR body LIKE '%https://%' OR body LIKE '%www.%') "
      'ORDER BY id DESC LIMIT 500',
      [chat],
    ))
      ChatMessage.fromRow(r),
  ];

  /// Chats that have at least one message, newest first.
  List<ChatSummary> chats() => [
    for (final r in db.raw.select(
      'SELECT m.* FROM messages m JOIN (SELECT chat, MAX(id) AS id FROM messages WHERE kind != \'control\' GROUP BY chat) x ON x.id = m.id ORDER BY m.id DESC',
    ))
      ChatSummary(
        r['chat'] as String,
        chatTitle(r['chat'] as String),
        ChatMessage.fromRow(r),
        (r['chat'] as String).startsWith('g:'),
        unread: unread(r['chat'] as String),
      ),
  ];
}
