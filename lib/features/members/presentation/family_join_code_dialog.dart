import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../family_invite_share.dart';

/// Диалог ввода 6-значного кода приглашения.
Future<String?> showFamilyJoinCodeDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => const _JoinCodeDialog(),
  );
}

class _JoinCodeDialog extends StatefulWidget {
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog> {
  final _controller = TextEditingController();
  String? _hintError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = FamilyInviteShare.normalizeJoinCode(_controller.text);
    if (code.length != 6) {
      setState(() => _hintError = 'Введите 6 цифр');
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return AlertDialog(
      title: const Text('Код приглашения'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Введите 6 цифр, которые показал вам близкий.',
            style: TextStyle(color: secondary, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: InputDecoration(
              hintText: '000000',
              errorText: _hintError,
            ),
            onChanged: (_) {
              if (_hintError != null) setState(() => _hintError = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Продолжить'),
        ),
      ],
    );
  }
}
