import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:irm_core/irm_core.dart';

import 'background.dart';
import 'buzz_sound.dart';
import 'platform/host.dart';
import 'platform/phone_push.dart';
import 'platform/push.dart';
import 'widgets/common.dart' show fa;

/// What the connection banner should say.
enum LinkState { ok, offline, firewall, serverError, authError }

/// Owns the [Messenger], the polling loop and connection status.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  /// Wraps an already opened [messenger]. [poll] is off in widget tests.
  AppState.withMessenger(this.messenger, this.wafLog, {bool poll = true})
    : live = poll {
    _sub = messenger.changes.listen((_) => notifyListeners());
    // A BUZZ for a chat that is not on screen still makes the phone buzz;
    // the open chat also shakes (see BuzzShaker).
    _buzzSub = messenger.incoming.listen((msg) {
      if (poll && msg.kind == 'buzz' && msg.chat != openChat) {
        buzzAlert(messenger);
      }
    });
    if (poll) {
      // The service stored something new while the UI was open.
      BackgroundDelivery.onData(notifyListeners);
      WidgetsBinding.instance.addObserver(this);
      _schedule(Duration.zero);
      unawaited(refreshAlertHealth());
    }
  }

  /// False in widget tests: no timers and no background network calls.
  final bool live;

  final Messenger messenger;
  final WafLog wafLog;

  LinkState link = LinkState.ok;
  String? linkDetail;

  /// Chat currently on screen; polling is faster while one is open.
  String? openChat;

  Timer? _timer;
  bool _foreground = true;
  int _failures = 0;
  bool _configLoaded = false;
  StreamSubscription<void>? _sub;
  StreamSubscription<ChatMessage>? _buzzSub;

  static const _keyName = dbKeyName;

  /// How messages reach this phone while the app is closed:
  /// - "push": Google wakes the app (like Telegram and WhatsApp); no
  ///   persistent notification, little battery. Needs Google services and
  ///   the server's push gateway; during an international internet cut
  ///   messages only arrive when the app is opened.
  /// - "always": a background service stays connected to the server; it
  ///   also works when only the domestic network is up, but shows a small
  ///   persistent notification and uses more battery.
  /// - "off": only while the app is open.
  /// Until the user chooses, "push" is used where it works.
  String get backgroundMode {
    final saved = messenger.db.kvString('bg_mode');
    if (saved != null) return saved;
    if ((messenger.db.kvInt('bg_enabled') ?? 1) == 0) return 'off';
    return PhonePush.active(messenger) ? 'push' : 'always';
  }

  bool get backgroundWanted => backgroundMode != 'off';
  bool get serviceWanted => backgroundMode == 'always';

  /// Starts (or stops) the background service to match the mode.
  Future<void> applyBackground({String? mode}) async {
    if (!BackgroundDelivery.supported || !messenger.isRegistered) return;
    if (mode != null) messenger.db.kvPutString('bg_mode', mode);
    if (serviceWanted) {
      await BackgroundDelivery.start();
    } else {
      await BackgroundDelivery.stop();
    }
    await refreshAlertHealth();
    notifyListeners();
  }

  /// Something keeps messages from arriving in the chosen mode.
  bool get alertProblem {
    final h = alertHealth;
    if (h == null || !backgroundWanted) return false;
    if (!h.notifications) return true;
    if (backgroundMode == 'push') return !PhonePush.active(messenger);
    return !h.battery || !h.running;
  }

  /// Anything stopping alerts on this phone; null where it does not apply.
  AlertHealth? alertHealth;

  Future<void> refreshAlertHealth() async {
    if (!live || !BackgroundDelivery.supported || !messenger.isRegistered) {
      return;
    }
    if (serviceWanted) await BackgroundDelivery.ensureRunning();
    alertHealth = await BackgroundDelivery.health();
    notifyListeners();
  }

  void _markUi(bool active) {
    try {
      messenger.db.kvPutInt(
        uiActiveKey,
        active ? DateTime.now().millisecondsSinceEpoch : 0,
      );
    } catch (_) {
      // Database briefly busy in the other isolate; the next tick retries.
    }
  }

  /// Opens the encrypted database. Its key lives in the platform keystore
  /// (Android Keystore / Windows credential store), never in a file. A
  /// browser has no keystore: there the key sits in the site's own storage.
  static Future<AppState> open() async {
    const secure = FlutterSecureStorage();
    var key = await secure.read(key: _keyName);
    if (key == null) {
      final r = Random.secure();
      key = List.generate(64, (_) => r.nextInt(16).toRadixString(16)).join();
      await secure.write(key: _keyName, value: key);
    }
    final (messenger, wafLog) = await openLocalMessenger(key);
    return AppState.withMessenger(messenger, wafLog);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A browser window that merely lost focus is still on screen.
    _foreground =
        state == AppLifecycleState.resumed ||
        (isWebApp && state == AppLifecycleState.inactive);
    _markUi(_foreground);
    if (_foreground) {
      // The service may have stored messages while we were away.
      notifyListeners();
      BackgroundDelivery.clearAlerts();
      _schedule(Duration.zero);
      unawaited(refreshAlertHealth());
    } else if (_othersDeliver) {
      // Leave fetching to the service or the push wake-up: whoever fetches
      // a message first is the only one that sees it, and only they raise
      // an alert.
      _timer?.cancel();
      if (messenger.isRegistered && serviceWanted) {
        unawaited(BackgroundDelivery.ensureRunning());
      }
    } else if (isWebApp) {
      // A hidden page is not allowed to keep polling; the server alerts
      // this browser instead, and the next look at the app fetches.
      _timer?.cancel();
      WebPush.idle(messenger);
    }
  }

  void setOpenChat(String? chat) {
    openChat = chat;
    if (chat != null) _schedule(Duration.zero);
  }

  /// While the UI is hidden, the background service or the push wake-up
  /// is in charge of fetching.
  bool get _othersDeliver =>
      !_foreground && BackgroundDelivery.supported && backgroundWanted;

  void _schedule(Duration d) {
    if (!live || (isWebApp && !_foreground) || _othersDeliver) return;
    _timer?.cancel();
    _timer = Timer(d, _tick);
  }

  /// Adaptive polling: quick in an open chat, slower on the list, slowest in
  /// the background, with exponential backoff and jitter after failures.
  Duration _nextDelay() {
    if (_failures > 0) {
      final secs = min(120, 5 * pow(2, min(_failures, 5)).toInt());
      return Duration(milliseconds: secs * 1000 + Random().nextInt(2000));
    }
    if (!_foreground) return const Duration(seconds: 60);
    return Duration(seconds: openChat != null ? 3 : 10);
  }

  Future<void> _tick() async {
    if (_foreground) _markUi(true);
    if (messenger.isRegistered && !_othersDeliver) await syncNow();
    _schedule(_nextDelay());
  }

  /// Runs one sync round and maps any failure to a user-facing state.
  Future<void> syncNow() async {
    try {
      await messenger.syncOnce();
      _failures = 0;
      if (!_configLoaded && !messenger.isPending) {
        // Once per launch: the pinned server key and the private relay list.
        _configLoaded = true;
        try {
          await messenger.refreshConfig();
          unawaited(WebPush.refresh(messenger));
          // Once Google push is known to work, the default mode may change
          // from the background service to push.
          unawaited(
            PhonePush.start(
              messenger,
              () => _schedule(Duration.zero),
            ).then((_) => applyBackground()),
          );
        } catch (_) {
          _configLoaded = false;
        }
      }
      _setLink(LinkState.ok, null);
    } on UntrustedResponse {
      _failures++;
      _setLink(LinkState.firewall, 'پاسخ دستکاری‌شده');
    } on WafBlock catch (e) {
      _failures++;
      if (e.serverDown) {
        _setLink(
          LinkState.serverError,
          'سرور موقتا پاسخ نداد، کد ${fa(e.evidence['status'])}',
        );
      } else {
        _setLink(LinkState.firewall, 'کد ${fa(e.evidence['status'])}');
      }
    } on RelayError {
      _failures++;
      _setLink(LinkState.serverError, 'سرور و رله هر دو در دسترس نبودند');
    } on ApiError catch (e) {
      _failures++;
      _setLink(
        e.status == 401 ? LinkState.authError : LinkState.serverError,
        e.code,
      );
    } on TimeoutException {
      _failures++;
      _setLink(LinkState.offline, 'timeout');
    } catch (e) {
      _failures++;
      _setLink(
        LinkState.offline,
        isConnectionError(e) ? null : e.runtimeType.toString(),
      );
    }
  }

  void _setLink(LinkState s, String? detail) {
    if (link == s && linkDetail == detail) return;
    link = s;
    linkDetail = detail;
    notifyListeners();
  }

  String get linkText => switch (link) {
    LinkState.ok => '',
    LinkState.offline => 'اتصال به سرور برقرار نیست؛ پیام‌ها در صف می‌مانند',
    LinkState.firewall =>
      'فایروال سرور جلوی اتصال را گرفته است (${linkDetail ?? ''})',
    LinkState.serverError =>
      'مشکل موقت سرور (${linkDetail ?? ''})؛ پیام‌ها در صف می‌مانند و خودکار ارسال می‌شوند',
    LinkState.authError =>
      'این دستگاه از حساب خارج شده است؛ احتمالا در گوشی دیگری وارد شده‌اید',
  };

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _buzzSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
