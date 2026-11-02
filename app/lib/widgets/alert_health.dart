import 'package:flutter/material.dart';

import '../app_state.dart';
import '../background.dart';
import '../platform/phone_push.dart';
import 'common.dart';
import 'motion.dart';

/// Phone settings that decide whether new-message alerts arrive: the
/// notification permission, the battery exemption, the background service
/// itself, and the maker's own "auto-start" list.

/// Where each maker hides its auto-start or battery switch.
String _makerHint(String maker) {
  if (['xiaomi', 'redmi', 'poco'].contains(maker)) {
    return 'در برنامه «امنیت»، اجرای خودکار را برای ایران مسنجر روشن کنید. در تنظیمات باتری برنامه هم گزینه «بدون محدودیت» را بزنید.';
  }
  if (maker == 'samsung') {
    return 'در تنظیمات باتری، ایران مسنجر را از فهرست برنامه‌های «در خواب» بیرون بیاورید و استفاده «نامحدود» را انتخاب کنید.';
  }
  if (['huawei', 'honor'].contains(maker)) {
    return 'در «راه‌اندازی برنامه‌ها»، مدیریت خودکار ایران مسنجر را خاموش کنید و هر سه گزینه دستی را روشن بگذارید.';
  }
  if (['oppo', 'realme', 'oneplus'].contains(maker)) {
    return 'اجرای خودکار و فعالیت در پس‌زمینه را برای ایران مسنجر مجاز کنید.';
  }
  if (['vivo', 'iqoo'].contains(maker)) {
    return 'در مدیریت مجوزها، اجرای خودکار و مصرف باتری در پس‌زمینه را برای ایران مسنجر مجاز کنید.';
  }
  return 'اگر گوشی برنامه را بعد از مدتی می‌بندد، در تنظیمات برنامه اجرای خودکار را روشن کنید و باتری را «بدون محدودیت» بگذارید.';
}

/// Warning on the chat list while alerts cannot arrive.
class AlertHealthBanner extends StatefulWidget {
  const AlertHealthBanner({super.key, required this.state});
  final AppState state;

  @override
  State<AlertHealthBanner> createState() => _AlertHealthBannerState();
}

class _AlertHealthBannerState extends State<AlertHealthBanner> {
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final h = s.alertHealth;
    if (_hidden || h == null || !s.alertProblem) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Icon(Icons.notifications_off_rounded, color: scheme.error),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'اعلان پیام تازه ممکن است نرسد.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: AlertHealthPanel(state: s),
                ),
              ),
            ),
            child: const Text('درست کردن'),
          ),
          IconButton(
            tooltip: 'بستن',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => setState(() => _hidden = true),
          ),
        ],
      ),
    );
  }
}

/// Checklist with a button next to each problem.
class AlertHealthPanel extends StatelessWidget {
  const AlertHealthPanel({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final h = state.alertHealth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                BrandLottie(
                  'bell',
                  size: 36,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'دریافت پیام وقتی برنامه بسته است',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final (mode, title, text) in const [
              (
                'push',
                'کم‌مصرف، مثل تلگرام',
                'بدون اعلان ثابت؛ گوگل برنامه را برای پیام تازه بیدار می‌کند. در قطعی اینترنت بین‌الملل، پیام فقط با باز کردن برنامه می‌رسد.',
              ),
              (
                'always',
                'همیشه وصل',
                'در قطعی اینترنت بین‌الملل هم پیام می‌رسد. یک اعلان کوچک و بی‌صدا در پایین فهرست اعلان‌ها می‌ماند و باتری بیشتری مصرف می‌شود.',
              ),
              ('off', 'خاموش', 'پیام فقط وقتی برنامه باز است می‌رسد.'),
            ])
              if (mode != 'push' || PhonePush.supported)
                _ModeTile(
                  selected: state.backgroundMode == mode,
                  title: title,
                  text: text,
                  onTap: () => state.applyBackground(mode: mode),
                ),
            if (state.backgroundWanted && h != null) ...[
              const SizedBox(height: 4),
              if (state.backgroundMode == 'push')
                _Check(
                  ok: PhonePush.active(state.messenger),
                  title: 'بیدار شدن با پوش گوگل',
                  bad:
                      'روی این گوشی کار نمی‌کند (سرویس‌های گوگل نیست، یا دروازه پوش روی سرور تنظیم نشده). حالت «همیشه وصل» را انتخاب کنید.',
                  action: '',
                  onFix: () {},
                ),
              _Check(
                ok: h.notifications,
                title: 'اجازه نمایش اعلان',
                bad: 'بدون این اجازه هیچ اعلانی دیده نمی‌شود.',
                action: 'اجازه بده',
                onFix: () => _fix(BackgroundDelivery.askNotifications),
              ),
              if (state.serviceWanted) ...[
                _Check(
                  ok: h.battery,
                  title: 'معافیت از بهینه‌سازی باتری',
                  bad:
                      'وقتی گوشی خاموش و بی‌حرکت است، اینترنت برنامه قطع می‌شود.',
                  action: 'معاف کن',
                  onFix: () => _fix(BackgroundDelivery.askBattery),
                ),
                _Check(
                  ok: h.running,
                  title: 'سرویس دریافت پیام',
                  bad: 'سرویس متوقف شده است.',
                  action: 'روشن کن',
                  onFix: () => _fix(BackgroundDelivery.start),
                ),
                _Check(
                  ok: null,
                  title: 'اجرای خودکار گوشی',
                  bad: _makerHint(h.maker),
                  action: 'باز کن',
                  onFix: BackgroundDelivery.openAutoStart,
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  Future<void> _fix(Future<Object?> Function() ask) async {
    await ask();
    await state.refreshAlertHealth();
  }
}

/// One choice of how messages arrive in the background.
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.selected,
    required this.title,
    required this.text,
    required this.onTap,
  });
  final bool selected;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Panel(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_off_rounded,
            color: selected ? primary : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(text, style: const TextStyle(fontSize: 12.5, height: 1.6)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({
    required this.ok,
    required this.title,
    required this.bad,
    required this.action,
    required this.onFix,
  });

  /// null: the phone cannot tell us, so the hint is always shown.
  final bool? ok;
  final String title;
  final String bad;
  final String action;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ok == null
        ? scheme.primary
        : ok!
        ? const Color(0xFF10B981)
        : scheme.error;
    return Panel(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok == null
                ? Icons.info_outline_rounded
                : ok!
                ? Icons.check_circle_rounded
                : Icons.error_rounded,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (ok != true)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      bad,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (ok != true && action.isNotEmpty)
            TextButton(onPressed: onFix, child: Text(action)),
        ],
      ),
    );
  }
}
