import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:test/test.dart';
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

/// What the server would return for [device]: public keys only, with a
/// single one-time prekey, after a JSON round trip.
Future<RemoteBundle> serverBundle(
  DeviceCrypto device,
  int deviceId, {
  int? preKeyId = 1,
}) async {
  final pub = await device.publicBundle(preKeyId == null ? [] : [preKeyId]);
  final wire =
      jsonDecode(
            jsonEncode({
              'device_id': deviceId,
              'registration_id': pub['registration_id'],
              'identity_key': pub['identity_key'],
              'signed_prekey': pub['signed_prekey'],
              'prekey': preKeyId == null
                  ? null
                  : (pub['prekeys'] as List).first,
            }),
          )
          as Map<String, dynamic>;
  return RemoteBundle.fromJson(wire);
}

void main() {
  late Directory dir;
  final open = <AppDb>[];

  Future<DeviceCrypto> device(String name, {bool fresh = true}) async {
    final db = openAppDbSync('${dir.path}/$name.db', keyHex: key);
    open.add(db);
    final d = DeviceCrypto(SqlSignalStore(db));
    if (fresh) await d.provision();
    return d;
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('irm_test_'));
  tearDown(() {
    for (final db in open) {
      db.close();
    }
    open.clear();
    dir.deleteSync(recursive: true);
  });

  test('database file is encrypted at rest', () async {
    final a = await device('alice');
    expect(a.store.db.cipherAvailable, isTrue);
    a.store.db.kvPutString('marker', 'PLAINTEXT-MARKER-12345');
    a.store.db.close();
    open.clear();
    final bytes = File('${dir.path}/alice.db').readAsBytesSync();
    expect(latin1.decode(bytes), isNot(contains('PLAINTEXT-MARKER-12345')));
    expect(latin1.decode(bytes.sublist(0, 16)), isNot(contains('SQLite')));
    expect(
      () => openAppDbSync(
        '${dir.path}/alice.db',
        keyHex: key.replaceFirst('00', 'ff'),
      ),
      throwsA(anything),
    );
  });

  test('offline first message, reply, and state surviving restarts', () async {
    var alice = await device('alice');
    var bob = await device('bob');

    await alice.startSession('bob', await serverBundle(bob, 20));
    final first = await alice.encrypt('bob', 20, utf8Bytes('سلام باب'));
    expect(first.type, CiphertextMessage.prekeyType);

    // Both processes restart before Bob comes online.
    for (final db in open) {
      db.close();
    }
    open.clear();
    alice = await device('alice', fresh: false);
    bob = await device('bob', fresh: false);

    expect(utf8.decode(await bob.decrypt('alice', 10, first)), 'سلام باب');
    expect(await bob.store.containsPreKey(1), isFalse);

    final reply = await bob.encrypt('alice', 10, utf8Bytes('سلام آلیس'));
    expect(utf8.decode(await alice.decrypt('bob', 20, reply)), 'سلام آلیس');

    final next = await alice.encrypt('bob', 20, utf8Bytes('پیام دوم'));
    expect(next.type, CiphertextMessage.whisperType);
    expect(utf8.decode(await bob.decrypt('alice', 10, next)), 'پیام دوم');
  });

  test('a rolled-back transaction leaves the ratchet untouched', () async {
    final alice = await device('alice');
    final bob = await device('bob');
    await alice.startSession('bob', await serverBundle(bob, 20));
    final m1 = await alice.encrypt('bob', 20, utf8Bytes('one'));

    // Simulate a crash after decrypting but before the message row commits.
    await expectLater(
      bob.store.db.tx(() async {
        await bob.decrypt('alice', 10, m1);
        throw StateError('crash');
      }),
      throwsStateError,
    );
    // The same envelope is redelivered and must still decrypt.
    expect(utf8.decode(await bob.decrypt('alice', 10, m1)), 'one');
  });

  test('out-of-order delivery decrypts; replay is rejected', () async {
    final alice = await device('alice');
    final bob = await device('bob');
    await alice.startSession('bob', await serverBundle(bob, 20));
    final m1 = await alice.encrypt('bob', 20, utf8Bytes('one'));
    final m2 = await alice.encrypt('bob', 20, utf8Bytes('two'));
    final m3 = await alice.encrypt('bob', 20, utf8Bytes('three'));
    expect(utf8.decode(await bob.decrypt('alice', 10, m3)), 'three');
    expect(utf8.decode(await bob.decrypt('alice', 10, m1)), 'one');
    expect(utf8.decode(await bob.decrypt('alice', 10, m2)), 'two');
    await expectLater(
      bob.decrypt('alice', 10, m2),
      throwsA(isA<DuplicateMessageException>()),
    );
  });

  test('tampered ciphertext is rejected', () async {
    final alice = await device('alice');
    final bob = await device('bob');
    await alice.startSession('bob', await serverBundle(bob, 20));
    final msg = await alice.encrypt('bob', 20, utf8Bytes('pay 10'));
    final bad = Uint8List.fromList(msg.body);
    bad[bad.length - 12] ^= 0x01;
    await expectLater(
      bob.decrypt('alice', 10, Envelope(msg.type, bad)),
      throwsA(isA<Exception>()),
    );
  });

  test('server swapping the identity key is detected', () async {
    final alice = await device('alice');
    final bob = await device('bob');
    final mallory = await device('mallory');
    await alice.startSession('bob', await serverBundle(bob, 20));
    await expectLater(
      alice.startSession('bob', await serverBundle(mallory, 20)),
      throwsA(isA<UntrustedIdentityException>()),
    );
  });

  test('forged signed prekey is rejected', () async {
    final alice = await device('alice');
    final bob = await device('bob');
    final mallory = await device('mallory');
    final real = await bob.publicBundle([1]);
    final fake = await mallory.publicBundle([1]);
    final forged = RemoteBundle.fromJson({
      'device_id': 20,
      'registration_id': real['registration_id'],
      'identity_key': real['identity_key'],
      'signed_prekey': fake['signed_prekey'],
      'prekey': (fake['prekeys'] as List).first,
    });
    await expectLater(
      alice.startSession('bob', forged),
      throwsA(isA<InvalidKeyException>()),
    );
  });
}
