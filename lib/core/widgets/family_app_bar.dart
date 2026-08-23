import 'package:flutter/material.dart';

import '../../features/chat/data/chat_offline_sync.dart';
import '../../features/profile/presentation/widgets/chat_avatar.dart';

/// Заголовок AppBar с индикатором «Ожидание соединения» при офлайне.
class FamilyAppBarTitle extends StatelessWidget {
  const FamilyAppBarTitle({
    super.key,
    this.text,
    this.child,
  }) : assert(text != null || child != null);

  final String? text;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final content = child ?? Text(text!);
    return ListenableBuilder(
      listenable: ChatOfflineSync.instance,
      builder: (context, _) {
        if (ChatOfflineSync.instance.isOnline) return content;
        return _offlineTitle(context, content);
      },
    );
  }

  Widget _offlineTitle(BuildContext context, Widget content) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.appBarTheme.foregroundColor ??
                theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle(
                style: theme.textTheme.titleLarge ??
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: content,
              ),
              Text(
                'Ожидание соединения',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Аватар профиля в AppBar: крупнее, с обводкой и лёгкой тенью.
class FamilyAppBarProfileAvatar extends StatelessWidget {
  const FamilyAppBarProfileAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    required this.onTap,
    this.radius = 22,
  });

  final String name;
  final String? avatarUrl;
  final VoidCallback onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = radius * 2;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.only(left: 6, top: 4, bottom: 4, right: 2),
          child: Container(
            width: size + 3,
            height: size + 3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.85),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: ClipOval(
                child: ChatAvatar(
                  name: name,
                  avatarUrl: avatarUrl ?? '',
                  radius: radius,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Единый AppBar приложения с офлайн-индикатором в заголовке.
abstract final class FamilyAppBar {
  static PreferredSizeWidget build({
    required String title,
    List<Widget>? actions,
    PreferredSizeWidget? bottom,
    Widget? leading,
    bool automaticallyImplyLeading = true,
    Color? backgroundColor,
    Color? foregroundColor,
    IconThemeData? iconTheme,
    TextStyle? titleStyle,
    String? profileName,
    String? profileAvatarUrl,
    VoidCallback? onProfileTap,
  }) {
    final hasProfile = onProfileTap != null;
    final titleWidget = FamilyAppBarTitle(
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      ),
    );

    return AppBar(
      leading: hasProfile
          ? FamilyAppBarProfileAvatar(
              name: profileName ?? '',
              avatarUrl: profileAvatarUrl,
              onTap: onProfileTap,
            )
          : leading,
      automaticallyImplyLeading: hasProfile ? false : automaticallyImplyLeading,
      leadingWidth: hasProfile ? 54 : null,
      titleSpacing: hasProfile ? 0 : null,
      backgroundColor: backgroundColor ?? Colors.white,
      foregroundColor: foregroundColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: iconTheme,
      title: titleWidget,
      actions: actions,
      bottom: bottom,
    );
  }

  static PreferredSizeWidget buildCustom({
    required Widget title,
    List<Widget>? actions,
    PreferredSizeWidget? bottom,
    Widget? leading,
    bool automaticallyImplyLeading = true,
    Color? backgroundColor,
    Color? foregroundColor,
    IconThemeData? iconTheme,
  }) {
    return AppBar(
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      backgroundColor: backgroundColor ?? Colors.white,
      foregroundColor: foregroundColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: iconTheme,
      title: FamilyAppBarTitle(child: title),
      actions: actions,
      bottom: bottom,
    );
  }
}
