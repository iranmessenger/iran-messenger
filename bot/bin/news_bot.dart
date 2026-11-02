// IRAN Messenger news bot.
//
//   irm_news_bot setup  --site https://example.ir --invite CODE --username newsbot [--name "ربات خبر"]
//   irm_news_bot serve  keeps running: checks every few minutes, posts once per period
//   irm_news_bot run    one pass (for a scheduler such as Windows Task Scheduler or cron)
//   irm_news_bot status
//
// Every command takes --data <folder> (default: "irm_bot_data" next to
// where it is started). The folder holds the bot's account and settings;
// keep it private and back it up.
import 'dart:async';
import 'dart:io';

import 'package:irm_news_bot/news_bot.dart';

Future<void> main(List<String> args) async {
  final opts = <String, String>{};
  final words = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--') && i + 1 < args.length) {
      opts[args[i].substring(2)] = args[++i];
    } else {
      words.add(args[i]);
    }
  }
  final command = words.isEmpty ? '' : words.first;
  final dir = Directory(opts['data'] ?? 'irm_bot_data')
    ..createSync(recursive: true);

  if (!const {'setup', 'serve', 'run', 'status'}.contains(command)) {
    stdout.writeln(
      File.fromUri(Platform.script).existsSync()
          ? File.fromUri(
              Platform.script,
            ).readAsLinesSync().takeWhile((l) => l.startsWith('//')).join('\n')
          : 'Commands: setup, serve, run, status',
    );
    exit(64);
  }

  final bot = NewsBot(dir);
  try {
    switch (command) {
      case 'setup':
        final site = opts['site'],
            invite = opts['invite'],
            user = opts['username'];
        if (site == null || invite == null || user == null) {
          stderr.writeln('setup needs --site, --invite and --username');
          exit(64);
        }
        await bot.setup(
          site: site,
          invite: invite,
          username: user,
          name: opts['name'] ?? 'ربات خبر',
        );
      case 'status':
        stdout.writeln(bot.status());
      case 'run':
        await bot.cycle();
      case 'serve':
        log('Serving. Stop with Ctrl+C.');
        while (true) {
          try {
            await bot.cycle();
          } on FormatException catch (e) {
            log('Settings problem: ${e.message}');
          } catch (e) {
            log('Will retry: $e');
          }
          await Future<void>.delayed(const Duration(minutes: 5));
        }
    }
  } on FormatException catch (e) {
    stderr.writeln('Settings problem: ${e.message}');
    exitCode = 78;
  } catch (e) {
    stderr.writeln('Failed: $e');
    exitCode = 1;
  } finally {
    bot.close();
  }
}
