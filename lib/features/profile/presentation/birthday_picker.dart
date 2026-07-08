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
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => _BirthDatePickerDialog(initial: initial),
  );
}

class _BirthDatePickerDialog extends StatefulWidget {
  const _BirthDatePickerDialog({this.initial});

  final DateTime? initial;

  @override
  State<_BirthDatePickerDialog> createState() => _BirthDatePickerDialogState();
}

class _BirthDatePickerDialogState extends State<_BirthDatePickerDialog> {
  late final TextEditingController _controller;
  late final DateTime _initialDate;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _initialDate = widget.initial ?? DateTime(now.year - 25, now.month, now.day);
    _controller = TextEditingController(
      text: formatBirthDateDisplay(_initialDate, showYear: true),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final now = DateTime.now();
    final parsed = parseDdMmYyyy(_controller.text);
    if (parsed == null) {
      setState(() => _errorText = 'Некорректная дата');
      return;
    }
    if (parsed.isAfter(now)) {
      setState(() => _errorText = 'Дата не может быть в будущем');
      return;
    }
    if (parsed.isBefore(DateTime(1900))) {
      setState(() => _errorText = 'Укажите год не ранее 1900');
      return;
    }
    Navigator.pop(context, parsed);
  }

  Future<void> _pickFromCalendar() async {
    final now = DateTime.now();
    final cal = await showDatePicker(
      context: context,
      initialDate: parseDdMmYyyy(_controller.text) ?? _initialDate,
      firstDate: DateTime(1900),
      lastDate: now,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      locale: const Locale('ru'),
    );
    if (!mounted || cal == null) return;
    Navigator.pop(context, cal);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('День рождения'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [DdMmYyyyTextInputFormatter()],
            decoration: InputDecoration(
              labelText: 'ДД.ММ.ГГГГ',
              hintText: '09.06.1986',
              errorText: _errorText,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_errorText != null) {
                setState(() => _errorText = null);
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _pickFromCalendar,
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Выбрать в календаре'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('OK'),
        ),
      ],
    );
  }
}
