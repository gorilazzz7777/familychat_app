import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../app/shell_refresh.dart';
import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/push/push_navigation.dart';
import '../../../core/feed/feed_photo_batch_session.dart';
import '../../feed/data/feed_post_uploader.dart';
import '../../profile/data/album_upload_coordinator.dart';
import '../../profile/presentation/custom_album_dialog.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
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
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  final _selectedThreads = <int>{};
  final _selectedAlbumPks = <int>{};
  bool _shareToFeed = false;
  int _tabIndex = 0;
  bool _loadingAttachments = true;
  bool _loadingThreads = true;
  bool _loadingAlbums = true;
  bool _creatingAlbum = false;
  bool _sending = false;
  String? _loadError;
  int? _myUserId;
  late final TextEditingController _captionController;
  late final TextEditingController _albumSearchController;
  String _albumSearchQuery = '';
  List<ShareAttachmentData> _attachments = const [];

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.media.content ?? '');
    _albumSearchController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _captionController.dispose();
    _albumSearchController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _parseCustomAlbums(Map<String, dynamic> data) {
    return (data['albums'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .where((a) => a['kind']?.toString() == 'custom')
        .toList();
  }

  int? _albumPk(Map<String, dynamic> album) {
    final idStr = album['id']?.toString() ?? '';
    if (!idStr.startsWith('custom:')) return null;
    return int.tryParse(idStr.substring(7));
  }

  Future<void> _loadThreads(dynamic repo) async {
    try {
      final results = await Future.wait<dynamic>([
        repo.chatThreads(),
        repo.members(),
      ]);
      final list = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      final byUserId = <int, Map<String, dynamic>>{};
      for (final member in members) {
        final uid = member['user_id'];
        final userId = uid is int ? uid : int.tryParse('$uid');
        if (userId == null) continue;
        byUserId[userId] = member;
      }
      if (!mounted) return;
      setState(() {
        _threads = list;
        _memberByUserId
          ..clear()
          ..addAll(byUserId);
        _loadingThreads = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingThreads = false);
    }
  }

  int? _dmPeerUserId(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString();
    if (kind != 'dm' && kind != 'friend_dm') return null;
    final raw = thread['peer_user_id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  String _threadTitle(Map<String, dynamic> thread) {
    final peerId = _dmPeerUserId(thread);
    if (peerId != null) {
      final display = _memberByUserId[peerId]?['display_name']?.toString().trim();
      if (display != null && display.isNotEmpty) return display;
    }
    return thread['title']?.toString() ?? 'Чат';
  }

  String? _threadSubtitle(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString() ?? '';
    if (kind == 'dm') {
      final peerId = _dmPeerUserId(thread);
      if (peerId == null) return null;
      final label = _memberByUserId[peerId]?['kinship_label']?.toString().trim();
      return label == null || label.isEmpty ? null : label;
    }
    if (kind == 'group') {
      return 'Группа';
    }
    if (kind == 'family') {
      return 'Общий чат семьи';
    }
    return null;
  }

  String? _threadAvatarUrl(Map<String, dynamic> thread) {
    final fromThread = thread['peer_avatar_url']?.toString().trim();
    if (fromThread != null && fromThread.isNotEmpty) return fromThread;
    final peerId = _dmPeerUserId(thread);
    if (peerId == null) return null;
    final url = _memberByUserId[peerId]?['avatar_url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  Future<void> _loadAlbums(
    dynamic repo,
    int myUserId, {
    bool selectNewest = false,
    bool forceRefresh = false,
  }) async {
    var albums = <Map<String, dynamic>>[];
    try {
      if (!forceRefresh) {
        final cached = await FamilyChatLocalCache.readMemberAlbums(myUserId);
        if (cached != null) {
          albums = _parseCustomAlbums(cached);
          if (mounted) {
            setState(() => _albums = albums);
          }
        }
      }
      final albumsData = await repo.memberGalleryAlbums(myUserId);
      await FamilyChatLocalCache.saveMemberAlbums(myUserId, albumsData);
      albums = _parseCustomAlbums(albumsData);
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _loadingAlbums = false;
        if (selectNewest && albums.isNotEmpty) {
          int? newestPk;
          for (final album in albums) {
            final pk = _albumPk(album);
            if (pk == null) continue;
            if (newestPk == null || pk > newestPk) {
              newestPk = pk;
            }
          }
          if (newestPk != null) _selectedAlbumPks.add(newestPk);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAlbums = false);
      if (albums.isEmpty) rethrow;
    }
  }

  Future<void> _load() async {
    try {
      final attachments = await readShareAttachments(widget.media);
      if (!mounted) return;
      setState(() {
        _attachments = attachments;
        _loadingAttachments = false;
      });

      final repo = ref.read(familychatRepositoryProvider);
      final status = await repo.status();
      final myUserId = status['user_id'] is int
          ? status['user_id'] as int
          : int.tryParse('${status['user_id']}');
      if (mounted) setState(() => _myUserId = myUserId);

      await Future.wait<void>([
        _loadThreads(repo),
        if (myUserId != null) _loadAlbums(repo, myUserId) else Future<void>.value(),
      ]);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Не удалось подготовить отправку';
        _loadingAttachments = false;
        _loadingThreads = false;
        _loadingAlbums = false;
      });
    }
  }

  Future<void> _createAlbum() async {
    final userId = _myUserId;
    if (userId == null || _creatingAlbum) return;
    final created = await CustomAlbumDialog.show(context, userId: userId);
    if (created != true || !mounted) return;
    setState(() {
      _creatingAlbum = true;
      _loadingAlbums = true;
    });
    try {
      final repo = ref.read(familychatRepositoryProvider);
      await _loadAlbums(
        repo,
        userId,
        selectNewest: true,
        forceRefresh: true,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось обновить список альбомов')),
      );
    } finally {
      if (mounted) {
        setState(() => _creatingAlbum = false);
      }
    }
  }

  bool get _canSend {
    final caption = _captionController.text.trim();
    final images = _attachments.where((a) => a.isImage).toList();
    if (_shareToFeed && images.isNotEmpty) return true;
    if (_selectedThreads.isNotEmpty && (caption.isNotEmpty || _attachments.isNotEmpty)) {
      return true;
    }
    return _selectedAlbumPks.isNotEmpty && images.isNotEmpty;
  }

  String get _sendButtonLabel {
    final parts = <String>[];
    if (_shareToFeed) parts.add('лента');
    if (_selectedThreads.isNotEmpty) parts.add('${_selectedThreads.length} ч');
    if (_selectedAlbumPks.isNotEmpty) parts.add('${_selectedAlbumPks.length} альб');
    if (parts.isEmpty) return 'Отправить';
    return 'Отправить (${parts.join(', ')})';
  }

  List<ShareAttachmentData> get _imageAttachments =>
      _attachments.where((a) => a.isImage).toList();

  Future<void> _sendToFeed({
    required List<ShareAttachmentData> images,
    required String caption,
  }) async {
    final limited = images.take(FeedPostUploader.maxPhotos).toList();
    if (limited.length < images.length && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'В ленту можно отправить не более ${FeedPostUploader.maxPhotos} фото',
          ),
        ),
      );
    }
    await FeedPostUploader.publish(
      repo: ref.read(familychatRepositoryProvider),
      photos: limited
          .map(
            (att) => FeedPostPhoto(
              bytes: Uint8List.fromList(att.bytes),
              filename: att.filename,
              contentType: att.contentType,
            ),
          )
          .toList(),
      caption: caption,
    );
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
    final batch = FeedPhotoBatchSession(
      totalTasks: albumPks.length * photos.length,
    );

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
        batchSession: batch,
      );
    }

    if (!mounted || navigatePk == null) return;
    final nav = familyChatNavigatorKey.currentState;
    Navigator.of(context).pop();
    if (nav == null) return;
    await nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileGalleryAlbumScreen(
          userId: myUserId,
          albumId: 'custom:$navigatePk',
          title: navigateTitle,
          canManage: true,
          isOwnGallery: true,
        ),
      ),
    );
    await ShellRefresh.instance.refreshMainTabs();
  }

  Future<void> _send() async {
    if (!_canSend || _sending) return;
    setState(() => _sending = true);

    final caption = _captionController.text.trim();
    final repo = ref.read(familychatRepositoryProvider);
    final threadIds = _selectedThreads.toList();
    final albumPks = _selectedAlbumPks.toList();
    final images = _imageAttachments;

    try {
      var sentAny = false;

      if (_shareToFeed && images.isNotEmpty) {
        await _sendToFeed(images: images, caption: caption);
        sentAny = true;
      }

      if (threadIds.isNotEmpty) {
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
        sentAny = true;
      }

      if (albumPks.isNotEmpty && images.isNotEmpty) {
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

      if (!mounted) return;
      if (sentAny) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _shareToFeed && threadIds.isEmpty && albumPks.isEmpty
                  ? 'Опубликовано в ленту'
                  : 'Отправлено',
            ),
          ),
        );
        await ShellRefresh.instance.refreshMainTabs();
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

  List<Map<String, dynamic>> get _filteredAlbums {
    if (_albumSearchQuery.isEmpty) return _albums;
    return _albums
        .where((a) =>
            (a['title']?.toString().toLowerCase() ?? '').contains(_albumSearchQuery))
        .toList();
  }

  bool get _hasSelectableTargets {
    if (_creatingAlbum) return false;
    if (_tabIndex == 0) {
      return !_loadingThreads && _selectableThreadIds.isNotEmpty;
    }
    return !_loadingAlbums && _selectableAlbumPks.isNotEmpty;
  }

  Widget _buildFeedShareTile() {
    final enabled = _imageAttachments.isNotEmpty;
    return _buildSelectableTile(
      selected: _shareToFeed,
      onTap: () {
        if (!enabled) return;
        setState(() => _shareToFeed = !_shareToFeed);
      },
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          Icons.home_outlined,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: 'Семье — в ленту',
      subtitle: 'Все увидят на главной, фото попадёт в «Все фото»',
    );
  }

  Widget _buildLoadingTargets(String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectableTile({
    required bool selected,
    required VoidCallback onTap,
    required String title,
    String? subtitle,
    Widget? leading,
  }) {
    final theme = Theme.of(context);
    final bg = selected ? theme.colorScheme.primaryContainer : Colors.transparent;
    final fg = selected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final subFg = selected
        ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8)
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: bg,
      child: ListTile(
        leading: leading,
        title: Text(
          title,
          style: TextStyle(
            color: fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(color: subFg),
              ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildGalleryToolbar() {
    final busy = _creatingAlbum;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _albumSearchController,
                enabled: !busy,
                textInputAction: TextInputAction.search,
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Поиск альбома',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (value) =>
                    setState(() => _albumSearchQuery = value.trim().toLowerCase()),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Новый альбом',
            onPressed: _myUserId == null || _sending || busy ? null : _createAlbum,
            icon: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildTargetsList() {
    if (_tabIndex == 0) {
      if (_loadingThreads) return _buildLoadingTargets('Загрузка чатов...');
      if (_threads.isEmpty) {
        return const Center(child: Text('Нет доступных чатов'));
      }
      return ListView.builder(
        itemCount: _threads.length,
        itemBuilder: (_, i) {
          final t = _threads[i];
          final id = chatAsInt(t['id']);
          if (id == null) return const SizedBox.shrink();
          final selected = _selectedThreads.contains(id);
          return _buildSelectableTile(
            selected: selected,
            onTap: () {
              setState(() {
                if (selected) {
                  _selectedThreads.remove(id);
                } else {
                  _selectedThreads.add(id);
                }
              });
            },
            leading: ChatAvatar(
              name: _threadTitle(t),
              avatarUrl: _threadAvatarUrl(t),
              userId: _dmPeerUserId(t),
              radius: 24,
            ),
            title: _threadTitle(t),
            subtitle: _threadSubtitle(t),
          );
        },
      );
    }
    if (_loadingAlbums && _albums.isEmpty) {
      return _buildLoadingTargets('Загрузка альбомов...');
    }
    final albums = _filteredAlbums;
    if (albums.isEmpty) {
      final message = _albumSearchQuery.isNotEmpty
          ? 'Ничего не найдено'
          : 'Нет доступных альбомов';
      return Center(child: Text(message));
    }
    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (_, i) {
        final a = albums[i];
        final pk = _albumPk(a);
        if (pk == null) return const SizedBox.shrink();
        final selected = _selectedAlbumPks.contains(pk);
        return _buildSelectableTile(
          selected: selected,
          onTap: () {
            setState(() {
              if (selected) {
                _selectedAlbumPks.remove(pk);
              } else {
                _selectedAlbumPks.add(pk);
              }
            });
          },
          title: a['title']?.toString() ?? 'Альбом',
          subtitle: '${a['count'] ?? 0} фото',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = _captionController.text.trim();
    final hasPayload = caption.isNotEmpty || _attachments.isNotEmpty;

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Поделиться',
        actions: [
          TextButton(
            onPressed: _hasSelectableTargets ? _toggleSelectAllTargets : null,
            child: Text(_allTargetsSelected ? 'Снять все' : 'Выбрать все'),
          ),
          TextButton(
            onPressed: !_canSend || _sending || _creatingAlbum ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_sendButtonLabel),
          ),
        ],
      ),
      body: _loadingAttachments
          ? const DeferredPlaceholder(
              child: Center(child: CircularProgressIndicator()),
            )
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
                                maxLength: _shareToFeed
                                    ? FeedPostUploader.maxCaptionLength
                                    : null,
                                decoration: InputDecoration(
                                  labelText: _shareToFeed
                                      ? 'Описание для ленты'
                                      : 'Подпись',
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                        ),
                        if (_imageAttachments.isNotEmpty) ...[
                          const Divider(height: 1),
                          _buildFeedShareTile(),
                        ],
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: SegmentedButton<int>(
                            showSelectedIcon: false,
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
                        if (_tabIndex == 1) _buildGalleryToolbar(),
                        Expanded(
                          child: _tabIndex == 1 && _creatingAlbum
                              ? _buildLoadingTargets('Создание альбома...')
                              : _buildTargetsList(),
                        ),
                      ],
                    ),
    );
  }
}
