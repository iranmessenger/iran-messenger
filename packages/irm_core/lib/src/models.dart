import 'dart:convert';

/// Message lifecycle. Outgoing: pending -> sent -> delivered -> read (or
/// failed).
/// Incoming: received, or undecryptable when the envelope could not be read.
class MsgStatus {
  static const pending = 0;
  static const sent = 1;
  static const delivered = 2;
  static const failed = 3;
  static const read = 4;
  static const received = 10;
  static const undecryptable = 11;
}

class Contact {
  Contact(this.identityId, this.displayName, [this.username, this.avatar]);
  final int identityId;
  final String displayName;
  final String? username;

  /// Local path of this person's picture, if they shared one.
  final String? avatar;
}

class GroupInfo {
  GroupInfo(
    this.id,
    this.title,
    this.admin,
    this.epoch,
    this.members, {
    this.left = false,
    List<int>? admins,
    this.avatar,
  }) : admins = admins ?? [admin];
  final String id;
  final String title;

  /// The creator. Only this member decides who else is an admin.
  final int admin;

  /// Everyone who may rename the group and change its members; always
  /// includes [admin].
  final List<int> admins;
  final String? avatar;
  final int epoch;
  final List<int> members;
  final bool left;
}

/// Attachment metadata. [key] and [nonce] never leave the E2EE payload;
/// the server only ever sees the encrypted blob under [serverId].
class MediaInfo {
  MediaInfo({
    required this.kind,
    required this.mime,
    required this.name,
    required this.size,
    this.durationMs,
    this.path,
    this.serverId,
    this.key,
    this.sha256,
    this.uploadId,
    this.plainSha,
  });

  /// image | video | voice | gif | sticker | file
  final String kind;
  final String mime;
  final String name;
  final int size;
  final int? durationMs;

  /// Local decrypted file, null until downloaded.
  String? path;
  String? serverId;
  String? key;
  String? sha256;
  String? uploadId;

  /// SHA-256 of the unencrypted file, sent with GIFs and stickers so a
  /// phone that already has the same file need not download it again.
  String? plainSha;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'mime': mime,
    'name': name,
    'size': size,
    if (durationMs != null) 'dur': durationMs,
    if (path != null) 'path': path,
    if (serverId != null) 'sid': serverId,
    if (key != null) 'key': key,
    if (sha256 != null) 'sha': sha256,
    if (uploadId != null) 'up': uploadId,
    if (plainSha != null) 'psha': plainSha,
  };

  /// What is sent to the peer: everything except local-only fields.
  Map<String, dynamic> toWire() =>
      toJson()..removeWhere((k, _) => k == 'path' || k == 'up');

  static MediaInfo fromJson(Map<String, dynamic> j) => MediaInfo(
    kind: '${j['kind']}',
    mime: '${j['mime']}',
    name: '${j['name']}',
    size: (j['size'] as num).toInt(),
    durationMs: (j['dur'] as num?)?.toInt(),
    path: j['path'] as String?,
    serverId: j['sid'] as String?,
    key: j['key'] as String?,
    sha256: j['sha'] as String?,
    uploadId: j['up'] as String?,
    plainSha: j['psha'] as String?,
  );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.chat,
    required this.sender,
    required this.outgoing,
    required this.kind,
    required this.body,
    required this.status,
    required this.createdAt,
    this.media,
    this.error,
    this.clientMsgId,
    this.reply,
    this.reactions = const {},
    this.edited = false,
    this.readers = const {},
    this.poll,
    this.votes = const {},
  });

  /// Options and state of a poll (kind "poll"); the question is [body].
  final PollInfo? poll;

  /// Identity id (as text) -> chosen option indexes, for polls.
  final Map<String, List<int>> votes;

  /// Identity id (as text) -> when that member read this outgoing message.
  final Map<String, int> readers;

  /// Sender-chosen id shared by both sides; replies, reactions and edits
  /// refer to a message through it.
  final String? clientMsgId;

  /// The quoted message, when this one is a reply.
  final ReplyRef? reply;

  /// Identity id (as text) -> emoji.
  final Map<String, String> reactions;
  final bool edited;

  final int id;

  /// `u:<identity>` for direct chats, `g:<group id>` for groups.
  final String chat;
  final int sender;
  final bool outgoing;

  /// text | media | system
  final String kind;
  final String body;
  final int status;
  final DateTime createdAt;
  final MediaInfo? media;
  final String? error;

  static ChatMessage fromRow(Map<String, dynamic> r) => ChatMessage(
    id: r['id'] as int,
    chat: r['chat'] as String,
    sender: r['sender'] as int,
    outgoing: r['outgoing'] == 1,
    kind: r['kind'] as String,
    body: r['body'] as String,
    status: r['status'] as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    media: r['media'] == null
        ? null
        : MediaInfo.fromJson(
            jsonDecode(r['media'] as String) as Map<String, dynamic>,
          ),
    error: r['error'] as String?,
    clientMsgId: r['client_msg_id'] as String?,
    reply: r['reply'] == null
        ? null
        : ReplyRef.fromJson(
            jsonDecode(r['reply'] as String) as Map<String, dynamic>,
          ),
    reactions: r['reactions'] == null
        ? const {}
        : (jsonDecode(r['reactions'] as String) as Map).map(
            (k, v) => MapEntry('$k', '$v'),
          ),
    edited: r['edited'] == 1,
    readers: r['readers'] == null
        ? const {}
        : (jsonDecode(r['readers'] as String) as Map).map(
            (k, v) => MapEntry('$k', (v as num).toInt()),
          ),
    poll: r['poll'] == null
        ? null
        : PollInfo.fromJson(
            jsonDecode(r['poll'] as String) as Map<String, dynamic>,
          ),
    votes: r['votes'] == null
        ? const {}
        : (jsonDecode(r['votes'] as String) as Map).map(
            (k, v) =>
                MapEntry('$k', [for (final i in v as List) (i as num).toInt()]),
          ),
  );
}

/// The answers of a poll and whether voting is over.
class PollInfo {
  PollInfo(this.options, {this.multi = false, this.closed = false});
  final List<String> options;

  /// Several answers may be chosen.
  final bool multi;

  /// The author stopped the voting.
  final bool closed;

  static PollInfo fromJson(Map<String, dynamic> j) => PollInfo(
    [for (final o in j['o'] as List) '$o'],
    multi: j['m'] == true,
    closed: j['c'] == true,
  );
}

/// Pointer to a quoted message plus a short preview, so the quote still
/// reads when the original is no longer on this device.
class ReplyRef {
  ReplyRef(this.id, this.sender, this.preview);
  final String id;
  final int sender;
  final String preview;

  Map<String, dynamic> toJson() => {'id': id, 's': sender, 'p': preview};

  static ReplyRef fromJson(Map<String, dynamic> j) =>
      ReplyRef('${j['id']}', (j['s'] as num).toInt(), '${j['p'] ?? ''}');
}

/// A GIF or sticker the user keeps for reuse. Stored only on this device.
class Favorite {
  Favorite(this.id, this.kind, this.mime, this.path);
  final int id;

  /// gif | sticker
  final String kind;
  final String mime;
  final String path;
}

/// One row of the chat list.
class ChatSummary {
  ChatSummary(
    this.chat,
    this.title,
    this.last,
    this.isGroup, {
    this.unread = 0,
  });
  final String chat;
  final String title;
  final ChatMessage? last;
  final bool isGroup;
  final int unread;
}
