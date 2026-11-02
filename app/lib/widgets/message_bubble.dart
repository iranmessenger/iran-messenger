import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'buzz.dart';
import 'media_view.dart';
import 'message_text.dart';
import 'poll_view.dart';
import 'reaction_bar.dart';

/// Centered pill used for dates and group events.
class ChatChip extends StatelessWidget {
  const ChatChip(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: Brand.raised(context).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(14),
            boxShadow: Brand.shadow(context, strength: 0.5),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Brand.muted(context),
            ),
          ),
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.state,
    required this.message,
    required this.showSender,
    required this.tail,
    this.onMention,
    this.onMenu,
    this.onReact,
  });

  /// Tapping an existing reaction chip toggles the same emoji for me.
  final void Function(String emoji)? onReact;

  final AppState state;
  final ChatMessage message;

  /// Show the sender's name (first message of a run in a group).
  final bool showSender;

  /// Last message of a run from the same sender: gets the pointed corner.
  final bool tail;
  final void Function(String username)? onMention;

  /// Opens the message's menu next to the bubble (tap or long press).
  final void Function(Rect bubble)? onMenu;

  String _errorText(String? code) => switch (code) {
    'identity_changed' =>
      'کلید امنیتی مخاطب عوض شده است. از منوی گفتگو هویت را دوباره تایید کنید.',
    'media_too_large' => 'حجم فایل از سقف مجاز بیشتر است.',
    'media_missing' => 'فایل روی دستگاه پیدا نشد.',
    'irm_media_quota' => 'سهمیه رسانه روی سرور پر است.',
    _ => 'ارسال نشد (${code ?? ''})',
  };

  /// Body text with @mentions and web links emphasised and tappable.
  InlineSpan _rich(BuildContext context, String text, Color fg) =>
      richMessageText(
        context,
        text: text,
        color: fg,
        accent: message.outgoing
            ? (Brand.dark(context) ? const Color(0xFFFFE08A) : Colors.white)
            : Theme.of(context).colorScheme.primary,
        onMention: onMention,
      );

  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m.kind == 'system') return ChatChip(m.body);
    if (m.kind == 'buzz') return BuzzChip(state: state, message: m);

    final scheme = Theme.of(context).colorScheme;
    final mine = m.outgoing;
    final bare = m.media?.kind == 'sticker';
    final fg = mine ? Brand.onBubbleOut(context) : scheme.onSurface;
    final meta = fg.withValues(alpha: 0.62);

    Widget content;
    if (m.status == MsgStatus.undecryptable) {
      content = Text(
        'این پیام قابل رمزگشایی نبود.',
        style: TextStyle(color: fg, fontStyle: FontStyle.italic),
      );
    } else if (m.kind == 'media') {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File names and sizes take the bubble's own text colour.
          DefaultTextStyle.merge(
            style: TextStyle(color: fg),
            child: MediaView(state: state, message: m),
          ),
          if (mine && m.status == MsgStatus.pending)
            UploadProgress(state: state, message: m, color: fg),
          if (m.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text.rich(_rich(context, m.body, fg)),
            ),
        ],
      );
    } else if (m.kind == 'poll' && m.poll != null) {
      content = PollView(state: state, message: m, color: fg);
    } else {
      content = Text.rich(_rich(context, m.body, fg));
    }

    final status = !mine
        ? null
        : switch (m.status) {
            MsgStatus.pending => Icons.schedule_rounded,
            MsgStatus.sent => Icons.check_rounded,
            MsgStatus.delivered => Icons.done_all_rounded,
            MsgStatus.read => Icons.done_all_rounded,
            _ => Icons.error_outline_rounded,
          };

    // Own messages sit on the right, others on the left (physical sides,
    // independent of text direction); the pointed corner faces outward.
    const big = Radius.circular(18);
    const small = Radius.circular(5);
    final radius = BorderRadius.only(
      topLeft: big,
      topRight: big,
      bottomLeft: !mine && tail ? small : big,
      bottomRight: mine && tail ? small : big,
    );

    final hasImage =
        m.kind == 'media' &&
        (m.media?.kind == 'image' || m.media?.kind == 'gif');

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Column(
          crossAxisAlignment: mine
              // The app is right-to-left, so "start" is the right edge.
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(
              builder: (bubble) {
                void open() {
                  final box = bubble.findRenderObject() as RenderBox?;
                  if (box == null || onMenu == null) return;
                  onMenu!(box.localToGlobal(Offset.zero) & box.size);
                }

                return GestureDetector(
                  onTap: onMenu == null ? null : open,
                  onLongPress: onMenu == null ? null : open,
                  child: Container(
                    margin: EdgeInsets.only(
                      top: 2,
                      bottom: reactionGroups(m).isNotEmpty ? 0 : (tail ? 7 : 2),
                      left: 10,
                      right: 10,
                    ),
                    padding: bare
                        ? EdgeInsets.zero
                        : hasImage
                        ? const EdgeInsets.all(5)
                        : const EdgeInsets.fromLTRB(13, 8, 13, 7),
                    decoration: bare
                        ? null
                        : BoxDecoration(
                            color: mine ? null : Brand.bubbleIn(context),
                            gradient: mine ? Brand.bubbleOut(context) : null,
                            borderRadius: radius,
                            border: Border.all(color: Brand.hairline(context)),
                            boxShadow: Brand.shadow(context, strength: 0.75),
                          ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showSender && !mine)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: 3,
                              right: hasImage ? 8 : 0,
                              top: hasImage ? 3 : 0,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    state.messenger.nameOf(m.sender),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Brand.avatar(
                                        state.messenger.nameOf(m.sender),
                                      ).colors.last,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                if (state.messenger.isBot(m.sender))
                                  const BotBadge(size: 10),
                              ],
                            ),
                          ),
                        if (m.reply != null)
                          Container(
                            margin: EdgeInsets.only(
                              bottom: 5,
                              left: hasImage ? 6 : 0,
                              right: hasImage ? 6 : 0,
                              top: hasImage ? 4 : 0,
                            ),
                            padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
                            decoration: BoxDecoration(
                              color: fg.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(9),
                              border: BorderDirectional(
                                start: BorderSide(
                                  color: mine
                                      ? fg.withValues(alpha: 0.7)
                                      : scheme.primary,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  state.messenger.nameOf(m.reply!.sender),
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: mine ? fg : scheme.primary,
                                  ),
                                ),
                                Text(
                                  isolateMentions(m.reply!.preview),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, color: meta),
                                ),
                              ],
                            ),
                          ),
                        content,
                        Padding(
                          padding: EdgeInsets.only(
                            top: 3,
                            left: hasImage ? 6 : 0,
                            right: hasImage ? 6 : 0,
                            bottom: hasImage ? 2 : 0,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (m.edited) ...[
                                Text(
                                  'ویرایش‌شده',
                                  style: TextStyle(fontSize: 10.5, color: meta),
                                ),
                                const SizedBox(width: 5),
                              ],
                              Text(
                                clock(m.createdAt),
                                style: TextStyle(fontSize: 11, color: meta),
                              ),
                              if (status != null) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  status,
                                  size: 15,
                                  color: m.status == MsgStatus.failed
                                      ? scheme.error
                                      : m.status == MsgStatus.read
                                      ? Brand.readTick(context)
                                      : meta,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (mine && m.status == MsgStatus.failed)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: InkWell(
                              onTap: () => state.messenger.retry(m.id),
                              child: Text(
                                '${_errorText(m.error)} — تلاش دوباره',
                                style: TextStyle(
                                  color: scheme.error,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (reactionGroups(m).isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, tail ? 7 : 3),
                child: Transform.translate(
                  offset: const Offset(0, -3),
                  child: ReactionBar(
                    state: state,
                    message: m,
                    onToggle: onReact,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
