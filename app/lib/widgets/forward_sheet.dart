import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import 'common.dart';

/// The local copy of an attachment, fetched first if it is not here yet.
/// Null if the server no longer has it.
Future<Uint8List?> attachmentBytes(Messenger m, ChatMessage msg) async {
  var path = msg.media?.path;
  if (path == null || !m.files.existsSync(path)) {
    path = await m.media.download(msg.id);
  }
  return path == null ? null : m.files.read(path);
}

/// A file name with an extension, so the saved copy opens in other apps.
String saveName(MediaInfo info) {
  final name = info.name.trim();
  if (name.contains('.')) return name;
  final ext = switch (info.mime) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'video/mp4' => 'mp4',
    'audio/mp4' => 'm4a',
    'audio/webm' => 'webm',
    'application/pdf' => 'pdf',
    _ => 'bin',
  };
  return '${name.isEmpty ? 'irm' : name}.$ext';
}

/// Lets the user keep an attachment on their phone (or download it in a
/// browser).
Future<void> saveAttachment(
  BuildContext context,
  AppState state,
  ChatMessage msg,
) async {
  final toast = ScaffoldMessenger.of(context);
  try {
    final bytes = await attachmentBytes(state.messenger, msg);
    if (bytes == null) {
      toast.showSnackBar(
        const SnackBar(content: Text('این فایل دیگر روی سرور نیست.')),
      );
      return;
    }
    if (await saveBytes(saveName(msg.media!), bytes)) {
      toast.showSnackBar(const SnackBar(content: Text('ذخیره شد.')));
    }
  } catch (_) {
    toast.showSnackBar(const SnackBar(content: Text('ذخیره انجام نشد.')));
  }
}

/// Sends a copy of [msg] to another chat the user picks.
Future<void> showForwardSheet(
  BuildContext context,
  AppState state,
  ChatMessage msg,
) {
  final m = state.messenger;
  final toast = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) {
      var query = '';
      return StatefulBuilder(
        builder: (sheet, setState) {
          final chats = m
              .chats()
              .where(
                (c) =>
                    !c.isGroup || (m.group(c.chat.substring(2))?.left == false),
              )
              .where(
                (c) => query.isEmpty || c.title.toLowerCase().contains(query),
              )
              .toList();
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheet).height * 0.6,
              child: Column(
                children: [
                  const Text(
                    'هدایت به…',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                    child: TextField(
                      onChanged: (v) =>
                          setState(() => query = v.trim().toLowerCase()),
                      decoration: const InputDecoration(
                        hintText: 'جستجوی گفتگو',
                        prefixIcon: Icon(Icons.search_rounded),
                        isDense: true,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final c in chats)
                          ListTile(
                            leading: Avatar(
                              c.title,
                              group: c.isGroup,
                              size: 42,
                              image: m.chatAvatar(c.chat),
                            ),
                            title: Text(c.title),
                            onTap: () async {
                              Navigator.pop(sheet);
                              try {
                                if (msg.kind == 'media' && msg.media != null) {
                                  final bytes = await attachmentBytes(m, msg);
                                  if (bytes == null) {
                                    toast.showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'این فایل دیگر روی سرور نیست.',
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  final info = msg.media!;
                                  await m.sendMedia(
                                    c.chat,
                                    bytes,
                                    name: info.name,
                                    kind: info.kind,
                                    mime: info.mime,
                                    caption: msg.body,
                                    durationMs: info.durationMs,
                                  );
                                } else {
                                  await m.sendText(c.chat, msg.body);
                                }
                                toast.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'به «${c.title}» فرستاده شد.',
                                    ),
                                  ),
                                );
                              } catch (_) {
                                toast.showSnackBar(
                                  const SnackBar(
                                    content: Text('هدایت انجام نشد.'),
                                  ),
                                );
                              }
                            },
                          ),
                        if (chats.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'گفتگویی پیدا نشد.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Brand.muted(context)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
