import 'package:flutter/material.dart';

class SocialLoginPanel extends StatelessWidget {
  const SocialLoginPanel({
    super.key,
    required this.loading,
    required this.onGoogle,
    required this.onVk,
    required this.onYandex,
  });

  final bool loading;
  final VoidCallback onGoogle;
  final VoidCallback onVk;
  final VoidCallback onYandex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.75),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _SocialLoginIcon(
            assetPath: 'assets/logo/vk.png',
            semanticLabel: 'Вход через ВК',
            onTap: loading ? null : onVk,
          ),
          _SocialLoginIcon(
            assetPath: 'assets/logo/ya.png',
            semanticLabel: 'Вход через Яндекс',
            onTap: loading ? null : onYandex,
          ),
          _SocialLoginIcon(
            assetPath: 'assets/logo/google.png',
            semanticLabel: 'Вход через Google',
            onTap: loading ? null : onGoogle,
          ),
        ],
      ),
    );
  }
}

class _SocialLoginIcon extends StatelessWidget {
  const _SocialLoginIcon({
    required this.assetPath,
    required this.semanticLabel,
    required this.onTap,
  });

  final String assetPath;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 68,
          height: 68,
          child: Center(
            child: Image.asset(
              assetPath,
              width: 52,
              height: 52,
              fit: BoxFit.contain,
              semanticLabel: semanticLabel,
            ),
          ),
        ),
      ),
    );
  }
}
