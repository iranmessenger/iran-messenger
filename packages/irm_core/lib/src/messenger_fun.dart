part of 'messenger.dart';

/// Polls and BUZZ.
///
/// A poll is an ordinary message (kind "poll") carrying its question and
/// options; every vote is a small end-to-end encrypted control message to
/// the whole chat, so each member tallies the same result and can see who
/// chose what. Only the poll's author can close it.
///
/// A BUZZ shakes the other side's chat, as in Yahoo! Messenger. Anyone may
/// send one to a chat at most every five minutes, and a receiver ignores
/// more frequent ones from the same person, so a modified app cannot turn
/// it into a nuisance.
///
/// Older apps get a readable text instead of either (the wire body), and
/// are never sent votes, which they would show as empty messages.
extension MessengerFun on Messenger {
  static const buzzGap = Duration(minutes: 5);
  static const maxPollOptions = 10;

  // ------------------------------------------------------------------
  // BUZZ
  // ------------------------------------------------------------------

  /// Seconds before this user may BUZZ [chat] again (0: now).
  int buzzWait(String chat) {
    final last = db.kvInt('buzz:$chat') ?? 0;
    final left =
        last + buzzGap.inMilliseconds - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? (left / 1000).ceil() : 0;
  }

  /// Sends a BUZZ to [chat]; false while the five minutes are not over.
  Future<bool> sendBuzz(String chat) async {
    if (buzzWait(chat) > 0) return false;
    db.kvPutInt('buzz:$chat', DateTime.now().millisecondsSinceEpoch);
    await _insertOutgoing(chat, 'buzz', '', null);
    return true;
  }

  /// Runs inside the receiving transaction. Null when [from] buzzed this
  /// chat less than five minutes ago (or the clock is far off).
  ChatMessage? _receiveBuzz(
    String chat,
    int from,
    int deliveryId,
    int ts,
    String? wireId,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = db.raw.select(
      'SELECT created_at FROM messages WHERE chat = ? AND sender = ? AND kind = ? '
      'ORDER BY id DESC LIMIT 1',
      [chat, from, 'buzz'],
    );
    if (last.isNotEmpty &&
        now - (last.first['created_at'] as int) <
            buzzGap.inMilliseconds - 20000) {
      return null;
    }
    // Stamped with the arrival time: the shake belongs to "now".
    return _insertIncoming(
      chat,
      from,
      'buzz',
      '',
      null,
      deliveryId,
      MsgStatus.received,
      (ts - now).abs() < 600000 ? ts : now,
      wireId: wireId,
    );
  }

  // ------------------------------------------------------------------
  // Polls
  // ------------------------------------------------------------------

  /// Starts a poll in [chat]. [options] holds 2 to 10 distinct answers.
  Future<void> sendPoll(
    String chat,
    String question,
    List<String> options, {
    bool multi = false,
  }) async {
    final q = question.trim();
    final o = [
      for (final x in options)
        if (x.trim().isNotEmpty) x.trim(),
    ];
    if (q.isEmpty ||
        q.length > 300 ||
        o.length < 2 ||
        o.length > maxPollOptions ||
        o.toSet().length != o.length ||
        o.any((x) => x.length > 100)) {
      throw ArgumentError('invalid poll');
    }
    await _insertOutgoing(
      chat,
      'poll',
      q,
      null,
      poll: jsonEncode({'o': o, 'm': multi}),
    );
  }

  /// What an older app shows instead of the poll.
  static String pollFallback(String question, List<String> options) => [
    '📊 $question',
    for (var i = 0; i < options.length; i++) '${i + 1}. ${options[i]}',
    '(برای رای دادن، برنامه را به‌روز کنید)',
  ].join('\n');

  /// Validates a poll as received; null if malformed.
  static String? _pollJson(Object? raw) {
    if (raw is! Map) return null;
    final q = raw['q'];
    final o = raw['o'];
    if (q is! String || q.trim().isEmpty || q.length > 300) return null;
    if (o is! List || o.length < 2 || o.length > maxPollOptions) return null;
    final options = [
      for (final x in o)
        if (x is String && x.trim().isNotEmpty && x.length <= 100) x.trim(),
    ];
    if (options.length != o.length) return null;
    return jsonEncode({'o': options, 'm': raw['m'] == true});
  }

  /// Casts (or with an empty [choice] withdraws) this user's vote.
  Future<bool> vote(ChatMessage poll, List<int> choice) async {
    final info = poll.poll;
    final target = poll.clientMsgId;
    if (info == null || target == null || info.closed) return false;
    final clean = _cleanChoice(info, choice);
    if (clean == null) return false;
    await db.tx(() async => _setVotes(poll.id, myIdentity, clean));
    notify();
    try {
      await _queueControl2(poll.chat, {
        't': 'vote',
        'target': target,
        'choice': clean,
      }, minCapability: 4);
    } on StateError {
      return false;
    }
    return true;
  }

  /// Stops voting. Only the author of the poll can.
  Future<bool> closePoll(ChatMessage poll) async {
    final target = poll.clientMsgId;
    if (!poll.outgoing || poll.poll == null || target == null) return false;
    await db.tx(() async => _markClosed(poll.id));
    notify();
    try {
      await _queueControl2(poll.chat, {
        't': 'pollclose',
        'target': target,
      }, minCapability: 4);
    } on StateError {
      return false;
    }
    return true;
  }

  static List<int>? _cleanChoice(PollInfo info, List<int> choice) {
    final set = choice.toSet().toList()..sort();
    if (set.any((i) => i < 0 || i >= info.options.length)) return null;
    if (!info.multi && set.length > 1) return null;
    return set;
  }

  void _setVotes(int rowId, int who, List<int> choice) {
    final rows = db.raw.select('SELECT votes FROM messages WHERE id = ?', [
      rowId,
    ]);
    if (rows.isEmpty) return;
    final votes = rows.first['votes'] == null
        ? <String, dynamic>{}
        : (jsonDecode(rows.first['votes'] as String) as Map)
              .cast<String, dynamic>();
    if (choice.isEmpty) {
      votes.remove('$who');
    } else {
      votes['$who'] = choice;
    }
    db.raw.execute('UPDATE messages SET votes = ? WHERE id = ?', [
      votes.isEmpty ? null : jsonEncode(votes),
      rowId,
    ]);
  }

  void _markClosed(int rowId) {
    final rows = db.raw.select('SELECT poll FROM messages WHERE id = ?', [
      rowId,
    ]);
    if (rows.isEmpty || rows.first['poll'] == null) return;
    final p = (jsonDecode(rows.first['poll'] as String) as Map)
        .cast<String, dynamic>();
    p['c'] = true;
    db.raw.execute('UPDATE messages SET poll = ? WHERE id = ?', [
      jsonEncode(p),
      rowId,
    ]);
  }

  /// A vote from [from]. Runs inside the receiving transaction.
  void _applyVote(String chat, int from, Map<String, dynamic> wire) {
    final rows = db.raw.select(
      'SELECT * FROM messages WHERE client_msg_id = ? AND chat = ? AND kind = ?',
      [wire['target'], chat, 'poll'],
    );
    if (rows.isEmpty) return;
    final poll = ChatMessage.fromRow(rows.first);
    final info = poll.poll;
    final raw = wire['choice'];
    if (info == null || info.closed || raw is! List) return;
    final clean = _cleanChoice(info, [
      for (final x in raw)
        if (x is int) x,
    ]);
    if (clean == null) return;
    _setVotes(poll.id, from, clean);
    notify();
  }

  void _applyPollClose(String chat, int from, Map<String, dynamic> wire) {
    final rows = db.raw.select(
      'SELECT id FROM messages WHERE client_msg_id = ? AND chat = ? AND kind = ? AND sender = ?',
      [wire['target'], chat, 'poll', from],
    );
    if (rows.isEmpty) return;
    _markClosed(rows.first['id'] as int);
    notify();
  }
}
