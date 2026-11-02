import 'dart:convert';
import 'dart:io';

/// One news source: an RSS 2.0 or Atom feed.
class Feed {
  const Feed(this.name, this.url);
  final String name;
  final String url;

  static Feed fromJson(Map j) => Feed('${j['name']}', '${j['url']}');
  Map<String, Object> toJson() => {'name': name, 'url': url};
}

/// Everything the operator sets in `bot.json`. The file lives in the bot's
/// data folder next to its account; it holds the AI key, so keep it private.
class BotConfig {
  BotConfig({
    required this.site,
    required this.aiBaseUrl,
    required this.aiKey,
    required this.aiModel,
    required this.everyHours,
    required this.itemsPerReport,
    required this.feeds,
  });

  final String site;
  final String aiBaseUrl;
  final String aiKey;
  final String aiModel;
  final int everyHours;
  final int itemsPerReport;
  final List<Feed> feeds;

  static const defaultFeeds = [
    Feed('ایسنا', 'https://www.isna.ir/rss'),
    Feed('ایرنا', 'https://www.irna.ir/rss'),
    Feed('خبرآنلاین', 'https://www.khabaronline.ir/rss'),
    Feed('همشهری آنلاین', 'https://www.hamshahrionline.ir/rss'),
    Feed('بی‌بی‌سی فارسی', 'https://feeds.bbci.co.uk/persian/rss.xml'),
    Feed('یورونیوز فارسی', 'https://parsi.euronews.com/rss'),
    Feed('BBC World', 'https://feeds.bbci.co.uk/news/world/rss.xml'),
    Feed('Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'),
  ];

  static Map<String, Object> template(String site) => {
    'site': site,
    'ai': {
      'base_url': 'https://api.gapgpt.app/v1',
      'api_key': '',
      'model': 'gemini-3.8-flash',
    },
    'every_hours': 6,
    'items_per_report': 8,
    'feeds': [for (final f in defaultFeeds) f.toJson()],
  };

  /// Reads and checks `bot.json`. Throws a [FormatException] whose message
  /// says what to fix.
  static BotConfig load(File file) {
    if (!file.existsSync()) {
      throw FormatException('${file.path} not found. Run "setup" first.');
    }
    final j = jsonDecode(file.readAsStringSync()) as Map;
    final ai = (j['ai'] ?? {}) as Map;
    final c = BotConfig(
      site: '${j['site'] ?? ''}'.trim(),
      aiBaseUrl: '${ai['base_url'] ?? ''}'.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      ),
      aiKey: '${ai['api_key'] ?? ''}'.trim(),
      aiModel: '${ai['model'] ?? ''}'.trim(),
      everyHours: (j['every_hours'] as num? ?? 6).toInt(),
      itemsPerReport: (j['items_per_report'] as num? ?? 8).toInt(),
      feeds: [
        for (final f in (j['feeds'] as List? ?? const []))
          Feed.fromJson(f as Map),
      ],
    );
    if (!c.site.startsWith('https://') &&
        !c.site.startsWith('http://localhost')) {
      throw const FormatException(
        '"site" must be the https address of the messenger server.',
      );
    }
    if (c.aiKey.isEmpty) {
      throw const FormatException(
        '"ai.api_key" is empty: put the GapGPT key in bot.json.',
      );
    }
    // Plain http only for a test service on this machine.
    if (!c.aiBaseUrl.startsWith('https://') &&
        !c.aiBaseUrl.startsWith('http://localhost')) {
      throw const FormatException('"ai.base_url" must be an https address.');
    }
    if (c.aiModel.isEmpty) throw const FormatException('"ai.model" is empty.');
    if (c.everyHours < 1 || c.everyHours > 24 || 24 % c.everyHours != 0) {
      throw const FormatException(
        '"every_hours" must divide 24 (1, 2, 3, 4, 6, 8, 12 or 24).',
      );
    }
    if (c.itemsPerReport < 3 || c.itemsPerReport > 15) {
      throw const FormatException(
        '"items_per_report" must be between 3 and 15.',
      );
    }
    if (c.feeds.isEmpty) throw const FormatException('"feeds" is empty.');
    return c;
  }
}
