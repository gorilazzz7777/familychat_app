import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_image_viewer.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import 'face_tagging_sheet.dart';
import 'media_engagement_inline.dart';
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
  ConsumerState<GalleryPhotoViewerScreen> createState() => _GalleryPhotoViewerScreenState();
}

class _GalleryPhotoViewerScreenState extends ConsumerState<GalleryPhotoViewerScreen> {
  late final List<Map<String, dynamic>> _photos;
  late int _index;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _photos = (widget.photos == null || widget.photos!.isEmpty) ? [widget.photo] : widget.photos!;
    _index = widget.initialIndex.clamp(0, _photos.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _photo => _photos[_index];

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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
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

  Future<void> _openShare(BuildContext context, WidgetRef ref) async {
    final threadId = _threadId;
    final attachmentId = _attachmentId;
    if (threadId == null || attachmentId == null) return;
    final repo = ref.read(familychatRepositoryProvider);
    final url = chatAttachmentImageUrl(
      repo: repo,
      threadId: threadId,
      attachment: _photo,
    );
    await ChatImageViewer.open(
      context,
      imageUrl: url,
      threadId: threadId,
      attachmentId: attachmentId,
      filename: _photo['filename']?.toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final threadId = _threadId;
    final attachmentId = _attachmentId;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (threadId != null && attachmentId != null)
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
                case 'share':
                  await _openShare(context, ref);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'faces', child: Text('Указать, кто на фото')),
              if (_isOwnGallery && !_isOwnUpload)
                const PopupMenuItem(value: 'delete', child: Text('Убрать из моей галереи')),
              if (_isOwnUpload)
                const PopupMenuItem(value: 'delete', child: Text('Удалить фото')),
              const PopupMenuItem(value: 'share', child: Text('Поделиться / скачать')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _index = i),
              itemCount: _photos.length,
              itemBuilder: (_, i) {
                final p = _photos[i];
                final tid = p['thread_id'];
                if (tid is! int) {
                  return const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48);
                }
                return Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) => InteractiveViewer(
                      minScale: 0.2,
                      maxScale: 5,
                      constrained: false,
                      clipBehavior: Clip.none,
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
                  ),
                );
              },
            ),
          ),
          if (attachmentId != null)
            Expanded(
              flex: 2,
              child: ColoredBox(
                color: Colors.grey.shade900,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: MediaEngagementInline(
                    key: ValueKey<int>(attachmentId),
                    attachmentId: attachmentId,
                    onDarkBackground: true,
                  ),
                ),
              ),
            ),
          if (attachmentId != null)
            PhotoPeopleOnPhotoBar(
              key: ValueKey<int>(attachmentId),
              attachmentId: attachmentId,
              profileUserId: widget.profileUserId,
              threadId: threadId,
            ),
        ],
      ),
    );
  }
}
