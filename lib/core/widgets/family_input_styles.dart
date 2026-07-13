import 'package:flutter/material.dart';

/// Единый скруглённый стиль полей ввода (как в чате).
class FamilyInputStyles {
  FamilyInputStyles._();

  static const double radius = 24;

  static InputDecorationTheme decorationTheme(ColorScheme cs) {
    final enabledBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: cs.primary, width: 1.5),
    );
    return InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: enabledBorder,
      enabledBorder: enabledBorder,
      focusedBorder: focusedBorder,
      errorBorder: enabledBorder,
      focusedErrorBorder: focusedBorder,
      isDense: true,
    );
  }

  static BoxDecoration composeShellDecoration(
    ThemeData theme, {
    Color? fillColor,
    Color? borderColor,
  }) {
    final cs = theme.colorScheme;
    return BoxDecoration(
      color: fillColor ?? cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: borderColor ?? cs.outlineVariant.withValues(alpha: 0.55),
      ),
    );
  }
}
