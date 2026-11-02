import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:irm_core/irm_core.dart';

/// New-message alerts while the web app is closed.
///
/// The browser subscribes to its vendor's push service with this server's
/// public key and hands the subscription to the server. From then on the
/// server can wake the service worker (web/sw.js), which shows a fixed
/// "new message" alert. Nothing about the message travels that way.
class WebPush {
  static web.Navigator get _nav => web.window.navigator;

  static bool get _ios {
    final ua = _nav.userAgent;
    return RegExp('iPhone|iPad|iPod').hasMatch(ua) ||
        (ua.contains('Macintosh') && _nav.maxTouchPoints > 1);
  }

  static bool get _installed =>
      web.window.matchMedia('(display-mode: standalone)').matches ||
      (_nav as JSObject).getProperty<JSAny?>('standalone'.toJS).dartify() ==
          true;

  /// On an iPhone, alerts (and a storage area of its own) exist only once
  /// the app has been added to the home screen and is opened from there.
  static bool get needsInstall => _ios && !_installed;

  static bool get supported =>
      (web.window as JSObject).has('PushManager') &&
      (web.window as JSObject).has('Notification') &&
      (_nav as JSObject).has('serviceWorker');

  /// "default", "granted" or "denied".
  static String get permission =>
      supported ? web.Notification.permission : 'denied';

  /// Whether the user turned alerts on in this browser.
  static bool isOn(Messenger m) =>
      supported && permission == 'granted' && m.db.kvInt('push_on') == 1;

  static Future<web.ServiceWorkerRegistration> _worker() =>
      _nav.serviceWorker.ready.toDart.timeout(const Duration(seconds: 15));

  static String _b64u(JSArrayBuffer? buffer) => buffer == null
      ? ''
      : base64Url.encode(buffer.toDart.asUint8List()).replaceAll('=', '');

  static Future<web.PushSubscription> _subscribe(
    web.ServiceWorkerRegistration worker,
    String key,
  ) {
    final raw = Uint8List.fromList(
      base64Url.decode(key.padRight((key.length + 3) & ~3, '=')),
    );
    return worker.pushManager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            userVisibleOnly: true,
            applicationServerKey: raw.toJS,
          ),
        )
        .toDart;
  }

  static Future<void> _register(Messenger m, web.PushSubscription sub) async {
    // Sent again only when the subscription or the device changed.
    final mark = '${m.db.kvInt('device_id')}|${sub.endpoint}';
    if (m.db.kvString('push_sent') == mark) return;
    await m.pushSubscribe(
      sub.endpoint,
      _b64u(sub.getKey('p256dh')),
      _b64u(sub.getKey('auth')),
    );
    m.db.kvPutString('push_sent', mark);
  }

  /// Asks for permission and subscribes. Must be called straight from a
  /// tap. Returns null on success, otherwise why it did not work:
  /// unsupported | no_key | denied | failed.
  static Future<String?> enable(Messenger m) async {
    if (!supported) return 'unsupported';
    final key = m.vapidKey;
    if (key == null) return 'no_key';
    try {
      final answer = (await web.Notification.requestPermission().toDart).toDart;
      if (answer != 'granted') return 'denied';
      final worker = await _worker();
      var sub = await worker.pushManager.getSubscription().toDart;
      if (sub == null) {
        sub = await _subscribe(worker, key);
      } else if (m.db.kvString('push_key') != key) {
        // Made for another server key: start over.
        await sub.unsubscribe().toDart;
        sub = await _subscribe(worker, key);
      }
      m.db.kvPutString('push_key', key);
      m.db.kvPutString('push_sent', '');
      await _register(m, sub);
      m.db.kvPutInt('push_on', 1);
      m.notify();
      return null;
    } catch (_) {
      return 'failed';
    }
  }

  static Future<void> disable(Messenger m) async {
    m.db.kvPutInt('push_on', 0);
    m.db.kvPutString('push_sent', '');
    m.notify();
    try {
      final sub = await (await _worker()).pushManager.getSubscription().toDart;
      await sub?.unsubscribe().toDart;
      await m.pushUnsubscribe();
    } catch (_) {
      // Offline: the server drops the subscription when it stops working.
    }
  }

  /// Keeps the server's copy current: browsers replace subscriptions from
  /// time to time, and signing in again creates a new device.
  static Future<void> refresh(Messenger m) async {
    if (!isOn(m) || !m.isRegistered || m.isPending) return;
    final key = m.vapidKey;
    if (key == null) return;
    try {
      final worker = await _worker();
      final sub =
          await worker.pushManager.getSubscription().toDart ??
          await _subscribe(worker, key);
      await _register(m, sub);
    } catch (_) {
      // Tried again on the next launch.
    }
  }

  /// The app left the screen: from now on the server should alert.
  static Future<void> idle(Messenger m) async {
    if (!isOn(m) || !m.isRegistered || m.isPending) return;
    try {
      await m.pushIdle();
    } catch (_) {
      // The server notices by itself a few seconds later.
    }
  }
}
