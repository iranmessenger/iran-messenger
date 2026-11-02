// Renders the main screens with seeded sample data and writes PNGs to
// test/shots/ for visual review. No network, no real accounts.
//
//   flutter test test/screenshots_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:iran_messenger/app_state.dart';
import 'package:iran_messenger/screens/chat_profile_screen.dart';
import 'package:iran_messenger/screens/chat_screen.dart';
import 'package:iran_messenger/screens/home_screen.dart';
import 'package:iran_messenger/screens/auth_screen.dart';
import 'package:iran_messenger/screens/new_chat_screen.dart';
import 'package:iran_messenger/screens/settings_screen.dart';
import 'package:iran_messenger/screens/status_screen.dart';
import 'package:iran_messenger/theme.dart';
import 'package:iran_messenger/widgets/common.dart';
import 'package:iran_messenger/platform/host_io.dart';
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

/// Fixed clock so times and date labels in the goldens never drift.
final _now = DateTime(2026, 10, 11, 12, 30);

const _key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.view(File(path).readAsBytesSync().buffer);
  final vazir = FontLoader('Vazirmatn')
    ..addFont(bytes('assets/fonts/Vazirmatn-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Vazirmatn-Medium.ttf'))
    ..addFont(bytes('assets/fonts/Vazirmatn-Bold.ttf'));
  await vazir.load();
  final flutterRoot = Directory(
    Platform.environment['FLUTTER_ROOT'] ?? 'C:/flutter',
  );
  final icons = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(bytes(icons.path))).load();
  }
}

AppState _seeded(Directory dir, {bool registered = true}) {
  final db = openAppDbSync('${dir.path}/shots.db', keyHex: _key);
  final m = Messenger(db, IoFileStore(dir));
  if (registered) {
    db.kvPutString('site', 'http://localhost:1');
    db.kvPutInt('device_id', 1);
    db.kvPutInt('identity_id', 1);
    db.kvPutString('display_name', 'آزاده');
    db.kvPutString('username', 'azadeh');
    for (final c in [
      [2, 'سلیمی', 'salimi'],
      [3, 'نگار احمدی', 'negar_a'],
      [4, 'رضا کریمی', 'reza'],
      // A contact without any messages yet (the empty chat screen).
      [5, 'سارا', 'sara'],
    ]) {
      db.raw.execute(
        'INSERT INTO contacts (identity_id, display_name, username) VALUES (?, ?, ?)',
        c,
      );
    }
    db.raw.execute(
      "INSERT INTO groups (id, title, admin, epoch, left) VALUES ('g1', 'خانواده', 1, 1, 0)",
    );
    for (final id in [1, 2, 3, 4]) {
      db.raw.execute(
        "INSERT INTO group_members (group_id, identity_id) VALUES ('g1', ?)",
        [id],
      );
    }
    final now = _now;
    var n = 0;
    void msg(
      String chat,
      int sender,
      String body,
      int status, {
      String kind = 'text',
      Duration ago = Duration.zero,
    }) {
      db.raw.execute(
        'INSERT INTO messages (chat, sender, outgoing, kind, body, client_msg_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          chat,
          sender,
          sender == 1 ? 1 : 0,
          kind,
          body,
          'id${n++}',
          status,
          now.subtract(ago).millisecondsSinceEpoch,
        ],
      );
    }

    msg(
      'u:4',
      4,
      'فایل را فرستادم، ببین رسید؟',
      MsgStatus.received,
      ago: const Duration(days: 3),
    );
    msg(
      'u:3',
      1,
      'فردا ساعت ده خوبه؟',
      MsgStatus.sent,
      ago: const Duration(days: 1, hours: 2),
    );
    msg(
      'g:g1',
      1,
      'گروه «خانواده» ساخته شد',
      MsgStatus.sent,
      kind: 'system',
      ago: const Duration(days: 1, hours: 5),
    );
    msg(
      'g:g1',
      3,
      'سلام به همه',
      MsgStatus.received,
      ago: const Duration(days: 1, hours: 4),
    );
    msg(
      'g:g1',
      3,
      'کسی آخر هفته وقت دارد؟',
      MsgStatus.received,
      ago: const Duration(days: 1, hours: 4),
    );
    msg(
      'g:g1',
      1,
      'من هستم 👍',
      MsgStatus.delivered,
      ago: const Duration(hours: 3),
    );
    msg(
      'g:g1',
      4,
      '@azadeh لطفا نشانی را هم بفرست',
      MsgStatus.received,
      ago: const Duration(minutes: 40),
    );
    msg('u:2', 2, 'سلام', MsgStatus.received, ago: const Duration(hours: 2));
    msg(
      'u:2',
      1,
      'سلام، خوبی؟',
      MsgStatus.delivered,
      ago: const Duration(hours: 2),
    );
    msg(
      'u:2',
      1,
      'عکس‌ها را دیدی؟',
      MsgStatus.delivered,
      ago: const Duration(hours: 2),
    );
    msg(
      'u:2',
      2,
      'آره، خیلی خوب شده بودند. دستت درد نکند.',
      MsgStatus.received,
      ago: const Duration(minutes: 12),
    );
    msg(
      'u:2',
      2,
      'فردا می‌بینمت',
      MsgStatus.received,
      ago: const Duration(minutes: 11),
    );
    msg('u:2', 1, 'حتما', MsgStatus.sent, ago: const Duration(minutes: 2));
    msg(
      'u:2',
      2,
      'نشانی برنامه وب: https://example.org/app',
      MsgStatus.received,
      ago: const Duration(minutes: 1),
    );
    db.raw.execute(
      "UPDATE messages SET status = ? WHERE body IN ('سلام، خوبی؟', 'من هستم 👍')",
      [MsgStatus.read],
    );
    // An own document still waiting to be sent.
    File('${dir.path}/plan.pdf').writeAsBytesSync(List.filled(3200000, 0));
    db.raw.execute(
      'INSERT INTO messages (chat, sender, outgoing, kind, body, media, client_msg_id, status, created_at) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?)',
      [
        'u:2',
        1,
        'media',
        '',
        jsonEncode({
          'kind': 'file',
          'mime': 'application/pdf',
          'name': 'برنامه سفر.pdf',
          'size': 3200000,
          'path': '${dir.path}/plan.pdf',
        }),
        'idup',
        MsgStatus.pending,
        _now.millisecondsSinceEpoch,
      ],
    );
    // A received document that is not downloaded yet.
    db.raw.execute(
      'INSERT INTO messages (chat, sender, outgoing, kind, body, media, client_msg_id, status, created_at) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)',
      [
        'u:2',
        2,
        'media',
        '',
        jsonEncode({
          'kind': 'file',
          'mime': 'application/pdf',
          'name': 'گزارش ماهانه.pdf',
          'size': 2457600,
        }),
        'idfile',
        MsgStatus.received,
        _now.millisecondsSinceEpoch,
      ],
    );
    db.raw.execute(
      "UPDATE messages SET reply = ?, edited = 1 WHERE body = 'حتما'",
      ['{"id":"id10","s":2,"p":"فردا می‌بینمت"}'],
    );
    // A BUZZ and a poll (with votes) in the chat with Reza.
    msg(
      'u:4',
      4,
      '',
      MsgStatus.received,
      kind: 'buzz',
      ago: const Duration(minutes: 30),
    );
    msg(
      'u:4',
      1,
      'ناهار کجا برویم؟',
      MsgStatus.delivered,
      kind: 'poll',
      ago: const Duration(minutes: 20),
    );
    db.raw.execute(
      "UPDATE messages SET poll = ?, votes = ? WHERE kind = 'poll'",
      [
        jsonEncode({
          'o': ['کافه', 'رستوران', 'خانه'],
          'm': false,
        }),
        jsonEncode({
          '1': [1],
          '4': [1],
          '3': [0],
        }),
      ],
    );
    db.raw.execute("UPDATE messages SET reactions = ? WHERE body LIKE 'آره%'", [
      '{"1":"👍"}',
    ]);
    db.raw.execute(
      "UPDATE messages SET reactions = ? WHERE body LIKE 'کسی آخر%'",
      ['{"1":"❤️","4":"❤️","2":"😂"}'],
    );
    db.raw.execute(
      "UPDATE messages SET readers = ? WHERE body LIKE 'من هستم%'",
      [
        jsonEncode({
          '3': _now.millisecondsSinceEpoch - 60000,
          '4': _now.millisecondsSinceEpoch - 30000,
        }),
      ],
    );
    db.kvPutInt('read:g:g1', 6);
    db.kvPutInt('read:u:4', 1);
    db.kvPutInt('read:u:3', 2);
  }
  return AppState.withMessenger(
    m,
    WafLog(File('${dir.path}/waf.jsonl')),
    poll: false,
  );
}

Widget _app(Widget home, Brightness b) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('fa'),
  supportedLocales: const [Locale('fa')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: Brand.theme(b),
  home: home,
);

void main() {
  setUpAll(() async {
    labelNow = () => _now;
    await _loadFonts();
  });

  Future<void> shot(
    WidgetTester tester,
    String name,
    Brightness b,
    Widget Function(AppState) build, {
    bool registered = true,
    Future<void> Function(WidgetTester)? before,
  }) async {
    tester.view.physicalSize = const Size(824, 1740);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    // Real soft shadows, as on a phone (tests draw them solid by default).
    debugDisableShadows = false;
    final dir = Directory.systemTemp.createTempSync('irm_shot_');
    final state = _seeded(dir, registered: registered);
    try {
      await tester.pumpWidget(_app(build(state), b));
      await tester.pumpAndSettle();
      if (before != null) await before(tester);
      // Pictures (the logo) decode outside the fake test clock.
      await tester.runAsync(() async {
        for (final e in find.byType(Image).evaluate()) {
          await precacheImage((e.widget as Image).image, e);
        }
      });
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
    await tester.pumpWidget(const SizedBox());
    state.messenger.dispose();
    state.messenger.db.close();
  }

  for (final b in Brightness.values) {
    final tag = b.name;
    testWidgets(
      'home $tag',
      (t) => shot(t, 'home_$tag', b, (s) => HomeScreen(state: s)),
    );
    testWidgets(
      'chat $tag',
      (t) => shot(t, 'chat_$tag', b, (s) => ChatScreen(state: s, chat: 'u:2')),
    );
    testWidgets(
      'group $tag',
      (t) =>
          shot(t, 'group_$tag', b, (s) => ChatScreen(state: s, chat: 'g:g1')),
    );
  }
  for (final (name, body, b) in [
    ('menu_mine_dark', 'من هستم', Brightness.dark),
    ('menu_other_light', 'کسی آخر هفته', Brightness.light),
  ]) {
    testWidgets(
      name,
      (t) => shot(
        t,
        name,
        b,
        (s) => ChatScreen(state: s, chat: 'g:g1'),
        before: (t) async {
          await t.tap(find.textContaining(body).first);
          await t.pumpAndSettle();
        },
      ),
    );
  }
  testWidgets(
    'profile',
    (t) => shot(
      t,
      'profile_links_dark',
      Brightness.dark,
      (s) => ChatProfileScreen(state: s, chat: 'u:2'),
      before: (t) async {
        await t.tap(find.text('لینک'));
        await t.pumpAndSettle();
      },
    ),
  );
  testWidgets(
    'group members',
    (t) => shot(
      t,
      'group_members_light',
      Brightness.light,
      (s) => ChatProfileScreen(state: s, chat: 'g:g1'),
      before: (t) async {
        await t.tap(find.text('نگار احمدی').last);
        await t.pumpAndSettle();
      },
    ),
  );
  testWidgets(
    'profile files',
    (t) => shot(
      t,
      'profile_files_light',
      Brightness.light,
      (s) => ChatProfileScreen(state: s, chat: 'u:2'),
      before: (t) async {
        await t.tap(find.text('فایل'));
        await t.pumpAndSettle();
      },
    ),
  );
  testWidgets(
    'emoji keyboard',
    (t) => shot(
      t,
      'emoji_light',
      Brightness.light,
      (s) => ChatScreen(state: s, chat: 'u:2'),
      before: (t) async {
        SharedPreferences.setMockInitialValues({});
        await t.tap(find.byTooltip('شکلک'));
        await t.pumpAndSettle();
      },
    ),
  );
  testWidgets(
    'delete',
    (t) => shot(
      t,
      'delete_dark',
      Brightness.dark,
      (s) => ChatScreen(state: s, chat: 'g:g1'),
      before: (t) async {
        await t.tap(find.textContaining('من هستم').first);
        await t.pumpAndSettle();
        await t.tap(find.text('حذف'));
        await t.pumpAndSettle();
      },
    ),
  );
  testWidgets(
    'empty chat',
    (t) => shot(
      t,
      'chat_empty_light',
      Brightness.light,
      (s) => ChatScreen(state: s, chat: 'u:5'),
    ),
  );
  for (final b in Brightness.values) {
    testWidgets(
      'settings ${b.name}',
      (t) => shot(t, 'settings_${b.name}', b, (s) => SettingsScreen(state: s)),
    );
  }
  testWidgets(
    'status',
    (t) => shot(
      t,
      'status_light',
      Brightness.light,
      (s) => StatusScreen(state: s),
    ),
  );
  testWidgets(
    'new chat',
    (t) => shot(
      t,
      'new_chat_dark',
      Brightness.dark,
      (s) => NewChatScreen(state: s),
    ),
  );
  testWidgets(
    'poll and buzz',
    (t) => shot(
      t,
      'fun_light',
      Brightness.light,
      (s) => ChatScreen(state: s, chat: 'u:4'),
    ),
  );
  testWidgets(
    'auth',
    (t) => shot(
      t,
      'auth_light',
      Brightness.light,
      (s) => AuthScreen(state: s),
      registered: false,
    ),
  );
  testWidgets(
    'pending',
    (t) => shot(
      t,
      'pending_dark',
      Brightness.dark,
      (s) => PendingScreen(state: s),
    ),
  );
}
