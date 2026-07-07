import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/push/push_navigation.dart';
import '../../profile/data/album_upload_coordinator.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';
import '../data/chat_realtime_utils.dart';
import '../data/share_attachment_loader.dart';

/// Выбор чата для отправки контента из системного «Поделиться».
class ChatShareTargetScreen extends ConsumerStatefulWidget {
  const ChatShareTargetScreen({super.key, required this.media});

  final SharedMedia media;

  @override
  ConsumerState<ChatShareTargetScreen> createState() => _ChatShareTargetScreenState();
}

class _ChatShareTargetScreenState extends ConsumerState<ChatShareTargetScreen> {
  List<Map<String, dynamic>> _threads = [];
  List<Map<String, dynamic>> _albums = [];
  final _selectedThreads = <int>{};
  final _selectedAlbumPks = <int>{};
  int _tabIndex = 0;
  bool _loading = true;
  bool _sending = false;
  String? _loadError;
  late final TextEditingController _captionController;
  List<ShareAttachmentData> _attachments = const [];

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.media.content ?? '');
    _load();
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final attachments = await readShareAttachments(widget.media);
      final repo = ref.read(familychatRepositoryProvider);
      final status = await repo.status();
      final myUserId = status['user_id'] is int ? status['user_id'] as int : null;
      List<Map<String, dynamic>> albums = const [];
      if (myUserId != null) {
        final cached = await FamilyChatLocalCache.readMemberAlbums(myUserId);
        if (cached != null) {
          albums = (cached['albums'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>()
              .where((a) => a['kind']?.toString() == 'custom')
              .toList();
          if (mounted) {
            setState(() {
              _attachments = attachments;
              _albums = albums;
              _loading = false;
            });
          }
        }
        try {
          final albumsData = await repo.memberGalleryAlbums(myUserId);
          await FamilyChatLocalCache.saveMemberAlbums(myUserId, albumsData);
          albums = (albumsData['albums'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>()
              .where((a) => a['kind']?.toString() == 'custom')
              .toList();
        } catch (_) {
          if (albums.isEmpty) rethrow;
        }
      }
      final list = await repo.chatThreads();
      if (!mounted) return;
      setState(() {
        _attachments = attachments;
        _threads = list;
        _albums = albums;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Не удалось подготовить отправку';
        _loading = false;
      });
    }
  }

  bool get _canSend {
    final caption = _captionController.text.trim();
    if (_tabIndex == 0) {
      return _selectedThreads.isNotEmpty && (caption.isNotEmpty || _attachments.isNotEmpty);
    }
    final imageCount = _attachments.where((a) => a.isImage).length;
    return _selectedAlbumPks.isNotEmpty && imageCount > 0;
  }

  Map<String, dynamic>? _albumByPk(int pk) {
    for (final album in _albums) {
      final idStr = album['id']?.toString() ?? '';
      if (idStr == 'custom:$pk') return album;
    }
    return null;
  }

  Future<void> _sendToAlbums({
    required int myUserId,
    required List<int> albumPks,
    required List<ShareAttachmentData> images,
  }) async {
    final repo = ref.read(familychatRepositoryProvider);
    final coordinator = AlbumUploadCoordinator.instance;
    final photos = images
        .map(
          (att) => AlbumUploadPhoto(
            bytes: Uint8List.fromList(att.bytes),
            filename: att.filename,
            contentType: att.contentType ?? 'image/jpeg',
          ),
        )
        .toList();

    int? navigatePk;
    var navigateTitle = 'Альбом';

    for (final albumPk in albumPks) {
      final album = _albumByPk(albumPk);
      final title = album?['title']?.toString() ?? 'Альбом';
      navigatePk ??= albumPk;
      navigateTitle = title;
      coordinator.startUploadToCustomAlbum(
        repo: repo,
        userId: myUserId,
        albumPk: albumPk,
        albumId: 'custom:$albumPk',
        title: title,
        photos: photos,
      );
    }

    if (!mounted || navigatePk == null) return;
    Navigator.of(context).pop();
    familyChatNavigatorKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileGalleryAlbumScreen(
          userId: myUserId,
          albumId: 'custom:$navigatePk',
          title: navigateTitle,
          canManage: true,
        ),
      ),
    );
  }

  Future<void> _send() async {
    if (!_canSend || _sending) return;
    setState(() => _sending = true);

    final caption = _captionController.text.trim();
    final repo = ref.read(familychatRepositoryProvider);
    final threadIds = _selectedThreads.toList();
    final albumPks = _selectedAlbumPks.toList();

    try {
      if (_tabIndex == 0) {
        for (final threadId in threadIds) {
          final attachmentIds = <int>[];
          for (final att in _attachments) {
            final uploaded = await repo.uploadChatAttachmentBytes(
              threadId,
              bytes: Uint8List.fromList(att.bytes),
              filename: att.filename,
              contentType: att.contentType,
            );
            final id = chatAsInt(uploaded['id']);
            if (id != null) attachmentIds.add(id);
          }
          await repo.sendThreadMessage(
            threadId,
            body: caption.isEmpty ? null : caption,
            attachmentIds: attachmentIds.isEmpty ? null : attachmentIds,
          );
        }
        if (!mounted) return;
        Navigator.of(context).pop(true);
        final message = threadIds.length == 1
            ? 'Отправлено в чат'
            : 'Отправлено в ${threadIds.length} чата';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      } else {
        final images = _attachments.where((a) => a.isImage).toList();
        final status = await repo.status();
        final myUserId = status['user_id'] is int
            ? status['user_id'] as int
            : int.tryParse('${status['user_id']}');
        if (myUserId == null) {
          throw StateError('User id is missing');
        }
        await _sendToAlbums(
          myUserId: myUserId,
          albumPks: albumPks,
          images: images,
        );
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить')),
      );
    }
  }

  List<int> get _selectableThreadIds => _threads.map(chatAsInt).whereType<int>().toList();

  List<int> get _selectableAlbumPks => _albums
      .map((a) {
        final idStr = a['id']?.toString() ?? '';
        if (!idStr.startsWith('custom:')) return null;
        return int.tryParse(idStr.substring(7));
      })
      .whereType<int>()
      .toList();

  bool get _allThreadsSelected {
    final ids = _selectableThreadIds;
    return ids.isNotEmpty && ids.every(_selectedThreads.contains);
  }

  bool get _allAlbumsSelected {
    final ids = _selectableAlbumPks;
    return ids.isNotEmpty && ids.every(_selectedAlbumPks.contains);
  }

  void _toggleSelectAllTargets() {
    if (_tabIndex == 0) {
      final ids = _selectableThreadIds;
      setState(() {
        if (_allThreadsSelected) {
          _selectedThreads.removeAll(ids);
        } else {
          _selectedThreads.addAll(ids);
        }
      });
      return;
    }
    final ids = _selectableAlbumPks;
    setState(() {
      if (_allAlbumsSelected) {
        _selectedAlbumPks.removeAll(ids);
      } else {
        _selectedAlbumPks.addAll(ids);
      }
    });
  }

  bool get _allTargetsSelected => _tabIndex == 0 ? _allThreadsSelected : _allAlbumsSelected;

  bool get _hasSelectableTargets =>
      _tabIndex == 0 ? _selectableThreadIds.isNotEmpty : _selectableAlbumPks.isNotEmpty;

  Widget _buildTargetsList() {
    if (_tabIndex == 0) {
      if (_threads.isEmpty) return const Center(child: Text('Нет доступных чатов'));
      return ListView.builder(
        itemCount: _threads.length,
        itemBuilder: (_, i) {
          final t = _threads[i];
          final id = chatAsInt(t['id']);
          if (id == null) return const SizedBox.shrink();
          final selected = _selectedThreads.contains(id);
          return CheckboxListTile(
            value: selected,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _selectedThreads.add(id);
                } else {
                  _selectedThreads.remove(id);
                }
              });
            },
            title: Text(t['title']?.toString() ?? 'Чат'),
            subtitle: Text(_preview(t)),
          );
        },
      );
    }
    if (_albums.isEmpty) {
      return const Center(child: Text('Нет доступных альбомов'));
    }
    return ListView.builder(
      itemCount: _albums.length,
      itemBuilder: (_, i) {
        final a = _albums[i];
        final idStr = a['id']?.toString() ?? '';
        final pk = idStr.startsWith('custom:') ? int.tryParse(idStr.substring(7)) : null;
        if (pk == null) return const SizedBox.shrink();
        final selected = _selectedAlbumPks.contains(pk);
        return CheckboxListTile(
          value: selected,
          onChanged: (v) {
            setState(() {
              if (v == true) {
                _selectedAlbumPks.add(pk);
              } else {
                _selectedAlbumPks.remove(pk);
              }
            });
          },
          title: Text(a['title']?.toString() ?? 'Альбом'),
          subtitle: Text('${a['count'] ?? 0} фото'),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = _captionController.text.trim();
    final hasPayload = caption.isNotEmpty || _attachments.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Поделиться'),
        actions: [
          TextButton(
            onPressed: _hasSelectableTargets ? _toggleSelectAllTargets : null,
            child: Text(_allTargetsSelected ? 'Снять все' : 'Выбрать все'),
          ),
          TextButton(
            onPressed: !_canSend || _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _tabIndex == 0
                        ? 'Отправить (${_selectedThreads.length})'
                        : 'Добавить (${_selectedAlbumPks.length})',
                  ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(child: Text(_loadError!))
              : !hasPayload
                  ? const Center(child: Text('Нет данных для отправки'))
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_attachments.isNotEmpty)
                                SizedBox(
                                  height: 88,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _attachments.length,
                                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                                    itemBuilder: (_, i) {
                                      final att = _attachments[i];
                                      if (att.isImage) {
                                        return ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Image.memory(
                                            Uint8List.fromList(att.bytes),
                                            width: 88,
                                            height: 88,
                                            fit: BoxFit.cover,
                                          ),
                                        );
                                      }
                                      return Container(
                                        width: 88,
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            const Icon(Icons.insert_drive_file_outlined),
                                            const SizedBox(width: 4),
                                            Text(
                                              att.filename,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.labelSmall,
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              if (_attachments.isNotEmpty) const SizedBox(height: 12),
                              TextField(
                                controller: _captionController,
                                minLines: 1,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                  labelText: 'Подпись',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: SegmentedButton<int>(
                            segments: const [
                              ButtonSegment(value: 0, label: Text('Чаты')),
                              ButtonSegment(value: 1, label: Text('Галерея')),
                            ],
                            selected: {_tabIndex},
                            onSelectionChanged: (s) {
                              setState(() => _tabIndex = s.first);
                            },
                          ),
                        ),
                        Expanded(
                          child: _buildTargetsList(),
                        ),
                      ],
                    ),
    );
  }

  String _preview(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    if (last == null) return 'Нет сообщений';
    final body = last['body']?.toString() ?? '';
    if (body.isNotEmpty) return body;
    return 'Вложение';
  }
}
