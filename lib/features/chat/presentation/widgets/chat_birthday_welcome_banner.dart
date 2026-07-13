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
}) async {
  final controller = TextEditingController(text: initialText);
  final formKey = GlobalKey<FormState>();
  var saving = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocalState) {
        Future<void> submit({required bool delete}) async {
          if (saving) return;
          if (delete) {
            if (onDelete == null) return;
            setLocalState(() => saving = true);
            try {
              await onDelete();
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Не удалось удалить: $e')),
                );
              }
            } finally {
              if (ctx.mounted) setLocalState(() => saving = false);
            }
            return;
          }
          if (!(formKey.currentState?.validate() ?? false)) return;
          setLocalState(() => saving = true);
          try {
            await onSave(controller.text.trim());
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) {
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('Не удалось сохранить: $e')),
              );
            }
          } finally {
            if (ctx.mounted) setLocalState(() => saving = false);
          }
        }

        return AlertDialog(
          title: const Text('Поздравление имениннику'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
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
            if (onDelete != null && initialText.trim().isNotEmpty)
              TextButton(
                onPressed: saving ? null : () => submit(delete: true),
                child: const Text('Удалить'),
              ),
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: saving ? null : () => submit(delete: false),
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Сохранить'),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
}
