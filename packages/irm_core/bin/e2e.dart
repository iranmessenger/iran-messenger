// End-to-end check of plugin + client core with three simulated devices.
// Intended for a local development server only: it registers accounts.
//
//   dart run bin/e2e.dart <site-url> <token-A> <token-B> <token-C>
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

/// Simulates a network where the server (port 8089) cannot be reached
/// directly; optionally also corrupts whatever the relay returns.
class FilteredClient extends http.BaseClient {
  FilteredClient({this.tamper = false});
  final bool tamper;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.port == 8089) {
      throw const SocketException('direct route blocked (simulated)');
    }
    final res = await _inner.send(request);
    if (!tamper) return res;
    final body = await res.stream.toBytes();
    // A dishonest relay rewrites the answer but keeps the signature header.
    final forged = String.fromCharCodes(body)
        .replaceFirst('"envelopes":[', '"envelopes":[ ')
        .replaceFirst('"duplicate":false', '"duplicate":true ')
        .replaceFirst('{', '{ ');
    return http.StreamedResponse(
      Stream.value(forged.codeUnits),
      res.statusCode,
      headers: res.headers,
    );
  }
}

final mobiles = <String, String>{};

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [Object? detail]) {
  ok ? _passed++ : _failed++;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $name${detail == null || ok ? '' : '  -> $detail'}',
  );
}

final passwords = <String, String>{};

final keys = <String, String>{};

Messenger fresh(String file, Directory dir, Random r) {
  final key = List.generate(64, (_) => r.nextInt(16).toRadixString(16)).join();
  keys[file] = key;
  return Messenger(
    openAppDbSync('${dir.path}/$file.db', keyHex: key),
    IoFileStore(Directory('${dir.path}/files_$file')),
    wafLog: fileWafSink(File('waf_evidence.jsonl')),
  );
}

Future<Messenger> member(
  String site,
  String code,
  String name,
  Directory dir,
  Random r,
) async {
  final m = fresh(name, dir, r);
  final tag = r.nextInt(900000) + 100000;
  mobiles[name] = '0900$tag${r.nextInt(9)}';
  passwords[name] = Messenger.newId();
  await m.register(
    site: site,
    username: '$name$tag',
    password: passwords[name]!,
    inviteCode: code,
  );
  await m.updateProfile(displayName: name, mobile: mobiles[name]);
  return m;
}

Future<void> main(List<String> args) async {
  if (args.length != 6) {
    stderr.writeln(
      'usage: e2e.dart <site-url> <code-A> <code-B> <code-C> <setup.php> <wp-root>',
    );
    exit(64);
  }
  final r = Random.secure();
  final dir = Directory.systemTemp.createTempSync('irm_e2e_');
  final all = <Messenger>[];
  try {
    final a = await member(args[0], args[1], 'alice', dir, r);
    final b = await member(args[0], args[2], 'bob', dir, r);
    final c = await member(args[0], args[3], 'carol', dir, r);
    all.addAll([a, b, c]);
    check(
      'invite code activates the account at once',
      !a.isPending && a.myName == 'alice',
    );

    // ---- registration without a code waits for the administrator ----
    final d = fresh('dave', dir, r);
    all.add(d);
    final daveName = 'dave${r.nextInt(900000) + 100000}';
    await d.register(
      site: args[0],
      username: daveName,
      password: 'dave-password-1',
    );
    check('no code: account is pending', d.isRegistered && d.isPending);
    check(
      'pending account cannot sync',
      await d.syncOnce() == false && d.isPending,
    );
    var blocked = false;
    try {
      await d.api.get('/sync');
    } on ApiError catch (e) {
      blocked = e.code == 'irm_pending';
    }
    check('server refuses a pending device', blocked);
    check(
      'pending account is not discoverable',
      await c.lookupUsername(daveName) == null,
    );
    final approve = await Process.run('php', [
      args[4],
      args[5],
      '0',
      '--approve=$daveName',
    ]);
    check('admin approves', approve.exitCode == 0, approve.stderr);
    await d.syncOnce();
    check('approved account becomes active', !d.isPending);
    check(
      'approved account is discoverable',
      (await c.lookupUsername(daveName))?.identityId == d.myIdentity,
    );
    var taken = false;
    try {
      await fresh(
        'dup',
        dir,
        r,
      ).register(site: args[0], username: daveName, password: 'whatever-123');
    } on ApiError catch (e) {
      taken = e.code == 'irm_username_taken';
    }
    check('duplicate username is refused', taken);

    // ---- discovery: there is no member directory ----
    check('nobody is visible at first', a.contacts().isEmpty);
    var noDirectory = false;
    try {
      await a.api.get('/directory');
    } on ApiError catch (e) {
      noDirectory = e.status == 404;
    }
    check('directory endpoint is gone', noDirectory);
    // Phone numbers are dropped by the server, so the address book never
    // finds anyone, not even bob, who sent his number at registration.
    final bobLocal = mobiles['bob']!;
    final found = await a.matchContacts([
      '+98 ${bobLocal.substring(1, 4)} ${bobLocal.substring(4)}',
      '09120000000',
    ]);
    check(
      'address-book match finds nobody (no numbers stored)',
      found == 0 && a.contacts().isEmpty,
    );
    final viaBob = await a.lookupUsername('@${b.myUsername}');
    check(
      'exact username lookup finds bob',
      viaBob?.identityId == b.myIdentity &&
          a.contacts().single.displayName == 'bob',
    );
    final viaName = await a.lookupUsername('@${c.myUsername}');
    check(
      'exact username lookup finds carol',
      viaName?.identityId == c.myIdentity,
    );
    check(
      'unknown username finds nobody',
      await a.lookupUsername('nosuchuser') == null,
    );
    check('bob still sees nobody', b.contacts().isEmpty);

    // ---- direct text ----
    final toBob = 'u:${b.myIdentity}';
    final toAlice = 'u:${a.myIdentity}';
    await a.sendText(toBob, 'سلام باب');
    await a.syncOnce();
    check(
      'alice: message accepted by server',
      a.messages(toBob).single.status == MsgStatus.sent,
    );
    await b.syncOnce();
    check(
      'bob: received and decrypted',
      b.messages(toAlice).single.body == 'سلام باب',
    );
    check(
      'bob: learns the sender name from the message itself',
      b.nameOf(a.myIdentity) == 'alice' &&
          b.contact(a.myIdentity)?.username == a.myUsername,
    );
    check('bob: one unread', b.unread(toAlice) == 1);
    b.markRead(toAlice);
    check('bob: read clears the badge', b.unread(toAlice) == 0);
    check(
      'mention detection',
      b.mentionsMe('سلام @${b.myUsername} خوبی؟') &&
          !b.mentionsMe('mail@${b.myUsername}x') &&
          !b.mentionsMe('@${a.myUsername}'),
    );
    await b.syncOnce();
    check('bob: no duplicate on second sync', b.messages(toAlice).length == 1);
    await a.syncOnce();
    check(
      'alice: delivery receipt applied',
      // Bob has also read it, which may already have been reported.
      const {
        MsgStatus.delivered,
        MsgStatus.read,
      }.contains(a.messages(toBob).single.status),
    );

    await b.sendText(toAlice, 'سلام آلیس');
    await b.syncOnce();
    await a.syncOnce();
    check(
      'alice: reply arrives in same chat',
      a.messages(toBob).last.body == 'سلام آلیس',
    );

    final codeA = await a.safetyNumber(b.myIdentity);
    final codeB = await b.safetyNumber(a.myIdentity);
    check(
      'safety numbers match on both sides',
      codeA.isNotEmpty && codeA == codeB,
      '$codeA vs $codeB',
    );

    // ---- reply, reaction, edit, typing ----
    final firstAtBob = b
        .messages(toAlice)
        .firstWhere((m) => m.body == 'سلام باب');
    await b.sendText(toAlice, 'جواب', replyTo: firstAtBob);
    await b.syncOnce();
    await a.syncOnce();
    final quoted = a.messages(toBob).last;
    final original = a.messages(toBob).firstWhere((m) => m.body == 'سلام باب');
    check(
      'reply carries the quoted text and author',
      quoted.body == 'جواب' &&
          quoted.reply?.preview == 'سلام باب' &&
          quoted.reply?.sender == a.myIdentity,
    );
    check(
      'reply points at the original message',
      quoted.reply?.id == original.clientMsgId,
    );

    final before = a.messages(toBob).length;
    check('reaction is accepted', await a.react(quoted, '👍'));
    await a.syncOnce();
    await b.syncOnce();
    check(
      'bob sees the reaction on his message',
      b.messages(toAlice).last.reactions['${a.myIdentity}'] == '👍',
    );
    check(
      'reaction adds no visible message',
      a.messages(toBob).length == before &&
          b.messages(toAlice).every((m) => m.kind != 'control'),
    );
    await a.react(a.messages(toBob).last, '👍');
    await a.syncOnce();
    await b.syncOnce();
    check(
      'same emoji again removes the reaction',
      b.messages(toAlice).last.reactions.isEmpty,
    );

    check(
      'edit of own message is accepted',
      await b.editMessage(b.messages(toAlice).last, 'جواب اصلاح‌شده'),
    );
    await b.syncOnce();
    await a.syncOnce();
    check(
      'alice sees the edited text, marked as edited',
      a.messages(toBob).last.body == 'جواب اصلاح‌شده' &&
          a.messages(toBob).last.edited,
    );
    check(
      "someone else's message cannot be edited",
      await a.editMessage(a.messages(toBob).last, 'جعل') == false,
    );

    final rowsBefore = b.messages(toAlice).length;
    await a.sendTyping(toBob);
    final gotVisible = await b.syncOnce();
    check('typing indicator arrives', b.typingIn(toAlice) == 'alice');
    check(
      'typing is not a message',
      !gotVisible && b.messages(toAlice).length == rowsBefore,
    );

    // ---- group ----
    final gid = await a.createGroup('دوستان', [b.myIdentity, c.myIdentity]);
    final g = 'g:$gid';
    await a.sendText(g, 'سلام به همه');
    await a.syncOnce();
    await b.syncOnce();
    await c.syncOnce();
    check(
      'bob: joined group with 3 members',
      b.group(gid)?.members.length == 3 && b.group(gid)?.title == 'دوستان',
    );
    check(
      'carol: learns bob from the group without any lookup',
      c.nameOf(b.myIdentity) == 'bob' &&
          c.contact(b.myIdentity)?.username == b.myUsername,
    );
    check(
      'carol: got group text',
      c.messages(g).any((m) => m.body == 'سلام به همه'),
    );
    await c.sendText(g, 'سلام از کارول');
    await c.syncOnce();
    await a.syncOnce();
    await b.syncOnce();
    check(
      'bob: sees carol in group',
      b
          .messages(g)
          .any((m) => m.body == 'سلام از کارول' && m.sender == c.myIdentity),
    );

    // Non-admin cannot change the group.
    var refused = false;
    try {
      await b.updateGroup(gid, 'هک', [b.myIdentity]);
    } on StateError {
      refused = true;
    }
    check('non-admin cannot edit group', refused);

    // Admin removes carol; she stops receiving and her sends are dropped.
    await a.updateGroup(gid, 'دوستان', [b.myIdentity]);
    await a.syncOnce();
    await b.syncOnce();
    await c.syncOnce();
    check('carol: marked as removed', c.group(gid)?.left == true);
    await a.sendText(g, 'بعد از حذف');
    await a.syncOnce();
    await b.syncOnce();
    await c.syncOnce();
    check(
      'bob: gets post-removal message',
      b.messages(g).any((m) => m.body == 'بعد از حذف'),
    );
    check(
      'carol: does not get post-removal message',
      !c.messages(g).any((m) => m.body == 'بعد از حذف'),
    );

    // ---- reinstall: log in again with username and password ----
    var wrong = false;
    try {
      await fresh('thief', dir, r).login(
        site: args[0],
        username: b.myUsername!,
        password: 'not-the-password',
      );
    } on ApiError catch (e) {
      wrong = e.code == 'irm_bad_login';
    }
    check('wrong password is refused', wrong);
    final b2 = fresh('bob2', dir, r);
    all.add(b2);
    await b2.login(
      site: args[0],
      username: b.myUsername!,
      password: passwords['bob']!,
    );
    check(
      'login returns the same account',
      b2.myIdentity == b.myIdentity && b2.myName == 'bob' && !b2.isPending,
    );
    var oldRefused = false;
    try {
      await b.api.get('/sync');
    } on ApiError catch (e) {
      oldRefused = e.status == 401;
    }
    check('old device is signed out', oldRefused);
    await a.sendText(toBob, 'بعد از نصب دوباره');
    await a.syncOnce();
    check(
      'alice: message reaches the new device after a silent retry',
      a.messages(toBob).last.status == MsgStatus.sent ||
          a
              .messages(toBob)
              .any(
                (m) =>
                    m.body == 'بعد از نصب دوباره' && m.status == MsgStatus.sent,
              ),
    );
    check(
      'alice: is told that bob changed device',
      a
          .messages(toBob)
          .any((m) => m.kind == 'system' && m.body.contains('عوض شده')),
    );
    await b2.syncOnce();
    check(
      'bob (new device): receives and decrypts',
      b2.messages(toAlice).any((m) => m.body == 'بعد از نصب دوباره'),
    );
    await b2.sendText(toAlice, 'برگشتم');
    await b2.syncOnce();
    await a.syncOnce();
    check(
      'alice: gets the reply from the new device',
      a.messages(toBob).any((m) => m.body == 'برگشتم' && !m.outgoing),
    );

    // ---- media ----
    final bytes = Uint8List.fromList(
      List.generate(1300 * 1024, (_) => r.nextInt(256)),
    ); // 3 chunks
    await a.sendMedia(
      toBob,
      bytes,
      name: 'photo.bin',
      kind: 'image',
      mime: 'image/jpeg',
      caption: 'عکس',
    );
    await a.syncOnce();
    final sentMedia = a.messages(toBob).last;
    check(
      'alice: media uploaded and sent',
      sentMedia.status == MsgStatus.sent && sentMedia.media?.serverId != null,
      sentMedia.error,
    );
    await b2.syncOnce();
    final got = b2.messages(toAlice).last;
    check(
      'bob: media message with caption',
      got.kind == 'media' && got.body == 'عکس' && got.media?.path == null,
    );
    final file = await b2.media.download(got.id);
    final same = file != null && _eq(await b2.files.read(file), bytes);
    check('bob: downloaded file is byte-identical', same);
    var denied = false;
    try {
      await c.api.get('/media/${got.media!.serverId}', query: {'offset': '0'});
    } on ApiError catch (e) {
      denied = e.status == 404;
    }
    check('carol: cannot fetch media not addressed to her', denied);
    var gone = false;
    try {
      await b2.api.get('/media/${got.media!.serverId}', query: {'offset': '0'});
    } on ApiError catch (e) {
      gone = e.status == 404;
    }
    check('server deleted media after last recipient fetched it', gone);

    // ---- the sender takes a file back before it was fetched ----
    await a.sendMedia(
      toBob,
      Uint8List.fromList(List.generate(300 * 1024, (_) => r.nextInt(256))),
      name: 'oops.pdf',
      kind: 'file',
      mime: 'application/pdf',
    );
    await a.syncOnce();
    final oops = a.messages(toBob).last;
    await b2.syncOnce();
    final oopsAtBob = b2.messages('u:${a.myIdentity}').last;
    await a.deleteForEveryone(oops);
    await a.syncOnce();
    var takenBack = false;
    try {
      await b2.api.get(
        '/media/${oopsAtBob.media!.serverId}',
        query: {'offset': '0'},
      );
    } on ApiError catch (e) {
      takenBack = e.status == 404;
    }
    check('deleting for everyone removes the file from the server', takenBack);

    // ---- the same GIF sameGif is taken from the phone, not the server ----
    final sameGif = Uint8List.fromList(
      List.generate(90 * 1024, (_) => r.nextInt(256)),
    );
    await a.sendMedia(
      toBob,
      sameGif,
      name: 'loop.gif',
      kind: 'gif',
      mime: 'image/gif',
    );
    await a.syncOnce();
    await b2.syncOnce();
    final firstGif = b2.messages('u:${a.myIdentity}').last;
    await b2.media.download(firstGif.id);
    await a.sendMedia(
      toBob,
      sameGif,
      name: 'loop.gif',
      kind: 'gif',
      mime: 'image/gif',
    );
    await a.syncOnce();
    await b2.syncOnce();
    final secondGif = b2.messages('u:${a.myIdentity}').last;
    // Remove the second copy from the server: only the cache can serve it.
    await a.api.post(
      '/media/${a.messages(toBob).last.media!.serverId}/delete',
      {},
    );
    final cached = await b2.media.download(secondGif.id);
    check(
      'a GIF received before is reused without downloading',
      cached != null &&
          secondGif.id != firstGif.id &&
          (await b2.files.read(cached)).length == sameGif.length,
    );

    // ---- a bot posts but receives nothing anyone writes ----
    final makeBot = await Process.run('php', [
      args[4],
      args[5],
      '0',
      '--bot=$daveName',
    ]);
    check(
      'admin marks an account as a bot',
      makeBot.exitCode == 0,
      makeBot.stderr,
    );
    await a.refreshConfig();
    await b2.refreshConfig();
    check('members learn which accounts are bots', a.isBot(d.myIdentity));
    d.botMode = true;
    final news = await a.createGroup('اخبار', [b2.myIdentity, d.myIdentity]);
    await a.syncOnce();
    await d.syncOnce();
    check('a bot learns the groups it is added to', d.group(news) != null);
    await a.sendText('g:$news', 'not for the bot');
    await a.react(a.messages('g:$news').last, '👍');
    await a.syncOnce();
    final toBot = await d.api.get('/sync') as Map;
    check(
      'nothing members write is encrypted for the bot',
      (toBot['envelopes'] as List).isEmpty,
      toBot['envelopes'],
    );
    await d.sendText('g:$news', 'خبر تازه');
    await d.syncOnce();
    await b2.syncOnce();
    check(
      'the bot posts to the group',
      b2
          .messages('g:$news')
          .any((m) => m.body == 'خبر تازه' && m.sender == d.myIdentity),
    );
    b2.markRead('g:$news');
    await b2.syncOnce();
    await d.syncOnce();
    check(
      'read receipts are not sent to the bot',
      d.messages('g:$news').every((m) => m.readers.isEmpty),
    );

    // ---- saved GIFs ----
    final gif = Uint8List.fromList(List.generate(4000, (_) => r.nextInt(256)));
    check(
      'gif is saved to the collection',
      await a.addFavorite(gif, name: 'fun.gif', kind: 'gif', mime: 'image/gif'),
    );
    check(
      'the same gif is not saved twice',
      await a.addFavorite(
                gif,
                name: 'fun.gif',
                kind: 'gif',
                mime: 'image/gif',
              ) ==
              false &&
          a.favorites('gif').length == 1 &&
          a.favorites('sticker').isEmpty,
    );
    await a.sendFavorite(toBob, a.favorites('gif').single);
    await a.syncOnce();
    await b2.syncOnce();
    final gotGif = b2.messages(toAlice).last;
    check('saved gif is delivered as a gif', gotGif.media?.kind == 'gif');
    await b2.media.download(gotGif.id);
    check(
      'recipient can keep a received gif',
      await b2.addFavoriteFromMessage(b2.messages(toAlice).last) &&
          b2.favorites('gif').length == 1,
    );
    a.removeFavorite(a.favorites('gif').single.id);
    check('removing empties the collection', a.favorites('gif').isEmpty);

    // ---- signed answers and the private relay ----
    final keyBefore = a.db.kvString('server_key');
    check(
      'server key is pinned at registration',
      (keyBefore ?? '').length > 40,
    );
    await a.refreshConfig();
    check(
      'relay list arrives in the signed config',
      a.db.kvString('relays')!.contains('8090') && a.routeLabel == 'direct',
    );

    final plain = await http.get(Uri.parse('http://localhost:8090/wp-json/'));
    check(
      'relay is not advertised in the site index',
      !plain.body.contains('pr/v1'),
    );
    final noKey = await http.get(
      Uri.parse('http://localhost:8090/wp-json/pr/v1/f/sync'),
    );
    check('relay answers 404 without the access key', noKey.statusCode == 404);

    // Alice's network now blocks the server; only the relay is reachable.
    final aliceId = a.myIdentity;
    a.dispose();
    a.db.close();
    all.remove(a);
    final viaRelay = Messenger(
      openAppDbSync('${dir.path}/alice.db', keyHex: keys['alice']!),
      IoFileStore(Directory('${dir.path}/files_alice')),
      httpClient: FilteredClient(),
    );
    all.add(viaRelay);
    await viaRelay.sendText(toBob, 'از راه رله');
    await viaRelay.syncOnce();
    check(
      'message goes out through the relay',
      viaRelay.routeLabel == 'localhost' &&
          viaRelay.messages(toBob).last.status == MsgStatus.sent,
      viaRelay.messages(toBob).last.error,
    );
    await b2.syncOnce();
    check(
      'recipient receives the relayed message',
      b2.messages(toAlice).any((m) => m.body == 'از راه رله'),
    );
    await b2.sendText(toAlice, 'رسید');
    await b2.syncOnce();
    await viaRelay.syncOnce();
    check(
      'replies come back through the relay',
      viaRelay.messages(toBob).any((m) => m.body == 'رسید' && !m.outgoing),
    );

    // A dishonest relay alters answers: nothing it says is believed.
    viaRelay.dispose();
    viaRelay.db.close();
    all.remove(viaRelay);
    final viaLiar = Messenger(
      openAppDbSync('${dir.path}/alice.db', keyHex: keys['alice']!),
      IoFileStore(Directory('${dir.path}/files_alice')),
      httpClient: FilteredClient(tamper: true),
    );
    all.add(viaLiar);
    await viaLiar.sendText(toBob, 'از رله دروغگو');
    Object? seen;
    try {
      await viaLiar.syncOnce();
    } catch (e) {
      seen = e;
    }
    check('altered answers are rejected', seen is UntrustedResponse, seen);
    check(
      'a forged "accepted" is not believed',
      viaLiar.messages(toBob).last.status == MsgStatus.pending &&
          viaLiar.myIdentity == aliceId,
    );

    // ---- change password, then backup and restore on a new install ----
    var refusedChange = false;
    try {
      await b2.changePassword('not-the-password', 'new-password-123');
    } on ApiError catch (e) {
      refusedChange = e.code == 'irm_bad_login';
    }
    check('password change needs the current password', refusedChange);
    await b2.changePassword(passwords['bob']!, 'new-password-123');

    final watch = Stopwatch()..start();
    final backupFile = await Backup.export(b2, 'backup pass phrase');
    check(
      'backup is produced (${watch.elapsedMilliseconds} ms to seal)',
      backupFile.length > 200,
    );
    check(
      'backup backupFile shows no message text',
      !String.fromCharCodes(backupFile).contains('سلام') &&
          !latin1.decode(backupFile).contains('alice'),
    );
    final historyBefore = b2.messages(toAlice).length;
    final groupsBefore = b2.chats().where((c) => c.isGroup).length;

    var oldPassword = false;
    try {
      await fresh('bob-old-pass', dir, r).login(
        site: args[0],
        username: b.myUsername!,
        password: passwords['bob']!,
      );
    } on ApiError catch (e) {
      oldPassword = e.code == 'irm_bad_login';
    }
    check('old password no longer signs in', oldPassword);

    final b3 = fresh('bob3', dir, r);
    all.add(b3);
    await b3.login(
      site: args[0],
      username: b.myUsername!,
      password: 'new-password-123',
    );
    check('new install starts empty', b3.messages(toAlice).isEmpty);

    Object? wrongPass;
    try {
      await Backup.restore(b3, backupFile, 'wrong phrase 123');
    } catch (e) {
      wrongPass = e;
    }
    check(
      'wrong passphrase is refused',
      wrongPass is BackupError && wrongPass.code == 'wrong_passphrase',
      wrongPass,
    );
    Object? otherAccount;
    try {
      await Backup.restore(c, backupFile, 'backup pass phrase');
    } catch (e) {
      otherAccount = e;
    }
    check(
      "another account cannot restore someone's backup",
      otherAccount is BackupError && otherAccount.code == 'other_account',
    );
    final tampered = Uint8List.fromList(backupFile)
      ..[backupFile.length - 40] ^= 1;
    Object? corrupt;
    try {
      await Backup.restore(b3, tampered, 'backup pass phrase');
    } catch (e) {
      corrupt = e;
    }
    check('a modified backup is refused', corrupt is BackupError);

    final summary = await Backup.restore(b3, backupFile, 'backup pass phrase');
    check(
      'history is restored',
      summary.messages > 0 &&
          b3.messages(toAlice).length == historyBefore &&
          b3.messages(toAlice).any((m) => m.body == 'بعد از نصب دوباره') &&
          b3.messages(toAlice).any((m) => m.body == 'برگشتم' && m.outgoing),
      '${summary.messages} added, ${b3.messages(toAlice).length} vs $historyBefore',
    );
    check(
      'contact names are restored',
      b3.chats().where((c) => c.isGroup).length == groupsBefore &&
          b3.nameOf(viaLiar.myIdentity) == 'alice',
    );

    // Carol still has the group on her device: it must survive a restore.
    final carolFile = await Backup.export(c, 'carol backup phrase');
    final carolName = c.myUsername!;
    final c2 = fresh('carol2', dir, r);
    all.add(c2);
    await c2.login(
      site: args[0],
      username: carolName,
      password: passwords['carol']!,
    );
    await Backup.restore(c2, carolFile, 'carol backup phrase');
    check(
      'groups and their messages are restored',
      c2.group(gid)?.title == 'دوستان' &&
          c2.messages(g).any((m) => m.body == 'سلام به همه') &&
          c2.messages(g).any((m) => m.body == 'سلام از کارول' && m.outgoing),
    );
    check('restored history is not shown as unread', b3.unread(toAlice) == 0);
    final again = await Backup.restore(b3, backupFile, 'backup pass phrase');
    check('restoring twice adds nothing', again.messages == 0);
    await b3.sendText(toAlice, 'بعد از بازیابی');
    await b3.syncOnce();
    check(
      'new message sorts after restored history',
      b3.messages(toAlice).last.body == 'بعد از بازیابی',
    );

    // ---- wake-up alerts for browsers ----
    await c2.refreshConfig();
    final vapid = c2.vapidKey;
    check(
      'server offers a key for browser alerts',
      vapid != null &&
          base64Url
                  .decode(vapid.padRight((vapid.length + 3) & ~3, '='))
                  .length ==
              65,
    );
    String b64u(List<int> v) => base64Url.encode(v).replaceAll('=', '');
    final point = b64u([4, ...List.generate(64, (_) => r.nextInt(256))]);
    final secret = b64u(List.generate(16, (_) => r.nextInt(256)));
    Future<String> pushAnswer(String endpoint, String key, String auth) async {
      try {
        await c2.pushSubscribe(endpoint, key, auth);
        return 'accepted';
      } on ApiError catch (e) {
        return e.code;
      }
    }

    check(
      'alerts can only be sent to a real push service',
      await pushAnswer('https://evil.example/push', point, secret) ==
              'irm_bad_endpoint' &&
          await pushAnswer('http://web.push.apple.com/x', point, secret) ==
              'irm_bad_endpoint' &&
          await pushAnswer(
                'https://web.push.apple.com.evil.example/x',
                point,
                secret,
              ) ==
              'irm_bad_endpoint' &&
          await pushAnswer('https://localhost/x', point, secret) ==
              'irm_bad_endpoint',
    );
    check(
      'malformed subscription keys are refused',
      await pushAnswer('https://web.push.apple.com/x', secret, secret) ==
          'irm_bad_subscription',
    );
    check(
      'a browser subscription is stored and can be withdrawn',
      await pushAnswer('https://web.push.apple.com/test-only', point, secret) ==
          'accepted',
    );
    await c2.pushIdle();
    await c2.pushUnsubscribe();
  } on WafBlock catch (e) {
    _failed++;
    stdout.writeln('BLOCKED in front of WordPress: $e');
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

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
