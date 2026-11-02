import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

/// Visual language of the app (redesign 2.15).
///
/// Dark-first, ink-navy surfaces that step up in tone instead of relying on
/// heavy shadows; the logo's cyan-to-royal-blue gradient for anything that
/// is "yours" (own messages, primary actions); the logo's orange for things
/// that need the eye (mentions, read ticks); generous radii; Vazirmatn
/// throughout. Page transitions come from the animations package (Material
/// motion), retuned to these tokens. Ideas from fossui are taken one piece
/// at a time rather than through the package.
class Brand {
  static const teal = Color(0xFF2BC48A); // logo green
  static const deep = Color(0xFF0E6B4E); // logo deep green
  static const amber = Color(0xFFFF8A1F); // logo orange
  static const navy = Color(0xFF04122B);

  /// Primary action and own-message gradient.
  static const gradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFF34CF94), Color(0xFF0F7F5A)],
  );

  /// Primary buttons: the same gradient a shade deeper, so white labels
  /// stay readable across all of it.
  static const action = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFF27B07E), Color(0xFF0B6A4C)],
  );

  static bool dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

  /// A destructive button (delete, leave): solid red with a white label in
  /// both themes, without the gradient.
  static ButtonStyle danger(BuildContext c) => FilledButton.styleFrom(
    backgroundColor: dark(c)
        ? const Color(0xFFD63A3A)
        : Theme.of(c).colorScheme.error,
    foregroundColor: Colors.white,
    backgroundBuilder: _flat,
  );

  /// A quiet button inside a card, where a full gradient would shout.
  static ButtonStyle tonal(BuildContext c) {
    final p = Theme.of(c).colorScheme.primary;
    return FilledButton.styleFrom(
      minimumSize: const Size(120, 44),
      backgroundColor: p.withValues(alpha: dark(c) ? 0.16 : 0.1),
      foregroundColor: p,
      backgroundBuilder: _flat,
    );
  }

  static Widget _flat(BuildContext _, Set<WidgetState> _, Widget? child) =>
      child!;

  /// Ticks of a message someone has read: warm gold, which stands out on
  /// the blue bubble (where white means delivered) and on the chat list.
  static Color readTick(BuildContext c) =>
      dark(c) ? const Color(0xFFFFCB57) : const Color(0xFFE38A00);

  // Surfaces, from the page background up to floating elements. In dark
  // mode depth is carried by tone; in light mode by hairlines and shadow.
  static Color page(BuildContext c) =>
      dark(c) ? const Color(0xFF0A111D) : const Color(0xFFF2F5FA);
  static Color card(BuildContext c) =>
      dark(c) ? const Color(0xFF111A28) : Colors.white;
  static Color raised(BuildContext c) =>
      dark(c) ? const Color(0xFF18233A) : Colors.white;
  static Color hairline(BuildContext c) =>
      dark(c) ? const Color(0x14FFFFFF) : const Color(0x160A2540);
  static Color muted(BuildContext c) =>
      dark(c) ? const Color(0xFF8B99B0) : const Color(0xFF66758C);

  static Color bubbleIn(BuildContext c) =>
      dark(c) ? const Color(0xFF172236) : Colors.white;
  static LinearGradient bubbleOut(BuildContext c) => LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: dark(c)
        ? const [Color(0xFF27B07E), Color(0xFF0B6A4C)]
        : const [Color(0xFF33C98E), Color(0xFF0E7A57)],
  );
  static Color onBubbleOut(BuildContext c) => Colors.white;

  static List<BoxShadow> shadow(BuildContext c, {double strength = 1}) => [
    BoxShadow(
      color: (dark(c) ? Colors.black : const Color(0xFF0A2540)).withValues(
        alpha: (dark(c) ? 0.32 : 0.07) * strength,
      ),
      blurRadius: 18 * strength,
      offset: Offset(0, 6 * strength),
    ),
  ];

  /// A soft coloured glow under gradient elements (buttons, own bubbles).
  static List<BoxShadow> glow({double strength = 1}) => [
    BoxShadow(
      color: teal.withValues(alpha: 0.30 * strength),
      blurRadius: 22 * strength,
      offset: Offset(0, 8 * strength),
    ),
  ];

  static const _avatarPalettes = [
    [Color(0xFFFF8A65), Color(0xFFE5533D)],
    [Color(0xFF8C9BFF), Color(0xFF5661D8)],
    [Color(0xFF4FD1A8), Color(0xFF169C82)],
    [Color(0xFFFFC266), Color(0xFFE48A1A)],
    [Color(0xFFF07FAE), Color(0xFFC2447C)],
    [Color(0xFF5BC0F5), Color(0xFF2B7FD0)],
    [Color(0xFFB59BFF), Color(0xFF7C4DDB)],
  ];

  /// A stable colour pair per name, so each person is recognisable at a glance.
  static LinearGradient avatar(String name) {
    var h = 0;
    for (final u in name.runes) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    final p = _avatarPalettes[h % _avatarPalettes.length];
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: p,
    );
  }

  static ThemeData theme(Brightness b) {
    final isDark = b == Brightness.dark;
    final page = isDark ? const Color(0xFF0A111D) : const Color(0xFFF2F5FA);
    final card = isDark ? const Color(0xFF111A28) : Colors.white;
    final raised = isDark ? const Color(0xFF18233A) : Colors.white;
    final ink = isDark ? const Color(0xFFE9EEF6) : const Color(0xFF0F1A2A);
    final muted = isDark ? const Color(0xFF8B99B0) : const Color(0xFF66758C);
    final hairline = isDark ? const Color(0x14FFFFFF) : const Color(0x160A2540);
    final primary = isDark ? const Color(0xFF3DD69B) : const Color(0xFF0E7A57);
    final scheme = ColorScheme.fromSeed(seedColor: teal, brightness: b)
        .copyWith(
          primary: primary,
          onPrimary: Colors.white,
          secondary: amber,
          surface: card,
          onSurface: ink,
          surfaceContainerHighest: raised,
          outlineVariant: hairline,
        );
    TextStyle t(double size, FontWeight w, {Color? color, double h = 1.5}) =>
        TextStyle(
          fontFamily: 'Vazirmatn',
          fontSize: size,
          fontWeight: w,
          height: h,
          color: color ?? ink,
        );
    // Material motion: the next page grows out of the current one. It has
    // no left or right, so it reads the same in a right-to-left app.
    const motion = SharedAxisPageTransitionsBuilder(
      transitionType: SharedAxisTransitionType.scaled,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Vazirmatn',
      scaffoldBackgroundColor: page,
      canvasColor: page,
      dividerColor: hairline,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: motion,
          TargetPlatform.iOS: motion,
          TargetPlatform.windows: motion,
          TargetPlatform.linux: motion,
          TargetPlatform.macOS: motion,
        },
      ),
      textTheme: TextTheme(
        headlineSmall: t(24, FontWeight.w700, h: 1.35),
        titleLarge: t(20, FontWeight.w700, h: 1.4),
        titleMedium: t(16, FontWeight.w600),
        titleSmall: t(14, FontWeight.w600),
        bodyLarge: t(15.5, FontWeight.w400),
        bodyMedium: t(14.5, FontWeight.w400),
        bodySmall: t(12.5, FontWeight.w400, color: muted),
        labelLarge: t(14.5, FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: page,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 2,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
        titleTextStyle: t(19, FontWeight.w700, h: 1.3),
      ),
      cardTheme: CardThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: hairline),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        titleTextStyle: t(15.5, FontWeight.w600, h: 1.4),
        subtitleTextStyle: t(13, FontWeight.w400, color: muted, h: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: muted.withValues(alpha: 0.45),
        modalBarrierColor: Colors.black.withValues(alpha: 0.42),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: t(18, FontWeight.w700, h: 1.4),
        contentTextStyle: t(14.5, FontWeight.w400, color: muted, h: 1.65),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: hairline),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF18233A) : const Color(0xFFF0F4F9),
        hintStyle: t(14.5, FontWeight.w400, color: muted),
        prefixIconColor: muted,
        suffixIconColor: muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: t(16, FontWeight.w700),
          // The brand gradient. Ink paints it on the button's own surface,
          // so the touch ripple still shows on top of it; the button does
          // not clip, so the gradient carries the same corners.
          backgroundBuilder: (context, states, child) =>
              states.contains(WidgetState.disabled)
              ? child!
              : Ink(
                  decoration: BoxDecoration(
                    gradient: action,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: child,
                ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          side: BorderSide(color: hairline, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: t(14.5, FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: t(14.5, FontWeight.w600),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? primary
              : (isDark ? const Color(0xFF243149) : const Color(0xFFDCE4EE)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: muted,
        labelStyle: t(14.5, FontWeight.w700),
        unselectedLabelStyle: t(14.5, FontWeight.w500),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: hairline,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: primary, width: 3),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        side: BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: t(13, FontWeight.w500),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF243149) : const Color(0xFF1A2639),
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: t(12.5, FontWeight.w500, color: Colors.white),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: hairline,
        circularTrackColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF243149)
            : const Color(0xFF14213A),
        contentTextStyle: t(14, FontWeight.w500, color: Colors.white),
        insetPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

/// Soft patterned backdrop behind the messages, so bubbles read as objects
/// resting on a surface instead of blending into a flat fill.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Brand.dark(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF0A111D), Color(0xFF0D1828)]
              : const [Color(0xFFE6EDF7), Color(0xFFEEF2F8)],
        ),
      ),
      child: CustomPaint(
        painter: _PatternPainter(
          dark
              ? Colors.white.withValues(alpha: 0.026)
              : const Color(0xFF0E6B4E).withValues(alpha: 0.045),
        ),
        child: child,
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;
    const step = 64.0;
    var row = 0;
    for (var y = 20.0; y < size.height + step; y += step, row++) {
      var col = 0;
      for (
        var x = (row.isEven ? 18.0 : 50.0);
        x < size.width + step;
        x += step, col++
      ) {
        switch ((row + col * 2) % 4) {
          case 0:
            canvas.drawCircle(Offset(x, y), 7, stroke);
          case 1:
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(center: Offset(x, y), width: 18, height: 12),
                const Radius.circular(5),
              ),
              stroke,
            );
          case 2:
            canvas.drawCircle(Offset(x, y), 2.4, fill);
          default:
            canvas.drawLine(Offset(x - 6, y), Offset(x + 6, y), stroke);
            canvas.drawLine(Offset(x, y - 6), Offset(x, y + 6), stroke);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) => old.color != color;
}
