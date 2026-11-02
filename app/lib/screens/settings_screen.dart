import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/buzz.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import '../widgets/profile_header.dart';
import 'account_screen.dart';
import 'status_screen.dart';

const appVersion = '1.0.0';

/// Everything the user can adjust, in one place: profile, privacy,
/// appearance, account and connection.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  AppState get state => widget.state;
  Messenger get m => state.messenger;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _edit({required bool mobile}) async {
    final c = TextEditingController(text: mobile ? '' : m.myName);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: Text(mobile ? 'شماره موبایل' : 'نام نمایشی'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mobile
                    ? 'اختیاری است. با ثبت شماره، دوستانی که آن را در دفترچه تلفن دارند می‌توانند شما را پیدا کنند. برای حذف، خالی بگذارید.'
                    : 'نامی که دیگران در گفتگوها می‌بینند.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: c,
                autofocus: true,
                keyboardType: mobile ? TextInputType.phone : null,
                textDirection: mobile ? TextDirection.ltr : null,
                decoration: InputDecoration(
                  hintText: mobile ? '09xxxxxxxxx' : null,
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('لغو'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  if (mobile) {
                    await m.updateProfile(mobile: c.text);
                  } else {
                    await m.updateProfile(displayName: c.text);
                  }
                  if (d.mounted) Navigator.pop(d);
                } on ApiError catch (e) {
                  setD(
                    () => error = switch (e.code) {
                      'irm_bad_mobile' => 'شماره معتبر نیست',
                      'irm_contact_in_use' => 'این شماره قابل استفاده نیست',
                      'irm_bad_name' => 'نام باید ۱ تا ۴۰ نویسه باشد',
                      _ => 'پذیرفته نشد (${e.code})',
                    },
                  );
                } catch (_) {
                  setD(() => error = 'اتصال برقرار نشد');
                }
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _photo() async {
    final has = m.myAvatar != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('انتخاب عکس'),
              onTap: () => Navigator.pop(sheet, 'pick'),
            ),
            if (has)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('حذف عکس'),
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
        await m.setMyAvatar(null);
        return;
      }
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final jpeg = await avatarJpeg(await x.readAsBytes());
      if (jpeg == null) return _toast('این فایل تصویر نیست.');
      await m.setMyAvatar(jpeg);
    } catch (_) {
      _toast('انجام نشد؛ دوباره امتحان کنید.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _title(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _group(List<Widget> children) => Panel(
    margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(children: children),
  );

  @override
  Widget build(BuildContext context) {
    final u = m.myUsername;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        body: EntranceScope(
          child: CustomScrollView(
            slivers: [
              ProfileAppBar(
                name: m.myName,
                title: 'تنظیمات',
                picture: GestureDetector(
                  onTap: _busy ? null : _photo,
                  child: Stack(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                        child: Avatar(m.myName, size: 96, image: m.myAvatar),
                      ),
                      PositionedDirectional(
                        bottom: 2,
                        end: 2,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: Brand.shadow(context, strength: 0.6),
                          ),
                          child: const Icon(
                            Icons.photo_camera_rounded,
                            size: 17,
                            color: Brand.deep,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                subtitle: u == null
                    ? null
                    : TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: '@$u'));
                          _toast('نام کاربری کپی شد.');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        label: Text('@$u', textDirection: TextDirection.ltr),
                      ),
              ),
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 28),
                sliver: SliverList.list(children: _sections(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final theme = m.db.kvString('theme') ?? 'system';
    var n = 0;
    Widget step(Widget child) => Entrance(index: n++, child: child);
    return [
      if (_busy) const LinearProgressIndicator(minHeight: 3),
      step(_title('نمایه')),
      step(
        _group([
          ListTile(
            leading: const Icon(Icons.badge_rounded),
            title: const Text('نام نمایشی'),
            subtitle: Text(m.myName),
            onTap: () => _edit(mobile: false),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_rounded),
            title: const Text('عکس نمایه'),
            subtitle: const Text(
              'فقط کسانی می‌بینند که با آن‌ها گفتگو یا گروه مشترک دارید.',
            ),
            onTap: _busy ? null : _photo,
          ),
        ]),
      ),
      step(_title('حریم خصوصی')),
      step(
        _group([
          SwitchListTile(
            secondary: const Icon(Icons.done_all_rounded),
            title: const Text('نمایش «خوانده شد»'),
            subtitle: const Text(
              'اگر خاموش باشد، دیگران نمی‌فهمند پیامشان را خوانده‌اید و شما هم خوانده شدن پیام‌های خودتان را نمی‌بینید.',
            ),
            value: m.readReceipts,
            onChanged: m.setReadReceipts,
          ),
        ]),
      ),
      step(_title('BUZZ')),
      step(_group([BuzzSoundTile(messenger: m)])),
      step(_title('ظاهر')),
      step(
        _group([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'system', label: Text('مثل گوشی')),
                  ButtonSegment(value: 'light', label: Text('روشن')),
                  ButtonSegment(value: 'dark', label: Text('تیره')),
                ],
                selected: {theme},
                showSelectedIcon: false,
                onSelectionChanged: (v) {
                  m.db.kvPutString('theme', v.first);
                  m.notify();
                },
              ),
            ),
          ),
        ]),
      ),
      step(_title('حساب و اتصال')),
      step(
        _group([
          ListTile(
            leading: const Icon(Icons.shield_rounded),
            title: const Text('حساب و پشتیبان'),
            subtitle: const Text('تغییر رمز، پشتیبان و بازیابی گفتگوها'),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AccountScreen(state: state)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('اتصال و اعلان‌ها'),
            subtitle: const Text('وضعیت سرور، دریافت در پس‌زمینه، اعلان'),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StatusScreen(state: state)),
            ),
          ),
        ]),
      ),
      step(
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: Column(
            children: [
              Text(
                'IRAN Messenger ${fa(appVersion)}\nنام کاربری‌تان را به هر کسی بدهید که می‌خواهید پیدایتان کند. کسی نمی‌تواند فهرست اعضای سرور را ببیند.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Brand.muted(context)),
              ),
              TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'IRAN Messenger',
                  applicationVersion: fa(appVersion),
                ),
                child: const Text(
                  'مجوز نرم‌افزارهای متن‌باز',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}
