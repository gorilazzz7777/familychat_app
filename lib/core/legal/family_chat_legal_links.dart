import 'package:flutter/material.dart';

import 'legal_page_launcher.dart';

class FamilyChatLegalLinks extends StatelessWidget {
  const FamilyChatLegalLinks({
    super.key,
    this.enabled = true,
    this.alignment = WrapAlignment.center,
    this.color = const Color(0xFF4A9FD4),
  });

  final bool enabled;
  final WrapAlignment alignment;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: color,
      decoration: TextDecoration.underline,
      decorationColor: color,
    );
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed:
              enabled ? () => openFamilyChatPrivacyPolicy(context) : null,
          child: Text('Политика конфиденциальности', style: style),
        ),
        Text(
          '·',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed:
              enabled ? () => openFamilyChatUserAgreement(context) : null,
          child: Text('Пользовательское соглашение', style: style),
        ),
      ],
    );
  }
}
