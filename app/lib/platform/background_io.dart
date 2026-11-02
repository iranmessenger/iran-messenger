import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:irm_core/irm_core.dart';

import '../buzz_sound.dart';
import 'host_io.dart';

/// Background delivery without any push service.
///
/// An Android foreground service keeps a small Dart isolate alive that polls
/// the server and raises a local notification for new messages. Nothing is
/// routed through Google or any third party. The UI and this isolate share
/// the encrypted database; the sync lease in irm_core keeps them from
/// syncing at the same moment.
const dbKeyName = 'irm_db_key_v1';
const _serviceId = 4107;
const _pollMs = 15000;

/// The UI writes this timestamp while it is on screen; the service stays
/// quiet during that time so requests are not doubled.
const uiActiveKey = 'ui_active';

const _messageChannel = AndroidNotificationDetails(
  'messages',
  'پیام‌های جدید',
  channelDescription: 'اعلان رسیدن پیام تازه',
  importance: Importance.high,
  priority: Priority.high,
  category: AndroidNotificationCategory.message,
);

/// A BUZZ rings with the sound chosen in settings. Android fixes a
/// channel's sound when it is created, so every sound has its own channel.
AndroidNotificationDetails _buzzChannel(String sound) =>
    AndroidNotificationDetails(
      'buzz_$sound',
      'BUZZ: ${buzzSounds[sound]}',
      channelDescription: 'وقتی کسی برای شما BUZZ می‌فرستد',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.message,
      playSound: sound != 'none',
      sound: sound == 'none'
          ? null
          : RawResourceAndroidNotificationSound('buzz_$sound'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 160, 90, 160, 90, 260]),
    );

Future<Messenger> openMessenger() async {
  final key = await const FlutterSecureStorage().read(key: dbKeyName);
  if (key == null) throw StateError('no database key yet');
  return (await openLocalMessenger(key)).$1;
}

bool uiActive(Messenger m) {
  final t = m.db.kvInt(uiActiveKey) ?? 0;
  return DateTime.now().millisecondsSinceEpoch - t < 20000;
}

Future<void> _initAlerts(FlutterLocalNotificationsPlugin n) => n.initialize(
  settings: const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ),
);

/// Sender (or group) only. Message text never appears on the lock screen.
Future<void> showMessageAlert(
  FlutterLocalNotificationsPlugin n,
  Messenger m,
  ChatMessage msg,
) async {
  if (msg.kind == 'system') return;
  await n.show(
    id: msg.chat.hashCode & 0x7fffffff,
    title: m.chatTitle(msg.chat),
    body: msg.kind == 'buzz'
        ? '📳 ${m.nameOf(msg.sender)} برای شما BUZZ فرستاد!'
        : msg.kind == 'poll'
        ? '📊 نظرسنجی تازه از ${m.nameOf(msg.sender)}'
        : m.mentionsMe(msg.body)
        ? '${m.nameOf(msg.sender)} از شما نام برد'
        : msg.chat.startsWith('g:')
        ? 'پیام جدید از ${m.nameOf(msg.sender)}'
        : 'پیام جدید',
    notificationDetails: NotificationDetails(
      android: msg.kind == 'buzz'
          ? _buzzChannel(buzzSoundOf(m))
          : _messageChannel,
    ),
    payload: msg.chat,
  );
}

/// A push wake-up arrived while the app was not on screen: fetch now and
/// raise alerts. If the background service is already fetching, it holds
/// the sync lease and raises the alerts itself, so this returns at once.
Future<void> syncFromWakeUp() async {
  final n = FlutterLocalNotificationsPlugin();
  await _initAlerts(n);
  final m = await openMessenger();
  final shown = <Future<void>>[];
  final sub = m.incoming.listen(
    (msg) => shown.add(showMessageAlert(n, m, msg)),
  );
  try {
    if (m.isRegistered && !uiActive(m)) await m.syncOnce();
    await Future.wait(shown);
  } finally {
    await sub.cancel();
    m.dispose();
    m.db.close();
  }
}

@pragma('vm:entry-point')
void backgroundStart() {
  FlutterForegroundTask.setTaskHandler(SyncTaskHandler());
}

class SyncTaskHandler extends TaskHandler {
  Messenger? _m;
  final _notifications = FlutterLocalNotificationsPlugin();
  StreamSubscription<ChatMessage>? _sub;
  bool _busy = false;
  int _failures = 0;
  int _skip = 0;
  int _tickCount = 0;
  DateTime _lastActivity = DateTime.now();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    WidgetsFlutterBinding.ensureInitialized();
    await _initAlerts(_notifications);
    await _open();
  }

  Future<void> _open() async {
    try {
      final m = await openMessenger();
      _m = m;
      _sub = m.incoming.listen(_notify);
    } catch (_) {
      // Not registered yet or keystore unavailable; retried on the next tick.
    }
  }

  Future<void> _notify(ChatMessage msg) async {
    final m = _m;
    if (m != null) await showMessageAlert(_notifications, m, msg);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_tick());
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      if (_m == null) await _open();
      final m = _m;
      if (m == null || !m.isRegistered) return;
      if (uiActive(m)) {
        // The user was just in the app: a reply may follow soon.
        _lastActivity = DateTime.now();
        return;
      }
      // After failures, skip ticks: 15s, 30s, then 45 seconds at most.
      if (_skip > 0) {
        _skip--;
        return;
      }
      // Quick right after activity, then slower: 15 s for two minutes,
      // 45 s up to a quarter of an hour, then once a minute.
      final idle = DateTime.now().difference(_lastActivity);
      final every = idle < const Duration(minutes: 2)
          ? 1
          : idle < const Duration(minutes: 15)
          ? 3
          : 4;
      if (++_tickCount % every != 0) return;
      try {
        if (await m.syncOnce()) {
          _lastActivity = DateTime.now();
          FlutterForegroundTask.sendDataToMain('changed');
        }
        _failures = 0;
      } catch (_) {
        _failures++;
        _skip = _failures >= 3 ? 2 : _failures - 1;
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _sub?.cancel();
    _m?.dispose();
    _m?.db.close();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

/// Starts, stops and configures the service from the UI side.
class BackgroundDelivery {
  static bool get supported => Platform.isAndroid;

  /// Calls [changed] when the service stored something new.
  static void onData(void Function() changed) {
    if (supported) FlutterForegroundTask.addTaskDataCallback((_) => changed());
  }

  static void init() {
    if (!supported) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // Lowest importance: folded away, no status-bar icon, no sound.
        channelId: 'connection_quiet',
        channelName: 'اتصال دائمی',
        channelDescription:
            'تا وقتی این اعلان هست، برنامه می‌تواند پیام تازه را دریافت کند.',
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_pollMs),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        // No permanent wake lock: it kept the processor awake all day.
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
  }

  static Future<bool> get running async =>
      supported && await FlutterForegroundTask.isRunningService;

  /// Asks for notification permission and exemption from battery
  /// optimisation, then starts the service. Returns false if it could not.
  static Future<bool> start() async {
    if (!supported) return false;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return _launch();
  }

  /// Restarts a service the phone stopped, without asking for anything.
  static Future<void> ensureRunning() async {
    if (!supported) return;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      return;
    }
    await _launch();
  }

  static Future<bool> _launch() async {
    if (await FlutterForegroundTask.isRunningService) return true;
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.remoteMessaging],
      notificationTitle: 'همگام‌سازی',
      notificationText: '',
      callback: backgroundStart,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    if (supported) await FlutterForegroundTask.stopService();
  }

  /// Clears message alerts once the user is looking at the app.
  static Future<void> clearAlerts() async {
    if (!supported) return;
    await FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.cancelAll();
  }

  /// What could keep alerts from arriving, for the status screen.
  static Future<AlertHealth?> health() async {
    if (!supported) return null;
    String maker = '';
    try {
      maker = await _device.invokeMethod<String>('maker') ?? '';
    } catch (_) {}
    return AlertHealth(
      notifications:
          await FlutterForegroundTask.checkNotificationPermission() ==
          NotificationPermission.granted,
      battery: await FlutterForegroundTask.isIgnoringBatteryOptimizations,
      running: await FlutterForegroundTask.isRunningService,
      maker: maker,
    );
  }

  static Future<void> askNotifications() =>
      FlutterForegroundTask.requestNotificationPermission();

  static Future<void> askBattery() =>
      FlutterForegroundTask.requestIgnoreBatteryOptimization();

  /// Opens the maker's "auto-start" list, or this app's settings page.
  static Future<void> openAutoStart() async {
    try {
      await _device.invokeMethod<bool>('autostart');
    } catch (_) {}
  }
}

const _device = MethodChannel('irm/device');

class AlertHealth {
  const AlertHealth({
    required this.notifications,
    required this.battery,
    required this.running,
    required this.maker,
  });
  final bool notifications;
  final bool battery;
  final bool running;

  /// Lower-case manufacturer, such as "xiaomi" or "samsung".
  final String maker;

  bool get ok => notifications && battery && running;
}
