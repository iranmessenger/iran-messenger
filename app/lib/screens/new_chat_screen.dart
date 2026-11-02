import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'chat_screen.dart';
import 'group_edit_screen.dart';

/// Start a chat: known people, or find someone by exact username. There is
/// no address-book matching: the server never learns phone numbers.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key, required this.state});
  final AppState state;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _search = TextEditingController();
  bool _busy = false;

  Messenger get m => widget.state.messenger;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _open(int identity) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(state: widget.state, chat: 'u:$identity'),
      ),
    );
  }

  Future<void> _lookup(String username) async {
    setState(() => _busy = true);
    try {
      final c = await m.lookupUsername(username);
      if (c == null) {
        _toast('کسی با نام کاربری @$username پیدا نشد.');
      } else if (mounted) {
        _open(c.identityId);
      }
    } on ApiError catch (e) {
      _toast(
        e.code == 'irm_rate_limited'
            ? 'تعداد جستجو زیاد بود؛ کمی بعد دوباره امتحان کنید.'
            : 'جستجو انجام نشد (${e.code}).',
      );
    } catch (_) {
      _toast('اتصال به سرور برقرار نشد.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _action(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return Panel(
      margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      padding: const EdgeInsets.all(12),
      onTap: _busy ? null : onTap,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12.5, color: Brand.muted(context)),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_left_rounded, color: Brand.muted(context)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final raw = _search.text.trim();
    final q = raw.toLowerCase().replaceFirst('@', '');
    final contacts = m
        .contacts()
        .where(
          (c) =>
              q.isEmpty ||
              c.displayName.toLowerCase().contains(q) ||
              (c.username ?? '').contains(q),
        )
        .toList();
    final canLookup =
        RegExp(r'^[a-z][a-z0-9_]{3,19}$').hasMatch(q) &&
        !contacts.any((c) => c.username == q);

    return Scaffold(
      appBar: AppBar(title: const Text('گفتگوی جدید')),
      body: EntranceScope(
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 3),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
              child: TextField(
                controller: _search,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: 'نام یا @نام‌کاربری',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (canLookup)
                    _action(
                      Icons.alternate_email_rounded,
                      'جستجوی @$q',
                      'پیدا کردن با نام کاربری دقیق',
                      () => _lookup(q),
                    ),
                  if (q.isEmpty) ...[
                    Entrance(
                      index: 1,
                      child: _action(
                        Icons.group_add_rounded,
                        'گروه جدید',
                        'تا ۱۵ نفر، با رمزنگاری سراسری',
                        () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) =>
                                  GroupEditScreen(state: widget.state),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
                    child: Text(
                      'افرادی که می‌شناسید',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Brand.muted(context),
                      ),
                    ),
                  ),
                  if (contacts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                      child: Text(
                        q.isEmpty
                            ? (isWebApp
                                  ? 'هنوز کسی اینجا نیست. نام کاربری دوستتان را بالا بنویسید.'
                                  : 'هنوز کسی اینجا نیست. از دفترچه تلفن کمک بگیرید یا نام کاربری دوستتان را بالا بنویسید.')
                            : 'کسی با این مشخصات در فهرست شما نیست.',
                        style: TextStyle(color: Brand.muted(context)),
                      ),
                    ),
                  for (final (i, c) in contacts.indexed)
                    Entrance(
                      index: i + 2,
                      child: Panel(
                        margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        onTap: () => _open(c.identityId),
                        child: Row(
                          children: [
                            Avatar(c.displayName, size: 46),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.displayName,
                                    style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (c.username != null)
                                    Text(
                                      '@${c.username}',
                                      textDirection: TextDirection.ltr,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
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
