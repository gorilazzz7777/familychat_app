import 'package:flutter/material.dart';

import 'chat_attach_models.dart';

/// Общая высота нижней панели шторки (режимы ↔ отправка), без safe-area.
/// Держим одинаковой, чтобы сетка галереи не прыгала.
const double kChatAttachBottomChromeHeight = 120;

class AttachSelectionBar extends StatelessWidget {
  const AttachSelectionBar({
    super.key,
    required this.items,
    required this.controller,
    required this.onSend,
    required this.onRemove,
    this.sending = false,
    this.showCaption = true,
    this.sendIcon = Icons.send_rounded,
  });

  final List<ChatAttachSelectionItem> items;
  final TextEditingController controller;
  final VoidCallback onSend;
  final void Function(String id) onRemove;
  final bool sending;
  final bool showCaption;
  final IconData sendIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final item = items[i];
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: item.kind == 'file'
                              ? ColoredBox(
                                  color: scheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.insert_drive_file_outlined,
                                    color: scheme.primary,
                                  ),
                                )
                              : Image.memory(
                                  item.previewBytes,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => ColoredBox(
                                    color: scheme.surfaceContainerHighest,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: InkWell(
                          onTap: () => onRemove(item.id),
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: scheme.error,
                            child: Icon(
                              Icons.close,
                              size: 12,
                              color: scheme.onError,
                            ),
                          ),
                        ),
                      ),
                      if (item.kind == 'video')
                        const Positioned.fill(
                          child: Center(
                            child: Icon(
                              Icons.play_circle_fill,
                              color: Colors.white70,
                              size: 22,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: showCaption
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            minLines: 1,
                            maxLines: 2,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: 'Подпись…',
                              filled: true,
                              fillColor: scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.55),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(22),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                            ),
                            onSubmitted: (_) {
                              if (!sending) onSend();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Center(
                          child: IconButton.filled(
                            onPressed: sending ? null : onSend,
                            icon: sending
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(sendIcon),
                          ),
                        ),
                      ],
                    )
                  : Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: sending ? null : onSend,
                        icon: sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(sendIcon),
                        label: Text(sending ? 'Добавляем…' : 'Добавить'),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
