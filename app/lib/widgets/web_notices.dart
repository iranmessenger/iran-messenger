import 'package:flutter/material.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../platform/push.dart';
import '../theme.dart';
import 'common.dart';

/// Parts of the interface that only exist in the web app: the frame on
/// wide screens, the "add to home screen" guide for iPhones, and the
/// switch for new-message alerts.

/// Keeps the phone-shaped layout on a desktop monitor.
class WebFrame extends StatelessWidget {
  const WebFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isWebApp || MediaQuery.sizeOf(context).width <= 620) return child;
    return ColoredBox(
      color: Brand.navy,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ClipRect(child: child),
        ),
      ),
    );
  }
}

/// How to put the app on an iPhone's home screen, and why.
class InstallSteps extends StatelessWidget {
  const InstallSteps({super.key});

  Widget _step(BuildContext context, String n, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              gradient: Brand.gradient,
              shape: BoxShape.circle,
            ),
            child: Text(
              n,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(height: 1.6))),
          const SizedBox(width: 8),
          Icon(icon, color: Theme.of(context).colorScheme.primary),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _step(
          context,
          '۱',
          Icons.ios_share_rounded,
          'در سافاری دکمه اشتراک‌گذاری را بزنید (مربعی با پیکان رو به بالا).',
        ),
        _step(
          context,
          '۲',
          Icons.add_box_outlined,
          'گزینه افزودن به صفحه اصلی را انتخاب و تایید کنید. نام انگلیسی آن Add to Home Screen است.',
        ),
        _step(
          context,
          '۳',
          Icons.touch_app_rounded,
          'سافاری را ببندید و برنامه را با آیکون ایران مسنجر از صفحه اصلی باز کنید.',
        ),
      ],
    );
  }
}

/// On an iPhone, shown before sign-in while the app still runs inside
/// Safari: an account made there does not carry over to the home screen
/// app, and alerts only work in the installed one.
class InstallGate extends StatefulWidget {
  const InstallGate({super.key, required this.child});
  final Widget child;

  @override
  State<InstallGate> createState() => _InstallGateState();
}

class _InstallGateState extends State<InstallGate> {
  bool _skipped = false;

  @override
  Widget build(BuildContext context) {
    if (_skipped || !WebPush.needsInstall) return widget.child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Panel(
              radius: 24,
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'اول برنامه را نصب کنید',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'روی آیفون، اعلان پیام تازه فقط وقتی کار می‌کند که برنامه روی صفحه اصلی گوشی باشد. حسابی هم که داخل سافاری بسازید به برنامه نصب‌شده منتقل نمی‌شود.',
                    style: TextStyle(
                      height: 1.7,
                      color: Brand.muted(context),
                      fontSize: 13.5,
                    ),
                  ),
                  const InstallSteps(),
                  const SizedBox(height: 18),
                  Center(
                    child: TextButton(
                      onPressed: () => setState(() => _skipped = true),
                      child: Text(
                        'فعلا در مرورگر ادامه می‌دهم',
                        style: TextStyle(color: Brand.muted(context)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _pushProblem(String code) => switch (code) {
  'denied' =>
    'اجازه اعلان داده نشد. از تنظیمات مرورگر یا گوشی، اعلان را برای این برنامه آزاد کنید.',
  'no_key' => 'سرور هنوز آماده ارسال اعلان نیست؛ کمی بعد دوباره امتحان کنید.',
  'unsupported' => 'این مرورگر از اعلان پشتیبانی نمی‌کند.',
  _ => 'روشن کردن اعلان انجام نشد؛ اتصال را بررسی و دوباره امتحان کنید.',
};

Future<void> _turnOn(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final problem = await WebPush.enable(state.messenger);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        problem == null ? 'اعلان پیام تازه روشن شد.' : _pushProblem(problem),
      ),
    ),
  );
}

/// Under the header of the chat list until alerts are on (or declined).
class PushBanner extends StatelessWidget {
  const PushBanner({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final m = state.messenger;
    if (!isWebApp ||
        WebPush.isOn(m) ||
        m.db.kvInt('push_banner_off') == 1 ||
        WebPush.permission == 'denied' && WebPush.supported) {
      return const SizedBox.shrink();
    }
    final install = WebPush.needsInstall;
    if (!install && !WebPush.supported) return const SizedBox.shrink();
    return Panel(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Icon(
            Icons.notifications_active_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              install
                  ? 'برای گرفتن اعلان، برنامه را به صفحه اصلی گوشی اضافه کنید.'
                  : 'اعلان پیام تازه خاموش است.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () => install
                ? showDialog<void>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('افزودن به صفحه اصلی'),
                      content: const SingleChildScrollView(
                        child: InstallSteps(),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d),
                          child: const Text('فهمیدم'),
                        ),
                      ],
                    ),
                  )
                : _turnOn(context, state),
            child: Text(install ? 'راهنما' : 'روشن کردن'),
          ),
          IconButton(
            tooltip: 'بستن',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () {
              m.db.kvPutInt('push_banner_off', 1);
              m.notify();
            },
          ),
        ],
      ),
    );
  }
}

/// The alerts switch on the connection status screen.
class PushTile extends StatelessWidget {
  const PushTile({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!isWebApp) return const SizedBox.shrink();
    final m = state.messenger;
    if (WebPush.needsInstall) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.notifications_off_outlined),
        title: Text('اعلان پیام تازه'),
        subtitle: Text(
          'روی آیفون، اول باید برنامه را از منوی اشتراک‌گذاری سافاری به صفحه اصلی اضافه و از همان‌جا باز کنید.',
        ),
      );
    }
    if (!WebPush.supported) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.notifications_off_outlined),
        title: Text('اعلان پیام تازه'),
        subtitle: Text('این مرورگر از اعلان پشتیبانی نمی‌کند.'),
      );
    }
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('اعلان پیام تازه'),
      subtitle: Text(
        WebPush.permission == 'denied'
            ? 'اعلان برای این برنامه در تنظیمات مرورگر یا گوشی بسته شده است.'
            : 'وقتی برنامه بسته است، رسیدن پیام تازه را خبر می‌دهد. متن پیام و نام فرستنده در اعلان نمی‌آید.',
      ),
      value: WebPush.isOn(m),
      onChanged: (on) => on ? _turnOn(context, state) : WebPush.disable(m),
    );
  }
}
