import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:irm_core/io.dart';
import 'package:irm_core/irm_core.dart';

import 'config.dart';
import 'feeds.dart';
import 'report.dart';
import 'state.dart';
import 'summarizer.dart';

void log(String text) => stdout.writeln(
  '[${DateTime.now().toIso8601String().substring(0, 19)}] $text',
);

/// The bot's account and memory, all inside one data folder:
/// `account.db` (encrypted; its key in `account.key`), `files/`,
/// `bot.json` (settings) and `state.json` (what was posted).
class NewsBot {
  NewsBot(this.dir) {
    final keyFile = File('${dir.path}/account.key');
    if (!keyFile.existsSync()) {
      final r = Random.secure();
      keyFile.writeAsStringSync(
        List.generate(64, (_) => r.nextInt(16).toRadixString(16)).join(),
      );
    }
    messenger = Messenger(
      openAppDbSync(
        '${dir.path}/account.db',
        keyHex: keyFile.readAsStringSync().trim(),
      ),
      IoFileStore(Directory('${dir.path}/files')),
    )..botMode = true;
    // The database holds the bot's private keys: never without encryption.
    if (!messenger.db.cipherAvailable) {
      messenger.db.close();
      throw StateError(
        'This build has no database encryption; it must not be used.',
      );
    }
  }

  final Directory dir;
  late final Messenger messenger;
  final _http = http.Client();
  bool _configFresh = false;

  File get configFile => File('${dir.path}/bot.json');
  File get stateFile => File('${dir.path}/state.json');

  /// Creates the bot's account with an invite code and writes a settings
  /// template next to it.
  Future<void> setup({
    required String site,
    required String invite,
    required String username,
    required String name,
  }) async {
    if (messenger.isRegistered) {
      log('Already set up as @${messenger.myUsername}.');
    } else {
      await messenger.register(
        site: site,
        username: username,
        password: _password(),
        inviteCode: invite,
      );
      await messenger.updateProfile(displayName: name);
      log('Account @$username created.');
    }
    if (!configFile.existsSync()) {
      configFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(BotConfig.template(site)),
      );
      log(
        'Settings written to ${configFile.path}: put the GapGPT key in "ai.api_key".',
      );
    }
    log(
      'Next: in the WordPress admin, IRAN Messenger page, press "Make bot" next to @${messenger.myUsername}.',
    );
  }

  /// The password is never needed again (the device key signs every
  /// request); it is random and kept nowhere.
  String _password() {
    final r = Random.secure();
    return base64Url.encode(List.generate(24, (_) => r.nextInt(256)));
  }

  List<String> groups() => [
    for (final r in messenger.db.raw.select(
      'SELECT id FROM groups WHERE left = 0 ORDER BY id',
    ))
      'g:${r['id']}',
  ];

  /// One pass: learn group changes, then post the report of the current
  /// period if it has not been posted yet. Safe to run as often as wanted.
  Future<void> cycle() async {
    if (!messenger.isRegistered)
      throw StateError('Not set up. Run "setup" first.');
    final cfg = BotConfig.load(configFile);
    final state = BotState.load(stateFile);
    if (!_configFresh) {
      await messenger.refreshConfig();
      _configFresh = true;
    }
    await messenger.syncOnce();

    final now = tehranNow();
    final slot = slotOf(now, cfg.everyHours);
    if (state.pendingText == null && slot != state.lastSlot) {
      await _prepare(cfg, state, slot, now);
    }
    if (state.pendingText != null) await _deliver(state);
  }

  Future<void> _prepare(
    BotConfig cfg,
    BotState state,
    String slot,
    DateTime now,
  ) async {
    final fetched = await fetchAll(cfg.feeds, _http);
    fetched.failed.forEach((name, why) => log('Feed "$name" skipped: $why'));
    // Recent and not used before. Undated items count as recent once.
    final since = DateTime.now().toUtc().subtract(
      Duration(hours: cfg.everyHours + 2),
    );
    final fresh = [
      for (final a in fetched.articles)
        if (!state.seen.containsKey(_key(a.url)) &&
            (a.published == null || a.published!.isAfter(since)))
          a,
    ];
    log('${fetched.articles.length} articles fetched, ${fresh.length} new.');
    if (fresh.length < 3) {
      log('Too little news for a report; trying again next time.');
      return;
    }
    // Newest first, a fair share from each source, at most 60 in the request.
    final bySource = <String, List<Article>>{};
    for (final a in fresh) {
      (bySource[a.source] ??= []).add(a);
    }
    final pick = <Article>[];
    for (
      var round = 0;
      pick.length < 60 && bySource.values.any((l) => l.length > round);
      round++
    ) {
      for (final l in bySource.values) {
        if (round < l.length && pick.length < 60) pick.add(l[round]);
      }
    }
    final summaries = await summarize(cfg, _http, pick, cfg.itemsPerReport);
    state
      ..pendingSlot = slot
      ..pendingText = buildReport(summaries, now)
      ..pendingUrls = [for (final a in pick) a.url]
      ..pendingDone.clear();
    state.save();
    log('Report for $slot ready (${summaries.length} items).');
  }

  /// Sends the finished report to every group that has not had it. A
  /// message is safe in the outbox as soon as it is queued, so a crash
  /// after this point never loses or repeats it.
  Future<void> _deliver(BotState state) async {
    final targets = groups()
        .where((g) => !state.pendingDone.contains(g))
        .toList();
    if (groups().isEmpty)
      log('Not a member of any group yet; the report is dropped.');
    for (final g in targets) {
      await messenger.sendText(g, state.pendingText!);
      state.pendingDone.add(g);
      state.save();
    }
    await messenger.syncOnce();
    final waiting =
        messenger.db.raw.select(
              'SELECT COUNT(*) AS n FROM messages WHERE outgoing = 1 AND status = ?',
              [MsgStatus.pending],
            ).first['n']
            as int;
    log(
      'Report ${state.pendingSlot} posted to ${state.pendingDone.length} group(s)${waiting > 0 ? ', $waiting still on the way' : ''}.',
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final u in state.pendingUrls) {
      state.seen[_key(u)] = now;
    }
    state
      ..lastSlot = state.pendingSlot!
      ..pendingSlot = null
      ..pendingText = null
      ..pendingUrls = const []
      ..pendingDone.clear();
    state.save();
  }

  String _key(String url) =>
      crypto.sha1.convert(utf8.encode(url.trim().toLowerCase())).toString();

  String status() {
    final s = BotState.load(stateFile);
    return [
      'Account: ${messenger.isRegistered ? '@${messenger.myUsername} on ${messenger.site}' : 'not set up'}',
      'Groups: ${groups().length}',
      'Last report: ${s.lastSlot.isEmpty ? 'none yet' : s.lastSlot}',
      if (s.pendingText != null) 'Waiting to send: ${s.pendingSlot}',
    ].join('\n');
  }

  void close() {
    messenger.dispose();
    messenger.db.close();
    _http.close();
  }
}
