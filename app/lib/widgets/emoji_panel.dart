import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Emoji keyboard shown in place of the system keyboard under the message
/// box. Picked emoji go in at the cursor of [controller]; recently used
/// ones come first.
class EmojiPanel extends StatelessWidget {
  const EmojiPanel({super.key, required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final surface = Brand.raised(context);
    final muted = Brand.muted(context);
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: Brand.hairline(context))),
      ),
      child: EmojiPicker(
        textEditingController: controller,
        config: Config(
          height: 300,
          // The emoji font ships with the app, so every emoji can be drawn.
          checkPlatformCompatibility: false,
          emojiViewConfig: EmojiViewConfig(
            columns: 8,
            emojiSizeMax: 30,
            backgroundColor: surface,
            recentsLimit: 32,
            noRecents: Text(
              'هنوز شکلکی نفرستاده‌اید',
              style: TextStyle(fontSize: 14, color: muted),
            ),
          ),
          categoryViewConfig: CategoryViewConfig(
            backgroundColor: surface,
            indicatorColor: primary,
            iconColor: muted,
            iconColorSelected: primary,
            dividerColor: Brand.hairline(context),
            recentTabBehavior: RecentTabBehavior.RECENT,
          ),
          bottomActionBarConfig: BottomActionBarConfig(
            backgroundColor: surface,
            buttonColor: surface,
            buttonIconColor: muted,
          ),
          searchViewConfig: SearchViewConfig(
            backgroundColor: surface,
            buttonIconColor: muted,
            hintText: 'جستجو (انگلیسی)',
          ),
        ),
      ),
    );
  }
}
