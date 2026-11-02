// Deleting whole chats and leaving groups, on one device's database.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

void main() {
  late Directory dir;
  late Messenger m;

  void msg(String chat, int sender, String body) => m.db.raw.execute(
    'INSERT INTO messages (chat, sender, outgoing, kind, body, client_msg_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [
      chat,
      sender,
      sender == 1 ? 1 : 0,
      'text',
      body,
      Messenger.newId(),
      MsgStatus.received,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );

  /// Pending wire messages the outbox would send, as "type:audience".
  List<String> queued(String chat) => [
    for (final r in m.db.raw.select(
      'SELECT error FROM messages WHERE chat = ? AND kind = ? AND status = ?',
      [chat, 'control', MsgStatus.pending],
    ))
      '${(jsonDecode(r['error'] as String)['wire'] as Map)['t']}:'
          '${(jsonDecode(r['error'] as String)['to'] as List).join(',')}',
  ];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('irm_wipe_');
    final db = openAppDbSync('${dir.path}/t.db', keyHex: key);
    m = Messenger(db, IoFileStore(dir));
    db.kvPutString('site', 'http://localhost:1');
    db.kvPutInt('device_id', 1);
    db.kvPutInt('identity_id', 1);
    db.kvPutString('display_name', 'me');
    db.raw.execute(
      "INSERT INTO groups (id, title, admin, epoch, left) VALUES ('g1', 'family', 1, 1, 0)",
    );
    for (final id in [1, 2, 3]) {
      db.raw.execute(
        "INSERT INTO group_members (group_id, identity_id) VALUES ('g1', ?)",
        [id],
      );
    }
    msg('u:2', 2, 'hello');
    msg('u:2', 1, 'hi');
    msg('u:3', 3, 'keep me');
    msg('g:g1', 2, 'group hello');
    db.kvPutInt('read:u:2', 2);
  });

  tearDown(() {
    m.dispose();
    m.db.close();
    dir.deleteSync(recursive: true);
  });

  test('deleting a person chat leaves nothing of it, and only it', () async {
    await m.deleteChat('u:2');
    expect(m.messages('u:2'), isEmpty);
    expect(m.db.kvInt('read:u:2'), isNull);
    expect(m.messages('u:3'), hasLength(1));
    expect(m.chats().map((c) => c.chat), isNot(contains('u:2')));
  });

  test('for both: sent only when the other app understands it', () async {
    await m.deleteChat('u:2', forBoth: true);
    expect(queued('u:2'), isEmpty);

    msg('u:3', 3, 'again');
    m.db.kvPutInt('cap:3', 3);
    expect(m.canClearForBoth('u:3'), isTrue);
    await m.deleteChat('u:3', forBoth: true);
    expect(queued('u:3'), ['clear:3']);
    // The notice waits in the outbox but the chat is gone from the list.
    expect(m.messages('u:3'), isEmpty);
    expect(m.chats().map((c) => c.chat), ['g:g1']);
  });

  test('deleting a group leaves it and forgets everything about it', () async {
    m.db.kvPutInt('cap:2', 3);
    await m.deleteChat('g:g1');
    expect(m.group('g1'), isNull);
    expect(m.messages('g:g1'), isEmpty);
    expect(queued('g:g1'), ['leave:2']);
    expect(m.db.kvInt('left:g1'), isNotNull);
  });

  test('the creator may delete the group for everyone', () async {
    m.db.kvPutInt('cap:2', 3);
    m.db.kvPutInt('cap:3', 3);
    await m.deleteChat('g:g1', forBoth: true);
    expect(queued('g:g1'), ['gdel:2,3']);
    expect(m.group('g1'), isNull);
  });
}
