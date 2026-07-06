import 'package:flutter/material.dart';

/// Диалог выбора степени родства для приглашения.
Future<String?> showInviteKinshipDialog(
  BuildContext context, {
  required List<Map<String, dynamic>> options,
}) {
  String? selected = options.isNotEmpty ? options.first['code'] as String? : null;

  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Пригласить в семью'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Кого вы приглашаете? Укажите степень родства.'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: selected,
              decoration: const InputDecoration(
                labelText: 'Родство',
                border: OutlineInputBorder(),
              ),
              items: options
                  .map(
                    (o) => DropdownMenuItem(
                      value: o['code'] as String,
                      child: Text(o['label'] as String? ?? o['code'] as String),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => selected = v),
            ),
            const SizedBox(height: 8),
            Text(
              'Ссылка действует 24 часа и может быть использована один раз.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: selected == null ? null : () => Navigator.pop(ctx, selected),
            child: const Text('Создать ссылку'),
          ),
        ],
      ),
    ),
  );
}
