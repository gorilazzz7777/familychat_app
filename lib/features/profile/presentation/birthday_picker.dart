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

class BirthDatePickerResult {
  const BirthDatePickerResult({
    required this.date,
    required this.showYear,
  });

  final DateTime date;
  final bool showYear;
}

/// Диалог ввода даты рождения с авторазделителями и опциональным календарём.
Future<BirthDatePickerResult?> showBirthDatePicker(
  BuildContext context, {
  DateTime? initial,
  bool? initialShowYear,
}) {
  return showDialog<BirthDatePickerResult>(
    context: context,
    builder: (ctx) => _BirthDatePickerDialog(
      initial: initial,
      initialShowYear: initialShowYear,
    ),
  );
}

class _BirthDatePickerDialog extends StatefulWidget {
  const _BirthDatePickerDialog({
    this.initial,
    this.initialShowYear,
  });

  final DateTime? initial;
  final bool? initialShowYear;

  @override
  State<_BirthDatePickerDialog> createState() => _BirthDatePickerDialogState();
}

class _BirthDatePickerDialogState extends State<_BirthDatePickerDialog> {
  late final TextEditingController _controller;
  late final DateTime _initialDate;
  late bool _showYear;
  String? _errorText;

  bool get _showYearToggle => widget.initialShowYear != null;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _initialDate = widget.initial ?? DateTime(now.year - 25, now.month, now.day);
    _showYear = widget.initialShowYear ?? true;
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
    Navigator.pop(
      context,
      BirthDatePickerResult(date: parsed, showYear: _showYear),
    );
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
    Navigator.pop(
      context,
      BirthDatePickerResult(date: cal, showYear: _showYear),
    );
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
          if (_showYearToggle) ...[
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _showYear,
              onChanged: (v) => setState(() => _showYear = v ?? true),
              title: const Text('Показывать год'),
              subtitle: const Text(
                'Если выключено, другим участникам виден только день и месяц',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
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
