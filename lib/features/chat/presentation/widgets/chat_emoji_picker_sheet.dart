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
class ChatEmojiPickerPanel extends StatelessWidget {
  const ChatEmojiPickerPanel({
    super.key,
    required this.controller,
    this.onCollapse,
  });

  final TextEditingController controller;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final height =
        (MediaQuery.sizeOf(context).height * 0.38).clamp(260.0, 360.0);

    return Material(
      color: cs.surface,
      child: SizedBox(
        height: height,
        child: EmojiPicker(
          textEditingController: controller,
          config: Config(
            height: height,
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
              extraTab: CategoryExtraTab.SEARCH,
            ),
            bottomActionBarConfig: BottomActionBarConfig(
              backgroundColor: cs.surface,
              buttonColor: cs.primary,
              buttonIconColor: cs.onSurface,
              customBottomActionBar: (config, state, showSearchView) {
                return _ChatEmojiBottomBar(
                  config: config,
                  state: state,
                  searching: false,
                  onSearch: showSearchView,
                  onCollapse: onCollapse,
                );
              },
            ),
            searchViewConfig: SearchViewConfig(
              backgroundColor: cs.surface,
              buttonIconColor: cs.onSurfaceVariant,
              hintText: 'Поиск смайлов',
              customSearchView: (config, state, showEmojiView) {
                return _ChatEmojiSearchView(
                  config,
                  state,
                  showEmojiView,
                  onCollapse: onCollapse,
                );
              },
            ),
            skinToneConfig: SkinToneConfig(
              dialogBackgroundColor: cs.surface,
              indicatorColor: cs.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Нижняя полоса: поиск по центру, backspace + свернуть справа.
class _ChatEmojiBottomBar extends StatelessWidget {
  const _ChatEmojiBottomBar({
    required this.config,
    required this.state,
    required this.searching,
    this.searchField,
    this.onSearch,
    this.onCollapse,
  });

  final Config config;
  final EmojiViewState state;
  final bool searching;
  final Widget? searchField;
  final VoidCallback? onSearch;
  final VoidCallback? onCollapse;

  static const double _barHeight = 52;
  static const double _rightActionsWidth = 96;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = config.bottomActionBarConfig.backgroundColor ?? cs.surface;

    return Material(
      color: bg,
      child: SizedBox(
        height: _barHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 6),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _rightActionsWidth / 2,
                ),
                child: Align(
                  alignment: Alignment.center,
                  child: searching
                      ? (searchField ?? const SizedBox.shrink())
                      : _SearchPillButton(onTap: onSearch),
                ),
              ),
              Positioned(
                right: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BackspaceButton(
                      config,
                      state.onBackspacePressed,
                      state.onBackspaceLongPressed,
                      cs.onSurface,
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchPillButton extends StatelessWidget {
  const _SearchPillButton({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primary,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 20, color: cs.onPrimary),
              const SizedBox(width: 8),
              Text(
                'Поиск',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: cs.onPrimary,
                      fontWeight: FontWeight.w600,
                    ),
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
    this.onCollapse,
  });

  final VoidCallback? onCollapse;

  @override
  State<_ChatEmojiSearchView> createState() => _ChatEmojiSearchViewState();
}

class _ChatEmojiSearchViewState extends SearchViewState<_ChatEmojiSearchView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph;
  late final Animation<double> _expand;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _expand = CurvedAnimation(parent: _morph, curve: Curves.easeOutCubic);
    _fade = CurvedAnimation(parent: _morph, curve: Curves.easeOut);
    _morph.forward();
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
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
                          'Ничего не найдено',
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
                onCollapse: widget.onCollapse,
                searchField: AnimatedBuilder(
                  animation: _morph,
                  builder: (context, _) {
                    return _MorphingSearchField(
                      expand: _expand.value,
                      fade: _fade.value,
                      focusNode: focusNode,
                      hintText:
                          widget.config.searchViewConfig.hintText ?? 'Поиск',
                      hintStyle: widget.config.searchViewConfig.hintTextStyle,
                      style: widget.config.searchViewConfig.inputTextStyle,
                      onChanged: onTextInputChanged,
                      onCloseSearch: widget.showEmojiView,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Кнопка «Поиск» плавно расширяется в поле ввода на том же месте.
class _MorphingSearchField extends StatelessWidget {
  const _MorphingSearchField({
    required this.expand,
    required this.fade,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    required this.onCloseSearch,
    this.hintStyle,
    this.style,
  });

  final double expand;
  final double fade;
  final FocusNode focusNode;
  final String hintText;
  final TextStyle? hintStyle;
  final TextStyle? style;
  final ValueChanged<String> onChanged;
  final VoidCallback onCloseSearch;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pillWidth = 120.0;
    final maxWidth = MediaQuery.sizeOf(context).width - 16 - 96;
    final width = pillWidth + (maxWidth - pillWidth) * expand;

    return SizedBox(
      width: width.clamp(pillWidth, maxWidth),
      child: Material(
        color: Color.lerp(cs.primary, cs.surfaceContainerHighest, expand),
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Назад',
                visualDensity: VisualDensity.compact,
                onPressed: onCloseSearch,
                icon: Icon(
                  Icons.arrow_back,
                  size: 20,
                  color: Color.lerp(cs.onPrimary, cs.onSurfaceVariant, expand),
                ),
              ),
              Expanded(
                child: Opacity(
                  opacity: fade,
                  child: TextField(
                    focusNode: focusNode,
                    onChanged: onChanged,
                    style: style ??
                        Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurface,
                            ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: hintText,
                      hintStyle: hintStyle ??
                          TextStyle(color: cs.onSurfaceVariant),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
