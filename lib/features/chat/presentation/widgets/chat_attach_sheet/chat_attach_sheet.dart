import 'package:flutter/material.dart';

import '../../../data/chat_location_utils.dart';
import 'attach_file_tab.dart';
import 'attach_gallery_tab.dart';
import 'attach_location_tab.dart';
import 'attach_selection_bar.dart';
import 'chat_attach_models.dart';

/// Режим шторки: полный чат или только галерея/камера телефона.
enum ChatAttachSheetStyle {
  /// Галерея · Файл · Гео + подпись (чат).
  chat,

  /// Только галерея с live-камерой (альбом / лента).
  phoneMedia,
}

class ChatAttachSheet extends StatefulWidget {
  const ChatAttachSheet({
    super.key,
    required this.onSendMedia,
    this.onSendLocation,
    this.style = ChatAttachSheetStyle.chat,
  });

  final Future<void> Function(
    String caption,
    List<ChatAttachSelectionItem> items,
  ) onSendMedia;
  final Future<void> Function(ChatLocationPoint point)? onSendLocation;
  final ChatAttachSheetStyle style;

  static Future<void> show(
    BuildContext context, {
    required Future<void> Function(
      String caption,
      List<ChatAttachSelectionItem> items,
    ) onSendMedia,
    Future<void> Function(ChatLocationPoint point)? onSendLocation,
    ChatAttachSheetStyle style = ChatAttachSheetStyle.chat,
  }) {
    assert(
      style != ChatAttachSheetStyle.chat || onSendLocation != null,
      'ChatAttachSheetStyle.chat requires onSendLocation',
    );
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatAttachSheet(
        onSendMedia: onSendMedia,
        onSendLocation: onSendLocation,
        style: style,
      ),
    );
  }

  @override
  State<ChatAttachSheet> createState() => _ChatAttachSheetState();
}

class _ChatAttachSheetState extends State<ChatAttachSheet> {
  late ChatAttachMode _mode;
  final List<ChatAttachSelectionItem> _selected = [];
  final _captionCtrl = TextEditingController();
  final _sheetCtrl = DraggableScrollableController();
  bool _sending = false;
  bool _expanded = false;

  bool get _mediaOnly => widget.style == ChatAttachSheetStyle.phoneMedia;

  @override
  void initState() {
    super.initState();
    _mode = ChatAttachMode.gallery;
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
    final caption = _mediaOnly ? '' : _captionCtrl.text.trim();
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
    await widget.onSendLocation?.call(point);
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
        initialChildSize: _mediaOnly ? 0.55 : 0.48,
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
                if (_mediaOnly)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'С телефона',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  )
                else
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
                    showCaption: !_mediaOnly,
                    sendIcon: _mediaOnly ? Icons.check_rounded : Icons.send_rounded,
                    onSend: _sendSelected,
                    onRemove: _removeSelected,
                  ),
                if (!_mediaOnly)
                  _ModeBar(
                    mode: _mode,
                    onChanged: (m) => setState(() => _mode = m),
                  ),
                if (_mediaOnly) const SizedBox(height: 4),
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
