import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Системное приветствие в чате подготовки к дню рождения с отложенным поздравлением.
class ChatBirthdayWelcomeBanner extends StatelessWidget {
  const ChatBirthdayWelcomeBanner({
    super.key,
    required this.body,
    this.createdAt,
    this.scheduled,
    this.onCompose,
    this.saving = false,
  });

  final String body;
  final DateTime? createdAt;
  final Map<String, dynamic>? scheduled;
  final VoidCallback? onCompose;
  final bool saving;

  int get _pendingCount {
    final raw = scheduled?['pending_count'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  bool get _hasMine {
    final mine = scheduled?['mine'];
    return mine is Map && (mine['body']?.toString().trim().isNotEmpty ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final timeFmt = DateFormat.Hm();
    final canWrite = scheduled?['can_write'] == true && onCompose != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.92,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.tertiaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.tertiary.withValues(alpha: 0.35)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cake_rounded, color: cs.tertiary, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        'Подготовка к дню рождения',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: cs.onTertiaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onTertiaryContainer,
                      height: 1.35,
                    ),
                  ),
                  if (_pendingCount > 0) ...[
                    const SizedBox(height: 10),
                    Text(
                      _pendingCount == 1
                          ? '1 поздравление готово'
                          : '$_pendingCount поздравления готовы',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: cs.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (canWrite) ...[
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: saving ? null : onCompose,
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_hasMine ? Icons.edit_outlined : Icons.card_giftcard_outlined),
                      label: Text(
                        _hasMine
                            ? 'Изменить поздравление'
                            : 'Написать поздравление',
                      ),
                    ),
                    if (_hasMine) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Отправится автоматически, когда именинник подключится',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onTertiaryContainer.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ],
                  if (createdAt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      timeFmt.format(createdAt!.toLocal()),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onTertiaryContainer.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showBirthdayScheduledCongratulationDialog({
  required BuildContext context,
  required String initialText,
  required Future<void> Function(String body) onSave,
  Future<void> Function()? onDelete,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _BirthdayScheduledCongratulationDialog(
      initialText: initialText,
      onSave: onSave,
      onDelete: onDelete,
    ),
  );
}

class _BirthdayScheduledCongratulationDialog extends StatefulWidget {
  const _BirthdayScheduledCongratulationDialog({
    required this.initialText,
    required this.onSave,
    this.onDelete,
  });

  final String initialText;
  final Future<void> Function(String body) onSave;
  final Future<void> Function()? onDelete;

  @override
  State<_BirthdayScheduledCongratulationDialog> createState() =>
      _BirthdayScheduledCongratulationDialogState();
}

class _BirthdayScheduledCongratulationDialogState
    extends State<_BirthdayScheduledCongratulationDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  static final _compactTextButton = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  static final _compactFilledButton = FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool delete}) async {
    if (_saving) return;
    if (delete) {
      final onDelete = widget.onDelete;
      if (onDelete == null) return;
      setState(() => _saving = true);
      try {
        await onDelete();
        if (!mounted) return;
        Navigator.of(context).pop();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить: $e')),
        );
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Поздравление имениннику'),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: 2000,
          decoration: const InputDecoration(
            hintText: 'Напишите тёплые слова…',
            alignLabelWithHint: true,
          ),
          validator: (value) {
            if ((value ?? '').trim().isEmpty) {
              return 'Введите текст поздравления';
            }
            return null;
          },
        ),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onDelete != null &&
                    widget.initialText.trim().isNotEmpty)
                  TextButton(
                    style: _compactTextButton,
                    onPressed: _saving ? null : () => _submit(delete: true),
                    child: const Text('Удалить'),
                  ),
                TextButton(
                  style: _compactTextButton,
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  style: _compactFilledButton,
                  onPressed: _saving ? null : () => _submit(delete: false),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
