import 'package:flutter/material.dart';

/// Шильдики подписок из `entitlements` в status / member profile.
class PremiumBadges extends StatelessWidget {
  const PremiumBadges({
    super.key,
    required this.entitlements,
    this.alignment = WrapAlignment.center,
  });

  final Map<String, dynamic>? entitlements;
  final WrapAlignment alignment;

  static List<String> labelsFrom(Map<String, dynamic>? entitlements) {
    if (entitlements == null) return const [];
    final labels = <String>[];
    if (entitlements['individual_premium'] == true) {
      labels.add('Premium');
    }
    if (entitlements['family_premium'] == true) {
      labels.add('Family Premium');
    }
    return labels;
  }

  @override
  Widget build(BuildContext context) {
    final labels = labelsFrom(entitlements);
    if (labels.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Wrap(
      alignment: alignment,
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final label in labels)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: cs.primary.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
      ],
    );
  }
}
