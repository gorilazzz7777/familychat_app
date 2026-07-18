import 'package:flutter/material.dart';

import 'attach_file_tab.dart';
import 'attach_gallery_tab.dart';
import 'attach_selection_bar.dart';
import 'chat_attach_models.dart';

/// Gallery + File attach sheet (Family Chat look, without location/albums).
class ChatAttachSheet extends StatefulWidget {
  const ChatAttachSheet({
    super.key,
    required this.onSendMedia,
  });

  final Future<void> Function(
    String caption,
    List<ChatAttachSelectionItem> items,
  ) onSendMedia;

  static Future<void> show(
    BuildContext context, {
    required Future<void> Function(
      String caption,
      List<ChatAttachSelectionItem> items,
    ) onSendMedia,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatAttachSheet(onSendMedia: onSendMedia),
    );
  }

  @override
  State<ChatAttachSheet> createState() => _ChatAttachSheetState();
}

class _ChatAttachSheetState extends State<ChatAttachSheet> {
  ChatAttachMode _mode = ChatAttachMode.gallery;
  final List<ChatAttachSelectionItem> _selected = [];
  final _captionCtrl = TextEditingController();
  final _sheetCtrl = DraggableScrollableController();
  bool _sending = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _sheetCtrl.addListener(_onSheetSize);
  }

  void _onSheetSize() {
    if (!_sheetCtrl.isAttached) return;
    final expanded = _sheetCtrl.size > 0.72;
    if (expanded != _expanded && mounted) {
      setState(() => _expanded = expanded);
    }
  }

  @override
  void dispose() {
    _sheetCtrl.removeListener(_onSheetSize);
    _sheetCtrl.dispose();
    _captionCtrl.dispose();
    super.dispose();
  }

  void _setMode(ChatAttachMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _selected.clear();
    });
  }

  void _setSelected(List<ChatAttachSelectionItem> items) {
    setState(() {
      _selected
        ..clear()
        ..addAll(items);
    });
  }

  void _removeSelected(String id) {
    setState(() => _selected.removeWhere((e) => e.id == id));
  }

  Future<void> _sendSelected() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    final caption = _captionCtrl.text.trim();
    final items = List<ChatAttachSelectionItem>.from(_selected);
    final send = widget.onSendMedia;
    if (mounted) Navigator.of(context).pop();
    await Future<void>.delayed(Duration.zero);
    try {
      await send(caption, items);
    } catch (e, st) {
      debugPrint('ChatAttachSheet send failed: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        controller: _sheetCtrl,
        expand: false,
        initialChildSize: 0.67,
        minChildSize: 0.40,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return Material(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: switch (_mode) {
                    ChatAttachMode.gallery => AttachGalleryTab(
                        selected: _selected,
                        onSelectedChanged: _setSelected,
                        scrollController: scrollController,
                        expanded: _expanded,
                      ),
                    ChatAttachMode.file => AttachFileTab(
                        selected: _selected,
                        onSelectedChanged: _setSelected,
                        scrollController: scrollController,
                      ),
                    _ => const SizedBox.shrink(),
                  },
                ),
                _buildBottomChrome(scheme),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomChrome(ColorScheme scheme) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: kChatAttachBottomChromeHeight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _selected.isNotEmpty
                ? KeyedSubtree(
                    key: const ValueKey('attach-send'),
                    child: AttachSelectionBar(
                      items: _selected,
                      controller: _captionCtrl,
                      sending: _sending,
                      onSend: _sendSelected,
                      onRemove: _removeSelected,
                    ),
                  )
                : KeyedSubtree(
                    key: const ValueKey('attach-modes'),
                    child: _ModeBar(
                      mode: _mode,
                      onChanged: _setMode,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.mode,
    required this.onChanged,
  });

  final ChatAttachMode mode;
  final ValueChanged<ChatAttachMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const chips = [
      (ChatAttachMode.gallery, 'Галерея', Icons.photo_outlined),
      (ChatAttachMode.file, 'Файл', Icons.insert_drive_file_outlined),
    ];

    return SizedBox.expand(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final chip in chips)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Material(
                    color: mode == chip.$1
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => onChanged(chip.$1),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              chip.$3,
                              color: mode == chip.$1
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              chip.$2,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: mode == chip.$1
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
