// Polls a public URL the way an idle app would and records every response
// that does not look like WordPress answering. Sends no credentials.
//
//   dart run bin/waf_probe.dart <url> [count=60] [interval-ms=3000]
//
// Output: one line per request on stdout, blocks appended to
// waf_evidence.jsonl, summary at the end.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: waf_probe.dart <url> [count] [interval-ms]');
    exit(64);
  }
  final uri = Uri.parse(args[0]);
  final count = args.length > 1 ? int.parse(args[1]) : 60;
  final interval = Duration(
    milliseconds: args.length > 2 ? int.parse(args[2]) : 3000,
  );
  final log = File('waf_evidence.jsonl');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'IRM-probe/0.1';

  var ok = 0, blocked = 0, failed = 0;
  final times = <int>[];

  for (var i = 1; i <= count; i++) {
    final started = DateTime.now();
    final watch = Stopwatch()..start();
    try {
      final req = await client.getUrl(uri);
      req.headers.set('Accept', 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      watch.stop();
      final type = res.headers.contentType?.mimeType ?? '';
      final looksLikeApi = res.statusCode == 200 && type.contains('json');
      if (looksLikeApi) {
        ok++;
        times.add(watch.elapsedMilliseconds);
      } else {
        blocked++;
        final headers = <String, String>{};
        res.headers.forEach((k, v) => headers[k] = v.join(', '));
        log.writeAsStringSync(
          '${jsonEncode({'time_local': '${started.toIso8601String()} (UTC offset ${started.timeZoneOffset.inMinutes} min)', 'time_utc': started.toUtc().toIso8601String(), 'request_number': i, 'interval_ms': interval.inMilliseconds, 'method': 'GET', 'url': uri.toString(), 'status': res.statusCode, 'response_headers': headers, 'response_body_start': body.length > 2000 ? body.substring(0, 2000) : body, 'reproduce': "curl -i '$uri'"})}\n',
          mode: FileMode.append,
          flush: true,
        );
      }
      stdout.writeln(
        '#$i ${started.toIso8601String()} ${res.statusCode} $type ${watch.elapsedMilliseconds}ms${looksLikeApi ? '' : '  <-- NOT API'}',
      );
    } catch (e) {
      failed++;
      stdout.writeln('#$i ${started.toIso8601String()} ERROR $e');
    }
    if (i < count) await Future<void>.delayed(interval);
  }
  client.close(force: true);

  times.sort();
  final p50 = times.isEmpty ? 0 : times[times.length ~/ 2];
  final p95 = times.isEmpty
      ? 0
      : times[(times.length * 95 ~/ 100).clamp(0, times.length - 1)];
  stdout.writeln(
    '\nok=$ok blocked=$blocked network_errors=$failed p50=${p50}ms p95=${p95}ms',
  );
}
