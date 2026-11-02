import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'config.dart';

/// One article as it came from a feed.
class Article {
  Article({
    required this.source,
    required this.title,
    required this.url,
    required this.summary,
    required this.published,
  });
  final String source;
  final String title;
  final String url;
  final String summary;
  final DateTime? published;
}

/// What one round of fetching gave: the articles and which feeds failed.
class FetchResult {
  FetchResult(this.articles, this.failed);
  final List<Article> articles;
  final Map<String, String> failed;
}

const _maxBytes = 3 * 1024 * 1024;
const _perFeed = 15;

/// Fetches every feed at once. A feed that does not answer in time, is too
/// large or is not valid XML is skipped; the others are unaffected.
Future<FetchResult> fetchAll(List<Feed> feeds, http.Client client) async {
  final failed = <String, String>{};
  final lists = await Future.wait([
    for (final f in feeds)
      _fetch(f, client).catchError((Object e) {
        failed[f.name] = e is TimeoutException
            ? 'timeout'
            : '$e'.split('\n').first;
        return <Article>[];
      }),
  ]);
  return FetchResult([for (final l in lists) ...l], failed);
}

Future<List<Article>> _fetch(Feed feed, http.Client client) async {
  final uri = Uri.parse(feed.url);
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    throw const FormatException('not a web address');
  }
  final res = await client
      .get(
        uri,
        headers: {
          'User-Agent': 'IrmNewsBot/1.0',
          'Accept':
              'application/rss+xml, application/atom+xml, application/xml, text/xml',
        },
      )
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
  if (res.bodyBytes.length > _maxBytes)
    throw const FormatException('feed too large');
  return parseFeed(feed.name, utf8.decode(res.bodyBytes, allowMalformed: true));
}

/// RSS 2.0 `<item>` or Atom `<entry>`, newest first, at most [_perFeed].
List<Article> parseFeed(String source, String xmlText) {
  final doc = XmlDocument.parse(xmlText);
  String text(XmlElement e, String name) =>
      e.findElements(name).firstOrNull?.innerText.trim() ?? '';
  final out = <Article>[];
  for (final item in doc.findAllElements('item')) {
    final link = text(item, 'link');
    if (link.isEmpty) continue;
    out.add(
      Article(
        source: source,
        title: clean(text(item, 'title')),
        url: link,
        summary: clean(text(item, 'description')),
        published: _date(text(item, 'pubDate')),
      ),
    );
  }
  for (final entry in doc.findAllElements('entry')) {
    final link =
        entry
            .findElements('link')
            .where((l) => (l.getAttribute('rel') ?? 'alternate') == 'alternate')
            .firstOrNull
            ?.getAttribute('href') ??
        '';
    if (link.isEmpty) continue;
    out.add(
      Article(
        source: source,
        title: clean(text(entry, 'title')),
        url: link,
        summary: clean(
          text(entry, 'summary').isNotEmpty
              ? text(entry, 'summary')
              : text(entry, 'content'),
        ),
        published: _date(
          text(entry, 'updated').isNotEmpty
              ? text(entry, 'updated')
              : text(entry, 'published'),
        ),
      ),
    );
  }
  out.removeWhere(
    (a) =>
        a.title.isEmpty ||
        !(a.url.startsWith('https://') || a.url.startsWith('http://')),
  );
  out.sort(
    (a, b) => (b.published ?? DateTime(2000)).compareTo(
      a.published ?? DateTime(2000),
    ),
  );
  return out.take(_perFeed).toList();
}

/// Plain text: tags and entities removed, spaces collapsed, at most 500
/// characters (enough for a summary, and it keeps the AI request small).
String clean(String html) {
  var s = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&zwnj;': '‌',
  };
  entities.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m[1]!);
    return code == null || code > 0x10FFFF ? '' : String.fromCharCode(code);
  });
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 500 ? '${s.substring(0, 500)}…' : s;
}

DateTime? _date(String s) {
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.toUtc();
  try {
    return HttpDate.parse(s).toUtc();
  } catch (_) {}
  // RSS dates with a numeric zone, e.g. "Mon, 13 Oct 2026 10:20:00 +0330".
  final m = RegExp(
    r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})(?::(\d{2}))? ([+-])(\d{2})(\d{2})',
  ).firstMatch(s);
  if (m == null) return null;
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final month = months.indexOf(m[2]!.toLowerCase()) + 1;
  if (month == 0) return null;
  final local = DateTime.utc(
    int.parse(m[3]!),
    month,
    int.parse(m[1]!),
    int.parse(m[4]!),
    int.parse(m[5]!),
    int.parse(m[6] ?? '0'),
  );
  final offset = Duration(hours: int.parse(m[8]!), minutes: int.parse(m[9]!));
  return m[7] == '+' ? local.subtract(offset) : local.add(offset);
}
