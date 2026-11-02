import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'app_db.dart';
import 'files.dart';

/// Phone and desktop implementations of what differs in a browser.

bool isTransportError(Object e) => e is IOException;

/// Runs [work] off the calling isolate.
Future<T> runHeavy<T>(FutureOr<T> Function() work) => Isolate.run(work);

List<int> gzipEncode(List<int> data) => gzip.encode(data);
List<int> gzipDecode(List<int> data) => gzip.decode(data);

/// Opens the database file at [path].
AppDb openAppDbSync(String path, {String? keyHex}) =>
    AppDb.wrap(sqlite3.open(path), keyHex: keyHex);

Future<AppDb> openAppDb(String path, {String? keyHex}) async =>
    openAppDbSync(path, keyHex: keyHex);

Future<FileStore> openFileStore(String root) async =>
    IoFileStore(Directory(root));

/// Appends firewall evidence to a file.
WafSink fileWafSink(File file) =>
    (line) =>
        file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);

class IoFileStore implements FileStore {
  IoFileStore(this.root);
  final Directory root;

  @override
  String newPath(String folder, String name) {
    Directory('${root.path}/$folder').createSync(recursive: true);
    return '${root.path}/$folder/$name';
  }

  @override
  bool existsSync(String path) => File(path).existsSync();

  @override
  Future<Uint8List> read(String path) => File(path).readAsBytes();

  @override
  Future<void> write(String path, List<int> bytes) =>
      File(path).writeAsBytes(bytes, flush: true);

  @override
  Future<void> delete(String path) async {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
}
