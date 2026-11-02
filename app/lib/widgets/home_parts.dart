import 'package:flutter/material.dart';

import '../platform/host.dart';
import '../theme.dart';
import 'motion.dart';

/// Shown instead of the chat list when there is nothing to list.
class HomeEmpty extends StatelessWidget {
  const HomeEmpty({super.key, required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final q = query;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Brand.card(context),
                border: Border.all(color: Brand.hairline(context)),
                boxShadow: Brand.shadow(context),
              ),
              child: q.isEmpty
                  ? BrandLottie(
                      'chats',
                      size: 72,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : Icon(
                      Icons.search_off_rounded,
                      size: 44,
                      color: Brand.muted(context),
                    ),
            ),
            const SizedBox(height: 18),
            Text(
              q.isEmpty ? 'هنوز گفتگویی ندارید' : 'گفتگویی با این نام پیدا نشد',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            if (q.isEmpty)
              Text(
                isWebApp
                    ? 'با دکمه پایین، دوستانتان را با نام کاربری پیدا کنید.'
                    : 'با دکمه پایین، دوستانتان را از دفترچه تلفن یا با نام کاربری پیدا کنید.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Brand.muted(context)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The floating pill that starts a new conversation.
class StartChatButton extends StatelessWidget {
  const StartChatButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Brand.teal.withValues(alpha: 0.35),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline_rounded, color: Colors.white),
                SizedBox(width: 10),
                Text(
                  'گفتگوی تازه',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
