import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Change the account password; make or restore an encrypted backup of
/// the conversation history.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.state});
  final AppState state;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _busy = false;

  Messenger get m => widget.state.messenger;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<List<String>?> _ask(
    String title,
    String note,
    List<String> labels, {
    String action = 'ادامه',
  }) {
    final controllers = [for (final _ in labels) TextEditingController()];
    return showDialog<List<String>>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(note),
              for (var i = 0; i < labels.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: controllers[i],
                    obscureText: true,
                    textDirection: TextDirection.ltr,
                    autocorrect: false,
                    decoration: InputDecoration(labelText: labels[i]),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('لغو'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(d, [for (final c in controllers) c.text]),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _changePassword() async {
    final v = await _ask(
      'تغییر رمز عبور',
      'رمز فعلی لازم است تا کسی که گوشی باز شما را در دست دارد نتواند حساب را بگیرد.',
      ['رمز فعلی', 'رمز تازه', 'تکرار رمز تازه'],
      action: 'تغییر',
    );
    if (v == null) return;
    if (v[1].length < 8) return _toast('رمز تازه باید دست‌کم ۸ نویسه باشد.');
    if (v[1] != v[2]) return _toast('رمز تازه و تکرارش یکی نیستند.');
    setState(() => _busy = true);
    try {
      await m.changePassword(v[0], v[1]);
      _toast('رمز عبور تغییر کرد.');
    } on ApiError catch (e) {
      _toast(switch (e.code) {
        'irm_bad_login' => 'رمز فعلی درست نیست.',
        'irm_rate_limited' => 'تلاش بیش از حد؛ بعدا دوباره امتحان کنید.',
        _ => 'انجام نشد (${e.code}).',
      });
    } catch (_) {
      _toast('اتصال به سرور برقرار نشد.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _makeBackup() async {
    final v = await _ask(
      'ساخت پشتیبان',
      'یک عبارت عبور برای این فایل انتخاب کنید. بدون آن، فایل برای هیچ‌کس، حتی خودتان، باز نمی‌شود و راهی برای بازیابی‌اش نیست.',
      ['عبارت عبور پشتیبان', 'تکرار عبارت عبور'],
      action: 'ساخت',
    );
    if (v == null) return;
    if (v[0].length < 8) return _toast('عبارت عبور باید دست‌کم ۸ نویسه باشد.');
    if (v[0] != v[1]) return _toast('عبارت عبور و تکرارش یکی نیستند.');
    setState(() => _busy = true);
    try {
      final bytes = await Backup.export(m, v[0]);
      final now = DateTime.now();
      final name =
          'irm-backup-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.irmbk';
      // A browser only lets a page save a file straight from a tap, and
      // building the backup took a moment, so ask for one more tap there.
      if (isWebApp && !await _confirmSave()) return;
      final saved = await saveBytes(name, bytes);
      _toast(saved ? 'فایل پشتیبان ذخیره شد.' : 'ذخیره انجام نشد.');
    } catch (_) {
      _toast('ساخت پشتیبان انجام نشد.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmSave() async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('پشتیبان آماده است'),
          content: const Text('برای نگه داشتن فایل، «ذخیره فایل» را بزنید.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('لغو'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('ذخیره فایل'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _restore() async {
    final Uint8List? picked = await pickFileBytes();
    if (picked == null || !mounted) return;
    final v = await _ask(
      'بازیابی پشتیبان',
      'عبارت عبوری را که هنگام ساخت این فایل انتخاب کردید وارد کنید.',
      ['عبارت عبور پشتیبان'],
      action: 'بازیابی',
    );
    if (v == null) return;
    setState(() => _busy = true);
    try {
      final s = await Backup.restore(m, picked, v[0]);
      _toast(
        s.messages == 0
            ? 'چیز تازه‌ای در این پشتیبان نبود.'
            : '${fa(s.messages)} پیام در ${fa(s.chats)} گفتگو بازیابی شد.',
      );
    } on BackupError catch (e) {
      _toast(switch (e.code) {
        'wrong_passphrase' => 'عبارت عبور درست نیست.',
        'other_account' => 'این پشتیبان متعلق به حساب دیگری است.',
        _ => 'این فایل پشتیبان معتبر نیست یا آسیب دیده است.',
      });
    } catch (_) {
      _toast('بازیابی انجام نشد.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(
    IconData icon,
    String title,
    String text,
    String button,
    VoidCallback onTap,
  ) {
    return Panel(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: Brand.gradient,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(fontSize: 13.5, color: Brand.muted(context)),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonal(
              style: Brand.tonal(context),
              onPressed: _busy ? null : onTap,
              child: Text(button),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('حساب و پشتیبان')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          _card(
            Icons.password_rounded,
            'رمز عبور',
            'با این رمز و نام کاربری می‌توانید بعد از نصب دوباره یا در گوشی تازه وارد حساب شوید.',
            'تغییر رمز',
            _changePassword,
          ),
          _card(
            Icons.cloud_download_rounded,
            'پشتیبان از گفتگوها',
            'یک فایل رمزشده از پیام‌ها، مخاطبان و گروه‌ها می‌سازد که هر جا بخواهید نگهش می‌دارید. عکس، ویدیو و صدا داخل آن نیست. بدون عبارت عبور باز نمی‌شود.',
            'ساخت پشتیبان',
            _makeBackup,
          ),
          _card(
            Icons.restore_rounded,
            'بازیابی گفتگوها',
            'بعد از ورود در گوشی تازه، فایل پشتیبان را انتخاب کنید تا تاریخچه برگردد. فقط پشتیبان همین حساب پذیرفته می‌شود و پیام تکراری ساخته نمی‌شود.',
            'انتخاب فایل',
            _restore,
          ),
        ],
      ),
    );
  }
}
