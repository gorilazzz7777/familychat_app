import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/gallery_media_export.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/zoom_aware_page_view.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import '../../feed/presentation/widgets/feed_reactions.dart';
import 'face_tagging_sheet.dart';
import 'media_engagement_inline.dart';
import 'photo_slideshow_screen.dart';
import 'widgets/photo_people_on_photo_bar.dart';

/// Полноэкранный просмотр фото из галереи с меню действий.
class GalleryPhotoViewerScreen extends ConsumerStatefulWidget {
  const GalleryPhotoViewerScreen({
    super.key,
    required this.profileUserId,
    required this.photo,
    required this.currentUserId,
    this.photos,
    this.initialIndex = 0,
    this.onChanged,
  });

  final int profileUserId;
  final Map<String, dynamic> photo;
  final int currentUserId;
  final List<Map<String, dynamic>>? photos;
  final int initialIndex;
  final VoidCallback? onChanged;

  static Future<void> open(
    BuildContext context, {
    required int profileUserId,
    required Map<String, dynamic> photo,
    required int currentUserId,
    List<Map<String, dynamic>>? photos,
    int initialIndex = 0,
    VoidCallback? onChanged,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ProviderScope(
          parent: ProviderScope.containerOf(context),
          child: GalleryPhotoViewerScreen(
            profileUserId: profileUserId,
            photo: photo,
            currentUserId: currentUserId,
            photos: photos,
            initialIndex: initialIndex,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<GalleryPhotoViewerScreen> createState() =>
      _GalleryPhotoViewerScreenState();
}

class _GalleryPhotoViewerScreenState
    extends ConsumerState<GalleryPhotoViewerScreen> {
  late final List<Map<String, dynamic>> _photos;
  late int _index;
  late final PageController _pageController;
  final _zoomPageKey = GlobalKey<ZoomAwarePageViewState>();
  bool _commentsExpanded = false;
  bool _reactBusy = false;
  int? _highlightUserId;
  List<PhotoFaceBox> _highlightBoxes = const [];

  @override
  void initState() {
    super.initState();
    // Копия: альбом может мутировать свой список пока открыт просмотрщик.
    final source = (widget.photos == null || widget.photos!.isEmpty)
        ? <Map<String, dynamic>>[Map<String, dynamic>.from(widget.photo)]
        : widget.photos!
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
    _photos = source.isEmpty
        ? <Map<String, dynamic>>[Map<String, dynamic>.from(widget.photo)]
        : source;
    _index = widget.initialIndex.clamp(0, _photos.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _photo {
    if (_photos.isEmpty) return widget.photo;
    final i = _index.clamp(0, _photos.length - 1);
    return _photos[i];
  }

  bool get _isVideo => isVideoAttachment(_photo);

  int get _commentsCount {
    final raw = _photo['comments_count'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  int get _reactionsCount {
    final raw = _photo['reactions_count'] ?? _photo['likes_count'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  String get _myReaction => _photo['my_reaction']?.toString() ?? '';

  Future<void> _openReactionPicker() async {
    final attachmentId = _attachmentId;
    if (attachmentId == null || _reactBusy || _photos.isEmpty) return;
    final emoji = await showFeedReactionPicker(context);
    if (emoji == null || emoji.isEmpty || !mounted) return;
    final index = _index.clamp(0, _photos.length - 1);
    setState(() => _reactBusy = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .toggleMediaReaction(attachmentId, emoji: emoji);
      if (!mounted) return;
      if (index >= _photos.length) return;
      final reactions = parseMediaReactions(data['reactions']);
      final total = reactions.fold<int>(
        0,
        (sum, r) => sum + ((r['count'] as int?) ?? 0),
      );
      setState(() {
        _photos[index] = {
          ..._photos[index],
          'reactions': reactions,
          'reactions_count': total,
          'my_reaction': data['my_reaction']?.toString() ?? '',
          'liked_by_me': data['liked_by_me'] == true,
          'likes_count': data['likes_count'] is int
              ? data['likes_count'] as int
              : int.tryParse('${data['likes_count']}') ?? 0,
        };
        _reactBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _reactBusy = false);
    }
  }

  int? get _attachmentId {
    final photo = _photo;
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  int? get _threadId {
    final photo = _photo;
    final id = photo['thread_id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  int? get _uploadedByUserId {
    final photo = _photo;
    final id = photo['uploaded_by_user_id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  bool get _isOwnGallery => widget.profileUserId == widget.currentUserId;
  bool get _isOwnUpload => _uploadedByUserId == widget.currentUserId;

  Future<void> _openFaceTagging(BuildContext context, WidgetRef ref) async {
    final threadId = _threadId;
    final attachmentId = _attachmentId;
    if (threadId == null || attachmentId == null) return;
    await FaceTaggingSheet.show(
      context,
      threadId: threadId,
      attachmentId: attachmentId,
      profileUserId: widget.profileUserId,
      imageChild: ChatNetworkImage(
        threadId: threadId,
        attachment: _photo,
        fit: BoxFit.contain,
      ),
    );
    widget.onChanged?.call();
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final attachmentId = _attachmentId;
    final threadId = _threadId;
    if (attachmentId == null || threadId == null) return;

    final isPhysical = _isOwnUpload;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isPhysical ? 'Удалить фото?' : 'Убрать из моей галереи?'),
        content: Text(
          isPhysical
              ? 'Фото будет удалено из чата для всех.'
              : 'Фото останется у других участников, но исчезнет из всех ваших альбомов.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isPhysical ? 'Удалить' : 'Убрать'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    try {
      final repo = ref.read(familychatRepositoryProvider);
      if (isPhysical) {
        await MediaIncomingSync.deleteFromPhone(_photo);
        await repo.deleteChatAttachment(threadId, attachmentId);
      } else {
        await repo.hideGalleryPhoto(attachmentId);
      }
      if (!context.mounted) return;
      Navigator.pop(context);
      widget.onChanged?.call();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _shareCurrent(BuildContext context) async {
    final photo = _photo;
    final threadId = _threadId;
    final attachmentId = _attachmentId;
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await GalleryMediaExport.shareAttachments(
        attachments: [photo],
        fetchBytes: threadId == null || attachmentId == null
            ? null
            : (_) => ref
                .read(familychatRepositoryProvider)
                .fetchChatAttachmentBytes(threadId, attachmentId),
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось поделиться: $e')),
      );
    }
  }

  Future<void> _downloadCurrent(BuildContext context) async {
    final photo = _photo;
    final threadId = _threadId;
    final attachmentId = _attachmentId;
    try {
      await MediaIncomingSync.saveByUserDownload(
        photo,
        fetchBytes: threadId == null || attachmentId == null
            ? null
            : () => ref
                .read(familychatRepositoryProvider)
                .fetchChatAttachmentBytes(threadId, attachmentId),
      );
      if (mounted) setState(() {});
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Сохранено в галерею («${GalleryMediaExport.appAlbumName}»)',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось скачать: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final threadId = _threadId;
    final attachmentId = _attachmentId;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: FamilyAppBar.build(
        title: _isVideo ? 'Видео' : 'Фото',
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_photos.length - _index >= 2)
            IconButton(
              tooltip: 'Диафильм',
              onPressed: () {
                PhotoSlideshowScreen.open(
                  context,
                  photos: _photos,
                  startIndex: _index,
                );
              },
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          if (attachmentId != null)
            IconButton(
              tooltip: 'Поделиться',
              onPressed: () => _shareCurrent(context),
              icon: const Icon(Icons.share),
            ),
          if (threadId != null && attachmentId != null && !_isVideo)
            IconButton(
              tooltip: 'Кто на фото',
              onPressed: () => _openFaceTagging(context, ref),
              icon: const Icon(Icons.face_outlined),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              switch (value) {
                case 'faces':
                  await _openFaceTagging(context, ref);
                case 'delete':
                  if (_isOwnGallery || _isOwnUpload) {
                    await _confirmDelete(context, ref);
                  }
                case 'download':
                  await _downloadCurrent(context);
              }
            },
            itemBuilder: (context) => [
              if (!_isVideo)
                const PopupMenuItem(
                    value: 'faces', child: Text('Указать, кто на фото')),
              if (_isOwnGallery && !_isOwnUpload)
                const PopupMenuItem(
                    value: 'delete', child: Text('Убрать из моей галереи')),
              if (_isOwnUpload)
                const PopupMenuItem(
                    value: 'delete', child: Text('Удалить фото')),
              const PopupMenuItem(
                  value: 'download', child: Text('Скачать')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: ZoomAwarePageView(
              key: _zoomPageKey,
              controller: _pageController,
              onPageChanged: (i) => setState(() {
                _index = i;
                _commentsExpanded = false;
                _highlightUserId = null;
                _highlightBoxes = const [];
              }),
              itemCount: _photos.length,
              itemBuilder: (_, i) {
                final p = _photos[i];
                final tid = p['thread_id'];
                if (tid is! int) {
                  return const Icon(Icons.broken_image_outlined,
                      color: Colors.white54, size: 48);
                }
                final showHighlight =
                    i == _index && _highlightBoxes.isNotEmpty;
                return Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ScaleReportingInteractiveViewer(
                            minScale: 0.8,
                            maxScale: 5,
                            constrained: false,
                            clipBehavior: Clip.none,
                            onScaleChanged: i == _index
                                ? (scale) =>
                                    _zoomPageKey.currentState?.reportScale(scale)
                                : null,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                              child: ChatNetworkImage(
                                threadId: tid,
                                attachment: p,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          if (showHighlight)
                            PhotoFaceHighlightOverlay(boxes: _highlightBoxes),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (attachmentId != null)
            SafeArea(
              top: false,
              bottom: false,
              child: Container(
                color: Colors.grey.shade900,
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: () =>
                            setState(() => _commentsExpanded = !_commentsExpanded),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 8, 10),
                          child: Row(
                            children: [
                              Icon(
                                _commentsExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_up,
                                size: 18,
                                color: Colors.white70,
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 24, minHeight: 24),
                                tooltip: 'Реакция',
                                onPressed:
                                    _reactBusy ? null : _openReactionPicker,
                                icon: _myReaction.isNotEmpty
                                    ? Text(
                                        _myReaction,
                                        style: const TextStyle(fontSize: 16),
                                      )
                                    : const Icon(
                                        Icons.add_reaction_outlined,
                                        size: 18,
                                        color: Colors.white70,
                                      ),
                              ),
                              SizedBox(
                                width: 36,
                                child: _reactionsCount > 0
                                    ? Text(
                                        '$_reactionsCount',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Комментарии ($_commentsCount)',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 110,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    _commentsExpanded ? 'Свернуть' : 'Развернуть',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_commentsExpanded)
                        const Divider(height: 1, color: Colors.white12),
                      if (_commentsExpanded)
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.30,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: MediaEngagementInline(
                              key: ValueKey<int>(attachmentId),
                              attachmentId: attachmentId,
                              onDarkBackground: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (attachmentId != null)
            SafeArea(
              top: false,
              child: PhotoPeopleOnPhotoBar(
                key: ValueKey<int>(attachmentId),
                attachmentId: attachmentId,
                profileUserId: widget.profileUserId,
                threadId: threadId,
                selectedUserId: _highlightUserId,
                onHighlightChanged: (highlight) {
                  setState(() {
                    if (highlight == null) {
                      _highlightUserId = null;
                      _highlightBoxes = const [];
                    } else {
                      _highlightUserId = highlight.userId;
                      _highlightBoxes = highlight.boxes;
                    }
                  });
                },
              ),
            ),
        ],
      ),
    );
  }
}
