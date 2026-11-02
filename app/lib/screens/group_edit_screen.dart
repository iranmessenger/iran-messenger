import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';

/// Create a group, or (admins only) rename it, change its picture and its
/// members. The creator also chooses who else is an admin.
class GroupEditScreen extends StatefulWidget {
  const GroupEditScreen({super.key, required this.state, this.groupId});
  final AppState state;
  final String? groupId;

  @override
  State<GroupEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends State<GroupEditScreen> {
  final _title = TextEditingController();
  final _selected = <int>{};
  final _admins = <int>{};
  bool _busy = false;

  Messenger get m => widget.state.messenger;
  GroupInfo? get _group =>
      widget.groupId == null ? null : m.group(widget.groupId!);

  /// Only the creator decides who is an admin.
  bool get _owner => _group == null || _group!.admin == m.myIdentity;

  @override
  void initState() {
    super.initState();
    final g = _group;
    if (g != null) {
      _title.text = g.title;
      _selected.addAll(g.members);
      _admins.addAll(g.admins);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _selected.where((i) => i != m.myIdentity).isEmpty) {
      _toast('نام گروه و دست‌کم یک عضو لازم است');
      return;
    }
    setState(() => _busy = true);
    try {
      if (widget.groupId == null) {
        final gid = await m.createGroup(title, _selected.toList());
        if (_admins.isNotEmpty) {
          await m.updateGroup(
            gid,
            title,
            _selected.toList(),
            admins: _admins.toList(),
          );
        }
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ChatScreen(state: widget.state, chat: 'g:$gid'),
          ),
        );
      } else {
        await m.updateGroup(
          widget.groupId!,
          title,
          _selected.toList(),
          admins: _owner ? _admins.toList() : null,
        );
        if (mounted) Navigator.pop(context);
      }
    } on StateError {
      _toast('فقط مدیر گروه می‌تواند آن را تغییر دهد.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _photo() async {
    final gid = widget.groupId!;
    final has = m.chatAvatar('g:$gid') != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('انتخاب عکس گروه'),
              onTap: () => Navigator.pop(sheet, 'pick'),
            ),
            if (has)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('حذف عکس گروه'),
                onTap: () => Navigator.pop(sheet, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    setState(() => _busy = true);
    try {
      if (choice == 'remove') {
        await m.setGroupAvatar(gid, null);
        return;
      }
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final jpeg = await avatarJpeg(await x.readAsBytes());
      if (jpeg == null) return _toast('این فایل تصویر نیست.');
      await m.setGroupAvatar(gid, jpeg);
    } catch (_) {
      _toast('انجام نشد؛ دوباره امتحان کنید.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = m.contacts();
    final gid = widget.groupId;
    final owner = _group?.admin;
    return Scaffold(
      appBar: AppBar(
        title: Text(gid == null ? 'گروه جدید' : 'ویرایش گروه'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('ذخیره'),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          if (gid != null) ...[
            const SizedBox(height: 16),
            Center(
              child: GestureDetector(
                onTap: _busy ? null : _photo,
                child: Avatar(
                  _title.text,
                  group: true,
                  size: 84,
                  image: m.chatAvatar('g:$gid'),
                ),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: _busy ? null : _photo,
                child: const Text('عکس گروه'),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _title,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'نام گروه',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _owner
                  ? 'عضو تازه پیام‌های قبلی گروه را نمی‌بیند و عضو حذف‌شده پیام‌های بعدی را نمی‌گیرد. با ستاره، عضو را مدیر کنید؛ مدیر می‌تواند نام، عکس و اعضا را تغییر دهد.'
                  : 'عضو تازه پیام‌های قبلی گروه را نمی‌بیند و عضو حذف‌شده پیام‌های بعدی را نمی‌گیرد.',
              style: TextStyle(fontSize: 13, color: Brand.muted(context)),
            ),
          ),
          const SizedBox(height: 8),
          for (final c in contacts)
            CheckboxListTile(
              secondary: Avatar(c.displayName, image: m.avatarOf(c.identityId)),
              title: Row(
                children: [
                  Flexible(child: Text(c.displayName)),
                  if (c.identityId == owner) ...[
                    const SizedBox(width: 8),
                    Text(
                      'سازنده',
                      style: TextStyle(
                        fontSize: 12,
                        color: Brand.muted(context),
                      ),
                    ),
                  ] else if (_selected.contains(c.identityId) &&
                      (_owner || _admins.contains(c.identityId)))
                    IconButton(
                      tooltip: 'مدیر گروه',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _admins.contains(c.identityId)
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: _admins.contains(c.identityId)
                            ? Brand.amber
                            : Brand.muted(context),
                      ),
                      onPressed: !_owner
                          ? null
                          : () => setState(
                              () => _admins.contains(c.identityId)
                                  ? _admins.remove(c.identityId)
                                  : _admins.add(c.identityId),
                            ),
                    ),
                ],
              ),
              subtitle: c.username == null
                  ? null
                  : Text('@${c.username}', textDirection: TextDirection.ltr),
              value: _selected.contains(c.identityId),
              // Nobody but the creator may remove the creator.
              onChanged: c.identityId == owner
                  ? null
                  : (v) => setState(() {
                      if (v == true) {
                        _selected.add(c.identityId);
                      } else {
                        _selected.remove(c.identityId);
                        _admins.remove(c.identityId);
                      }
                    }),
            ),
        ],
      ),
    );
  }
}
