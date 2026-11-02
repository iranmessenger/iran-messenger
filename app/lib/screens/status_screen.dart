import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../background.dart';
import '../theme.dart';
import '../widgets/alert_health.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import '../widgets/web_notices.dart';

/// Connection status plus the firewall incident log, formatted so it can be
/// pasted straight into a support ticket for the hosting provider.
class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key, required this.state});
  final AppState state;

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  List<Map<String, dynamic>> _events = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = <Map<String, dynamic>>[];
    for (final line in await widget.state.wafLog.lines()) {
      try {
        events.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (mounted) setState(() => _events = events.reversed.toList());
  }

  String _report() {
    final b = StringBuffer('گزارش مسدودسازی فایروال\n');
    for (final e in _events) {
      final headers = (e['response_headers'] as Map?) ?? {};
      b
        ..writeln('---')
        ..writeln('زمان محلی: ${e['time_local']}')
        ..writeln('زمان UTC: ${e['time_utc']}')
        ..writeln('درخواست: ${e['method']} ${e['url']}')
        ..writeln('حجم بدنه درخواست: ${e['request_body_bytes']} بایت')
        ..writeln('کد پاسخ: ${e['status']}')
        ..writeln(
          'مدت تا پاسخ: ${e['elapsed_ms'] == null ? 'ثبت نشده' : '${(e['elapsed_ms'] as num) / 1000} ثانیه'}',
        )
        ..writeln('Server: ${headers['server'] ?? '-'}')
        ..writeln('Content-Type: ${headers['content-type'] ?? '-'}')
        ..writeln('تکرار: ${e['reproduce']}');
    }
    return b.toString();
  }

  /// The connection at a glance: a check when the server answers,
  /// otherwise what is wrong.
  Widget _hero(BuildContext context) {
    final s = widget.state;
    final ok = s.link == LinkState.ok;
    return Panel(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Column(
        children: [
          ok
              ? const BrandLottie('check', size: 92)
              : Icon(
                  Icons.cloud_off_rounded,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
          const SizedBox(height: 6),
          Text(
            ok ? 'متصل' : s.linkText,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            s.messenger.site ?? '',
            textDirection: TextDirection.ltr,
            style: TextStyle(fontSize: 13, color: Brand.muted(context)),
          ),
        ],
      ),
    );
  }

  Widget _fact(IconData icon, String title, String value) => ListTile(
    dense: true,
    leading: Icon(icon),
    title: Text(title),
    trailing: Text(
      value,
      style: TextStyle(fontSize: 13, color: Brand.muted(context)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final m = s.messenger;
    return Scaffold(
      appBar: AppBar(title: const Text('وضعیت اتصال')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _hero(context),
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _fact(Icons.person_rounded, 'نام شما', m.myName),
                _fact(
                  Icons.alt_route_rounded,
                  'مسیر اتصال',
                  m.routeLabel == 'direct'
                      ? 'مستقیم'
                      : 'از راه رله ${m.routeLabel}',
                ),
                _fact(
                  Icons.verified_rounded,
                  'امضای سرور',
                  m.db.kvString('server_key') == null
                      ? 'هنوز دریافت نشده'
                      : 'بررسی می‌شود',
                ),
                _fact(
                  Icons.lock_rounded,
                  'پایگاه داده محلی',
                  m.db.cipherAvailable ? 'رمزشده' : 'بدون رمز',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              await s.syncNow();
              await _load();
            },
            icon: const Icon(Icons.sync_rounded),
            label: const Text('همگام‌سازی دوباره'),
          ),
          PushTile(state: s),
          if (BackgroundDelivery.supported) ...[
            const SizedBox(height: 12),
            AlertHealthPanel(state: s),
          ],
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text(
                  'مسدودسازی‌های فایروال (${fa(_events.length)})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_events.isNotEmpty)
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _report()));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('گزارش در حافظه موقت کپی شد'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('کپی گزارش'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'هر بار که چیزی جلوتر از وردپرس (فایروال یا صفحه CAPTCHA) به جای افزونه پاسخ بدهد، اینجا ثبت می‌شود. این گزارش هیچ پیام یا کلیدی ندارد و برای ارسال به پشتیبانی هاست مناسب است.',
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: Brand.muted(context),
            ),
          ),
          const SizedBox(height: 8),
          if (_events.isEmpty) const Text('موردی ثبت نشده است.'),
          for (final e in _events)
            Panel(
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${e['time_local']}',
                      textDirection: TextDirection.ltr,
                    ),
                    Text(
                      '${e['method']} ${e['url']}',
                      textDirection: TextDirection.ltr,
                    ),
                    Text('کد پاسخ: ${e['status']}'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
