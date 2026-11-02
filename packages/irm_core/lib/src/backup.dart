import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'messenger.dart';
import 'models.dart';
import 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';

/// Why a backup file could not be restored.
class BackupError implements Exception {
  BackupError(this.code);

  /// bad_file | wrong_passphrase | other_account | weak_passphrase
  final String code;
  @override
  String toString() => 'BackupError($code)';
}

class BackupSummary {
  BackupSummary(this.messages, this.chats);
  final int messages;
  final int chats;
}

/// Password-protected history backup.
///
/// The file holds conversations, contacts and groups, sealed with
/// AES-256-GCM under a key stretched from the user's passphrase with
/// Argon2id (library implementations of both). It never contains protocol
/// keys or the account password: a restored device gets fresh keys by
/// signing in, then reads its old history from the file. Attachments are
/// not included.
class Backup {
  static const _magic = 'IRMBK1';
  static const _memoryKiB = 19456;
  static const _iterations = 2;

  static Future<List<int>> _derive(String passphrase, List<int> salt) =>
      // Off the calling isolate where there is one: stretching takes a
      // noticeable moment.
      runHeavy(() async {
        final key = await Argon2id(
          parallelism: 1,
          memory: _memoryKiB,
          iterations: _iterations,
          hashLength: 32,
        ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
        return key.extractBytes();
      });

  static Future<Uint8List> export(Messenger m, String passphrase) async {
    if (passphrase.length < 8) throw BackupError('weak_passphrase');
    final db = m.db.raw;
    final data = {
      'v': 1,
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'identity': m.myIdentity,
      'username': m.myUsername,
      'contacts': [
        for (final r in db.select('SELECT * FROM contacts'))
          {
            'id': r['identity_id'],
            'name': r['display_name'],
            'username': r['username'],
          },
      ],
      'groups': [
        for (final g in db.select('SELECT * FROM groups'))
          {
            'id': g['id'],
            'title': g['title'],
            'admin': g['admin'],
            'epoch': g['epoch'],
            'left': g['left'],
            'members': [
              for (final x in db.select(
                'SELECT identity_id FROM group_members WHERE group_id = ?',
                [g['id']],
              ))
                x['identity_id'],
            ],
          },
      ],
      'messages': [
        for (final r in db.select(
          'SELECT * FROM messages WHERE kind != ? ORDER BY id',
          ['control'],
        ))
          {
            'chat': r['chat'],
            'sender': r['sender'],
            'out': r['outgoing'],
            'kind': r['kind'],
            'body': r['body'],
            'media': _portableMedia(r['media'] as String?),
            'cmid': r['client_msg_id'],
            'status': r['status'],
            'ts': r['created_at'],
            'reply': r['reply'],
            'reactions': r['reactions'],
            'edited': r['edited'],
            'poll': r['poll'],
            'votes': r['votes'],
          },
      ],
    };
    final plain = gzipEncode(utf8.encode(jsonEncode(data)));

    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final header = utf8.encode(
      '$_magic\n${jsonEncode({'kdf': 'argon2id', 'm': _memoryKiB, 't': _iterations, 'salt': base64Encode(salt), 'nonce': base64Encode(nonce)})}\n',
    );
    final box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: SecretKey(await _derive(passphrase, salt)),
      nonce: nonce,
      // The header is authenticated, so its parameters cannot be swapped.
      aad: header,
    );
    return Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Local paths and upload state mean nothing on another installation.
  static String? _portableMedia(String? json) {
    if (json == null) return null;
    final map = (jsonDecode(json) as Map)
      ..remove('path')
      ..remove('up');
    return jsonEncode(map);
  }

  /// Adds the backup's history to [m]. Existing messages are kept and not
  /// duplicated, so restoring the same file twice is harmless.
  static Future<BackupSummary> restore(
    Messenger m,
    Uint8List file,
    String passphrase,
  ) async {
    Map<String, dynamic> data;
    try {
      final firstNl = file.indexOf(10);
      final secondNl = file.indexOf(10, firstNl + 1);
      if (firstNl < 0 ||
          secondNl < 0 ||
          utf8.decode(file.sublist(0, firstNl)) != _magic) {
        throw BackupError('bad_file');
      }
      final params =
          jsonDecode(utf8.decode(file.sublist(firstNl + 1, secondNl))) as Map;
      if (params['kdf'] != 'argon2id' ||
          params['m'] != _memoryKiB ||
          params['t'] != _iterations) {
        throw BackupError('bad_file');
      }
      final body = file.sublist(secondNl + 1);
      if (body.length < 17) throw BackupError('bad_file');
      final key = await _derive(
        passphrase,
        base64Decode(params['salt'] as String),
      );
      List<int> plain;
      try {
        plain = await AesGcm.with256bits().decrypt(
          SecretBox(
            body.sublist(0, body.length - 16),
            nonce: base64Decode(params['nonce'] as String),
            mac: Mac(body.sublist(body.length - 16)),
          ),
          secretKey: SecretKey(key),
          aad: file.sublist(0, secondNl + 1),
        );
      } on SecretBoxAuthenticationError {
        throw BackupError('wrong_passphrase');
      }
      data = (jsonDecode(utf8.decode(gzipDecode(plain))) as Map)
          .cast<String, dynamic>();
    } on BackupError {
      rethrow;
    } catch (_) {
      throw BackupError('bad_file');
    }
    if (data['identity'] != m.myIdentity) throw BackupError('other_account');

    final db = m.db;
    var added = 0;
    final chats = <String>{};
    await db.tx(() async {
      for (final c in data['contacts'] as List) {
        db.raw.execute(
          'INSERT OR IGNORE INTO contacts (identity_id, display_name, username) VALUES (?, ?, ?)',
          [c['id'], c['name'], c['username']],
        );
      }
      for (final g in data['groups'] as List) {
        if (db.raw.select('SELECT 1 FROM groups WHERE id = ?', [
          g['id'],
        ]).isNotEmpty) {
          continue; // what this device already knows is newer
        }
        db.raw.execute(
          'INSERT INTO groups (id, title, admin, epoch, left) VALUES (?, ?, ?, ?, ?)',
          [g['id'], g['title'], g['admin'], g['epoch'], g['left']],
        );
        for (final member in g['members'] as List) {
          db.raw.execute(
            'INSERT OR IGNORE INTO group_members (group_id, identity_id) VALUES (?, ?)',
            [g['id'], member],
          );
        }
      }
      // Restored rows get ids below everything already here, so old
      // history sorts before messages that arrived since signing in.
      final list = data['messages'] as List;
      final minRow = db.raw.select('SELECT MIN(id) AS m FROM messages').first;
      var nextId = ((minRow['m'] as int?) ?? 1) - list.length - 1;
      for (final r in list) {
        nextId++;
        final cmid = r['cmid'] as String?;
        final exists = cmid != null
            ? db.raw.select('SELECT 1 FROM messages WHERE client_msg_id = ?', [
                cmid,
              ]).isNotEmpty
            : db.raw.select(
                'SELECT 1 FROM messages WHERE chat = ? AND sender = ? AND created_at = ? AND body = ?',
                [r['chat'], r['sender'], r['ts'], r['body']],
              ).isNotEmpty;
        if (exists) continue;
        // Something still queued on the old device was never sent.
        final status = r['status'] == MsgStatus.pending
            ? MsgStatus.failed
            : r['status'];
        db.raw.execute(
          'INSERT INTO messages (id, chat, sender, outgoing, kind, body, media, client_msg_id, status, created_at, reply, reactions, edited, error, poll, votes) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            nextId,
            r['chat'],
            r['sender'],
            r['out'],
            r['kind'],
            r['body'],
            r['media'],
            cmid,
            status,
            r['ts'],
            r['reply'],
            r['reactions'],
            r['edited'] ?? 0,
            r['status'] == MsgStatus.pending ? 'not_sent_before_restore' : null,
            r['poll'],
            r['votes'],
          ],
        );
        added++;
        chats.add(r['chat'] as String);
      }
    });
    m.notify();
    return BackupSummary(added, chats.length);
  }
}
