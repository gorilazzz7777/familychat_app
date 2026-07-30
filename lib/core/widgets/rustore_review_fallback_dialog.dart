import 'package:flutter/material.dart';

const Color _starActive = Color(0xFFFFB300);
const Color _starInactive = Color(0xFF9E9E9E);

/// Запасной запрос оценки: выбор 1–5 звёзд, затем «Отправить» или «Позже».
Future<void> showRustoreReviewFallbackDialog(
  BuildContext context, {
  required Future<void> Function(int stars) onSubmit,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _RustoreReviewFallbackDialog(onSubmit: onSubmit),
  );
}

class _RustoreReviewFallbackDialog extends StatefulWidget {
  const _RustoreReviewFallbackDialog({required this.onSubmit});

  final Future<void> Function(int stars) onSubmit;

  @override
  State<_RustoreReviewFallbackDialog> createState() =>
      _RustoreReviewFallbackDialogState();
}

class _RustoreReviewFallbackDialogState
    extends State<_RustoreReviewFallbackDialog> {
  int _selectedStars = 0;
  bool _submitting = false;

  Future<void> _submit() async {
    if (_selectedStars < 1 || _submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_selectedStars);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить оценку: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Оцените приложение'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Вам нравится Family Chat? '
            'Выберите оценку — после отправки откроется RuStore.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          Row(
            children: List.generate(5, (index) {
              final filled = index < _selectedStars;
              return Expanded(
                child: IconButton(
                  tooltip: 'Оценка ${index + 1}',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _selectedStars = index + 1),
                  icon: Icon(
                    filled ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 32,
                    color: filled ? _starActive : _starInactive,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Позже'),
        ),
        FilledButton(
          onPressed: _selectedStars > 0 && !_submitting ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Отправить'),
        ),
      ],
    );
  }
}