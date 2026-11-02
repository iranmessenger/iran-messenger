import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'forward_sheet.dart';
import 'reaction_bar.dart';
import 'motion.dart';

/// Reactions offered at the top of a message's menu.
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥'];

/// The compact menu of one message, opened next to it with a tap: a row
/// of reactions, who has seen it (own messages), then the actions.
void showMessageMenu(
  BuildContext context,
  AppState state,
  ChatMessage msg, {
  required Rect anchor,
  required bool isGroup,
  required VoidCallback onReply,
  required VoidCallback onEdit,
}) {
  final m = state.messenger;
  final toast = ScaffoldMessenger.of(context);
  final error = Theme.of(context).colorScheme.error;
  final delivered =
      msg.clientMsgId != null &&
      (msg.status == MsgStatus.sent ||
          msg.status == MsgStatus.delivered ||
          msg.status == MsgStatus.read);

  final items = <_Item>[
    if (msg.clientMsgId != null && msg.status != MsgStatus.failed)
      _Item(Icons.reply_rounded, 'پاسخ', onReply),
    if (msg.body.isNotEmpty)
      _Item(
        Icons.copy_rounded,
        'کپی',
        () => Clipboard.setData(ClipboardData(text: msg.body)),
      ),
    if (msg.kind == 'media' &&
        msg.media != null &&
        msg.status != MsgStatus.undecryptable)
      _Item(
        Icons.download_rounded,
        'ذخیره در گوشی',
        () => saveAttachment(context, state, msg),
      ),
    if ((msg.kind == 'text' || msg.kind == 'media') &&
        msg.status != MsgStatus.undecryptable &&
        msg.status != MsgStatus.failed)
      _Item(
        Icons.forward_rounded,
        'هدایت به گفتگوی دیگر',
        () => showForwardSheet(context, state, msg),
      ),
    if (msg.outgoing && msg.kind == 'text' && delivered)
      _Item(Icons.edit_rounded, 'ویرایش', onEdit),
    if ((msg.media?.kind == 'gif' || msg.media?.kind == 'sticker') &&
        msg.media?.path != null)
      _Item(Icons.bookmark_add_rounded, 'افزودن به ذخیره‌ها', () async {
        final added = await m.addFavoriteFromMessage(msg);
        toast.showSnackBar(
          SnackBar(
            content: Text(
              added ? 'به ذخیره‌های شما اضافه شد.' : 'قبلا ذخیره شده بود.',
            ),
          ),
        );
      }),
    if (reactionGroups(msg).isNotEmpty)
      _Item(
        Icons.emoji_emotions_outlined,
        'واکنش‌ها',
        () => showReactors(context, state, msg),
      ),
    if (msg.outgoing && msg.status == MsgStatus.failed)
      _Item(Icons.refresh_rounded, 'تلاش دوباره', () => m.retry(msg.id)),
    _Item(
      Icons.delete_outline_rounded,
      'حذف',
      () => confirmDeleteMessage(context, state, msg),
      color: error,
    ),
  ];
  // Nobody reacts to their own message.
  final canReact =
      !msg.outgoing &&
      msg.kind != 'buzz' &&
      msg.clientMsgId != null &&
      msg.status != MsgStatus.failed &&
      msg.status != MsgStatus.pending;
  final showSeen = msg.outgoing && delivered;

  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'بستن',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialog, _, _) => _MenuLayout(
      anchor: anchor,
      mine: msg.outgoing,
      reactions: canReact
          ? _Reactions(
              current: msg.reactions['${m.myIdentity}'],
              onPick: (e) {
                Navigator.pop(dialog);
                m.react(msg, e);
              },
            )
          : null,
      panel: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: msg.outgoing
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          if (showSeen) ...[
            _SeenBy(state: state, msg: msg, isGroup: isGroup),
            const SizedBox(height: 8),
          ],
          _Actions(
            items: items,
            onPick: (item) {
              Navigator.pop(dialog);
              item.run();
            },
          ),
        ],
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curve),
          alignment: msg.outgoing ? Alignment.topRight : Alignment.topLeft,
          child: child,
        ),
      );
    },
  );
}

class _Item {
  _Item(this.icon, this.label, this.run, {this.color});
  final IconData icon;
  final String label;
  final VoidCallback run;
  final Color? color;
}

/// Puts the reactions just above the message and the rest just below
/// it, so the message itself stays visible. When there is no room below,
/// both go above it. Everything stays on the message's own side.
class _MenuLayout extends StatelessWidget {
  const _MenuLayout({
    required this.anchor,
    required this.mine,
    required this.reactions,
    required this.panel,
  });
  final Rect anchor;
  final bool mine;
  final Widget? reactions;
  final Widget panel;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: CustomMultiChildLayout(
        delegate: _MenuPlacement(anchor, mine, MediaQuery.paddingOf(context)),
        children: [
          if (reactions != null) LayoutId(id: #reactions, child: reactions!),
          LayoutId(id: #panel, child: panel),
        ],
      ),
    );
  }
}

class _MenuPlacement extends MultiChildLayoutDelegate {
  _MenuPlacement(this.anchor, this.mine, this.safe);
  final Rect anchor;
  final bool mine;
  final EdgeInsets safe;

  static const gap = 8.0;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(
      Size(size.width - 24, size.height - safe.vertical - 24),
    );
    final top = safe.top + 12;
    final bottom = size.height - safe.bottom - 12;
    final p = layoutChild(#panel, loose);
    final r = hasChild(#reactions) ? layoutChild(#reactions, loose) : null;
    final rh = r == null ? 0.0 : r.height + gap;

    double side(Size child) => (mine ? anchor.right - child.width : anchor.left)
        .clamp(12.0, size.width - child.width - 12);

    double py;
    double ry;
    if (anchor.bottom + gap + p.height <= bottom) {
      // Panel below the message, reactions above it (or above the panel
      // when the message reaches the top of the screen).
      py = anchor.bottom + gap;
      ry = anchor.top - rh;
      if (ry < top) {
        ry = py;
        py += rh;
      }
    } else {
      // Both above the message, as close to it as fits.
      py = (anchor.top - gap - p.height).clamp(top + rh, bottom - p.height);
      ry = py - rh;
    }
    positionChild(#panel, Offset(side(p), py.clamp(top, bottom - p.height)));
    if (r != null) {
      positionChild(#reactions, Offset(side(r), ry.clamp(top, bottom)));
    }
  }

  @override
  bool shouldRelayout(_MenuPlacement old) =>
      old.anchor != anchor || old.mine != mine || old.safe != safe;
}

class _Reactions extends StatelessWidget {
  const _Reactions({required this.current, required this.onPick});
  final String? current;
  final void Function(String emoji) onPick;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Brand.raised(context),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Brand.hairline(context)),
        boxShadow: Brand.shadow(context, strength: 1.4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in quickReactions)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onPick(e),
              child: Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: current == e ? primary.withValues(alpha: 0.22) : null,
                ),
                child: Text(e, style: const TextStyle(fontSize: 23)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small profile pictures of whoever has seen an own message.
class _SeenBy extends StatelessWidget {
  const _SeenBy({
    required this.state,
    required this.msg,
    required this.isGroup,
  });
  final AppState state;
  final ChatMessage msg;
  final bool isGroup;

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    final readers = msg.readers.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final ids = [for (final r in readers) int.parse(r.key)];
    final muted = Brand.muted(context);
    final String label;
    if (ids.isEmpty) {
      label = msg.status == MsgStatus.read ? 'دیده شد' : 'هنوز دیده نشده';
    } else if (!isGroup) {
      label =
          'دیده شد ${shortTime(DateTime.fromMillisecondsSinceEpoch(readers.first.value))}';
    } else {
      label = fa('${ids.length} نفر دیدند');
    }
    final shown = ids.take(4).toList();
    return Material(
      color: Brand.raised(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isGroup && ids.isNotEmpty
            ? () => _list(
                context,
                readers.map((r) => (int.parse(r.key), r.value)).toList(),
              )
            : null,
        child: Container(
          width: 230,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Brand.hairline(context)),
          ),
          child: Row(
            children: [
              Icon(
                ids.isEmpty && msg.status != MsgStatus.read
                    ? Icons.visibility_off_outlined
                    : Icons.done_all_rounded,
                size: 18,
                color: ids.isEmpty ? muted : Brand.readTick(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: muted),
                ),
              ),
              if (shown.isNotEmpty)
                SizedBox(
                  width: 18.0 * shown.length + 8,
                  height: 26,
                  child: Stack(
                    children: [
                      for (var i = 0; i < shown.length; i++)
                        PositionedDirectional(
                          end: 18.0 * i,
                          child: Container(
                            padding: const EdgeInsets.all(1.5),
                            decoration: BoxDecoration(
                              color: Brand.raised(context),
                              shape: BoxShape.circle,
                            ),
                            child: Avatar(
                              m.nameOf(shown[i]),
                              size: 23,
                              image: m.avatarOf(shown[i]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Everyone who has seen it in a group, with the time.
  void _list(BuildContext context, List<(int, int)> readers) {
    final m = state.messenger;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (id, ts) in readers)
              ListTile(
                leading: Avatar(m.nameOf(id), size: 38, image: m.avatarOf(id)),
                title: Text(m.nameOf(id)),
                trailing: Text(
                  shortTime(DateTime.fromMillisecondsSinceEpoch(ts)),
                  style: TextStyle(color: Brand.muted(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.items, required this.onPick});
  final List<_Item> items;
  final void Function(_Item item) onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Brand.raised(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Brand.hairline(context)),
        boxShadow: Brand.shadow(context, strength: 1.4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            InkWell(
              onTap: () => onPick(item),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Icon(item.icon, size: 21, color: item.color),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        item.label,
                        style: TextStyle(fontSize: 14.5, color: item.color),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks whether a message (or file) goes for everyone or only here. Only
/// the sender can take a message back from the others.
Future<void> confirmDeleteMessage(
  BuildContext context,
  AppState state,
  ChatMessage msg,
) async {
  final m = state.messenger;
  final error = Theme.of(context).colorScheme.error;
  final forAll = msg.outgoing && msg.clientMsgId != null;
  final what = msg.kind == 'media' ? 'این فایل' : 'این پیام';
  final choice = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      icon: BrandLottie('trash', size: 64, color: error),
      title: Text('حذف $what'),
      content: Text(
        forAll
            ? '$what از گوشی همه گیرنده‌ها هم پاک شود، یا فقط از گوشی شما؟'
            : 'فقط از گوشی شما پاک می‌شود؛ پیامی را که دیگری فرستاده نمی‌شود از گوشی او پاک کرد.',
      ),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowButtonSpacing: 4,
      actions: [
        if (forAll)
          FilledButton(
            style: Brand.danger(d),
            onPressed: () => Navigator.pop(d, 'all'),
            child: const Text('حذف برای همه'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(d, 'me'),
          child: Text(
            forAll ? 'فقط برای من' : 'حذف',
            style: forAll ? null : TextStyle(color: error),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('انصراف'),
        ),
      ],
    ),
  );
  if (choice == 'me') m.deleteLocal(msg.id);
  if (choice == 'all') await m.deleteForEveryone(msg);
}
