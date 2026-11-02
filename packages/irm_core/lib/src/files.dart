import 'dart:typed_data';

/// Private storage for decrypted attachments and saved GIFs. A plain
/// directory on phones and desktops; IndexedDB in a browser.
///
/// Paths are opaque strings produced by [newPath]; they are stored in the
/// database and only ever handed back to the same store.
abstract class FileStore {
  /// A fresh path for [name] inside [folder] ("media" or "favorites").
  String newPath(String folder, String name);

  bool existsSync(String path);
  Future<Uint8List> read(String path);
  Future<void> write(String path, List<int> bytes);
  Future<void> delete(String path);
}

/// Receives one JSON line per suspected firewall block.
typedef WafSink = void Function(String jsonLine);

/// Last segment of a stored path, without the random prefix [newPath] adds.
String fileNameOf(String path) {
  final last = path.substring(path.lastIndexOf('/') + 1);
  final cut = last.indexOf('_');
  return cut == 36 ? last.substring(37) : last;
}
