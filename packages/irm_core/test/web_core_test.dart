// The browser build of the core: SQLite as WebAssembly, attachments in
// IndexedDB, and the protocol libraries under 53-bit JavaScript integers.
//
//   copy app/web/sqlite3mc.wasm to test/, then
//   dart test -p chrome test/web_core_test.dart
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:test/test.dart';
import 'package:irm_core/irm_core.dart';

const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

Future<RemoteBundle> serverBundle(DeviceCrypto device, int deviceId) async {
  final pub = await device.publicBundle([1]);
  return RemoteBundle.fromJson(
    jsonDecode(
          jsonEncode({
            'device_id': deviceId,
            'registration_id': pub['registration_id'],
            'identity_key': pub['identity_key'],
            'signed_prekey': pub['signed_prekey'],
            'prekey': (pub['prekeys'] as List).first,
          }),
        )
        as Map<String, dynamic>,
  );
}

void main() {
  final run = DateTime.now().microsecondsSinceEpoch;

  test('encrypted database keeps its data and refuses a wrong key', () async {
    var db = await openAppDb('a$run.db', keyHex: key);
    expect(db.cipherAvailable, isTrue);
    await db.tx(() async => db.kvPutString('marker', 'سلام'));
    db.close();
    db = await openAppDb('a$run.db', keyHex: key);
    expect(db.kvString('marker'), 'سلام');
    db.close();
    await expectLater(
      openAppDb('a$run.db', keyHex: key.replaceFirst('00', 'ff')),
      throwsA(anything),
    );
  });

  test('signal sessions stored in the database', () async {
    final aliceDb = await openAppDb('alice$run.db', keyHex: key);
    final bobDb = await openAppDb('bob$run.db', keyHex: key);
    final alice = DeviceCrypto(SqlSignalStore(aliceDb));
    final bob = DeviceCrypto(SqlSignalStore(bobDb));
    await alice.provision();
    await bob.provision();

    await alice.startSession('bob', await serverBundle(bob, 20));
    final first = await alice.encrypt('bob', 20, utf8Bytes('سلام باب'));
    expect(first.type, CiphertextMessage.prekeyType);
    expect(utf8.decode(await bob.decrypt('alice', 10, first)), 'سلام باب');
    for (var i = 0; i < 4; i++) {
      final back = await bob.encrypt('alice', 10, utf8Bytes('پاسخ $i'));
      expect(utf8.decode(await alice.decrypt('bob', 20, back)), 'پاسخ $i');
      final again = await alice.encrypt('bob', 20, utf8Bytes('دوباره $i'));
      expect(utf8.decode(await bob.decrypt('alice', 10, again)), 'دوباره $i');
    }
  });

  test('attachments in IndexedDB', () async {
    var files = await openFileStore('files$run');
    final path = files.newPath('media', 'x_photo.jpg');
    expect(files.existsSync(path), isFalse);
    final data = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    await files.write(path, data);
    expect(files.existsSync(path), isTrue);
    files = await openFileStore('files$run');
    expect(files.existsSync(path), isTrue);
    expect(await files.read(path), data);
    await files.delete(path);
    expect(files.existsSync(path), isFalse);
  });

  test(
    'request signing key and backup key derivation match the phone',
    () async {
      final ed = Ed25519();
      final pair = await ed.newKeyPairFromSeed(
        List<int>.generate(32, (i) => i),
      );
      expect(
        base64Encode((await pair.extractPublicKey()).bytes),
        'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
      );
      final derived =
          await Argon2id(
            parallelism: 1,
            memory: 19456,
            iterations: 2,
            hashLength: 32,
          ).deriveKey(
            secretKey: SecretKey(utf8.encode('correct horse')),
            nonce: List<int>.generate(16, (i) => i),
          );
      expect(
        (await derived.extractBytes())
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'd00b90c40f918cf889780d7d3a9ec3c2b1719df87dc5e4d4d93ea6163db04e17',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
