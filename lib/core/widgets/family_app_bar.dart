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
    String? profileName,
    String? profileAvatarUrl,
    VoidCallback? onProfileTap,
  }) {
    final titleWidget = onProfileTap != null
        ? FamilyAppBarTitle(
            child: Row(
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onProfileTap,
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: ChatAvatar(
                        name: profileName ?? '',
                        avatarUrl: profileAvatarUrl,
                        radius: 18,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        : FamilyAppBarTitle(text: title);

    return AppBar(
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
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
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      iconTheme: iconTheme,
      title: FamilyAppBarTitle(child: title),
      actions: actions,
      bottom: bottom,
    );
  }
}
