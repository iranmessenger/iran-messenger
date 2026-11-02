// Drives the real screens against a LOCAL development server and exchanges
// messages with a second simulated device. Skipped unless SITE is given:
//
//   flutter test --dart-define=SITE=http://localhost:8089 \
//     --dart-define=TOKEN_A=... --dart-define=TOKEN_B=...
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iran_messenger/app_state.dart';
import 'package:iran_messenger/main.dart';
import 'package:iran_messenger/widgets/motion.dart';
import 'package:iran_messenger/platform/host_io.dart';
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

const site = String.fromEnvironment('SITE');
const tokenA = String.fromEnvironment('TOKEN_A');
const tokenB = String.fromEnvironment('TOKEN_B');

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('join, receive, reply, verify, group', (tester) async {
    HttpOverrides.global = null; // real network to the local server
    // A tall phone-like surface so the whole form is laid out at once.
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final r = Random.secure();
    final tag = r.nextInt(900000) + 100000;
    final dir = Directory.systemTemp.createTempSync('irm_ui_');
    String key() =>
        List.generate(64, (_) => r.nextInt(16).toRadixString(16)).join();
    // Live binding: real clock and real sockets, so UI-triggered network
    // calls complete while we wait.
    Future<void> real([int ms = 2500]) async {
      for (var waited = 0; waited < ms; waited += 100) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final state = AppState.withMessenger(
      Messenger(
        openAppDbSync('${dir.path}/app.db', keyHex: key()),
        IoFileStore(Directory('${dir.path}/files')),
      ),
      WafLog(File('${dir.path}/waf.jsonl')),
      poll: false,
    );

    await tester.pumpWidget(IrmApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('ورود'), findsWidgets);

    // Register tab: username, password, invite code, server.
    await tester.tap(find.text('ثبت‌نام'));
    await tester.pumpAndSettle();
    // An empty form is rejected locally.
    await tester.ensureVisible(find.text('ساخت حساب'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ساخت حساب'));
    await tester.pumpAndSettle();
    expect(find.textContaining('۴ تا ۲۰ نویسه'), findsOneWidget);

    final appPassword = Messenger.newId();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'appuser$tag');
    await tester.enterText(fields.at(1), appPassword);
    await tester.enterText(fields.at(2), tokenA);
    await tester.enterText(fields.at(3), site);
    await tester.ensureVisible(find.text('ساخت حساب'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ساخت حساب'));
    for (var i = 0; i < 20 && !state.messenger.isRegistered; i++) {
      await real(1000);
    }
    await real(1500);
    await tester.pumpAndSettle();
    expect(
      state.messenger.isRegistered,
      isTrue,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    expect(state.messenger.isPending, isFalse);
    // The chat list: its floating search bar (the title went in 2.14).
    expect(find.text('جستجو در ایران مسنجر'), findsOneWidget);
    expect(find.textContaining('هنوز گفتگویی ندارید'), findsOneWidget);

    // Second device through the core library.
    late Messenger bob;
    await tester.runAsync(() async {
      bob = Messenger(
        openAppDbSync('${dir.path}/bob.db', keyHex: key()),
        IoFileStore(Directory('${dir.path}/m')),
      );
      await bob.register(
        site: site,
        username: 'bob$tag',
        password: Messenger.newId(),
        inviteCode: tokenB,
      );
      await bob.updateProfile(displayName: 'باب');
      await bob.sendText('u:${state.messenger.myIdentity}', 'سلام از باب');
      await bob.syncOnce();
      await state.syncNow();
    });
    await tester.pumpAndSettle();
    expect(
      find.text('باب'),
      findsOneWidget,
      reason:
          'link=${state.link} ${state.linkDetail} '
          'chats=${state.messenger.chats().map((c) => c.title).toList()} '
          'bob=${bob.messages('u:${state.messenger.myIdentity}').map((x) => '${x.status}/${x.error}').toList()}',
    );
    expect(find.text('سلام از باب'), findsOneWidget);

    expect(
      find.byWidgetPredicate((w) => w is CountPill && w.count > 0),
      findsOneWidget,
    );
    expect(state.messenger.contacts().single.username, 'bob$tag');

    // Open the chat and reply from the UI.
    await tester.tap(find.text('باب'));
    await tester.pumpAndSettle();
    expect(find.text('سلام از باب'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'سلام از اپ');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await real(3000);
    await tester.runAsync(() async {
      await state.syncNow();
      await bob.syncOnce();
    });
    final got = bob.messages('u:${state.messenger.myIdentity}');
    expect(got.last.body, 'سلام از اپ');
    await tester.runAsync(() async {
      await bob.syncOnce();
      await state.syncNow();
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);

    // The safety number dialog shows the same code bob computes.
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await real(800);
    await tester.pumpAndSettle();
    final code = await tester.runAsync(
      () => bob.safetyNumber(state.messenger.myIdentity),
    );
    expect(find.text(code!), findsOneWidget);
    await tester.tap(find.text('بستن'));
    await tester.pumpAndSettle();

    // Back to the list, create a group from the UI.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('گفتگوی تازه'));
    await real(2000);
    await tester.pumpAndSettle();
    await tester.tap(find.text('گروه جدید'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'گروه آزمون');
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text('ذخیره'));
    await real(3000);
    await tester.pumpAndSettle();
    expect(find.text('گروه آزمون'), findsWidgets);
    await tester.enterText(find.byType(TextField), 'سلام گروه @bob$tag');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await real(3000);
    await tester.runAsync(() async {
      await state.syncNow();
      await bob.syncOnce();
    });
    final groupChat = bob.chats().firstWhere((c) => c.isGroup);
    expect(groupChat.title, 'گروه آزمون');
    expect(bob.messages(groupChat.chat).last.body, 'سلام گروه @bob$tag');
    expect(bob.mentionsMe(bob.messages(groupChat.chat).last.body), isTrue);

    await tester.pumpWidget(const SizedBox());
    bob.dispose();
    bob.db.close();
    state.messenger.dispose();
    state.messenger.db.close();
  }, skip: site.isEmpty);
}
