import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

/// Top of a profile, after the profile screens of briltec/flutter_UI_Kit
/// (Apache License 2.0): the brand gradient with a curved bottom edge, a
/// large picture, the name and a line under it. While the page scrolls it
/// folds into a plain gradient toolbar that shows only [title].
class ProfileAppBar extends StatelessWidget {
  const ProfileAppBar({
    super.key,
    required this.name,
    required this.picture,
    this.title,
    this.subtitle,
    this.actions,
  });

  /// Large, under the picture.
  final String name;
  final Widget picture;

  /// In the folded toolbar; [name] when null.
  final String? title;

  /// White text or buttons under the name.
  final Widget? subtitle;
  final List<Widget>? actions;

  static const _curve = 34.0;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final expanded = subtitle == null ? 262.0 : 292.0;
    final barStyle = Theme.of(
      context,
    ).appBarTheme.titleTextStyle?.copyWith(color: Colors.white);
    return SliverAppBar(
      pinned: true,
      expandedHeight: expanded,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      actions: actions,
      flexibleSpace: LayoutBuilder(
        builder: (context, c) {
          final folded = top + kToolbarHeight;
          // 1 when fully open, 0 when folded into a toolbar.
          final t = ((c.maxHeight - folded) / (top + expanded - folded)).clamp(
            0.0,
            1.0,
          );
          final show = Curves.easeIn.transform(((t - 0.35) / 0.65).clamp(0, 1));
          return Stack(
            fit: StackFit.expand,
            children: [
              ArcHeader(height: c.maxHeight, depth: _curve * t),
              PositionedDirectional(
                top: top,
                start: 64,
                end: 64,
                height: kToolbarHeight,
                child: Opacity(
                  opacity: (1 - t * 3).clamp(0.0, 1.0),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      title ?? name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: barStyle,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: _curve * t + 12,
                child: IgnorePointer(
                  ignoring: show < 0.5,
                  child: Opacity(
                    opacity: show,
                    child: Transform.scale(
                      scale: 0.75 + 0.25 * show,
                      alignment: Alignment.bottomCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          picture,
                          const SizedBox(height: 10),
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                            ),
                          ),
                          if (subtitle != null)
                            DefaultTextStyle.merge(
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 14,
                              ),
                              child: IconTheme.merge(
                                data: const IconThemeData(color: Colors.white),
                                child: subtitle!,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
