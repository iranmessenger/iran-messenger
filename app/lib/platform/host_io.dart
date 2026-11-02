import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

import 'picked.dart';

export 'picked.dart';

const isWebApp = false;

/// The server this copy belongs to, when it cannot be anything else.
String get builtInSite => '';

bool get shareIntakeAvailable => Platform.isAndroid;

bool isConnectionError(Object e) => e is IOException;

/// Firewall incidents, one JSON line each.
class WafLog {
  WafLog(this._file);
  final File _file;

  void add(String line) =>
      _file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);

  Future<List<String>> lines() async =>
      await _file.exists() ? _file.readAsLines() : const [];
}

/// Opens the encrypted database and private storage of this installation.
Future<(Messenger, WafLog)> openLocalMessenger(String keyHex) async {
  final dir = await getApplicationSupportDirectory();
  final log = WafLog(File('${dir.path}/waf_evidence.jsonl'));
  return (
    Messenger(
      openAppDbSync('${dir.path}/irm.db', keyHex: keyHex),
      IoFileStore(dir),
      wafLog: log.add,
    ),
    log,
  );
}

/// Bytes of something the user picked or recorded.
Future<Uint8List> readPath(String path) => File(path).readAsBytes();

int localFileSize(String path) => File(path).lengthSync();

/// Re-encodes a photo so that nothing but pixels survives: EXIF, GPS
/// position and camera details are dropped, and very large photos are
/// scaled down. Returns JPEG bytes, or null if [bytes] is not an image.
Future<Uint8List?> stripAndCompressPhoto(Uint8List bytes) =>
    compute(_reencode, bytes);

Uint8List? _reencode(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // Apply the EXIF rotation to the pixels first, since the tag is removed.
  var image = img.bakeOrientation(decoded);
  const maxSide = 1920;
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  image.exif = img.ExifData();
  return img.encodeJpg(image, quality: 82);
}

/// A small square JPEG for a profile picture, cut from the middle of
/// [bytes]. Null if [bytes] is not an image.
Future<Uint8List?> avatarJpeg(Uint8List bytes) => compute(_avatar, bytes);

Uint8List? _avatar(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final square = img.copyResizeCropSquare(
    img.bakeOrientation(decoded),
    size: 320,
  );
  square.exif = img.ExifData();
  return img.encodeJpg(square, quality: 84);
}

Widget localImage(
  String path, {
  BoxFit? fit,
  double? width,
  double? height,
  int? cacheWidth,
  ImageErrorWidgetBuilder? errorBuilder,
}) => Image.file(
  File(path),
  fit: fit,
  width: width,
  height: height,
  cacheWidth: cacheWidth,
  errorBuilder: errorBuilder,
);

Future<VideoPlayerController> localVideo(
  String path,
  String mime, {
  bool mix = false,
}) async => VideoPlayerController.file(
  File(path),
  videoPlayerOptions: VideoPlayerOptions(mixWithOthers: mix),
);

Future<Source> localAudio(String path, String mime) async =>
    DeviceFileSource(path);

/// Where a voice message is recorded to, and the format it comes out in.
Future<(String, String)> voiceTarget() async {
  final dir = await getTemporaryDirectory();
  return ('${dir.path}/${Messenger.newId()}_voice.m4a', 'audio/mp4');
}

/// A short strong vibration pattern for an incoming BUZZ.
Future<void> deviceBuzz() async {
  try {
    if (Platform.isAndroid) {
      await const MethodChannel('irm/device').invokeMethod<void>('buzz');
      return;
    }
  } catch (_) {
    // Fall back to the system's own haptics below.
  }
  for (var i = 0; i < 3; i++) {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
}

/// Changes once per power-on of the phone ('' when unknown); the intro
/// animation plays once per value.
Future<String> bootId() async {
  if (!Platform.isAndroid) return '';
  try {
    return await const MethodChannel(
          'irm/device',
        ).invokeMethod<String>('bootId') ??
        '';
  } catch (_) {
    return '';
  }
}

// Implemented in MainActivity with Android's own file pickers, so the app
// needs no storage permission.
const _files = MethodChannel('irm/files');

/// Lets the user choose where to keep [bytes].
Future<bool> saveBytes(String name, Uint8List bytes) async {
  if (!Platform.isAndroid) return false;
  final tmp = File('${(await getTemporaryDirectory()).path}/$name');
  await tmp.writeAsBytes(bytes, flush: true);
  try {
    return await _files.invokeMethod<bool>('save', {
          'name': name,
          'path': tmp.path,
        }) ??
        false;
  } finally {
    await tmp.delete();
  }
}

/// Lets the user choose a file and returns its bytes.
Future<Uint8List?> pickFileBytes() async {
  if (!Platform.isAndroid) return null;
  final path = await _files.invokeMethod<String>('open');
  if (path == null) return null;
  final file = File(path);
  try {
    return await file.readAsBytes();
  } finally {
    await file.delete();
  }
}

/// Lets the user choose any file to send. Null if they cancelled; throws
/// [FileTooLarge] past [maxBytes].
Future<ChosenFile?> pickFileToSend(int maxBytes) async {
  if (!Platform.isAndroid) return null;
  final r = await _files.invokeMapMethod<String, Object?>('pick', {
    'max': maxBytes,
  });
  if (r == null) return null;
  if (r['error'] == 'too_large') throw const FileTooLarge();
  if (r['path'] == null) throw StateError('pick failed');
  return _takeFile(
    r['path']! as String,
    r['name']! as String,
    r['mime']! as String,
  );
}

/// Whether a whole folder can be chosen at once.
bool get folderImportAvailable => Platform.isAndroid;

/// Lets the user choose a folder and returns its GIF, WebP and MP4 files
/// of at most [maxBytes] each. Null if they cancelled.
Future<GifFolder?> pickGifFolder(int maxBytes) async {
  if (!Platform.isAndroid) return null;
  final r = await _files.invokeMapMethod<String, Object?>('gifFolder', {
    'max': maxBytes,
  });
  if (r == null) return null;
  if (r['files'] == null) throw StateError('folder failed');
  final files = <ChosenFile>[];
  for (final f in (r['files']! as List).cast<Map>()) {
    files.add(
      await _takeFile(
        f['path'] as String,
        f['name'] as String,
        f['mime'] as String,
      ),
    );
  }
  return GifFolder(files, r['tooLarge']! as int, r['other']! as int);
}

/// Reads a picked copy and removes it from the cache.
Future<ChosenFile> _takeFile(String path, String name, String mime) async {
  final file = File(path);
  try {
    return ChosenFile(await file.readAsBytes(), name, mime);
  } finally {
    await file.delete().catchError((_) => file);
  }
}

/// Opens a received file in another app. False if none can open it.
Future<bool> openFile(String path, String name, String mime) async {
  if (!Platform.isAndroid) return false;
  return await _files.invokeMethod<bool>('view', {
        'path': path,
        'name': name,
        'mime': mime,
      }) ??
      false;
}
