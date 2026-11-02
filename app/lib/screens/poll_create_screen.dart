import 'package:flutter/material.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Writes a poll: a question, two to ten answers, and whether several
/// answers may be chosen.
class PollCreateScreen extends StatefulWidget {
  const PollCreateScreen({super.key, required this.state, required this.chat});
  final AppState state;
  final String chat;

  @override
  State<PollCreateScreen> createState() => _PollCreateScreenState();
}

class _PollCreateScreenState extends State<PollCreateScreen> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];
  bool _multi = false;
  bool _busy = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _send() async {
    final q = _question.text.trim();
    final answers = [
      for (final c in _options)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    if (q.isEmpty) return _toast('سوال نظرسنجی را بنویسید.');
    if (answers.length < 2) return _toast('دست‌کم دو گزینه لازم است.');
    if (answers.toSet().length != answers.length) {
      return _toast('دو گزینه یکسان است.');
    }
    setState(() => _busy = true);
    try {
      await widget.state.messenger.sendPoll(
        widget.chat,
        q,
        answers,
        multi: _multi,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      _toast('نظرسنجی فرستاده نشد.');
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Brand.muted(context);
    return Scaffold(
      appBar: AppBar(title: const Text('نظرسنجی تازه')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            controller: _question,
            maxLength: 300,
            minLines: 1,
            maxLines: 4,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'سوال',
              prefixIcon: Icon(Icons.poll_rounded),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'گزینه‌ها',
            style: TextStyle(fontWeight: FontWeight.w700, color: muted),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _options[i],
                maxLength: 100,
                decoration: InputDecoration(
                  counterText: '',
                  hintText: fa('گزینه ${i + 1}'),
                  suffixIcon: _options.length <= 2
                      ? null
                      : IconButton(
                          tooltip: 'حذف گزینه',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () =>
                              setState(() => _options.removeAt(i).dispose()),
                        ),
                ),
              ),
            ),
          if (_options.length < MessengerFun.maxPollOptions)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded),
                label: const Text('افزودن گزینه'),
              ),
            ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('چند گزینه‌ای'),
            subtitle: const Text('هر نفر بتواند بیش از یک گزینه انتخاب کند.'),
            value: _multi,
            onChanged: (v) => setState(() => _multi = v),
          ),
          const SizedBox(height: 4),
          Text(
            'همه اعضا می‌بینند چه کسی به کدام گزینه رای داده است.',
            style: TextStyle(fontSize: 12.5, color: muted),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.send_rounded),
            label: const Text('فرستادن نظرسنجی'),
          ),
        ],
      ),
    );
  }
}
