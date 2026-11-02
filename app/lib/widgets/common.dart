import 'package:flutter/material.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import 'motion.dart';

String _two(int n) => n.toString().padLeft(2, '0');

const _faDigits = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

/// Latin digits to Persian digits, for anything shown to the user.
String fa(Object value) => value.toString().replaceAllMapped(
  RegExp(r'\d'),
  (m) => _faDigits[int.parse(m[0]!)],
);

const _jalaliMonths = [
  'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
  'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند', //
];

/// Gregorian date to Solar Hijri [year, month, day].
List<int> toJalali(DateTime t) {
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  final gy = t.year, gm = t.month, gd = t.day;
  final gy2 = gm > 2 ? gy + 1 : gy;
  var days =
      355666 +
      365 * gy +
      (gy2 + 3) ~/ 4 -
      (gy2 + 99) ~/ 100 +
      (gy2 + 399) ~/ 400 +
      gd +
      gdm[gm - 1];
  var jy = -1595 + 33 * (days ~/ 12053);
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  final jm = days < 186 ? 1 + days ~/ 31 : 7 + (days - 186) ~/ 30;
  final jd = 1 + (days < 186 ? days % 31 : (days - 186) % 30);
  return [jy, jm, jd];
}

/// Current time for date labels; tests pin it so screenshots stay stable.
DateTime Function() labelNow = DateTime.now;

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "امروز", "دیروز" or a Solar Hijri date such as "۱۹ مهر".
String dayLabel(DateTime t) {
  final now = labelNow();
  if (sameDay(t, now)) return 'امروز';
  if (sameDay(t, now.subtract(const Duration(days: 1)))) return 'دیروز';
  final j = toJalali(t);
  final sameYear = toJalali(now)[0] == j[0];
  return fa('${j[2]} ${_jalaliMonths[j[1] - 1]}${sameYear ? '' : ' ${j[0]}'}');
}

/// Keeps `@name` reading left-to-right when embedded in Persian text.
String isolateMentions(String s) => s.replaceAllMapped(
  RegExp(r'@[a-zA-Z][a-zA-Z0-9_]{3,19}'),
  (m) => '\u2066${m[0]}\u2069',
);

String clock(DateTime t) => fa('${_two(t.hour)}:${_two(t.minute)}');

/// Time today, otherwise the day label.
String shortTime(DateTime t) => sameDay(t, labelNow()) ? clock(t) : dayLabel(t);

String fileSize(int bytes) => fa(
  bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} مگابایت'
      : '${(bytes / 1024).ceil()} کیلوبایت',
);

String duration(int ms) {
  final s = (ms / 1000).round();
  return fa('${s ~/ 60}:${_two(s % 60)}');
}

/// Round avatar with a per-name gradient, a light rim and a soft shadow.
class Avatar extends StatelessWidget {
  const Avatar(
    this.name, {
    super.key,
    this.group = false,
    this.size = 48,
    this.image,
  });
  final String name;
  final bool group;
  final double size;

  /// Local path of a profile picture; initials are shown without one.
  final String? image;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: group ? Brand.gradient : Brand.avatar(trimmed),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: Brand.shadow(context, strength: 0.7),
      ),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: image != null
          ? localImage(
              image!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: 320,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            )
          : group
          ? Icon(Icons.groups_rounded, color: Colors.white, size: size * 0.5)
          : Text(
              trimmed.isEmpty ? '?' : trimmed.characters.first,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.42,
                height: 1.2,
              ),
            ),
    );
  }
}

/// A raised rounded panel: the basic "object on a surface" of this design.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 18,
    this.onTap,
    this.onLongPress,
  });
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: Brand.card(context),
        borderRadius: r,
        border: Border.all(color: Brand.hairline(context)),
        boxShadow: Brand.shadow(context),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );
  }
}

/// Count pill for unread messages (see [CountPill]).
class UnreadBadge extends StatelessWidget {
  const UnreadBadge(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => CountPill(count);
}

/// Shown under the app bar whenever the server cannot be reached.
class LinkBanner extends StatelessWidget {
  const LinkBanner({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.link == LinkState.ok) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: Brand.shadow(context, strength: 0.6),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 20,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.linkText,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular gradient action button (send, new chat).
class GradientIconButton extends StatelessWidget {
  const GradientIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 50,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: Brand.gradient,
          boxShadow: [
            BoxShadow(
              color: Brand.deep.withValues(alpha: 0.45),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            // A new icon (microphone to send) turns and grows into place.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, a) => RotationTransition(
                turns: Tween(begin: 0.85, end: 1.0).animate(a),
                child: ScaleTransition(scale: a, child: child),
              ),
              child: Icon(
                icon,
                key: ValueKey(icon),
                color: Colors.white,
                size: size * 0.46,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks an account the server has made a bot: it posts but never sees
/// what anyone writes.
class BotBadge extends StatelessWidget {
  const BotBadge({super.key, this.size = 11});
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_rounded, size: size + 2, color: color),
          const SizedBox(width: 3),
          Text(
            'ربات',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
