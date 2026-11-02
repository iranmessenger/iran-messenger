import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';

/// The single local database of one device: protocol state, contacts,
/// messages and the outbox. Opened with a key when the SQLite build
/// supports encryption (SQLite3 Multiple Ciphers).
class AppDb {
  AppDb._(this.raw, this._flush);

  final CommonDatabase raw;

  /// Waits until committed pages are on durable storage. Only set where
  /// the file system writes behind (a browser).
  final Future<void> Function()? _flush;
  Future<void> _lock = Future.value();

  static const _schemaVersion = 6;

  /// Takes over an opened connection. [keyHex] is 64 hex characters held
  /// in the OS keystore, never in files.
  static AppDb wrap(
    CommonDatabase db, {
    String? keyHex,
    bool wal = true,
    Future<void> Function()? flush,
  }) {
    if (keyHex != null) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(keyHex)) {
        throw ArgumentError('database key must be 64 hex characters');
      }
      db.execute("PRAGMA key = '$keyHex';");
    }
    try {
      // Fails here with "file is not a database" if the key is wrong.
      db.select('SELECT count(*) FROM sqlite_master');
    } catch (_) {
      db.close();
      rethrow;
    }
    if (wal) db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = FULL;');
    // The UI and the background service each hold their own connection.
    db.execute('PRAGMA busy_timeout = 8000;');
    final app = AppDb._(db, flush);
    app._migrate();
    return app;
  }

  /// True when the linked SQLite can actually encrypt (cipher build).
  bool get cipherAvailable => raw.select('PRAGMA cipher;').isNotEmpty;

  void _migrate() {
    final version = raw.select('PRAGMA user_version').first.values.first as int;
    if (version >= _schemaVersion) return;
    if (version < 1) _createV1();
    if (version < 2) {
      raw.execute('ALTER TABLE contacts ADD COLUMN username TEXT');
    }
    if (version < 3) {
      raw.execute('ALTER TABLE messages ADD COLUMN reply TEXT');
      raw.execute('ALTER TABLE messages ADD COLUMN reactions TEXT');
      raw.execute(
        'ALTER TABLE messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (version < 4) {
      raw.execute(
        'CREATE TABLE IF NOT EXISTS favorites ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, '
        'mime TEXT NOT NULL, path TEXT NOT NULL UNIQUE, '
        'sha TEXT NOT NULL, added_at INTEGER NOT NULL)',
      );
    }
    if (version < 5) {
      // Who read an outgoing message, several admins, profile pictures.
      raw.execute('ALTER TABLE messages ADD COLUMN readers TEXT');
      raw.execute('ALTER TABLE groups ADD COLUMN admins TEXT');
      raw.execute('ALTER TABLE groups ADD COLUMN avatar TEXT');
      raw.execute('ALTER TABLE contacts ADD COLUMN avatar TEXT');
    }
    if (version < 6) {
      // Polls: the question's options and everyone's votes.
      raw.execute('ALTER TABLE messages ADD COLUMN poll TEXT');
      raw.execute('ALTER TABLE messages ADD COLUMN votes TEXT');
    }
    raw.execute('PRAGMA user_version = $_schemaVersion');
  }

  void _createV1() {
    raw.execute('''
      CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS prekeys (id INTEGER PRIMARY KEY, record BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS signed_prekeys (id INTEGER PRIMARY KEY, record BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS sessions (
        name TEXT NOT NULL, device INTEGER NOT NULL, record BLOB NOT NULL,
        PRIMARY KEY (name, device));
      CREATE TABLE IF NOT EXISTS peer_identities (
        name TEXT NOT NULL, device INTEGER NOT NULL, key BLOB NOT NULL,
        PRIMARY KEY (name, device));
      CREATE TABLE IF NOT EXISTS contacts (
        identity_id INTEGER PRIMARY KEY, display_name TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS peer_devices (
        identity_id INTEGER NOT NULL, device_id INTEGER NOT NULL,
        PRIMARY KEY (identity_id, device_id));
      CREATE TABLE IF NOT EXISTS groups (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, admin INTEGER NOT NULL,
        epoch INTEGER NOT NULL DEFAULT 1, left INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS group_members (
        group_id TEXT NOT NULL, identity_id INTEGER NOT NULL,
        PRIMARY KEY (group_id, identity_id));
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat TEXT NOT NULL,
        sender INTEGER NOT NULL,
        outgoing INTEGER NOT NULL,
        kind TEXT NOT NULL DEFAULT 'text',
        body TEXT NOT NULL,
        media TEXT,
        client_msg_id TEXT UNIQUE,
        delivery_id INTEGER UNIQUE,
        status INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        payload TEXT,
        error TEXT);
      CREATE INDEX IF NOT EXISTS messages_chat ON messages (chat, id);
      CREATE INDEX IF NOT EXISTS messages_outbox ON messages (outgoing, status, id);
    ''');
  }

  /// Runs [body] as one atomic unit. Calls are serialised, so awaits inside
  /// [body] cannot interleave with another transaction. Not re-entrant.
  Future<T> tx<T>(Future<T> Function() body) {
    final done = Completer<void>();
    final previous = _lock;
    _lock = done.future;
    return previous.then((_) async {
      raw.execute('BEGIN IMMEDIATE');
      try {
        final result = await body();
        raw.execute('COMMIT');
        await _flush?.call();
        return result;
      } catch (_) {
        raw.execute('ROLLBACK');
        rethrow;
      } finally {
        done.complete();
      }
    });
  }

  // ---- key/value ----
  Uint8List? kvBytes(String k) {
    final rows = raw.select('SELECT v FROM kv WHERE k = ?', [k]);
    return rows.isEmpty ? null : rows.first['v'] as Uint8List;
  }

  void kvPutBytes(String k, List<int> v) => raw.execute(
    'INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v',
    [k, Uint8List.fromList(v)],
  );

  String? kvString(String k) {
    final b = kvBytes(k);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  void kvPutString(String k, String v) => kvPutBytes(k, utf8.encode(v));

  int? kvInt(String k) {
    final s = kvString(k);
    return s == null ? null : int.parse(s);
  }

  void kvPutInt(String k, int v) => kvPutString(k, '$v');

  void close() => raw.close();
}
