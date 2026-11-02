import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'chat_screen.dart';

/// Receives what other apps share with IRAN Messenger through Android's
/// share sheet and opens the "send to" screen.
class ShareIntake {
  static const _channel = MethodChannel('irm/share');

  static void init(GlobalKey<NavigatorState> nav, AppState state) {
    if (!shareIntakeAvailable) return;
    void open(Object? raw, Duration wait) {
      if (raw is! Map) return;
      final item = raw.cast<String, dynamic>();
      // Wait for the intro to finish on a cold start.
      Future<void>.delayed(wait, () {
        final m = state.messenger;
        if (!m.isRegistered || m.isPending) return;
        nav.currentState?.push(
          MaterialPageRoute(
            builder: (_) => ShareScreen(state: state, item: item),
          ),
        );
      });
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') open(call.arguments, Duration.zero);
    });
    _channel
        .invokeMethod<Object?>('take')
        .then((v) => open(v, const Duration(milliseconds: 3700)))
        .catchError((Object _) {});
  }
}

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.state, required this.item});
  final AppState state;

  /// `{text}` or `{path, mime}` or `{error}`.
  final Map<String, dynamic> item;

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  bool _busy = false;
  late bool _asGif;

  Messenger get m => widget.state.messenger;
  String? get _text => widget.item['text'] as String?;
  String? get _path => widget.item['path'] as String?;
  String get _mime => '${widget.item['mime'] ?? ''}';
  int get _size => _path == null ? 0 : localFileSize(_path!);
  String get _name => _path!.substring(_path!.lastIndexOf('/') + 1);

  /// GIFs, and short clips (the form GIFs take when shared from Telegram).
  bool get _gifCapable =>
      _path != null &&
      (_mime == 'image/gif' ||
          _mime == 'image/webp' ||
          (_mime.startsWith('video/') &&
              _size <= MediaTransfer.limits['gif']!));

  @override
  void initState() {
    super.initState();
    _asGif = _gifCapable;
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _send(String chat) async {
    setState(() => _busy = true);
    try {
      if (_text != null) {
        await m.sendText(chat, _text!);
      } else if (_path != null) {
        final data = await readPath(_path!);
        if (_asGif) {
          await m.sendMedia(chat, data, name: _name, kind: 'gif', mime: _mime);
        } else if (_mime.startsWith('video/')) {
          if (_size > MediaTransfer.limits['video']!) {
            _toast('این ویدیو برای ارسال بزرگ است.');
            return;
          }
          await m.sendMedia(
            chat,
            data,
            name: _name,
            kind: 'video',
            mime: _mime,
          );
        } else if (_mime.startsWith('image/')) {
          // Location and camera details are removed before sending.
          final clean = await stripAndCompressPhoto(data);
          if (clean == null) {
            _toast('این فایل تصویر نیست.');
            return;
          }
          await m.sendMedia(
            chat,
            clean,
            name: 'photo.jpg',
            kind: 'image',
            mime: 'image/jpeg',
          );
        } else {
          _toast('این نوع فایل پشتیبانی نمی‌شود.');
          return;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(state: widget.state, chat: chat),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final added = await m.addFavorite(
      await readPath(_path!),
      name: _name,
      kind: 'gif',
      mime: _mime,
    );
    _toast(added ? 'به «گیف‌های من» اضافه شد.' : 'قبلا ذخیره شده بود.');
  }

  @override
  Widget build(BuildContext context) {
    final failed =
        widget.item['error'] != null || (_text == null && _path == null);
    final chats = m.chats();
    final listed = {for (final c in chats) c.chat};
    final others = [
      for (final c in m.contacts())
        if (!listed.contains('u:${c.identityId}')) c,
    ];
    final what = _text != null
        ? 'متن'
        : _mime.startsWith('video/')
        ? (_asGif ? 'گیف' : 'ویدیو')
        : _mime == 'image/gif'
        ? 'گیف'
        : 'عکس';

    return Scaffold(
      appBar: AppBar(title: const Text('ارسال به…')),
      body: failed
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'این مورد قابل دریافت نبود؛ ممکن است حجمش بیش از حد مجاز باشد.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 3),
                Panel(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          BrandLottie(
                            'send',
                            size: 44,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _text != null
                                  ? _text!
                                  : '$what · ${fileSize(_size)}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_gifCapable) ...[
                        if (_mime.startsWith('video/'))
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                              'ارسال به‌صورت گیف (بی‌صدا و تکرارشونده)',
                            ),
                            value: _asGif,
                            onChanged: (v) => setState(() => _asGif = v),
                          ),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.bookmark_add_rounded),
                          label: const Text('ذخیره در «گیف‌های من»'),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 20),
                    children: [
                      if (chats.isEmpty && others.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text(
                            'هنوز گفتگویی ندارید که چیزی برایش بفرستید.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Brand.muted(context)),
                          ),
                        ),
                      for (final c in chats)
                        Panel(
                          margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          onTap: _busy ? null : () => _send(c.chat),
                          child: Row(
                            children: [
                              Avatar(c.title, group: c.isGroup, size: 44),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15.5),
                                ),
                              ),
                              Icon(
                                Icons.send_rounded,
                                size: 18,
                                color: Brand.muted(context),
                              ),
                            ],
                          ),
                        ),
                      for (final c in others)
                        Panel(
                          margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          onTap: _busy
                              ? null
                              : () => _send('u:${c.identityId}'),
                          child: Row(
                            children: [
                              Avatar(c.displayName, size: 44),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  c.displayName,
                                  style: const TextStyle(fontSize: 15.5),
                                ),
                              ),
                              Icon(
                                Icons.send_rounded,
                                size: 18,
                                color: Brand.muted(context),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
