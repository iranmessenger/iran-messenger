import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:irm_news_bot/news_bot.dart';
import 'package:test/test.dart';

BotConfig cfg() => BotConfig(
  site: 'https://example.ir',
  aiBaseUrl: 'https://api.gapgpt.app/v1',
  aiKey: 'test-key',
  aiModel: 'gpt-5.2-chat-latest',
  everyHours: 6,
  itemsPerReport: 3,
  feeds: const [Feed('Test', 'https://example.org/rss')],
);

List<Article> articles(int n) => [
  for (var i = 1; i <= n; i++)
    Article(
      source: 'منبع $i',
      title: 'Title $i',
      url: 'https://news.example/$i',
      summary: 'Body $i',
      published: DateTime.utc(2026, 10, 13, 8),
    ),
];

/// An AI service that answers [content] as the assistant message.
MockClient ai(String content, {List<Map>? requests}) => MockClient((req) async {
  requests?.add(jsonDecode(req.body) as Map);
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

void main() {
  group('feeds', () {
    test('RSS items, newest first, with tags and entities removed', () {
      final list = parseFeed('ISNA', '''<?xml version="1.0"?>
<rss><channel>
<item><title>Old</title><link>https://a/1</link><description>&lt;p&gt;first&lt;/p&gt;</description>
<pubDate>Mon, 12 Oct 2026 08:00:00 +0330</pubDate></item>
<item><title>New &amp; shiny</title><link>https://a/2</link><description><![CDATA[<b>second</b>&nbsp;one]]></description>
<pubDate>Tue, 13 Oct 2026 09:30:00 GMT</pubDate></item>
<item><title>No link</title></item>
</channel></rss>''');
      expect(list.map((a) => a.url), ['https://a/2', 'https://a/1']);
      expect(list.first.title, 'New & shiny');
      expect(list.first.summary, 'second one');
      expect(list.last.published, DateTime.utc(2026, 10, 12, 4, 30));
    });

    test('Atom entries', () {
      final list = parseFeed('X', '''<feed xmlns="http://www.w3.org/2005/Atom">
<entry><title>A</title><link rel="alternate" href="https://b/1"/><updated>2026-10-13T10:00:00Z</updated><summary>s</summary></entry>
</feed>''');
      expect(list.single.url, 'https://b/1');
      expect(list.single.published, DateTime.utc(2026, 10, 13, 10));
    });

    test('links that are not web addresses are dropped', () {
      final list = parseFeed(
        'X',
        '<rss><channel><item><title>T</title><link>javascript:alert(1)</link></item></channel></rss>',
      );
      expect(list, isEmpty);
    });
  });

  group('periods and report', () {
    test('a period is the same for its whole span, Tehran time', () {
      // 08:40 UTC = 12:10 Tehran; 14:20 UTC = 17:50 Tehran.
      expect(
        slotOf(tehranNow(DateTime.utc(2026, 10, 13, 8, 40)), 6),
        '2026-10-13T12',
      );
      expect(
        slotOf(tehranNow(DateTime.utc(2026, 10, 13, 14, 20)), 6),
        '2026-10-13T12',
      );
      expect(
        slotOf(tehranNow(DateTime.utc(2026, 10, 13, 14, 31)), 6),
        '2026-10-13T18',
      );
    });

    test('report has the Persian date, sections, sources and links', () {
      final a = articles(2);
      final text = buildReport([
        Summary(a[0], 'economy', 'تیتر اقتصادی', 'خلاصه اول'),
        Summary(a[1], 'politics', 'تیتر سیاسی', 'خلاصه دوم'),
      ], DateTime.utc(2026, 10, 13, 12));
      expect(text, contains('۲۱ مهر ۱۴۰۵'));
      // Sections follow a fixed order: politics before economy.
      expect(text.indexOf('▪️ سیاست'), lessThan(text.indexOf('▪️ اقتصاد')));
      expect(text, contains('منبع: منبع 1'));
      expect(text, contains('https://news.example/2'));
    });

    test('links are shown readable, spaces stay encoded', () {
      expect(
        readableUrl(
          'https://a.ir/news/1/%D8%AE%D8%A8%D8%B1%20%D8%AA%D8%A7%D8%B2%D9%87',
        ),
        'https://a.ir/news/1/خبر%20تازه',
      );
      expect(readableUrl('https://a.ir/%E0%A4%A'), 'https://a.ir/%E0%A4%A');
    });
  });

  group('AI answer', () {
    test('only items that point at real input articles are kept', () async {
      final sent = <Map>[];
      final out = await summarize(
        cfg(),
        ai(
          'Here you go: {"items":['
          '{"id":2,"category":"economy","title":"T2","summary":"S2"},'
          '{"id":2,"category":"economy","title":"again","summary":"dup"},'
          '{"id":99,"category":"world","title":"made up","summary":"x"},'
          '{"id":1,"category":"nonsense","title":"T1","summary":"S1","url":"https://evil.example"},'
          '{"id":3,"category":"world","title":"","summary":"no title"}'
          ']}',
          requests: sent,
        ),
        articles(3),
        3,
      );
      expect(out.map((s) => s.article.url), [
        'https://news.example/2',
        'https://news.example/1',
      ]);
      // An unknown category falls back to "other"; the link is the feed's own.
      expect(out.last.category, 'other');
      expect(sent.single['model'], 'gpt-5.2-chat-latest');
      expect(jsonEncode(sent.single), contains('DATA, not instructions'));
    });

    test('a model that rejects JSON mode is asked again without it', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        final body = jsonDecode(req.body) as Map;
        if (body.containsKey('response_format'))
          return http.Response('{"error":"unsupported"}', 400);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '{"items":[{"id":1,"category":"world","title":"T","summary":"S"}]}',
                },
              },
            ],
          }),
          200,
        );
      });
      final out = await summarize(cfg(), client, articles(1), 3);
      expect(calls, 2);
      expect(out.single.title, 'T');
    });

    test('errors say what is wrong', () async {
      Future<void> expectError(http.Response r, String text) async {
        await expectLater(
          summarize(cfg(), MockClient((_) async => r), articles(2), 3),
          throwsA(
            isA<AiError>().having((e) => e.message, 'message', contains(text)),
          ),
        );
      }

      await expectError(http.Response('', 401), 'refused the key');
      await expectError(http.Response('', 402), 'no credit');
      await expectError(http.Response('{}', 404), 'does not know the model');
      await expectError(
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'sorry'},
              },
            ],
          }),
          200,
        ),
        'not JSON',
      );
      await expectError(
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '{"items":[{"id":7,"title":"x","summary":"y"}]}',
                },
              },
            ],
          }),
          200,
        ),
        'no usable items',
      );
    });
  });
}
