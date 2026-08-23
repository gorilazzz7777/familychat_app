import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cache/familychat_local_cache.dart';
import '../../../../core/providers/app_providers.dart';
import '../../data/chat_gif_item.dart';

/// Сетка GIF (trending / search) с локальным кэшем каталога.
class ChatGifPickerPanel extends ConsumerStatefulWidget {
  const ChatGifPickerPanel({
    super.key,
    required this.onSelected,
    this.onCollapse,
  });

  final void Function(ChatGifItem item) onSelected;
  final VoidCallback? onCollapse;

  @override
  ConsumerState<ChatGifPickerPanel> createState() => _ChatGifPickerPanelState();
}

class _ChatGifPickerPanelState extends ConsumerState<ChatGifPickerPanel> {
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  String _query = '';
  int _page = 1;
  bool _hasNext = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  List<ChatGifItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasNext || _loadingMore || _loading) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      unawaited(_loadMore());
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final next = value.trim();
      if (next == _query) return;
      setState(() => _query = next);
      unawaited(_load(reset: true));
    });
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _error = null;
        _page = 1;
      }
    });

    final page = reset ? 1 : _page;
    final cached = await FamilyChatLocalCache.readGifCatalog(
      query: _query,
      page: page,
    );
    if (cached != null && mounted && reset) {
      _applyPage(cached, append: false);
    }

    try {
      final repo = ref.read(familychatRepositoryProvider);
      final data = await repo.fetchGifCatalog(query: _query, page: page);
      await FamilyChatLocalCache.saveGifCatalog(
        query: _query,
        page: page,
        data: data,
      );
      if (!mounted) return;
      _applyPage(data, append: !reset && page > 1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_items.isEmpty) {
          _error = 'Не удалось загрузить гифки';
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
      final cached = await FamilyChatLocalCache.readGifCatalog(
        query: _query,
        page: nextPage,
      );
      if (cached != null && mounted) {
        _applyPage(cached, append: true);
      }
      final repo = ref.read(familychatRepositoryProvider);
      final data = await repo.fetchGifCatalog(query: _query, page: nextPage);
      await FamilyChatLocalCache.saveGifCatalog(
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final height =
        (MediaQuery.sizeOf(context).height * 0.38).clamp(260.0, 360.0);

    return Material(
      color: cs.surface,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: _onQueryChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Поиск GIF',
                        isDense: true,
                        filled: true,
                        fillColor: cs.surfaceContainerHighest.withValues(
                          alpha: 0.55,
                        ),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(999),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Свернуть',
                    onPressed: widget.onCollapse,
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: cs.onSurface,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody(cs)),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'GIF via KLIPY',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
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
              onPressed: () => unawaited(_load(reset: true)),
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? 'Пока нет гифок' : 'Ничего не найдено',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    return Stack(
      children: [
        GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final item = _items[index];
            return Material(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => widget.onSelected(item),
                child: CachedNetworkImage(
                  imageUrl: item.previewUrl,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 120),
                  placeholder: (_, __) => ColoredBox(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                  ),
                  errorWidget: (_, __, ___) => Icon(
                    Icons.broken_image_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            );
          },
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
