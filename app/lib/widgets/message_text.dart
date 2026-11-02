import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Web addresses and @mentions inside a message, found in one pass.
final _tokens = RegExp(
  r'''(?<link>(?:https?://|www\.)[^\s<>"']+)|(?<mention>@[a-zA-Z][a-zA-Z0-9_]{3,19})''',
  caseSensitive: false,
);

final _lri = String.fromCharCode(0x2066);
final _pdi = String.fromCharCode(0x2069);

/// Punctuation that ends a sentence rather than the address.
final _trailing = RegExp(r'''[.,;:!?؟،)\]}»"']+$''');

/// Message text with @mentions and web addresses emphasised and tappable.
/// Both are isolated left-to-right so they read correctly inside Persian.
InlineSpan richMessageText(
  BuildContext context, {
  required String text,
  required Color color,
  required Color accent,
  void Function(String username)? onMention,
  double fontSize = 15.5,
}) {
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in _tokens.allMatches(text)) {
    if (m.start < at) continue;
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    final link = m.namedGroup('link');
    if (link != null) {
      final cut = _trailing.firstMatch(link);
      final url = cut == null ? link : link.substring(0, cut.start);
      spans.add(
        TextSpan(
          text: '$_lri$url$_pdi',
          style: TextStyle(
            color: accent,
            decoration: TextDecoration.underline,
            decorationColor: accent.withValues(alpha: 0.6),
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => openLink(context, url),
        ),
      );
      if (cut != null) spans.add(TextSpan(text: link.substring(cut.start)));
    } else {
      final name = m[0]!.substring(1).toLowerCase();
      spans.add(
        TextSpan(
          text: '$_lri${m[0]}$_pdi',
          style: TextStyle(color: accent, fontWeight: FontWeight.w700),
          recognizer: onMention == null
              ? null
              : (TapGestureRecognizer()..onTap = () => onMention(name)),
        ),
      );
    }
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(
    style: TextStyle(color: color, fontSize: fontSize, height: 1.5),
    children: spans,
  );
}

/// Opens a web address in the phone's browser. Only http(s) addresses are
/// opened; if no browser takes it, the address is copied instead.
Future<void> openLink(BuildContext context, String raw) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var url = raw.trim();
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
    url = 'https://$url';
  }
  final uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return;
  }
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened) {
    await Clipboard.setData(ClipboardData(text: url));
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('برنامهای برای باز کردن لینک پیدا نشد؛ لینک کپی شد.'),
      ),
    );
  }
}
