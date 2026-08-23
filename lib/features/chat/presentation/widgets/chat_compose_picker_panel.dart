import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chat_emoji_picker_sheet.dart';
import 'chat_gif_picker_panel.dart';
import '../../data/chat_gif_item.dart';

enum ChatComposePickerTab { emoji, gif, sticker }

/// Высота шторки без клавиатуры — ~38% экрана.
double chatComposePickerMaxHeight(BuildContext context) {
  final mq = MediaQuery.of(context);
  return (mq.size.height * 0.38).clamp(200.0, 360.0);
}

/// Оценка высоты строки ввода (без зазора 6 px перед шторкой).
const chatComposeBarEstimate = 96.0;

/// Запас на табы / SafeArea / дробные пиксели (типичный overflow ≈ 6.3).
const chatComposePickerLayoutSlack = 12.0;

/// Фактическая высота шторки с учётом клавиатуры и доступного слота.
double chatComposePickerHeight(
  BuildContext context, {
  BoxConstraints? constraints,
  double? panelSlotMaxHeight,
  double composeBarHeight = chatComposeBarEstimate,
  double barsOverhead = 0,
}) {
  final ideal = chatComposePickerMaxHeight(context);
  const gap = 6.0;
  final reserved =
      composeBarHeight + gap + chatComposePickerLayoutSlack + barsOverhead;

  double? cap;
  if (panelSlotMaxHeight != null && panelSlotMaxHeight.isFinite) {
    cap = panelSlotMaxHeight - reserved;
  } else if (constraints != null &&
      constraints.hasBoundedHeight &&
      constraints.maxHeight.isFinite) {
    cap = constraints.maxHeight - reserved;
  }
  if (cap == null) return ideal;
  return cap.clamp(0.0, ideal);
}

void debugComposePickerLayout({
  required String tag,
  required BuildContext context,
  required BoxConstraints constraints,
  required double pickerHeight,
  required bool showPicker,
  double? composeBarHeight,
  double? panelSlotMaxHeight,
}) {
  if (!kDebugMode) return;
  final mq = MediaQuery.of(context);
  debugPrint(
    '[ComposePicker/$tag] show=$showPicker '
    'constraints.maxH=${constraints.maxHeight.isFinite ? constraints.maxHeight.toStringAsFixed(1) : "Infinity"} '
    'slotMaxH=${panelSlotMaxHeight?.toStringAsFixed(1) ?? "?"} '
    'composeH=${composeBarHeight?.toStringAsFixed(1) ?? "?"} '
    'pickerH=${pickerHeight < 0 ? "expanded" : pickerHeight.toStringAsFixed(1)} '
    'viewInsets.bottom=${mq.viewInsets.bottom.toStringAsFixed(1)} '
    'screenH=${mq.size.height.toStringAsFixed(1)}',
  );
}

/// Шторка смайлов / GIF / стикеров в стиле Telegram.
class ChatComposePickerPanel extends StatefulWidget {
  const ChatComposePickerPanel({
    super.key,
    required this.tab,
    required this.onTabChanged,
    required this.emojiController,
    required this.onKlipySelected,
    this.onCollapse,
  });

  final ChatComposePickerTab tab;
  final ValueChanged<ChatComposePickerTab> onTabChanged;
  final TextEditingController emojiController;
  final void Function(ChatGifItem item) onKlipySelected;
  final VoidCallback? onCollapse;

  @override
  State<ChatComposePickerPanel> createState() => _ChatComposePickerPanelState();
}

class _ChatComposePickerPanelState extends State<ChatComposePickerPanel> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  VoidCallback? _forceKlipySearch;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _dismissSearchKeyboard() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
    }
  }

  @override
  void didUpdateWidget(covariant ChatComposePickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab != widget.tab) {
      _searchCtrl.clear();
      _searchFocus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surface,
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PickerSearchBar(
            tab: widget.tab,
            searchController: _searchCtrl,
            searchFocus: _searchFocus,
            onSearchSubmit: () => _forceKlipySearch?.call(),
            onCollapse: widget.onCollapse,
          ),
          Expanded(
            child: switch (widget.tab) {
              ChatComposePickerTab.emoji => ChatEmojiPickerPanel(
                  controller: widget.emojiController,
                  searchController: _searchCtrl,
                  searchFocusNode: _searchFocus,
                  onCollapse: widget.onCollapse,
                ),
              ChatComposePickerTab.gif => ChatGifPickerPanel(
                  key: const ValueKey('gif'),
                  kind: 'gif',
                  searchController: _searchCtrl,
                  onSelected: widget.onKlipySelected,
                  onUserScroll: _dismissSearchKeyboard,
                  onRegisterForceSearch: (cb) {
                    if (_forceKlipySearch != cb) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() => _forceKlipySearch = cb);
                        }
                      });
                    }
                  },
                ),
              ChatComposePickerTab.sticker => ChatGifPickerPanel(
                  key: const ValueKey('sticker'),
                  kind: 'sticker',
                  searchController: _searchCtrl,
                  onSelected: widget.onKlipySelected,
                  onUserScroll: _dismissSearchKeyboard,
                  onRegisterForceSearch: (cb) {
                    if (_forceKlipySearch != cb) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() => _forceKlipySearch = cb);
                        }
                      });
                    }
                  },
                ),
            },
          ),
          _PickerModeTabs(
            tab: widget.tab,
            onChanged: widget.onTabChanged,
          ),
        ],
      ),
    );
  }
}

class _PickerSearchBar extends StatelessWidget {
  const _PickerSearchBar({
    required this.tab,
    required this.searchController,
    required this.searchFocus,
    this.onSearchSubmit,
    this.onCollapse,
  });

  final ChatComposePickerTab tab;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final VoidCallback? onSearchSubmit;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final hint = switch (tab) {
      ChatComposePickerTab.emoji => 'Поиск эмодзи',
      ChatComposePickerTab.gif => 'Поиск GIF',
      ChatComposePickerTab.sticker => 'Поиск стикеров',
    };
    final showSubmit = tab != ChatComposePickerTab.emoji;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, keyboardOpen ? 4 : 8, 4, keyboardOpen ? 2 : 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: searchController,
              focusNode: searchFocus,
              textInputAction:
                  showSubmit ? TextInputAction.search : TextInputAction.done,
              onSubmitted: showSubmit ? (_) => onSearchSubmit?.call() : null,
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.65),
                prefixIcon: Icon(
                  Icons.search,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
                suffixIcon: showSubmit
                    ? IconButton(
                        tooltip: 'Найти',
                        onPressed: onSearchSubmit,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.arrow_forward_rounded,
                          size: 22,
                          color: cs.primary,
                        ),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Свернуть',
            onPressed: onCollapse,
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: cs.onSurface,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerModeTabs extends StatelessWidget {
  const _PickerModeTabs({
    required this.tab,
    required this.onChanged,
  });

  final ChatComposePickerTab tab;
  final ValueChanged<ChatComposePickerTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget tabLabel(String label, ChatComposePickerTab value) {
      final selected = tab == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(value),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? cs.surfaceContainerHighest.withValues(alpha: 0.95)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? cs.onSurface : cs.onSurfaceVariant,
                  ),
            ),
          ),
        ),
      );
    }

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, keyboardOpen ? 2 : 4, 16, keyboardOpen ? 0 : 8),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              tabLabel('Эмодзи', ChatComposePickerTab.emoji),
              tabLabel('GIF', ChatComposePickerTab.gif),
              tabLabel('Стикеры', ChatComposePickerTab.sticker),
            ],
          ),
        ),
      ),
    );
  }
}
