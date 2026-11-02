import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'sql_signal_store.dart';

/// One ciphertext addressed to exactly one remote device.
class Envelope {
  Envelope(this.type, this.body);

  /// [CiphertextMessage.prekeyType] (3) or [CiphertextMessage.whisperType] (2).
  final int type;
  final Uint8List body;
}

/// The public key material another device needs to start a session with us.
/// Mirrors the JSON returned by `GET /keys/{identity}`.
class RemoteBundle {
  RemoteBundle.fromJson(Map<String, dynamic> j)
    : deviceId = j['device_id'] as int,
      registrationId = j['registration_id'] as int,
      identityKey = base64Decode(j['identity_key'] as String),
      signedPreKeyId = (j['signed_prekey'] as Map)['id'] as int,
      signedPreKey = base64Decode((j['signed_prekey'] as Map)['key']),
      signedPreKeySig = base64Decode((j['signed_prekey'] as Map)['sig']),
      preKeyId = (j['prekey'] as Map?)?['id'] as int?,
      preKey = j['prekey'] == null
          ? null
          : base64Decode((j['prekey'] as Map)['key'] as String);

  final int deviceId;
  final int registrationId;
  final Uint8List identityKey;
  final int signedPreKeyId;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySig;
  final int? preKeyId;
  final Uint8List? preKey;
}

/// Signal-protocol operations for one local device.
///
/// Wraps a maintained library; no cryptographic construction is defined here.
/// Callers wrap state-changing calls in [AppDb.tx] together with the message
/// rows they belong to.
class DeviceCrypto {
  DeviceCrypto(this.store);

  final SqlSignalStore store;

  static const int signedPreKeyId = 1;

  /// Generates identity, signed prekey and the first batch of one-time
  /// prekeys if this device has none yet. Returns the new prekey ids.
  Future<List<int>> provision({int preKeyCount = 50}) async {
    if (!store.initIdentity()) return [];
    final identity = await store.getIdentityKeyPair();
    await store.storeSignedPreKey(
      signedPreKeyId,
      generateSignedPreKey(identity, signedPreKeyId),
    );
    return addPreKeys(preKeyCount);
  }

  /// Generates [count] more one-time prekeys and returns their ids.
  Future<List<int>> addPreKeys(int count) async {
    final start = (store.db.kvInt('next_prekey_id') ?? 1);
    final keys = generatePreKeys(start, count);
    for (final pk in keys) {
      await store.storePreKey(pk.id, pk);
    }
    store.db.kvPutInt('next_prekey_id', start + count);
    return [for (final pk in keys) pk.id];
  }

  /// Public keys in the shape the server stores. Never contains private keys.
  Future<Map<String, dynamic>> publicBundle(List<int> preKeyIds) async {
    final identity = await store.getIdentityKeyPair();
    final spk = await store.loadSignedPreKey(signedPreKeyId);
    return {
      'registration_id': await store.getLocalRegistrationId(),
      'identity_key': base64Encode(identity.getPublicKey().serialize()),
      'signed_prekey': {
        'id': spk.id,
        'key': base64Encode(spk.getKeyPair().publicKey.serialize()),
        'sig': base64Encode(spk.signature),
      },
      'prekeys': await preKeyList(preKeyIds),
    };
  }

  Future<List<Map<String, dynamic>>> preKeyList(List<int> ids) async => [
    for (final id in ids)
      {
        'id': id,
        'key': base64Encode(
          (await store.loadPreKey(id)).getKeyPair().publicKey.serialize(),
        ),
      },
  ];

  Future<bool> hasSession(String peer, int deviceId) =>
      store.containsSession(SignalProtocolAddress(peer, deviceId));

  /// Starts a session from a bundle fetched from the server. Throws
  /// [UntrustedIdentityException] if the peer's identity key changed, and
  /// [InvalidKeyException] if the signed prekey signature does not verify.
  Future<void> startSession(String peer, RemoteBundle b) async {
    final address = SignalProtocolAddress(peer, b.deviceId);
    final bundle = PreKeyBundle(
      b.registrationId,
      b.deviceId,
      b.preKeyId,
      b.preKey == null ? null : Curve.decodePoint(b.preKey!, 0),
      b.signedPreKeyId,
      Curve.decodePoint(b.signedPreKey, 0),
      b.signedPreKeySig,
      IdentityKey.fromBytes(b.identityKey, 0),
    );
    await SessionBuilder.fromSignalStore(
      store,
      address,
    ).processPreKeyBundle(bundle);
  }

  Future<Envelope> encrypt(String peer, int deviceId, Uint8List plain) async {
    final cipher = SessionCipher.fromStore(
      store,
      SignalProtocolAddress(peer, deviceId),
    );
    final msg = await cipher.encrypt(plain);
    return Envelope(msg.getType(), msg.serialize());
  }

  Future<Uint8List> decrypt(String peer, int deviceId, Envelope e) async {
    final cipher = SessionCipher.fromStore(
      store,
      SignalProtocolAddress(peer, deviceId),
    );
    switch (e.type) {
      case CiphertextMessage.prekeyType:
        return cipher.decrypt(PreKeySignalMessage(e.body));
      case CiphertextMessage.whisperType:
        return cipher.decryptFromSignal(SignalMessage.fromSerialized(e.body));
      default:
        throw ArgumentError('Unknown envelope type ${e.type}');
    }
  }

  /// Hex of our public identity key, for out-of-band comparison by users.
  Future<String> identityFingerprint() async =>
      (await store.getIdentityKeyPair()).getPublicKey().getFingerprint();
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
