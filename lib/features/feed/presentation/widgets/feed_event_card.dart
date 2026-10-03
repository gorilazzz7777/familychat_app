import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/i18n/gender_verbs.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/rustore_review_prompt_service.dart';
import '../../../profile/presentation/photo_slideshow_screen.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
import 'feed_birthday_event_card.dart';
import 'feed_holiday_event_card.dart';
import 'feed_event_action_bar.dart';
import 'feed_expandable_caption.dart';
import 'feed_event_media_block.dart';
import '../feed_jank_log.dart';
import '../feed_scroll_busy.dart';
import 'feed_reactions.dart';
import 'feed_viewed_by_row.dart';

/// Fraction of the card that must be on-screen to count as a personal view.
const _kFeedViewVisibleFraction = 0.5;

class FeedEventCard extends ConsumerStatefulWidget {
  const FeedEventCard({
    super.key,
    required this.event,
    required this.onOpenSource,
    this.onOpenProfile,
    this.onOpenMedia,
    this.onOpenPhotoBatch,
    this.onEngagementChanged,
    this.onDeleted,
  });

  final Map<String, dynamic> event;
  final VoidCallback onOpenSource;
  final VoidCallback? onOpenProfile;
  final void Function(Map<String, dynamic> photo)? onOpenMedia;
  final void Function(Map<String, dynamic> event, {int initialIndex})? onOpenPhotoBatch;
  final VoidCallback? onEngagementChanged;
  final VoidCallback? onDeleted;

  @override
  ConsumerState<FeedEventCard> createState() => _FeedEventCardState();
}

class _FeedEventCardState extends ConsumerState<FeedEventCard> {
  int _batchIndex = 0;
  List<Map<String, dynamic>> _viewedBy = const [];
  bool _viewMarked = false;
  bool _reactBusy = false;
  /// Avatar + action bar + viewed-by stay light until fling settles.
  bool _showHeavyChrome = true;

  Map<String, dynamic> get _event => widget.event;
  Map<String, dynamic> get _actor => (_event['actor'] as Map<String, dynamic>?) ?? {};
  Map<String, dynamic> get _payload => (_event['payload'] as Map<String, dynamic>?) ?? {};
  String get _kind => _event['kind']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _viewedBy = _parseViewedBy(_event['viewed_by']);
    if (FeedScrollBusy.isFlinging) {
      _showHeavyChrome = false;
      FeedScrollBusy.onIdle(() {
        if (!mounted || _showHeavyChrome) return;
        setState(() => _showHeavyChrome = true);
      });
    }
  }

  @override
  void didUpdateWidget(covariant FeedEventCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event['id'] != widget.event['id']) {
      _viewMarked = false;
      _viewedBy = _parseViewedBy(widget.event['viewed_by']);
      if (FeedScrollBusy.isFlinging && _showHeavyChrome) {
        _showHeavyChrome = false;
        FeedScrollBusy.onIdle(() {
          if (!mounted || _showHeavyChrome) return;
          setState(() => _showHeavyChrome = true);
        });
      }
    }
  }

  List<Map<String, dynamic>> _parseViewedBy(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (_viewMarked || !mounted) return;
    if (info.visibleFraction < _kFeedViewVisibleFraction) return;
    unawaited(_markViewed());
  }

  Future<void> _markViewed() async {
    if (_viewMarked || !mounted) return;
    // Skip network/setState while the feed is flinging.
    if (FeedScrollBusy.isBusy) {
      FeedScrollBusy.onIdle(() {
        if (mounted) unawaited(_markViewed());
      });
      return;
    }
    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_markViewed());
      });
      return;
    }
    final eventId = _event['id'];
    final id = eventId is int ? eventId : int.tryParse('$eventId');
    // Optimistic / локальные id (<0) на сервер не отправляем — URL не матчится.
    if (id == null || id <= 0) return;
    if (_event['_optimistic'] == true) return;
    _viewMarked = true;
    FeedJankLog.log('VIEW_MARK id=$id');
    // Persist locally so the next tab entry rebuilds sections correctly even
    // if the list is still served from cache before the next full fetch.
    widget.event['is_new'] = false;
    try {
      final data =
          await ref.read(familychatRepositoryProvider).markFeedEventViewed(id);
      if (!mounted) return;
      // Engagement UI can wait until the next idle frame after a fling.
      void applyViewed() {
        if (!mounted) return;
        final next = _parseViewedBy(data['viewed_by']);
        if (next.isNotEmpty) {
          _storeViewedBy(next);
        } else {
          widget.onEngagementChanged?.call();
        }
      }

      if (FeedScrollBusy.isBusy) {
        FeedScrollBusy.onIdle(applyViewed);
      } else {
        applyViewed();
      }
    } catch (_) {
      // Keep local is_new=false; retry on next visit via server state.
      widget.onEngagementChanged?.call();
    }
  }

  void _storeViewedBy(List<Map<String, dynamic>> people) {
    widget.event['viewed_by'] = people;
    widget.event['viewed_count'] = people.length;
    void apply() {
      if (!mounted) return;
      setState(() => _viewedBy = people);
      widget.onEngagementChanged?.call();
    }

    if (FeedScrollBusy.isBusy) {
      FeedScrollBusy.onIdle(apply);
    } else {
      apply();
    }
  }

  Widget _withViewTracking(Widget child) {
    final id = _eventId;
    return VisibilityDetector(
      key: Key('feed_view_${id ?? identityHashCode(_event)}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: child,
    );
  }

  int? get _eventId {
    final raw = _event['id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  bool get _isBirthdayEvent =>
      _kind == 'calendar_event' && _payload['event_kind']?.toString() == 'birthday';

  bool get _isHolidayEvent =>
      _kind == 'calendar_event' && _payload['event_kind']?.toString() == 'holiday';

  bool get _isMilestoneEvent =>
      _kind == 'calendar_event' && _payload['event_kind']?.toString() == 'milestone';

  bool get _tracksMediaCarousel =>
      _kind == 'photo_batch_uploaded' || _isMilestoneEvent;

  String _honoreeName() {
    final fromPayload = _payload['person_name']?.toString().trim();
    if (fromPayload != null && fromPayload.isNotEmpty) return fromPayload;
    final title = _payload['title']?.toString() ?? '';
    final parts = title.split('—');
    if (parts.length > 1) return parts.last.trim();
    return _actor['name']?.toString() ?? 'Именинник';
  }

  Map<String, dynamic> get _displayActor {
    final childId = _payload['child_id'];
    if (childId != null) {
      final name = _payload['child_name']?.toString().trim();
      if (name != null && name.isNotEmpty) {
        return {
          'name': name,
          'avatar_url': _payload['child_avatar_url']?.toString(),
          'gender': _payload['child_gender']?.toString() ?? '',
        };
      }
    }
    return _actor;
  }

  String _titleText() {
    final actor = _displayActor;
    final name = actor['name']?.toString() ?? 'Участник';
    if (_kind == 'calendar_event') {
      return _payload['title']?.toString() ?? 'Событие календаря';
    }
    final photoCount = _kind == 'photo_batch_uploaded'
        ? (_payload['photo_count'] is int
            ? _payload['photo_count'] as int
            : int.tryParse('${_payload['photo_count']}') ?? _batchPhotos().length)
        : null;
    final othersRaw = _payload['others_count'];
    final othersCount = othersRaw is int
        ? othersRaw
        : int.tryParse('$othersRaw');
    return feedEventTitle(
      kind: _kind,
      actorName: name,
      gender: actorGender(actor),
      joinedName: _payload['name']?.toString(),
      photoCount: photoCount,
      othersCount: othersCount,
    );
  }

  String _navigateTooltip() {
    if (_isMilestoneEvent) return 'Открыть веху';
    return switch (_kind) {
      'message_sent' => 'Открыть чат',
      'photo_added_to_album' => 'Открыть альбом',
      'photo_batch_uploaded' => 'Открыть альбом',
      'photo_uploaded' => 'Открыть галерею',
      'media_liked' || 'media_commented' => 'Открыть фото',
      'calendar_event' => 'Открыть календарь',
      'member_joined' || 'profile_updated' => 'Открыть профиль',
      _ => 'Перейти',
    };
  }

  String? _captionText() {
    final caption = _payload['caption']?.toString().trim() ?? '';
    if (caption.isEmpty) return null;
    if (_kind == 'photo_uploaded' ||
        _kind == 'photo_added_to_album' ||
        _kind == 'photo_batch_uploaded' ||
        _isMilestoneEvent) {
      return caption;
    }
    return null;
  }

  String? _formatMeasure(dynamic raw, String unit) {
    if (raw == null) return null;
    if (raw is num) {
      final d = raw.toDouble();
      final text = d == d.roundToDouble() ? '${d.toInt()}' : '$d';
      return '$text $unit';
    }
    final text = '$raw'.trim();
    return text.isEmpty ? null : '$text $unit';
  }

  String? get _weightLabel => _formatMeasure(_payload['weight_kg'], 'кг');

  String? get _heightLabel => _formatMeasure(_payload['height_cm'], 'см');

  bool get _hasMilestoneMeta =>
      _weightLabel != null || _heightLabel != null;

  String _bodyPreview() {
    if (_kind == 'message_sent') {
      return _payload['body_preview']?.toString() ?? '';
    }
    if (_kind == 'profile_updated') {
      final fields = (_payload['changed_fields'] as List<dynamic>? ?? []).join(', ');
      return fields.isEmpty ? '' : 'Изменено: $fields';
    }
    return '';
  }

  List<Map<String, dynamic>> _attachments() {
    return (_payload['attachments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  int? _parseThreadId(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value');
  }

  int? _payloadThreadId() => _parseThreadId(_payload['thread_id']);

  bool _isImageAttachment(Map<String, dynamic> att) {
    final local = att['local_bytes'];
    if (local is Uint8List && local.isNotEmpty) return true;
    final kind = att['kind']?.toString();
    if (kind == 'image' || kind == 'video') return true;
    final name = att['filename']?.toString().toLowerCase() ?? '';
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp') ||
        name.endsWith('.heic');
  }

  Map<String, dynamic> _normalizePhoto(Map<String, dynamic> att, {int? threadId}) {
    final tid = _parseThreadId(att['thread_id']) ?? threadId ?? _payloadThreadId();
    final rawId = att['id'] ?? att['attachment_id'];
    final id = rawId is int ? rawId : int.tryParse('$rawId');
    return {
      ...att,
      if (id != null) 'id': id,
      if (tid != null) 'thread_id': tid,
    };
  }

  List<Map<String, dynamic>> _batchPhotos() {
    return _attachments()
        .where(_isImageAttachment)
        .map((att) => _normalizePhoto(att))
        .where((att) =>
            att['local_bytes'] != null ||
            (att['thread_id'] != null && att['id'] != null))
        .toList();
  }

  Map<String, dynamic>? _singlePhoto() {
    final id = _payload['attachment_id'];
    final threadId = _payloadThreadId();
    if (id == null || threadId == null) return null;
    return {
      'id': id is int ? id : int.tryParse('$id'),
      'thread_id': threadId,
      'file_url': _payload['file_url'],
      'filename': _payload['filename'],
    };
  }

  List<Map<String, dynamic>> _displayPhotos() {
    if (_kind == 'photo_batch_uploaded' || _isMilestoneEvent) {
      return _batchPhotos();
    }
    final single = _singlePhoto();
    if (single != null) return [single];

    if (_kind == 'message_sent') {
      final images = _attachments()
          .where(_isImageAttachment)
          .map((att) => _normalizePhoto(att))
          .where((att) => att['thread_id'] != null && att['id'] != null)
          .toList();
      if (images.isNotEmpty) return images;
    }
    return const [];
  }

  int? _attachmentIdForEngagement(Map<String, dynamic>? photo) {
    if (photo == null) return null;
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  int? _currentEngagementAttachmentId(List<Map<String, dynamic>> photos) {
    if (photos.isEmpty) return null;
    final index = _tracksMediaCarousel
        ? _batchIndex.clamp(0, photos.length - 1)
        : 0;
    return _attachmentIdForEngagement(photos[index]);
  }

  void _openPhoto(int index, List<Map<String, dynamic>> photos) {
    if (widget.onOpenPhotoBatch != null &&
        (_kind == 'photo_batch_uploaded' || _isMilestoneEvent)) {
      widget.onOpenPhotoBatch!(widget.event, initialIndex: index);
      return;
    }
    if (photos.isEmpty) return;
    final photo = photos[index.clamp(0, photos.length - 1)];
    widget.onOpenMedia?.call(photo);
  }

  Future<void> _openViewedPeople() {
    return openFeedViewedByPeople(
      context: context,
      ref: ref,
      viewedBy: _viewedBy,
      eventId: _eventId,
      onViewedByChanged: _storeViewedBy,
    );
  }

  Future<void> _openReactionPeople(int? attachmentId) {
    final stored = feedEngagementFromEvent(
      _event,
      attachmentId: attachmentId,
    );
    return openFeedReactionPeople(
      context: context,
      ref: ref,
      reactions: stored.reactions,
      attachmentId: attachmentId,
      commentsCount: stored.commentsCount,
      onEngagementUpdated: ({
        required List<Map<String, dynamic>> reactions,
        required int commentsCount,
      }) {
        if (attachmentId != null) {
          writeFeedEngagementToEvent(
            _event,
            attachmentId: attachmentId,
            reactions: reactions,
            commentsCount: commentsCount,
          );
        }
        widget.onEngagementChanged?.call();
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _toggleReaction(int? attachmentId, String emoji) async {
    if (attachmentId == null || _reactBusy || emoji.trim().isEmpty) return;
    final stored = feedEngagementFromEvent(
      _event,
      attachmentId: attachmentId,
    );
    final previous = [
      for (final r in stored.reactions) Map<String, dynamic>.from(r),
    ];
    final hadMine = mediaReactionsHasMine(previous);
    final optimistic = optimisticToggleMediaReaction(previous, emoji: emoji);
    writeFeedEngagementToEvent(
      _event,
      attachmentId: attachmentId,
      reactions: optimistic,
      commentsCount: stored.commentsCount,
    );
    widget.onEngagementChanged?.call();
    if (mounted) setState(() {});

    _reactBusy = true;
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .toggleMediaReaction(attachmentId, emoji: emoji);
      if (!mounted) return;
      final nextReactions = parseMediaReactions(data['reactions']);
      final commentsCount = data['comments_count'] is int
          ? data['comments_count'] as int
          : int.tryParse('${data['comments_count']}') ?? stored.commentsCount;
      writeFeedEngagementToEvent(
        _event,
        attachmentId: attachmentId,
        reactions: nextReactions,
        commentsCount: commentsCount,
      );
      widget.onEngagementChanged?.call();
      if (mounted) setState(() {});
      if (!hadMine && mediaReactionsHasMine(nextReactions) && mounted) {
        unawaited(
          RuStoreReviewPromptService.onFirstFeedLike(
            context,
            repository: ref.read(familychatRepositoryProvider),
          ),
        );
      }
    } catch (_) {
      writeFeedEngagementToEvent(
        _event,
        attachmentId: attachmentId,
        reactions: previous,
        commentsCount: stored.commentsCount,
      );
      widget.onEngagementChanged?.call();
      if (mounted) setState(() {});
    } finally {
      _reactBusy = false;
    }
  }

  Future<void> _onPostDoubleTap({int? attachmentId}) async {
    if (attachmentId == null) return;
    HapticFeedback.lightImpact();
    await _toggleReaction(attachmentId, kFeedDoubleTapReactionEmoji);
  }

  Future<void> _onPostActionsMenu({int? attachmentId}) async {
    final canReact = attachmentId != null;
    final stored = feedEngagementFromEvent(
      _event,
      attachmentId: attachmentId,
    );
    final hasReactions = mediaReactionsTotalCount(stored.reactions) > 0;

    if (!mounted) return;
    final choice = await showFeedPostActionsSheet(
      context,
      canReact: canReact,
      hasReactions: hasReactions,
      navigateLabel: _navigateTooltip(),
      canDelete: _canDelete,
    );
    if (!mounted || choice == null) return;
    final emoji = choice.reactionEmoji?.trim();
    if (emoji != null && emoji.isNotEmpty) {
      if (attachmentId != null) {
        await _toggleReaction(attachmentId, emoji);
      }
      return;
    }
    switch (choice.action) {
      case 'viewed':
        await _openViewedPeople();
      case 'reactions':
        if (attachmentId != null) {
          await _openReactionPeople(attachmentId);
        }
      case 'navigate':
        widget.onOpenSource();
      case 'delete':
        await _confirmAndDeletePost();
    }
  }

  /// Gestures on post body below media (caption / meta / dead zones).
  /// Short tap & long-press → actions sheet; double-tap → quick ❤️.
  Widget _postBodyGestures({
    required Widget child,
    int? attachmentId,
    bool enableDoubleTap = true,
    bool enableShortTap = true,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enableShortTap
          ? () => _onPostActionsMenu(attachmentId: attachmentId)
          : null,
      onLongPress: () => _onPostActionsMenu(attachmentId: attachmentId),
      onDoubleTap: enableDoubleTap && attachmentId != null
          ? () => _onPostDoubleTap(attachmentId: attachmentId)
          : null,
      child: child,
    );
  }

  bool get _canDelete => _event['can_delete'] == true;

  Future<void> _confirmAndDeletePost() async {
    final eventId = _eventId;
    if (eventId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить пост?'),
        content: const Text(
          'Пост и все фото из него будут удалены из ленты и из всех альбомов.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Удалить',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(familychatRepositoryProvider).deleteFeedEvent(eventId);
      if (!mounted) return;
      widget.onDeleted?.call();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить пост')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final createdAt = DateTime.tryParse(_event['created_at']?.toString() ?? '');

    if (_isBirthdayEvent) {
      return _withViewTracking(
        _postBodyGestures(
          enableDoubleTap: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FeedBirthdayEventCard(
                honoreeName: _honoreeName(),
                honoreeAvatarUrl: _actor['avatar_url']?.toString(),
                eventDate: _payload['date']?.toString(),
                createdAt: createdAt,
                onOpenChat: widget.onOpenSource,
                onOpenProfile: widget.onOpenProfile,
              ),
              FeedViewedByRow(
                viewedBy: _viewedBy,
                eventId: _eventId,
                onViewedByChanged: _storeViewedBy,
              ),
            ],
          ),
        ),
      );
    }

    if (_isHolidayEvent) {
      final description = _payload['description']?.toString().trim() ?? '';
      return _withViewTracking(
        _postBodyGestures(
          enableDoubleTap: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FeedHolidayEventCard(
                title: _payload['title']?.toString() ?? 'Праздник',
                description: description.isNotEmpty
                    ? description
                    : 'Сегодня в семейном календаре отмечен праздник.',
                holidayCode: _payload['code']?.toString() ?? '',
                eventDate: _payload['date']?.toString(),
                createdAt: createdAt,
                onOpenCalendar: widget.onOpenSource,
              ),
              FeedViewedByRow(
                viewedBy: _viewedBy,
                eventId: _eventId,
                onViewedByChanged: _storeViewedBy,
              ),
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final preview = _bodyPreview();
    final caption = _captionText();
    final photos = _displayPhotos();
    final hasMedia = photos.isNotEmpty;
    final engagementAttachmentId = _currentEngagementAttachmentId(photos);

    return _withViewTracking(
      Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: long-press on InkWell (same arena as profile tap).
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onOpenProfile,
                onLongPress: () =>
                    _onPostActionsMenu(attachmentId: engagementAttachmentId),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      ChatAvatar(
                        name: _displayActor['name']?.toString() ?? '?',
                        avatarUrl: _showHeavyChrome
                            ? _displayActor['avatar_url']?.toString()
                            : null,
                        radius: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _titleText(),
                          style: theme.textTheme.titleSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (preview.isNotEmpty)
              _postBodyGestures(
                attachmentId: engagementAttachmentId,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(
                    preview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            if (hasMedia)
              FeedEventMediaBlock(
                photos: photos,
                onPhotoTap: (index) => _openPhoto(index, photos),
                onPhotoLongPress: () =>
                    _onPostActionsMenu(attachmentId: engagementAttachmentId),
                onPhotoDoubleTap: engagementAttachmentId != null
                    ? () => _onPostDoubleTap(
                          attachmentId: engagementAttachmentId,
                        )
                    : null,
                onIndexChanged: _tracksMediaCarousel
                    ? (index) => setState(() => _batchIndex = index)
                    : null,
                onPlaySlideshow: photos.length > 1
                    ? (startIndex) {
                        PhotoSlideshowScreen.open(
                          context,
                          photos: photos,
                          startIndex: startIndex,
                        );
                      }
                    : null,
              ),
            if (caption != null)
              _postBodyGestures(
                attachmentId: engagementAttachmentId,
                child: FeedExpandableCaption(text: caption),
              ),
            if (_isMilestoneEvent && _hasMilestoneMeta)
              _postBodyGestures(
                attachmentId: engagementAttachmentId,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_weightLabel != null)
                        _FeedMetaChip(
                          icon: LucideIcons.weight,
                          label: _weightLabel!,
                        ),
                      if (_heightLabel != null)
                        _FeedMetaChip(
                          icon: LucideIcons.ruler,
                          label: _heightLabel!,
                        ),
                    ],
                  ),
                ),
              ),
            // Footer dead zones (outside reaction count / comments / viewed
            // row buttons) open the same actions menu on tap / long-press.
            _postBodyGestures(
              attachmentId: engagementAttachmentId,
              child: _showHeavyChrome
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FeedEventActionBar(
                          key: ValueKey<int?>(engagementAttachmentId),
                          attachmentId: engagementAttachmentId,
                          event: _event,
                          createdAt: createdAt,
                          onEngagementChanged: widget.onEngagementChanged,
                        ),
                        FeedViewedByRow(
                          viewedBy: _viewedBy,
                          eventId: _eventId,
                          onViewedByChanged: _storeViewedBy,
                        ),
                      ],
                    )
                  : const SizedBox(height: 52),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedMetaChip extends StatelessWidget {
  const _FeedMetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
