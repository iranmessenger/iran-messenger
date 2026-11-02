import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'api_client.dart';
import 'messenger.dart';
import 'models.dart';

/// Client-side encryption and chunked transfer of attachments.
///
/// Files are sealed with AES-256-GCM (library implementation) under a fresh
/// random key before upload. The key travels only inside the E2EE message.
class MediaTransfer {
  MediaTransfer(this._m);

  final Messenger _m;
  static final _aes = AesGcm.with256bits();
  static final _rng = Random.secure();

  /// Plaintext size limits per kind, in bytes.
  static const limits = {
    'image': 5 * 1024 * 1024,
    'gif': 5 * 1024 * 1024,
    'sticker': 1024 * 1024,
    'voice': 10 * 1024 * 1024,
    'video': 25 * 1024 * 1024,
    'file': 40 * 1024 * 1024,
  };

  /// Transfers running in this isolate: message row id -> (bytes done,
  /// bytes in total). An entry with total 0 is still being prepared.
  final _progress = <int, (int, int)>{};

  /// How far the upload or download of message [rowId] is, or null if
  /// none is running here.
  (int, int)? progress(int rowId) => _progress[rowId];

  void _report(int rowId, int done, int total) {
    _progress[rowId] = (done, total);
    _m.notify();
  }

  void _finish(int rowId) {
    if (_progress.remove(rowId) != null) _m.notify();
  }

  /// GIFs and stickers are kept by content: the same file arriving again
  /// (from anyone, in any chat) is copied from this device instead of
  /// being downloaded. Only hashes this device computed itself are indexed.
  static bool reusable(String kind) => kind == 'gif' || kind == 'sticker';

  static Future<String> plainHash(List<int> bytes) async =>
      _hex((await Sha256().hash(bytes)).bytes);

  void remember(String sha, String path) =>
      _m.db.kvPutString('anim:$sha', path);

  String? _known(String? sha) {
    if (sha == null) return null;
    final path = _m.db.kvString('anim:$sha');
    return path != null && _m.files.existsSync(path) ? path : null;
  }

  void _save(int rowId, MediaInfo info) {
    _m.db.raw.execute('UPDATE messages SET media = ? WHERE id = ?', [
      jsonEncode(info.toJson()),
      rowId,
    ]);
  }

  /// Encrypts and uploads the attachment of message [rowId]. Safe to call
  /// again after an interruption: it resumes at the first missing chunk.
  /// [between] runs after every piece, so short messages queued meanwhile
  /// need not wait for the whole file.
  Future<void> upload(
    int rowId,
    MediaInfo info,
    List<int> deviceIds, {
    Future<void> Function()? between,
  }) async {
    final path = info.path;
    if (path == null || !_m.files.existsSync(path)) {
      throw StateError('media_missing');
    }
    final plain = await _m.files.read(path);
    if (plain.length > (limits[info.kind] ?? limits['file']!)) {
      throw StateError('media_too_large');
    }
    if (deviceIds.isEmpty) return;
    _report(rowId, 0, 0);
    try {
      await _upload(rowId, info, deviceIds, plain, between);
    } finally {
      _finish(rowId);
    }
  }

  Future<void> _upload(
    int rowId,
    MediaInfo info,
    List<int> deviceIds,
    Uint8List plain,
    Future<void> Function()? between,
  ) async {
    // Key and nonce are fixed before the first byte is sent, so a resumed
    // upload produces the identical ciphertext.
    if (info.key == null) {
      info.key = base64Encode(
        List<int>.generate(32 + 12, (_) => _rng.nextInt(256)),
      );
      _save(rowId, info);
    }
    final secret = base64Decode(info.key!);
    final box = await _aes.encrypt(
      plain,
      secretKey: SecretKey(secret.sublist(0, 32)),
      nonce: secret.sublist(32),
    );
    final blob = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    final sha = _hex((await Sha256().hash(blob)).bytes);

    var next = 0;
    var chunkSize = 0;
    if (info.uploadId != null) {
      try {
        final st = await _m.api.get('/media/uploads/${info.uploadId}') as Map;
        next = st['next_chunk'] as int;
        chunkSize = st['chunk_size'] as int;
      } on ApiError catch (e) {
        if (e.status != 404) rethrow;
        info.uploadId = null;
      }
    }
    if (info.uploadId == null) {
      final st =
          await _m.api.post('/media/uploads', {
                'size': blob.length,
                'sha256': sha,
                'recipients': deviceIds,
              })
              as Map;
      info.uploadId = st['media_id'] as String;
      chunkSize = st['chunk_size'] as int;
      next = 0;
      _save(rowId, info);
    }

    final total = (blob.length / chunkSize).ceil();
    _report(rowId, min(next * chunkSize, blob.length), blob.length);
    while (next < total) {
      final start = next * chunkSize;
      final end = min(start + chunkSize, blob.length);
      final res =
          await _m.api.post('/media/uploads/${info.uploadId}/chunks', {
                'n': next,
                'data': base64Encode(blob.sublist(start, end)),
              })
              as Map;
      next = res['next_chunk'] as int;
      _report(rowId, min(next * chunkSize, blob.length), blob.length);
      _m.touchLease();
      if (between != null && next < total) await between();
    }

    info
      ..serverId = info.uploadId
      ..sha256 = sha;
    _save(rowId, info);
  }

  /// Fetches, verifies and decrypts the attachment of an incoming message.
  /// Returns the local path, or null when the server no longer has it.
  Future<String?> download(int rowId) async {
    final rows = _m.db.raw.select('SELECT media FROM messages WHERE id = ?', [
      rowId,
    ]);
    if (rows.isEmpty || rows.first['media'] == null) return null;
    final info = MediaInfo.fromJson(
      jsonDecode(rows.first['media'] as String) as Map<String, dynamic>,
    );
    if (info.path != null && _m.files.existsSync(info.path!)) {
      return info.path;
    }
    if (info.serverId == null || info.key == null) return null;

    final known = reusable(info.kind) ? _known(info.plainSha) : null;
    if (known != null) {
      final out = _m.files.newPath(
        'media',
        '${Messenger.newId()}_${known.split('/').last}',
      );
      await _m.files.write(out, await _m.files.read(known));
      info.path = out;
      _save(rowId, info);
      _m.notify();
      // The server copy is no longer needed by this device.
      try {
        await _m.api.post('/media/${info.serverId}/done', {});
      } on ApiError {
        // Server-side cleanup also happens by expiry.
      }
      return out;
    }

    final blob = BytesBuilder(copy: false);
    _report(rowId, 0, 0);
    try {
      var offset = 0;
      var total = 1;
      while (offset < total) {
        final res =
            await _m.api.get(
                  '/media/${info.serverId}',
                  query: {'offset': '$offset'},
                )
                as Map;
        total = res['total'] as int;
        blob.add(base64Decode(res['data'] as String));
        offset = res['next'] as int;
        _report(rowId, offset, total);
        _m.touchLease();
      }
    } on ApiError catch (e) {
      _finish(rowId);
      if (e.status != 404) rethrow;
      _m.db.raw.execute('UPDATE messages SET error = ? WHERE id = ?', [
        'media_expired',
        rowId,
      ]);
      _m.notify();
      return null;
    } catch (_) {
      _finish(rowId);
      rethrow;
    }

    _finish(rowId);
    final bytes = blob.takeBytes();
    if (_hex((await Sha256().hash(bytes)).bytes) != info.sha256) {
      throw StateError('media_corrupt');
    }
    final secret = base64Decode(info.key!);
    // Authenticated decryption: throws if a single bit was altered.
    final plain = await _aes.decrypt(
      SecretBox(
        bytes.sublist(0, bytes.length - 16),
        nonce: secret.sublist(32),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: SecretKey(secret.sublist(0, 32)),
    );

    final safe = info.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final out = _m.files.newPath('media', '${Messenger.newId()}_$safe');
    await _m.files.write(out, plain);
    info.path = out;
    _save(rowId, info);
    if (reusable(info.kind)) remember(await plainHash(plain), out);
    _m.notify();

    try {
      await _m.api.post('/media/${info.serverId}/done', {});
    } on ApiError {
      // Server-side cleanup also happens by expiry.
    }
    return out;
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
