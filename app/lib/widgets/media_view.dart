import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../screens/viewer_screens.dart';
import '../theme.dart';
import 'common.dart';
import 'favorites_sheet.dart';

/// Renders an attachment, downloading and decrypting it on demand.
class MediaView extends StatefulWidget {
  const MediaView({super.key, required this.state, required this.message});
  final AppState state;
  final ChatMessage message;

  @override
  State<MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<MediaView> {
  static final _inFlight = <int>{};
  String? _problem;

  MediaInfo get info => widget.message.media!;
  bool get _hasFile =>
      info.path != null && widget.state.messenger.files.existsSync(info.path!);

  @override
  void initState() {
    super.initState();
    // Small items load by themselves; large ones wait for a tap.
    final auto = info.kind != 'video' && info.size <= 2 * 1024 * 1024;
    if (!_hasFile && auto && widget.message.error == null) _download();
  }

  Future<void> _download() async {
    final id = widget.message.id;
    if (_inFlight.contains(id)) return;
    _inFlight.add(id);
    if (mounted) setState(() => _problem = null);
    try {
      final f = await widget.state.messenger.media.download(id);
      if (f == null && mounted) setState(() => _problem = 'expired');
    } catch (_) {
      if (mounted) setState(() => _problem = 'failed');
    } finally {
      _inFlight.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_hasFile) {
      final expired =
          _problem == 'expired' || widget.message.error == 'media_expired';
      final busy = _inFlight.contains(widget.message.id);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: _fraction(
                  widget.state.messenger.media.progress(widget.message.id),
                ),
              ),
            )
          else if (expired)
            Icon(Icons.cloud_off, color: scheme.outline)
          else
            IconButton.filledTonal(
              onPressed: _download,
              icon: const Icon(Icons.download),
            ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              expired
                  ? 'فایل دیگر روی سرور موجود نیست؛ از فرستنده بخواهید دوباره بفرستد.'
                  : _problem == 'failed'
                  ? 'دریافت ناموفق بود. دوباره امتحان کنید.'
                  : busy
                  ? _amount(
                      widget.state.messenger.media.progress(widget.message.id),
                      info.size,
                    )
                  : '${info.kind == 'file' ? info.name : _label(info.kind)} · ${fileSize(info.size)}',
            ),
          ),
        ],
      );
    }

    final path = info.path!;
    switch (info.kind) {
      case 'gif' when info.mime.startsWith('video/'):
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280, maxWidth: 260),
            child: LoopingVideo(path: path, mime: info.mime),
          ),
        );
      case 'image':
      case 'gif':
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ImageViewerScreen(path: path)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: localImage(
                path,
                fit: BoxFit.cover,
                cacheWidth: info.kind == 'gif' ? null : 900,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
              ),
            ),
          ),
        );
      case 'sticker':
        return localImage(
          path,
          width: 150,
          height: 150,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        );
      case 'voice':
        return VoicePlayer(
          path: path,
          mime: info.mime,
          durationMs: info.durationMs,
        );
      case 'video':
        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VideoViewerScreen(path: path, mime: info.mime),
            ),
          ),
          child: Container(
            width: 220,
            height: 130,
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.play_circle_outline,
                  color: Colors.white,
                  size: 48,
                ),
                Text(
                  fileSize(info.size),
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        );
      default:
        return FileTile(
          name: info.name,
          size: info.size,
          mime: info.mime,
          path: path,
          accent: widget.message.outgoing ? Colors.white : null,
        );
    }
  }

  String _label(String kind) => switch (kind) {
    'image' => 'عکس',
    'video' => 'ویدیو',
    'voice' => 'پیام صوتی',
    'gif' => 'GIF',
    'sticker' => 'استیکر',
    _ => 'فایل',
  };
}

class VoicePlayer extends StatefulWidget {
  const VoicePlayer({
    super.key,
    required this.path,
    required this.mime,
    this.durationMs,
  });
  final String path;
  final String mime;
  final int? durationMs;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<dynamic>>[];
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration? _total;

  @override
  void initState() {
    super.initState();
    if (widget.durationMs != null) {
      _total = Duration(milliseconds: widget.durationMs!);
    }
    _subs.add(
      _player.onPositionChanged.listen(
        (p) => mounted ? setState(() => _pos = p) : null,
      ),
    );
    _subs.add(
      _player.onDurationChanged.listen(
        (d) => mounted ? setState(() => _total = d) : null,
      ),
    );
    _subs.add(
      _player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playing = false;
            _pos = Duration.zero;
          });
        }
      }),
    );
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play(await localAudio(widget.path, widget.mime));
    }
    if (mounted) setState(() => _playing = !_playing);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _total?.inMilliseconds ?? 0;
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          IconButton.filledTonal(
            onPressed: _toggle,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LinearProgressIndicator(
              value: total == 0
                  ? 0
                  : (_pos.inMilliseconds / total).clamp(0, 1).toDouble(),
            ),
          ),
          const SizedBox(width: 8),
          Text(duration(_playing ? _pos.inMilliseconds : total)),
        ],
      ),
    );
  }
}

/// A sent or received document: its kind, name and size. A tap opens it
/// in another app (on a phone) or downloads it (in a browser).
class FileTile extends StatelessWidget {
  const FileTile({
    super.key,
    required this.name,
    required this.size,
    required this.mime,
    required this.path,
    this.accent,
  });
  final String name;
  final int size;
  final String mime;
  final String path;

  /// Colour of the type icon; white on own (blue) bubbles.
  final Color? accent;

  static IconData iconFor(String name, String mime) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (ext == 'pdf' || mime == 'application/pdf') {
      return Icons.picture_as_pdf_rounded;
    }
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) {
      return Icons.folder_zip_rounded;
    }
    if (const {'doc', 'docx', 'txt', 'rtf', 'odt'}.contains(ext)) {
      return Icons.description_rounded;
    }
    if (const {'xls', 'xlsx', 'csv', 'ods'}.contains(ext)) {
      return Icons.table_chart_rounded;
    }
    if (const {'ppt', 'pptx', 'odp'}.contains(ext)) {
      return Icons.slideshow_rounded;
    }
    if (ext == 'apk') return Icons.android_rounded;
    if (mime.startsWith('audio/')) return Icons.audio_file_rounded;
    if (mime.startsWith('image/')) return Icons.image_rounded;
    if (mime.startsWith('video/')) return Icons.video_file_rounded;
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        if (!await openFile(path, name, mime)) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('برنامه‌ای برای باز کردن این فایل پیدا نشد.'),
            ),
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: accent == null ? 0.16 : 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(iconFor(name, mime), color: tint),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    fileSize(size),
                    // Readable on own (blue) and others' bubbles alike.
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          (DefaultTextStyle.of(context).style.color ??
                                  Brand.muted(context))
                              .withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Share of a transfer that is done, or null while it is being prepared.
double? _fraction((int, int)? p) =>
    p == null || p.$2 == 0 ? null : (p.$1 / p.$2).clamp(0.0, 1.0);

/// "۱۲٫۳ از ۴۰ مگابایت · ۳۱٪", or what is happening before bytes move.
String _amount((int, int)? p, int size) {
  final f = _fraction(p);
  if (f == null) return 'در حال آماده‌سازی… ${fileSize(size)}';
  return '${fileSize(p!.$1)} از ${fileSize(p.$2)} · ${fa((f * 100).round())}٪';
}

/// Under an attachment that is still on its way: how much has been sent,
/// or that it waits for a connection.
class UploadProgress extends StatelessWidget {
  const UploadProgress({
    super.key,
    required this.state,
    required this.message,
    required this.color,
  });
  final AppState state;
  final ChatMessage message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = state.messenger.media.progress(message.id);
    final size = message.media?.size ?? 0;
    final text = p == null
        ? 'در صف ارسال · ${fileSize(size)}'
        : 'در حال ارسال: ${_amount(p, size)}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 5,
                // Waiting in the queue shows an empty bar, not motion.
                value: p == null ? 0 : _fraction(p),
                color: color,
                backgroundColor: color.withValues(alpha: 0.22),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                color: color.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
