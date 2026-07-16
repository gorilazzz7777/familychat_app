import 'package:flutter/material.dart';

import '../../../data/chat_location_utils.dart';
import 'attach_file_tab.dart';
import 'attach_gallery_tab.dart';
import 'attach_location_tab.dart';
import 'attach_selection_bar.dart';
import 'chat_attach_models.dart';

class ChatAttachSheet extends StatefulWidget {
  const ChatAttachSheet({
    super.key,
    required this.onSendMedia,
    required this.onSendLocation,
  });

  final Future<void> Function(
    String caption,
    List<ChatAttachSelectionItem> items,
  ) onSendMedia;
  final Future<void> Function(ChatLocationPoint point) onSendLocation;

  static Future<void> show(
    BuildContext context, {
    required Future<void> Function(
      String caption,
      List<ChatAttachSelectionItem> items,
    ) onSendMedia,
    required Future<void> Function(ChatLocationPoint point) onSendLocation,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatAttachSheet(
        onSendMedia: onSendMedia,
        onSendLocation: onSendLocation,
      ),
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
    if (mounted) Navigator.of(context).pop();
    try {
      await widget.onSendMedia(caption, items);
    } catch (_) {
      // caller shows errors
    }
  }

  Future<void> _sendLocation(ChatLocationPoint point) async {
    if (mounted) Navigator.of(context).pop();
    await widget.onSendLocation(point);
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
        initialChildSize: 0.48,
        minChildSize: 0.34,
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
                    ChatAttachMode.location => AttachLocationTab(
                        onSend: _sendLocation,
                        scrollController: scrollController,
                      ),
                  },
                ),
                if (_mode != ChatAttachMode.location)
                  AttachSelectionBar(
                    items: _selected,
                    controller: _captionCtrl,
                    sending: _sending,
                    onSend: _sendSelected,
                    onRemove: _removeSelected,
                  ),
                _ModeBar(
                  mode: _mode,
                  onChanged: (m) => setState(() => _mode = m),
                ),
              ],
            ),
          );
        },
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            _ModeChip(
              label: 'Галерея',
              icon: Icons.photo_outlined,
              selected: mode == ChatAttachMode.gallery,
              onTap: () => onChanged(ChatAttachMode.gallery),
              scheme: scheme,
            ),
            _ModeChip(
              label: 'Файл',
              icon: Icons.insert_drive_file_outlined,
              selected: mode == ChatAttachMode.file,
              onTap: () => onChanged(ChatAttachMode.file),
              scheme: scheme,
            ),
            _ModeChip(
              label: 'Геопозиция',
              icon: Icons.location_on_outlined,
              selected: mode == ChatAttachMode.location,
              onTap: () => onChanged(ChatAttachMode.location),
              scheme: scheme,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
