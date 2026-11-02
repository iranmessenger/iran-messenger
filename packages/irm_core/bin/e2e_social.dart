// End-to-end checks for read receipts, deleting for everyone, profile
// pictures, several group admins and the shared GIF collection, against a
// real server:
//
//   dart run bin/e2e_social.dart <site-url> <code-A> <code-B> <code-C>
//
// The server needs one item in its GIF collection
// (scripts/local-dev-setup.php ... --gif).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [Object? detail]) {
  ok ? _passed++ : _failed++;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $name${detail == null || ok ? '' : '  -> $detail'}',
  );
}

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln(
      'usage: e2e_social.dart <site-url> <code-A> <code-B> <code-C>',
    );
    exit(64);
  }
  final r = Random.secure();
  final dir = Directory.systemTemp.createTempSync('irm_social_');
  final all = <Messenger>[];

  Future<Messenger> member(String name, String code) async {
    final key = List.generate(
      64,
      (_) => r.nextInt(16).toRadixString(16),
    ).join();
    final m = Messenger(
      openAppDbSync('${dir.path}/$name.db', keyHex: key),
      IoFileStore(Directory('${dir.path}/files_$name')),
    );
    all.add(m);
    await m.register(
      site: args[0],
      username: '$name${r.nextInt(900000) + 100000}',
      password: 'social-test-pass-1',
      inviteCode: code,
    );
    return m;
  }

  /// Everybody sends what is queued and fetches what is waiting, twice, so
  /// that answers to answers arrive too.
  Future<void> settle() async {
    for (var i = 0; i < 2; i++) {
      for (final m in all) {
        await m.syncOnce();
      }
    }
  }

  Uint8List picture(int seed) =>
      Uint8List.fromList(List.generate(9000, (i) => (i * 31 + seed) % 251));

  try {
    final a = await member('alice', args[1]);
    final b = await member('bob', args[2]);
    final c = await member('carol', args[3]);
    final toBob = 'u:${b.myIdentity}';
    final toAlice = 'u:${a.myIdentity}';
    await a.lookupUsername(b.myUsername!);
    await a.lookupUsername(c.myUsername!);

    // ---- read receipts ----
    await a.sendText(toBob, 'سلام');
    await settle();
    check(
      'delivered is not yet read',
      a.messages(toBob).last.status == MsgStatus.delivered,
      a.messages(toBob).last.status,
    );
    b.markRead(toAlice);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await settle();
    check(
      'sender sees the message was read',
      a.messages(toBob).last.status == MsgStatus.read &&
          a.messages(toBob).last.readers.containsKey('${b.myIdentity}'),
      a.messages(toBob).last.status,
    );
    check(
      'a read receipt is not shown as a message',
      a.messages(toBob).length == 1 && b.messages(toAlice).length == 1,
    );

    b.setReadReceipts(false);
    await a.sendText(toBob, 'دومی');
    await settle();
    b.markRead(toAlice);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await settle();
    check(
      'with receipts off nothing is reported',
      a.messages(toBob).last.status == MsgStatus.delivered,
      a.messages(toBob).last.status,
    );
    b.setReadReceipts(true);

    // ---- delete for everyone ----
    await a.sendText(toBob, 'اشتباهی');
    await settle();
    final wrong = a.messages(toBob).last;
    check(
      'recipient has the message before it is taken back',
      b.messages(toAlice).any((m) => m.body == 'اشتباهی'),
    );
    await a.deleteForEveryone(wrong);
    await settle();
    check(
      'deleted for everyone: gone on both sides',
      !a.messages(toBob).any((m) => m.body == 'اشتباهی') &&
          !b.messages(toAlice).any((m) => m.body == 'اشتباهی'),
    );
    // Bob tries to delete Alice's message on her device.
    final hers = b.messages(toAlice).firstWhere((m) => m.body == 'سلام');
    await b.api.post('/envelopes', {
      'client_msg_id': Messenger.newId(),
      'quiet': true,
      'envelopes': [
        for (final d in await b.devicesOf(a.myIdentity))
          await (() async {
            final e = await b.crypto.encrypt(
              '${a.myIdentity}',
              d,
              utf8Bytes(
                '{"v":1,"cv":2,"t":"del","target":"${hers.clientMsgId}","ts":1}',
              ),
            );
            return {
              'to_device': d,
              'type': e.type,
              'body': base64Encode(e.body),
            };
          })(),
      ],
    });
    await settle();
    check(
      'nobody can delete someone else\'s message',
      a.messages(toBob).any((m) => m.body == 'سلام'),
    );

    // The reported bug: Alice had never heard from Bob's updated app, so
    // her delete request was not sent. Now she asks the server.
    await b.refreshConfig();
    await a.sendText(toBob, 'فایل اشتباهی');
    await settle();
    a.db.kvPutInt('cap:${b.myIdentity}', 1);
    a.db.kvPutInt('capchk:${b.myIdentity}', 0);
    await a.deleteForEveryone(a.messages(toBob).last);
    await settle();
    check(
      'delete reaches an updated app that has not written yet',
      !b.messages(toAlice).any((m) => m.body == 'فایل اشتباهی'),
    );

    // An old app would show control messages as empty bubbles, so none
    // is sent to it.
    await b.api.post('/caps', {'mine': 1, 'ids': <int>[]});
    await a.sendText(toBob, 'برای برنامه قدیمی');
    await settle();
    a.db.kvPutInt('cap:${b.myIdentity}', 1);
    a.db.kvPutInt('capchk:${b.myIdentity}', 0);
    await a.deleteForEveryone(a.messages(toBob).last);
    await settle();
    check(
      'old apps are not sent delete requests',
      b.messages(toAlice).any((m) => m.body == 'برای برنامه قدیمی') &&
          !b.messages(toAlice).any((m) => m.body.isEmpty),
    );
    await b.api.post('/caps', {'mine': Messenger.capability, 'ids': <int>[]});
    a.db.kvPutInt('cap:${b.myIdentity}', Messenger.capability);

    // ---- profile pictures ----
    final mine = picture(1);
    await a.setMyAvatar(mine);
    await settle();
    final atBob = b.avatarOf(a.myIdentity);
    check(
      'a contact receives the profile picture',
      atBob != null && _eq(await b.files.read(atBob), mine),
    );
    check(
      'someone never written to does not get it',
      c.avatarOf(a.myIdentity) == null,
    );
    check(
      'a picture is not shown as a message',
      !b.messages(toAlice).any((m) => m.kind == 'media'),
    );
    final newer = picture(2);
    await a.setMyAvatar(newer);
    await settle();
    final atBob2 = b.avatarOf(a.myIdentity);
    check(
      'a new picture replaces the old one',
      atBob2 != null &&
          _eq(await b.files.read(atBob2), newer) &&
          !b.files.existsSync(atBob!),
    );
    await a.setMyAvatar(null);
    await settle();
    check(
      'removing the picture removes it for contacts',
      b.avatarOf(a.myIdentity) == null,
    );
    await a.setMyAvatar(mine);
    await settle();

    // ---- group, several admins, group picture ----
    final gid = await a.createGroup('دوستان', [b.myIdentity, c.myIdentity]);
    final g = 'g:$gid';
    await settle();
    check(
      'new group has its creator as the only admin',
      b.group(gid)!.admins.length == 1 && b.group(gid)!.admin == a.myIdentity,
    );
    check(
      'a member whose app has not announced itself gets no picture yet',
      c.avatarOf(a.myIdentity) == null,
    );
    await c.sendText(g, 'سلام از کارول');
    await settle();
    check(
      'group members get the creator\'s picture once they have written',
      c.avatarOf(a.myIdentity) != null,
    );
    var refused = false;
    try {
      await b.updateGroup(gid, 'تصرف', [a.myIdentity, c.myIdentity]);
    } on StateError {
      refused = true;
    }
    check('a plain member cannot edit the group', refused);

    await a.updateGroup(
      gid,
      'دوستان',
      [b.myIdentity, c.myIdentity],
      admins: [b.myIdentity],
    );
    await settle();
    check(
      'creator appoints a second admin',
      b.group(gid)!.admins.contains(b.myIdentity) &&
          c.group(gid)!.admins.contains(b.myIdentity),
    );
    await b.updateGroup(gid, 'دوستان قدیمی', [a.myIdentity, c.myIdentity]);
    await settle();
    check(
      'the second admin can rename the group',
      a.group(gid)!.title == 'دوستان قدیمی' &&
          c.group(gid)!.title == 'دوستان قدیمی',
    );
    // An admin who is not the creator cannot appoint admins.
    await b.updateGroup(
      gid,
      'دوستان قدیمی',
      [a.myIdentity, c.myIdentity],
      admins: [c.myIdentity],
    );
    await settle();
    check(
      'only the creator names admins',
      !a.group(gid)!.admins.contains(c.myIdentity) &&
          a.group(gid)!.admin == a.myIdentity,
    );

    final groupPic = picture(3);
    await b.setGroupAvatar(gid, groupPic);
    await settle();
    final atCarol = c.chatAvatar(g);
    check(
      'an admin sets the group picture for everyone',
      atCarol != null &&
          _eq(await c.files.read(atCarol), groupPic) &&
          a.chatAvatar(g) != null,
    );
    refused = false;
    try {
      await c.setGroupAvatar(gid, picture(4));
    } on StateError {
      refused = true;
    }
    check('a plain member cannot change the group picture', refused);

    await a.sendText(g, 'سلام گروه');
    await settle();
    b.markRead(g);
    c.markRead(g);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await settle();
    final inGroup = a.messages(g).lastWhere((m) => m.body == 'سلام گروه');
    check(
      'group message lists who read it',
      inGroup.readers.length == 2 && inGroup.status == MsgStatus.read,
      inGroup.readers,
    );

    // ---- reactions: only others, and who reacted ----
    /// Sends [wire] from [from] to every device of [to], as a modified app
    /// could.
    Future<void> forge(Messenger from, Messenger to, String wire) async {
      await from.api.post('/envelopes', {
        'client_msg_id': Messenger.newId(),
        'quiet': true,
        'envelopes': [
          for (final d in await from.devicesOf(to.myIdentity))
            await (() async {
              final e = await from.crypto.encrypt(
                '${to.myIdentity}',
                d,
                utf8Bytes(wire),
              );
              return {
                'to_device': d,
                'type': e.type,
                'body': base64Encode(e.body),
              };
            })(),
        ],
      });
    }

    await a.sendText(toBob, 'به این واکنش بده');
    await settle();
    final ownMsg = a.messages(toBob).last;
    check(
      'nobody can react to their own message',
      !(await a.react(ownMsg, '👍')),
    );
    await b.react(
      b.messages(toAlice).lastWhere((m) => m.body == 'به این واکنش بده'),
      '❤️',
    );
    await settle();
    check(
      'the author sees who reacted with what',
      a.messages(toBob).last.reactions['${b.myIdentity}'] == '❤️',
    );
    await forge(
      a,
      b,
      '{"v":1,"cv":4,"t":"react","target":"${ownMsg.clientMsgId}","emoji":"😂","ts":1}',
    );
    await settle();
    check(
      'a reaction to one\'s own message is ignored even if forged',
      !b
          .messages(toAlice)
          .lastWhere((m) => m.body == 'به این واکنش بده')
          .reactions
          .containsKey('${a.myIdentity}'),
    );

    // ---- polls ----
    ChatMessage lastPoll(Messenger who) =>
        who.messages(g).lastWhere((m) => m.kind == 'poll');
    await a.sendPoll(g, 'ناهار کجا؟', ['کافه', 'رستوران', 'خانه']);
    await settle();
    check(
      'a poll arrives with its question and options',
      lastPoll(b).body == 'ناهار کجا؟' &&
          lastPoll(c).poll?.options.length == 3 &&
          lastPoll(b).poll?.multi == false,
    );
    await b.vote(lastPoll(b), [1]);
    await c.vote(lastPoll(c), [1]);
    await settle();
    check(
      'everyone sees the same votes and who cast them',
      lastPoll(a).votes['${b.myIdentity}']?.single == 1 &&
          lastPoll(a).votes['${c.myIdentity}']?.single == 1 &&
          lastPoll(b).votes.length == 2 &&
          lastPoll(c).votes.length == 2,
      lastPoll(a).votes,
    );
    check(
      'a single-choice poll refuses two answers',
      !(await b.vote(lastPoll(b), [0, 2])),
    );
    await b.vote(lastPoll(b), [0]);
    await settle();
    check(
      'a vote can be changed',
      lastPoll(a).votes['${b.myIdentity}']?.single == 0 &&
          lastPoll(c).votes['${b.myIdentity}']?.single == 0,
    );
    await forge(
      b,
      c,
      '{"v":1,"cv":4,"t":"pollclose","target":"${lastPoll(b).clientMsgId}","ts":1}',
    );
    await settle();
    check(
      'only the author can close a poll',
      lastPoll(c).poll?.closed == false,
    );
    await a.closePoll(lastPoll(a));
    await settle();
    check(
      'after closing, nobody can vote',
      lastPoll(c).poll?.closed == true &&
          !(await c.vote(lastPoll(c), [2])) &&
          lastPoll(c).votes['${c.myIdentity}']?.single == 1,
    );
    await b.sendPoll(g, 'کدام روزها؟', ['شنبه', 'یکشنبه'], multi: true);
    await settle();
    await c.vote(lastPoll(c), [0, 1]);
    await settle();
    check(
      'a multiple-choice poll takes several answers',
      lastPoll(b).votes['${c.myIdentity}']?.length == 2,
    );

    // ---- BUZZ ----
    await a.sendBuzz(toBob);
    await settle();
    check(
      'a BUZZ arrives',
      b.messages(toAlice).where((m) => m.kind == 'buzz').length == 1 &&
          b.unread(toAlice) > 0,
    );
    check(
      'a second BUZZ within five minutes is refused',
      !(await a.sendBuzz(toBob)) && a.buzzWait(toBob) > 0,
    );
    a.db.kvPutInt('buzz:$toBob', 0); // as a modified app would
    await a.sendBuzz(toBob);
    await settle();
    check(
      'the receiver ignores BUZZes closer than five minutes apart',
      b.messages(toAlice).where((m) => m.kind == 'buzz').length == 1,
    );

    // ---- shared GIF collection ----
    final library = await c.gifLibrary();
    check('server lists its GIF collection', library.isNotEmpty);
    if (library.isNotEmpty) {
      final path = await c.gifFile(library.first);
      final bytes = await c.files.read(path);
      check(
        'a library item is downloaded and kept',
        bytes.length == library.first.size &&
            String.fromCharCodes(bytes.take(3)) == 'GIF' &&
            c.files.existsSync(path),
      );
      await c.sendLibraryGif(g, library.first);
      await settle();
      check(
        'a library GIF is delivered as a gif',
        a.messages(g).last.media?.kind == 'gif',
      );
    }
    var missing = false;
    try {
      await c.api.get('/gifs/pdoesnotexist00');
    } on ApiError catch (e) {
      missing = e.status == 404;
    }
    check('unknown library item is refused', missing);
  } catch (e, st) {
    check('no unexpected error', false, '$e\n$st');
  } finally {
    for (final m in all) {
      m.dispose();
      m.db.close();
    }
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
  stdout.writeln('\n$_passed passed, $_failed failed');
  exit(_failed == 0 ? 0 : 1);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
