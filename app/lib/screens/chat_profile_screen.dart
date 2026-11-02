import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/message_text.dart';
import '../widgets/common.dart';
import '../widgets/media_view.dart';
import '../widgets/profile_header.dart';
import 'group_edit_screen.dart';
import 'viewer_screens.dart';

/// A person's or a group's profile: a large picture that opens full
/// screen, the name, and what has been shared in the chat, sorted into
/// media, files, links and voice messages. Groups also list their members.
class ChatProfileScreen extends StatelessWidget {
  const ChatProfileScreen({super.key, required this.state, required this.chat});
  final AppState state;
  final String chat;

  bool get isGroup => chat.startsWith('g:');

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    final tabs = [
      if (isGroup) const Tab(text: 'اعضا'),
      const Tab(text: 'رسانه'),
      const Tab(text: 'فایل'),
      const Tab(text: 'لینک'),
      const Tab(text: 'صوتی'),
    ];
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => DefaultTabController(
        length: tabs.length,
        child: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              _header(context, m),
              if (_isBot(m)) SliverToBoxAdapter(child: _botNote(context)),
              SliverPersistentHeader(
                pinned: true,
                delegate: _TabBarHeader(
                  TabBar(isScrollable: false, tabs: tabs),
                  Brand.page(context),
                ),
              ),
            ],
            body: TabBarView(
              children: [
                if (isGroup) _Members(state: state, gid: chat.substring(2)),
                _MediaGrid(state: state, chat: chat),
                _MediaList(state: state, chat: chat, kinds: const {'file'}),
                _Links(state: state, chat: chat),
                _MediaList(state: state, chat: chat, kinds: const {'voice'}),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _canEdit(Messenger m) {
    final g = m.group(chat.substring(2));
    return g != null && !g.left && g.admins.contains(m.myIdentity);
  }

  bool _isBot(Messenger m) => !isGroup && m.isBot(int.parse(chat.substring(2)));

  Widget _header(BuildContext context, Messenger m) {
    final picture = m.chatAvatar(chat);
    final title = m.chatTitle(chat);
    final g = isGroup ? m.group(chat.substring(2)) : null;
    final username = isGroup
        ? null
        : m.contact(int.parse(chat.substring(2)))?.username;
    return ProfileAppBar(
      name: title,
      actions: [
        if (isGroup && _canEdit(m))
          IconButton(
            tooltip: 'ویرایش گروه',
            icon: const Icon(Icons.edit_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    GroupEditScreen(state: state, groupId: chat.substring(2)),
              ),
            ),
          ),
      ],
      picture: GestureDetector(
        onTap: picture == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(path: picture),
                ),
              ),
        child: Hero(
          tag: 'avatar:$chat',
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.22),
            ),
            child: Avatar(title, group: isGroup, size: 104, image: picture),
          ),
        ),
      ),
      subtitle: username != null
          ? Text('@$username', textDirection: TextDirection.ltr)
          : g != null
          ? Text(fa('${g.members.length} عضو'))
          : null,
    );
  }

  Widget _botNote(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
    child: Column(
      children: [
        const BotBadge(size: 12),
        const SizedBox(height: 6),
        Text(
          'فقط پیام می‌فرستد و هیچ پیامی از گفتگوها دریافت نمی‌کند.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: Brand.muted(context)),
        ),
      ],
    ),
  );
}

class _TabBarHeader extends SliverPersistentHeaderDelegate {
  _TabBarHeader(this.bar, this.color);
  final TabBar bar;
  final Color color;

  @override
  double get minExtent => bar.preferredSize.height;
  @override
  double get maxExtent => bar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrink, bool overlaps) =>
      ColoredBox(color: color, child: bar);

  @override
  bool shouldRebuild(_TabBarHeader old) => old.bar != bar || old.color != color;
}

Widget _empty(BuildContext context, String text) => Center(
  child: Padding(
    padding: const EdgeInsets.all(32),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: Brand.muted(context)),
    ),
  ),
);

/// Downloads an attachment that is not on this device yet.
Future<void> _fetch(
  BuildContext context,
  AppState state,
  ChatMessage msg,
) async {
  final toast = ScaffoldMessenger.of(context);
  try {
    final path = await state.messenger.media.download(msg.id);
    if (path == null) {
      toast.showSnackBar(
        const SnackBar(content: Text('این فایل دیگر روی سرور نیست.')),
      );
    }
  } catch (_) {
    toast.showSnackBar(const SnackBar(content: Text('دریافت نشد.')));
  }
  state.messenger.notify();
}

class _Members extends StatelessWidget {
  const _Members({required this.state, required this.gid});
  final AppState state;
  final String gid;

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    final g = m.group(gid);
    if (g == null) return _empty(context, 'این گروه دیگر روی این گوشی نیست.');
    final iAmAdmin = !g.left && g.admins.contains(m.myIdentity);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (iAmAdmin)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.16),
              child: Icon(
                Icons.group_add_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            title: const Text('افزودن عضو، تغییر نام و عکس گروه'),
            subtitle: const Text(
              'برای مدیر کردن یا حذف یک عضو، روی اسمش بزنید',
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => GroupEditScreen(state: state, groupId: gid),
              ),
            ),
          ),
        for (final id in g.members)
          ListTile(
            leading: Avatar(m.nameOf(id), size: 42, image: m.avatarOf(id)),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    id == m.myIdentity ? '${m.nameOf(id)} (شما)' : m.nameOf(id),
                  ),
                ),
                if (m.isBot(id)) const BotBadge(),
              ],
            ),
            subtitle:
                (id == m.myIdentity ? m.myUsername : m.contact(id)?.username) ==
                    null
                ? null
                : Text(
                    '@${id == m.myIdentity ? m.myUsername : m.contact(id)!.username}',
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.right,
                  ),
            trailing: g.admins.contains(id)
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Brand.amber.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      id == g.admin ? 'سازنده' : 'مدیر',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : null,
            onTap: id == m.myIdentity
                ? null
                : () => _memberMenu(context, g, id),
          ),
      ],
    );
  }

  /// What one can do with a member: see their profile, and for admins
  /// make them an admin (the creator only) or remove them.
  void _memberMenu(BuildContext context, GroupInfo g, int id) {
    final m = state.messenger;
    final iAmAdmin = !g.left && g.admins.contains(m.myIdentity);
    final iAmCreator = !g.left && g.admin == m.myIdentity;
    final toast = ScaffoldMessenger.of(context);
    Future<void> change(
      List<int> members,
      List<int>? admins,
      String done,
    ) async {
      try {
        await m.updateGroup(gid, g.title, members, admins: admins);
        toast.showSnackBar(SnackBar(content: Text(done)));
      } catch (_) {
        toast.showSnackBar(const SnackBar(content: Text('تغییر انجام نشد.')));
      }
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              m.nameOf(id),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: const Text('مشاهده پروفایل'),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatProfileScreen(state: state, chat: 'u:$id'),
                  ),
                );
              },
            ),
            if (iAmCreator && !m.isBot(id))
              ListTile(
                leading: Icon(
                  g.admins.contains(id)
                      ? Icons.remove_moderator_rounded
                      : Icons.add_moderator_rounded,
                ),
                title: Text(
                  g.admins.contains(id) ? 'برداشتن از مدیری' : 'مدیر گروه شود',
                ),
                subtitle: const Text(
                  'مدیرها می‌توانند نام، عکس و اعضای گروه را تغییر دهند',
                ),
                onTap: () {
                  Navigator.pop(sheet);
                  final admins = {...g.admins};
                  g.admins.contains(id) ? admins.remove(id) : admins.add(id);
                  change(
                    g.members,
                    admins.toList(),
                    g.admins.contains(id) ? 'دیگر مدیر نیست.' : 'مدیر گروه شد.',
                  );
                },
              ),
            if (iAmAdmin && id != g.admin)
              ListTile(
                leading: Icon(
                  Icons.person_remove_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'حذف از گروه',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () async {
                  Navigator.pop(sheet);
                  final sure = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text('${m.nameOf(id)} از گروه حذف شود؟'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('انصراف'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text('حذف شود'),
                        ),
                      ],
                    ),
                  );
                  if (sure == true) {
                    change(
                      [
                        for (final x in g.members)
                          if (x != id) x,
                      ],
                      iAmCreator
                          ? [
                              for (final x in g.admins)
                                if (x != id) x,
                            ]
                          : null,
                      'از گروه حذف شد.',
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Pictures, videos, GIFs and stickers as a grid.
class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.state, required this.chat});
  final AppState state;
  final String chat;

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    final items = m.sharedMedia(chat, const {
      'image',
      'video',
      'gif',
      'sticker',
    });
    if (items.isEmpty) {
      return _empty(context, 'هنوز عکس یا ویدیویی فرستاده نشده است.');
    }
    return GridView.count(
      crossAxisCount: 3,
      padding: const EdgeInsets.all(4),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      children: [for (final msg in items) _cell(context, m, msg)],
    );
  }

  Widget _cell(BuildContext context, Messenger m, ChatMessage msg) {
    final info = msg.media!;
    final path = info.path;
    final here = path != null && m.files.existsSync(path);
    final still =
        info.kind == 'image' ||
        (info.kind != 'video' && !info.mime.startsWith('video/'));
    return GestureDetector(
      onTap: () {
        if (!here) {
          _fetch(context, state, msg);
        } else if (still) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ImageViewerScreen(path: path)),
          );
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VideoViewerScreen(path: path, mime: info.mime),
            ),
          );
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: Colors.black26,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (here && still)
                localImage(
                  path,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                ),
              if (!here || !still)
                Center(
                  child: Icon(
                    !here
                        ? Icons.download_rounded
                        : info.kind == 'gif'
                        ? Icons.gif_rounded
                        : Icons.play_circle_outline_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Files or voice messages as a list, newest first.
class _MediaList extends StatelessWidget {
  const _MediaList({
    required this.state,
    required this.chat,
    required this.kinds,
  });
  final AppState state;
  final String chat;
  final Set<String> kinds;

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    final items = m.sharedMedia(chat, kinds);
    if (items.isEmpty) {
      return _empty(
        context,
        kinds.contains('voice')
            ? 'هنوز پیام صوتی فرستاده نشده است.'
            : 'هنوز فایلی فرستاده نشده است.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, i) {
        final msg = items[i];
        final info = msg.media!;
        final here = info.path != null && m.files.existsSync(info.path!);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!here)
                Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: () => _fetch(context, state, msg),
                      icon: const Icon(Icons.download_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${info.kind == 'voice' ? 'پیام صوتی' : info.name} · ${fileSize(info.size)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                )
              else if (info.kind == 'voice')
                VoicePlayer(
                  path: info.path!,
                  mime: info.mime,
                  durationMs: info.durationMs,
                )
              else
                FileTile(
                  name: info.name,
                  size: info.size,
                  mime: info.mime,
                  path: info.path!,
                ),
              const SizedBox(height: 2),
              Text(
                '${m.nameOf(msg.sender)} · ${dayLabel(msg.createdAt)} ${clock(msg.createdAt)}',
                style: TextStyle(fontSize: 11.5, color: Brand.muted(context)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Every web address mentioned in the chat. A tap opens it, holding
/// copies it.
class _Links extends StatelessWidget {
  const _Links({required this.state, required this.chat});
  final AppState state;
  final String chat;

  static final _url = RegExp(
    r'''(https?://|www\.)[^\s<>"']+''',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    final found = [
      for (final msg in m.sharedLinks(chat))
        for (final match in _url.allMatches(msg.body))
          (match[0]!.replaceAll(RegExp(r'[.,;:!?)\]]+$'), ''), msg),
    ];
    if (found.isEmpty) return _empty(context, 'هنوز لینکی فرستاده نشده است.');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: found.length,
      itemBuilder: (context, i) {
        final (url, msg) = found[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.16),
            child: Icon(
              Icons.link_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(
            url,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.left,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          subtitle: Text(
            '${m.nameOf(msg.sender)} · ${dayLabel(msg.createdAt)}',
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () => openLink(context, url),
          onLongPress: () async {
            final toast = ScaffoldMessenger.of(context);
            await Clipboard.setData(ClipboardData(text: url));
            toast.showSnackBar(const SnackBar(content: Text('لینک کپی شد.')));
          },
        );
      },
    );
  }
}
