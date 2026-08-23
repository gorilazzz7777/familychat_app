import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cache/familychat_local_cache.dart';
import '../../../../core/providers/app_providers.dart';
import '../../data/chat_gif_item.dart';

/// Сетка GIF или стикеров (trending / search) с локальным кэшем каталога.
class ChatGifPickerPanel extends ConsumerStatefulWidget {
  const ChatGifPickerPanel({
    super.key,
    required this.kind,
    required this.searchController,
    required this.onSelected,
    this.onUserScroll,
    this.onRegisterForceSearch,
  });

  /// `gif` or `sticker`.
  final String kind;
  final TextEditingController searchController;
  final void Function(ChatGifItem item) onSelected;

  /// Скрыть клавиатуру при прокрутке сетки пользователем.
  final VoidCallback? onUserScroll;

  /// Регистрация колбэка для кнопки «Найти» / Enter (поиск даже при < 4 символах).
  final void Function(VoidCallback forceSearch)? onRegisterForceSearch;

  @override
  ConsumerState<ChatGifPickerPanel> createState() => _ChatGifPickerPanelState();
}

class _ChatGifPickerPanelState extends ConsumerState<ChatGifPickerPanel> {
  static const _debounceDelay = Duration(milliseconds: 700);
  static const _minAutoQueryLength = 4;

  final _scroll = ScrollController();
  Timer? _debounce;

  String _query = '';
  int _page = 1;
  bool _hasNext = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  List<ChatGifItem> _items = const [];

  bool get _isSticker => widget.kind == 'sticker';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.searchController.addListener(_onSearchChanged);
    widget.onRegisterForceSearch?.call(forceSearch);
    unawaited(_load(reset: true));
  }

  @override
  void didUpdateWidget(covariant ChatGifPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchController != widget.searchController) {
      oldWidget.searchController.removeListener(_onSearchChanged);
      widget.searchController.addListener(_onSearchChanged);
    }
    if (oldWidget.onRegisterForceSearch != widget.onRegisterForceSearch ||
        oldWidget.kind != widget.kind) {
      widget.onRegisterForceSearch?.call(forceSearch);
    }
    if (oldWidget.kind != widget.kind) {
      _query = _effectiveQuery(
        widget.searchController.text.trim(),
        force: false,
      );
      _items = const [];
      unawaited(_load(reset: true));
    }
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_onSearchChanged);
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Поиск по текущему тексту (в т.ч. короче 4 символов).
  void forceSearch() {
    _debounce?.cancel();
    _commitQuery(force: true);
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      _commitQuery(force: false);
    });
  }

  String _effectiveQuery(String raw, {required bool force}) {
    if (raw.isEmpty) return '';
    if (force || raw.length >= _minAutoQueryLength) return raw;
    return '';
  }

  void _commitQuery({required bool force}) {
    final raw = widget.searchController.text.trim();
    final next = _effectiveQuery(raw, force: force);
    if (next == _query) return;
    setState(() => _query = next);
    unawaited(_load(reset: true));
  }

  void _onScroll() {
    if (!_hasNext || _loadingMore || _loading) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      unawaited(_loadMore());
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      widget.onUserScroll?.call();
    }
    return false;
  }

  Future<Map<String, dynamic>> _fetchRemote(int page) {
    final repo = ref.read(familychatRepositoryProvider);
    if (_isSticker) {
      return repo.fetchStickerCatalog(query: _query, page: page);
    }
    return repo.fetchGifCatalog(query: _query, page: page);
  }

  Future<void> _load({
    required bool reset,
    bool forceNetwork = false,
  }) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _error = null;
        _page = 1;
      }
    });

    final page = reset ? 1 : _page;
    final cached = await FamilyChatLocalCache.readKlipyCatalog(
      kind: widget.kind,
      query: _query,
      page: page,
    );
    if (cached != null && mounted) {
      _applyPage(cached, append: !reset && page > 1);
      if (!forceNetwork) {
        if (mounted) setState(() => _loading = false);
        return;
      }
    }

    try {
      final data = await _fetchRemote(page);
      await FamilyChatLocalCache.saveKlipyCatalog(
        kind: widget.kind,
        query: _query,
        page: page,
        data: data,
      );
      if (!mounted) return;
      _applyPage(data, append: !reset && page > 1);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (_items.isEmpty) {
          _error = _isSticker
              ? 'Не удалось загрузить стикеры'
              : 'Не удалось загрузить гифки';
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasNext || _loadingMore || _loading) return;
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;
    try {
      final cached = await FamilyChatLocalCache.readKlipyCatalog(
        kind: widget.kind,
        query: _query,
        page: nextPage,
      );
      if (cached != null && mounted) {
        _applyPage(cached, append: true);
        return;
      }
      final data = await _fetchRemote(nextPage);
      await FamilyChatLocalCache.saveKlipyCatalog(
        kind: widget.kind,
        query: _query,
        page: nextPage,
        data: data,
      );
      if (!mounted) return;
      _applyPage(data, append: true);
    } catch (_) {
      // keep current list
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _applyPage(Map<String, dynamic> data, {required bool append}) {
    final raw = data['items'];
    final parsed = <ChatGifItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final item = ChatGifItem.fromJson(e);
          if (item.url.isNotEmpty && item.previewUrl.isNotEmpty) {
            parsed.add(item);
          }
        } else if (e is Map) {
          final item = ChatGifItem.fromJson(Map<String, dynamic>.from(e));
          if (item.url.isNotEmpty && item.previewUrl.isNotEmpty) {
            parsed.add(item);
          }
        }
      }
    }
    final page = int.tryParse(data['page']?.toString() ?? '') ?? 1;
    final hasNext = data['has_next'] == true;
    setState(() {
      _page = page;
      _hasNext = hasNext;
      _error = null;
      if (append) {
        final seen = {for (final i in _items) i.id.isNotEmpty ? i.id : i.url};
        final merged = [..._items];
        for (final item in parsed) {
          final key = item.id.isNotEmpty ? item.id : item.url;
          if (seen.add(key)) merged.add(item);
        }
        _items = merged;
      } else {
        _items = parsed;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surface,
      child: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () =>
                  unawaited(_load(reset: true, forceNetwork: true)),
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty
              ? (_isSticker ? 'Пока нет стикеров' : 'Пока нет гифок')
              : 'Ничего не найдено',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: _items.length,
            itemBuilder: (context, index) {
              final item = _items[index];
              return Material(
                color: _isSticker
                    ? Colors.transparent
                    : cs.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => widget.onSelected(item),
                  child: _RetryableGifPreview(
                    primaryUrl: item.gridPreviewUrl,
                    fallbackUrl: item.url,
                    fit: _isSticker ? BoxFit.contain : BoxFit.cover,
                    transparentPlaceholder: _isSticker,
                  ),
                ),
              );
            },
          ),
        ),
        if (_loadingMore)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }
}

/// Превью в сетке с автоповтором и fallback URL при сбое CDN.
class _RetryableGifPreview extends StatefulWidget {
  const _RetryableGifPreview({
    required this.primaryUrl,
    required this.fallbackUrl,
    required this.fit,
    this.transparentPlaceholder = false,
  });

  final String primaryUrl;
  final String fallbackUrl;
  final BoxFit fit;
  final bool transparentPlaceholder;

  @override
  State<_RetryableGifPreview> createState() => _RetryableGifPreviewState();
}

class _RetryableGifPreviewState extends State<_RetryableGifPreview> {
  static const _maxAttempts = 4;

  int _attempt = 0;
  bool _retryScheduled = false;
  late String _url;

  @override
  void initState() {
    super.initState();
    _url = widget.primaryUrl;
  }

  @override
  void didUpdateWidget(covariant _RetryableGifPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.primaryUrl != widget.primaryUrl ||
        oldWidget.fallbackUrl != widget.fallbackUrl) {
      _attempt = 0;
      _retryScheduled = false;
      _url = widget.primaryUrl;
    }
  }

  void _scheduleRetry() {
    if (_retryScheduled || _attempt >= _maxAttempts) return;
    _retryScheduled = true;
    final next = _attempt + 1;
    Future<void>.delayed(Duration(milliseconds: 280 * next), () {
      if (!mounted) return;
      setState(() {
        _attempt = next;
        _retryScheduled = false;
        // После первой ошибки — полный файл, если он другой.
        if (next == 1 &&
            widget.fallbackUrl.isNotEmpty &&
            widget.fallbackUrl != widget.primaryUrl) {
          _url = widget.fallbackUrl;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: widget.transparentPlaceholder
          ? Colors.transparent
          : cs.surfaceContainerHighest.withValues(alpha: 0.4),
      child: _attempt > 0
          ? Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.55),
                ),
              ),
            )
          : null,
    );

    if (_url.isEmpty) {
      return Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant);
    }

    return CachedNetworkImage(
      key: ValueKey('gif-preview:$_url:$_attempt'),
      imageUrl: _url,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) {
        if (_attempt < _maxAttempts) {
          _scheduleRetry();
          return placeholder;
        }
        return GestureDetector(
          onTap: () {
            setState(() {
              _attempt = 0;
              _retryScheduled = false;
              _url = widget.primaryUrl;
            });
          },
          child: Icon(
            Icons.refresh_rounded,
            color: cs.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
