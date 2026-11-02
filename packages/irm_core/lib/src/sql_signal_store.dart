import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'app_db.dart';

/// Signal protocol state kept in [AppDb]. Every write happens on the same
/// connection as message storage, so one [AppDb.tx] covers both and a crash
/// can never leave a ratchet step without its message (or the reverse).
class SqlSignalStore extends SignalProtocolStore {
  SqlSignalStore(this.db);

  final AppDb db;

  /// Creates the local identity once. Returns false if it already existed.
  bool initIdentity() {
    if (db.kvBytes('identity') != null) return false;
    db.kvPutBytes('identity', generateIdentityKeyPair().serialize());
    db.kvPutInt('registration_id', generateRegistrationId(false));
    return true;
  }

  // ---- identity ----
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async =>
      IdentityKeyPair.fromSerialized(db.kvBytes('identity')!);

  @override
  Future<int> getLocalRegistrationId() async => db.kvInt('registration_id')!;

  Uint8List? _peerKey(SignalProtocolAddress a) {
    final rows = db.raw.select(
      'SELECT key FROM peer_identities WHERE name = ? AND device = ?',
      [a.getName(), a.getDeviceId()],
    );
    return rows.isEmpty ? null : rows.first['key'] as Uint8List;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final k = _peerKey(address);
    return k == null ? null : IdentityKey.fromBytes(k, 0);
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final previous = _peerKey(address);
    final bytes = identityKey.serialize();
    if (previous != null && _eq(previous, bytes)) return false;
    db.raw.execute(
      'INSERT INTO peer_identities (name, device, key) VALUES (?, ?, ?) '
      'ON CONFLICT(name, device) DO UPDATE SET key = excluded.key',
      [address.getName(), address.getDeviceId(), bytes],
    );
    return previous != null;
  }

  /// Trust on first use. A changed key is refused until the user approves
  /// it, which calls [forgetIdentity].
  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    final known = _peerKey(address);
    if (known == null) return true;
    return identityKey != null && _eq(known, identityKey.serialize());
  }

  void forgetIdentity(String name) {
    db.raw.execute('DELETE FROM peer_identities WHERE name = ?', [name]);
    db.raw.execute('DELETE FROM sessions WHERE name = ?', [name]);
  }

  /// Known identity keys of a peer's devices, for the verification screen.
  Map<int, Uint8List> peerKeys(String name) => {
    for (final r in db.raw.select(
      'SELECT device, key FROM peer_identities WHERE name = ? ORDER BY device',
      [name],
    ))
      r['device'] as int: r['key'] as Uint8List,
  };

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ---- one-time prekeys ----
  @override
  Future<bool> containsPreKey(int preKeyId) async => db.raw.select(
    'SELECT 1 FROM prekeys WHERE id = ?',
    [preKeyId],
  ).isNotEmpty;

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final rows = db.raw.select('SELECT record FROM prekeys WHERE id = ?', [
      preKeyId,
    ]);
    if (rows.isEmpty) {
      throw InvalidKeyIdException('No such prekey: $preKeyId');
    }
    return PreKeyRecord.fromBuffer(rows.first['record'] as Uint8List);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async =>
      db.raw.execute(
        'INSERT OR REPLACE INTO prekeys (id, record) VALUES (?, ?)',
        [preKeyId, record.serialize()],
      );

  @override
  Future<void> removePreKey(int preKeyId) async =>
      db.raw.execute('DELETE FROM prekeys WHERE id = ?', [preKeyId]);

  // ---- signed prekeys ----
  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async => db.raw.select(
    'SELECT 1 FROM signed_prekeys WHERE id = ?',
    [signedPreKeyId],
  ).isNotEmpty;

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final rows = db.raw.select(
      'SELECT record FROM signed_prekeys WHERE id = ?',
      [signedPreKeyId],
    );
    if (rows.isEmpty) {
      throw InvalidKeyIdException('No such signed prekey: $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(rows.first['record'] as Uint8List);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async => [
    for (final r in db.raw.select('SELECT record FROM signed_prekeys'))
      SignedPreKeyRecord.fromSerialized(r['record'] as Uint8List),
  ];

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async => db.raw.execute(
    'INSERT OR REPLACE INTO signed_prekeys (id, record) VALUES (?, ?)',
    [signedPreKeyId, record.serialize()],
  );

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async => db.raw.execute(
    'DELETE FROM signed_prekeys WHERE id = ?',
    [signedPreKeyId],
  );

  // ---- sessions ----
  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      db.raw.select('SELECT 1 FROM sessions WHERE name = ? AND device = ?', [
        address.getName(),
        address.getDeviceId(),
      ]).isNotEmpty;

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final rows = db.raw.select(
      'SELECT record FROM sessions WHERE name = ? AND device = ?',
      [address.getName(), address.getDeviceId()],
    );
    return rows.isEmpty
        ? SessionRecord()
        : SessionRecord.fromSerialized(rows.first['record'] as Uint8List);
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async => db.raw.execute(
    'INSERT INTO sessions (name, device, record) VALUES (?, ?, ?) '
    'ON CONFLICT(name, device) DO UPDATE SET record = excluded.record',
    [address.getName(), address.getDeviceId(), record.serialize()],
  );

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async =>
      db.raw.execute('DELETE FROM sessions WHERE name = ? AND device = ?', [
        address.getName(),
        address.getDeviceId(),
      ]);

  @override
  Future<void> deleteAllSessions(String name) async =>
      db.raw.execute('DELETE FROM sessions WHERE name = ?', [name]);

  @override
  Future<List<int>> getSubDeviceSessions(String name) async => [
    for (final r in db.raw.select(
      'SELECT device FROM sessions WHERE name = ? AND device != 1',
      [name],
    ))
      r['device'] as int,
  ];
}
