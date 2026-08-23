import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chat_compose_circle_button.dart';

/// Круглая кнопка смайлов / клавиатуры слева от отправки.
class ChatComposeEmojiButton extends StatelessWidget {
  const ChatComposeEmojiButton({
    super.key,
    required this.open,
    required this.onPressed,
  });

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ChatComposeCircleButton(
      tooltip: open ? 'Клавиатура' : 'Смайлы',
      icon: open ? Icons.keyboard_alt_outlined : Icons.emoji_emotions_outlined,
      iconColor: theme.colorScheme.onSurface,
      onTap: onPressed,
    );
  }
}

/// Панель эмодзи под строкой ввода (поле сообщения остаётся видимым).
class ChatEmojiPickerPanel extends StatefulWidget {
  const ChatEmojiPickerPanel({
    super.key,
    required this.controller,
    required this.searchController,
    required this.searchFocusNode,
    this.onCollapse,
  });

  final TextEditingController controller;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final VoidCallback? onCollapse;

  @override
  State<ChatEmojiPickerPanel> createState() => _ChatEmojiPickerPanelState();
}

class _ChatEmojiPickerPanelState extends State<ChatEmojiPickerPanel> {
  VoidCallback? _showSearchView;
  VoidCallback? _hideSearchView;
  void Function(String query)? _applySearchQuery;

  @override
  void initState() {
    super.initState();
    widget.searchController.addListener(_onExternalSearchChanged);
  }

  @override
  void didUpdateWidget(covariant ChatEmojiPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchController != widget.searchController) {
      oldWidget.searchController.removeListener(_onExternalSearchChanged);
      widget.searchController.addListener(_onExternalSearchChanged);
    }
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_onExternalSearchChanged);
    super.dispose();
  }

  void _onExternalSearchChanged() {
    final query = widget.searchController.text.trim();
    if (query.isEmpty) {
      _hideSearchView?.call();
      return;
    }
    _showSearchView?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applySearchQuery?.call(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: cs.surface,
      child: EmojiPicker(
        textEditingController: widget.controller,
        config: Config(
          height: double.maxFinite,
          locale: const Locale('ru'),
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            backgroundColor: cs.surface,
            columns: 8,
            emojiSizeMax: 28 *
                (defaultTargetPlatform == TargetPlatform.iOS ? 1.2 : 1.0),
          ),
          categoryViewConfig: CategoryViewConfig(
            backgroundColor: cs.surface,
            indicatorColor: cs.primary,
            iconColor: Colors.grey,
            iconColorSelected: cs.primary,
          ),
          bottomActionBarConfig: BottomActionBarConfig(
            backgroundColor: cs.surface,
            buttonColor: cs.primary,
            buttonIconColor: cs.onSurface,
            showSearchViewButton: false,
            customBottomActionBar: (config, state, showSearchView) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _showSearchView = showSearchView;
                if (widget.searchController.text.trim().isNotEmpty) {
                  showSearchView();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _applySearchQuery?.call(
                      widget.searchController.text.trim(),
                    );
                  });
                }
              });
              return _ChatEmojiBottomBar(
                config: config,
                state: state,
                searching: false,
              );
            },
          ),
          searchViewConfig: SearchViewConfig(
            backgroundColor: cs.surface,
            buttonIconColor: cs.onSurfaceVariant,
            hintText: 'Поиск',
            customSearchView: (config, state, showEmojiView) {
              return _ChatEmojiSearchView(
                config,
                state,
                showEmojiView,
                searchController: widget.searchController,
                onHideSearch: () => _hideSearchView = showEmojiView,
                onRegisterApplyQuery: (apply) => _applySearchQuery = apply,
              );
            },
          ),
          skinToneConfig: SkinToneConfig(
            dialogBackgroundColor: cs.surface,
            indicatorColor: cs.primary,
          ),
        ),
      ),
    );
  }
}

/// Нижняя полоса эмодзи: backspace (поиск — в шапке шторки).
class _ChatEmojiBottomBar extends StatelessWidget {
  const _ChatEmojiBottomBar({
    required this.config,
    required this.state,
    required this.searching,
  });

  final Config config;
  final EmojiViewState state;
  final bool searching;

  static const double _barHeight = 44;

  @override
  Widget build(BuildContext context) {
    if (searching) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final bg = config.bottomActionBarConfig.backgroundColor ?? cs.surface;

    return Material(
      color: bg,
      child: SizedBox(
        height: _barHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 4, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              BackspaceButton(
                config,
                state.onBackspacePressed,
                state.onBackspaceLongPressed,
                cs.onSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatEmojiSearchView extends SearchView {
  const _ChatEmojiSearchView(
    super.config,
    super.state,
    super.showEmojiView, {
    required this.searchController,
    required this.onHideSearch,
    required this.onRegisterApplyQuery,
  });

  final TextEditingController searchController;
  final VoidCallback onHideSearch;
  final ValueChanged<void Function(String query)> onRegisterApplyQuery;

  @override
  State<_ChatEmojiSearchView> createState() => _ChatEmojiSearchViewState();
}

class _ChatEmojiSearchViewState extends SearchViewState<_ChatEmojiSearchView> {
  @override
  void initState() {
    super.initState();
    focusNode.canRequestFocus = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      focusNode.unfocus();
      widget.onHideSearch();
      widget.onRegisterApplyQuery(onTextInputChanged);
      final query = widget.searchController.text.trim();
      if (query.isNotEmpty) {
        onTextInputChanged(query);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final emojiSize =
            widget.config.emojiViewConfig.getEmojiSize(constraints.maxWidth);
        final emojiBoxSize =
            widget.config.emojiViewConfig.getEmojiBoxSize(constraints.maxWidth);

        return ColoredBox(
          color: widget.config.searchViewConfig.backgroundColor,
          child: Column(
            children: [
              Expanded(
                child: results.isEmpty
                    ? Center(
                        child: Text(
                          widget.searchController.text.trim().isEmpty
                              ? 'Введите запрос в строке поиска выше'
                              : 'Ничего не найдено',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount:
                              widget.config.emojiViewConfig.columns,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          return buildEmoji(
                            results[index],
                            emojiSize,
                            emojiBoxSize,
                          );
                        },
                      ),
              ),
              _ChatEmojiBottomBar(
                config: widget.config,
                state: widget.state,
                searching: true,
              ),
            ],
          ),
        );
      },
    );
  }
}
