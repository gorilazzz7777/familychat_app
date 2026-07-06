import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';

class ProfileGalleryAlbumScreen extends ConsumerStatefulWidget {
  const ProfileGalleryAlbumScreen({
    super.key,
    required this.userId,
    required this.albumId,
    required this.title,
  });

  final int userId;
  final String albumId;
  final String title;

  @override
  ConsumerState<ProfileGalleryAlbumScreen> createState() => _ProfileGalleryAlbumScreenState();
}

class _ProfileGalleryAlbumScreenState extends ConsumerState<ProfileGalleryAlbumScreen> {
  final List<Map<String, dynamic>> _photos = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _offset = 0;
  int _total = 0;
  static const _pageSize = 60;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _offset = 0;
        _photos.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).memberGalleryPhotos(
            widget.userId,
            widget.albumId,
            offset: _offset,
            limit: _pageSize,
          );
      if (!mounted) return;
      final batch = (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _total = data['total'] is int ? data['total'] as int : int.tryParse('${data['total']}') ?? 0;
        _photos.addAll(batch);
        _offset += batch.length;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => _load(reset: true),
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                )
              : _photos.isEmpty
                  ? const Center(child: Text('Нет фото'))
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200 &&
                            !_loadingMore &&
                            _photos.length < _total) {
                          _load(reset: false);
                        }
                        return false;
                      },
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: _photos.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= _photos.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            );
                          }
                          final photo = _photos[i];
                          final threadId = photo['thread_id'];
                          if (threadId is! int) {
                            return const ColoredBox(color: Color(0x22000000));
                          }
                          return ChatNetworkImage(
                            threadId: threadId,
                            attachment: photo,
                            fit: BoxFit.cover,
                          );
                        },
                      ),
                    ),
    );
  }
}
