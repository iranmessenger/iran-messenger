import 'dart:async';
import 'dart:math';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../buzz_sound.dart';
import '../platform/host.dart';
import '../theme.dart';
import 'common.dart';

/// A BUZZ in the chat history: a ringing bell and who sent it.
class BuzzChip extends StatelessWidget {
  const BuzzChip({super.key, required this.state, required this.message});
  final AppState state;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final who = message.outgoing
        ? 'شما BUZZ فرستادید'
        : '${state.messenger.nameOf(message.sender)} BUZZ فرستاد!';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 7, 10, 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: [
                Brand.amber.withValues(alpha: 0.22),
                Brand.amber.withValues(alpha: 0.10),
              ],
            ),
            border: Border.all(color: Brand.amber.withValues(alpha: 0.55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Swing(
                duration: const Duration(milliseconds: 900),
                child: const Icon(
                  Icons.vibration_rounded,
                  color: Brand.amber,
                  size: 20,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                who,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                clock(message.createdAt),
                style: TextStyle(fontSize: 11.5, color: Brand.muted(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shakes [child] (the open chat) for two seconds when a BUZZ arrives,
/// as Yahoo! Messenger did: live for everyone who has the chat open, and
/// once on entering, with its sound, for those who were away when it came
/// (within an hour).
/// The sender's own chat shakes too.
class BuzzShaker extends StatefulWidget {
  const BuzzShaker({
    super.key,
    required this.messenger,
    required this.chat,
    required this.child,
  });
  final Messenger messenger;
  final String chat;
  final Widget child;

  /// Shakes the chat around [context], if there is one.
  static void shakeOf(BuildContext context) =>
      context.findAncestorStateOfType<_BuzzShakerState>()?._play();

  @override
  State<BuzzShaker> createState() => _BuzzShakerState();
}

class _BuzzShakerState extends State<BuzzShaker>
    with SingleTickerProviderStateMixin {
  static const _fresh = Duration(hours: 1);
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );
  StreamSubscription<ChatMessage>? _sub;

  String get _key => 'buzz_shown:${widget.chat}';

  @override
  void initState() {
    super.initState();
    _sub = widget.messenger.incoming.listen((msg) {
      if (msg.kind == 'buzz' && msg.chat == widget.chat) {
        widget.messenger.db.kvPutInt(_key, msg.id);
        buzzAlert(widget.messenger);
        _play();
      }
    });
    // A BUZZ that came while this chat was closed shakes it once on entry.
    ChatMessage? missed;
    for (final m in widget.messenger.messages(widget.chat, limit: 60)) {
      if (m.kind == 'buzz' && !m.outgoing) missed = m;
    }
    if (missed != null &&
        missed.id > (widget.messenger.db.kvInt(_key) ?? 0) &&
        DateTime.now().difference(missed.createdAt) < _fresh) {
      widget.messenger.db.kvPutInt(_key, missed.id);
      Future.delayed(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        playBuzzSound(buzzSoundOf(widget.messenger));
        _play();
      });
    }
  }

  void _play() => _shake.forward(from: 0);

  @override
  void dispose() {
    _sub?.cancel();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shake,
      child: widget.child,
      builder: (_, child) {
        final t = _shake.value;
        if (t == 0 || t == 1) return child!;
        // About eight jolts a second, fading out over the last half.
        final fade = t < 0.5 ? 1.0 : (1 - t) * 2;
        final dx = sin(t * pi * 32) * 11 * fade;
        final dy = cos(t * pi * 24) * 4 * fade;
        return Transform.translate(offset: Offset(dx, dy), child: child);
      },
    );
  }
}

/// Settings row for the BUZZ sound; the sheet plays each one as it is picked.
class BuzzSoundTile extends StatelessWidget {
  const BuzzSoundTile({super.key, required this.messenger});
  final Messenger messenger;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.notifications_active_rounded),
      title: const Text('صدای BUZZ'),
      subtitle: Text(buzzSounds[buzzSoundOf(messenger)]!),
      trailing: const Icon(Icons.chevron_left_rounded),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => _BuzzSoundSheet(messenger: messenger),
      ),
    );
  }
}

class _BuzzSoundSheet extends StatefulWidget {
  const _BuzzSoundSheet({required this.messenger});
  final Messenger messenger;

  @override
  State<_BuzzSoundSheet> createState() => _BuzzSoundSheetState();
}

class _BuzzSoundSheetState extends State<_BuzzSoundSheet> {
  late String _sound = buzzSoundOf(widget.messenger);

  void _pick(String? sound) {
    if (sound == null) return;
    setState(() => _sound = sound);
    setBuzzSound(widget.messenger, sound);
    sound == 'none' ? deviceBuzz() : playBuzzSound(sound);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(
              'وقتی کسی برایتان BUZZ می‌فرستد، حتی اگر برنامه بسته باشد یا '
              'پای گوشی نباشید، همین صدا پخش می‌شود. با زدن هر گزینه صدایش '
              'را می‌شنوید.',
              style: TextStyle(fontSize: 13, color: Brand.muted(context)),
            ),
          ),
          RadioGroup<String>(
            groupValue: _sound,
            onChanged: _pick,
            child: Column(
              children: [
                for (final e in buzzSounds.entries)
                  RadioListTile<String>(value: e.key, title: Text(e.value)),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
