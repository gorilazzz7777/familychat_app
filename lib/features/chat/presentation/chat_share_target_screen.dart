import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../../../core/media/local_device_file.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/widgets/family_compose_input.dart';
import '../../../core/widgets/family_tab_bar.dart';
import '../../../app/shell_refresh.dart';
import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/push/push_navigation.dart';
import '../../../core/push/push_message_handler.dart';
import '../../../core/local_db/chat_local_store.dart';
import 'chat_conversation_screen.dart';
import '../../../core/feed/feed_photo_batch_session.dart';
import '../../profile/data/album_upload_coordinator.dart';
import '../../profile/presentation/custom_album_dialog.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';
import '../data/chat_realtime_utils.dart';
import '../data/share_attachment_loader.dart';
import '../data/share_chat_send_coordinator.dart';
import 'widgets/chat_link_preview_mini.dart';
import 'widgets/chat_mention_text.dart';
import 'widgets/chat_thread_select_tile.dart';

/// Выбор чата для отправки контента из системного «Поделиться».
class ChatShareTargetScreen extends ConsumerStatefulWidget {
  const ChatShareTargetScreen({super.key, required this.media});

  final SharedMedia media;

  @override
  ConsumerState<ChatShareTargetScreen> createState() => _ChatShareTargetScreenState();
}

class _ChatShareTargetScreenState extends ConsumerState<ChatShareTargetScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _threads = [];
  List<Map<String, dynamic>> _albums = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  final _selectedThreads = <int>{};
  final _selectedAlbumPks = <int>{};
  bool _loadingAttachments = true;
  bool _loadingThreads = true;
  bool _loadingAlbums = true;
  bool _creatingAlbum = false;
  bool _sending = false;
  String? _loadError;
  int? _myUserId;
  late final TabController _tabController;
  late final TextEditingController _captionController;
  late final TextEditingController _albumSearchController;
  String _albumSearchQuery = '';
  List<ShareAttachmentData> _attachments = const [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _captionController = TextEditingController(text: widget.media.content ?? '');
    _captionController.addListener(_onCaptionChanged);
    _albumSearchController = TextEditingController();
    // Цели (чаты) — сразу из локальной БД; вложения и сеть не блокируют список.
    unawaited(_hydrateTargetsFromLocal());
    unawaited(_loadAttachments());
    unawaited(_refreshTargetsFromNetwork());
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _captionController.removeListener(_onCaptionChanged);
    _captionController.dispose();
    _albumSearchController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    setState(() {});
  }

  void _onCaptionChanged() {
    if (mounted) setState(() {});
  }

  int get _tabIndex => _tabController.index;

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

  void _applyMembers(List<Map<String, dynamic>> members) {
    final byUserId = <int, Map<String, dynamic>>{};
    for (final member in members) {
      final uid = member['user_id'];
      final userId = uid is int ? uid : int.tryParse('$uid');
      if (userId == null) continue;
      byUserId[userId] = member;
    }
    _memberByUserId
      ..clear()
      ..addAll(byUserId);
  }

  void _applyStatusMap(Map<String, dynamic> status) {
    final raw = status['user_id'];
    _myUserId = raw is int ? raw : int.tryParse('$raw');
  }

  /// Быстрый путь: SQLite (+ JSON-кэш) без сети.
  Future<void> _hydrateTargetsFromLocal() async {
    try {
      final cachedStatus = await FamilyChatLocalCache.readStatus();
      if (cachedStatus != null && mounted) {
        setState(() => _applyStatusMap(cachedStatus));
      }

      var threads = <Map<String, dynamic>>[];
      var members = <Map<String, dynamic>>[];

      if (ChatLocalStore.isSupported) {
        final results = await Future.wait([
          ChatLocalStore.instance.readThreads(),
          ChatLocalStore.instance.readMembers(),
        ]);
        threads = results[0];
        members = results[1];
      }

      if (threads.isEmpty) {
        final cachedThreads = await FamilyChatLocalCache.readChatThreads();
        if (cachedThreads != null && cachedThreads.isNotEmpty) {
          threads = cachedThreads;
        }
      }
      if (members.isEmpty) {
        final cachedMembers = await FamilyChatLocalCache.readChatMembers();
        if (cachedMembers != null && cachedMembers.isNotEmpty) {
          members = cachedMembers;
        }
      }

      if (!mounted) return;
      if (threads.isNotEmpty || members.isNotEmpty) {
        setState(() {
          if (threads.isNotEmpty) {
            _threads = threads;
            _loadingThreads = false;
          }
          if (members.isNotEmpty) _applyMembers(members);
        });
      }

      final myUserId = _myUserId;
      if (myUserId != null) {
        final cachedAlbums =
            await FamilyChatLocalCache.readMemberAlbums(myUserId);
        if (cachedAlbums != null && mounted) {
          setState(() {
            _albums = _parseCustomAlbums(cachedAlbums);
            _loadingAlbums = false;
          });
        }
      }
    } catch (_) {
      // Сеть/ошибка ниже; UI может остаться в loading до refresh.
    }
  }

  Future<void> _loadAttachments() async {
    try {
      final attachments = await readShareAttachments(widget.media);
      if (!mounted) return;
      setState(() {
        _attachments = attachments;
        _loadingAttachments = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Не удалось подготовить вложения';
        _loadingAttachments = false;
      });
    }
  }

  Future<void> _refreshTargetsFromNetwork() async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      // Не блокируем UI: status + threads параллельно.
      final statusFuture = repo.status();
      final threadsFuture = Future.wait<dynamic>([
        repo.chatThreads(),
        repo.members(),
      ]);

      final status = await statusFuture;
      if (!mounted) return;
      setState(() => _applyStatusMap(status));
      unawaited(FamilyChatLocalCache.saveStatus(status));

      final myUserId = _myUserId;
      final albumsFuture = myUserId == null
          ? Future<void>.value()
          : _loadAlbums(repo, myUserId);

      final results = await threadsFuture;
      final list = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();

      await FamilyChatLocalCache.saveChatThreads(list);
      await FamilyChatLocalCache.saveChatMembers(members);
      if (ChatLocalStore.isSupported) {
        await ChatLocalStore.instance.replaceThreads(list);
        await ChatLocalStore.instance.replaceMembers(members);
      }

      if (!mounted) return;
      setState(() {
        _threads = list;
        _applyMembers(members);
        _loadingThreads = false;
      });

      await albumsFuture;
      if (mounted && _loadingAlbums) {
        setState(() => _loadingAlbums = false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // Локальный список уже мог показаться — не затираем ошибкой весь экран.
        if (_threads.isEmpty) {
          _loadError ??= 'Не удалось загрузить чаты';
        }
        _loadingThreads = false;
        _loadingAlbums = false;
      });
    }
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
            setState(() {
              _albums = albums;
              _loadingAlbums = false;
            });
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

  bool get _canSendChats {
    if (_selectedThreads.isEmpty) return false;
    return _captionController.text.trim().isNotEmpty || _attachments.isNotEmpty;
  }

  bool get _canSendAlbums {
    return _selectedAlbumPks.isNotEmpty && _imageAttachments.isNotEmpty;
  }

  bool get _canSend => _tabIndex == 0 ? _canSendChats : _canSendAlbums;

  List<ShareAttachmentData> get _imageAttachments =>
      _attachments.where((a) => a.isImage).toList();

  Map<String, dynamic>? _albumByPk(int pk) {
    for (final album in _albums) {
      final idStr = album['id']?.toString() ?? '';
      if (idStr == 'custom:$pk') return album;
    }
    return null;
  }

  Future<void> _send() async {
    if (!_canSend || _sending) return;
    setState(() => _sending = true);

    final caption = _captionController.text.trim();
    final repo = ref.read(familychatRepositoryProvider);
    final threadIds = _tabIndex == 0 ? _selectedThreads.toList() : <int>[];
    final albumPks = _tabIndex == 1 ? _selectedAlbumPks.toList() : <int>[];
    final pending = List<ShareAttachmentData>.from(_attachments);
    final myUserId = _myUserId;
    final openThreadId = threadIds.isNotEmpty ? threadIds.first : null;
    Map<String, dynamic>? openThread;
    if (openThreadId != null) {
      for (final t in _threads) {
        if (chatAsInt(t['id']) == openThreadId) {
          openThread = t;
          break;
        }
      }
    }
    int? openAlbumPk;
    var openAlbumTitle = 'Альбом';
    final albumTitles = <int, String>{};
    if (albumPks.isNotEmpty) {
      openAlbumPk = albumPks.first;
      for (final pk in albumPks) {
        albumTitles[pk] = _albumByPk(pk)?['title']?.toString() ?? 'Альбом';
      }
      openAlbumTitle = albumTitles[openAlbumPk] ?? 'Альбом';
    }

    final messenger = familyChatScaffoldMessengerKey.currentState;
    final nav = familyChatNavigatorKey.currentState;
    final shareNav = Navigator.of(context);

    final pendingByThread =
        <int, ({int tempId, List<Map<String, dynamic>> atts})>{};
    if (threadIds.isNotEmpty) {
      final optimisticAtts =
          ShareChatSendCoordinator.buildPendingAttachments(pending);
      for (final threadId in threadIds) {
        final tempId = ShareChatSendCoordinator.nextTempId();
        final message = ShareChatSendCoordinator.buildPendingMessage(
          threadId: threadId,
          tempId: tempId,
          senderUserId: myUserId,
          caption: caption,
          attachments: optimisticAtts,
        );
        await ShareChatSendCoordinator.seedPendingMessage(message);
        pendingByThread[threadId] = (tempId: tempId, atts: optimisticAtts);
      }
    }

    if (!mounted) return;
    shareNav.pop(true);

    unawaited(() async {
      try {
        if (threadIds.isNotEmpty) {
          for (final threadId in threadIds) {
            final seeded = pendingByThread[threadId];
            if (seeded == null) continue;
            try {
              await ShareChatSendCoordinator.deliver(
                repo: repo,
                threadId: threadId,
                tempId: seeded.tempId,
                caption: caption,
                pendingAttachments: pending,
                optimisticAttachmentMaps: seeded.atts,
              );
            } catch (_) {
              await ShareChatSendCoordinator.markPendingFailed(
                threadId: threadId,
                tempId: seeded.tempId,
              );
              rethrow;
            }
          }
        }

        if (albumPks.isNotEmpty && myUserId != null) {
          final resolved = await _resolveList(pending);
          final resolvedImages = resolved.where((a) => a.isImage).toList();
          if (resolvedImages.isNotEmpty) {
            final photos = resolvedImages
                .map(
                  (att) => AlbumUploadPhoto(
                    bytes: Uint8List.fromList(att.bytes),
                    filename: att.filename,
                    contentType: att.contentType ?? 'image/jpeg',
                    localPath: att.localPath,
                  ),
                )
                .toList();
            final batch = FeedPhotoBatchSession(
              totalTasks: albumPks.length * photos.length,
            );
            for (final albumPk in albumPks) {
              AlbumUploadCoordinator.instance.startUploadToCustomAlbum(
                repo: repo,
                userId: myUserId,
                albumPk: albumPk,
                albumId: 'custom:$albumPk',
                title: albumTitles[albumPk] ?? 'Альбом',
                photos: photos,
                batchSession: batch,
              );
            }
          }
        } else if (threadIds.isNotEmpty) {
          await finishShareAttachmentRead();
        }

        await ShellRefresh.instance.refreshMainTabs();
      } catch (_) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Не удалось отправить')),
        );
      }
    }());

    if (openAlbumPk != null && myUserId != null && nav != null) {
      await nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ProfileGalleryAlbumScreen(
            userId: myUserId,
            albumId: 'custom:$openAlbumPk',
            title: openAlbumTitle,
            canManage: true,
            isOwnGallery: true,
          ),
        ),
      );
      return;
    }
    if (openThreadId != null && nav != null) {
      await nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatConversationScreen(
            threadId: openThreadId,
            title: openThread?['title']?.toString() ?? 'Чат',
            defaultTitle: openThread?['default_title']?.toString() ??
                openThread?['title']?.toString() ??
                'Чат',
            customTitle: openThread?['custom_title']?.toString() ?? '',
            kind: openThread?['kind']?.toString() ?? 'family',
            peerUserId: chatAsInt(openThread?['peer_user_id']),
            initialPeerAvatarUrl: openThread?['peer_avatar_url']?.toString(),
            initialCanSend: openThread?['can_send'] != false,
          ),
        ),
      );
      return;
    }
    messenger?.showSnackBar(
      const SnackBar(content: Text('Отправляем…')),
    );
  }

  Future<List<ShareAttachmentData>> _resolveList(
    List<ShareAttachmentData> items,
  ) async {
    final out = <ShareAttachmentData>[];
    for (var i = 0; i < items.length; i++) {
      out.add(await resolveShareAttachmentBytes(items[i], index: i));
    }
    await finishShareAttachmentRead();
    return out;
  }

  List<Map<String, dynamic>> get _filteredAlbums {
    if (_albumSearchQuery.isEmpty) return _albums;
    return _albums
        .where((a) =>
            (a['title']?.toString().toLowerCase() ?? '').contains(_albumSearchQuery))
        .toList();
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

  Widget _buildChatsList() {
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
        return ChatThreadSelectTile(
          thread: t,
          selected: selected,
          memberByUserId: _memberByUserId,
          onTap: () {
            setState(() {
              if (selected) {
                _selectedThreads.remove(id);
              } else {
                _selectedThreads.add(id);
              }
            });
          },
        );
      },
    );
  }

  Widget _buildAlbumsList() {
    if (_creatingAlbum) return _buildLoadingTargets('Создание альбома...');
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

  Widget _buildAttachmentThumb(ShareAttachmentData att) {
    if (att.isImage || att.isVideo) {
      final path = att.localPath;
      final child = path != null && localDeviceFileExists(path)
          ? localDeviceFileImage(
              path: path,
              width: 72,
              height: 72,
              fit: BoxFit.cover,
            )
          : ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(
                att.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
              ),
            );
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 72,
          height: 72,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (att.isVideo)
                const ColoredBox(
                  color: Color(0x33000000),
                  child: Icon(Icons.play_circle_outline, color: Colors.white),
                ),
            ],
          ),
        ),
      );
    }
    return Container(
      width: 72,
      height: 72,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 22),
          const SizedBox(height: 4),
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
  }

  Widget _buildChatCompose() {
    final shareUrl = ChatMentionText.firstUrl(_captionController.text);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loadingAttachments)
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: LinearProgressIndicator(),
                )
              else if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: SizedBox(
                    height: 72,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attachments.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => _buildAttachmentThumb(_attachments[i]),
                    ),
                  ),
                ),
              FamilyComposeInput(
                controller: _captionController,
                hintText: 'Сообщение...',
                sending: _sending,
                header: shareUrl == null
                    ? null
                    : ChatLinkPreviewMini(url: shareUrl),
                onSend: !_canSendChats || _sending || _creatingAlbum
                    ? null
                    : () {
                        unawaited(_send());
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumSendBar() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: FilledButton(
            onPressed: !_canSendAlbums || _sending || _creatingAlbum
                ? null
                : () => unawaited(_send()),
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _selectedAlbumPks.length == 1
                        ? 'Отправить в альбом'
                        : 'Отправить в ${_selectedAlbumPks.length} альб.',
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = _captionController.text.trim();
    final hasPayload = caption.isNotEmpty || _attachments.isNotEmpty;
    final showTargets = _loadError == null &&
        (_loadingAttachments || hasPayload || _threads.isNotEmpty);
    final showChatCompose = _tabIndex == 0 && _selectedThreads.isNotEmpty;
    final showAlbumSend = _tabIndex == 1 && _selectedAlbumPks.isNotEmpty;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Поделиться'),
      body: _loadError != null && _threads.isEmpty && !_loadingAttachments
          ? Center(child: Text(_loadError!))
          : !showTargets
              ? const Center(child: Text('Нет данных для отправки'))
              : Column(
                  children: [
                    FamilyTabBar.build(
                      controller: _tabController,
                      tabs: const [
                        Tab(text: 'Чаты'),
                        Tab(text: 'Галерея'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildChatsList(),
                          Column(
                            children: [
                              _buildGalleryToolbar(),
                              Expanded(child: _buildAlbumsList()),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (showChatCompose) _buildChatCompose(),
                    if (showAlbumSend) _buildAlbumSendBar(),
                  ],
                ),
    );
  }
}
