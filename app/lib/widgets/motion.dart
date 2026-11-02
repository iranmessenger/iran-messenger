import 'package:animate_do/animate_do.dart';
import 'package:badges/badges.dart' as badges;
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../theme.dart';
import 'common.dart';

/// Motion and small animated pieces shared by the screens.
///
/// Sources (see app/THIRD_PARTY_NOTICES.md): entrance staggering follows the
/// "Staggered List" template and the typing dots the "Simple Chat"
/// template of fluttertemplates.dev (MIT); entrances are driven by
/// animate_do, count badges by badges, icons by Lottie animations from
/// the flutter_animated_icons collection (LottieFiles).

/// Marks the moment a screen first appeared. Rows built within the first
/// moments animate in; rows built later (scrolling back, rebuilds) do not,
/// so lists never flicker while being used.
class EntranceScope extends StatefulWidget {
  const EntranceScope({super.key, required this.child});
  final Widget child;

  static bool active(BuildContext context) {
    final s = context
        .dependOnInheritedWidgetOfExactType<_EntranceData>()
        ?.start;
    return s != null &&
        DateTime.now().difference(s) < const Duration(milliseconds: 900);
  }

  @override
  State<EntranceScope> createState() => _EntranceScopeState();
}

class _EntranceScopeState extends State<EntranceScope> {
  final _start = DateTime.now();

  @override
  Widget build(BuildContext context) =>
      _EntranceData(start: _start, child: widget.child);
}

class _EntranceData extends InheritedWidget {
  const _EntranceData({required this.start, required super.child});
  final DateTime start;

  @override
  bool updateShouldNotify(_EntranceData old) => old.start != start;
}

/// Fades and lifts [child] into place, [index] steps after the first row.
class Entrance extends StatelessWidget {
  const Entrance({
    super.key,
    required this.child,
    this.index = 0,
    this.always = false,
  });
  final Widget child;
  final int index;

  /// Animate even outside an [EntranceScope] (single elements).
  final bool always;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    if (!always && (index > 14 || !EntranceScope.active(context))) {
      return child;
    }
    return FadeInUp(
      from: 18,
      duration: const Duration(milliseconds: 420),
      delay: Duration(milliseconds: 45 * index.clamp(0, 14)),
      curve: Curves.easeOutCubic,
      child: child,
    );
  }
}

/// Count of unread messages: a gradient pill that pops in and out.
class CountPill extends StatelessWidget {
  const CountPill(this.count, {super.key, this.child, this.mention = false});
  final int count;

  /// When given, the pill sits on its top corner (e.g. on an avatar).
  final Widget? child;

  /// Someone named this user: shows "@" in the brand orange instead.
  final bool mention;

  @override
  Widget build(BuildContext context) {
    final show = count > 0 || mention;
    return badges.Badge(
      showBadge: show,
      ignorePointer: true,
      position: child == null
          ? null
          : badges.BadgePosition.topEnd(top: -3, end: -5),
      badgeAnimation: const badges.BadgeAnimation.scale(
        animationDuration: Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
      ),
      badgeStyle: badges.BadgeStyle(
        shape: badges.BadgeShape.square,
        borderRadius: BorderRadius.circular(12),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        badgeGradient: badges.BadgeGradient.linear(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: mention
              ? const [Color(0xFFFFB25B), Brand.amber]
              : const [Color(0xFF34CF94), Color(0xFF0F7F5A)],
        ),
        borderSide: child == null
            ? BorderSide.none
            : BorderSide(color: Brand.page(context), width: 2),
        elevation: 0,
      ),
      badgeContent: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 9),
        child: Text(
          mention ? '@' : fa(count > 99 ? '99+' : count),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// A brand-coloured animated icon. [name] is a file in assets/anim/.
class BrandLottie extends StatelessWidget {
  const BrandLottie(
    this.name, {
    super.key,
    this.size = 56,
    this.color,
    this.repeat = false,
  });
  final String name;
  final double size;

  /// Recolours every shape; null keeps the animation's own colours.
  final Color? color;
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    final c = color;
    return Lottie.asset(
      'assets/anim/$name.json',
      width: size,
      height: size,
      repeat: repeat,
      animate: !MediaQuery.disableAnimationsOf(context),
      delegates: c == null
          ? null
          : LottieDelegates(
              values: [
                ValueDelegate.color(const ['**'], value: c),
                ValueDelegate.strokeColor(const ['**'], value: c),
              ],
            ),
      errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
    );
  }
}

/// "Someone is typing": three dots that rise in turn inside a small bubble.
class TypingBubble extends StatefulWidget {
  const TypingBubble({super.key, this.name});

  /// Shown above the dots in groups.
  final String? name;

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _dot(int i, Color color) {
    final start = i * 0.18;
    final rise = CurvedAnimation(
      parent: _c,
      curve: Interval(start, start + 0.36, curve: Curves.easeInOut),
    );
    return AnimatedBuilder(
      animation: rise,
      builder: (_, _) {
        // Up and back down within the interval.
        final v = rise.value < 0.5 ? rise.value * 2 : (1 - rise.value) * 2;
        return Transform.translate(
          offset: Offset(0, -4 * v),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.45 + 0.55 * v),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = Brand.muted(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: FadeIn(
        duration: const Duration(milliseconds: 250),
        child: Container(
          // Same edges and corners as an incoming message bubble.
          margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
          decoration: BoxDecoration(
            color: Brand.bubbleIn(context),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomRight: Radius.circular(18),
              bottomLeft: Radius.circular(5),
            ),
            border: Border.all(color: Brand.hairline(context)),
            boxShadow: Brand.shadow(context, strength: 0.6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.name != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    widget.name!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Brand.avatar(widget.name!).colors.last,
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                textDirection: TextDirection.ltr,
                children: [
                  _dot(0, muted),
                  const SizedBox(width: 5),
                  _dot(1, muted),
                  const SizedBox(width: 5),
                  _dot(2, muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Curved bottom edge for gradient headers. Adapted from ArcClipper in
/// briltec/flutter_UI_Kit (Apache License 2.0).
class ArcClipper extends CustomClipper<Path> {
  const ArcClipper({this.depth = 30});
  final double depth;

  @override
  Path getClip(Size size) {
    return Path()
      ..lineTo(0, size.height - depth)
      ..quadraticBezierTo(
        size.width / 4,
        size.height,
        size.width / 2,
        size.height,
      )
      ..quadraticBezierTo(
        size.width * 3 / 4,
        size.height,
        size.width,
        size.height - depth,
      )
      ..lineTo(size.width, 0)
      ..close();
  }

  @override
  bool shouldReclip(ArcClipper old) => old.depth != depth;
}

/// The brand gradient header with a curved bottom, used behind profiles.
class ArcHeader extends StatelessWidget {
  const ArcHeader({
    super.key,
    required this.height,
    this.depth = 34,
    this.child,
  });
  final double height;

  /// How far the curve dips; 0 gives a straight edge (a folded header).
  final double depth;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: ArcClipper(depth: depth),
      child: Container(
        height: height,
        width: double.infinity,
        decoration: const BoxDecoration(gradient: Brand.gradient),
        child: Stack(
          children: [
            // Two soft light spots give the flat gradient some depth.
            PositionedDirectional(
              top: -60,
              start: -40,
              child: _Glow(size: 200, alpha: 0.18),
            ),
            PositionedDirectional(
              bottom: -80,
              end: -30,
              child: _Glow(size: 240, alpha: 0.12),
            ),
            if (child != null) Positioned.fill(child: child!),
          ],
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.alpha});
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}
