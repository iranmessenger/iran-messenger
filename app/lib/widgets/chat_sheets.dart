import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../screens/group_edit_screen.dart';
import '../theme.dart';
import 'common.dart';
import 'motion.dart';

/// Members of a group, who its admins are, and the way to edit it.
void showGroupInfo(BuildContext context, AppState state, String gid) {
  final m = state.messenger;
  final g = m.group(gid);
  if (g == null) return;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Center(
              child: Avatar(
                g.title,
                group: true,
                size: 72,
                image: m.chatAvatar('g:$gid'),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                g.title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Center(
              child: Text(
                fa('${g.members.length} عضو'),
                style: TextStyle(color: Brand.muted(context)),
              ),
            ),
            const SizedBox(height: 8),
            for (final id in g.members)
              ListTile(
                leading: Avatar(m.nameOf(id), size: 40, image: m.avatarOf(id)),
                title: Text(m.nameOf(id)),
                subtitle:
                    (id == m.myIdentity
                            ? m.myUsername
                            : m.contact(id)?.username) ==
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
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : null,
              ),
            if (g.admins.contains(m.myIdentity) && !g.left)
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('ویرایش نام، عکس و اعضا'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          GroupEditScreen(state: state, groupId: gid),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// Asks before deleting a whole chat. A person's chat can also be deleted
/// on their phone; a group is left first, and its creator may delete it
/// for every member. Returns true once it is gone.
Future<bool> confirmDeleteChat(
  BuildContext context,
  AppState state,
  String chat,
) async {
  final m = state.messenger;
  final isGroup = chat.startsWith('g:');
  final g = isGroup ? m.group(chat.substring(2)) : null;
  final creator = g != null && !g.left && g.admin == m.myIdentity;
  final canBoth = (!isGroup || creator) && m.canClearForBoth(chat);
  var both = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, setState) => AlertDialog(
        icon: BrandLottie(
          'trash',
          size: 64,
          color: Theme.of(d).colorScheme.error,
        ),
        title: Text(isGroup ? 'خروج و پاک کردن گروه' : 'پاک کردن گفتگو'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isGroup && g != null && !g.left
                  ? 'از «${g.title}» خارج می‌شوید و همه پیام‌ها، عکس‌ها و فایل‌های آن از این گوشی برای همیشه پاک می‌شود. این کار برگشت ندارد.'
                  : 'همه پیام‌ها، عکس‌ها و فایل‌های «${m.chatTitle(chat)}» از این گوشی برای همیشه پاک می‌شود. این کار برگشت ندارد.',
              style: const TextStyle(height: 1.7),
            ),
            if (canBoth)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: both,
                onChanged: (v) => setState(() => both = v ?? false),
                title: Text(
                  isGroup
                      ? 'حذف گروه برای همه اعضا'
                      : 'برای ${m.chatTitle(chat)} هم پاک شود',
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            style: Brand.danger(d),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('پاک شود'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  await m.deleteChat(chat, forBoth: both);
  return true;
}
