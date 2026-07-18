import 'package:flutter/material.dart';

import '../../../data/chat_location_utils.dart';
import 'attach_family_gallery_tab.dart';
import 'attach_file_tab.dart';
import 'attach_gallery_tab.dart';
import 'attach_location_tab.dart';
import 'attach_selection_bar.dart';
import 'chat_attach_models.dart';

/// Режим шторки: полный чат, только телефон, или альбом (телефон + галерея семьи).
enum ChatAttachSheetStyle {
  /// Галерея · Файл · Гео + подпись (чат).
  chat,

  /// Только галерея с live-камерой (лента).
  phoneMedia,

  /// С телефона · Из галереи (пользовательский альбом).
  albumMedia,
}

class ChatAttachSheet extends StatefulWidget {
  const ChatAttachSheet({
    super.key,
    required this.onSendMedia,
    this.onSendLocation,
    this.onAddFromFamilyGallery,
    this.familyGalleryUserId,
    this.excludeFamilyAttachmentIds = const {},
    this.style = ChatAttachSheetStyle.chat,
  });

  final Future<void> Function(
    String caption,
    List<ChatAttachSelectionItem> items,
  ) onSendMedia;
  final Future<void> Function(ChatLocationPoint point)? onSendLocation;
  final Future<void> Function(List<int> attachmentIds)? onAddFromFamilyGallery;
  final int? familyGalleryUserId;
  final Set<int> excludeFamilyAttachmentIds;
  final ChatAttachSheetStyle style;

  static Future<void> show(
    BuildContext context, {
    required Future<void> Function(
      String caption,
      List<ChatAttachSelectionItem> items,
    ) onSendMedia,
    Future<void> Function(ChatLocationPoint point)? onSendLocation,
    Future<void> Function(List<int> attachmentIds)? onAddFromFamilyGallery,
    int? familyGalleryUserId,
    Set<int> excludeFamilyAttachmentIds = const {},
    ChatAttachSheetStyle style = ChatAttachSheetStyle.chat,
  }) {
    assert(
      style != ChatAttachSheetStyle.chat || onSendLocation != null,
      'ChatAttachSheetStyle.chat requires onSendLocation',
    );
    assert(
      style != ChatAttachSheetStyle.albumMedia ||
          (onAddFromFamilyGallery != null && familyGalleryUserId != null),
      'ChatAttachSheetStyle.albumMedia requires family gallery callbacks',
    );
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChatAttachSheet(
        onSendMedia: onSendMedia,
        onSendLocation: onSendLocation,
        onAddFromFamilyGallery: onAddFromFamilyGallery,
        familyGalleryUserId: familyGalleryUserId,
        excludeFamilyAttachmentIds: excludeFamilyAttachmentIds,
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
  final Set<int> _familySelected = {};
  final _captionCtrl = TextEditingController();
  final _sheetCtrl = DraggableScrollableController();
  bool _sending = false;
  bool _expanded = false;

  bool get _phoneOnly => widget.style == ChatAttachSheetStyle.phoneMedia;
  bool get _albumMode => widget.style == ChatAttachSheetStyle.albumMedia;
  bool get _hideCaption =>
      widget.style == ChatAttachSheetStyle.phoneMedia ||
      widget.style == ChatAttachSheetStyle.albumMedia;

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

  void _setMode(ChatAttachMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _selected.clear();
      _familySelected.clear();
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

  void _setFamilySelected(Set<int> ids) {
    setState(() {
      _familySelected
        ..clear()
        ..addAll(ids);
    });
  }

  Future<void> _sendSelected() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    final caption = _hideCaption ? '' : _captionCtrl.text.trim();
    final items = List<ChatAttachSelectionItem>.from(_selected);
    final send = widget.onSendMedia;
    if (mounted) Navigator.of(context).pop();
    // После pop виджет шторки disposed — отправку запускаем на следующем кадре.
    await Future<void>.delayed(Duration.zero);
    try {
      await send(caption, items);
    } catch (e, st) {
      debugPrint('ChatAttachSheet send failed: $e\n$st');
    }
  }

  Future<void> _sendFamilySelected() async {
    if (_familySelected.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ids = _familySelected.toList();
    if (mounted) Navigator.of(context).pop();
    try {
      await widget.onAddFromFamilyGallery?.call(ids);
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
        // ~2/3 экрана при открытии (можно потянуть выше/ниже).
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
                if (_phoneOnly)
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
                    ChatAttachMode.familyGallery => AttachFamilyGalleryTab(
                        userId: widget.familyGalleryUserId!,
                        selected: _familySelected,
                        onSelectedChanged: _setFamilySelected,
                        scrollController: scrollController,
                        excludeAttachmentIds: widget.excludeFamilyAttachmentIds,
                      ),
                  },
                ),
                if (_mode == ChatAttachMode.familyGallery)
                  _FamilySelectionBar(
                    count: _familySelected.length,
                    sending: _sending,
                    onSend: _sendFamilySelected,
                  )
                else if (_mode != ChatAttachMode.location)
                  AttachSelectionBar(
                    items: _selected,
                    controller: _captionCtrl,
                    sending: _sending,
                    showCaption: !_hideCaption,
                    sendIcon: _hideCaption
                        ? Icons.check_rounded
                        : Icons.send_rounded,
                    onSend: _sendSelected,
                    onRemove: _removeSelected,
                  ),
                if (!_phoneOnly)
                  _ModeBar(
                    style: widget.style,
                    mode: _mode,
                    onChanged: _setMode,
                  ),
                if (_phoneOnly) const SizedBox(height: 4),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FamilySelectionBar extends StatelessWidget {
  const _FamilySelectionBar({
    required this.count,
    required this.sending,
    required this.onSend,
  });

  final int count;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Выбрано: $count',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              FilledButton.icon(
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('Добавить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.style,
    required this.mode,
    required this.onChanged,
  });

  final ChatAttachSheetStyle style;
  final ChatAttachMode mode;
  final ValueChanged<ChatAttachMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chips = switch (style) {
      ChatAttachSheetStyle.albumMedia => const [
          (ChatAttachMode.gallery, 'С телефона', Icons.phone_android_outlined),
          (
            ChatAttachMode.familyGallery,
            'Из галереи',
            Icons.collections_outlined
          ),
        ],
      _ => const [
          (ChatAttachMode.gallery, 'Галерея', Icons.photo_outlined),
          (ChatAttachMode.file, 'Файл', Icons.insert_drive_file_outlined),
          (ChatAttachMode.location, 'Геопозиция', Icons.location_on_outlined),
        ],
    };

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            for (final chip in chips)
              _ModeChip(
                label: chip.$2,
                icon: chip.$3,
                selected: mode == chip.$1,
                onTap: () => onChanged(chip.$1),
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
