import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_profile_screen.dart';
import '../widgets/chat_sheets.dart';
import '../widgets/buzz.dart';
import '../widgets/composer.dart';
import '../widgets/message_menu.dart';
import '../widgets/message_bubble.dart';
import '../widgets/motion.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.state, required this.chat});
  final AppState state;
  final String chat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();
  bool _showJump = false;
  ChatMessage? _replyTo;
  ChatMessage? _editing;

  Messenger get m => widget.state.messenger;
  bool get isGroup => widget.chat.startsWith('g:');
  String get gid => widget.chat.substring(2);

  @override
  void initState() {
    super.initState();
    widget.state.setOpenChat(widget.chat);
    _scroll.addListener(() {
      final show = _scroll.hasClients && _scroll.offset > 500;
      if (show != _showJump) setState(() => _showJump = show);
    });
  }

  @override
  void dispose() {
    widget.state.setOpenChat(null);
    _scroll.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Tapping @username opens a chat with that person, if they exist.
  Future<void> _openMention(String username) async {
    if (username == m.myUsername) return;
    var c = m.contacts().where((x) => x.username == username).firstOrNull;
    try {
      c ??= await m.lookupUsername(username);
    } catch (_) {
      _toast('اتصال به سرور برقرار نشد.');
      return;
    }
    if (c == null) {
      _toast('کسی با نام کاربری @$username پیدا نشد.');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(state: widget.state, chat: 'u:${c!.identityId}'),
      ),
    );
  }

  void _actions(ChatMessage msg, Rect bubble) => showMessageMenu(
    context,
    widget.state,
    msg,
    anchor: bubble,
    isGroup: isGroup,
    onReply: () => setState(() {
      _editing = null;
      _replyTo = msg;
    }),
    onEdit: () => setState(() {
      _replyTo = null;
      _editing = msg;
    }),
  );

  Future<void> _verify() async {
    final peer = int.parse(gid);
    final code = await m.safetyNumber(peer);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.verified_user_rounded, size: 34),
        title: const Text('تایید هویت'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              code.isEmpty
                  ? 'هنوز پیامی با این مخاطب رد و بدل نشده است.'
                  : 'این کد را حضوری یا تلفنی با مخاطب مقایسه کنید. اگر روی هر دو دستگاه یکسان بود، کسی بین شما قرار نگرفته است.',
            ),
            if (code.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Brand.page(context),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SelectableText(
                  code,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontSize: 18,
                    letterSpacing: 1.2,
                    height: 1.6,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(d);
              await m.acceptNewIdentity(peer);
              _toast('کلید تازه مخاطب پذیرفته شد؛ کد را دوباره مقایسه کنید.');
            },
            child: const Text('مخاطب دستگاه عوض کرده است'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  void _profile() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ChatProfileScreen(state: widget.state, chat: widget.chat),
    ),
  );

  PreferredSizeWidget _appBar(BuildContext context) {
    final title = m.chatTitle(widget.chat);
    final g = isGroup ? m.group(gid) : null;
    final username = isGroup ? null : m.contact(int.parse(gid))?.username;
    final typing = m.typingIn(widget.chat);
    final subtitle = typing != null
        ? (isGroup ? '$typing در حال نوشتن…' : 'در حال نوشتن…')
        : isGroup
        ? (g == null ? null : fa('${g.members.length} عضو'))
        : (username == null ? null : '@$username');
    return AppBar(
      // Next to the back arrow; away from the edge when there is none.
      titleSpacing: Navigator.of(context).canPop() ? 0 : 14,
      title: InkWell(
        onTap: _profile,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Avatar(
                title,
                group: isGroup,
                size: 40,
                image: m.chatAvatar(widget.chat),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (!isGroup && m.isBot(int.parse(gid)))
                          const BotBadge(),
                      ],
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        textDirection: isGroup || typing != null
                            ? null
                            : TextDirection.ltr,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: typing != null
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: typing != null
                              ? Theme.of(context).colorScheme.primary
                              : Brand.muted(context),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!isGroup)
          IconButton(
            tooltip: 'تایید هویت',
            onPressed: _verify,
            icon: const Icon(Icons.verified_user_outlined),
          ),
        if (isGroup)
          IconButton(
            tooltip: 'اعضا',
            onPressed: _profile,
            icon: const Icon(Icons.info_outline_rounded),
          ),
        PopupMenuButton<String>(
          tooltip: 'بیشتر',
          onSelected: (_) async {
            final nav = Navigator.of(context);
            if (await confirmDeleteChat(context, widget.state, widget.chat)) {
              nav.pop();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.delete_forever_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  isGroup ? 'خروج و پاک کردن گروه' : 'پاک کردن گفتگو',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        // Newest first: the list is reversed so it opens at the bottom.
        final list = m.messages(widget.chat).reversed.toList();
        final typing = m.typingIn(widget.chat);
        // The "typing" bubble sits below the newest message.
        final lead = typing == null ? 0 : 1;
        final rowOf = {for (final (i, x) in list.indexed) x.id: i};
        final g = isGroup ? m.group(gid) : null;
        final toBot = !isGroup && m.isBot(int.parse(gid));
        final canWrite = !toBot && (!isGroup || (g != null && !g.left));
        if (list.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => m.markRead(widget.chat),
          );
        }
        return Scaffold(
          appBar: _appBar(context),
          body: BuzzShaker(
            messenger: m,
            chat: widget.chat,
            child: ChatWallpaper(
              child: Column(
                children: [
                  LinkBanner(state: widget.state),
                  Expanded(
                    child: Stack(
                      children: [
                        if (list.isEmpty)
                          Center(
                            child: Entrance(
                              always: true,
                              child: Container(
                                margin: const EdgeInsets.all(32),
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  18,
                                  22,
                                  22,
                                ),
                                decoration: BoxDecoration(
                                  color: Brand.raised(
                                    context,
                                  ).withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: Brand.hairline(context),
                                  ),
                                  boxShadow: Brand.shadow(context),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    BrandLottie(
                                      'lock',
                                      size: 76,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'رمزنگاری سراسری',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'پیام‌ها روی گوشی شما رمز می‌شوند و سرور فقط متن رمزشده را می‌بیند.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Brand.muted(context),
                                        height: 1.7,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else
                          ListView.builder(
                            controller: _scroll,
                            reverse: true,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            itemCount: list.length + lead,
                            // Rows keep their state (a playing GIF or voice
                            // message) when a new message pushes them up.
                            findChildIndexCallback: (key) {
                              if (key is ValueKey<int>) {
                                final i = rowOf[key.value];
                                return i == null ? null : i + lead;
                              }
                              return lead == 1 &&
                                      key == const ValueKey('typing')
                                  ? 0
                                  : null;
                            },
                            itemBuilder: (_, at) {
                              if (at < lead) {
                                return TypingBubble(
                                  key: const ValueKey('typing'),
                                  name: isGroup ? typing : null,
                                );
                              }
                              final i = at - lead;
                              final msg = list[i];
                              final older = i + 1 < list.length
                                  ? list[i + 1]
                                  : null;
                              final newer = i > 0 ? list[i - 1] : null;
                              final newDay =
                                  older == null ||
                                  !sameDay(older.createdAt, msg.createdAt);
                              final startsRun =
                                  newDay ||
                                  older.sender != msg.sender ||
                                  older.kind == 'system';
                              final endsRun =
                                  newer == null ||
                                  newer.sender != msg.sender ||
                                  newer.kind == 'system' ||
                                  !sameDay(newer.createdAt, msg.createdAt);
                              return Column(
                                key: ValueKey(msg.id),
                                children: [
                                  if (newDay) ChatChip(dayLabel(msg.createdAt)),
                                  MessageBubble(
                                    state: widget.state,
                                    message: msg,
                                    showSender: isGroup && startsRun,
                                    tail: endsRun,
                                    onMention: _openMention,
                                    onReact: (e) => m.react(msg, e),
                                    onMenu: msg.kind == 'system'
                                        ? null
                                        : (r) => _actions(msg, r),
                                  ),
                                ],
                              );
                            },
                          ),
                        if (_showJump)
                          PositionedDirectional(
                            end: 14,
                            bottom: 10,
                            child: FloatingActionButton.small(
                              heroTag: null,
                              backgroundColor: Brand.raised(context),
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              onPressed: () => _scroll.animateTo(
                                0,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              ),
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: canWrite
                        ? Composer(
                            state: widget.state,
                            chat: widget.chat,
                            replyTo: _replyTo,
                            editing: _editing,
                            onClear: () => setState(() {
                              _replyTo = null;
                              _editing = null;
                            }),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(14),
                            child: ChatChip(
                              toBot
                                  ? 'این ربات فقط پیام می‌فرستد و پیام‌های شما را دریافت نمی‌کند. برای گرفتن خبرهایش، آن را به یک گروه اضافه کنید.'
                                  : 'شما دیگر عضو این گروه نیستید',
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
