import 'dart:typed_data';

/// A file the user chose, already read into memory.
class ChosenFile {
  const ChosenFile(this.bytes, this.name, this.mime);
  final Uint8List bytes;
  final String name;
  final String mime;
}

/// The chosen file is over the size limit.
class FileTooLarge implements Exception {
  const FileTooLarge();
}

/// What a folder of GIFs gave: the usable files, how many were too large,
/// and how many were not GIFs at all.
class GifFolder {
  const GifFolder(this.files, this.tooLarge, this.other);
  final List<ChosenFile> files;
  final int tooLarge;
  final int other;
}
