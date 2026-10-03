import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/diagnostics/session_log.dart';
import '../../../core/theme/appearance_prefs.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/data/chat_location_utils.dart';
import '../../chat/data/chat_send_options.dart';
import '../../chat/data/chat_ui_connectivity.dart';
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
import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../telegram_match_store.dart';
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
  Timer? _mediaIdleRescanTimer;
  /// Avoid stacking idle rescans while one is already armed.
  int _mediaIdleRescanGen = 0;
  void Function()? _viewportMediaRescanListener;
  Timer? _markVisibleReadTimer;
  Timer? _scrollBusyClearTimer;
  Timer? _reassertUnreadScrollTimer;
  Timer? _openRevealTimeout;
  Timer? _stickyDayThrottle;
  String? _stickyDayLabel;
  bool _showStickyDay = false;
  /// Highest message id we already sent to viewMessages this session.
  int _maxMarkedReadId = 0;
  /// Token from [TelegramTdlibService.openChat] — stale dispose must not close
  /// a re-opened session of the same chat.
  int? _openChatToken;
  DateTime? _lastUserScrollAt;
  /// True while open-positioning drives jumpTo/ensureVisible — must not be
  /// treated as a user fling (that used to force-reveal before the divider).
  bool _programmaticOpenScroll = false;
  final Set<int> _expandedBodyIds = {};
  final Map<int, GlobalKey> _messageKeys = {};
  final GlobalKey _unreadSeparatorKey = GlobalKey();
  /// Inflated during unread open so ensureVisible can mount the frontier row.
  double _listCacheExtent = 1200;

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
    if (_programmaticOpenScroll) {
      // Still allow older-page load near the end, but never treat this as a
      // user takeover / force-reveal.
      if (_scroll.position.pixels >=
          _scroll.position.maxScrollExtent - 200) {
        if (!_loadingOlder) unawaited(_loadOlder());
      }
      return;
    }
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
    // Never force-reveal on deep-unread opens until the divider is pinned
    // (programmatic jumpTo used to trip this and paint the wrong place).
    if (_initialScrollDone &&
        _suppressMarkRead &&
        _isUserActivelyScrolling &&
        _openUnreadCount > 0 &&
        _unreadFrontierReady) {
      _suppressMarkRead = false;
      _revealChatContent();
    } else if (_initialScrollDone &&
        _suppressMarkRead &&
        _isUserActivelyScrolling &&
        _openUnreadCount > 0 &&
        _openUnreadCount < 2) {
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
      _armIdleMediaRescan();
    });
  }

  void _scheduleMarkVisibleRead() {
    if (_suppressMarkRead) return;
    _markVisibleReadTimer?.cancel();
    // While scrolling: still mark periodically so the FAB unread badge drops
    // as rows leave the viewport (was deferred until scroll-end forever).
    final delay = _isUserActivelyScrolling
        ? const Duration(milliseconds: 140)
        : _markVisibleReadDebounce;
    _markVisibleReadTimer = Timer(delay, () {
      if (!mounted || _suppressMarkRead) return;
      unawaited(_markVisibleMessagesRead());
      if (_isUserActivelyScrolling) {
        _scheduleMarkVisibleRead();
      }
    });
  }

  /// Keep watching the viewport after focus settles — hold expiry / wrong
  /// neighbor focus used to leave the on-screen soft photo stuck forever.
  void _armIdleMediaRescan() {
    if (_suppressViewportPrefetch || !_contentReady) return;
    _mediaIdleRescanTimer?.cancel();
    final gen = ++_mediaIdleRescanGen;
    _mediaIdleRescanTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted || gen != _mediaIdleRescanGen) return;
      if (_suppressViewportPrefetch || !_contentReady) return;
      if (_isUserActivelyScrolling) {
        _armIdleMediaRescan();
        return;
      }
      final svc = ref.read(telegramTdlibServiceProvider);
      final focusId = _pickVisibleSoftMediaMessageId(svc);
      if (focusId == null) return;
      // Already downloading this focus — just keep watching.
      final msgs = svc.messagesFor(widget.chatId);
      TdlibMessage? m;
      for (final x in msgs) {
        if (x.id == focusId) {
          m = x;
          break;
        }
      }
      final busyId = m?.photoRemoteId ??
          m?.videoThumbFileId ??
          m?.videoNoteThumbFileId ??
          m?.documentThumbFileId;
      if (busyId != null && svc.isFileDownloading(busyId)) {
        _armIdleMediaRescan();
        return;
      }
      // Force: ignore leftover hold from a neighbor that already finished.
      svc.prefetchOpenChatViewport(
        chatId: widget.chatId,
        focusMessageId: focusId,
        forceFocus: true,
      );
      _armIdleMediaRescan();
    });
  }

  void _onViewportMediaRescanFromService() {
    if (!mounted || _suppressViewportPrefetch) return;
    _scheduleViewportPrefetch();
    _armIdleMediaRescan();
  }

  DateTime? _lastViewportNoneLogAt;

  /// Exclusive focus: pick soft media that is actually on screen via GlobalKeys.
  void _prefetchAroundViewport() {
    if (!_scroll.hasClients) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = svc.messagesFor(widget.chatId);
    if (msgs.isEmpty) return;

    final layoutId = _pickVisibleSoftMediaMessageId(svc);
    final focusId = layoutId ?? _estimateSoftMediaNearScroll(svc);
    if (focusId == null) {
      // Layout not ready (px=0 / empty extent) — keep prior media focus; do
      // not log none flaps that SessionLog showed on every cold open.
      if (!_scroll.hasClients) return;
      final maxExt = _scroll.position.maxScrollExtent;
      final px = _scroll.position.pixels;
      if (maxExt <= 0 || (px <= 0 && _messageKeys.length < 4)) {
        return;
      }
      final now = DateTime.now();
      final last = _lastViewportNoneLogAt;
      if (last == null || now.difference(last) > const Duration(seconds: 3)) {
        _lastViewportNoneLogAt = now;
        SessionLog.instance.event('tg.ui', 'viewport_focus_none', {
          'chatId': widget.chatId,
          'msgs': msgs.length,
          'px': px,
          'max': maxExt,
          'keys': _messageKeys.length,
        });
      }
      return;
    }

    SessionLog.instance.event('tg.ui', 'viewport_focus', {
      'chatId': widget.chatId,
      'msgId': focusId,
      'source': layoutId != null ? 'layout' : 'estimate',
      'px': _scroll.position.pixels,
      'max': _scroll.position.maxScrollExtent,
      'keys': _messageKeys.length,
    });

    svc.prefetchOpenChatViewport(
      chatId: widget.chatId,
      focusMessageId: focusId,
      // Settled viewport pick must beat leftover 4s hold from a prior row.
      forceFocus: true,
    );
  }

  /// Real layout hit-test: which soft-media row intersects the viewport,
  /// preferring the one closest to the visual center.
  int? _pickVisibleSoftMediaMessageId(TelegramTdlibService svc) {
    if (!_scroll.hasClients) return null;
    final scrollCtx = _scroll.position.context.notificationContext;
    final viewportBox = scrollCtx?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return null;

    final listTop = viewportBox.localToGlobal(Offset.zero).dy;
    final listH = viewportBox.size.height;
    if (listH <= 0) return null;
    final listBottom = listTop + listH;
    final centerY = listTop + listH * 0.42;

    final msgs = svc.messagesFor(widget.chatId);
    if (msgs.isEmpty) return null;
    final byId = <int, TdlibMessage>{for (final m in msgs) m.id: m};

    int? bestId;
    var bestPriority = 99;
    var bestScore = double.infinity;

    for (final entry in _messageKeys.entries) {
      final id = entry.key;
      final m = byId[id];
      if (m == null) continue;
      if (!svc.mediaNeedsViewportFocus(m)) continue;

      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= listTop + 4 || top >= listBottom - 4) continue;

      final mid = (top + bottom) * 0.5;
      final dist = (mid - centerY).abs();
      final coversCenter = top <= centerY && bottom >= centerY;
      // Photo upgrades beat video thumbs; both beat docs/stickers.
      final priority = svc.photoNeedsFocusDownload(m)
          ? 0
          : (m.isVideo || m.isAnimation || m.isVideoNote)
              ? 1
              : 2;
      final score = coversCenter ? dist : dist + listH;

      if (priority < bestPriority ||
          (priority == bestPriority && score < bestScore)) {
        bestPriority = priority;
        bestScore = score;
        bestId = id;
      }
    }
    return bestId;
  }

  /// Fallback when GlobalKeys are not mounted yet (open settle / sparse build).
  int? _estimateSoftMediaNearScroll(TelegramTdlibService svc) {
    final msgs = svc.messagesFor(widget.chatId);
    if (msgs.isEmpty || !_scroll.hasClients) return null;
    final timeline = _buildTimeline(msgs);
    if (timeline.isEmpty) return null;

    // Slightly taller than before — still only a fallback for cold frames.
    const avgExtent = 360.0;
    final pixels = _scroll.position.pixels;
    final viewport = _scroll.position.viewportDimension;
    final centerPixels = pixels + viewport * 0.42;
    final reversedIndex =
        (centerPixels / avgExtent).floor().clamp(0, timeline.length - 1);
    final chronoIndex = timeline.length - 1 - reversedIndex;
    final maxDist = (viewport / avgExtent).ceil().clamp(6, 24);

    int? pick(bool Function(_TgTimelineRow row) want) {
      for (var dist = 0; dist <= maxDist; dist++) {
        for (final sign in dist == 0 ? <int>[0] : <int>[-1, 1]) {
          final i = chronoIndex + sign * dist;
          if (i < 0 || i >= timeline.length) continue;
          final row = timeline[i];
          if (want(row)) return row.primary.id;
        }
      }
      return null;
    }

    return pick((row) => row.members.any(svc.photoNeedsFocusDownload)) ??
        pick((row) => row.members.any(svc.mediaNeedsViewportFocus));
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

    final lastRead = svc.lastReadInboxMessageId(widget.chatId);
    final floor = _maxMarkedReadId > lastRead ? _maxMarkedReadId : lastRead;

    // Prefer real layout hit-test (media-heavy channels like Mash have uneven
    // row heights — avgExtent estimate under-marked while scrolling).
    var highestVisibleUnread =
        _highestVisibleUnreadByLayout(msgs: msgs, floor: floor);
    if (highestVisibleUnread <= 0) {
      const avgExtent = 220.0;
      final pixels = _scroll.position.pixels;
      final viewport = _scroll.position.viewportDimension;
      final topPx = pixels;
      final bottomPx = pixels + viewport;
      final firstRev =
          (topPx / avgExtent).floor().clamp(0, timeline.length - 1);
      final lastRev =
          (bottomPx / avgExtent).ceil().clamp(0, timeline.length - 1);
      for (var rev = firstRev; rev <= lastRev; rev++) {
        final chrono = timeline.length - 1 - rev;
        if (chrono < 0 || chrono >= timeline.length) continue;
        for (final m in timeline[chrono].members) {
          if (m.isOutgoing) continue;
          if (m.id <= floor) continue;
          if (m.id > highestVisibleUnread) highestVisibleUnread = m.id;
        }
      }
    }
    if (highestVisibleUnread <= 0) return;

    _maxMarkedReadId = highestVisibleUnread;
    await svc.markMessagesRead(widget.chatId, [highestVisibleUnread]);
    // FAB badge reads live unreadCountFor — bump UI while scroll-busy defers
    // media notifies (mark-read must still refresh the counter).
    if (mounted) setState(() {});
    // Unread divider stays for this visit even after reading past the anchor.
  }

  /// Highest inbound message id whose row intersects the viewport.
  int _highestVisibleUnreadByLayout({
    required List<TdlibMessage> msgs,
    required int floor,
  }) {
    if (!_scroll.hasClients) return 0;
    final scrollCtx = _scroll.position.context.notificationContext;
    final viewportBox = scrollCtx?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return 0;
    final listTop = viewportBox.localToGlobal(Offset.zero).dy;
    final listBottom = listTop + viewportBox.size.height;
    final byId = <int, TdlibMessage>{for (final m in msgs) m.id: m};
    var highest = 0;
    for (final entry in _messageKeys.entries) {
      final m = byId[entry.key];
      if (m == null || m.isOutgoing || m.id <= floor) continue;
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= listTop + 4 || top >= listBottom - 4) continue;
      if (m.id > highest) highest = m.id;
    }
    return highest;
  }

  /// When [requireSeparatorAtTop] is true (deep unread open), only the
  /// «Непрочитанные» bar in the top band counts — a message-key overlap used
  /// to report success while parked deep in already-read history.
  bool _isUnreadAnchorInViewport({bool requireSeparatorAtTop = false}) {
    if (!_scroll.hasClients) return false;
    final sepCtx = _unreadSeparatorKey.currentContext;
    final listBox = _scroll.position.context.storageContext.findRenderObject()
        as RenderBox?;
    if (listBox == null || !listBox.hasSize) return false;
    final viewH = listBox.size.height;

    if (sepCtx != null && sepCtx.mounted) {
      final box = sepCtx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return false;
      final topLeft = box.localToGlobal(Offset.zero, ancestor: listBox);
      final bottom = topLeft.dy + box.size.height;
      // Generous top band — padding + day chip can push the bar down a bit.
      final ok = topLeft.dy >= -48 && topLeft.dy <= 280 && bottom > 0;
      if (ok) return true;
      // Few short unreads (Шарий, unread=2): the bar is on screen but the
      // reverse list is already at offset 0, so it cannot be pulled to the
      // top. Treating that as a miss kept the transcript at opacity 0.
      final onScreen = bottom > 8 && topLeft.dy < viewH - 8;
      // Offset 0 is the newest edge of a reverse list — nothing left to pull up.
      final stuckAtNewest = _scroll.position.pixels <= 2.0;
      if (requireSeparatorAtTop && onScreen && stuckAtNewest) {
        TgJankLog.log(
          'open-sep-at-tip dy=${topLeft.dy.toStringAsFixed(0)} '
          'viewH=${viewH.toStringAsFixed(0)}',
        );
        return true;
      }
      if (requireSeparatorAtTop) {
        TgJankLog.log(
          'open-sep-miss dy=${topLeft.dy.toStringAsFixed(0)} '
          'h=${box.size.height.toStringAsFixed(0)} viewH=${viewH.toStringAsFixed(0)}',
        );
      }
      return false;
    }

    if (requireSeparatorAtTop) {
      TgJankLog.log('open-sep-miss sep=null anchor=$_unreadAnchorMessageId');
      return false;
    }

    final anchorId = _unreadAnchorMessageId;
    if (anchorId == null) return false;
    final svc = ref.read(telegramTdlibServiceProvider);
    final timeline = _buildTimeline(svc.messagesFor(widget.chatId));
    final keyId = _visibleKeyMessageId(anchorId, timeline);
    final ctx = _keyForMessage(keyId).currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: listBox);
    final bottom = topLeft.dy + box.size.height;
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

    // Scale pages with unread depth — Осташко (~60+) needs more than a tip page.
    final maxPages = (unread / 20).ceil().clamp(6, 16);
    const pageSize = 50;
    // Hard ceiling only after the read frontier is in RAM.
    final hardCap = (unread + 80).clamp(120, 400);
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
      // Reached the read frontier (or older) — divider target is in RAM.
      if (lastRead > 0 && msgs.first.id <= lastRead) return;
      // Continuous history from tip: enough unreads means firstUnread is known.
      final loadedUnread = lastRead > 0
          ? msgs.where((m) => m.id > lastRead).length
          : msgs.length;
      if (loadedUnread >= unread && lastRead > 0) return;
      // Never soft-cap while last_read is still older than everything loaded.
      if (msgs.length >= hardCap && loadedUnread >= unread) return;

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
    // Deep unread: prefer spinner + keep pinning over painting the wrong
    // place. Soft-reveal only after a long wait, still reasserting.
    _openRevealTimeout = Timer(const Duration(milliseconds: 9000), () {
      if (!mounted || _contentReady) return;
      _initialScrollDone = true;
      TgJankLog.log(
        'open-reveal-timeout frontier=$_unreadFrontierReady '
        'anchor=$_unreadAnchorMessageId unread=$_openUnreadCount',
      );
      if (!_unreadFrontierReady) {
        // Short unread tail already on screen (cannot pin the bar to the top).
        if (_isUnreadAnchorInViewport(requireSeparatorAtTop: true)) {
          _unreadFrontierReady = true;
          _suppressMarkRead = false;
          _revealChatContent();
          return;
        }
        unawaited(_reassertUnreadScroll());
        // Keep hidden for deep stacks — timeout alone must not flash tip.
        if (_openUnreadCount >= 2) return;
      }
      _revealChatContent();
    });
  }

  Future<bool> _ensureVisibleMessage(
    int messageId, {
    double alignment = 0.12,
    bool instant = false,
    int? unreadHint,
  }) async {
    if (!mounted) return false;
    if (_isUserActivelyScrolling && !_programmaticOpenScroll) return false;
    // Rough jump so the builder mounts the target row.
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = svc.messagesFor(widget.chatId);
    final timeline = _buildTimeline(msgs);
    final rowIndex =
        timeline.indexWhere((r) => r.containsMessageId(messageId));
    if (rowIndex < 0) return false;
    final keyId = _visibleKeyMessageId(messageId, timeline);

    final wasProgrammatic = _programmaticOpenScroll;
    _programmaticOpenScroll = true;
    // Wide cache so the frontier row mounts even when the first estimate is off.
    if (_listCacheExtent < 6000) {
      setState(() => _listCacheExtent = 8000);
      await WidgetsBinding.instance.endOfFrame;
    }
    try {
    if (_scroll.hasClients) {
      final listIndex = timeline.length - 1 - rowIndex;
      final max = _scroll.position.maxScrollExtent;
      final unread = unreadHint ?? _openUnreadCount;
      final rawAvg =
          timeline.isEmpty ? 220.0 : (max / timeline.length);
      // Use real average when layout has settled; only fall back when max≈0.
      final avg = rawAvg < 40 ? (unread >= 12 ? 280.0 : 200.0) : rawAvg;
      // Slight bias toward older (higher offset) so separator enters from above.
      final estimated = (listIndex * avg * 1.08).clamp(0.0, max);
      TgJankLog.log(
        'open-jump target=$messageId listIndex=$listIndex/'
        '${timeline.length} unread=$unread max=${max.toStringAsFixed(0)} '
        'avg=${avg.toStringAsFixed(0)} est=${estimated.toStringAsFixed(0)}',
      );
      _scroll.jumpTo(estimated);
    }

    // Opening path must never animate — animations are the visible “jumps”.
    final useInstant = instant || !_contentReady;

    for (var attempt = 0; attempt < 20; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      if (_isUserActivelyScrolling && !_programmaticOpenScroll) return false;
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
          for (var pin = 0; pin < 6; pin++) {
            await _pinUnreadSeparatorToTop();
            await WidgetsBinding.instance.endOfFrame;
            if (_isUnreadAnchorInViewport(requireSeparatorAtTop: true)) {
              break;
            }
            // Separator not built yet — step toward tip first (lower offset)
            // only when the key is missing; if it's on-screen but low, the
            // manual pin above already corrected by -dy.
            final sepCtx = _unreadSeparatorKey.currentContext;
            if (sepCtx == null && _scroll.hasClients && pin < 5) {
              final pos = _scroll.position;
              final step = 480.0 * (pin + 1);
              // Higher offset = older. Hunt the frontier row into cache.
              _scroll.jumpTo(
                (pos.pixels + step).clamp(0.0, pos.maxScrollExtent),
              );
              await WidgetsBinding.instance.endOfFrame;
              final againCtx = _keyForMessage(keyId).currentContext;
              if (againCtx != null && againCtx.mounted) {
                await Scrollable.ensureVisible(
                  againCtx,
                  duration: Duration.zero,
                  alignment: 0.0,
                );
              }
            }
          }
          return _isUnreadAnchorInViewport(requireSeparatorAtTop: true);
        }
        return true;
      }
      if (_scroll.hasClients) {
        final pos = _scroll.position;
        final listIndex = timeline.length - 1 - rowIndex;
        final max = pos.maxScrollExtent;
        final rawAvg =
            timeline.isEmpty ? 220.0 : (max / timeline.length);
        final avg = rawAvg < 40 ? 240.0 : rawAvg;
        final base = (listIndex * avg * (1.0 + attempt * 0.06))
            .clamp(0.0, max);
        final drift =
            400.0 * ((attempt ~/ 2) + 1) * (attempt.isEven ? 1 : -1);
        _scroll.jumpTo((base + drift).clamp(0.0, max));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return false;
    } finally {
      _programmaticOpenScroll = wasProgrammatic;
    }
  }

  /// Scroll so «Непрочитанные сообщения» sits at the top of the chat area.
  Future<void> _pinUnreadSeparatorToTop() async {
    if (!mounted) return;
    // jumpTo/ensureVisible trip isScrollingNotifier — must not abort the
    // open-path pin (that left Осташко on an eternal spinner).
    if (!_programmaticOpenScroll && _isUserActivelyScrolling) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (!_programmaticOpenScroll && _isUserActivelyScrolling) return;
    if (!_scroll.hasClients) return;
    final ctx = _unreadSeparatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      TgJankLog.log('open-pin sep=null anchor=$_unreadAnchorMessageId');
      return;
    }
    final box = ctx.findRenderObject() as RenderBox?;
    final listBox = _scroll.position.context.storageContext.findRenderObject()
        as RenderBox?;
    if (box == null || !box.hasSize || listBox == null || !listBox.hasSize) {
      return;
    }
    final dy = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
    // ensureVisible is a no-op when the bar is already fully on-screen
    // (e.g. dy=222) — so nudge the reverse ListView by hand. On reverse
    // lists, decreasing pixels moves content toward the visual top.
    if (dy.abs() <= 8) return;
    final pos = _scroll.position;
    final target = (pos.pixels - dy).clamp(0.0, pos.maxScrollExtent);
    TgJankLog.log(
      'open-pin dy=${dy.toStringAsFixed(0)} px=${pos.pixels.toStringAsFixed(0)} '
      '→ ${target.toStringAsFixed(0)}',
    );
    _scroll.jumpTo(target);
  }

  Future<void> _positionInitialScroll(TelegramTdlibService svc) async {
    if (_initialScrollDone || !mounted) return;
    _suppressMarkRead = true;
    _unreadFrontierReady = false;
    _programmaticOpenScroll = true;
    if (_listCacheExtent < 6000) {
      setState(() => _listCacheExtent = 8000);
      await WidgetsBinding.instance.endOfFrame;
    }

    try {
    await _ensureUnreadHistoryLoaded(svc);
    if (!mounted) return;

    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    final firstUnread = _resolveFirstUnreadId(svc);
    final msgs = svc.messagesFor(widget.chatId);

    // No unreads → tip is correct.
    if (unread <= 0) {
      _initialScrollDone = true;
      _unreadFrontierReady = true;
      _scrollToBottom(jump: true, settle: true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) _revealChatContent();
      _suppressMarkRead = false;
      _scheduleViewportPrefetch();
      _scheduleMarkVisibleRead();
      await _markCaughtUp();
      return;
    }

    // Unreads exist but frontier not in RAM yet — NEVER jump to tip (that
    // left Осташко parked on newest posts with the 61 FAB). Keep hidden and
    // retry as history pages in.
    if (firstUnread == null || msgs.isEmpty) {
      _initialScrollDone = true;
      _scheduleReassertUnreadScroll();
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
      unreadHint: unread,
    );
    final needSep = unread >= 2;
    if (ok &&
        !_isUnreadAnchorInViewport(requireSeparatorAtTop: needSep)) {
      ok = false;
    }
    if (!ok && mounted) {
      // History may still be growing — retry a few times before giving up.
      for (var i = 0; i < 10 && mounted && !ok; i++) {
        await Future<void>.delayed(Duration(milliseconds: 80 + i * 60));
        if (!mounted) return;
        await _ensureUnreadHistoryLoaded(svc);
        final again = _resolveFirstUnreadId(svc);
        if (again != null) anchorId = again;
        if (mounted && again != null) {
          setState(() => _unreadAnchorMessageId = again);
        }
        ok = await _ensureVisibleMessage(
          anchorId,
          alignment: 0.0,
          instant: true,
          unreadHint: unread,
        );
        if (ok &&
            !_isUnreadAnchorInViewport(requireSeparatorAtTop: needSep)) {
          ok = false;
        }
      }
    }
    _initialScrollDone = true;
    _msgsLenAtUnreadJump = svc.messagesFor(widget.chatId).length;
    final pinned = _isUnreadAnchorInViewport(requireSeparatorAtTop: needSep);
    TgJankLog.log(
      'open-pos done ok=$ok pinned=$pinned anchor=$anchorId '
      'unread=$unread msgs=${_msgsLenAtUnreadJump} needSep=$needSep',
    );
    if (ok && pinned) {
      _unreadFrontierReady = true;
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        setState(() => _listCacheExtent = 1200);
        _revealChatContent();
      }
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
    } finally {
      _programmaticOpenScroll = false;
    }
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
    if (_isUserActivelyScrolling && !_programmaticOpenScroll) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final len = svc.messagesFor(widget.chatId).length;
    _programmaticOpenScroll = true;
    try {
    // Always retry until frontier is visible — remote history fill often
    // resets reverse ListView back to the tip after the first jump.
    final ok = await _ensureVisibleMessage(
      _unreadAnchorMessageId!,
      alignment: 0.0,
      instant: true,
      unreadHint: _openUnreadCount,
    );
    if (!mounted) return;
    _msgsLenAtUnreadJump = len;
    final needSep = _openUnreadCount >= 2;
    if (ok &&
        _isUnreadAnchorInViewport(requireSeparatorAtTop: needSep)) {
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      if (mounted) setState(() => _listCacheExtent = 1200);
      _revealChatContent();
      _scheduleViewportPrefetch();
      _scheduleMarkVisibleRead();
      if (mounted) _updateScrollToBottomVisibility();
      return;
    }
    _scheduleReassertUnreadScroll();
    } finally {
      _programmaticOpenScroll = false;
    }
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
      if (mounted && !_suppressViewportPrefetch) {
        _scheduleViewportPrefetch();
      }
    } finally {
      _loadingOlder = false;
    }
  }

  /// Keep paging until the channel has a usable history (scroll may not fire
  /// when only 1–2 messages fit on screen).
  Future<void> _fillHistoryIfSparse() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.isUnreadHistoryWarm(widget.chatId) &&
        svc.messagesFor(widget.chatId).length >= 40) {
      return;
    }
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
      enableFaceTag: false,
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
      enableFaceTag: false,
    );
  }

  Future<void> _openAndWatch() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    _suppressMarkRead = true;
    // Snapshot unread frontier before openChat / history mutate inbox state.
    _openLastReadInboxId = svc.lastReadInboxMessageId(widget.chatId);
    _openUnreadCount = svc.unreadCountFor(widget.chatId);
    // Claim immediately so dispose during await still has a valid close token.
    _openChatToken = svc.claimOpenChat(widget.chatId);
    final preUnread = svc.firstUnreadMessageId(widget.chatId);
    if (preUnread != null) {
      _unreadAnchorMessageId = preUnread;
    }
    final deepLink =
        widget.initialMessageId != null && widget.initialMessageId! > 0;
    final unread = _openUnreadCount;
    final warm = svc.isUnreadHistoryWarm(widget.chatId);
    // Hide+jump only when the tip is wrong: deep link, or unread ≥ 2.
    // unread 0/1 → reverse list already sits on the tip (the only unread).
    final needsPositionGate = deepLink || unread >= 2;
    if (!needsPositionGate) {
      _revealChatContent();
      _initialScrollDone = true;
      if (unread <= 0) {
        _unreadFrontierReady = true;
        _suppressMarkRead = false;
      } else {
        // unread == 1: tip is the unread — show divider, allow mark-read
        // after first frame (no hide / no jump).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _unreadFrontierReady = true;
          _suppressMarkRead = false;
          _scheduleMarkVisibleRead();
        });
      }
    } else {
      _armDelayedOpenLoader();
      _armOpenRevealTimeout();
    }

    Future<void> finishOpenSideEffects() async {
      final jumpId = widget.initialMessageId;
      if (jumpId != null && jumpId > 0) {
        await _jumpToLinkedMessage(jumpId);
        if (mounted) _revealChatContent();
      }
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
      _viewportMediaRescanListener ??= _onViewportMediaRescanFromService;
      svc.addViewportMediaRescanListener(_viewportMediaRescanListener!);
      _scheduleViewportPrefetch();
      _armIdleMediaRescan();
      _tailSyncTimer?.cancel();
      _tailSyncTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted) return;
        unawaited(svc.syncChatTail(widget.chatId));
      });
    }

    // Warm RAM already covers the frontier — position from cache, don't wait
    // on syncChatTail / sparse fill (those caused the 1s spinner anyway).
    if (needsPositionGate && warm && !deepLink) {
      unawaited(svc.openChat(widget.chatId));
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await _positionInitialScroll(svc);
      await finishOpenSideEffects();
      return;
    }

    await svc.openChat(widget.chatId);
    if (needsPositionGate) {
      if (!warm) {
        await svc.syncChatTail(widget.chatId);
        await _fillHistoryIfSparse();
      } else {
        unawaited(svc.syncChatTail(widget.chatId));
      }
      unawaited(svc.refreshVideoChat(widget.chatId));
      await _positionInitialScroll(svc);
    } else {
      unawaited(svc.syncChatTail(widget.chatId));
      unawaited(svc.refreshVideoChat(widget.chatId));
      if (unread <= 0) {
        await _markCaughtUp();
      }
      _scheduleViewportPrefetch();
    }
    await finishOpenSideEffects();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(
        ref.read(telegramTdlibServiceProvider).syncChatTail(widget.chatId),
      );
      // Soft media may have been on-screen while paused — re-pick by layout.
      if (!_suppressViewportPrefetch) {
        _scheduleViewportPrefetch();
        _armIdleMediaRescan();
      }
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
    _mediaIdleRescanTimer?.cancel();
    _markVisibleReadTimer?.cancel();
    _scrollBusyClearTimer?.cancel();
    _reassertUnreadScrollTimer?.cancel();
    _openRevealTimeout?.cancel();
    _openLoaderTimer?.cancel();
    _stickyDayThrottle?.cancel();
    _scroll.removeListener(_onScroll);
    final rescan = _viewportMediaRescanListener;
    if (rescan != null) {
      TelegramTdlibService.instance.removeViewportMediaRescanListener(rescan);
      _viewportMediaRescanListener = null;
    }
    final chatId = widget.chatId;
    final openToken = _openChatToken;
    // Defer: closeChat → notifyListeners must not run during unmount
    // (Riverpod forbids provider updates while the tree is building).
    Future(() {
      unawaited(
        TelegramTdlibService.instance.closeChat(
          chatId,
          openToken: openToken,
        ),
      );
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
    final match = await TelegramMatchStore.instance.get(tgUserId);
    final fcId = match?.fcUserId ?? 0;
    if (fcId > 0) {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MemberProfileScreen(userId: fcId),
        ),
      );
      return;
    }
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
    // Own messages only; delete for everyone (both sides / all group members).
    // Private/group: TDLib sometimes drops can_be_deleted_* on updates — still
    // allow revoke for outgoing. Channels keep the TDLib admin gate.
    final canDeleteEveryone = m.isOutgoing &&
        !m.isService &&
        (m.canBeDeletedForAllUsers ||
            svc.isPrivateChat(widget.chatId) ||
            svc.isGroupChat(widget.chatId));
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
      canDeleteForEveryone: canDeleteEveryone,
      // Only «Удалить у всех» for own messages — no hide-for-me shortcut here.
      canDeleteForMe: false,
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
        await _deleteOwnMessagesForEveryone([m]);
      case 'delete_for_me':
        await svc.deleteMessages(widget.chatId, [m.id], revoke: false);
    }
  }

  /// TDLib revoke-delete + matched FC copy (when present).
  /// Returns false if the user cancelled the confirm dialog.
  Future<bool> _deleteOwnMessagesForEveryone(List<TdlibMessage> messages) async {
    final own = messages
        .where((m) => m.isOutgoing && !m.isService)
        .map((m) => m.id)
        .toList();
    if (own.isEmpty) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщения?'),
        content: Text(
          own.length == 1
              ? 'Сообщение будет удалено у всех участников чата.'
              : 'Выбранные сообщения (${own.length}) будут удалены у всех участников чата.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return false;

    final svc = ref.read(telegramTdlibServiceProvider);
    await svc.deleteMessages(widget.chatId, own, revoke: true);
    unawaited(_maybeDeleteMatchedFcCopies(own));
    return true;
  }

  Future<void> _maybeDeleteMatchedFcCopies(List<int> tgMessageIds) async {
    if (tgMessageIds.isEmpty) return;
    // Matched DM (fcUserId) or any chat that may have FC mirrors via map.
    try {
      await ref.read(familychatRepositoryProvider).deleteMessagesByTelegramIds(
            tgChatId: widget.chatId,
            tgMessageIds: tgMessageIds,
          );
    } catch (_) {
      // Best-effort — TG side already deleted.
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
    final svc = ref.read(telegramTdlibServiceProvider);
    final selected = svc
        .messagesFor(widget.chatId)
        .where((m) => _selectedIds.contains(m.id))
        .toList();
    if (selected.isEmpty) return;
    if (revoke) {
      final done = await _deleteOwnMessagesForEveryone(selected);
      if (done && mounted) _exitSelection();
      return;
    }
    final ids = selected.map((m) => m.id).toList();
    await svc.deleteMessages(widget.chatId, ids, revoke: false);
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
        'source': 'telegram',
        'voice': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isVideoNote) {
      final durationMs = m.videoNoteDurationMs;
      return {
        'source': 'telegram',
        'video_note': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isSticker) {
      return {
        'source': 'telegram',
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
        'source': 'telegram',
        'gif': {
          'source': 'telegram',
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isVideo) {
      final durationMs = m.videoDurationMs;
      return {
        'source': 'telegram',
        'video': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        },
      };
    }
    if (m.isDocument) {
      return {
        'source': 'telegram',
        'file': {
          if (m.documentFileName != null) 'filename': m.documentFileName,
          if (m.documentMimeType != null) 'mime_type': m.documentMimeType,
        },
      };
    }
    return const {'source': 'telegram'};
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

    return ListenableBuilder(
      listenable: ChatUiConnectivity.instance,
      builder: (context, _) {
        // No internet → FamilyAppBarTitle shows shared «Ожидание соединения»;
        // never overlay proxy-waiting copy inside the title child.
        final noInternet = !ChatUiConnectivity.instance.isOnline ||
            svc.mtprotoConnectionState == 'connectionStateWaitingForNetwork';
        final connLabel = noInternet ? '' : svc.connectionStatusLabel;
        // Label is grace-delayed in the service — empty means keep peer status
        // (no spinner flash on ~0.2–0.5s mobile↔Wi‑Fi flaps).
        final connPending = connLabel.isNotEmpty;
        final subtitle = connPending ? connLabel : status;
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
                        : () => unawaited(_deleteSelected(revoke: true)),
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
                  if (kDebugMode)
                    Tooltip(
                      message: svc.mtprotoProxyEnabled
                          ? 'MTProto proxy ON'
                          : 'MTProto proxy OFF (direct)',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Proxy',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: svc.mtprotoProxyEnabled
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                ),
                          ),
                          Transform.scale(
                            scale: 0.75,
                            child: Switch.adaptive(
                              value: svc.mtprotoProxyEnabled,
                              onChanged: (v) => unawaited(
                                svc.setMtprotoProxyEnabled(v),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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
                        cacheExtent: _listCacheExtent,
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
      },
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
