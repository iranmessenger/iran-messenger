import 'dart:convert';
import 'dart:io';

/// What the bot remembers between runs, in `state.json`: which report slot
/// it last posted, which articles it already used, and a finished report
/// that could not be sent yet (it is sent as it is, never rebuilt, so a
/// retry never posts twice or posts something different).
class BotState {
  BotState(this._file);
  final File _file;

  String lastSlot = '';
  final Map<String, int> seen = {};
  String? pendingSlot;
  String? pendingText;
  List<String> pendingUrls = const [];

  /// Groups that already received the pending report.
  final Set<String> pendingDone = {};

  static BotState load(File file) {
    final s = BotState(file);
    if (!file.existsSync()) return s;
    try {
      final j = jsonDecode(file.readAsStringSync()) as Map;
      s.lastSlot = '${j['last_slot'] ?? ''}';
      (j['seen'] as Map? ?? {}).forEach(
        (k, v) => s.seen['$k'] = (v as num).toInt(),
      );
      s.pendingSlot = j['pending_slot'] as String?;
      s.pendingText = j['pending_text'] as String?;
      s.pendingUrls = [
        for (final u in (j['pending_urls'] as List? ?? const [])) '$u',
      ];
      s.pendingDone.addAll([
        for (final g in (j['pending_done'] as List? ?? const [])) '$g',
      ]);
    } on FormatException {
      // A damaged file only costs the memory of what was already posted.
    }
    return s;
  }

  /// Written to a temporary file and renamed, so a crash mid-write cannot
  /// leave half a file behind.
  void save() {
    // Articles are remembered for three days; older ones cannot come back
    // into a report anyway.
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 3))
        .millisecondsSinceEpoch;
    seen.removeWhere((_, t) => t < cutoff);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'last_slot': lastSlot,
        'pending_slot': pendingSlot,
        'pending_text': pendingText,
        'pending_urls': pendingUrls,
        'pending_done': pendingDone.toList(),
        'seen': seen,
      }),
    );
    tmp.renameSync(_file.path);
  }
}
