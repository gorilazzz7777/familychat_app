import 'package:flutter/material.dart';

class GoogleRegistrationWarning extends StatelessWidget {
  const GoogleRegistrationWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFB300), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFE65100),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Регистрация через Google недоступна',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF5D4037),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Согласно российскому законодательству, регистрация новых '
            'пользователей через иностранные сервисы (Google, Apple ID) '
            'ограничена. Пожалуйста, выберите другой способ входа.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF6D4C41),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
