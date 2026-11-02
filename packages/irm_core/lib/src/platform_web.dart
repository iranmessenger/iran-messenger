import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

import 'app_db.dart';
import 'files.dart';

/// Browser implementations of what differs from phones and desktops.

bool isTransportError(Object e) => e is http.ClientException;

/// A browser tab has one thread; let a frame paint, then do the work.
Future<T> runHeavy<T>(FutureOr<T> Function() work) =>
    Future.delayed(const Duration(milliseconds: 60), work);

List<int> gzipEncode(List<int> data) => const GZipEncoder().encodeBytes(data);
List<int> gzipDecode(List<int> data) => const GZipDecoder().decodeBytes(data);

WasmSqlite3? _sqlite;

/// Opens the database called [name]. SQLite runs as WebAssembly (the
/// encrypting build) and keeps its pages in IndexedDB.
Future<AppDb> openAppDb(String name, {String? keyHex}) async {
  var sqlite = _sqlite;
  IndexedDbFileSystem? fs;
  if (sqlite == null) {
    sqlite = await WasmSqlite3.loadFromUrlString('sqlite3mc.wasm');
    fs = await IndexedDbFileSystem.open(dbName: 'irm_db');
    sqlite.registerVirtualFileSystem(fs, makeDefault: true);
    _sqlite = sqlite;
    _fs = fs;
  }
  // The cipher layer wraps a file system on request, by this name prefix.
  return AppDb.wrap(
    sqlite.open('/$name', vfs: 'multipleciphers-${_fs!.name}'),
    keyHex: keyHex,
    wal: false,
    flush: _fs!.flush,
  );
}

IndexedDbFileSystem? _fs;

Future<FileStore> openFileStore(String root) => IdbFileStore.open(root);

Future<T> _done<T extends JSAny?>(web.IDBRequest request) {
  final c = Completer<T>();
  request.onsuccess = ((web.Event _) => c.complete(request.result as T)).toJS;
  request.onerror = ((web.Event _) => c.completeError(
    StateError('storage: ${request.error?.message}'),
  )).toJS;
  return c.future;
}

/// Attachments as one IndexedDB record each, read only when shown.
class IdbFileStore implements FileStore {
  IdbFileStore._(this._db, this._known);

  final web.IDBDatabase _db;
  final Set<String> _known;
  static const _store = 'files';

  static Future<IdbFileStore> open(String name) async {
    final request = web.window.indexedDB.open(name, 1);
    request.onupgradeneeded = ((web.Event _) {
      (request.result as web.IDBDatabase).createObjectStore(_store);
    }).toJS;
    final db = await _done<web.IDBDatabase>(request);
    final keys = await _done<JSArray<JSAny?>>(
      db.transaction(_store.toJS).objectStore(_store).getAllKeys(),
    );
    return IdbFileStore._(db, {
      for (final k in keys.toDart) (k as JSString).toDart,
    });
  }

  web.IDBObjectStore _tx(String mode) =>
      _db.transaction(_store.toJS, mode).objectStore(_store);

  @override
  String newPath(String folder, String name) => '$folder/$name';

  @override
  bool existsSync(String path) => _known.contains(path);

  @override
  Future<Uint8List> read(String path) async {
    final value = await _done<JSAny?>(_tx('readonly').get(path.toJS));
    if (value == null) throw StateError('media_missing');
    return (value as JSUint8Array).toDart;
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    await _done<JSAny?>(_tx('readwrite').put(data.toJS, path.toJS));
    _known.add(path);
  }

  @override
  Future<void> delete(String path) async {
    _known.remove(path);
    await _done<JSAny?>(_tx('readwrite').delete(path.toJS));
  }
}
