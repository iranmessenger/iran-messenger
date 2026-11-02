import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'files.dart';
import 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';

/// The server answered with a normal API error (JSON body from the plugin).
class ApiError implements Exception {
  ApiError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => 'ApiError($status, $code): $message';
}

/// Something in front of WordPress (WAF, CAPTCHA page, host error page)
/// answered instead of the plugin. [evidence] is safe to hand to the host:
/// it never contains signatures, tokens or message bodies.
/// An answer arrived whose server signature is missing or wrong: something
/// between this device and the server changed or invented it.
class UntrustedResponse implements Exception {
  UntrustedResponse(this.via);
  final String via;
  @override
  String toString() => 'UntrustedResponse(via $via)';
}

/// A private relay: another site that forwards requests to the server.
class Relay {
  Relay(this.url, this.key);
  final String url;
  final String key;
}

/// A relay answered for itself, for example that it could not reach the
/// server either. Its own messages carry no server signature; that is not
/// a sign of tampering.
class RelayError implements Exception {
  RelayError(this.via, this.code);
  final String via;
  final String code;

  @override
  String toString() => 'RelayError($via, $code)';
}

class WafBlock implements Exception {
  WafBlock(this.evidence);

  /// 502/503/504: the proxy got no answer from the server behind it
  /// (overloaded, restarting or too slow), rather than refusing us.
  bool get serverDown => const {502, 503, 504}.contains(evidence['status']);
  final Map<String, dynamic> evidence;
  @override
  String toString() =>
      'WafBlock(${evidence['status']} ${evidence['method']} ${evidence['url']})';
}

/// REST client for `/wp-json/irm/v1`. Authenticated calls are signed with
/// the device's Ed25519 key; no password or bearer token is sent.
class ApiClient {
  ApiClient(this.siteUrl, {http.Client? httpClient, this.wafLog})
    : _http = httpClient ?? http.Client();

  final String siteUrl;
  final http.Client _http;

  /// Receives one JSON line per suspected WAF block.
  final WafSink? wafLog;

  int? deviceId;
  SimpleKeyPair? authKey;

  /// Pinned Ed25519 public key of the server. When set, every answer must
  /// carry a valid signature; relays are only used once it is known.
  List<int>? serverKey;

  /// Private relays to fall back on when the direct route fails.
  List<Relay> relays = const [];

  /// 0 = direct, n = relays[n-1]. Where the last request succeeded.
  int route = 0;
  DateTime _directRetryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Human-readable current path, for the status screen.
  String get routeLabel =>
      route == 0 ? 'direct' : Uri.parse(relays[route - 1].url).host;

  /// Server clock minus local clock, learned from a `clock_skew` rejection.
  int clockOffset = 0;

  static final _ed = Ed25519();
  static final _rng = Random.secure();

  static Future<SimpleKeyPair> newAuthKey() => _ed.newKeyPair();

  static Future<String> publicKeyB64(SimpleKeyPair key) async =>
      base64Encode((await key.extractPublicKey()).bytes);

  Future<dynamic> get(String route, {Map<String, String> query = const {}}) =>
      _send('GET', route, query: query, signed: true);

  Future<dynamic> post(String route, Object body, {bool signed = true}) =>
      _send('POST', route, body: body, signed: signed);

  Future<dynamic> _send(
    String method,
    String route, {
    Map<String, String> query = const {},
    Object? body,
    required bool signed,
    bool retried = false,
  }) async {
    final bodyBytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final sorted = query.keys.toList()..sort();
    final canonicalQuery = sorted
        .map(
          (k) => '${Uri.encodeComponent(k)}=${Uri.encodeComponent(query[k]!)}',
        )
        .join('&');
    final fullRoute = '/irm/v1$route';
    final qs = canonicalQuery.isEmpty ? '' : '?$canonicalQuery';

    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    // Every request carries a fresh nonce; the server's signature covers it,
    // so an old answer cannot be replayed for this request.
    final nonce = base64Encode(
      List<int>.generate(16, (_) => _rng.nextInt(256)),
    );
    headers['X-IRM-Nonce'] = nonce;
    if (signed) {
      final time = DateTime.now().millisecondsSinceEpoch ~/ 1000 + clockOffset;
      final digest = (await Sha256().hash(bodyBytes)).bytes;
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final canonical =
          'IRM1\n$method\n$fullRoute\n$canonicalQuery\n$time\n$nonce\n$hex';
      final sig = await _ed.sign(utf8.encode(canonical), keyPair: authKey!);
      headers.addAll({
        'X-IRM-Device': '$deviceId',
        'X-IRM-Time': '$time',
        'X-IRM-Sig': base64Encode(sig.bytes),
      });
    }

    // Try the route that worked last, then the others. Only failures of
    // the path itself (no connection, firewall page, bad signature) move on
    // to the next route; a signed answer from the server is final.
    final usable = serverKey == null ? 0 : relays.length;
    if (this.route > usable) this.route = 0;
    if (this.route != 0 && DateTime.now().isAfter(_directRetryAt)) {
      this.route = 0; // periodically give the direct path another chance
    }
    final order = [
      this.route,
      for (var i = 0; i <= usable; i++)
        if (i != this.route) i,
    ];
    Object? lastError;
    for (final r in order) {
      final uri = Uri.parse(
        r == 0
            ? '$siteUrl/wp-json$fullRoute$qs'
            : '${relays[r - 1].url}/wp-json/pr/v1/f/${fullRoute.substring('/irm/v1/'.length)}$qs',
      );
      final sent = {...headers, if (r != 0) 'X-Relay-Key': relays[r - 1].key};
      try {
        final result = await _attempt(
          method,
          uri,
          sent,
          bodyBytes,
          body != null,
          nonce,
          via: r == 0 ? 'direct' : uri.host,
        );
        if (r != 0 && this.route == 0) {
          _directRetryAt = DateTime.now().add(const Duration(minutes: 5));
        }
        this.route = r;
        return _finish(result, method, route, query, body, signed, retried);
      } on WafBlock catch (e) {
        lastError = e;
      } on UntrustedResponse catch (e) {
        lastError = e;
      } on RelayError catch (e) {
        // Keep what the direct way said; the relay only repeats it.
        lastError ??= e;
      } on TimeoutException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } catch (e) {
        if (!isTransportError(e)) rethrow;
        lastError = e;
      }
    }
    throw lastError!;
  }

  /// One request over one route. Returns (status, decoded JSON).
  Future<(int, dynamic)> _attempt(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int> bodyBytes,
    bool hasBody,
    String nonce, {
    required String via,
  }) async {
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (hasBody) request.bodyBytes = bodyBytes;
    final clock = Stopwatch()..start();
    final response = await http.Response.fromStream(
      // A short request that has not been answered in 15 s will not be;
      // switching to the relay then is faster. File pieces get longer.
      await _http
          .send(request)
          .timeout(Duration(seconds: bodyBytes.length > 64 * 1024 ? 60 : 15)),
    );
    clock.stop();

    final type = response.headers['content-type'] ?? '';
    dynamic json;
    if (type.contains('json')) {
      try {
        json = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        json = null;
      }
    }
    // The plugin always answers JSON. Anything else came from in front of it.
    final fromPlugin =
        json != null &&
        (response.statusCode < 400 || (json is Map && json['code'] != null));
    if (!fromPlugin) {
      final evidence = _evidence(
        method,
        uri,
        headers,
        bodyBytes.length,
        response,
        clock.elapsedMilliseconds,
      );
      wafLog?.call(jsonEncode(evidence));
      throw WafBlock(evidence);
    }

    final sig = response.headers['x-irm-server-sig'];
    if (via != 'direct' &&
        sig == null &&
        json is Map &&
        '${json['code']}'.startsWith('relay_')) {
      throw RelayError(via, '${json['code']}');
    }
    if (serverKey != null) {
      final digest = (await Sha256().hash(response.bodyBytes)).bytes;
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      var ok = false;
      if (sig != null) {
        try {
          ok = await _ed.verify(
            utf8.encode('IRM1-RESP\n${response.statusCode}\n$nonce\n$hex'),
            signature: Signature(
              base64Decode(sig),
              publicKey: SimplePublicKey(serverKey!, type: KeyPairType.ed25519),
            ),
          );
        } catch (_) {
          ok = false;
        }
      }
      if (!ok) throw UntrustedResponse(via);
    }
    return (response.statusCode, json);
  }

  Future<dynamic> _finish(
    (int, dynamic) result,
    String method,
    String route,
    Map<String, String> query,
    Object? body,
    bool signed,
    bool retried,
  ) async {
    final status = result.$1;
    final json = result.$2;
    if (status >= 400) {
      final map = json as Map;
      final data = map['data'];
      if (map['code'] == 'irm_clock_skew' &&
          !retried &&
          data is Map &&
          data['server_time'] is int) {
        clockOffset =
            (data['server_time'] as int) -
            DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return _send(
          method,
          route,
          query: query,
          body: body,
          signed: signed,
          retried: true,
        );
      }
      throw ApiError(status, '${map['code']}', '${map['message']}');
    }
    return json;
  }

  Map<String, dynamic> _evidence(
    String method,
    Uri uri,
    Map<String, String> sent,
    int bodyLength,
    http.Response r,
    int elapsedMs,
  ) {
    final now = DateTime.now();
    final off = now.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final tz =
        '$sign${off.inHours.abs().toString().padLeft(2, '0')}:'
        '${(off.inMinutes.abs() % 60).toString().padLeft(2, '0')}';
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    return {
      'time_local': '${now.toIso8601String()}$tz',
      'time_utc': now.toUtc().toIso8601String(),
      'method': method,
      'url': uri.toString(),
      'request_content_type': sent['Content-Type'],
      'request_body_bytes': bodyLength,
      'request_header_names': sent.keys.toList(),
      'status': r.statusCode,
      // Whether the proxy answered at once or only after waiting.
      'elapsed_ms': elapsedMs,
      'response_headers': r.headers,
      'response_body_start': text.length > 2000
          ? text.substring(0, 2000)
          : text,
      'reproduce':
          "curl -i -X $method '${uri.toString()}'"
          "${bodyLength > 0 ? " -H 'Content-Type: application/json' --data-binary @body.json" : ''}",
    };
  }

  void close() => _http.close();
}
