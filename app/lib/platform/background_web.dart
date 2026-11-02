/// A browser cannot keep a service running; new-message alerts come from
/// web push instead (see push.dart). Same surface as the phone version.
const dbKeyName = 'irm_db_key_v1';
const uiActiveKey = 'ui_active';

class BackgroundDelivery {
  static bool get supported => false;
  static void init() {}
  static void onData(void Function() changed) {}
  static Future<bool> get running async => false;
  static Future<bool> start() async => false;
  static Future<void> stop() async {}
  static Future<void> clearAlerts() async {}
  static Future<void> ensureRunning() async {}
  static Future<AlertHealth?> health() async => null;
  static Future<void> askNotifications() async {}
  static Future<void> askBattery() async {}
  static Future<void> openAutoStart() async {}
}

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
  final String maker;
  bool get ok => notifications && battery && running;
}
