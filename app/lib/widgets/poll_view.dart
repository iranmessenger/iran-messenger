import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'common.dart';

/// A poll inside its message bubble: tap an answer to vote (again to take
/// the vote back). Results show once you have voted, to the author, and
/// after the poll is closed; "رای‌ها" lists who chose what.
class PollView extends StatelessWidget {
  const PollView({
    super.key,
    required this.state,
    required this.message,
    required this.color,
  });
  final AppState state;
  final ChatMessage message;

  /// Text colour of the bubble the poll sits in.
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = message.poll!;
    final m = state.messenger;
    final mine = message.votes['${m.myIdentity}'] ?? const <int>[];
    final results = mine.isNotEmpty || p.closed || message.outgoing;
    final counts = List.filled(p.options.length, 0);
    for (final choice in message.votes.values) {
      for (final i in choice) {
        if (i >= 0 && i < counts.length) counts[i]++;
      }
    }
    final voters = message.votes.length;
    final accent = message.outgoing
        ? Colors.white
        : Theme.of(context).colorScheme.primary;
    final meta = color.withValues(alpha: 0.66);

    void toggle(int i) {
      final next = p.multi
          ? (mine.contains(i)
                ? (mine.where((x) => x != i).toList())
                : [...mine, i])
          : (mine.length == 1 && mine.first == i ? <int>[] : [i]);
      m.vote(message, next);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 230),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.poll_rounded, size: 16, color: meta),
              const SizedBox(width: 5),
              Text(
                p.closed
                    ? 'نظرسنجی بسته شده'
                    : p.multi
                    ? 'نظرسنجی چندگزینه‌ای'
                    : 'نظرسنجی',
                style: TextStyle(fontSize: 12.5, color: meta),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            message.body,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < p.options.length; i++)
            _Option(
              text: p.options[i],
              chosen: mine.contains(i),
              multi: p.multi,
              share: voters == 0 ? 0 : counts[i] / voters,
              results: results,
              color: color,
              accent: accent,
              onTap: p.closed ? null : () => toggle(i),
            ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                voters == 0
                    ? 'هنوز کسی رای نداده'
                    : fa('$voters نفر رای دادند'),
                style: TextStyle(fontSize: 12.5, color: meta),
              ),
              if (voters > 0) ...[
                const SizedBox(width: 6),
                _Link(
                  label: 'رای‌ها',
                  color: accent,
                  onTap: () => showVoters(context, state, message),
                ),
              ],
              if (message.outgoing && !p.closed) ...[
                const SizedBox(width: 6),
                _Link(
                  label: 'پایان رای‌گیری',
                  color: accent,
                  onTap: () => _close(context),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _close(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('پایان رای‌گیری؟'),
        content: const Text(
          'بعد از آن کسی نمی‌تواند رای بدهد یا رایش را عوض کند.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('پایان'),
          ),
        ],
      ),
    );
    if (ok == true) await state.messenger.closePoll(message);
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.text,
    required this.chosen,
    required this.multi,
    required this.share,
    required this.results,
    required this.color,
    required this.accent,
    required this.onTap,
  });
  final String text;
  final bool chosen;
  final bool multi;
  final double share;
  final bool results;
  final Color color;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final icon = multi
        ? (chosen ? Icons.check_box_rounded : Icons.check_box_outline_blank)
        : (chosen ? Icons.check_circle_rounded : Icons.radio_button_unchecked);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: chosen ? accent : color.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(fontSize: 14.5, color: color),
                  ),
                ),
                if (results)
                  Text(
                    '${fa((share * 100).round())}٪',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
              ],
            ),
            if (results)
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 5, start: 28),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    children: [
                      Container(
                        height: 6,
                        color: color.withValues(alpha: 0.12),
                      ),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: share),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        builder: (_, v, _) => FractionallySizedBox(
                          // Fills from the start (right) side.
                          alignment: AlignmentDirectional.centerStart,
                          widthFactor: v.clamp(0, 1),
                          child: Container(
                            height: 6,
                            color: accent.withValues(
                              alpha: chosen ? 0.95 : 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Everyone who voted, under each answer.
void showVoters(BuildContext context, AppState state, ChatMessage poll) {
  final m = state.messenger;
  final p = poll.poll!;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                poll.body,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (var i = 0; i < p.options.length; i++) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  '${p.options[i]} · ${fa(poll.votes.values.where((c) => c.contains(i)).length)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              for (final e in poll.votes.entries)
                if (e.value.contains(i))
                  ListTile(
                    dense: true,
                    leading: Avatar(
                      m.nameOf(int.parse(e.key)),
                      size: 34,
                      image: m.avatarOf(int.parse(e.key)),
                    ),
                    title: Text(
                      int.parse(e.key) == m.myIdentity
                          ? 'شما'
                          : m.nameOf(int.parse(e.key)),
                    ),
                  ),
              if (!poll.votes.values.any((c) => c.contains(i)))
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
                  child: Text(
                    'کسی این گزینه را انتخاب نکرده',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Brand.muted(context),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
