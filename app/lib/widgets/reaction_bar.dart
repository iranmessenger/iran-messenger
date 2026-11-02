import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Reactions of other people to a message, grouped by emoji in the order
/// they were first used. Never includes the author reacting to their own
/// message.
List<MapEntry<String, List<int>>> reactionGroups(ChatMessage msg) {
  final groups = <String, List<int>>{};
  msg.reactions.forEach((who, emoji) {
    final id = int.tryParse(who);
    if (id == null || id == msg.sender || emoji.isEmpty) return;
    (groups[emoji] ??= []).add(id);
  });
  return groups.entries.toList();
}

/// Telegram-style chips under a message: the emoji with the faces of who
/// chose it (or a count when many did). Tapping a chip on someone else's
/// message adds or removes the same reaction; holding it, or tapping one
/// on your own message, lists who reacted with what.
class ReactionBar extends StatelessWidget {
  const ReactionBar({
    super.key,
    required this.state,
    required this.message,
    this.onToggle,
  });
  final AppState state;
  final ChatMessage message;
  final void Function(String emoji)? onToggle;

  @override
  Widget build(BuildContext context) {
    final groups = reactionGroups(message);
    if (groups.isEmpty) return const SizedBox.shrink();
    final m = state.messenger;
    final mine = m.myIdentity;
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final g in groups)
          ZoomIn(
            duration: const Duration(milliseconds: 220),
            child: _chip(
              context,
              g.key,
              g.value,
              g.value.contains(mine),
              primary,
            ),
          ),
      ],
    );
  }

  Widget _chip(
    BuildContext context,
    String emoji,
    List<int> who,
    bool chosen,
    Color primary,
  ) {
    final m = state.messenger;
    final own = message.outgoing;
    final faces = who.take(3).toList();
    return Material(
      color: chosen
          ? Color.alphaBlend(
              primary.withValues(alpha: 0.22),
              Brand.raised(context),
            )
          : Brand.raised(context),
      shape: StadiumBorder(
        side: BorderSide(color: chosen ? primary : Brand.hairline(context)),
      ),
      elevation: 0,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: own || onToggle == null
            ? () => showReactors(context, state, message, emoji: emoji)
            : () => onToggle!(emoji),
        onLongPress: () => showReactors(context, state, message, emoji: emoji),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 3, 5, 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 15, height: 1.3)),
              const SizedBox(width: 4),
              if (who.length <= 3)
                SizedBox(
                  width: 14.0 * (faces.length - 1) + 20,
                  height: 20,
                  child: Stack(
                    children: [
                      for (var i = 0; i < faces.length; i++)
                        PositionedDirectional(
                          start: 14.0 * i,
                          child: Container(
                            padding: const EdgeInsets.all(1),
                            decoration: BoxDecoration(
                              color: Brand.raised(context),
                              shape: BoxShape.circle,
                            ),
                            child: Avatar(
                              m.nameOf(faces[i]),
                              size: 18,
                              image: m.avatarOf(faces[i]),
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 3),
                  child: Text(
                    fa(who.length),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: chosen ? primary : Brand.muted(context),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who reacted to [msg] and with what, optionally starting on one emoji.
void showReactors(
  BuildContext context,
  AppState state,
  ChatMessage msg, {
  String? emoji,
}) {
  final groups = reactionGroups(msg);
  if (groups.isEmpty) return;
  final m = state.messenger;
  final all = [
    for (final g in groups)
      for (final id in g.value) (id, g.key),
  ];
  final tabs = ['', for (final g in groups) g.key];
  final start = emoji == null ? 0 : tabs.indexOf(emoji).clamp(0, tabs.length);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => DefaultTabController(
      length: tabs.length,
      initialIndex: start,
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: Column(
            children: [
              Text('واکنش‌ها', style: Theme.of(context).textTheme.titleMedium),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final t in tabs)
                    Tab(
                      text: t.isEmpty
                          ? 'همه ${fa(all.length)}'
                          : '$t ${fa(all.where((x) => x.$2 == t).length)}',
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final t in tabs)
                      ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          for (final (id, e) in all)
                            if (t.isEmpty || e == t)
                              ListTile(
                                leading: Avatar(
                                  m.nameOf(id),
                                  size: 40,
                                  image: m.avatarOf(id),
                                ),
                                title: Text(
                                  id == m.myIdentity ? 'شما' : m.nameOf(id),
                                ),
                                subtitle:
                                    id == m.myIdentity ||
                                        m.contact(id)?.username == null
                                    ? null
                                    : Text(
                                        '@${m.contact(id)!.username}',
                                        textDirection: TextDirection.ltr,
                                        textAlign: TextAlign.right,
                                      ),
                                trailing: Text(
                                  e,
                                  style: const TextStyle(fontSize: 24),
                                ),
                              ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
