import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/diagnostics/session_log.dart';
import '../../../core/theme/appearance_prefs.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/data/chat_location_utils.dart';
import '../../chat/data/chat_send_options.dart';
import '../../chat/data/chat_ui_connectivity.dart';
import '../../chat/data/chat_voice_playback_coordinator.dart';
import '../../chat/data/chat_voice_transcription_prefs.dart';
import '../../chat/data/chat_voice_utils.dart';
import '../../chat/data/hub_first_paint_snapshot.dart';
import '../../chat/data/link_preview_service.dart';
import '../../chat/data/chat_realtime_utils.dart';
import '../tdlib_io.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../chat/presentation/chat_call_screen.dart';
import '../../chat/presentation/record_video_circle_screen.dart';
import '../../chat/presentation/widgets/chat_animated_media_scope.dart';
import '../../chat/presentation/widgets/chat_inline_video_autoplay.dart';
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
import '../../chat/presentation/youtube_proxy_navigation.dart';
import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../telegram_match_store.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';
import '../telegram_link_navigation.dart';
import '../tdlib_smartspeech.dart';
import '../tdlib_transcript_cache.dart';
import '../tg_history_store.dart';
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
    this.fcThreadId,
    this.peerAvatarUrl = '',
    this.initialMessageId,
  });

  final int chatId;
  final String title;
  final int? tgUserId;
  final int? fcUserId;
  /// Known FC DM thread for a matched peer (hub FC row). Used for FC calls.
  final int? fcThreadId;
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
  final _inlineVideoAutoplay = ChatInlineVideoAutoplayController();
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
  /// Set once on enter (or once when first tip-pack arrives while scrolled
  /// up). Never moves mid-visit; clears only on dispose (leave chat).
  int? _unreadAnchorMessageId;
  /// Snapshot of inbox cursor at open — survives history races.
  int? _openLastReadInboxId;
  /// Unread count frozen at open — open jump / pin depth only.
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
  /// Multi-unread open: block tip mark-read / nearTip until the user scrolls
  /// away from the tip (open pin often sits at px≈80 inside the "near tip" band).
  bool _userReleasedUnreadGate = false;
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
  Timer? _imeBusyClearTimer;
  Timer? _reassertUnreadScrollTimer;
  Timer? _openRevealTimeout;
  Timer? _stickyDayThrottle;
  String? _stickyDayLabel;
  bool _showStickyDay = false;
  /// Hold UI notifies while compose has focus / IME animates — tap-input
  /// raced enable-link-previews (Valya Davey ~10s).
  bool _imeUiBusy = false;
  /// Highest message id we already sent to viewMessages this session.
  int _maxMarkedReadId = 0;
  /// Token from [TelegramTdlibService.openChat] — stale dispose must not close
  /// a re-opened session of the same chat.
  int? _openChatToken;
  DateTime? _lastUserScrollAt;
  /// True while open-positioning drives jumpTo/ensureVisible — must not be
  /// treated as a user fling (that used to force-reveal before the divider).
  bool _programmaticOpenScroll = false;
  final Map<int, GlobalKey> _messageKeys = {};
  final GlobalKey _unreadSeparatorKey = GlobalKey();
  /// Inflated during unread open so ensureVisible can mount the frontier row.
  // Start modest — tip paint ≈20 from SQLite. Grow after first user scroll.
  double _listCacheExtent = 720;

  /// SQLite transcript (oldest→newest). UI window = last [_windowLimit].
  List<TdlibMessage> _dbMessages = const [];
  StreamSubscription<List<TdlibMessage>>? _dbWatchSub;
  Timer? _dbWatchApplyTimer;
  List<TdlibMessage>? _dbWatchPending;
  int _windowLimit = TgHistoryStore.tipPaintCap;
  /// Unread reassert after the list is already on screen. Tip-seed paints
  /// ~20 rows, then history floods to 200 and the 280ms reassert toggled
  /// cacheExtent 1200↔3600 forever (Осташко 22:03 BUILD every ~280ms).
  int _unreadReassertAfterReveal = 0;

  static const _stickyDayAwayPx = 40.0;
  static const _scrollToBottomAwayPx = 280.0;
  static const _scrollToBottomHintDelay = Duration(milliseconds: 420);
  static const _viewportPrefetchDebounce = Duration(milliseconds: 900);
  static const _markVisibleReadDebounce = Duration(milliseconds: 180);

  DateTime? _lastItemBuilderFlushAt;

  /// Matched FC peer — call goes through FamilyChat (not Telegram).
  int? _fcPeerUserId;
  int? _fcDmThreadId;
  bool _fcCallBusy = false;

  @override
  void initState() {
    super.initState();
    _fcPeerUserId = widget.fcUserId;
    _fcDmThreadId = widget.fcThreadId;
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _inputFocus.addListener(_onInputFocusChanged);
    TgJankLog.resetForChat(widget.chatId);
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
    // Stay deferred until reveal+settle — timed boot defer expires mid-open
    // on slow proxy and then OG scrapes nuke the first fling (~100+ frames).
    LinkPreviewService.instance.deferNetworkFetches = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openAndWatch());
    });
    unawaited(_resolveFcPeerForCalls());
  }

  void _onInputFocusChanged() {
    if (!mounted) return;
    if (_inputFocus.hasFocus) {
      _imeBusyClearTimer?.cancel();
      _imeBusyClearTimer = null;
      if (!_imeUiBusy) {
        _imeUiBusy = true;
        TgJankLog.log('ime-focus');
      }
      // IME busy has no 720ms TTL — scroll-busy expired mid-keyboard (Valya).
      ref.read(telegramTdlibServiceProvider).setUiImeBusy(true);
      return;
    }
    TgJankLog.log('ime-blur');
    _imeBusyClearTimer?.cancel();
    _imeBusyClearTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || _inputFocus.hasFocus) return;
      _imeUiBusy = false;
      ref.read(telegramTdlibServiceProvider).setUiImeBusy(false);
      // Previews may have been deferred while typing.
      if (!_linkPreviewsEnabled) _enableLinkPreviews();
    });
  }

  bool get _blocksLinkPreviews {
    if (_imeUiBusy || _inputFocus.hasFocus) return true;
    if (!mounted) return true;
    return MediaQuery.viewInsetsOf(context).bottom > 0;
  }

  Future<void> _resolveFcPeerForCalls() async {
    if ((_fcPeerUserId ?? 0) > 0) return;
    final tgUserId = widget.tgUserId;
    if (tgUserId != null && tgUserId > 0) {
      final match = await TelegramMatchStore.instance.get(tgUserId);
      if (!mounted) return;
      if (match != null && match.fcUserId > 0) {
        setState(() => _fcPeerUserId = match.fcUserId);
        return;
      }
    }
    final all = await TelegramMatchStore.instance.loadAll();
    if (!mounted) return;
    for (final m in all.values) {
      if (m.tgChatId == widget.chatId && m.fcUserId > 0) {
        setState(() => _fcPeerUserId = m.fcUserId);
        return;
      }
    }
  }

  bool get _canStartFcCall {
    final fcId = _fcPeerUserId ?? 0;
    if (fcId <= 0) return false;
    final svc = ref.read(telegramTdlibServiceProvider);
    // FC calls are 1:1 DM only.
    if (svc.isGroupChat(widget.chatId) || svc.isChannelChat(widget.chatId)) {
      return false;
    }
    return true;
  }

  /// Primary timeline source: SQLite window (+ thin RAM overlay for send).
  List<TdlibMessage> _messagesForUi(TelegramTdlibService svc) {
    final ram = svc.messagesFor(widget.chatId);
    final ramById = {for (final m in ram) m.id: m};
    final List<TdlibMessage> base;
    if (_dbMessages.isNotEmpty) {
      final start =
          (_dbMessages.length - _windowLimit).clamp(0, _dbMessages.length);
      base = _dbMessages.sublist(start);
    } else if (ram.isNotEmpty) {
      final start = (ram.length - _windowLimit).clamp(0, ram.length);
      base = ram.sublist(start);
    } else {
      return const [];
    }
    final out = <TdlibMessage>[];
    final seen = <int>{};
    for (final m in base) {
      seen.add(m.id);
      out.add(ramById[m.id] ?? m);
    }
    for (final m in ram) {
      if (seen.contains(m.id)) continue;
      final optimistic = m.sendingState != null;
      final newerTip = base.isNotEmpty && m.id > base.last.id;
      if (optimistic || newerTip) {
        out.add(m);
        seen.add(m.id);
      }
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  void _bindDbWatch() {
    _dbWatchSub?.cancel();
    _dbWatchApplyTimer?.cancel();
    _dbWatchPending = null;
    debugPrint('[tg-db] watch chat=${widget.chatId}');
    _dbWatchSub = TgHistoryStore.instance.watchChat(widget.chatId).listen(
      (msgs) {
        if (!mounted) return;
        // Coalesce Drift upsert storms (ready-catchup / ensureTip) — each
        // emission used to setState and freeze open (Шарий BUILD×500).
        // Also hold during service open-quiet — watch bypassed quiet and
        // stacked with the pierce-flush NOTIFY storm.
        _dbWatchPending = msgs;
        final quiet =
            ref.read(telegramTdlibServiceProvider).isOpenChatUiQuiet;
        final delay = quiet
            ? const Duration(milliseconds: 480)
            : const Duration(milliseconds: 220);
        _dbWatchApplyTimer?.cancel();
        _dbWatchApplyTimer = Timer(delay, () {
          _dbWatchApplyTimer = null;
          final pending = _dbWatchPending;
          _dbWatchPending = null;
          if (!mounted || pending == null) return;
          if (ref.read(telegramTdlibServiceProvider).isOpenChatUiQuiet) {
            // Still quiet — re-arm; do not paint mid-open.
            _dbWatchPending = pending;
            _dbWatchApplyTimer = Timer(const Duration(milliseconds: 300), () {
              _dbWatchApplyTimer = null;
              final p = _dbWatchPending;
              _dbWatchPending = null;
              if (!mounted || p == null) return;
              if (_dbTipFingerprint(p) == _dbTipFingerprint(_dbMessages)) {
                return;
              }
              setState(() => _dbMessages = p);
            });
            return;
          }
          if (_dbTipFingerprint(pending) == _dbTipFingerprint(_dbMessages)) {
            return;
          }
          setState(() => _dbMessages = pending);
        });
      },
      onError: (Object e) {
        debugPrint('[tg-db] watch error chat=${widget.chatId}: $e');
      },
    );
  }

  /// Tip id + length — enough to skip no-op watch rebuilds.
  String _dbTipFingerprint(List<TdlibMessage> msgs) {
    if (msgs.isEmpty) return '0';
    return '${msgs.length}:${msgs.first.id}:${msgs.last.id}';
  }

  Future<int> _ensureOlderFromDb(TelegramTdlibService svc) async {
    // Grow UI window from rows already in SQLite before hitting TDLib.
    if (_dbMessages.length > _windowLimit) {
      if (mounted) {
        setState(() {
          _windowLimit = (_windowLimit + TgHistoryStore.olderPageSize)
              .clamp(TgHistoryStore.tipPaintCap, 500);
        });
      }
      debugPrint(
        '[tg-db] older window chat=${widget.chatId} '
        'limit=$_windowLimit db=${_dbMessages.length}',
      );
      return TgHistoryStore.olderPageSize;
    }
    final ram = svc.messagesFor(widget.chatId);
    final before = _dbMessages.isNotEmpty
        ? _dbMessages.first.id
        : (ram.isNotEmpty ? ram.first.id : 0);
    if (before <= 0) {
      await TgHistoryStore.instance.ensureTip(
        widget.chatId,
        chatType: TgHistoryStore.chatTypeLabel(
          isChannel: svc.isChannelChat(widget.chatId),
          isPrivate: svc.isPrivateChat(widget.chatId),
          isGroup: svc.isGroupChat(widget.chatId),
        ),
        title: svc.peerTitle(widget.chatId),
        loadTip: () => svc.loadTipHistoryForDb(
          widget.chatId,
          maxCount: TgHistoryStore.tipPaintCap,
        ),
      );
      return await TgHistoryStore.instance.count(widget.chatId);
    }
    final added = await TgHistoryStore.instance.ensureOlder(
      widget.chatId,
      beforeMessageId: before,
      loadOlder: () => svc.loadOlderMessagesForDb(
        widget.chatId,
        beforeMessageId: before,
        pageSize: TgHistoryStore.olderPageSize,
      ),
    );
    if (mounted) {
      setState(() {
        _windowLimit = (_windowLimit + TgHistoryStore.olderPageSize)
            .clamp(TgHistoryStore.tipPaintCap, 500);
      });
    }
    return added;
  }

  Future<void> _startFcCall({bool isVideo = false}) async {
    if (_fcCallBusy || !_canStartFcCall) return;
    setState(() => _fcCallBusy = true);
    try {
      var threadId = _fcDmThreadId ?? 0;
      var title = widget.title;
      if (threadId <= 0) {
        final fcId = _fcPeerUserId!;
        final thread = await ref
            .read(familychatRepositoryProvider)
            .memberDmThread(fcId);
        if (!mounted) return;
        threadId = (thread['id'] as num?)?.toInt() ?? 0;
        title = thread['title']?.toString() ??
            thread['default_title']?.toString() ??
            widget.title;
        if (threadId > 0) _fcDmThreadId = threadId;
      }
      if (threadId <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось начать звонок')),
        );
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatCallScreen(
            threadId: threadId,
            title: title,
            isCaller: true,
            isVideo: isVideo,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось начать звонок: $e')),
      );
    } finally {
      if (mounted) setState(() => _fcCallBusy = false);
    }
  }

  /// Decode tip photos into the image cache before Opacity flips to 1 —
  /// otherwise the first painted frame is empty/light then the JPEGs pop in
  /// (visible «мигание» on photo-heavy DMs like Киса).
  Future<void> _precacheRecentMedia() async {
    if (!mounted) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = _messagesForUi(svc);
    if (msgs.isEmpty) return;
    final tip = msgs.length > 10 ? msgs.sublist(msgs.length - 10) : msgs;
    final futures = <Future<void>>[];
    for (final m in tip) {
      final path = svc.resolvedPhotoPath(m);
      if (path == null || path.isEmpty) continue;
      try {
        futures.add(precacheImage(FileImage(File(path)), context));
      } catch (_) {}
      final thumb = m.photoThumbBytes;
      if (thumb != null && thumb.isNotEmpty) {
        try {
          futures.add(
            precacheImage(MemoryImage(Uint8List.fromList(thumb)), context),
          );
        } catch (_) {}
      }
    }
    if (futures.isEmpty) return;
    try {
      await Future.wait(futures).timeout(const Duration(milliseconds: 280));
    } catch (_) {}
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
    _inlineVideoAutoplay.noteScroll();
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
    _scrollBusyClearTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || _isUserActivelyScrolling || _imeUiBusy) return;
      ref.read(telegramTdlibServiceProvider).setUiScrollBusy(false);
      _inlineVideoAutoplay.noteScrollEnd();
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
      // Multi-unread: force viewMessages stays blocked until the gate —
      // a tip-side pin + tiny scroll used to wipe 80 unreads (Осташко).
      if (_openUnreadCount < 2 || _userReleasedUnreadGate) {
        ref.read(telegramTdlibServiceProvider).setBlockUnreadForceView(false);
      }
      _revealChatContent();
    } else if (_initialScrollDone &&
        _suppressMarkRead &&
        _isUserActivelyScrolling &&
        _openUnreadCount > 0 &&
        _openUnreadCount < 2) {
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      ref.read(telegramTdlibServiceProvider).setBlockUnreadForceView(false);
      _revealChatContent();
    }
    _updateScrollToBottomVisibility();
    _scheduleStickyDayUpdate();
    _scheduleViewportPrefetch();
    _scheduleMarkVisibleRead();
    if (_loadingOlder) return;
    // reverse: true → maxScrollExtent is older history.
    // Prefetch when past ~55% so tip=20 window grows before the edge.
    final maxExt = _scroll.position.maxScrollExtent;
    final px = _scroll.position.pixels;
    final nearOlder = maxExt <= 0 ||
        px >= maxExt - 400 ||
        (maxExt > 800 && px >= maxExt * 0.55);
    if (!nearOlder) return;
    unawaited(_loadOlder());
  }

  DateTime? _dayOfTopmostVisibleMessage() {
    if (!_scroll.hasClients) return null;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = _messagesForUi(svc);
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
    // Ballistic: avoid O(n) GlobalKey walks every 48ms (Valya scroll hitch).
    final delay = _isUserActivelyScrolling
        ? const Duration(milliseconds: 160)
        : const Duration(milliseconds: 48);
    _stickyDayThrottle = Timer(delay, () {
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
      if (_isUserActivelyScrolling || _imeUiBusy) {
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
      final msgs = _messagesForUi(svc);
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
      // Do not forceFocus — under FakeTLS it flip-flops tip/photo rows and
      // cancels the only in-flight downloadFile into permanent 0B.
      svc.prefetchOpenChatViewport(
        chatId: widget.chatId,
        focusMessageId: focusId,
        forceFocus: false,
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
    final msgs = _messagesForUi(svc);
    if (msgs.isEmpty) return;

    final layoutId = _pickVisibleSoftMediaMessageId(svc);
    final focusId = layoutId ?? _estimateSoftMediaNearScroll(svc);
    if (focusId == null) {
      // Layout not ready (px=0 / empty extent) — keep prior media focus; do
      // not log none flaps that SessionLog showed on every cold open.
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (!pos.hasContentDimensions) return;
      final maxExt = pos.maxScrollExtent;
      final px = pos.pixels;
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

    final focusPos = _scroll.position;
    SessionLog.instance.event('tg.ui', 'viewport_focus', {
      'chatId': widget.chatId,
      'msgId': focusId,
      'source': layoutId != null ? 'layout' : 'estimate',
      'px': focusPos.pixels,
      'max': focusPos.hasContentDimensions ? focusPos.maxScrollExtent : -1,
      'keys': _messageKeys.length,
    });

    svc.prefetchOpenChatViewport(
      chatId: widget.chatId,
      focusMessageId: focusId,
      // Hold wins over scroll jitter; user tap uses ensureFileDownloaded.
      forceFocus: false,
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

    final msgs = _messagesForUi(svc);
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
      // Sharp photo + video first-frame thumbs share top priority; docs last.
      final priority = (svc.photoNeedsFocusDownload(m) ||
              svc.videoPreviewNeedsFocusDownload(m))
          ? 0
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
    final msgs = _messagesForUi(svc);
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

    return pick((row) => row.members.any(
              (m) =>
                  svc.photoNeedsFocusDownload(m) ||
                  svc.videoPreviewNeedsFocusDownload(m),
            )) ??
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
    final nearTip = pixels <= _scrollToBottomAwayPx;
    _syncOpenNearTip(svc, nearTip, pixels: pixels);
    final unread = svc.unreadCountFor(widget.chatId);
    // FAB badge = live unread. Line sticky is independent (may outlive unread).
    final hasLiveUnread = unread > 0;

    // At tip: no unread FAB — user already sees fresh; do not arm/move line.
    // Still schedule progressive mark — hiding the FAB must not leave the
    // hub badge stuck (НСИС SessionLog 10:36 unread stayed 6 after tip).
    if (nearTip) {
      _hideScrollToBottomButton();
      if (!_suppressMarkRead && _unreadFrontierReady) {
        _scheduleMarkVisibleRead();
      }
      return;
    }

    // Away from tip + live unread → FAB to sticky line (arm once if needed).
    if (hasLiveUnread && pixels > 48) {
      _armLiveUnreadAnchor(svc, unread: unread);
      if (!_showScrollToBottom) {
        setState(() => _showScrollToBottom = true);
      }
      return;
    }

    // unread=0: no unread FAB (sticky line may still paint until leave).
    // Still allow the plain tip FAB when scrolling toward tip.
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
      if (_scroll.position.pixels > _scrollToBottomAwayPx &&
          ref.read(telegramTdlibServiceProvider).unreadCountFor(widget.chatId) <=
              0) {
        setState(() => _showScrollToBottom = true);
      }
    });
  }

  /// Arm visit sticky divider at most once (open or first away-from-tip pack).
  /// Never moves an existing anchor — that made the line "dynamic" mid-read.
  void _armLiveUnreadAnchor(
    TelegramTdlibService svc, {
    int? unread,
  }) {
    if (_unreadAnchorMessageId != null) return;
    final count = unread ?? svc.unreadCountFor(widget.chatId);
    if (count <= 0) return;
    final first = svc.firstUnreadMessageId(widget.chatId);
    if (first == null) return;
    _unreadAnchorMessageId = first;
  }

  /// Called from build when the transcript grows — must not setState sync.
  void _syncOpenNearTip(
    TelegramTdlibService svc,
    bool nearTip, {
    required double pixels,
  }) {
    if (_openUnreadCount >= 2 && !_userReleasedUnreadGate) {
      if (_isUserActivelyScrolling && pixels > _scrollToBottomAwayPx) {
        _userReleasedUnreadGate = true;
        svc.setBlockUnreadForceView(false);
      } else {
        svc.setOpenChatNearTip(false);
        return;
      }
    }
    svc.setOpenChatNearTip(nearTip);
  }

  void _maybeArmLiveUnreadFromBuild(TelegramTdlibService svc) {
    if (!_contentReady || !_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final nearTip = pixels <= _scrollToBottomAwayPx;
    _syncOpenNearTip(svc, nearTip, pixels: pixels);
    // Tip: fresh messages stay in view — no new sticky, no FAB.
    if (nearTip) return;
    final unread = svc.unreadCountFor(widget.chatId);
    if (unread <= 0) return;
    final before = _unreadAnchorMessageId;
    final shown = _showScrollToBottom;
    _armLiveUnreadAnchor(svc, unread: unread);
    if (_unreadAnchorMessageId == before && shown) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _showScrollToBottom = true);
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
    final svc = ref.read(telegramTdlibServiceProvider);
    final unread = svc.unreadCountFor(widget.chatId);
    // FAB → sticky visit line (never retarget to live firstUnread mid-visit).
    if (unread > 0 && _unreadAnchorMessageId == null) {
      _armLiveUnreadAnchor(svc, unread: unread);
    }
    final anchor = _unreadAnchorMessageId;

    _unreadFrontierReady = true;
    _suppressMarkRead = false;

    if (unread > 0 && anchor != null) {
      if (mounted) setState(() => _showScrollToBottom = true);
      _programmaticOpenScroll = true;
      var ok = false;
      try {
        ok = await _ensureVisibleMessage(
          anchor,
          alignment: 0.0,
          instant: true,
          unreadHint: unread,
        );
        if (mounted) {
          await _pinUnreadSeparatorToTop();
        }
      } finally {
        _programmaticOpenScroll = false;
      }
      if (!ok && mounted) {
        _scrollToBottom(jump: false);
      }
      _scheduleMarkVisibleRead();
      if (mounted) _updateScrollToBottomVisibility();
      return;
    }

    _hideScrollToBottomButton();
    // No live unread — tip only (sticky line may still paint until leave).
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
    // SessionLog 13:41 «ТП НСИС» unread=6: gate required scroll-away
    // (pixels>280) before any markVisible — user read toward tip, FAB hid
    // (nearTip) but viewMessages never ran → hub badge stuck at 6.
    // Progressive layout mark is safe once the frontier is pinned; the
    // tip-force wipe is blocked separately via [_blockUnreadForceView].
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = _messagesForUi(svc);
    if (msgs.isEmpty) return;

    final lastRead = svc.lastReadInboxMessageId(widget.chatId);
    final floor = _maxMarkedReadId > lastRead ? _maxMarkedReadId : lastRead;
    // Caught-up chats: skip O(n) GlobalKey hit-tests every scroll tick.
    if (svc.unreadCountFor(widget.chatId) <= 0 &&
        msgs.last.id <= floor) {
      return;
    }

    // Layout hit-test only — avgExtent≈220 over-marked tall media rows and
    // wiped the unread pack while the sticky divider was still on screen.
    final highestVisibleUnread =
        _highestVisibleUnreadByLayout(msgs: msgs, floor: floor);
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

  /// When [requireSeparatorAtTop] is true (unread open), the «Непрочитанные»
  /// bar must sit near the visual top — a tall first-unread used to pass with
  /// only its bottom (end) on screen (reverse ListView + ensureVisible).
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
      // Strict top band: separator + start of first unread must be visible.
      final ok = topLeft.dy >= -24 && topLeft.dy <= 72 && bottom > 0;
      if (ok) return true;
      // Few short unreads: bar on screen but reverse list already at tip
      // (offset 0) — cannot pull higher. Don't leave opacity 0 forever.
      // Never accept tip-park for multi-unread opens — that marked the tip
      // read and wiped the pack while the divider sat on the newest post.
      final onScreen = bottom > 8 && topLeft.dy < viewH - 8;
      final stuckAtNewest = _scroll.position.pixels <= 2.0;
      if (requireSeparatorAtTop &&
          onScreen &&
          stuckAtNewest &&
          _openUnreadCount < 2) {
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
        return false;
      }
      // Soft path: separator anywhere in the upper half is enough.
      return onScreen && topLeft.dy < viewH * 0.55;
    }

    if (requireSeparatorAtTop) {
      TgJankLog.log('open-sep-miss sep=null anchor=$_unreadAnchorMessageId');
      return false;
    }

    final anchorId = _unreadAnchorMessageId;
    if (anchorId == null) return false;
    final svc = ref.read(telegramTdlibServiceProvider);
    final timeline = _buildTimeline(_messagesForUi(svc));
    final keyId = _visibleKeyMessageId(anchorId, timeline);
    final ctx = _keyForMessage(keyId).currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: listBox);
    // Prefer the TOP of the first unread, not merely any overlap (tall code
    // bubbles otherwise "succeed" while only the end is visible).
    return topLeft.dy >= -48 && topLeft.dy <= viewH * 0.45;
  }

  /// Explicit catch-up (FAB / open with no unreads) — tip only.
  /// Does not clear the visit sticky unread divider.
  Future<void> _markCaughtUp() async {
    if (_suppressMarkRead) return;
    if (_caughtUpMarked) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final msgs = _messagesForUi(svc);
    if (msgs.isEmpty) return;
    final tipId = msgs.last.id;
    final liveUnread = svc.unreadCountFor(widget.chatId);
    // Cold-boot open used to snapshot unread=0 before getChats, then call
    // this after openChat while live unread was still 19 → tip viewMessages
    // wiped the pack (Осташко 08:26 SessionLog).
    if (liveUnread > 0) {
      TgJankLog.log(
        'mark-caught-up skip liveUnread=$liveUnread tip=$tipId',
      );
      return;
    }
    // Already caught up (unread=0 + tip read): skip viewMessages + notify —
    // that rebuild was hitching every chat open even without unreads.
    if (tipId <= svc.lastReadInboxMessageId(widget.chatId)) {
      _caughtUpMarked = true;
      _maxMarkedReadId = tipId;
      return;
    }
    _caughtUpMarked = true;
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

  /// True when RAM reaches the open read floor (or has the full unread pack).
  /// Tip-only pages with unread ≥ 2 are NOT spanned — jumping there marks the
  /// whole pack read after reveal.
  bool _unreadFrontierSpanned(TelegramTdlibService svc) {
    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    if (unread <= 0) return true;
    // Single unread lives at the tip — reverse list is already correct.
    if (unread < 2) return true;
    final lastRead =
        _openLastReadInboxId ?? svc.lastReadInboxMessageId(widget.chatId);
    final msgs = _messagesForUi(svc);
    if (msgs.isEmpty) return false;
    if (lastRead > 0 && msgs.first.id <= lastRead) return true;
    final loadedUnread = lastRead > 0
        ? msgs.where((m) => !m.isOutgoing && m.id > lastRead).length
        : msgs.where((m) => !m.isOutgoing).length;
    if (loadedUnread >= unread) return true;
    // Do NOT treat "enough inbound rows" as spanned while oldest is still
    // newer than last_read — that mid-pack pin wiped Осташко unreads.
    return false;
  }

  /// Load older pages until the unread frontier is in RAM.
  ///
  /// Returns `true` when it is safe to resolve first-unread (spanned, or
  /// history exhausted / budget spent with at least one message). Returns
  /// `false` only when still empty / not mounted mid-load.
  Future<bool> _ensureUnreadHistoryLoaded(TelegramTdlibService svc) async {
    final lastRead =
        _openLastReadInboxId ?? svc.lastReadInboxMessageId(widget.chatId);
    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    if (unread <= 0) return true;

    // Scale pages with unread depth — keep small packs light (9 unread must
    // not walk 6×50 + openChat 200; SessionLog 20:41 freeze).
    // Deep channels (96+): need enough pages to reach last_read — Осташко
    // pinned mid-pack after only ~4 pages (SessionLog 20:07).
    final maxPages = unread <= 15
        ? 3
        : unread <= 40
            ? 6
            : (unread / 20).ceil().clamp(6, 16);
    // Hard ceiling only after the read frontier is in RAM.
    final hardCap = (unread + 80).clamp(80, 320);
    for (var i = 0; i < maxPages; i++) {
      if (!mounted) return false;
      final msgs = _messagesForUi(svc);
      if (msgs.isEmpty) {
        final added = await _ensureOlderFromDb(svc);
        if (added <= 0) return false;
        continue;
      }
      // Reached the read frontier (or older) — divider target is in RAM.
      if (lastRead > 0 && msgs.first.id <= lastRead) return true;
      // Continuous history from tip: enough unreads means firstUnread is known.
      final loadedUnread = lastRead > 0
          ? msgs.where((m) => m.id > lastRead).length
          : msgs.length;
      if (loadedUnread >= unread && lastRead > 0) return true;
      // Never soft-cap while last_read is still older than everything loaded.
      if (msgs.length >= hardCap && loadedUnread >= unread) return true;

      final added = await _ensureOlderFromDb(svc);
      if (added <= 0) {
        // No more pages — best-effort pin to oldest loaded unread.
        return true;
      }
    }
    return _messagesForUi(svc).isNotEmpty;
  }

  /// Oldest message with id > open last_read — only when frontier is spanned
  /// (or [allowBestEffort] after history exhausted). Tip-only RAM must not
  /// pretend the newest pack head is the sticky first-unread.
  int? _resolveFirstUnreadId(
    TelegramTdlibService svc, {
    bool allowBestEffort = false,
  }) {
    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    if (unread <= 0) return null;
    final spanned = _unreadFrontierSpanned(svc);
    if (unread >= 2 && !allowBestEffort && !spanned) {
      return null;
    }
    // Prefer service when spanned (or stale-high last_read tip-count).
    final fromSvc = svc.firstUnreadMessageId(widget.chatId);
    if (fromSvc != null) return fromSvc;
    // Best-effort after history exhausted: oldest loaded unread — never tip.
    // Tip-only packs (oldest still above last_read) must stay null: pinning
    // the tip-pack head then revealing wiped 80+ unreads (Осташко 22:25).
    final lastRead =
        _openLastReadInboxId ?? svc.lastReadInboxMessageId(widget.chatId);
    final msgs = _messagesForUi(svc);
    if (unread >= 2 &&
        lastRead > 0 &&
        msgs.isNotEmpty &&
        msgs.first.id > lastRead) {
      return null;
    }
    for (final m in msgs) {
      if (!m.isOutgoing && m.id > lastRead) return m.id;
    }
    return null;
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
  int _timelineContentFp = 0;
  List<_TgTimelineRow>? _cachedTimeline;
  List<_TgTimelineRow>? _cachedReversedTimeline;

  /// Reuse album grouping across rebuilds when the *structure* is unchanged.
  /// Reaction / path / text-paint patches must NOT rebuild the timeline — the
  /// itemBuilder resolves live [TdlibMessage] via messagesById. Key on id +
  /// album + text hash so edits still regroup correctly.
  List<_TgTimelineRow> _timelineCached(List<TdlibMessage> chronological) {
    final first = chronological.isEmpty ? 0 : chronological.first.id;
    final last = chronological.isEmpty ? 0 : chronological.last.id;
    final contentFp = chronological.isEmpty
        ? 0
        : Object.hashAll(
            chronological.map(
              (m) => Object.hash(m.id, m.mediaAlbumId, m.text.hashCode),
            ),
          );
    if (_cachedTimeline != null &&
        chronological.length == _timelineLen &&
        first == _timelineFirstId &&
        last == _timelineLastId &&
        contentFp == _timelineContentFp) {
      return _cachedTimeline!;
    }
    _timelineLen = chronological.length;
    _timelineFirstId = first;
    _timelineLastId = last;
    _timelineContentFp = contentFp;
    _cachedTimeline = _buildTimeline(chronological);
    _cachedReversedTimeline =
        _cachedTimeline!.reversed.toList(growable: false);
    return _cachedTimeline!;
  }

  TdlibMessage _liveMessage(
    TdlibMessage m,
    Map<int, TdlibMessage> byId,
  ) =>
      byId[m.id] ?? m;

  List<TdlibMessage> _liveMembers(
    _TgTimelineRow row,
    Map<int, TdlibMessage> byId,
  ) {
    if (!row.isAlbum) return [_liveMessage(row.primary, byId)];
    return [for (final m in row.members) _liveMessage(m, byId)];
  }

  List<_TgTimelineRow> _reversedTimelineCached(List<TdlibMessage> msgs) {
    _timelineCached(msgs);
    return _cachedReversedTimeline ?? const [];
  }

  List<Map<String, dynamic>> _attachmentsForRow(
    _TgTimelineRow row,
    Map<int, TdlibMessage> byId,
  ) {
    final members = _liveMembers(row, byId);
    if (members.length == 1) return _attachments(members.first);
    final ordered = [...members]..sort((a, b) => a.id.compareTo(b.id));
    final out = <Map<String, dynamic>>[];
    for (final m in ordered) {
      out.addAll(_attachments(m));
    }
    return out;
  }

  Map<String, dynamic> _messageMetadataForRow(
    _TgTimelineRow row,
    Map<int, TdlibMessage> byId,
  ) {
    for (final m in _liveMembers(row, byId)) {
      if (m.isSticker || m.isAnimation || m.isVideo) {
        return _messageMetadata(m);
      }
    }
    return _messageMetadata(_liveMessage(row.primary, byId));
  }

  String _bubbleBodyForRow(
    _TgTimelineRow row,
    Map<int, TdlibMessage> byId,
  ) {
    if (row.isAlbum) return row.caption;
    final m = _liveMessage(row.primary, byId);
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

  List<ChatTextEntity> _textEntitiesForRow(
    _TgTimelineRow row,
    Map<int, TdlibMessage> byId,
  ) {
    final m = _liveMessage(row.primary, byId);
    final body = _bubbleBodyForRow(row, byId);
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

  /// Leave the conversation onto the hub chat list (not one-level back).
  void _exitToChatList() {
    final nav = Navigator.of(context);
    if (!nav.canPop()) return;
    nav.popUntil((route) => route.isFirst);
  }

  Future<void> _toggleNotifications() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final muted = svc.isChatMuted(widget.chatId);
    final nextMuted = !muted;
    try {
      await svc.setChatMuted(widget.chatId, muted: nextMuted);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextMuted ? 'Уведомления отключены' : 'Уведомления включены',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось изменить уведомления: $e')),
      );
    }
  }

  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить историю?'),
        content: const Text(
          'Все сообщения в этом чате будут удалены. Чат останется в списке.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(telegramTdlibServiceProvider)
          .clearChatHistory(widget.chatId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('История очищена')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось очистить историю: $e')),
      );
    }
  }

  Future<void> _confirmDeleteOrLeave() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final isChannel = svc.isChannelChat(widget.chatId);
    final isGroup = svc.isGroupChat(widget.chatId);
    final title = isChannel
        ? 'Покинуть канал?'
        : isGroup
            ? 'Покинуть группу?'
            : 'Удалить чат?';
    final body = isChannel || isGroup
        ? widget.title
        : 'Чат будет удалён из списка вместе с историей.';
    final confirmLabel =
        isChannel || isGroup ? 'Покинуть' : 'Удалить';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (isChannel || isGroup) {
        await svc.leaveChat(widget.chatId);
      } else {
        await svc.deleteChat(widget.chatId);
      }
      if (!mounted) return;
      _exitToChatList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isChannel || isGroup
                ? 'Не удалось покинуть: $e'
                : 'Не удалось удалить чат: $e',
          ),
        ),
      );
    }
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

  Future<bool> _handleOpenUrl(String url) async {
    try {
      if (await YoutubeProxyNavigation.tryOpen(context, url)) return true;
    } catch (_) {}
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
    // Link-preview cards + Dio after open settle. Channels: much later —
    // enable@6.5s rebuilt tip rows and froze FRAME total≈4.5s (Шарий 20:37).
    final svc = ref.read(telegramTdlibServiceProvider);
    final delay = svc.isChannelChat(widget.chatId)
        ? const Duration(seconds: 22)
        : const Duration(seconds: 12);
    Timer(delay, () {
      if (!mounted || _isUserActivelyScrolling || _blocksLinkPreviews) {
        Timer(const Duration(seconds: 3), () {
          if (!mounted ||
              _isUserActivelyScrolling ||
              _blocksLinkPreviews) {
            return;
          }
          _enableLinkPreviews();
        });
        return;
      }
      _enableLinkPreviews();
    });
  }

  void _enableLinkPreviews() {
    if (!mounted || _linkPreviewsEnabled) return;
    if (_isUserActivelyScrolling || _blocksLinkPreviews) {
      Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        _enableLinkPreviews();
      });
      return;
    }
    TgJankLog.log('enable link previews');
    LinkPreviewService.instance.linkPreviewGateOpen = true;
    // Open Dio after this frame — one setState only (second rebuild was
    // stacking on the quiet-pierce NOTIFY storm).
    LinkPreviewService.instance.deferNetworkFetches = true;
    setState(() => _linkPreviewsEnabled = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      LinkPreviewService.instance.deferNetworkFetches = false;
    });
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
        final svc = ref.read(telegramTdlibServiceProvider);
        // Short unread tail already on screen (cannot pin the bar to the top).
        // Deep stacks: still require spanned floor before mark-read.
        if (_isUnreadAnchorInViewport(requireSeparatorAtTop: true) &&
            (_openUnreadCount < 2 || _unreadFrontierSpanned(svc))) {
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
    final msgs = _messagesForUi(svc);
    final timeline = _buildTimeline(msgs);
    final rowIndex =
        timeline.indexWhere((r) => r.containsMessageId(messageId));
    if (rowIndex < 0) return false;
    final keyId = _visibleKeyMessageId(messageId, timeline);

    final wasProgrammatic = _programmaticOpenScroll;
    _programmaticOpenScroll = true;
    // Wide enough to mount the frontier — avoid 8000px rebuild storms on open.
    // Do not expand again after reveal: shrinking back to 1200 then expanding
    // rebuilt 130+ rows every reassert (Осташко hang).
    if (!_contentReady && _listCacheExtent < 3200) {
      setState(() => _listCacheExtent = 3600);
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
        // reverse:true → AxisDirection.up. For a row taller than the viewport
        // (code blocks…), keepVisibleAtEnd prefers the trailing edge = visual
        // TOP (separator + start of first unread), not the message end.
        await Scrollable.ensureVisible(
          ctx,
          duration: useInstant || attempt == 0
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: alignment,
          alignmentPolicy: alignment <= 0.001
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.explicit,
        );
        // Pin the unread bar flush to the top of the chat viewport when
        // opening on the frontier (alignment 0).
        if (alignment <= 0.001) {
          for (var pin = 0; pin < 8; pin++) {
            await _pinUnreadSeparatorToTop();
            await WidgetsBinding.instance.endOfFrame;
            if (_isUnreadAnchorInViewport(requireSeparatorAtTop: true)) {
              break;
            }
            // Separator not built yet — step toward older history so the
            // frontier row mounts; if on-screen but low, pin corrected by -dy.
            final sepCtx = _unreadSeparatorKey.currentContext;
            if (sepCtx == null && _scroll.hasClients && pin < 7) {
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
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
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
    // Modest cache — 8000px forced ~125 channel rows (build 250ms+) on open.
    if (_listCacheExtent < 2800) {
      setState(() => _listCacheExtent = 2800);
      await WidgetsBinding.instance.endOfFrame;
    }

    try {
    final historyReady = await _ensureUnreadHistoryLoaded(svc);
    if (!mounted) return;

    final unread = _openUnreadCount > 0
        ? _openUnreadCount
        : svc.unreadCountFor(widget.chatId);
    final spanned = _unreadFrontierSpanned(svc);
    // After load budget / exhausted pages, accept oldest loaded unread.
    final firstUnread = _resolveFirstUnreadId(
      svc,
      allowBestEffort: historyReady && !spanned,
    );
    final msgs = _messagesForUi(svc);

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
    // retry as history pages in. Do not reveal / lift mark-read suppress.
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
    // Always require the unread bar at the visual top (not the end of a tall
    // first-unread). Separator paints whenever _unreadAnchorMessageId is set.
    const needSep = true;
    if (ok &&
        !_isUnreadAnchorInViewport(requireSeparatorAtTop: needSep)) {
      ok = false;
    }
    if (!ok && mounted) {
      // History may still be growing — retry a few times before giving up.
      for (var i = 0; i < 10 && mounted && !ok; i++) {
        await Future<void>.delayed(Duration(milliseconds: 80 + i * 60));
        if (!mounted) return;
        final ready = await _ensureUnreadHistoryLoaded(svc);
        final again = _resolveFirstUnreadId(
          svc,
          allowBestEffort: ready && !_unreadFrontierSpanned(svc),
        );
        // Open only: allow refining to an older first-unread as history fills.
        // Never move the visit sticky toward a newer id.
        if (again != null) {
          final cur = _unreadAnchorMessageId;
          if (cur == null || again <= cur) {
            anchorId = again;
            if (mounted) {
              setState(() => _unreadAnchorMessageId = again);
            }
          } else {
            anchorId = cur;
          }
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
    // History often floods tip→200 after the first tip-window jump. Re-resolve
    // the real first-unread before accepting the pin (Осташко 22:25 stuck on
    // tip-pack head 237790822400 while unread=81).
    if (unread >= 2 && mounted) {
      final spannedNow = _unreadFrontierSpanned(svc);
      final trueFirst = _resolveFirstUnreadId(
        svc,
        allowBestEffort: historyReady && !spannedNow,
      );
      if (trueFirst != null && trueFirst != anchorId) {
        TgJankLog.log(
          'open-pos rebind tip=$anchorId → first=$trueFirst unread=$unread',
        );
        anchorId = trueFirst;
        if (mounted) {
          setState(() => _unreadAnchorMessageId = trueFirst);
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
      } else if (trueFirst == null && !spannedNow) {
        ok = false;
      }
    }

    _initialScrollDone = true;
    _msgsLenAtUnreadJump = _messagesForUi(svc).length;
    final pinned = _isUnreadAnchorInViewport(requireSeparatorAtTop: needSep);
    TgJankLog.log(
      'open-pos done ok=$ok pinned=$pinned anchor=$anchorId '
      'unread=$unread msgs=${_msgsLenAtUnreadJump} needSep=$needSep',
    );
    if (ok && pinned) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        setState(() => _listCacheExtent = 1200);
        _revealChatContent();
      }
      // Only lift mark-read when the open floor is in RAM. Tip-only pin still
      // advances last_read past unloaded unreads and wipes the pack.
      if (unread < 2 || _unreadFrontierSpanned(svc)) {
        _unreadFrontierReady = true;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (mounted) {
          // Progressive markVisible still waits for [_userReleasedUnreadGate].
          // Keep force viewMessages blocked for multi-unread until the user
          // scrolls — focus on tip posts used to wipe the pack (Осташко).
          _suppressMarkRead = false;
          if (unread < 2) {
            ref
                .read(telegramTdlibServiceProvider)
                .setBlockUnreadForceView(false);
          }
        }
        _scheduleViewportPrefetch();
        // Frontier pinned → progressive mark of on-screen rows (multi-unread
        // included). Do not wait for scroll-away gate — that left hub badges
        // stuck when the pack fit on screen / user only scrolled to tip.
        _scheduleMarkVisibleRead();
      } else {
        _scheduleViewportPrefetch();
        if (!historyReady) {
          _scheduleReassertUnreadScroll();
        }
      }
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
    if (_contentReady) {
      _unreadReassertAfterReveal++;
      // Two tries after paint is enough to catch the history flood.
      // Further 280ms jumps rebuilt the whole 200-row list forever.
      if (_unreadReassertAfterReveal > 2) return;
    }
    _reassertUnreadScrollTimer?.cancel();
    _reassertUnreadScrollTimer =
        Timer(const Duration(milliseconds: 280), () {
      if (!mounted || _unreadFrontierReady) return;
      unawaited(_reassertUnreadScroll());
    });
  }

  Future<void> _reassertUnreadScroll() async {
    if (!mounted || _unreadFrontierReady) return;
    // No open unreads → tip is fine.
    if (_openUnreadCount <= 0) {
      _unreadFrontierReady = true;
      _suppressMarkRead = false;
      _revealChatContent();
      return;
    }
    if (_isUserActivelyScrolling && !_programmaticOpenScroll) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    _programmaticOpenScroll = true;
    try {
      // Deep unread: keep loading until spanned (or history exhausted). Never
      // reveal tip + lift mark-read while anchor is still null / tip-only.
      final historyReady = await _ensureUnreadHistoryLoaded(svc);
      if (!mounted || _unreadFrontierReady) return;
      final spanned = _unreadFrontierSpanned(svc);
      final resolved = _resolveFirstUnreadId(
        svc,
        allowBestEffort: historyReady && !spanned,
      );
      if (resolved != null) {
        final cur = _unreadAnchorMessageId;
        if (cur == null || resolved <= cur) {
          if (mounted) {
            setState(() => _unreadAnchorMessageId = resolved);
          } else {
            _unreadAnchorMessageId = resolved;
          }
        }
      }

      final anchor = _unreadAnchorMessageId;
      if (anchor == null) {
        // Still no frontier in RAM — keep suppress + hidden; retry.
        // Open reveal timeout stays the soft escape for unread < 2 only.
        if (_openUnreadCount >= 2) {
          TgJankLog.log(
            'open-reassert defer unread=$_openUnreadCount '
            'spanned=$spanned historyReady=$historyReady',
          );
          if (!historyReady) {
            _scheduleReassertUnreadScroll();
          }
          return;
        }
        _unreadFrontierReady = true;
        _suppressMarkRead = false;
        _revealChatContent();
        return;
      }

      final len = _messagesForUi(svc).length;
      // Always retry until frontier is visible — remote history fill often
      // resets reverse ListView back to the tip after the first jump.
      final ok = await _ensureVisibleMessage(
        anchor,
        alignment: 0.0,
        instant: true,
        unreadHint: _openUnreadCount,
      );
      if (!mounted) return;
      _msgsLenAtUnreadJump = len;
      if (ok &&
          _isUnreadAnchorInViewport(requireSeparatorAtTop: true)) {
        if (mounted) setState(() => _listCacheExtent = 1200);
        _revealChatContent();
        _scheduleViewportPrefetch();
        if (mounted) _updateScrollToBottomVisibility();
        // Mark-read only once the open floor is spanned — otherwise tip pin
        // advances last_read and clears unloaded unreads.
        if (_openUnreadCount < 2 || _unreadFrontierSpanned(svc)) {
          _unreadFrontierReady = true;
          _suppressMarkRead = false;
          // Keep force-view blocked for multi-unread until user scroll gate.
          if (_openUnreadCount < 2) {
            svc.setBlockUnreadForceView(false);
          }
          _scheduleMarkVisibleRead();
          return;
        }
        TgJankLog.log(
          'open-reassert pinned-best-effort unread=$_openUnreadCount '
          'anchor=$anchor historyReady=$historyReady (suppress mark-read)',
        );
        // History exhausted without spanning: keep suppress, stop hammering.
        // Growth via sync / loadOlder re-arms via [_maybeReassertUnreadAfterHistoryGrowth].
        if (!historyReady) {
          _scheduleReassertUnreadScroll();
        }
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
      final svc = ref.read(telegramTdlibServiceProvider);
      await _ensureOlderFromDb(svc);
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
        _messagesForUi(svc).length >= 40) {
      return;
    }
    var emptyStreak = 0;
    for (var i = 0; i < 20; i++) {
      if (!mounted) return;
      final count = _messagesForUi(svc).length;
      if (count >= 40) return;
      final added = await _ensureOlderFromDb(svc);
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
      // R49: await preempt first — unawaited raced ensureFileLocal so
      // downloadFile often started before openMessageContent/viewMessages.
      // Progressive play (official TG): open as soon as the stream proxy is
      // up; ExoPlayer Range requests drive TDLib downloadFile(offset/limit).
      unawaited(() async {
        var playId = id;
        final messageId = int.tryParse(play['message_id']?.toString() ?? '');
        if (messageId != null && messageId > 0) {
          final rebound = await svc.freshVideoFileId(
            chatId: widget.chatId,
            messageId: messageId,
            staleFileId: playId,
          );
          if (!mounted || _pendingOpenVideoId != id) return;
          if (rebound != null && rebound != playId) {
            play['id'] = rebound;
            play.remove('size_bytes');
            playId = rebound;
            if (mounted) setState(() => _pendingOpenVideoId = playId);
          }
        }
        await svc.preemptForUserTap(
          fileId: playId,
          chatId: widget.chatId,
          reason: 'tap:video:$playId',
        );
        if (!mounted || _pendingOpenVideoId != playId) return;
        final sizeBytes = () {
          final declared = play['size_bytes'];
          if (declared is int && declared > 0) return declared;
          if (declared is num && declared > 0) return declared.toInt();
          return svc.fileExpectedSize(playId);
        }();
        final mime = play['content_type']?.toString().trim();
        final streamUrl = await svc.beginVideoStream(
          fileId: playId,
          chatId: widget.chatId,
          expectedSize: sizeBytes > 0 ? sizeBytes : null,
          mimeType: (mime != null && mime.startsWith('video/'))
              ? mime
              : 'video/mp4',
        );
        if (!mounted || _pendingOpenVideoId != playId) return;
        if (streamUrl != null && streamUrl.isNotEmpty) {
          play['video_stream_url'] = streamUrl;
          if (sizeBytes > 0) play['size_bytes'] = sizeBytes;
          if (preferInline && !forceFullscreen) {
            if (mounted) setState(() => _pendingOpenVideoId = null);
            return;
          }
          await _openVideoViewer(play, '', gallery: galleryMedia);
          return;
        }
        // Already on disk, or stream unavailable → full-file path.
        final path = await svc.ensureFileLocal(
          playId,
          priority: TelegramTdlibService.prioFocused,
          reason: 'tap:video:$playId',
          waitFor: const Duration(minutes: 10),
        );
        if (!mounted) return;
        if (_pendingOpenVideoId != playId) return;
        if (path == null || path.isEmpty) {
          setState(() => _pendingOpenVideoId = null);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось загрузить видео')),
          );
          return;
        }
        if (preferInline && !forceFullscreen) {
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
    // Official: fullscreen may upgrade bubble `x` → `y`/`w`.
    final svc = ref.read(telegramTdlibServiceProvider);
    var id = int.tryParse(play['id']?.toString() ?? '');
    if (id != null && id > 0) {
      final upgrade = svc.photoFullscreenUpgradeId(id);
      if (upgrade != null && upgrade > 0) {
        id = upgrade;
        play['id'] = upgrade;
      }
      // R22/R49: await preempt so open/slot yield finishes before ensure.
      await svc.preemptForUserTap(
        fileId: id,
        chatId: widget.chatId,
        reason: 'tap:photo:$id',
      );
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
    if (videoPath.isNotEmpty) {
      play['video_local_path'] = videoPath;
    }
    // Keep thumb out of local_device_path — player must use video_local_path
    // or video_stream_url (progressive TDLib proxy).
    play.remove('local_device_path');
    if (!mounted) return;
    setState(() => _pendingOpenVideoId = null);
    // Gallery list is a snapshot from the bubble — stamp the downloaded path
    // onto the matching item. Otherwise ChatImageViewer ignores [play] and
    // opens a stale copy with empty localPath (black / non-playing video).
    List<Map<String, dynamic>>? galleryOut;
    if (gallery != null && gallery.length >= 2) {
      final playId = play['id']?.toString();
      final streamUrl = play['video_stream_url']?.toString();
      galleryOut = [
        for (final raw in gallery)
          () {
            final copy = Map<String, dynamic>.from(raw);
            if (playId != null &&
                playId.isNotEmpty &&
                copy['id']?.toString() == playId) {
              if (videoPath.isNotEmpty) {
                copy['video_local_path'] = videoPath;
              }
              if (streamUrl != null && streamUrl.isNotEmpty) {
                copy['video_stream_url'] = streamUrl;
              }
              copy.remove('local_device_path');
              copy.remove('is_downloading');
              copy.remove('download_progress');
            }
            return copy;
          }(),
      ];
    }
    final streamUrl = play['video_stream_url']?.toString() ?? '';
    await ChatImageViewer.open(
      context,
      imageUrl: streamUrl,
      threadId: widget.chatId,
      attachmentId: int.tryParse(play['id']?.toString() ?? ''),
      filename: play['filename']?.toString(),
      attachment: play,
      galleryAttachments: galleryOut,
      enableFaceTag: false,
    );
  }

  /// Hub snapshot unread when TDLib `_chats` is still empty (cold boot).
  int _hubSnapshotUnreadHint(int chatId) {
    final rows = HubFirstPaintSnapshot.warmed?.rows;
    if (rows == null || rows.isEmpty) return 0;
    for (final row in rows) {
      final id = chatAsInt(row['id']);
      if (id != chatId) continue;
      return chatAsInt(row['unread_count']) ?? 0;
    }
    return 0;
  }

  Future<void> _openAndWatch() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    _suppressMarkRead = true;
    _userReleasedUnreadGate = false;
    // Snapshot unread frontier before openChat / history mutate inbox state.
    _openLastReadInboxId = svc.lastReadInboxMessageId(widget.chatId);
    _openUnreadCount = svc.unreadCountFor(widget.chatId);
    // Cold boot: RAM chats empty → unreadCountFor=0 while hub still shows N.
    // Without this we tip-reveal + markCaughtUp and wipe the pack (Осташко).
    if (_openUnreadCount <= 0) {
      final snap = _hubSnapshotUnreadHint(widget.chatId);
      if (snap > _openUnreadCount) _openUnreadCount = snap;
    }
    // Multi-unread: block viewMessages from the first frame. Opening used to
    // allow briefly, then tip focus marked the whole pack read (Осташко 81→0).
    if (_openUnreadCount >= 2) {
      svc.setBlockUnreadForceView(true);
    } else {
      svc.setBlockUnreadForceView(false);
    }
    // SQLite tip first — paint ≤20 immediately; migrate/ensureTip in background.
    _windowLimit = TgHistoryStore.tipPaintCap;
    var tip = await TgHistoryStore.instance.readTail(
      widget.chatId,
      limit: _windowLimit,
    );
    if (tip.isEmpty) {
      // Cold: one-shot meta tip for first paint (full migrate is async).
      final cached = await TdlibTranscriptCache.read(widget.chatId);
      if (cached.isNotEmpty) {
        tip = cached.length <= _windowLimit
            ? cached
            : cached.sublist(cached.length - _windowLimit);
      }
    }
    if (!mounted) return;
    setState(() => _dbMessages = tip);
    _bindDbWatch();
    debugPrint(
      '[tg-db] tip/watch chat=${widget.chatId} tip=${tip.length} '
      'window=$_windowLimit',
    );
    unawaited(() async {
      await TgHistoryStore.instance.migrateFromTranscriptCacheIfNeeded(
        widget.chatId,
      );
      await svc.seedTranscriptFromCache(widget.chatId);
      await TgHistoryStore.instance.ensureTip(
        widget.chatId,
        chatType: TgHistoryStore.chatTypeLabel(
          isChannel: svc.isChannelChat(widget.chatId),
          isPrivate: svc.isPrivateChat(widget.chatId),
          isGroup: svc.isGroupChat(widget.chatId),
        ),
        title: svc.peerTitle(widget.chatId),
        loadTip: () => svc.loadTipHistoryForDb(
          widget.chatId,
          maxCount: TgHistoryStore.tipPaintCap,
        ),
      );
    }());
    // Re-read after seed — cache may expose a deeper unread pack than tip RAM.
    final seededUnread = svc.unreadCountFor(widget.chatId);
    if (seededUnread > _openUnreadCount) {
      _openUnreadCount = seededUnread;
    }
    // Claim immediately so dispose during await still has a valid close token.
    _openChatToken = svc.claimOpenChat(widget.chatId);
    final deepLink =
        widget.initialMessageId != null && widget.initialMessageId! > 0;
    final unread = _openUnreadCount;
    // Multi-unread: stay "not near tip" until jump pins the first unread —
    // otherwise tip seed / last_message upsert auto-marks through the pack.
    // Also block force viewMessages (tap/stream) until the user scrolls.
    if (unread >= 2) {
      svc.setOpenChatNearTip(false);
      svc.setBlockUnreadForceView(true);
    }
    // Only seed sticky when first-unread is known (spanned) — tip-count used
    // to plant the tip as the «Непрочитанные» anchor before history loaded.
    final preUnread = svc.firstUnreadMessageId(widget.chatId);
    if (preUnread != null &&
        (unread < 2 || svc.isUnreadHistoryWarm(widget.chatId))) {
      _unreadAnchorMessageId = preUnread;
    }
    final warm = svc.isUnreadHistoryWarm(widget.chatId);
    // Hide+jump only when the tip is wrong: deep link, or unread ≥ 2.
    // unread 0/1 → reverse list already sits on the tip (the only unread).
    final needsPositionGate = deepLink || unread >= 2;
    // Thin SQLite tip — wait for openChat/ensureTip before early reveal.
    final tipThin = _messagesForUi(svc).length < 16;
    if (!needsPositionGate && !tipThin) {
      // Warm tip photos first so reveal doesn't flash empty→JPEG.
      await _precacheRecentMedia();
      if (!mounted) return;
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
    } else if (!needsPositionGate && tipThin) {
      _armDelayedOpenLoader();
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
      // Was 4s → syncChatTail(40) + rebuild storms forever (Шарий BUILD×2400,
      // gap≈4s). Poll tip lightly and only when idle near tip.
      _tailSyncTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!mounted) return;
        if (_isUserActivelyScrolling || _imeUiBusy) return;
        if (!_scroll.hasClients) return;
        if (_scroll.position.pixels > _scrollToBottomAwayPx) return;
        unawaited(
          svc.syncChatTail(widget.chatId, limit: 5, lightPoll: true),
        );
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
    if (!mounted) return;
    // openChat may hydrate unread after a cold unread=0 snapshot — re-gate.
    final liveUnread = svc.unreadCountFor(widget.chatId);
    if (liveUnread > _openUnreadCount) {
      _openUnreadCount = liveUnread;
    }
    final mustJumpUnread = !deepLink && _openUnreadCount >= 2;
    if (needsPositionGate || mustJumpUnread) {
      if (mustJumpUnread && !needsPositionGate) {
        TgJankLog.log(
          'open-unread late-gate live=$_openUnreadCount '
          '(was tip-path unread=$unread)',
        );
        svc.setOpenChatNearTip(false);
        svc.setBlockUnreadForceView(true);
        _suppressMarkRead = true;
        _contentReady = false;
        // Tip-path may already have set this — allow [_positionInitialScroll].
        _initialScrollDone = false;
      }
      if (!warm) {
        await svc.syncChatTail(widget.chatId);
        await _fillHistoryIfSparse();
      } else {
        unawaited(svc.syncChatTail(widget.chatId));
      }
      unawaited(svc.refreshVideoChat(widget.chatId));
      await _positionInitialScroll(svc);
    } else {
      if (!_contentReady) {
        await _precacheRecentMedia();
        if (!mounted) return;
        _revealChatContent();
        _initialScrollDone = true;
        if (_openUnreadCount <= 0) {
          _unreadFrontierReady = true;
          _suppressMarkRead = false;
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _unreadFrontierReady = true;
            _suppressMarkRead = false;
            _scheduleMarkVisibleRead();
          });
        }
      }
      unawaited(svc.syncChatTail(widget.chatId));
      unawaited(svc.refreshVideoChat(widget.chatId));
      if (_openUnreadCount <= 0 && svc.unreadCountFor(widget.chatId) <= 0) {
        await _markCaughtUp();
      }
      _scheduleViewportPrefetch();
    }
    await finishOpenSideEffects();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final svc = ref.read(telegramTdlibServiceProvider);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(svc.persistTranscriptCache(widget.chatId));
      return;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(svc.syncChatTail(widget.chatId));
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
    _dbWatchSub?.cancel();
    _dbWatchSub = null;
    _dbWatchApplyTimer?.cancel();
    _dbWatchApplyTimer = null;
    _dbWatchPending = null;
    _tailSyncTimer?.cancel();
    _scrollToBottomHintTimer?.cancel();
    _viewportPrefetchTimer?.cancel();
    _mediaIdleRescanTimer?.cancel();
    _markVisibleReadTimer?.cancel();
    _scrollBusyClearTimer?.cancel();
    _imeBusyClearTimer?.cancel();
    _imeUiBusy = false;
    TelegramTdlibService.instance.setUiImeBusy(false);
    _reassertUnreadScrollTimer?.cancel();
    _openRevealTimeout?.cancel();
    _openLoaderTimer?.cancel();
    _stickyDayThrottle?.cancel();
    _scroll.removeListener(_onScroll);
    _inputFocus.removeListener(_onInputFocusChanged);
    final rescan = _viewportMediaRescanListener;
    if (rescan != null) {
      TelegramTdlibService.instance.removeViewportMediaRescanListener(rescan);
      _viewportMediaRescanListener = null;
    }
    final chatId = widget.chatId;
    final openToken = _openChatToken;
    // Leave-chat flush: if the unread frontier was on screen but progressive
    // mark never ran (gate / short visit), still advance inbox before close.
    int leaveMarkId = _maxMarkedReadId;
    if (_unreadFrontierReady &&
        !_suppressMarkRead &&
        _scroll.hasClients) {
      try {
        final svc = TelegramTdlibService.instance;
        final msgs = _messagesForUi(svc);
        final lastRead = svc.lastReadInboxMessageId(chatId);
        final floor =
            leaveMarkId > lastRead ? leaveMarkId : lastRead;
        final visible =
            _highestVisibleUnreadByLayout(msgs: msgs, floor: floor);
        if (visible > leaveMarkId) leaveMarkId = visible;
        // Near tip after reading the pack → mark tip (hub badge must clear).
        if (msgs.isNotEmpty &&
            _scroll.position.pixels <= _scrollToBottomAwayPx &&
            msgs.last.id > leaveMarkId) {
          leaveMarkId = msgs.last.id;
        }
      } catch (_) {}
    }
    final flushMarkId = leaveMarkId;
    // Defer: closeChat → notifyListeners must not run during unmount
    // (Riverpod forbids provider updates while the tree is building).
    Future(() async {
      if (flushMarkId > 0) {
        try {
          await TelegramTdlibService.instance.markMessagesRead(
            chatId,
            [flushMarkId],
          );
        } catch (_) {}
      }
      await TelegramTdlibService.instance.closeChat(
        chatId,
        openToken: openToken,
      );
    });
    LinkPreviewService.instance.deferNetworkFetches = false;
    LinkPreviewService.instance.linkPreviewGateOpen = false;
    _textCtrl.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _animatedMediaController.dispose();
    _inlineVideoAutoplay.dispose();
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

  /// Like voice: always stage into app-owned `tdlib_upload_*` before TDLib.
  Future<String> _localPathForItem(ChatAttachSelectionItem item) async {
    final name = item.filename.trim().isNotEmpty
        ? item.filename
        : (item.localPath != null ? p.basename(item.localPath!) : 'file.bin');
    return ref.read(telegramTdlibServiceProvider).stageLocalFileForTdlib(
          localPath: item.localPath,
          bytes: item.bytes,
          filename: name,
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
    final svc = ref.read(telegramTdlibServiceProvider);

    // Saved Messages: TG user-info layout (media/links), titled «Избранное».
    if (svc.isSavedMessagesChat(widget.chatId)) {
      await _openSavedMessagesInfo();
      return;
    }

    final fcId = widget.fcUserId;
    if (fcId != null && fcId > 0) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MemberProfileScreen(userId: fcId),
        ),
      );
      return;
    }
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
        onGoToMessage: _jumpToLinkedMessage,
      );
      return;
    }
    final tgUserId =
        widget.tgUserId ?? svc.privatePeerUserId(widget.chatId);
    if (tgUserId == null || tgUserId <= 0) return;
    await _openSenderInfo(tgUserId);
  }

  Future<void> _openSavedMessagesInfo() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final myId = svc.myUserId ?? svc.privatePeerUserId(widget.chatId) ?? 0;
    TdlibUserProfile? profile;
    if (myId > 0) {
      profile = await svc.loadUserProfile(myId);
    }
    if (!mounted) return;
    final base = profile;
    final savedProfile = TdlibUserProfile(
      userId: base?.userId ?? myId,
      displayName: widget.title.trim().isNotEmpty
          ? widget.title.trim()
          : 'Избранное',
      username: base?.username ?? '',
      phoneNumber: base?.phoneNumber ?? '',
      bio: base?.bio ?? '',
      statusText: 'Только вы',
      avatarLocalPath: base?.avatarLocalPath ??
          svc.peerAvatarPath(widget.chatId),
      avatarFileId: base?.avatarFileId,
    );
    await TelegramUserInfoSheet.show(
      context,
      chatId: widget.chatId,
      profile: savedProfile,
      onGoToMessage: _jumpToLinkedMessage,
    );
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
      // Jump only when the sheet's link list is this open chat (not a DM
      // opened from a group member row).
      onGoToMessage:
          dmChatId == widget.chatId ? _jumpToLinkedMessage : null,
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

  Future<bool> _ensureSmartSpeechConsent() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    if (await svc.hasSmartSpeechConsent()) return true;
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Расшифровка голосовых'),
        content: const Text(
          'Чтобы получить текст голосового сообщения, FamilyChat '
          'подключит бота SaluteSpeech (@smartspeech_sber_bot) и перешлёт '
          'ему это сообщение от вашего имени.\n\n'
          'Ответ бота появится как текст у голосового. Чат с ботом скрыт '
          'из списка — найти его можно через поиск по названию.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Согласен'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await svc.setSmartSpeechConsent(true);
    return true;
  }

  Future<void> _requestVoiceTranscript(TdlibMessage m) async {
    if (!m.isVoiceNote) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.isVoiceTranscriptPending(widget.chatId, m.id)) return;
    final existing = svc.voiceTranscriptText(widget.chatId, m.id);
    if (existing != null && existing.isNotEmpty) {
      await ref.read(voiceMessagePreferTextProvider.notifier).setPreferText(true);
      return;
    }
    if (!await _ensureSmartSpeechConsent()) return;
    if (!mounted) return;
    try {
      final text = await svc.requestVoiceTranscript(
        chatId: widget.chatId,
        messageId: m.id,
      );
      if (!mounted) return;
      if (text != null && text.isNotEmpty) {
        await ref
            .read(voiceMessagePreferTextProvider.notifier)
            .setPreferText(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось получить текст. Попробуйте ещё раз.'),
          ),
        );
      }
    } on TdlibSmartSpeechNeedConsent {
      // Consent cleared elsewhere — ignore.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка расшифровки: $e')),
      );
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
    final norm = TelegramTdlibService.normalizeReactionEmoji(emoji);
    final chosen = m.reactions.where(
      (r) =>
          TelegramTdlibService.normalizeReactionEmoji(r.emoji) == norm &&
          r.chosen,
    );
    final already = chosen.isNotEmpty;
    // Remove with the exact glyph TDLib stored on the message (toggle-off).
    final sendEmoji = already
        ? TelegramTdlibService.normalizeReactionEmoji(chosen.first.emoji)
        : norm;
    try {
      await ref.read(telegramTdlibServiceProvider).toggleReaction(
            chatId: m.chatId,
            messageId: m.id,
            emoji: sendEmoji,
            add: !already,
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            already
                ? 'Не удалось снять реакцию'
                : 'Не удалось поставить реакцию',
          ),
        ),
      );
    }
  }

  Future<void> _deleteSelected({required bool revoke}) async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final selected = _messagesForUi(svc)
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
      final fileId = m.voiceFileId;
      final path = m.voiceLocalPath ??
          (fileId == null ? null : svc.cachedFilePath(fileId));
      final durationMs = m.voiceDurationMs ?? 0;
      final hasPath = path != null && path.isNotEmpty;
      // Always paint the voice player — empty attachments used to collapse
      // to a blank bubble while the file was still remote.
      // R70: do NOT ensure here — ChatVoiceMessagePlayer already auto-ensures
      // once. Double ensure×N visible bubbles flooded FakeTLS slot=1 on
      // mobile (purge/slot-fail while .oga was already on disk).
      final downloading = !hasPath &&
          fileId != null &&
          fileId > 0 &&
          svc.isFileDownloading(fileId);
      return [
        {
          'id': fileId ?? m.id,
          'kind': 'file',
          'content_type': 'audio/ogg',
          'filename': voiceMessageFilename(
            durationMs > 0 ? durationMs : 0,
            extension: 'ogg',
          ),
          'skip_age_defer': true,
          if (fileId != null && fileId > 0) 'tdlib_file_id': fileId,
          if (hasPath) 'local_device_path': path,
          if (!hasPath) 'is_downloading': true,
          if (downloading)
            'download_progress': svc.fileDownloadProgress(fileId!),
        },
      ];
    }

    if (m.isVideoNote) {
      final fileId = m.videoNoteFileId;
      final path = m.videoNoteLocalPath ??
          (fileId == null ? null : svc.cachedFilePath(fileId));
      // Thumbs come from exclusive focus; body via TDLib (not FC HTTP).
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
      final previewLoading = svc.videoPreviewNeedsFocusDownload(m) &&
          svc.isMessagePreviewLoading(m);
      final bodyLoading = fileId != null &&
          (path == null || path.isEmpty) &&
          svc.isFileDownloading(fileId);
      final downloading = previewLoading || bodyLoading;
      final progress = downloading
          ? (svc.messagePreviewProgress(m) ??
              (fileId == null ? null : svc.fileDownloadProgress(fileId)))
          : null;
      final sizeBytes =
          fileId == null ? 0 : svc.fileExpectedSize(fileId);
      final downloadedBytes =
          fileId == null ? 0 : svc.fileDownloadedBytes(fileId);
      return [
        {
          'id': fileId ?? m.id,
          'kind': 'video',
          'content_type': 'video/mp4',
          'filename': 'video_note_${durationMs > 0 ? durationMs : m.id}.mp4',
          'is_video_note': true,
          'skip_age_defer': true,
          if (fileId != null && fileId > 0) 'tdlib_file_id': fileId,
          if (path != null && path.isNotEmpty) ...{
            'local_device_path': path,
            'video_local_path': path,
          },
          if (thumbPath != null && thumbPath.isNotEmpty)
            'thumbnail_local_path': thumbPath,
          if ((thumbPath == null || thumbPath.isEmpty) &&
              m.videoNoteThumbBytes != null &&
              m.videoNoteThumbBytes!.isNotEmpty)
            'thumbnail_bytes': Uint8List.fromList(m.videoNoteThumbBytes!),
          if (sizeBytes > 0) 'size_bytes': sizeBytes,
          if (downloading) 'is_downloading': true,
          if (downloading && progress != null) 'download_progress': progress,
          if (downloading) 'downloaded_bytes': downloadedBytes,
        },
      ];
    }

    if (m.isVideo) {
      var path = m.videoLocalPath ??
          (m.videoFileId == null ? null : svc.cachedFilePath(m.videoFileId!));
      if (path != null && path.isNotEmpty) {
        final lower = path.toLowerCase();
        final image = lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp');
        if (image) path = null;
      }
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
      final hasThumbFile = thumbPath != null && thumbPath.isNotEmpty;
      // Spinner: thumb preview loading, or full body on tap (even if thumb ready).
      // Progressive stream ready → playable; do not keep the blocking loader
      // while TDLib fills ranges in the background.
      final tapping = fileId != null && _pendingOpenVideoId == fileId;
      final streamReady = fileId != null &&
          (svc.videoStreamUrl(fileId) ?? '').isNotEmpty;
      final previewLoading = svc.videoPreviewNeedsFocusDownload(m) &&
          svc.isMessagePreviewLoading(m);
      final bodyLoading = fileId != null &&
          (path == null || path.isEmpty) &&
          !streamReady &&
          (tapping || svc.isFileDownloading(fileId));
      final downloading = previewLoading || bodyLoading;
      final progress = downloading
          ? (svc.messagePreviewProgress(m) ??
              (fileId == null ? null : svc.fileDownloadProgress(fileId)))
          : null;
      final sizeBytes = () {
        final declared = m.videoSizeBytes ?? 0;
        if (declared > 0) return declared;
        if (fileId == null) return 0;
        return svc.fileExpectedSize(fileId);
      }();
      final downloadedBytes =
          fileId == null ? 0 : svc.fileDownloadedBytes(fileId);
      return [
        {
          'id': fileId ?? m.id,
          'message_id': m.id,
          'kind': 'video',
          'content_type': m.isAnimation ? 'image/gif' : 'video/mp4',
          'filename':
              '${m.isAnimation ? 'animation' : 'video'}_$durationMs.$ext',
          'skip_age_defer': true,
          // Keep video file separate — ChatNetworkImage must not decode mp4.
          if (path != null && path.isNotEmpty) 'video_local_path': path,
          if (fileId != null &&
              (svc.videoStreamUrl(fileId) ?? '').isNotEmpty)
            'video_stream_url': svc.videoStreamUrl(fileId),
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
          if (sizeBytes > 0) 'size_bytes': sizeBytes,
          if (downloading) 'is_downloading': true,
          if (downloading && progress != null) 'download_progress': progress,
          if (downloading) 'downloaded_bytes': downloadedBytes,
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
    // Soft m on disk + sharp x in flight still needs the loader (R45).
    // Progressive JPEG prefix already paints — drop the blocking overlay.
    final progressiveReady =
        fileId != null && svc.hasProgressivePhotoPaint(fileId);
    final downloading = !progressiveReady &&
        svc.photoNeedsFocusDownload(m) &&
        svc.isMessagePreviewLoading(m);
    final progress =
        downloading ? svc.messagePreviewProgress(m) : null;
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
        // Spinner over minithumb/soft path while focus/tap transfer is live.
        if (downloading) 'is_downloading': true,
        if (downloading && progress != null) 'download_progress': progress,
      },
    ];
  }

  Map<String, dynamic> _messageMetadata(TdlibMessage m) {
    if (m.isVoiceNote) {
      final durationMs = m.voiceDurationMs;
      final svc = ref.read(telegramTdlibServiceProvider);
      final transcript = svc.voiceTranscriptText(widget.chatId, m.id);
      final pending = svc.isVoiceTranscriptPending(widget.chatId, m.id);
      return {
        'source': 'telegram',
        'voice': {
          if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
          if (transcript != null && transcript.isNotEmpty)
            'transcript': transcript,
          if (pending)
            'transcript_status': 'pending'
          else if (transcript != null && transcript.isNotEmpty)
            'transcript_status': 'ready',
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
        _messagesForUi(svc).where((x) => x.id == id).firstOrNull;
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
    final messages = _messagesForUi(svc);
    _maybeReassertUnreadAfterHistoryGrowth(messages.length);
    _maybeArmLiveUnreadFromBuild(svc);
    final wallpaperId = ref.watch(chatWallpaperIdProvider);
    final title = svc.peerTitle(widget.chatId);
    final displayTitle = title == 'Telegram' ? widget.title : title;
    final avatarPath = svc.peerAvatarPath(widget.chatId);
    final status = svc.peerStatusSubtitle(widget.chatId);
    final isGroup = svc.isGroupChat(widget.chatId);
    final isChannel = svc.isChannelChat(widget.chatId);
    final isGroupLike = isGroup || isChannel;
    final chronologicalRows = _timelineCached(messages);
    final reversedRows = _reversedTimelineCached(messages);
    // Voice autoplay-next (same as FC): consecutive voices oldest→newest.
    // Attachment id must match ChatVoiceMessagePlayer (`fileId ?? message.id`).
    // Skip mid-fling — rebuilding the voice id list on every notify hitch.
    if (!_isUserActivelyScrolling) {
      ChatVoicePlaybackCoordinator.instance.syncFromVoiceAttachmentIds([
        for (final row in chronologicalRows)
          row.primary.isVoiceNote
              ? (row.primary.voiceFileId ?? row.primary.id)
              : null,
      ]);
    }
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
      // Always intercept: back must land on the chat list, not an
      // intermediate route (profile / previous chat / push stack).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelection();
          return;
        }
        _exitToChatList();
      },
      child: Scaffold(
        // Pad compose with viewInsets instead — resizing the whole Scaffold
        // rebuilt the tip list under IME (Valya + link-previews Davey ~10s).
        resizeToAvoidBottomInset: false,
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
                automaticallyImplyLeading: false,
                leading: IconButton(
                  tooltip: 'Назад',
                  onPressed: _exitToChatList,
                  icon: const Icon(LucideIcons.arrow_left),
                ),
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
                  if (_canStartFcCall)
                    IconButton(
                      tooltip: 'Звонок',
                      onPressed: _fcCallBusy
                          ? null
                          : () => unawaited(_startFcCall()),
                      icon: const Icon(LucideIcons.phone),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Ещё',
                    onSelected: (value) {
                      switch (value) {
                        case 'video':
                          unawaited(_startFcCall(isVideo: true));
                        case 'mute':
                          unawaited(_toggleNotifications());
                        case 'search':
                          unawaited(_openSearch());
                        case 'clear':
                          unawaited(_confirmClearHistory());
                        case 'delete_or_leave':
                          unawaited(_confirmDeleteOrLeave());
                      }
                    },
                    itemBuilder: (context) {
                      final muted = svc.isChatMuted(widget.chatId);
                      final isChannel = svc.isChannelChat(widget.chatId);
                      final isGroup = svc.isGroupChat(widget.chatId);
                      final leaveLabel = isChannel
                          ? 'Покинуть канал'
                          : isGroup
                              ? 'Выйти из группы'
                              : 'Удалить чат';
                      final leaveIcon = isChannel || isGroup
                          ? LucideIcons.log_out
                          : LucideIcons.trash;
                      return [
                        if (_canStartFcCall)
                          const PopupMenuItem(
                            value: 'video',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(LucideIcons.video),
                              title: Text('Видеозвонок'),
                            ),
                          ),
                        PopupMenuItem(
                          value: 'mute',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              muted ? LucideIcons.bell : LucideIcons.bell_off,
                            ),
                            title: Text(
                              muted
                                  ? 'Включить уведомления'
                                  : 'Выключить уведомления',
                            ),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'search',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(LucideIcons.search),
                            title: Text('Поиск'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'clear',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(LucideIcons.eraser),
                            title: Text('Очистить историю'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete_or_leave',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(leaveIcon),
                            title: Text(leaveLabel),
                          ),
                        ),
                      ];
                    },
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
                                child: ChatInlineVideoAutoplayScope(
                                  controller: _inlineVideoAutoplay,
                                  child: NotificationListener<ScrollNotification>(
                                  onNotification: (n) {
                                    if (n is ScrollUpdateNotification &&
                                        n.dragDetails != null) {
                                      _animatedMediaController.noteUserScroll();
                                      _inlineVideoAutoplay.noteScroll();
                                    } else if (n is ScrollEndNotification) {
                                      _animatedMediaController.noteScrollEnd();
                                      _inlineVideoAutoplay.noteScrollEnd();
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
                        padding: EdgeInsets.fromLTRB(4, 8, 4, 8 + composePad),
                        itemCount: reversedRows.length,
                        itemBuilder: (context, i) {
                          TgJankLog.itemBuilderTick();
                          final rowItem = reversedRows[i];
                          // Live paint data (reactions/paths) — timeline rows
                          // only hold structural ids to keep cache stable.
                          final m = _liveMessage(rowItem.primary, messagesById);
                          final created = m.date > 0
                              ? DateTime.fromMillisecondsSinceEpoch(
                                  m.date * 1000,
                                )
                              : null;
                          final prevRow = i + 1 < reversedRows.length
                              ? reversedRows[i + 1]
                              : null;
                          final nextRow = i > 0 ? reversedRows[i - 1] : null;
                          final prev = prevRow == null
                              ? null
                              : _liveMessage(prevRow.primary, messagesById);
                          final next = nextRow == null
                              ? null
                              : _liveMessage(nextRow.primary, messagesById);
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
                            messageId: m.id,
                            isMine: m.isOutgoing,
                            body: _bubbleBodyForRow(rowItem, messagesById),
                            textEntities:
                                _textEntitiesForRow(rowItem, messagesById),
                            attachments:
                                _attachmentsForRow(rowItem, messagesById),
                            messageMetadata:
                                _messageMetadataForRow(rowItem, messagesById),
                            showTelegramBadge: false,
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
                                gallery:
                                    _attachmentsForRow(rowItem, messagesById),
                              ),
                            ),
                            onOpenUrl: _handleOpenUrl,
                            showLinkPreview: _linkPreviewsEnabled,
                            canToggleVoiceTranscript: m.isVoiceNote &&
                                (svc.voiceTranscriptText(
                                          widget.chatId,
                                          m.id,
                                        ) ??
                                        '')
                                    .isNotEmpty,
                            voiceTranscriptBusy: m.isVoiceNote &&
                                svc.isVoiceTranscriptPending(
                                  widget.chatId,
                                  m.id,
                                ),
                            onRequestVoiceTranscript: m.isVoiceNote
                                ? () => unawaited(
                                      _requestVoiceTranscript(m),
                                    )
                                : null,
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
                      AnimatedPadding(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.viewInsetsOf(context).bottom,
                        ),
                        child: SafeArea(
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
