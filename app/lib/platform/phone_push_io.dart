import 'package:irm_core/irm_core.dart';

/// No Google wake-ups: they need Google services and a server abroad,
/// and stop working the moment the international internet is cut.
/// Phones stay reachable through the background service instead.
class PhonePush {
  static bool get supported => false;
  static Future<void> start(Messenger m, void Function() wake) async {}
  static bool active(Messenger m) => false;
}
