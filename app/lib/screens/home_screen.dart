import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/alert_health.dart';
import '../widgets/chat_sheets.dart';
import '../widgets/common.dart';
import '../widgets/home_parts.dart';
import '../widgets/motion.dart';
import '../widgets/web_notices.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';
import 'status_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();

  AppState get state => widget.state;
  Messenger get m => state.messenger;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureUsername());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Accounts created before usernames existed must pick one once.
  Future<void> _ensureUsername() async {
    if (!state.live) return;
    try {
      if (await m.syncProfile()) {
        if (mounted) setState(() {});
        return;
      }
    } catch (_) {
      return; // offline; asked again on the next launch
    }
    if (!mounted) return;
    final c = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: const Text('نام کاربری انتخاب کنید'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'دیگران می‌توانند با این نام شما را پیدا کنند و در گروه‌ها نام ببرند. بعدا قابل تغییر نیست.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: c,
                textDirection: TextDirection.ltr,
                autocorrect: false,
                decoration: InputDecoration(
                  prefixText: '@',
                  hintText: 'username',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () async {
                final u = c.text.trim().toLowerCase();
                if (!RegExp(r'^[a-z][a-z0-9_]{3,19}$').hasMatch(u)) {
                  setD(() => error = '۴ تا ۲۰ نویسه: حروف انگلیسی، رقم و _');
                  return;
                }
                try {
                  await m.setUsername(u);
                  if (d.mounted) Navigator.pop(d);
                } on ApiError catch (e) {
                  setD(
                    () => error = e.code == 'irm_username_taken'
                        ? 'این نام قبلا گرفته شده است'
                        : 'پذیرفته نشد (${e.code})',
                  );
                } catch (_) {
                  setD(() => error = 'اتصال برقرار نشد');
                }
              },
              child: const Text('ثبت'),
            ),
          ],
        ),
      ),
    );
  }

  void _open(String chat) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(state: state, chat: chat),
      ),
    );
  }

  void _profile() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SettingsScreen(state: state)));
  }

  String _preview(ChatMessage msg) {
    if (msg.status == MsgStatus.undecryptable) return 'پیام قابل خواندن نیست';
    if (msg.kind == 'buzz') {
      return msg.outgoing ? '📳 BUZZ فرستادید' : '📳 BUZZ!';
    }
    if (msg.kind == 'poll') return '📊 ${msg.body}';
    if (msg.kind == 'media') {
      final label = switch (msg.media?.kind) {
        'image' => '📷 عکس',
        'video' => '🎬 ویدیو',
        'voice' => '🎤 پیام صوتی',
        'gif' => 'GIF',
        'sticker' => 'استیکر',
        _ => 'فایل',
      };
      return msg.body.isEmpty ? label : '$label · ${msg.body}';
    }
    return isolateMentions(msg.body);
  }

  // ---- pinned chats (kept on this device only) ----

  List<String> get _pins {
    final raw = m.db.kvString('pins');
    return raw == null || raw.isEmpty ? [] : raw.split(',');
  }

  void _togglePin(String chat) {
    final pins = _pins;
    pins.contains(chat) ? pins.remove(chat) : pins.insert(0, chat);
    m.db.kvPutString('pins', pins.take(9).join(','));
    setState(() {});
  }

  void _chatMenu(ChatSummary c) {
    final pinned = _pins.contains(c.chat);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              ),
              title: Text(
                pinned ? 'برداشتن از بالای فهرست' : 'سنجاق به بالای فهرست',
              ),
              onTap: () {
                Navigator.pop(sheet);
                _togglePin(c.chat);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('حذف گفتگو'),
              onTap: () {
                Navigator.pop(sheet);
                confirmDeleteChat(context, state, c.chat);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- top: one floating search bar with settings and profile ----

  Widget _topBar(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final muted = Brand.muted(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(14, top + 10, 14, 6),
      child: Container(
        height: 54,
        padding: const EdgeInsetsDirectional.only(start: 16, end: 6),
        decoration: BoxDecoration(
          color: Brand.raised(context),
          borderRadius: BorderRadius.circular(27),
          border: Border.all(color: Brand.hairline(context)),
          boxShadow: Brand.shadow(context, strength: 0.8),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, color: muted),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  filled: false,
                  isDense: true,
                  hintText: 'جستجو در ایران مسنجر',
                  hintStyle: TextStyle(color: muted),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_search.text.isNotEmpty)
              IconButton(
                tooltip: 'پاک کردن',
                icon: Icon(Icons.close_rounded, color: muted),
                onPressed: _search.clear,
              ),
            IconButton(
              tooltip: 'اتصال و اعلان‌ها',
              icon: Icon(
                state.link == LinkState.ok
                    ? Icons.settings_outlined
                    : Icons.cloud_off_rounded,
                color: state.link == LinkState.ok
                    ? muted
                    : Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => StatusScreen(state: state)),
              ),
            ),
            InkWell(
              customBorder: const CircleBorder(),
              onTap: _profile,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Avatar(m.myName, size: 38, image: m.myAvatar),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- pinned chats as large circles ----

  Widget _pinnedGrid(BuildContext context, List<ChatSummary> pinned) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        runSpacing: 14,
        children: [
          for (final c in pinned)
            SizedBox(
              width: (MediaQuery.sizeOf(context).width.clamp(0, 560) - 16) / 3,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _open(c.chat),
                onLongPress: () => _chatMenu(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Avatar(
                            c.title,
                            group: c.isGroup,
                            size: 76,
                            image: m.chatAvatar(c.chat),
                          ),
                          if (c.unread > 0)
                            PositionedDirectional(
                              top: -2,
                              end: -4,
                              child: UnreadBadge(c.unread),
                            ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: c.unread > 0
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- one row of the chat list ----

  Widget _tile(BuildContext context, ChatSummary c) {
    final last = c.last!;
    final unread = c.unread;
    final muted = Brand.muted(context);
    final status = !last.outgoing || last.kind == 'system'
        ? null
        : switch (last.status) {
            MsgStatus.pending => Icons.schedule_rounded,
            MsgStatus.sent => Icons.check_rounded,
            MsgStatus.delivered => Icons.done_all_rounded,
            MsgStatus.read => Icons.done_all_rounded,
            _ => Icons.error_outline_rounded,
          };
    final mention = !last.outgoing && m.mentionsMe(last.body);
    return InkWell(
      onTap: () => _open(c.chat),
      onLongPress: () => _chatMenu(c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Avatar(
              c.title,
              group: c.isGroup,
              size: 54,
              image: m.chatAvatar(c.chat),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: unread > 0
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        shortTime(last.createdAt),
                        style: TextStyle(
                          fontSize: 12,
                          color: unread > 0
                              ? Theme.of(context).colorScheme.primary
                              : muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (status != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            status,
                            size: 16,
                            color: last.status == MsgStatus.failed
                                ? Theme.of(context).colorScheme.error
                                // Blue only once someone has read it.
                                : last.status == MsgStatus.read
                                ? Brand.readTick(context)
                                : muted,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          _preview(last),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: unread > 0
                                ? Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.82)
                                : muted,
                          ),
                        ),
                      ),
                      if (mention || unread > 0) ...[
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: CountPill(unread, mention: mention),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final all = m
        .chats()
        .where((c) => q.isEmpty || c.title.toLowerCase().contains(q))
        .toList();
    final pins = q.isEmpty ? _pins : const <String>[];
    final pinned = [for (final p in pins) ...all.where((c) => c.chat == p)];
    final rest = all.where((c) => !pinned.contains(c)).toList();
    final dark = Brand.dark(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: Brand.page(context),
        body: EntranceScope(
          child: Column(
            children: [
              _topBar(context),
              LinkBanner(state: state),
              PushBanner(state: state),
              AlertHealthBanner(state: state),
              Expanded(
                child: all.isEmpty
                    ? HomeEmpty(query: q)
                    : RefreshIndicator(
                        onRefresh: state.syncNow,
                        child: ListView(
                          padding: const EdgeInsets.only(top: 4, bottom: 100),
                          children: [
                            if (pinned.isNotEmpty) ...[
                              Entrance(child: _pinnedGrid(context, pinned)),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 6,
                                ),
                                child: Divider(
                                  height: 1,
                                  color: Brand.hairline(context),
                                ),
                              ),
                            ],
                            for (final (i, c) in rest.indexed)
                              Entrance(
                                index: i + (pinned.isEmpty ? 0 : 1),
                                child: _tile(context, c),
                              ),
                            if (pinned.isEmpty && q.isEmpty && rest.length > 3)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  14,
                                  24,
                                  0,
                                ),
                                child: Text(
                                  'برای سنجاق کردن گفتگوهای مهم به بالای فهرست، روی آن‌ها انگشت نگه دارید.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Brand.muted(context),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        floatingActionButton: StartChatButton(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => NewChatScreen(state: state)),
          ),
        ),
      ),
    );
  }
}
