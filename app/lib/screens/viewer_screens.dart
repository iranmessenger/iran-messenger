import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../platform/host.dart';

class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(maxScale: 5, child: localImage(path)),
      ),
    );
  }
}

class VideoViewerScreen extends StatefulWidget {
  const VideoViewerScreen({super.key, required this.path, required this.mime});
  final String path;
  final String mime;

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  VideoPlayerController? _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = await localVideo(widget.path, widget.mime);
      if (!mounted) return c.dispose();
      _c = c;
      c.addListener(() {
        if (mounted) setState(() {});
      });
      await c.initialize();
      if (!mounted) return;
      setState(() {});
      await c.play();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _error != null
            ? const Text(
                'این ویدیو روی این دستگاه قابل پخش نیست.',
                style: TextStyle(color: Colors.white),
              )
            : c == null || !c.value.isInitialized
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: VideoPlayer(c),
                    ),
                  ),
                  VideoProgressIndicator(c, allowScrubbing: true),
                  IconButton(
                    color: Colors.white,
                    iconSize: 40,
                    icon: Icon(
                      c.value.isPlaying
                          ? Icons.pause_circle
                          : Icons.play_circle,
                    ),
                    onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
                  ),
                ],
              ),
      ),
    );
  }
}
