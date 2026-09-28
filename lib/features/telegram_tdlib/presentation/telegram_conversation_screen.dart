import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/appearance_prefs.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/data/chat_location_utils.dart';
import '../../chat/data/chat_send_options.dart';
import '../../chat/data/chat_voice_utils.dart';
import '../../chat/data/link_preview_service.dart';
import '../tdlib_io.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../chat/presentation/record_video_circle_screen.dart';
import '../../chat/presentation/widgets/chat_animated_media_scope.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_models.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_sheet.dart';
import '../../chat/presentation/widgets/chat_compose_input.dart';
import '../../chat/presentation/widgets/chat_day_separator.dart';
import '../../chat/presentation/widgets/chat_image_viewer.dart';
import '../../chat/presentation/widgets/chat_mention_text.dart';
import '../../chat/presentation/widgets/chat_message_actions_sheet.dart';
import '../../chat/presentation/widgets/chat_message_bubble.dart';
import '../../chat/presentation/widgets/chat_pinned_bar.dart';
import '../../chat/presentation/widgets/chat_reply_compose_bar.dart';
import '../../chat/presentation/widgets/chat_unread_separator.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';
import '../telegram_link_navigation.dart';
import '../tg_jank_log.dart';
import 'telegram_chat_info_sheet.dart';
import 'telegram_live_stream_bar.dart';
import 'telegram_message_search_sheet.dart';
import 'telegram_user_info_sheet.dart';

class TelegramConversationScreen extends ConsumerStatefulWidget {
  const TelegramConversationScreen({
    super.key,
    required this.chatId,
    required this.title,
    this.tgUserId,
    this.fcUserId,
    this.peerAvatarUrl = '',
    this.initialMessageId,
  });

  final int chatId;
  final String title;
  final int? tgUserId;
  final int? fcUserId;
  final String peerAvatarUrl;
  /// Deep-link target: jump here after history loads.
  final int? initialMessageId;

  @override
  ConsumerState<TelegramConversationScreen> createState() =>
      _TelegramConversationScreenState();
}

class _TelegramConversationScreenState
    extends ConsumerState<TelegramConversationScreen>
    with WidgetsBindingObserver {
  final _textCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _animatedMediaController = ChatAnimatedMediaController();
  final _tts = FlutterTts();
  bool _sending = false;
  bool _loadingOlder = false;
  Timer? _tailSyncTimer;

  TdlibMessage? _replyTo;
  TdlibMessage? _editing;
  bool _selectionMode = false;
  final Set<int> _selectedIds = {};
  int? _pendingOpenVideoId;
  bool _joiningLiveStream = false;

  /// First unread message id for the divider — sticky for this visit.
  /// Captured on enter; not cleared by mark-as-read / scroll / FAB.
  /// Resets when the screen is disposed (leave + re-enter).
  int? _unreadAnchorMessageId;
  /// Snapshot of inbox cursor at open — survives history races.
  int? _openLastReadInboxId;
  /// Unread count frozen at open — keeps divider placement stable mid-visit.
  int _openUnreadCount = 0;
  bool _initialScrollDone = false;
  /// True once the unread frontier is on-screen (or there were no unreads).
  /// Until then we must not call viewMessages — a tip-side viewport would
  /// mark everything above the sticky divider as read.
  bool _unreadFrontierReady = false;
  /// Hide the message list until open positioning finishes — avoids tip→unread
  /// bounce while history pages in and ensureVisible retries.
  bool _contentReady = false;
  bool _linkPreviewsEnabled = false;
  /// Spinner only after 1s still waiting — avoid 100ms flash on fast opens.
  bool _showOpenLoader = false;
  Timer? _openLoaderTimer;
  bool _caughtUpMarked = false;
  /// Ignore tip mark-read while we jump to the unread frontier.
  bool _suppressMarkRead = true;
  bool _suppressViewportPrefetch = true;
  bool _showScrollToBottom = false;
  double _lastScrollPixels = 0;
  int _msgsLenAtUnreadJump = -1;
  Timer? _scrollToBottomHintTimer;
  Timer? _viewportPrefetchTimer;
  Timer? _markVisibleReadTimer;
  Timer? _scrollBusyClearTimer;
  Timer? _reassertUnreadScrollTimer;
  Timer? _openRevealTimeout;
  Timer? _stickyDayThrottle;
  String? _stickyDayLabel;
  bool _showStickyDay = false;
  /// Highest message id we already sent to viewMessages this session.
  int _maxMarkedReadId = 0;
  DateTime? _lastUserScrollAt;
  final Set<int> _expandedBodyIds = {};
  final Map<int, GlobalKey> _messageKeys = {};
  final GlobalKey _unreadSeparatorKey = GlobalKey();

  static const _stickyDayAwayPx = 40.0;
  static const _scrollToBottomAwayPx = 280.0;
  static const _scrollToBottomHintDelay = Duration(milliseconds: 420);
  static const _viewportPrefetchDebounce = Duration(milliseconds: 900);
  static const _markVisibleReadDebounce = Duration(milliseconds: 180);

  DateTime? _lastItemBuilderFlushAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    TgJankLog.resetForChat(widget.chatId);
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
    // Stay deferred until reveal+settle — timed boot defer expires mid-open
    // on slow proxy and then OG scrapes nuke the first fling (~100+ frames).
    LinkPreviewService.instance.deferNetworkFetches = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openAndWatch());
    });
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (TgJankLog.focusChatId != widget.chatId) return;
    for (final t in timings) {
      final buildMs = t.buildDuration.inMilliseconds;
      final rasterMs = t.rasterDuration.inMilliseconds;
      final totalMs = t.totalSpan.inMilliseconds;
      if (buildMs < 18 && rasterMs < 18 && totalMs < 22) continue;
      TgJankLog.log(
        'FRAME build=${buildMs}ms raster=${rasterMs}ms '
        'total=${totalMs}ms vsync=${t.vsyncOverhead.inMilliseconds}ms',
      );
    }
    final now = DateTime.now();
    final last = _lastItemBuilderFlushAt;
    if (last == null || now.difference(last).inMilliseconds >= 250) {
      _lastItemBuilderFlushAt = now;
      TgJankLog.flushItemBuilderWindow();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _lastUserScrollAt = DateTime.now();
    _animatedMediaController.noteUserScroll();
    final pos = _scroll.position;
    final activity = pos.activity;
    final actName = activity is BallisticScrollActivity
        ? 'ballistic'
        : activity is DragScrollActivity
            ? 'drag'
            : activity is IdleScrollActivity
                ? 'idle'
                : activity?.runtimeType.toString() ?? 'none';
    TgJankLog.scroll(
      chatId: widget.chatId,
      pixels: pos.pixels,
      max: pos.maxScrollExtent,
      activity: actName,
      busy: true,
    );
    // Defer media-driven ListView rebuilds while dragging/flinging — otherwise
    // download progress/completes hitch ballistic scroll every few frames.
    ref.read(telegramTdlibServiceProvider).setUiScrollBusy(true);
    _scrollBusyClearTimer?.cancel();
    _scrollBusyClearTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || _isUserActivelyScrolling) return;
      ref.read(telegramTdlibServiceProvider).setUiScrollBusy(false);
      TgJankLog.log('scroll-busy cleared');
    });
    // User took over before we finished the unread jump — allow progressive
    // read from whatever is on screen, but only after intentional scroll.
    if (_initialScrollDone &&
        _suppressMarkRead &&
        _isUserActivelyScrolling &&
        _openUnreadCount > 0) {
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      _revealChatContent();
    }
    _updateScrollToBottomVisibility();
    _scheduleStickyDayUpdate();
    _scheduleViewportPrefetch();
    _scheduleMarkVisibleRead();
    if (_loadingOlder) return;
    // reverse: true → maxScrollExtent is older history.
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 200) {
      return;
    }
    unawaited(_loadOlder());
  }

  DateTime? _dayOfTopmostVisibleMessage() {
    if (!_scroll.hasClients) return null;
    final msgs = ref.read(telegramTdlibServiceProvider).messagesFor(widget.chatId);
    if (msgs.isEmpty) return null;
    final scrollCtx = _scroll.position.context.notificationContext;
    final viewport = scrollCtx?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return null;

    final listTop = viewport.localToGlobal(Offset.zero).dy;
    final listBottom = listTop + viewport.size.height;

    DateTime? bestDay;
    var bestTop = double.infinity;
    for (final m in msgs) {
      final ctx = _messageKeys[m.id]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= listTop || top >= listBottom) continue;
      if (top < bestTop) {
        bestTop = top;
        bestDay = _messageLocalDay(m);
      }
    }
    return bestDay;
  }

  void _updateStickyDayHeader() {
    if (!_scroll.hasClients || !_contentReady) {
      if (_showStickyDay || _stickyDayLabel != null) {
        setState(() {
          _showStickyDay = false;
          _stickyDayLabel = null;
        });
      }
      return;
    }
    final pos = _scroll.position;
    // Near older edge the in-list day chip sits at the top — sticky doubles it.
    final nearOlder = pos.maxScrollExtent > 0 &&
        (pos.pixels >= pos.maxScrollExtent - 120 ||
            (pos.pixels / pos.maxScrollExtent) >= 0.90);
    if (nearOlder || _loadingOlder) {
      if (_showStickyDay || _stickyDayLabel != null) {
        setState(() {
          _showStickyDay = false;
          _stickyDayLabel = null;
        });
      }
      return;
    }
    final away = pos.pixels > _stickyDayAwayPx;
    final day = away ? _dayOfTopmostVisibleMessage() : null;
    final label = day == null ? null : formatChatDayLabel(day);
    final show = away && label != null;
    if (show == _showStickyDay && label == _stickyDayLabel) return;
    setState(() {
      _showStickyDay = show;
      _stickyDayLabel = label;
    });
  }

  void _scheduleStickyDayUpdate() {
    if (_stickyDayThrottle?.isActive ?? false) return;
    _stickyDayThrottle = Timer(const Duration(milliseconds: 48), () {
      if (!mounted) return;
      _updateStickyDayHeader();
    });
  }

  void _scheduleViewportPrefetch() {
    if (_suppressViewportPrefetch) return;
    _viewportPrefetchTimer?.cancel();
    // While the user is flinging, don't retarget exclusive media focus —
    // rebuilds + download churn mid-gesture feel like scroll "stick".
    final delay = _isUserActivelyScrolling
        ? const Duration(milliseconds: 480)
        : _viewportPrefetchDebounce;
    _viewportPrefetchTimer = Timer(delay, () {
      if (!mounted || _suppressViewportPrefetch) return;
      if (_isUserActivelyScrolling) {
        _scheduleViewportPrefetch();
        return;
      }
      ref.read(telegramTdlibServiceProvider).setUiScrollBusy(false);
      _prefetchAroundViewport();
    });
  }

  void _scheduleMarkVisibleRead() {
    if (_suppressMarkRead) return;
    _markVisibleReadTimer?.cancel();
    final delay = _isUserActivelyScrolling
        ? const Duration(milliseconds: 320)
        : _markVisibleReadDebounce;
    _markVisibleReadTimer = Timer(delay, () {
      if (!mounted || _suppressMarkRead) return;
      if (_isUserActivelyScrolling) {
        _scheduleMarkVisibleRead();
        return;
      }
      unawaited(_markVisibleMessagesRead());
    });
  }

  /// Exclusive focus: prefer the nearest media-bearing row under the viewport.
  void _prefetchAroundViewport() {
    if (!_scroll.hasClients) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = svc.messagesFor(widget.chatId);
    if (msgs.isEmpty) return;

    final timeline = _buildTimeline(msgs);
    if (timeline.isEmpty) return;

    // reverse ListView: index 0 ≈ newest row near bottom.
    // Photo/album rows are tall — 160px under-estimates and focuses the wrong
    // bubble (sharp neighbor while the center album stays soft forever).
    const avgExtent = 280.0;
    final pixels = _scroll.position.pixels;
    final viewport = _scroll.position.viewportDimension;
    // Aim at the visual center of the screen, not the top edge.
    final centerPixels = pixels + viewport * 0.42;
    final reversedIndex =
        (centerPixels / avgExtent).floor().clamp(0, timeline.length - 1);
    final chronoIndex = timeline.length - 1 - reversedIndex;

    // Prefer a row that still needs PHOTO download. Video-thumb-only rows
    // (often stubs with null photoRemoteId) stole focus and then
    // focus-skip-empty'd — leaving the on-screen album blurry forever.
    bool rowNeedsPhoto(_TgTimelineRow row) {
      return row.members.any(svc.photoNeedsFocusDownload);
    }

    bool rowNeedsVideoThumb(_TgTimelineRow row) {
      return row.members.any((m) {
        final thumb = m.videoThumbFileId;
        return thumb != null &&
            thumb > 0 &&
            svc.cachedFilePath(thumb) == null;
      });
    }

    var focusRow = timeline[chronoIndex.clamp(0, timeline.length - 1)];
    var found = false;
    // Cover roughly one viewport of rows (±).
    final maxDist = (viewport / avgExtent).ceil().clamp(4, 14);
    for (var dist = 0; dist <= maxDist && !found; dist++) {
      for (final sign in dist == 0 ? <int>[0] : <int>[-1, 1]) {
        final i = chronoIndex + sign * dist;
        if (i < 0 || i >= timeline.length) continue;
        final row = timeline[i];
        if (rowNeedsPhoto(row)) {
          focusRow = row;
          found = true;
          break;
        }
      }
    }
    if (!found) {
      for (var dist = 0; dist <= maxDist && !found; dist++) {
        for (final sign in dist == 0 ? <int>[0] : <int>[-1, 1]) {
          final i = chronoIndex + sign * dist;
          if (i < 0 || i >= timeline.length) continue;
          final row = timeline[i];
          if (rowNeedsVideoThumb(row)) {
            focusRow = row;
            found = true;
            break;
          }
        }
      }
    }
    if (!found) return;

    svc.prefetchOpenChatViewport(
      chatId: widget.chatId,
      focusMessageId: focusRow.primary.id,
    );
  }

  void _hideScrollToBottomButton() {
    _scrollToBottomHintTimer?.cancel();
    _scrollToBottomHintTimer = null;
    if (_showScrollToBottom) {
      setState(() => _showScrollToBottom = false);
    }
  }

  void _updateScrollToBottomVisibility() {
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final delta = pixels - _lastScrollPixels;
    _lastScrollPixels = pixels;

    final svc = ref.read(telegramTdlibServiceProvider);
    final unread = svc.unreadCountFor(widget.chatId);
    // FAB catch-up uses live unread only — sticky visit divider must not
    // keep the button forced after everything was marked read.
    final hasLiveUnread = unread > 0;

    if (pixels <= _scrollToBottomAwayPx && !hasLiveUnread) {
      _hideScrollToBottomButton();
      return;
    }

    // Keep FAB visible while there are unreads (jump to tip + catch up).
    if (hasLiveUnread && pixels > 48) {
      if (!_showScrollToBottom) {
        setState(() => _showScrollToBottom = true);
      }
      return;
    }

    final scrollingDown = delta < -1.5;
    final scrollingUp = delta > 1.5;
    if (scrollingUp) {
      _hideScrollToBottomButton();
      return;
    }
    if (!scrollingDown || _showScrollToBottom) return;

    _scrollToBottomHintTimer ??= Timer(_scrollToBottomHintDelay, () {
      _scrollToBottomHintTimer = null;
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.pixels > _scrollToBottomAwayPx) {
        setState(() => _showScrollToBottom = true);
      }
    });
  }

  void _scrollToBottom({bool jump = false, bool settle = false}) {
    void apply() {
      if (!_scroll.hasClients) return;
      const target = 0.0;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        unawaited(
          _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      }
    }

    void scheduleSettle(int framesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        apply();
        if (framesLeft <= 0) return;
        scheduleSettle(framesLeft - 1);
      });
    }

    if (settle) {
      scheduleSettle(1);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }

  Future<void> _scrollToLiveTail() async {
    _hideScrollToBottomButton();
    _unreadFrontierReady = true;
    _suppressMarkRead = false;
    // Keep visit sticky unread divider; it resets only on leave + re-enter.
    _scrollToBottom(jump: false);
    await _markCaughtUp();
  }

  /// Mark only what's on screen (progressive). Not a bulk tip dump.
  Future<void> _markVisibleMessagesRead() async {
    if (_suppressMarkRead || !_scroll.hasClients) return;
    // Opening with unreads: never mark until the frontier row is on screen.
    // Otherwise a tip-side viewport marks the whole gap as read while the
    // sticky divider still paints at the old anchor.
    if (_openUnreadCount > 0 && !_unreadFrontierReady) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = svc.messagesFor(widget.chatId);
    if (msgs.isEmpty) return;

    final timeline = _buildTimeline(msgs);
    if (timeline.isEmpty) return;

    const avgExtent = 220.0;
    final pixels = _scroll.position.pixels;
    final viewport = _scroll.position.viewportDimension;
    final topPx = pixels;
    final bottomPx = pixels + viewport;
    final firstRev = (topPx / avgExtent).floor().clamp(0, timeline.length - 1);
    final lastRev =
        (bottomPx / avgExtent).ceil().clamp(0, timeline.length - 1);

    final lastRead = svc.lastReadInboxMessageId(widget.chatId);
    final floor = _maxMarkedReadId > lastRead ? _maxMarkedReadId : lastRead;

    var highestVisibleUnread = 0;
    for (var rev = firstRev; rev <= lastRev; rev++) {
      final chrono = timeline.length - 1 - rev;
      if (chrono < 0 || chrono >= timeline.length) continue;
      for (final m in timeline[chrono].members) {
        if (m.isOutgoing) continue;
        if (m.id <= floor) continue;
        if (m.id > highestVisibleUnread) highestVisibleUnread = m.id;
      }
    }
    if (highestVisibleUnread <= 0) return;

    _maxMarkedReadId = highestVisibleUnread;
    await svc.markMessagesRead(widget.chatId, [highestVisibleUnread]);
    // Unread divider stays for this visit even after reading past the anchor.
  }

  bool _isUnreadAnchorInViewport() {
    if (!_scroll.hasClients) return false;
    final sepCtx = _unreadSeparatorKey.currentContext;
    final ctx = (sepCtx != null && sepCtx.mounted)
        ? sepCtx
        : () {
            final anchorId = _unreadAnchorMessageId;
            if (anchorId == null) return null;
            final svc = ref.read(telegramTdlibServiceProvider);
            final timeline = _buildTimeline(svc.messagesFor(widget.chatId));
            final keyId = _visibleKeyMessageId(anchorId, timeline);
            return _keyForMessage(keyId).currentContext;
          }();
    if (ctx == null || !ctx.mounted) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final listBox = _scroll.position.context.storageContext.findRenderObject()
        as RenderBox?;
    if (listBox == null || !listBox.hasSize) return false;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: listBox);
    final bottom = topLeft.dy + box.size.height;
    final viewH = listBox.size.height;
    // Overlap the viewport at all (divider near top is fine).
    return bottom > 0 && topLeft.dy < viewH;
  }

  /// Explicit catch-up (FAB / open with no unreads) — tip only.
  /// Does not clear the visit sticky unread divider.
  Future<void> _markCaughtUp() async {
    if (_suppressMarkRead) return;
    if (_caughtUpMarked) return;
    _caughtUpMarked = true;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = svc.messagesFor(widget.chatId);
    if (msgs.isEmpty) return;
    final tipId = msgs.last.id;
    _maxMarkedReadId = tipId;
    await svc.markMessagesRead(widget.chatId, [tipId]);
  }

  DateTime? _messageLocalDay(TdlibMessage m) {
    if (m.date <= 0) return null;
    final local = DateTime.fromMillisecondsSinceEpoch(m.date * 1000).toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  bool _sameCalendarDay(TdlibMessage a, TdlibMessage b) {
    final da = _messageLocalDay(a);
    final db = _messageLocalDay(b);
    if (da == null || db == null) return false;
    return da == db;
  }

  Future<void> _ensureUnreadHistoryLoaded(TelegramTdlibService svc) async {
    final lastRead =
        _openLastReadInboxId ?? svc.lastReadInboxMessageId(widget.chatId);
    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    if (unread <= 0) return;

    // Cap pages — busy support groups can report hundreds of unreads; loading
    // them all at once freezes scroll/buttons. User can load older on scroll.
    const maxPages = 4;
    const pageSize = 40;
    for (var i = 0; i < maxPages; i++) {
      if (!mounted) return;
      final msgs = svc.messagesFor(widget.chatId);
      if (msgs.isEmpty) {
        final added = await svc.loadOlderMessages(
          widget.chatId,
          pageSize: pageSize,
        );
        if (added <= 0) return;
        continue;
      }
      // Reached the read frontier (or older).
      if (lastRead > 0 && msgs.first.id <= lastRead) return;
      // Already have at least as many unreads as reported.
      final loadedUnread = lastRead > 0
          ? msgs.where((m) => m.id > lastRead).length
          : msgs.length;
      if (loadedUnread >= unread) return;
      // Soft cap: enough context around the frontier for a smooth open.
      if (msgs.length >= 120) return;

      final added = await svc.loadOlderMessages(
        widget.chatId,
        pageSize: pageSize,
      );
      if (added <= 0) return;
    }
  }

  int? _resolveFirstUnreadId(TelegramTdlibService svc) {
    final lastRead =
        _openLastReadInboxId ?? svc.lastReadInboxMessageId(widget.chatId);
    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    if (unread <= 0) return null;
    final msgs = svc.messagesFor(widget.chatId);
    for (final m in msgs) {
      if (m.id > lastRead) return m.id;
    }
    return _unreadAnchorMessageId ?? svc.firstUnreadMessageId(widget.chatId);
  }

  GlobalKey _keyForMessage(int messageId) =>
      _messageKeys.putIfAbsent(messageId, GlobalKey.new);

  /// Album siblings share the primary row's [GlobalKey] for scroll-into-view.
  int _visibleKeyMessageId(
    int messageId,
    List<_TgTimelineRow> timeline,
  ) {
    for (final row in timeline) {
      if (row.containsMessageId(messageId)) return row.primary.id;
    }
    return messageId;
  }

  List<_TgTimelineRow> _buildTimeline(List<TdlibMessage> chronological) {
    final rows = <_TgTimelineRow>[];
    var i = 0;
    while (i < chronological.length) {
      final m = chronological[i];
      final albumId = m.mediaAlbumId;
      if (albumId != null) {
        final members = <TdlibMessage>[m];
        var j = i + 1;
        while (j < chronological.length &&
            chronological[j].mediaAlbumId == albumId) {
          members.add(chronological[j]);
          j++;
        }
        rows.add(
          members.length > 1
              ? _TgTimelineRow.album(members)
              : _TgTimelineRow.single(m),
        );
        i = j;
      } else {
        rows.add(_TgTimelineRow.single(m));
        i++;
      }
    }
    return rows;
  }

  int _timelineLen = -1;
  int _timelineFirstId = 0;
  int _timelineLastId = 0;
  List<_TgTimelineRow>? _cachedTimeline;
  List<_TgTimelineRow>? _cachedReversedTimeline;

  /// Reuse album grouping across rebuilds when the message window is unchanged.
  List<_TgTimelineRow> _timelineCached(List<TdlibMessage> chronological) {
    final first = chronological.isEmpty ? 0 : chronological.first.id;
    final last = chronological.isEmpty ? 0 : chronological.last.id;
    if (_cachedTimeline != null &&
        chronological.length == _timelineLen &&
        first == _timelineFirstId &&
        last == _timelineLastId) {
      return _cachedTimeline!;
    }
    _timelineLen = chronological.length;
    _timelineFirstId = first;
    _timelineLastId = last;
    _cachedTimeline = _buildTimeline(chronological);
    _cachedReversedTimeline =
        _cachedTimeline!.reversed.toList(growable: false);
    return _cachedTimeline!;
  }

  List<_TgTimelineRow> _reversedTimelineCached(List<TdlibMessage> msgs) {
    _timelineCached(msgs);
    return _cachedReversedTimeline ?? const [];
  }

  List<Map<String, dynamic>> _attachmentsForRow(_TgTimelineRow row) {
    if (!row.isAlbum) return _attachments(row.primary);
    final ordered = [...row.members]..sort((a, b) => a.id.compareTo(b.id));
    final out = <Map<String, dynamic>>[];
    for (final m in ordered) {
      out.addAll(_attachments(m));
    }
    return out;
  }

  Map<String, dynamic> _messageMetadataForRow(_TgTimelineRow row) {
    for (final m in row.members) {
      if (m.isSticker || m.isAnimation || m.isVideo) {
        return _messageMetadata(m);
      }
    }
    return _messageMetadata(row.primary);
  }

  String _bubbleBodyForRow(_TgTimelineRow row) {
    if (row.isAlbum) return row.caption;
    final m = row.primary;
    if (m.isSticker) return '';
    if (m.isVoiceNote || m.isVideoNote || m.isVideo || m.isPhoto) {
      if (m.text == 'Видео' ||
          m.text == 'GIF' ||
          m.text == 'Фото' ||
          m.text == 'Стикер') {
        return '';
      }
    }
    if (m.isDocument) {
      // Filename lives on the file card; keep only a real caption.
      if (m.text.startsWith('Файл:') || m.text == 'Файл') return '';
    }
    return m.text;
  }

  List<ChatTextEntity> _textEntitiesForRow(_TgTimelineRow row) {
    final m = row.primary;
    final body = _bubbleBodyForRow(row);
    if (body.isEmpty || m.textEntities.isEmpty) return const [];
    return ChatTextEntity.listFromMaps(m.text, m.textEntities);
  }

  Map<String, dynamic>? _forwardMap(TdlibMessage m) {
    if (!m.isForwarded) return null;
    return {
      if (m.forwardOriginName != null && m.forwardOriginName!.isNotEmpty)
        'original_sender_name': m.forwardOriginName,
      if (m.forwardOriginChatTitle != null &&
          m.forwardOriginChatTitle!.isNotEmpty)
        'original_thread_title': m.forwardOriginChatTitle,
      if (m.forwardFromChatId != null) 'from_chat_id': m.forwardFromChatId,
      if (m.forwardFromMessageId != null)
        'from_message_id': m.forwardFromMessageId,
    };
  }

  void _jumpToMessage(int messageId) {
    if (_isUserActivelyScrolling) return;
    unawaited(_jumpToLinkedMessage(messageId));
  }

  /// Keep the message top fixed when expanding/collapsing «ещё».
  /// reverse:true ListView anchors the bottom, so growth would otherwise
  /// push the visible head off-screen and land on the end of the post.
  void _toggleBodyExpand(int messageId) {
    final key = _keyForMessage(messageId);
    final beforeTop = _globalTopY(key);
    setState(() {
      if (_expandedBodyIds.contains(messageId)) {
        _expandedBodyIds.remove(messageId);
      } else {
        _expandedBodyIds.add(messageId);
      }
    });
    if (beforeTop == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keepGlobalTopY(key, beforeTop);
    });
  }

  double? _globalTopY(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero).dy;
  }

  void _keepGlobalTopY(GlobalKey key, double anchorTop) {
    if (!_scroll.hasClients) return;
    final afterTop = _globalTopY(key);
    if (afterTop == null) return;
    final delta = afterTop - anchorTop;
    if (delta.abs() < 0.5) return;
    final pos = _scroll.position;
    // reverse:true — larger pixels shifts content down on screen.
    // If the top moved up (delta < 0), increase pixels to push it back down.
    final target = (pos.pixels - delta).clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < 0.5) return;
    pos.jumpTo(target);
  }

  Future<void> _openSearch() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (_, __) => TelegramMessageSearchSheet(
          chatId: widget.chatId,
          service: svc,
          onSelect: (id) {
            Navigator.pop(ctx);
            unawaited(_jumpToLinkedMessage(id));
          },
        ),
      ),
    );
  }

  Future<void> _jumpToLinkedMessage(int messageId) async {
    if (!mounted || messageId <= 0) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    var ok = await _ensureVisibleMessage(messageId, alignment: 0.25);
    if (!ok) {
      await svc.ensureMessageLoaded(widget.chatId, messageId);
      if (!mounted) return;
      // Message may sit outside loaded history — pull a window around it.
      await svc.openChat(widget.chatId);
      ok = await _ensureVisibleMessage(messageId, alignment: 0.25);
    }
    if (!ok && mounted) {
      // Last attempt after a short settle (list rebuild).
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      await _ensureVisibleMessage(messageId, alignment: 0.25);
    }
  }

  Future<bool> _handleOpenUrl(String url) {
    return TelegramLinkNavigation.tryOpen(
      url,
      currentChatId: widget.chatId,
      onSameChat: _jumpToLinkedMessage,
    );
  }

  /// True while a drag/fling is in progress — programmatic jumpTo here
  /// feels like "scroll stick" (gesture cancelled mid-fling).
  bool get _isUserActivelyScrolling {
    if (!_scroll.hasClients) return false;
    final pos = _scroll.position;
    if (pos.isScrollingNotifier.value) return true;
    final activity = pos.activity;
    if (activity is DragScrollActivity || activity is BallisticScrollActivity) {
      return true;
    }
    final last = _lastUserScrollAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(milliseconds: 280)) {
      return true;
    }
    return false;
  }

  void _revealChatContent() {
    if (!mounted || _contentReady) return;
    _openRevealTimeout?.cancel();
    _openRevealTimeout = null;
    _openLoaderTimer?.cancel();
    _openLoaderTimer = null;
    TgJankLog.log('reveal content');
    setState(() {
      _contentReady = true;
      _showOpenLoader = false;
    });
    // Link-preview cards + Dio after first flings have a chance.
    Timer(const Duration(milliseconds: 2800), () {
      if (!mounted || _isUserActivelyScrolling) {
        // Try again shortly after fling ends.
        Timer(const Duration(milliseconds: 800), () {
          if (!mounted || _isUserActivelyScrolling) return;
          _enableLinkPreviews();
        });
        return;
      }
      _enableLinkPreviews();
    });
  }

  void _enableLinkPreviews() {
    if (!mounted || _linkPreviewsEnabled) return;
    TgJankLog.log('enable link previews');
    LinkPreviewService.instance.linkPreviewGateOpen = true;
    LinkPreviewService.instance.deferNetworkFetches = false;
    setState(() => _linkPreviewsEnabled = true);
  }

  void _armDelayedOpenLoader() {
    _openLoaderTimer?.cancel();
    _openLoaderTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted || _contentReady) return;
      setState(() => _showOpenLoader = true);
    });
  }

  void _armOpenRevealTimeout() {
    _openRevealTimeout?.cancel();
    _openRevealTimeout = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted || _contentReady) return;
      _initialScrollDone = true;
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      _revealChatContent();
    });
  }

  Future<bool> _ensureVisibleMessage(
    int messageId, {
    double alignment = 0.12,
    bool instant = false,
  }) async {
    if (!mounted) return false;
    if (_isUserActivelyScrolling) return false;
    // Rough jump so the builder mounts the target row.
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = svc.messagesFor(widget.chatId);
    final timeline = _buildTimeline(msgs);
    final rowIndex =
        timeline.indexWhere((r) => r.containsMessageId(messageId));
    if (rowIndex < 0) return false;
    final keyId = _visibleKeyMessageId(messageId, timeline);

    if (_scroll.hasClients && !_isUserActivelyScrolling) {
      final listIndex = timeline.length - 1 - rowIndex;
      final max = _scroll.position.maxScrollExtent;
      // Proportional jump beats a fixed avg height on media-heavy channels
      // (fixed 140px under-shoots → lands near the tip / “too low”).
      final t = timeline.length <= 1
          ? 0.0
          : listIndex / (timeline.length - 1);
      final estimated = (t * max).clamp(0.0, max);
      _scroll.jumpTo(estimated);
    }

    // Opening path must never animate — animations are the visible “jumps”.
    final useInstant = instant || !_contentReady;

    for (var attempt = 0; attempt < 16; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      if (_isUserActivelyScrolling) return false;
      final ctx = _keyForMessage(keyId).currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          duration: useInstant || attempt == 0
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: alignment,
        );
        // Pin the unread bar flush to the top of the chat viewport when
        // opening on the frontier (alignment 0).
        if (alignment <= 0.001) {
          await _pinUnreadSeparatorToTop();
        }
        return true;
      }
      if (_scroll.hasClients && !_isUserActivelyScrolling) {
        final pos = _scroll.position;
        final listIndex = timeline.length - 1 - rowIndex;
        final max = pos.maxScrollExtent;
        final t = timeline.length <= 1
            ? 0.0
            : listIndex / (timeline.length - 1);
        final base = (t * max).clamp(0.0, max);
        final drift =
            220.0 * ((attempt ~/ 2) + 1) * (attempt.isEven ? 1 : -1);
        _scroll.jumpTo((base + drift).clamp(0.0, max));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return false;
  }

  /// Scroll so «Непрочитанные сообщения» sits at the top of the chat area.
  Future<void> _pinUnreadSeparatorToTop() async {
    if (!mounted || _isUserActivelyScrolling) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _isUserActivelyScrolling) return;
    final ctx = _unreadSeparatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      alignment: 0.0,
      duration: Duration.zero,
    );
  }

  Future<void> _positionInitialScroll(TelegramTdlibService svc) async {
    if (_initialScrollDone || !mounted) return;
    _suppressMarkRead = true;
    _unreadFrontierReady = false;

    await _ensureUnreadHistoryLoaded(svc);
    if (!mounted) return;

    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    final firstUnread = _resolveFirstUnreadId(svc);
    final msgs = svc.messagesFor(widget.chatId);

    if (unread <= 0 || firstUnread == null || msgs.isEmpty) {
      _initialScrollDone = true;
      _unreadFrontierReady = true;
      _scrollToBottom(jump: true, settle: true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) _revealChatContent();
      _suppressMarkRead = false;
      _scheduleViewportPrefetch();
      _scheduleMarkVisibleRead();
      if (unread <= 0) {
        await _markCaughtUp();
      }
      return;
    }

    var anchorId = firstUnread;
    if (!msgs.any((m) => m.id == anchorId)) {
      final lastRead =
          _openLastReadInboxId ?? svc.lastReadInboxMessageId(widget.chatId);
      TdlibMessage? oldestUnread;
      for (final m in msgs) {
        if (m.id > lastRead) {
          oldestUnread = m;
          break;
        }
      }
      anchorId = oldestUnread?.id ?? msgs.first.id;
    }

    if (mounted) {
      setState(() {
        _unreadAnchorMessageId = anchorId;
        _showScrollToBottom = true;
      });
    }

    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    var ok = await _ensureVisibleMessage(
      anchorId,
      alignment: 0.0,
      instant: true,
    );
    if (!ok && mounted) {
      // History may still be growing — retry a few times before giving up.
      for (var i = 0; i < 5 && mounted && !ok; i++) {
        await Future<void>.delayed(Duration(milliseconds: 120 + i * 80));
        if (!mounted) return;
        await _ensureUnreadHistoryLoaded(svc);
        ok = await _ensureVisibleMessage(
          anchorId,
          alignment: 0.0,
          instant: true,
        );
      }
    }
    _initialScrollDone = true;
    _msgsLenAtUnreadJump = svc.messagesFor(widget.chatId).length;
    if (ok) {
      _unreadFrontierReady = true;
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) _revealChatContent();
      // Let layout settle before progressive read.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (mounted) _suppressMarkRead = false;
      _scheduleViewportPrefetch();
      _scheduleMarkVisibleRead();
    } else {
      // Stay suppressed — tip viewport must not wipe unreads. Reassert when
      // more history arrives / user scrolls. Keep list hidden until then.
      _scheduleReassertUnreadScroll();
    }
    if (mounted) _updateScrollToBottomVisibility();
  }

  void _scheduleReassertUnreadScroll() {
    _reassertUnreadScrollTimer?.cancel();
    _reassertUnreadScrollTimer =
        Timer(const Duration(milliseconds: 280), () {
      if (!mounted || _unreadFrontierReady) return;
      unawaited(_reassertUnreadScroll());
    });
  }

  Future<void> _reassertUnreadScroll() async {
    if (!mounted || _unreadFrontierReady) return;
    if (_openUnreadCount <= 0 || _unreadAnchorMessageId == null) {
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      _revealChatContent();
      return;
    }
    if (_isUserActivelyScrolling) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final len = svc.messagesFor(widget.chatId).length;
    // Always retry until frontier is visible — remote history fill often
    // resets reverse ListView back to the tip after the first jump.
    final ok = await _ensureVisibleMessage(
      _unreadAnchorMessageId!,
      alignment: 0.0,
      instant: true,
    );
    if (!mounted) return;
    _msgsLenAtUnreadJump = len;
    if (ok && _isUnreadAnchorInViewport()) {
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      _revealChatContent();
      _scheduleViewportPrefetch();
      _scheduleMarkVisibleRead();
      if (mounted) _updateScrollToBottomVisibility();
      return;
    }
    _scheduleReassertUnreadScroll();
  }

  /// Call from build when message list length changes during open settle.
  void _maybeReassertUnreadAfterHistoryGrowth(int messageCount) {
    if (_unreadFrontierReady || _openUnreadCount <= 0) return;
    if (!_initialScrollDone) return;
    if (messageCount == _msgsLenAtUnreadJump) return;
    _scheduleReassertUnreadScroll();
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !mounted) return;
    _loadingOlder = true;
    try {
      await ref
          .read(telegramTdlibServiceProvider)
          .loadOlderMessages(widget.chatId);
    } finally {
      _loadingOlder = false;
    }
  }

  /// Keep paging until the channel has a usable history (scroll may not fire
  /// when only 1–2 messages fit on screen).
  Future<void> _fillHistoryIfSparse() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    var emptyStreak = 0;
    for (var i = 0; i < 20; i++) {
      if (!mounted) return;
      final count = svc.messagesFor(widget.chatId).length;
      if (count >= 40) return;
      final added = await svc.loadOlderMessages(widget.chatId, pageSize: 50);
      if (added <= 0) {
        emptyStreak++;
        if (emptyStreak >= 5) return;
        await Future<void>.delayed(
          Duration(milliseconds: 350 + emptyStreak * 150),
        );
      } else {
        emptyStreak = 0;
      }
    }
  }

  Future<void> _openMedia(
    Map<String, dynamic> attachment, {
    List<Map<String, dynamic>>? gallery,
  }) async {
    final play = Map<String, dynamic>.from(attachment);
    final kind = play['kind']?.toString() ?? '';
    final isVideo = kind == 'video' ||
        (play['content_type']?.toString() ?? '').startsWith('video/');
    final preferInline = play['prefer_inline_play'] == true;
    final forceFullscreen = play['force_fullscreen'] == true;
    final galleryMedia = _galleryMediaList(gallery, play);

    var videoPath = play['video_local_path']?.toString().trim() ?? '';
    if (videoPath.isEmpty) {
      final local = play['local_device_path']?.toString().trim() ?? '';
      final lower = local.toLowerCase();
      if (lower.endsWith('.mp4') ||
          lower.endsWith('.mov') ||
          lower.endsWith('.webm') ||
          lower.endsWith('.mkv')) {
        videoPath = local;
      }
    }

    if (isVideo && videoPath.isEmpty) {
      final svc = ref.read(telegramTdlibServiceProvider);
      final id = int.tryParse(play['id']?.toString() ?? '');
      if (id == null || id <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Видео недоступно')),
        );
        return;
      }

      // Inline progress on the bubble preview — no blocking dialog.
      play.remove('local_device_path');
      setState(() => _pendingOpenVideoId = id);
      // User tap wins the exclusive slot — cancel autofocus photo first.
      unawaited(svc.preemptForUserTap(
        fileId: id,
        chatId: widget.chatId,
        reason: 'tap:video:$id',
      ));
      unawaited(() async {
        final path = await svc.ensureFileLocal(
          id,
          priority: TelegramTdlibService.prioFocused,
          reason: 'tap:video:$id',
          waitFor: const Duration(minutes: 10),
        );
        if (!mounted) return;
        if (_pendingOpenVideoId != id) return;
        if (path == null || path.isEmpty) {
          setState(() => _pendingOpenVideoId = null);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось загрузить видео')),
          );
          return;
        }
        // Single-video bubble: stay in chat — preview autoplays when
        // video_local_path appears. Gallery / explicit fullscreen: open viewer.
        if (preferInline && !forceFullscreen) {
          // Rebuild attachments from cache so the bubble sees video_local_path.
          if (mounted) setState(() => _pendingOpenVideoId = null);
          return;
        }
        await _openVideoViewer(play, path, gallery: galleryMedia);
      }());
      return;
    }

    if (videoPath.isNotEmpty) {
      // prefer_inline without force → bubble plays; only open viewer on
      // second tap (force_fullscreen) or gallery taps (no prefer_inline).
      if (preferInline && !forceFullscreen) {
        return;
      }
      await _openVideoViewer(play, videoPath, gallery: galleryMedia);
      return;
    }

    // Photo: ensure the focused high-res file is local before opening viewer
    // (bubble may still show minithumb while y/x downloads).
    final svc = ref.read(telegramTdlibServiceProvider);
    final id = int.tryParse(play['id']?.toString() ?? '');
    if (id != null && id > 0) {
      final path = await svc.ensureFileLocal(
        id,
        priority: TelegramTdlibService.prioFocused,
        reason: 'tap:photo:$id',
        waitFor: const Duration(seconds: 45),
      );
      if (path != null && path.isNotEmpty) {
        play['local_device_path'] = path;
        play.remove('local_bytes');
        play.remove('thumbnail_bytes');
        play.remove('is_downloading');
      }
    }

    if (!mounted) return;
    final galleryForViewer =
        galleryMedia.length >= 2 ? galleryMedia : null;
    if (galleryForViewer != null) {
      // Prefetch album siblings so swipe has local files ready.
      for (final att in galleryForViewer) {
        final sid = int.tryParse(att['id']?.toString() ?? '');
        if (sid == null || sid <= 0 || sid == id) continue;
        unawaited(
          svc.ensureFileLocal(
            sid,
            priority: TelegramTdlibService.prioOpenChatMedia,
            reason: 'album:prefetch:$sid',
            waitFor: const Duration(seconds: 90),
          ),
        );
      }
    }
    await ChatImageViewer.open(
      context,
      imageUrl: '',
      threadId: widget.chatId,
      attachmentId: id,
      filename: play['filename']?.toString(),
      attachment: play,
      galleryAttachments: galleryForViewer,
    );
  }

  List<Map<String, dynamic>> _galleryMediaList(
    List<Map<String, dynamic>>? gallery,
    Map<String, dynamic> current,
  ) {
    final source = gallery ?? const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    void add(Map<String, dynamic> raw) {
      if (!isGalleryMediaAttachment(raw)) return;
      final copy = Map<String, dynamic>.from(raw);
      final id = copy['id']?.toString() ?? '';
      final local = galleryLocalDevicePath(copy);
      final url = galleryAttachmentUrl(copy);
      final key = id.isNotEmpty
          ? 'id:$id'
          : (local.isNotEmpty ? 'local:$local' : 'url:$url');
      if (key == 'url:' || !seen.add(key)) return;
      out.add(copy);
    }

    for (final a in source) {
      add(a);
    }
    if (out.isEmpty) add(current);
    return out;
  }

  Future<void> _openVideoViewer(
    Map<String, dynamic> play,
    String videoPath, {
    List<Map<String, dynamic>>? gallery,
  }) async {
    play['video_local_path'] = videoPath;
    // Keep thumb out of local_device_path — player must use video_local_path.
    play.remove('local_device_path');
    if (!mounted) return;
    setState(() => _pendingOpenVideoId = null);
    // Gallery list is a snapshot from the bubble — stamp the downloaded path
    // onto the matching item. Otherwise ChatImageViewer ignores [play] and
    // opens a stale copy with empty localPath (black / non-playing video).
    List<Map<String, dynamic>>? galleryOut;
    if (gallery != null && gallery.length >= 2) {
      final playId = play['id']?.toString();
      galleryOut = [
        for (final raw in gallery)
          () {
            final copy = Map<String, dynamic>.from(raw);
            if (playId != null &&
                playId.isNotEmpty &&
                copy['id']?.toString() == playId) {
              copy['video_local_path'] = videoPath;
              copy.remove('local_device_path');
              copy.remove('is_downloading');
              copy.remove('download_progress');
            }
            return copy;
          }(),
      ];
    }
    await ChatImageViewer.open(
      context,
      imageUrl: '',
      threadId: widget.chatId,
      attachmentId: int.tryParse(play['id']?.toString() ?? ''),
      filename: play['filename']?.toString(),
      attachment: play,
      galleryAttachments: galleryOut,
    );
  }

  Future<void> _openAndWatch() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    _suppressMarkRead = true;
    // Snapshot unread frontier before openChat / history mutate inbox state.
    _openLastReadInboxId = svc.lastReadInboxMessageId(widget.chatId);
    _openUnreadCount = svc.unreadCountFor(widget.chatId);
    final preUnread = svc.firstUnreadMessageId(widget.chatId);
    if (preUnread != null) {
      _unreadAnchorMessageId = preUnread;
    }
    final deepLink = widget.initialMessageId != null && widget.initialMessageId! > 0;
    final needsPositionGate = _openUnreadCount > 0 || deepLink;
    if (!needsPositionGate) {
      // Tip is already correct for reverse lists — show immediately, no spinner.
      _revealChatContent();
    } else {
      _armDelayedOpenLoader();
      _armOpenRevealTimeout();
    }
    await svc.openChat(widget.chatId);
    // Catch anything that raced during history load.
    await svc.syncChatTail(widget.chatId);
    unawaited(svc.refreshVideoChat(widget.chatId));
    await _fillHistoryIfSparse();
    await _positionInitialScroll(svc);
    final jumpId = widget.initialMessageId;
    if (jumpId != null && jumpId > 0) {
      await _jumpToLinkedMessage(jumpId);
      if (mounted) _revealChatContent();
    }
    // Focus the on-screen / unread photo — not the newest tip (that stole the
    // exclusive slot and left the visible spinner spinning forever).
    final anchor = widget.initialMessageId ?? _unreadAnchorMessageId;
    if (anchor != null) {
      svc.prefetchOpenChatViewport(
        chatId: widget.chatId,
        focusMessageId: anchor,
      );
    } else {
      _prefetchAroundViewport();
    }
    _suppressViewportPrefetch = false;
    _scheduleViewportPrefetch();
    _tailSyncTimer?.cancel();
    _tailSyncTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      unawaited(svc.syncChatTail(widget.chatId));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(
        ref.read(telegramTdlibServiceProvider).syncChatTail(widget.chatId),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    TgJankLog.clearFocus();
    _tailSyncTimer?.cancel();
    _scrollToBottomHintTimer?.cancel();
    _viewportPrefetchTimer?.cancel();
    _markVisibleReadTimer?.cancel();
    _scrollBusyClearTimer?.cancel();
    _reassertUnreadScrollTimer?.cancel();
    _openRevealTimeout?.cancel();
    _openLoaderTimer?.cancel();
    _stickyDayThrottle?.cancel();
    _scroll.removeListener(_onScroll);
    final chatId = widget.chatId;
    // Defer: closeChat → notifyListeners must not run during unmount
    // (Riverpod forbids provider updates while the tree is building).
    Future(() {
      unawaited(TelegramTdlibService.instance.closeChat(chatId));
    });
    LinkPreviewService.instance.deferNetworkFetches = false;
    LinkPreviewService.instance.linkPreviewGateOpen = false;
    _textCtrl.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _animatedMediaController.dispose();
    unawaited(_tts.stop());
    super.dispose();
  }

  Future<void> _sendText(ChatSendOptions options) async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final svc = ref.read(telegramTdlibServiceProvider);
    try {
      if (_editing != null) {
        await svc.editMessageText(widget.chatId, _editing!.id, text);
        if (mounted) {
          setState(() => _editing = null);
        } else {
          _editing = null;
        }
      } else {
        await svc.sendText(
          widget.chatId,
          text,
          replyToMessageId: _replyTo?.id,
        );
        _replyTo = null;
      }
      _textCtrl.clear();
    } catch (e) {
      if (!mounted) return;
      final wasEditing = _editing != null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasEditing
                ? 'Не удалось изменить: $e'
                : 'Не удалось отправить: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAttachment() async {
    await ChatAttachSheet.show(
      context,
      onSendMedia: _sendAttachItems,
      onSendLocation: _sendLocationMessage,
      onRecordVideoCircle: () => unawaited(_recordAndSendVideoCircle()),
    );
  }

  Future<String> _localPathForItem(ChatAttachSelectionItem item) async {
    final existing = item.localPath?.trim() ?? '';
    if (existing.isNotEmpty && File(existing).existsSync()) {
      return existing;
    }
    return ref.read(telegramTdlibServiceProvider).materializeTempFile(
          bytes: item.bytes,
          filename: item.filename,
        );
  }

  Future<void> _sendAttachItems(
    String caption,
    List<ChatAttachSelectionItem> items,
  ) async {
    if (items.isEmpty || _sending) return;
    setState(() => _sending = true);
    final svc = ref.read(telegramTdlibServiceProvider);
    final replyId = _replyTo?.id;
    try {
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final path = await _localPathForItem(item);
        final cap = i == 0 ? caption.trim() : '';
        switch (item.kind) {
          case 'image':
            await svc.sendPhoto(
              widget.chatId,
              path,
              caption: cap,
              replyToMessageId: i == 0 ? replyId : null,
            );
          case 'video':
            await svc.sendVideo(
              widget.chatId,
              path,
              caption: cap,
              replyToMessageId: i == 0 ? replyId : null,
            );
          default:
            await svc.sendDocument(
              widget.chatId,
              path,
              caption: cap,
              replyToMessageId: i == 0 ? replyId : null,
            );
        }
      }
      _replyTo = null;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendLocationMessage(ChatLocationPoint point) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(telegramTdlibServiceProvider).sendLocation(
            widget.chatId,
            latitude: point.latitude,
            longitude: point.longitude,
            replyToMessageId: _replyTo?.id,
          );
      _replyTo = null;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить геолокацию: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _recordAndSendVideoCircle() async {
    final recording = await RecordVideoCircleScreen.open(context);
    if (recording == null || !mounted) return;
    await _sendVideoCircleMessage(recording);
  }

  Future<void> _sendVideoCircleMessage(VideoCircleRecording recording) async {
    if (recording.durationMs < 400 || _sending) return;
    setState(() => _sending = true);
    final svc = ref.read(telegramTdlibServiceProvider);
    try {
      var path = recording.localPath?.trim() ?? '';
      if (path.isEmpty || !File(path).existsSync()) {
        path = await svc.materializeTempFile(
          bytes: recording.bytes,
          filename: recording.filename,
        );
      }
      await svc.sendVideoNote(
        widget.chatId,
        path,
        durationMs: recording.durationMs,
        replyToMessageId: _replyTo?.id,
      );
      _replyTo = null;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить кружок: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendVoiceMessage(
    Uint8List bytes,
    int durationMs, {
    String? encoderName,
  }) async {
    if (durationMs < 400 || bytes.isEmpty || _sending) return;
    setState(() => _sending = true);
    final svc = ref.read(telegramTdlibServiceProvider);
    try {
      final name = (encoderName ?? '').toLowerCase();
      final extension = name.contains('opus') || name.contains('ogg')
          ? 'ogg'
          : voiceExtensionForEncoder(encoderName ?? 'm4a');
      final path = await svc.materializeTempFile(
        bytes: bytes,
        filename: voiceMessageFilename(durationMs, extension: extension),
      );
      await svc.sendVoiceNote(
        widget.chatId,
        path,
        durationMs: durationMs,
        replyToMessageId: _replyTo?.id,
      );
      _replyTo = null;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить голосовое: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openPeerInfo() async {
    final fcId = widget.fcUserId;
    if (fcId != null && fcId > 0) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MemberProfileScreen(userId: fcId),
        ),
      );
      return;
    }
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.isGroupChat(widget.chatId) || svc.isChannelChat(widget.chatId)) {
      final profile = await svc.loadChatProfile(widget.chatId);
      if (!mounted) return;
      if (profile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть профиль')),
        );
        return;
      }
      await TelegramChatInfoSheet.show(
        context,
        chatId: widget.chatId,
        profile: profile,
      );
      return;
    }
    final tgUserId = widget.tgUserId;
    if (tgUserId == null) return;
    await _openSenderInfo(tgUserId);
  }

  Future<void> _openSenderInfo(int tgUserId) async {
    if (tgUserId <= 0) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final profile = await svc.loadUserProfile(tgUserId);
    if (!mounted || profile == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть профиль')),
        );
      }
      return;
    }
    // Private DM with this user if we have one; else still show profile sheet
    // (chatId used for mute — fall back to current group chat).
    final dmChatId = svc.privateChatIdForUser(tgUserId) ?? widget.chatId;
    await TelegramUserInfoSheet.show(
      context,
      chatId: dmChatId,
      profile: profile,
    );
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _joinLiveStream() async {
    if (_joiningLiveStream) return;
    setState(() => _joiningLiveStream = true);
    final svc = ref.read(telegramTdlibServiceProvider);
    try {
      final url = await svc.videoChatJoinUrl(widget.chatId);
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть трансляцию')),
        );
        return;
      }
      final uri = Uri.tryParse(url);
      if (uri == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Некорректная ссылка на трансляцию')),
        );
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть трансляцию')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Трансляция: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _joiningLiveStream = false);
    }
  }

  Future<void> _openMessageMenu(TdlibMessage m) async {
    if (_selectionMode) {
      _toggleSelection(m.id);
      return;
    }
    final svc = ref.read(telegramTdlibServiceProvider);
    final result = await ChatMessageActionsSheet.show(
      context,
      showReactions: true,
      canReply: true,
      canEdit: m.isOutgoing &&
          !m.isService &&
          m.text.trim().isNotEmpty,
      canCopy: m.text.isNotEmpty,
      canForward: true,
      canSelect: true,
      canPin: true,
      isPinned: m.isPinned || svc.pinnedMessageId(widget.chatId) == m.id,
      canSpeak: m.text.trim().isNotEmpty,
      canDeleteForEveryone: m.canBeDeletedForAllUsers,
      canDeleteForMe: m.canBeDeletedOnlyForSelf || m.canBeDeletedForAllUsers,
    );
    if (!mounted || result == null) return;

    if (result.reactionEmoji != null) {
      await _toggleReaction(m, result.reactionEmoji!);
      return;
    }

    switch (result.action) {
      case 'reply':
        setState(() {
          _replyTo = m;
          _editing = null;
        });
        _inputFocus.requestFocus();
      case 'edit':
        setState(() {
          _editing = m;
          _replyTo = null;
          _textCtrl.text = m.text;
          _textCtrl.selection = TextSelection.collapsed(offset: m.text.length);
        });
        _inputFocus.requestFocus();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Скопировано')),
        );
      case 'forward':
        await _forwardMessages([m.id]);
      case 'select':
        setState(() {
          _selectionMode = true;
          _selectedIds
            ..clear()
            ..add(m.id);
        });
      case 'pin':
        await svc.pinMessage(widget.chatId, m.id);
      case 'unpin':
        await svc.unpinMessage(widget.chatId, messageId: m.id);
      case 'speak':
        await _speak(m.text);
      case 'delete':
        await svc.deleteMessages(widget.chatId, [m.id], revoke: true);
      case 'delete_for_me':
        await svc.deleteMessages(widget.chatId, [m.id], revoke: false);
    }
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    try {
      await _tts.setLanguage('ru-RU');
      await _tts.speak(t);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось озвучить: $e')),
      );
    }
  }

  Future<void> _forwardMessages(List<int> ids) async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final chats = svc.privateChats
        .where((c) => c.chatId != widget.chatId)
        .toList();
    if (chats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет чатов для пересылки')),
      );
      return;
    }
    final to = await showModalBottomSheet<TdlibChatPreview>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('Переслать в чат')),
            for (final c in chats)
              ListTile(
                leading: ChatAvatar(
                  name: c.title,
                  localFilePath: c.photoLocalPath,
                  memoryBytes: c.photoMinithumbnailBytes,
                  radius: 20,
                ),
                title: Text(c.title),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (to == null) return;
    await svc.forwardMessages(
      fromChatId: widget.chatId,
      messageIds: ids,
      toChatId: to.chatId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Переслано в «${to.title}»')),
    );
    _exitSelection();
  }

  Future<void> _toggleReaction(TdlibMessage m, String emoji) async {
    final already = m.reactions.any((r) => r.emoji == emoji && r.chosen);
    await ref.read(telegramTdlibServiceProvider).toggleReaction(
          chatId: m.chatId,
          messageId: m.id,
          emoji: emoji,
          add: !already,
        );
  }

  Future<void> _deleteSelected({required bool revoke}) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    await ref.read(telegramTdlibServiceProvider).deleteMessages(
          widget.chatId,
          ids,
          revoke: revoke,
        );
    _exitSelection();
  }

  Future<void> _copySelected(List<TdlibMessage> all) async {
    final texts = all
        .where((m) => _selectedIds.contains(m.id) && m.text.isNotEmpty)
        .map((m) => m.text)
        .join('\n');
    if (texts.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: texts));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скопировано')),
    );
  }

  List<Map<String, dynamic>> _reactionMaps(TdlibMessage m) {
    return [
      for (final r in m.reactions)
        {
          'emoji': r.emoji,
          'count': r.count,
          'reacted_by_me': r.chosen,
        },
    ];
  }

  List<Map<String, dynamic>> _attachments(TdlibMessage m) {
    final svc = ref.read(telegramTdlibServiceProvider);

    if (m.isVoiceNote) {
      final path = m.voiceLocalPath ??
          (m.voiceFileId == null ? null : svc.cachedFilePath(m.voiceFileId!));
      if (path == null || path.isEmpty) {
        // Voice: only when this message is the scroll focus (no bulk warm).
        return const [];
      }
      final durationMs = m.voiceDurationMs ?? 0;
      return [
        {
          'id': m.voiceFileId ?? m.id,
          'kind': 'file',
          'content_type': 'audio/ogg',
          'filename': voiceMessageFilename(
            durationMs > 0 ? durationMs : 0,
            extension: 'ogg',
          ),
          'skip_age_defer': true,
          'local_device_path': path,
        },
      ];
    }

    if (m.isVideoNote) {
      final path = m.videoNoteLocalPath ??
          (m.videoNoteFileId == null
              ? null
              : svc.cachedFilePath(m.videoNoteFileId!));
      // Thumbs / body come from exclusive focus — do not enqueue here.
      final thumbPath = m.videoNoteThumbLocalPath ??
          (m.videoNoteThumbFileId == null
              ? null
              : svc.cachedFilePath(m.videoNoteThumbFileId!));
      if (path == null || path.isEmpty) {
        // Still show circle with thumb while video downloads.
        if ((thumbPath == null || thumbPath.isEmpty) &&
            (m.videoNoteThumbBytes == null || m.videoNoteThumbBytes!.isEmpty)) {
          return const [];
        }
      }
      final durationMs = m.videoNoteDurationMs ?? 0;
      return [
        {
          'id': m.videoNoteFileId ?? m.id,
          'kind': 'video',
          'content_type': 'video/mp4',
          'filename': 'video_note_${durationMs > 0 ? durationMs : m.id}.mp4',
          'is_video_note': true,
          'skip_age_defer': true,
          if (path != null && path.isNotEmpty) 'local_device_path': path,
          if (thumbPath != null && thumbPath.isNotEmpty)
            'thumbnail_local_path': thumbPath,
          if ((thumbPath == null || thumbPath.isEmpty) &&
              m.videoNoteThumbBytes != null &&
              m.videoNoteThumbBytes!.isNotEmpty)
            'thumbnail_bytes': Uint8List.fromList(m.videoNoteThumbBytes!),
        },
      ];
    }

    if (m.isVideo) {
      final path = m.videoLocalPath ??
          (m.videoFileId == null ? null : svc.cachedFilePath(m.videoFileId!));
      final thumbPath = m.videoThumbLocalPath ??
          (m.videoThumbFileId == null
              ? null
              : svc.cachedFilePath(m.videoThumbFileId!));
      // Thumb download = exclusive scroll focus only (not every built bubble).
      final thumbBytes = m.videoThumbBytes != null && m.videoThumbBytes!.isNotEmpty
          ? Uint8List.fromList(m.videoThumbBytes!)
          : null;
      // Prefer showing thumbnail while full video downloads. Even without a
      // thumb yet, still expose a video cell — returning [] made the bubble
      // fall back to plain "Вложение" text with no way to tap-download.
      final durationMs = m.videoDurationMs ?? 0;
      final ext = m.isAnimation ? 'gif' : 'mp4';
      final fileId = m.videoFileId;
      final progress = fileId == null ? null : svc.fileDownloadProgress(fileId);
      final hasThumbFile = thumbPath != null && thumbPath.isNotEmpty;
      // Show spinner while the full video downloads on tap (even if thumb ready).
      final tapping = fileId != null && _pendingOpenVideoId == fileId;
      final downloading = fileId != null &&
          (path == null || path.isEmpty) &&
          (tapping ||
              ((!hasThumbFile) && svc.isFileDownloading(fileId)));
      return [
        {
          'id': fileId ?? m.id,
          'kind': 'video',
          'content_type': m.isAnimation ? 'image/gif' : 'video/mp4',
          'filename':
              '${m.isAnimation ? 'animation' : 'video'}_$durationMs.$ext',
          'skip_age_defer': true,
          // Keep video file separate — ChatNetworkImage must not decode mp4.
          if (path != null && path.isNotEmpty) 'video_local_path': path,
          // Thumb only via thumbnail_* — never as local_device_path (player
          // would try to play the jpg).
          if (hasThumbFile) 'thumbnail_local_path': thumbPath,
          // Always keep minithumb bytes as a fallback so the bubble does not
          // go grey if the thumb file path is stale/missing after video load.
          if (thumbBytes != null) ...{
            'thumbnail_bytes': thumbBytes,
            if (!hasThumbFile) 'local_bytes': thumbBytes,
          },
          if (durationMs > 0) 'duration_ms': durationMs,
          if (m.videoWidth != null && m.videoWidth! > 0)
            'width': m.videoWidth,
          if (m.videoHeight != null && m.videoHeight! > 0)
            'height': m.videoHeight,
          if (downloading) 'is_downloading': true,
          if (downloading && progress != null) 'download_progress': progress,
        },
      ];
    }

    if (m.isDocument) {
      final fileId = m.documentFileId;
      final path = m.documentLocalPath ??
          (fileId == null ? null : svc.cachedFilePath(fileId));
      final thumbPath = m.documentThumbLocalPath ??
          (m.documentThumbFileId == null
              ? null
              : svc.cachedFilePath(m.documentThumbFileId!));
      final thumbBytes =
          m.documentThumbBytes != null && m.documentThumbBytes!.isNotEmpty
              ? Uint8List.fromList(m.documentThumbBytes!)
              : null;
      final name = (m.documentFileName ?? '').trim();
      final mime = (m.documentMimeType ?? '').trim();
      final downloading = fileId != null &&
          (path == null || path.isEmpty) &&
          svc.isFileDownloading(fileId);
      final progress = fileId == null ? null : svc.fileDownloadProgress(fileId);
      return [
        {
          'id': fileId ?? m.id,
          'kind': 'file',
          'content_type': mime.isNotEmpty
              ? mime
              : (name.toLowerCase().endsWith('.pdf')
                  ? 'application/pdf'
                  : 'application/octet-stream'),
          'filename': name.isNotEmpty ? name : 'file_${fileId ?? m.id}',
          'skip_age_defer': true,
          'tdlib_file_id': fileId,
          if (m.documentSizeBytes != null && m.documentSizeBytes! > 0)
            'size_bytes': m.documentSizeBytes,
          if (path != null && path.isNotEmpty) 'local_device_path': path,
          if (thumbPath != null && thumbPath.isNotEmpty)
            'thumbnail_local_path': thumbPath,
          if ((thumbPath == null || thumbPath.isEmpty) && thumbBytes != null)
            'thumbnail_bytes': thumbBytes,
          if (downloading) 'is_downloading': true,
          if (downloading && progress != null) 'download_progress': progress,
        },
      ];
    }

    final path = svc.resolvedPhotoPath(m);
    final fileId = m.photoRemoteId;
    final hasPath = path != null && path.isNotEmpty;
    final readyPath = hasPath ? path : null;
    // Never File.existsSync() here — itemBuilder runs for every photo in
    // cacheExtent on each scroll frame; sync disk I/O kills ballistic fling
    // in media-heavy groups (ТП НСИС…). Stale paths fail in Image and
    // re-queue via invalidateCachedFile on error / focus.
    // Do NOT seed focus from every ListView tile — that raced openMessageContent
    // and cancelled CDN downloads. Viewport scroll owns exclusive focus.

    final thumbBytes = m.photoThumbBytes != null && m.photoThumbBytes!.isNotEmpty
        ? Uint8List.fromList(m.photoThumbBytes!)
        : null;
    // Always expose a photo slot so the bubble does not collapse to text-only
    // while TDLib downloads (and so updateFile can paint the image).
    if (readyPath == null && thumbBytes == null && fileId == null) {
      return const [];
    }
    final downloading =
        fileId != null && readyPath == null && svc.isFileDownloading(fileId);
    final progress = fileId == null ? null : svc.fileDownloadProgress(fileId);
    return [
      {
        'id': fileId ?? m.id,
        'kind': 'image',
        'content_type': 'image/jpeg',
        'filename': 'tg_${fileId ?? m.id}.jpg',
        // TDLib files are not FamilyChat API attachments — skip age-gate
        // "Load" which would hit the wrong downloader.
        'skip_age_defer': true,
        if (readyPath != null) 'local_device_path': readyPath,
        // Real photo size — keeps bubble media full-width before decode.
        if (m.photoWidth != null && m.photoWidth! > 0) 'width': m.photoWidth,
        if (m.photoHeight != null && m.photoHeight! > 0)
          'height': m.photoHeight,
        // Minithumb only while full file is missing — otherwise album tap
        // treats local_bytes as "preview only" and disables open.
        if (readyPath == null && thumbBytes != null) ...{
          'local_bytes': thumbBytes,
          'thumbnail_bytes': thumbBytes,
        },
        // Only while TDLib is actually downloading — never spin forever when
        // the file is merely missing (Connecting / not queued / stalled).
        if (downloading) 'is_downloading': true,
        if (downloading && progress != null) 'download_progress': progress,
      },
    ];
  }

  Map<String, dynamic> _messageMetadata(TdlibMessage m) {
    if (m.isVoiceNote) {
      final durationMs = m.voiceDurationMs;
      return {
        'voice': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isVideoNote) {
      final durationMs = m.videoNoteDurationMs;
      return {
        'video_note': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isSticker) {
      return {
        'sticker': {
          'source': 'telegram',
          if (m.stickerEmoji != null && m.stickerEmoji!.isNotEmpty)
            'emoji': m.stickerEmoji,
        },
      };
    }
    if (m.isAnimation) {
      final durationMs = m.videoDurationMs;
      return {
        'gif': {
          'source': 'telegram',
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isVideo) {
      final durationMs = m.videoDurationMs;
      return {
        'video': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isDocument) {
      return {
        'file': {
          if (m.documentFileName != null) 'filename': m.documentFileName,
          if (m.documentMimeType != null) 'mime_type': m.documentMimeType,
        },
      };
    }
    return const {};
  }

  String _messagePreviewLabel(TdlibMessage m) {
    if (m.isVoiceNote) return 'Голосовое сообщение';
    if (m.isVideoNote) return 'Видеосообщение';
    if (m.isSticker) {
      final e = (m.stickerEmoji ?? '').trim();
      return e.isNotEmpty ? e : 'Стикер';
    }
    if (m.isVideo) return m.isAnimation ? 'GIF' : 'Видео';
    if (m.isDocument) {
      final name = (m.documentFileName ?? '').trim();
      return name.isNotEmpty ? name : 'Файл';
    }
    return m.text;
  }

  Map<String, dynamic>? _replyMap(
    TdlibMessage m,
    TelegramTdlibService svc, [
    Map<int, TdlibMessage>? byId,
  ]) {
    final id = m.replyToMessageId;
    if (id == null) return null;
    final found = byId?[id] ??
        svc.messagesFor(widget.chatId).where((x) => x.id == id).firstOrNull;
    final preview = m.replyPreviewText.isNotEmpty
        ? m.replyPreviewText
        : (found == null ? '' : _messagePreviewLabel(found));
    final sender = found == null
        ? 'Сообщение'
        : (found.isOutgoing
            ? 'Вы'
            : svc.senderDisplayName(found.senderUserId));
    return {
      'id': id,
      'sender_name': sender,
      'body': preview,
    };
  }

  @override
  Widget build(BuildContext context) {
    final sw = Stopwatch()..start();
    final svc = ref.watch(telegramTdlibServiceProvider);
    final messages = svc.messagesFor(widget.chatId);
    _maybeReassertUnreadAfterHistoryGrowth(messages.length);
    final wallpaperId = ref.watch(chatWallpaperIdProvider);
    final title = svc.peerTitle(widget.chatId);
    final displayTitle = title == 'Telegram' ? widget.title : title;
    final avatarPath = svc.peerAvatarPath(widget.chatId);
    final status = svc.peerStatusSubtitle(widget.chatId);
    final connLabel = svc.connectionStatusLabel;
    final connPending = !svc.isMtprotoReadyForMedia;
    final subtitle = connPending
        ? (connLabel.isNotEmpty ? connLabel : 'подключение…')
        : status;
    final isGroup = svc.isGroupChat(widget.chatId);
    final isChannel = svc.isChannelChat(widget.chatId);
    final isGroupLike = isGroup || isChannel;
    final reversedRows = _reversedTimelineCached(messages);
    final messagesById = <int, TdlibMessage>{
      for (final m in messages) m.id: m,
    };
    TgJankLog.build(
      chatId: widget.chatId,
      ms: sw.elapsedMilliseconds,
      msgs: messages.length,
      rows: reversedRows.length,
      contentReady: _contentReady,
      linkPreviews: _linkPreviewsEnabled,
    );
    final pinnedId = svc.pinnedMessageId(widget.chatId);
    final pinnedMsg = pinnedId == null ? null : messagesById[pinnedId];
    final canSend = svc.canSendMessages(widget.chatId);
    final showCompose = !_selectionMode && canSend;
    final composePad = !showCompose
        ? 0.0
        : 72.0 +
            (_replyTo != null ? 56.0 : 0.0) +
            (_editing != null ? 56.0 : 0.0);

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: Colors.transparent,
        appBar: _selectionMode
            ? FamilyAppBar.build(
                title: '${_selectedIds.length} выбрано',
                automaticallyImplyLeading: false,
                leading: IconButton(
                  tooltip: 'Отменить выбор',
                  onPressed: _exitSelection,
                  icon: const Icon(LucideIcons.x),
                ),
                actions: [
                  IconButton(
                    tooltip: 'Переслать',
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => unawaited(
                              _forwardMessages(_selectedIds.toList()),
                            ),
                    icon: const Icon(LucideIcons.forward),
                  ),
                  IconButton(
                    tooltip: 'Скопировать',
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => unawaited(_copySelected(messages)),
                    icon: const Icon(LucideIcons.copy),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => unawaited(_deleteSelected(revoke: false)),
                    icon: const Icon(LucideIcons.trash),
                  ),
                ],
              )
            : FamilyAppBar.buildCustom(
                title: InkWell(
                  onTap: _openPeerInfo,
                  child: Row(
                    children: [
                      ChatAvatar(
                        name: displayTitle,
                        avatarUrl: widget.peerAvatarUrl.isEmpty
                            ? null
                            : widget.peerAvatarUrl,
                        // FC photo wins when linked; TG only if FC has none.
                        localFilePath: widget.peerAvatarUrl.isEmpty
                            ? avatarPath
                            : null,
                        memoryBytes: widget.peerAvatarUrl.isEmpty
                            ? svc.peerAvatarMinithumbnailBytes(widget.chatId)
                            : null,
                        userId: widget.fcUserId,
                        radius: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle.isNotEmpty)
                              Row(
                                children: [
                                  if (connPending) ...[
                                    SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  IconButton(
                    tooltip: 'Поиск',
                    onPressed: () => unawaited(_openSearch()),
                    icon: const Icon(LucideIcons.search),
                  ),
                ],
              ),
        body: ChatWallpaperBackdrop(
          wallpaperId: wallpaperId,
          child: Column(
            children: [
              if (pinnedMsg != null && !_selectionMode)
                ChatPinnedBar(
                  message: {
                    'id': pinnedMsg.id,
                    'body': _messagePreviewLabel(pinnedMsg),
                    'sender_name': pinnedMsg.isOutgoing
                        ? 'Вы'
                        : svc.senderDisplayName(pinnedMsg.senderUserId),
                  },
                  index: 0,
                  total: 1,
                  previewText: _messagePreviewLabel(pinnedMsg),
                  onTap: () {},
                  onClose: () => unawaited(
                    svc.unpinMessage(
                      widget.chatId,
                      messageId: pinnedMsg.id,
                    ),
                  ),
                ),
              if (!_selectionMode)
                Builder(
                  builder: (context) {
                    final live = svc.videoChatFor(widget.chatId);
                    if (live == null) return const SizedBox.shrink();
                    return TelegramLiveStreamBar(
                      videoChat: live,
                      joining: _joiningLiveStream,
                      onJoin: () => unawaited(_joinLiveStream()),
                    );
                  },
                ),
              Expanded(
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Opacity(
                            opacity: _contentReady ? 1 : 0,
                            child: IgnorePointer(
                              ignoring: !_contentReady,
                              child: ChatAnimatedMediaScope(
                                controller: _animatedMediaController,
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: (n) {
                                    if (n is ScrollUpdateNotification &&
                                        n.dragDetails != null) {
                                      _animatedMediaController.noteUserScroll();
                                    } else if (n is ScrollEndNotification) {
                                      _animatedMediaController.noteScrollEnd();
                                    }
                                    return false;
                                  },
                                  child: ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        // Modest cache — photo rows are tall; 2800px kept too
                        // many decodes warm and blocked ballistic fling.
                        cacheExtent: 1200,
                        addAutomaticKeepAlives: false,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + composePad),
                        itemCount: reversedRows.length,
                        itemBuilder: (context, i) {
                          TgJankLog.itemBuilderTick();
                          final rowItem = reversedRows[i];
                          final m = rowItem.primary;
                          final created = m.date > 0
                              ? DateTime.fromMillisecondsSinceEpoch(
                                  m.date * 1000,
                                )
                              : null;
                          final prevRow = i + 1 < reversedRows.length
                              ? reversedRows[i + 1]
                              : null;
                          final nextRow = i > 0 ? reversedRows[i - 1] : null;
                          final prev = prevRow?.primary;
                          final next = nextRow?.primary;
                          final compactPrev = prev != null &&
                              prev.isOutgoing == m.isOutgoing &&
                              prev.senderUserId == m.senderUserId;
                          final compactNext = next != null &&
                              next.isOutgoing == m.isOutgoing &&
                              next.senderUserId == m.senderUserId;
                          final showSender =
                              isGroup && !m.isOutgoing && m.senderUserId > 0;
                          final showAvatar = showSender && !compactNext;
                          final senderAvatarPath = showAvatar
                              ? svc.senderAvatarPath(m.senderUserId)
                              : null;
                          final senderAvatarBytes = showAvatar
                              ? svc.senderAvatarMinithumbnailBytes(
                                  m.senderUserId,
                                )
                              : null;
                          final day = _messageLocalDay(m);
                          final showDay = day != null &&
                              (prev == null || !_sameCalendarDay(m, prev));
                          final showUnread =
                              _unreadAnchorMessageId != null &&
                                  rowItem.containsMessageId(
                                    _unreadAnchorMessageId!,
                                  );

                          final replyId = m.replyToMessageId;
                          final forwardMap = _forwardMap(m);
                          final forwardJumpId = () {
                            final fromChat = forwardMap?['from_chat_id'];
                            final fromMsg = forwardMap?['from_message_id'];
                            if (fromChat is int &&
                                fromMsg is int &&
                                fromChat == widget.chatId) {
                              return fromMsg;
                            }
                            return null;
                          }();

                          final Widget messageBody;
                          if (m.isService) {
                            final canJoin = svc.videoChatFor(widget.chatId) != null;
                            messageBody = GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: canJoin
                                  ? () => unawaited(_joinLiveStream())
                                  : null,
                              child: ChatDaySeparator(
                                label: m.text.isNotEmpty
                                    ? m.text
                                    : 'Началась трансляция',
                                compact: true,
                              ),
                            );
                          } else {
                            messageBody = ChatMessageBubble(
                            threadId: widget.chatId,
                            isMine: m.isOutgoing,
                            body: _bubbleBodyForRow(rowItem),
                            textEntities: _textEntitiesForRow(rowItem),
                            attachments: _attachmentsForRow(rowItem),
                            messageMetadata: _messageMetadataForRow(rowItem),
                            createdAt: created,
                            reactions: _reactionMaps(m),
                            replyTo: _replyMap(m, svc, messagesById),
                            forward: forwardMap,
                            isGroupLike: isGroupLike,
                            showGroupAvatarColumn: isGroup,
                            showSenderAvatar: showAvatar,
                            senderName: showSender && !compactPrev
                                ? svc.senderDisplayName(m.senderUserId)
                                : null,
                            senderAvatarLocalPath: senderAvatarPath,
                            senderAvatarMemoryBytes: senderAvatarBytes,
                            onSenderAvatarTap: showAvatar
                                ? () => unawaited(
                                      _openSenderInfo(m.senderUserId),
                                    )
                                : null,
                            compactWithPrevious: compactPrev,
                            compactWithNext: compactNext,
                            readStatus: m.isOutgoing
                                ? svc.outgoingReadStatus(m)
                                : null,
                            selectionMode: _selectionMode,
                            selected: rowItem.members
                                .any((x) => _selectedIds.contains(x.id)),
                            onTap: () => unawaited(_openMessageMenu(m)),
                            onLongPress: () => unawaited(_openMessageMenu(m)),
                            onImageTap: (att) => unawaited(
                              _openMedia(
                                att,
                                gallery: _attachmentsForRow(rowItem),
                              ),
                            ),
                            onOpenUrl: _handleOpenUrl,
                            showLinkPreview: _linkPreviewsEnabled,
                            onReplyTap: replyId == null
                                ? null
                                : () => _jumpToMessage(replyId),
                            onForwardTap: forwardJumpId == null
                                ? null
                                : () => _jumpToMessage(forwardJumpId),
                            onSwipeReply: (_selectionMode || !canSend)
                                ? null
                                : () => setState(() {
                                      _replyTo = m;
                                      _editing = null;
                                    }),
                            onReactionTap: (emoji) =>
                                unawaited(_toggleReaction(m, emoji)),
                            collapseBodyAfterLines: isChannel ? 10 : null,
                            bodyExpanded: _expandedBodyIds.contains(m.id),
                            onToggleBodyExpand: isChannel
                                ? () => _toggleBodyExpand(m.id)
                                : null,
                          );
                          }

                          final row = (!showDay && !showUnread)
                              ? messageBody
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (showUnread)
                                      KeyedSubtree(
                                        key: _unreadSeparatorKey,
                                        child: const ChatUnreadSeparator(),
                                      ),
                                    if (day != null && showDay)
                                      ChatDaySeparator(
                                        label: formatChatDayLabel(day),
                                      ),
                                    messageBody,
                                  ],
                                );

                          return KeyedSubtree(
                            key: _keyForMessage(m.id),
                            child: RepaintBoundary(child: row),
                          );
                        },
                      ),
                                ),
                              ),
                            ),
                          ),
                          if (_showOpenLoader && !_contentReady)
                            const Center(child: CircularProgressIndicator()),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 8,
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: _showStickyDay &&
                                        (_stickyDayLabel?.isNotEmpty ?? false)
                                    ? 1
                                    : 0,
                                duration: const Duration(milliseconds: 160),
                                child: ChatDaySeparator(
                                  label: _stickyDayLabel ?? '',
                                  compact: true,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12 + (showCompose ? composePad : 0),
                      child: IgnorePointer(
                        ignoring: !_showScrollToBottom || !_contentReady,
                        child: AnimatedOpacity(
                          opacity: _showScrollToBottom ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: AnimatedSlide(
                            offset: _showScrollToBottom
                                ? Offset.zero
                                : const Offset(0.2, 0.15),
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            child: _TgScrollToBottomButton(
                              unreadCount: svc.unreadCountFor(widget.chatId),
                              onPressed: () => unawaited(_scrollToLiveTail()),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (showCompose)
                      SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_replyTo != null)
                              ChatReplyComposeBar(
                                senderName: _replyTo!.isOutgoing
                                    ? 'Вы'
                                    : svc.senderDisplayName(
                                        _replyTo!.senderUserId,
                                      ),
                                body: _messagePreviewLabel(_replyTo!),
                                onCancel: () =>
                                    setState(() => _replyTo = null),
                              ),
                            if (_editing != null)
                              ChatReplyComposeBar(
                                senderName: 'Редактирование',
                                body: _editing!.text,
                                onCancel: () {
                                  setState(() {
                                    _editing = null;
                                    _textCtrl.clear();
                                  });
                                },
                              ),
                            ChatComposeInput(
                              controller: _textCtrl,
                              focusNode: _inputFocus,
                              onAttach: () => unawaited(_pickAttachment()),
                              onSend: (options) =>
                                  unawaited(_sendText(options)),
                              onVoiceComplete:
                                  (bytes, durationMs, {String? encoderName}) =>
                                      _sendVoiceMessage(
                                        bytes,
                                        durationMs,
                                        encoderName: encoderName,
                                      ),
                              onVideoCircleComplete: _sendVideoCircleMessage,
                              forceSendButton: _sending ||
                                  _editing != null ||
                                  _textCtrl.text.trim().isNotEmpty,
                              highlightTelegram: true,
                              preferOpusVoice: true,
                              hintText: _editing != null
                                  ? 'Редактировать…'
                                  : 'Сообщение...',
                            ),
                          ],
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

class _TgScrollToBottomButton extends StatelessWidget {
  const _TgScrollToBottomButton({
    required this.onPressed,
    this.unreadCount = 0,
  });

  final VoidCallback onPressed;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final badge = unreadCount > 0
        ? (unreadCount > 99 ? '99+' : '$unreadCount')
        : null;

    return Semantics(
      button: true,
      label: badge == null ? 'Вниз' : 'Вниз, непрочитанных $badge',
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 52,
          height: 56,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Positioned(
                bottom: 0,
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: cs.outline.withValues(alpha: 0.45),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    LucideIcons.chevron_down,
                    size: 30,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(minWidth: 20),
                    child: Text(
                      badge,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
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

/// One ListView row: a single message or a Telegram media album.
class _TgTimelineRow {
  const _TgTimelineRow._(this.members);

  factory _TgTimelineRow.single(TdlibMessage m) => _TgTimelineRow._([m]);

  factory _TgTimelineRow.album(List<TdlibMessage> members) =>
      _TgTimelineRow._(List<TdlibMessage>.unmodifiable(members));

  final List<TdlibMessage> members;

  bool get isAlbum => members.length > 1;

  TdlibMessage get primary {
    const placeholders = {'Фото', 'Видео', 'GIF'};
    for (final m in members) {
      final t = m.text.trim();
      if (t.isNotEmpty && !placeholders.contains(t)) return m;
    }
    return members.first;
  }

  String get caption {
    const placeholders = {'Фото', 'Видео', 'GIF'};
    for (final m in members) {
      final t = m.text.trim();
      if (t.isNotEmpty && !placeholders.contains(t)) return t;
    }
    return '';
  }

  bool containsMessageId(int id) => members.any((m) => m.id == id);
}
