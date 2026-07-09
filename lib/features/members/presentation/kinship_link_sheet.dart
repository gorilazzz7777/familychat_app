import 'package:flutter/material.dart';

const _noKinshipCode = '__none__';

/// Редактор связи: кто этот человек для текущего пользователя.
Future<String?> showKinshipLinkSheet(
  BuildContext context, {
  required String personName,
  required List<Map<String, dynamic>> options,
  String? currentCode,
}) {
  final hasCurrent = currentCode != null && currentCode.isNotEmpty;
  var selected = hasCurrent ? currentCode : _noKinshipCode;
  final items = <DropdownMenuItem<String>>[
    const DropdownMenuItem(
      value: _noKinshipCode,
      child: Text('Без родства'),
    ),
    ...options.map(
      (o) => DropdownMenuItem(
        value: o['code']?.toString() ?? '',
        child: Text(
          o['label']?.toString() ?? o['code']?.toString() ?? '',
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
  ];

  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Кто $personName для вас?',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Изменение вступит в силу после сохранения на вкладке «Дерево».',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: selected,
                  decoration: const InputDecoration(
                    labelText: 'Родство',
                    border: OutlineInputBorder(),
                  ),
                  items: items,
                  onChanged: (v) => setState(() => selected = v ?? _noKinshipCode),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          if (selected == _noKinshipCode) {
                            Navigator.pop(ctx, '');
                          } else {
                            Navigator.pop(ctx, selected);
                          }
                        },
                        child: const Text('Применить'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
