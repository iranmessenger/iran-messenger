import 'package:irm_core/irm_core.dart';

/// Phones use the background service instead (see background.dart); this
/// is the same surface with nothing behind it.
class WebPush {
  static bool get supported => false;
  static bool get needsInstall => false;
  static String get permission => 'denied';
  static bool isOn(Messenger m) => false;
  static Future<String?> enable(Messenger m) async => 'unsupported';
  static Future<void> disable(Messenger m) async {}
  static Future<void> refresh(Messenger m) async {}
  static Future<void> idle(Messenger m) async {}
}
