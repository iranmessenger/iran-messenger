import 'package:irm_core/irm_core.dart';

/// Browsers are woken by web push instead (see push.dart).
class PhonePush {
  static bool get supported => false;
  static Future<void> start(Messenger m, void Function() wake) async {}
  static bool active(Messenger m) => false;
}
