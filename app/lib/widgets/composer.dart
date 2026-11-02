import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../media_prepare.dart';
import '../platform/host.dart';
import '../theme.dart';
import 'common.dart';
import '../screens/poll_create_screen.dart';
import 'buzz.dart';
import 'emoji_panel.dart';
import 'favorites_sheet.dart';

/// The floating message bar: text with @mention suggestions, attachments
/// and voice recording.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.state,
    required this.chat,
    this.replyTo,
    this.editing,
    required this.onClear,
  });
  final AppState state;
  final String chat;

  /// Message being answered, if any.
  final ChatMessage? replyTo;

  /// Own message being edited, if any.
  final ChatMessage? editing;

  /// Leaves reply/edit mode.
  final VoidCallback onClear;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _picker = ImagePicker();
  // Created on first use so the microphone plugin is not touched earlier.
  AudioRecorder? _rec;
  AudioRecorder get _recorder => _rec ??= AudioRecorder();
  bool _recording = false;
  String _voiceMime = 'audio/mp4';
  DateTime? _recordStart;
  Timer? _recordTick;
  bool _busy = false;

  /// The emoji keyboard is showing instead of the system keyboard.
  bool _emoji = false;

  Messenger get m => widget.state.messenger;
  bool get isGroup => widget.chat.startsWith('g:');

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      setState(() {});
      if (_input.text.trim().isNotEmpty && widget.editing == null) {
        m.sendTyping(widget.chat);
      }
    });
    // Tapping into the text brings the system keyboard back.
    _focus.addListener(() {
      if (_focus.hasFocus && _emoji) setState(() => _emoji = false);
    });
  }

  void _toggleEmoji() {
    if (_emoji) {
      setState(() => _emoji = false);
      _focus.requestFocus();
    } else {
      _focus.unfocus();
      setState(() => _emoji = true);
    }
  }

  Widget _quick(IconData icon, String tip, VoidCallback onTap) => IconButton(
    tooltip: tip,
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
    icon: Icon(icon, color: Brand.muted(context), size: 25),
  );

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    final e = widget.editing;
    if (e != null && e.id != old.editing?.id) {
      _input.value = TextEditingValue(
        text: e.body,
        selection: TextSelection.collapsed(offset: e.body.length),
      );
      _focus.requestFocus();
    } else if (e == null && old.editing != null) {
      _input.clear();
    } else if (widget.replyTo != null &&
        widget.replyTo?.id != old.replyTo?.id) {
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _recordTick?.cancel();
    _rec?.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---- mentions ----

  /// The partial "@word" right before the cursor, or null.
  ({int start, String query})? _mentionQuery() {
    final sel = _input.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final before = _input.text.substring(0, sel.start);
    final match = RegExp(r'(^|\s)@([A-Za-z0-9_]*)$').firstMatch(before);
    if (match == null) return null;
    return (
      start: sel.start - match[2]!.length - 1,
      query: match[2]!.toLowerCase(),
    );
  }

  List<Contact> _suggestions() {
    if (!isGroup) return const [];
    final q = _mentionQuery();
    if (q == null) return const [];
    final g = m.group(widget.chat.substring(2));
    if (g == null) return const [];
    return [
      for (final id in g.members)
        if (id != m.myIdentity)
          if (m.contact(id) case final c?
              when c.username != null &&
                  (c.username!.startsWith(q.query) ||
                      c.displayName.toLowerCase().contains(q.query)))
            c,
    ];
  }

  void _insertMention(Contact c) {
    final q = _mentionQuery();
    if (q == null) return;
    final text = _input.text;
    final cursor = _input.selection.start;
    final inserted = '@${c.username} ';
    _input.value = TextEditingValue(
      text: text.substring(0, q.start) + inserted + text.substring(cursor),
      selection: TextSelection.collapsed(offset: q.start + inserted.length),
    );
  }

  // ---- sending ----

  Future<void> _sendText() async {
    final text = _input.text;
    final editing = widget.editing;
    final replyTo = widget.replyTo;
    _input.clear();
    widget.onClear();
    if (editing != null) {
      await m.editMessage(editing, text);
    } else {
      await m.sendText(widget.chat, text, replyTo: replyTo);
    }
  }

  Future<void> _sendBytes(
    Uint8List data,
    String name,
    String kind,
    String mime, {
    int? durationMs,
  }) async {
    final limit = MediaTransfer.limits[kind]!;
    if (data.length > limit) {
      _toast('حجم فایل بیشتر از ${fileSize(limit)} است.');
      return;
    }
    await m.sendMedia(
      widget.chat,
      data,
      name: name,
      kind: kind,
      mime: mime,
      durationMs: durationMs,
    );
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final x = await _picker.pickImage(source: source);
    if (x == null) return;
    setState(() => _busy = true);
    try {
      // Location and camera metadata never leave the device.
      final clean = await stripAndCompressPhoto(await x.readAsBytes());
      if (clean == null) {
        _toast('این فایل تصویر نیست.');
        return;
      }
      await _sendBytes(clean, 'photo.jpg', 'image', 'image/jpeg');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A GIF straight from the gallery. Clips (MP4) count too: that is the
  /// form GIFs take when saved from Telegram and similar apps.
  Future<void> _pickGif() async {
    final x = await _picker.pickMedia();
    if (x == null) return;
    final mime = mimeForName(x.name);
    if (mime != 'image/gif' &&
        mime != 'image/webp' &&
        !mime.startsWith('video/')) {
      _toast('فقط فایل GIF یا کلیپ کوتاه قابل ارسال است.');
      return;
    }
    await _sendBytes(await x.readAsBytes(), x.name, 'gif', mime);
  }

  /// Any kind of file, up to the size the server accepts.
  Future<void> _pickFile() async {
    final ChosenFile? f;
    try {
      f = await pickFileToSend(MediaTransfer.limits['file']!);
    } on FileTooLarge {
      _toast('حجم فایل بیشتر از ۴۰ مگابایت است.');
      return;
    } catch (_) {
      _toast('خواندن فایل انجام نشد.');
      return;
    }
    if (f == null) return;
    await _sendBytes(f.bytes, f.name, 'file', f.mime);
  }

  Future<void> _pickVideo(ImageSource source) async {
    final x = await _picker.pickVideo(
      source: source,
      maxDuration: const Duration(minutes: 3),
    );
    if (x == null) return;
    await _sendBytes(
      await x.readAsBytes(),
      x.name,
      'video',
      mimeForName(x.name),
    );
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      final path = await _recorder.stop();
      final ms = DateTime.now().difference(_recordStart!).inMilliseconds;
      _recordTick?.cancel();
      setState(() => _recording = false);
      if (path == null || ms < 700) return;
      await _sendBytes(
        await readPath(path),
        _voiceMime == 'audio/mp4' ? 'voice.m4a' : 'voice.webm',
        'voice',
        _voiceMime,
        durationMs: ms,
      );
      return;
    }
    if (!await _recorder.hasPermission()) {
      _toast('برای ضبط صدا، اجازه میکروفون لازم است.');
      return;
    }
    final (target, mime) = await voiceTarget();
    _voiceMime = mime;
    await _recorder.start(
      RecordConfig(
        encoder: mime == 'audio/mp4' ? AudioEncoder.aacLc : AudioEncoder.opus,
        bitRate: 32000,
        sampleRate: isWebApp ? 44100 : 22050,
        numChannels: 1,
      ),
      path: target,
    );
    _recordStart = DateTime.now();
    _recordTick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
    setState(() => _recording = true);
  }

  Future<void> _cancelRecord() async {
    await _recorder.cancel();
    _recordTick?.cancel();
    setState(() => _recording = false);
  }

  void _poll() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PollCreateScreen(state: widget.state, chat: widget.chat),
    ),
  );

  /// Shakes the other side's chat; once every five minutes per chat.
  Future<void> _buzz() async {
    final wait = m.buzzWait(widget.chat);
    if (wait > 0) {
      final min = (wait / 60).ceil();
      _toast(
        min > 1
            ? fa('BUZZ هر ۵ دقیقه یک بار؛ $min دقیقه دیگر دوباره امتحان کنید.')
            : 'BUZZ هر ۵ دقیقه یک بار؛ کمتر از یک دقیقه دیگر امتحان کنید.',
      );
      return;
    }
    if (await m.sendBuzz(widget.chat) && mounted) BuzzShaker.shakeOf(context);
  }

  void _attach() {
    Widget item(
      IconData icon,
      String label,
      List<Color> colors,
      VoidCallback run,
    ) => InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.pop(context);
        run();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: colors,
                ),
                boxShadow: Brand.shadow(context, strength: 0.8),
              ),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
      ),
    );
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            childAspectRatio: 1.15,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              item(
                Icons.photo_rounded,
                'عکس از گالری',
                const [Color(0xFF7C8CF8), Color(0xFF5661D8)],
                () => _pickPhoto(ImageSource.gallery),
              ),
              item(
                Icons.photo_camera_rounded,
                'دوربین',
                const [Color(0xFFFF8A65), Color(0xFFE5533D)],
                () => _pickPhoto(ImageSource.camera),
              ),
              item(
                Icons.videocam_rounded,
                'ویدیو',
                const [Color(0xFFE879A6), Color(0xFFC2447C)],
                () => _pickVideo(ImageSource.gallery),
              ),
              item(
                Icons.video_call_rounded,
                'ضبط ویدیو',
                const [Color(0xFF5BB8F0), Color(0xFF2B86C9)],
                () => _pickVideo(ImageSource.camera),
              ),
              item(
                Icons.gif_box_rounded,
                'گیف‌های من',
                const [Color(0xFFF7B955), Color(0xFFE08B1F)],
                () => FavoritesSheet.show(context, widget.state, widget.chat),
              ),
              item(Icons.photo_library_rounded, 'گیف از گالری', const [
                Color(0xFF4FC3A1),
                Color(0xFF1E9E86),
              ], _pickGif),
              item(Icons.insert_drive_file_rounded, 'فایل', const [
                Color(0xFF8E9BB0),
                Color(0xFF5D6B82),
              ], _pickFile),
              item(Icons.poll_rounded, 'نظرسنجی', const [
                Color(0xFF4FD1A8),
                Color(0xFF169C82),
              ], _poll),
              item(Icons.vibration_rounded, 'BUZZ', const [
                Color(0xFFFFB25B),
                Color(0xFFE5701A),
              ], _buzz),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_recording) {
      final ms = DateTime.now().difference(_recordStart!).inMilliseconds;
      return Row(
        children: [
          IconButton(
            tooltip: 'لغو',
            onPressed: _cancelRecord,
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
          ),
          Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
          const SizedBox(width: 8),
          Expanded(child: Text('در حال ضبط  ${duration(ms)}')),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          tooltip: 'پیوست',
          onPressed: _busy ? null : _attach,
          icon: Icon(
            Icons.add_circle_outline_rounded,
            color: Brand.muted(context),
            size: 27,
          ),
        ),
        Expanded(
          child: TextField(
            controller: _input,
            focusNode: _focus,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: 'پیام',
              filled: false,
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 13),
            ),
          ),
        ),
        // At the far (left) end of the box: the user's saved GIFs, sent as
        // their own message, and emoji, added to the text.
        _quick(
          Icons.gif_box_outlined,
          'گیف‌های من',
          () => FavoritesSheet.show(
            context,
            widget.state,
            widget.chat,
            start: 'gif',
          ),
        ),
        _quick(
          _emoji ? Icons.keyboard_alt_outlined : Icons.emoji_emotions_outlined,
          _emoji ? 'صفحه‌کلید' : 'شکلک',
          _toggleEmoji,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _input.text.trim().isNotEmpty;
    final suggestions = _suggestions();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (widget.replyTo != null || widget.editing != null)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: Brand.raised(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Brand.hairline(context)),
              boxShadow: Brand.shadow(context, strength: 0.8),
            ),
            child: Row(
              children: [
                Icon(
                  widget.editing != null
                      ? Icons.edit_rounded
                      : Icons.reply_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.editing != null
                            ? 'ویرایش پیام'
                            : 'پاسخ به ${m.nameOf(widget.replyTo!.sender)}',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      Text(
                        m.previewOf(widget.editing ?? widget.replyTo!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Brand.muted(context),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'لغو',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClear,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            constraints: const BoxConstraints(maxHeight: 190),
            decoration: BoxDecoration(
              color: Brand.raised(context),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Brand.hairline(context)),
              boxShadow: Brand.shadow(context, strength: 1.2),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final c in suggestions)
                    ListTile(
                      dense: true,
                      leading: Avatar(c.displayName, size: 34),
                      title: Text(c.displayName),
                      trailing: Text(
                        '@${c.username}',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      onTap: () => _insertMention(c),
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
          // Send sits on the right (first child, as the app is right-to-left).
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // The send arrow is mirrored automatically in a right-to-left
              // layout; users expect it to point the original way.
              Directionality(
                textDirection: TextDirection.ltr,
                child: GradientIconButton(
                  icon: hasText || _recording
                      ? Icons.send_rounded
                      : Icons.mic_rounded,
                  tooltip: hasText || _recording ? 'ارسال' : 'ضبط صدا',
                  onPressed: hasText ? _sendText : _toggleRecord,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.only(left: 2, right: 2),
                  constraints: const BoxConstraints(minHeight: 50),
                  decoration: BoxDecoration(
                    color: Brand.raised(context),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: Brand.hairline(context)),
                    boxShadow: Brand.shadow(context),
                  ),
                  alignment: Alignment.center,
                  child: _bar(context),
                ),
              ),
            ],
          ),
        ),
        // Back closes the emoji keyboard before it leaves the chat.
        PopScope(
          canPop: !_emoji,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _emoji = false);
          },
          child: _emoji
              ? EmojiPanel(controller: _input)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
