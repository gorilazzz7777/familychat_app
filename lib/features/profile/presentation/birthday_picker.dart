import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'birthday_format.dart';

/// Автоматически вставляет точки при вводе: 09061986 → 09.06.1986
class DdMmYyyyTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;

    final buf = StringBuffer();
    for (var i = 0; i < limited.length; i++) {
      if (i == 2 || i == 4) buf.write('.');
      buf.write(limited[i]);
    }
    final formatted = buf.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Диалог ввода даты рождения с авторазделителями и опциональным календарём.
Future<DateTime?> showBirthDatePicker(
  BuildContext context, {
  DateTime? initial,
}) async {
  final now = DateTime.now();
  final initialDate = initial ?? DateTime(now.year - 25, now.month, now.day);
  final controller = TextEditingController(
    text: formatBirthDateDisplay(initialDate, showYear: true),
  );
  String? errorText;

  try {
    return await showDialog<DateTime>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            void submit() {
              final parsed = parseDdMmYyyy(controller.text);
              if (parsed == null) {
                setDialogState(() => errorText = 'Некорректная дата');
                return;
              }
              if (parsed.isAfter(now)) {
                setDialogState(() => errorText = 'Дата не может быть в будущем');
                return;
              }
              if (parsed.isBefore(DateTime(1900))) {
                setDialogState(() => errorText = 'Укажите год не ранее 1900');
                return;
              }
              Navigator.pop(ctx, parsed);
            }

            return AlertDialog(
              title: const Text('День рождения'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [DdMmYyyyTextInputFormatter()],
                    decoration: InputDecoration(
                      labelText: 'ДД.ММ.ГГГГ',
                      hintText: '09.06.1986',
                      errorText: errorText,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (errorText != null) {
                        setDialogState(() => errorText = null);
                      }
                    },
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final cal = await showDatePicker(
                          context: ctx,
                          initialDate: parseDdMmYyyy(controller.text) ?? initialDate,
                          firstDate: DateTime(1900),
                          lastDate: now,
                          initialEntryMode: DatePickerEntryMode.calendarOnly,
                          locale: const Locale('ru'),
                        );
                        if (cal != null && ctx.mounted) {
                          Navigator.pop(ctx, cal);
                        }
                      },
                      icon: const Icon(Icons.calendar_month_outlined),
                      label: const Text('Выбрать в календаре'),
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
                  onPressed: submit,
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    controller.dispose();
  }
}
