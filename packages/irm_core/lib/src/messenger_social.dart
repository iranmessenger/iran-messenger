part of 'messenger.dart';

/// One entry of the server's shared GIF collection.
class GifItem {
  GifItem(this.id, this.mime, this.size, this.trending);
  final String id;
  final String mime;
  final int size;

  /// True for items the server relays from the internet; they come with a
  /// small still picture for the grid.
  final bool trending;
}

/// Read receipts, deleting for everyone, profile pictures and the shared
/// GIF collection.
///
/// The first three travel as end-to-end encrypted control messages, like
/// reactions: the server learns neither who read what nor what a picture
/// shows.
extension MessengerSocial on Messenger {
  // ------------------------------------------------------------------
  // Read receipts
  // ------------------------------------------------------------------

  /// Reciprocal: with this off, nothing is reported to others and what
  /// others report is not shown.
  bool get readReceipts => (db.kvInt('read_receipts') ?? 1) == 1;

  void setReadReceipts(bool on) {
    db.kvPutInt('read_receipts', on ? 1 : 0);
    notify();
  }

  /// Tells the senders which of their messages in [chat] were just seen.
  Future<void> sendReadReceipts(String chat) async {
    if (!readReceipts || !isRegistered || isPending) return;
    final from = db.kvInt('rr:$chat') ?? 0;
    final rows = db.raw.select(
      'SELECT id, client_msg_id FROM messages WHERE chat = ? AND outgoing = 0 '
      'AND id > ? AND client_msg_id IS NOT NULL AND kind IN (?, ?, ?, ?) '
      'ORDER BY id DESC LIMIT 60',
      [chat, from, 'text', 'media', 'poll', 'buzz'],
    );
    if (rows.isEmpty) return;
    db.kvPutInt('rr:$chat', rows.first['id'] as int);
    try {
      await _queueControl2(chat, {
        't': 'read',
        'ids': [for (final r in rows) r['client_msg_id']],
      }, newClientsOnly: true);
    } on StateError {
      // No longer a member of this group.
    }
  }

  void _applyRead(String chat, int from, Map<String, dynamic> wire, int ts) {
    final ids = wire['ids'];
    // This user's own reading never counts as someone else having seen it.
    if (from == myIdentity) return;
    if (!readReceipts || ids is! List || ids.length > 100) return;
    for (final id in ids) {
      final rows = db.raw.select(
        'SELECT id, readers FROM messages WHERE client_msg_id = ? AND chat = ? AND outgoing = 1',
        [id, chat],
      );
      if (rows.isEmpty) continue;
      final readers = rows.first['readers'] == null
          ? <String, dynamic>{}
          : (jsonDecode(rows.first['readers'] as String) as Map)
                .cast<String, dynamic>();
      if (readers.containsKey('$from')) continue;
      readers['$from'] = ts;
      db.raw.execute(
        'UPDATE messages SET readers = ?, status = CASE WHEN status IN (?, ?) THEN ? ELSE status END WHERE id = ?',
        [
          jsonEncode(readers),
          MsgStatus.sent,
          MsgStatus.delivered,
          MsgStatus.read,
          rows.first['id'],
        ],
      );
    }
    notify();
  }

  // ------------------------------------------------------------------
  // Deleting
  // ------------------------------------------------------------------

  void _removeMessage(int rowId) {
    final rows = db.raw.select('SELECT media FROM messages WHERE id = ?', [
      rowId,
    ]);
    if (rows.isEmpty) return;
    final media = rows.first['media'] as String?;
    if (media != null) {
      final path = (jsonDecode(media) as Map)['path'];
      if (path is String) unawaited(files.delete(path).catchError((_) {}));
    }
    db.raw.execute('DELETE FROM messages WHERE id = ?', [rowId]);
  }

  /// Removes one of this user's own messages here and asks every recipient
  /// to remove it too. A recipient that is offline does so when it next
  /// connects; nothing can take back what was already seen or copied.
  Future<bool> deleteForEveryone(ChatMessage msg) async {
    if (!msg.outgoing || msg.clientMsgId == null) return false;
    _removeMessage(msg.id);
    notify();
    _takeBackFile(msg.media?.serverId);
    try {
      await _queueControl2(msg.chat, {
        't': 'del',
        'target': msg.clientMsgId,
      }, newClientsOnly: true);
    } on StateError {
      return false;
    }
    return true;
  }

  /// Removes this user's uploaded file from the server at once, instead of
  /// leaving it until every recipient has fetched it or it expires. Kept
  /// for the next sync if the server cannot be reached now.
  void _takeBackFile(String? serverId) {
    if (serverId == null) return;
    final pending = {...?db.kvString('take_back')?.split(',')}..remove('');
    db.kvPutString('take_back', ({...pending, serverId}).join(','));
    unawaited(_sendTakeBacks().catchError((_) {}));
  }

  Future<void> _sendTakeBacks() async {
    final pending = {...?db.kvString('take_back')?.split(',')}..remove('');
    if (pending.isEmpty) return;
    await _loadAuthKey();
    for (final id in pending) {
      try {
        await api.post('/media/$id/delete', {});
      } on ApiError catch (e) {
        // 404: already gone (fetched by everyone, or expired).
        if (e.status != 404) continue;
      }
      final left = {...?db.kvString('take_back')?.split(',')}..remove(id);
      db.kvPutString('take_back', left.join(','));
    }
  }

  void _applyDelete(String chat, int from, Map<String, dynamic> wire) {
    // Only the original sender may take a message back.
    final rows = db.raw.select(
      'SELECT id FROM messages WHERE client_msg_id = ? AND chat = ? AND sender = ? AND outgoing = 0',
      [wire['target'], chat, from],
    );
    if (rows.isEmpty) return;
    _removeMessage(rows.first['id'] as int);
    notify();
  }

  // ------------------------------------------------------------------
  // Profile pictures
  // ------------------------------------------------------------------

  String? _existing(String? path) =>
      path != null && path.isNotEmpty && files.existsSync(path) ? path : null;

  String? get myAvatar => _existing(db.kvString('avatar'));

  String? avatarOf(int identity) =>
      identity == myIdentity ? myAvatar : _existing(contact(identity)?.avatar);

  String? chatAvatar(String chat) => chat.startsWith('g:')
      ? _existing(group(chat.substring(2))?.avatar)
      : avatarOf(int.parse(chat.substring(2)));

  /// Everyone this user talks to: chat partners and fellow group members.
  List<int> _acquaintances() {
    final ids = <int>{};
    for (final r in db.raw.select(
      "SELECT DISTINCT chat FROM messages WHERE chat LIKE 'u:%'",
    )) {
      ids.add(int.parse((r['chat'] as String).substring(2)));
    }
    for (final r in db.raw.select(
      'SELECT m.identity_id FROM group_members m JOIN groups g ON g.id = m.group_id WHERE g.left = 0',
    )) {
      ids.add(r['identity_id'] as int);
    }
    return ids.where((i) => i != myIdentity).toList();
  }

  Future<void> _queueAvatar(
    String chat,
    List<int> all,
    String? path, {
    String? gid,
  }) async {
    await _learnCapabilities(all);
    final to = all.where(_capable).toList();
    if (to.isEmpty) return;
    final id = Messenger.newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final info = path == null
        ? null
        : MediaInfo(
            kind: 'image',
            mime: 'image/jpeg',
            name: 'avatar.jpg',
            size: (await files.read(path)).length,
            path: path,
          );
    await db.tx(
      () async => db.raw.execute(
        'INSERT INTO messages (chat, sender, outgoing, kind, body, media, client_msg_id, status, created_at, error) '
        'VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?)',
        [
          chat,
          myIdentity,
          'control',
          '',
          info == null ? null : jsonEncode(info.toJson()),
          id,
          MsgStatus.pending,
          now,
          jsonEncode({
            'wire': {
              'v': 1,
              'cv': Messenger.capability,
              't': 'avatar',
              'id': id,
              'ts': now,
              'gid': ?gid,
              'fn': myName,
              'fu': ?myUsername,
            },
            'to': to,
          }),
        ],
      ),
    );
    unawaited(syncOnce().catchError((_) => false));
  }

  /// Sends this user's current picture to whoever in [to] lacks it.
  Future<void> _shareAvatar(Iterable<int> to) async {
    final version = db.kvInt('avatar_v') ?? 0;
    if (version == 0) return;
    await _learnCapabilities(to);
    final need = [
      for (final id in to)
        if (id != myIdentity &&
            _capable(id) &&
            (db.kvInt('av:$id') ?? 0) != version)
          id,
    ];
    if (need.isEmpty) return;
    for (final id in need) {
      db.kvPutInt('av:$id', version);
    }
    await _queueAvatar('u:$myIdentity', need, myAvatar);
  }

  /// Sets (or with null removes) this user's picture. [jpeg] should be a
  /// small square JPEG. It goes, encrypted, only to people this user
  /// already talks to; new contacts get it with the first message.
  Future<void> setMyAvatar(Uint8List? jpeg) async {
    final old = db.kvString('avatar');
    var path = '';
    if (jpeg != null) {
      path = files.newPath('avatars', '${Messenger.newId()}.jpg');
      await files.write(path, jpeg);
    }
    db.kvPutString('avatar', path);
    db.kvPutInt('avatar_v', (db.kvInt('avatar_v') ?? 0) + 1);
    if (old != null && old.isNotEmpty) {
      unawaited(files.delete(old).catchError((_) {}));
    }
    notify();
    await _shareAvatar(_acquaintances());
  }

  /// Sets (or removes) a group's picture. Admins only.
  Future<void> setGroupAvatar(String gid, Uint8List? jpeg) async {
    final g = group(gid)!;
    if (!g.admins.contains(myIdentity)) {
      throw StateError('only an admin can edit');
    }
    String? path;
    if (jpeg != null) {
      path = files.newPath('avatars', '${Messenger.newId()}.jpg');
      await files.write(path, jpeg);
    }
    _setAvatar('g:$gid', path);
    db.kvPutInt('gav:$gid', (db.kvInt('gav:$gid') ?? 0) + 1);
    await _shareGroupAvatar(gid);
  }

  /// Sends the picture this admin chose for [gid] to members who lack it.
  /// Members whose app has not announced itself yet get it later.
  Future<void> _shareGroupAvatar(String gid) async {
    final version = db.kvInt('gav:$gid') ?? 0;
    final g = group(gid);
    if (version == 0 || g == null || !g.admins.contains(myIdentity)) return;
    await _learnCapabilities(g.members);
    final need = [
      for (final id in g.members)
        if (id != myIdentity &&
            _capable(id) &&
            (db.kvInt('gav:$gid:$id') ?? 0) != version)
          id,
    ];
    if (need.isEmpty) return;
    for (final id in need) {
      db.kvPutInt('gav:$gid:$id', version);
    }
    await _queueAvatar('g:$gid', need, _existing(g.avatar), gid: gid);
  }

  /// Someone's app just announced that it understands pictures: offer
  /// ours, and those of the groups we set a picture for.
  Future<void> _greet(Iterable<int> identities) async {
    await _shareAvatar(identities.where(_acquaintances().contains));
    for (final r in db.raw.select('SELECT id FROM groups WHERE left = 0')) {
      await _shareGroupAvatar(r['id'] as String);
    }
  }

  /// [target] is `c:<identity>` or `g:<group id>`.
  void _setAvatar(String target, String? path) {
    final group = target.startsWith('g:');
    final key = target.substring(2);
    final rows = group
        ? db.raw.select('SELECT avatar FROM groups WHERE id = ?', [key])
        : db.raw.select('SELECT avatar FROM contacts WHERE identity_id = ?', [
            int.parse(key),
          ]);
    if (rows.isEmpty) return;
    final old = rows.first['avatar'] as String?;
    if (old != null && old != path) {
      unawaited(files.delete(old).catchError((_) {}));
    }
    if (group) {
      db.raw.execute('UPDATE groups SET avatar = ? WHERE id = ?', [path, key]);
    } else {
      db.raw.execute('UPDATE contacts SET avatar = ? WHERE identity_id = ?', [
        path,
        int.parse(key),
      ]);
    }
    notify();
  }

  /// Runs inside the caller's transaction. The picture itself is fetched
  /// afterwards by [_fetchAvatars].
  void _receiveAvatar(
    int from,
    String? gid,
    Map<String, dynamic> wire,
    int deliveryId,
    int ts,
  ) {
    if (gid != null && !(group(gid)?.admins.contains(from) ?? false)) return;
    final target = gid == null ? 'c:$from' : 'g:$gid';
    // A newer picture replaces one that was still waiting to be fetched.
    db.raw.execute(
      'DELETE FROM messages WHERE kind = ? AND outgoing = 0 AND body = ?',
      ['control', target],
    );
    if (wire['media'] is! Map) {
      _setAvatar(target, null);
      return;
    }
    final info = MediaInfo.fromJson(
      (wire['media'] as Map).cast<String, dynamic>(),
    );
    if (info.size > 600 * 1024 || !info.mime.startsWith('image/')) return;
    db.raw.execute(
      'INSERT INTO messages (chat, sender, outgoing, kind, body, media, delivery_id, status, created_at) '
      'VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)',
      [
        gid == null ? 'u:$from' : 'g:$gid',
        from,
        'control',
        target,
        jsonEncode(info.toJson()),
        deliveryId,
        MsgStatus.received,
        ts,
      ],
    );
  }

  Future<void> _fetchAvatars() async {
    final rows = db.raw.select(
      'SELECT id, body FROM messages WHERE kind = ? AND outgoing = 0 AND media IS NOT NULL',
      ['control'],
    );
    for (final r in rows) {
      final id = r['id'] as int;
      String? path;
      try {
        path = await media.download(id);
      } on StateError {
        path = null; // damaged in transit
      } on ApiError catch (e) {
        if (e.status == 401 || e.status == 429 || e.status >= 500) rethrow;
        path = null;
      }
      if (path != null) _setAvatar(r['body'] as String, path);
      db.raw.execute('DELETE FROM messages WHERE id = ?', [id]);
    }
  }

  // ------------------------------------------------------------------
  // Shared GIF collection
  // ------------------------------------------------------------------

  /// What the administrator added, plus (if the server is set up for it)
  /// currently popular GIFs. The server fetches those itself, so the
  /// outside service never learns who is looking.
  Future<List<GifItem>> gifLibrary() async {
    await _loadAuthKey();
    return _gifItems(await api.get('/gifs') as Map);
  }

  /// GIPHY search, run by the server so GIPHY never sees who searched.
  /// Throws ApiError 501 when the server has no GIPHY key.
  Future<List<GifItem>> searchGifs(String query, {int offset = 0}) async {
    await _loadAuthKey();
    return _gifItems(
      await api.get(
            '/gifs/search',
            query: {'q': query.trim(), 'offset': '$offset'},
          )
          as Map,
    );
  }

  List<GifItem> _gifItems(Map res) => [
    for (final g in res['items'] as List)
      GifItem(
        '${g['id']}',
        '${g['mime']}',
        (g['size'] as num).toInt(),
        // Anything from GIPHY shows a still picture in the grid.
        g['src'] != 'pack',
      ),
  ];

  /// Bytes of a library item (or its still picture), kept on this device
  /// after the first fetch. Returns the local path.
  Future<String> gifFile(GifItem item, {bool thumb = false}) async {
    final ext = thumb
        ? '.jpg'
        : item.mime.startsWith('video/')
        ? '.mp4'
        : item.mime == 'image/webp'
        ? '.webp'
        : '.gif';
    final path = files.newPath('gifs', '${item.id}${thumb ? '_t' : ''}$ext');
    if (files.existsSync(path)) return path;
    await _loadAuthKey();
    final res =
        await api.get(
              '/gifs/${item.id}',
              query: thumb ? const {'thumb': '1'} : const {},
            )
            as Map;
    final bytes = base64Decode(res['data'] as String);
    await files.write(path, bytes);
    if (!thumb) media.remember(await MediaTransfer.plainHash(bytes), path);
    return path;
  }

  Future<void> sendLibraryGif(String chat, GifItem item) async {
    final path = await gifFile(item);
    await sendMedia(
      chat,
      await files.read(path),
      name: path.substring(path.lastIndexOf('/') + 1),
      kind: 'gif',
      mime: item.mime,
    );
  }
}
