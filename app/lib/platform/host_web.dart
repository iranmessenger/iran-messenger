import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;
import 'package:irm_core/irm_core.dart';

import 'picked.dart';

export 'picked.dart';

const isWebApp = true;

/// The web app only ever talks to the site it was loaded from.
String get builtInSite => Uri.base.origin;

bool get shareIntakeAvailable => false;

/// A short vibration for an incoming BUZZ, where the browser allows it
/// (Android browsers do; iPhones ignore it).
Future<void> deviceBuzz() async {
  try {
    web.window.navigator.vibrate(
      [160, 90, 160, 90, 260].map((e) => e.toJS).toList().toJS,
    );
  } catch (_) {}
}

/// A browser cannot tell when the phone was switched on, and the web app
/// shows no intro (it has its own loading screen instead).
Future<String> bootId() async => '';

bool isConnectionError(Object e) => e is http.ClientException;

/// Firewall incidents, one JSON line each (the newest fifty).
class WafLog {
  static const _key = 'irm_waf_log';

  List<String> _read() {
    final raw = web.window.localStorage.getItem(_key);
    return raw == null || raw.isEmpty ? [] : raw.split('\n');
  }

  void add(String line) {
    final all = _read()..add(line);
    try {
      web.window.localStorage.setItem(
        _key,
        all.skip(all.length > 50 ? all.length - 50 : 0).join('\n'),
      );
    } catch (_) {
      // Storage full or disabled: the incident is still shown on screen.
    }
  }

  Future<List<String>> lines() async => _read();
}

late FileStore _store;

/// Opens the encrypted database and private storage of this browser.
Future<(Messenger, WafLog)> openLocalMessenger(String keyHex) async {
  final log = WafLog();
  _store = await openFileStore('irm_files');
  final db = await openAppDb('irm.db', keyHex: keyHex);
  return (Messenger(db, _store, wafLog: log.add), log);
}

/// Bytes of something the user picked or recorded (a blob address).
Future<Uint8List> readPath(String path) async {
  final response = await web.window.fetch(path.toJS).toDart;
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

int localFileSize(String path) => 0;

/// Redraws a photo so that nothing but pixels survives: EXIF, GPS position
/// and camera details are dropped, and very large photos are scaled down.
/// Returns JPEG bytes, or null if [bytes] is not an image.
Future<Uint8List?> stripAndCompressPhoto(Uint8List bytes) async {
  try {
    // The browser applies the EXIF rotation while decoding.
    final bitmap = await web.window
        .createImageBitmap(web.Blob([bytes.toJS].toJS))
        .toDart;
    var w = bitmap.width;
    var h = bitmap.height;
    const maxSide = 1920;
    if (w > maxSide || h > maxSide) {
      final scale = maxSide / (w > h ? w : h);
      w = (w * scale).round();
      h = (h * scale).round();
    }
    final canvas = web.HTMLCanvasElement()
      ..width = w
      ..height = h;
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(
      bitmap,
      0,
      0,
      w.toDouble(),
      h.toDouble(),
    );
    bitmap.close();
    final done = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? blob) => done.complete(blob)).toJS,
      'image/jpeg',
      0.82.toJS,
    );
    final blob = await done.future;
    if (blob == null) return null;
    return (await blob.arrayBuffer().toDart).toDart.asUint8List();
  } catch (_) {
    return null;
  }
}

/// A small square JPEG for a profile picture, cut from the middle of
/// [bytes]. Null if [bytes] is not an image.
Future<Uint8List?> avatarJpeg(Uint8List bytes) async {
  try {
    final bitmap = await web.window
        .createImageBitmap(web.Blob([bytes.toJS].toJS))
        .toDart;
    final side = bitmap.width < bitmap.height ? bitmap.width : bitmap.height;
    final canvas = web.HTMLCanvasElement()
      ..width = 320
      ..height = 320;
    (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(
      bitmap,
      (bitmap.width - side) / 2,
      (bitmap.height - side) / 2,
      side.toDouble(),
      side.toDouble(),
      0,
      0,
      320,
      320,
    );
    bitmap.close();
    final done = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? blob) => done.complete(blob)).toJS,
      'image/jpeg',
      0.84.toJS,
    );
    final blob = await done.future;
    if (blob == null) return null;
    return (await blob.arrayBuffer().toDart).toDart.asUint8List();
  } catch (_) {
    return null;
  }
}

// Recently shown attachments, so scrolling does not hit storage again.
final _bytes = <String, Future<Uint8List>>{};
final _urls = <String, Future<String>>{};

Future<Uint8List> _load(String path) {
  final hit = _bytes.remove(path);
  final value = hit ?? _store.read(path);
  _bytes[path] = value;
  if (_bytes.length > 24) _bytes.remove(_bytes.keys.first);
  return value;
}

Future<String> _blobUrl(String path, String mime) => _urls[path] ??= _store
    .read(path)
    .then(
      (data) => web.URL.createObjectURL(
        web.Blob([data.toJS].toJS, web.BlobPropertyBag(type: mime)),
      ),
    );

Widget localImage(
  String path, {
  BoxFit? fit,
  double? width,
  double? height,
  int? cacheWidth,
  ImageErrorWidgetBuilder? errorBuilder,
}) => FutureBuilder<Uint8List>(
  key: ValueKey(path),
  future: _load(path),
  builder: (context, snap) {
    if (snap.hasError) {
      return errorBuilder?.call(context, snap.error!, snap.stackTrace) ??
          const SizedBox.shrink();
    }
    if (!snap.hasData) {
      return SizedBox(width: width ?? 120, height: height ?? 120);
    }
    return Image.memory(
      snap.data!,
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: errorBuilder,
    );
  },
);

Future<VideoPlayerController> localVideo(
  String path,
  String mime, {
  bool mix = false,
}) async => VideoPlayerController.networkUrl(
  Uri.parse(await _blobUrl(path, mime)),
  videoPlayerOptions: VideoPlayerOptions(mixWithOthers: mix),
);

Future<Source> localAudio(String path, String mime) async =>
    UrlSource(await _blobUrl(path, mime), mimeType: mime);

/// Where a voice message is recorded to, and the format it comes out in.
/// Browsers record into memory; Safari and current Chrome produce AAC,
/// older Chrome and Firefox only Opus.
Future<(String, String)> voiceTarget() async => (
  '',
  web.MediaRecorder.isTypeSupported('audio/mp4') ? 'audio/mp4' : 'audio/webm',
);

/// Hands [bytes] to the browser as a download (or, on phones, to the
/// system's "save to files" sheet). Must run from a tap.
Future<bool> saveBytes(String name, Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body!.append(a);
  a.click();
  a.remove();
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  return true;
}

/// Lets the user choose a file and returns its bytes. Must run from a tap.
Future<Uint8List?> pickFileBytes() {
  final done = Completer<Uint8List?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..style.display = 'none';
  input.onchange = ((web.Event _) {
    final file = input.files?.item(0);
    input.remove();
    if (file == null) return done.complete(null);
    file.arrayBuffer().toDart.then(
      (buffer) => done.complete(buffer.toDart.asUint8List()),
      onError: (Object _) => done.complete(null),
    );
  }).toJS;
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      input.remove();
      if (!done.isCompleted) done.complete(null);
    }).toJS,
  );
  web.document.body!.append(input);
  input.click();
  return done.future;
}

/// A browser has no access to the address book.

/// Lets the user choose any file to send. Must run from a tap. Null if
/// they cancelled; throws [FileTooLarge] past [maxBytes].
Future<ChosenFile?> pickFileToSend(int maxBytes) async {
  final files = await _choose(multiple: false, folder: false);
  if (files == null || files.isEmpty) return null;
  final f = files.first;
  if (f.size > maxBytes) throw const FileTooLarge();
  return ChosenFile(
    (await f.arrayBuffer().toDart).toDart.asUint8List(),
    f.name,
    f.type.isEmpty ? 'application/octet-stream' : f.type,
  );
}

/// Browsers can hand over a whole folder.
bool get folderImportAvailable => true;

/// Lets the user choose a folder and returns its GIF, WebP and MP4 files
/// of at most [maxBytes] each. Must run from a tap.
Future<GifFolder?> pickGifFolder(int maxBytes) async {
  final files = await _choose(multiple: true, folder: true);
  if (files == null) return null;
  final out = <ChosenFile>[];
  var tooLarge = 0, other = 0;
  for (final f in files) {
    final name = f.name.toLowerCase();
    final mime = name.endsWith('.gif') || f.type == 'image/gif'
        ? 'image/gif'
        : name.endsWith('.webp') || f.type == 'image/webp'
        ? 'image/webp'
        : name.endsWith('.mp4') || f.type == 'video/mp4'
        ? 'video/mp4'
        : null;
    if (mime == null) {
      other++;
    } else if (f.size > maxBytes || out.length >= 200) {
      tooLarge++;
    } else {
      out.add(
        ChosenFile(
          (await f.arrayBuffer().toDart).toDart.asUint8List(),
          f.name,
          mime,
        ),
      );
    }
  }
  return GifFolder(out, tooLarge, other);
}

Future<List<web.File>?> _choose({
  required bool multiple,
  required bool folder,
}) {
  final done = Completer<List<web.File>?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = multiple
    ..style.display = 'none';
  if (folder) input.setAttribute('webkitdirectory', '');
  input.onchange = ((web.Event _) {
    final list = input.files;
    input.remove();
    done.complete([
      if (list != null)
        for (var i = 0; i < list.length; i++) list.item(i)!,
    ]);
  }).toJS;
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      input.remove();
      if (!done.isCompleted) done.complete(null);
    }).toJS,
  );
  web.document.body!.append(input);
  input.click();
  return done.future;
}

/// A browser cannot hand a file to another app; it downloads it instead.
Future<bool> openFile(String path, String name, String mime) async =>
    saveBytes(name, await readPath(path));
