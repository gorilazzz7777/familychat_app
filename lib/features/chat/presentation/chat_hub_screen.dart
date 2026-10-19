import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_actions_scope.dart';
import '../../../app/shell_nav_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/settings/app_settings_controller.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/data/chat_offline_sync.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../data/chat_hub_folders.dart';
import '../data/chat_hub_folder_mirror_store.dart';
import '../data/chat_hub_last_message_time.dart';
import '../data/chat_hub_pin_storage.dart';
import '../data/chat_hub_tab_order_storage.dart';
import '../data/chat_local_reads.dart';
import '../data/chat_message_preview.dart';
import '../data/chat_realtime_utils.dart';
import '../data/familychat_realtime.dart';
import '../data/chat_sync_service.dart';
import '../data/hub_first_paint_snapshot.dart';
import '../data/hub_folder_mute.dart';
import '../data/hub_folder_mute_store.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/share/share_direct_target_service.dart';
import '../data/chat_local_mutations.dart';
import '../data/chat_mutation_coordinator.dart';
import '../data/chat_offline_outbox.dart';
import 'chat_conversation_screen.dart';
import 'chat_thread_avatars.dart';
import 'create_group_screen.dart';
import '../../telegram_tdlib/presentation/telegram_conversation_screen.dart';
import '../../telegram_tdlib/presentation/telegram_proxy_settings_screen.dart';
import '../../telegram_tdlib/tdlib_chat_folder.dart';
import '../../telegram_tdlib/telegram_group_bridge.dart';
import '../../telegram_tdlib/telegram_saved_bridge.dart';
import '../../telegram_tdlib/telegram_match_store.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';
import 'telegram_archive_screen.dart';
import 'telegram_chats_pane.dart';
import 'widgets/chat_message_read_status_icon.dart';

class ChatHubScreen extends ConsumerStatefulWidget {
  const ChatHubScreen({
    super.key,
    this.hasIndividualPremium = false,
    this.telegramConnected = false,
    this.telegramGrace = false,
    this.profileName = '',
    this.profileAvatarUrl = '',
    this.profileAvatarLocalPath = '',
    this.onProfileTap,
  });

  /// Enables TG hub features (folder when disconnected, rows in «Все»).
  /// Always true from shell — TG is available to all users.
  final bool hasIndividualPremium;
  /// TDLib authorization ready (logged in). When true, «Telegram» folder is hidden.
  final bool telegramConnected;
  /// Grace / read-only TG mode from backend status.
  final bool telegramGrace;
  final String profileName;
  final String profileAvatarUrl;
  /// Cold-start local copy of profile avatar (hub snapshot).
  final String profileAvatarLocalPath;
  final VoidCallback? onProfileTap;

  @override
  ConsumerState<ChatHubScreen> createState() => ChatHubScreenState();
}

class ChatHubScreenState extends ConsumerState<ChatHubScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// System chips: «Telegram» while TDLib is not logged in.
  static List<HubChip> _systemChipsFor({
    required bool hasIndividualPremium,
    required bool telegramConnected,
  }) {
    return [
      const HubChip.system(ChatHubSystemFilter.all),
      const HubChip.system(ChatHubSystemFilter.family),
      if (hasIndividualPremium && !telegramConnected)
        const HubChip.system(ChatHubSystemFilter.telegram),
    ];
  }

  late TabController _tabController;
  late List<HubChip> _chips;
  List<ChatFolderData> _customFolders = [];
  Map<int, int> _fcToTgFolder = {};
  Map<int, Set<String>> _tgFolderExtras = {};
  int _lastTgFoldersEpoch = -1;
  /// Live `getChatFolders` applied at least once this session (may be empty).
  bool _tgFoldersLiveOnce = false;
  Timer? _folderMuteReconcileTimer;
  int _folderMuteUiEpoch = 0;
  List<Map<String, dynamic>> _threads = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  Map<int, TelegramMatch> _tdlibMatches = {};
  bool _loading = true;
  bool _hubBootstrapDone = false;
  /// Hold first paint until FC folders + TG list/folders/matches are ready.
  bool _pendingFirstPaint = false;
  bool _fcFoldersLoaded = false;
  bool _tdlibMatchesLoaded = false;
  bool _mirrorStateLoaded = false;
  Timer? _tdlibRevealTimeout;
  bool _lastKnownOnline = true;
  bool _searchVisible = false;
  bool _folderReorderMode = false;
  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};
  final Map<String, Map<String, dynamic>> _selectedRows = {};
  /// Hub row keys (`t:…` / `tg:…`) pinned to the top, order preserved.
  List<String> _pinnedOrder = [];
  String _searchQuery = '';
  final _searchController = TextEditingController();
  /// Global TG search (debounced) while the hub search field is open.
  Timer? _tgSearchDebounce;
  int _tgSearchSeq = 0;
  bool _tgSearchLoading = false;
  List<TdlibGlobalSearchHit> _tgSearchHits = const [];
  StreamSubscription<List<Map<String, dynamic>>>? _threadsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _membersSub;
  int _threadsEnrichGen = 0;
  bool get _localFirst => ChatSyncService.isSupported;
  Timer? _hubAvatarPrefetchTimer;
  Timer? _hubScrollBusyClearTimer;
  Timer? _snapshotPersistTimer;
  String? _lastHubAvatarPrefetchKey;
  /// Approximate scroll offset of the active hub ListView (for viewport prefetch).
  double _hubListScrollPixels = 0;
  /// TG synthetics from last-session snapshot until live TDLib hub is ready.
  List<Map<String, dynamic>> _snapshotTgRows = const [];
  /// Archived TG synthetics from the same hub SQLite snapshot (cold Archive).
  List<Map<String, dynamic>> _snapshotArchiveRows = const [];
  /// First frame came from [HubFirstPaintSnapshot] (skip skeleton / gates).
  bool _paintedFromSnapshot = false;
  /// Hold sharp-avatar prefetch so cold-start path swaps don't flash tiles.
  DateTime? _hubAvatarPrefetchAfter;
  /// Suppress noisy setState while frozen snapshot is on screen awaiting TG.
  bool _coldStartCoalesce = false;
  /// Matched FC+TG DMs: tip from last-session snapshot / live TG enrich.
  /// Survives SQLite watch replace (FC tip is often stale; activity lives on TG).
  final Map<int, Map<String, dynamic>> _matchedFcSnapTips = {};

  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchQuery = '';
        _searchController.clear();
        _clearTgGlobalSearch();
      }
    });
  }

  void _clearTgGlobalSearch() {
    _tgSearchDebounce?.cancel();
    _tgSearchDebounce = null;
    _tgSearchSeq++;
    _tgSearchLoading = false;
    _tgSearchHits = const [];
  }

  void _onHubSearchChanged(String value) {
    setState(() => _searchQuery = value);
    _scheduleTgGlobalSearch(value);
  }

  void _scheduleTgGlobalSearch(String value) {
    _tgSearchDebounce?.cancel();
    if (!widget.hasIndividualPremium || !_tdlibReady) {
      if (_tgSearchHits.isNotEmpty || _tgSearchLoading) {
        setState(() {
          _tgSearchHits = const [];
          _tgSearchLoading = false;
        });
      }
      return;
    }
    final raw = value.trim();
    final hasAt = raw.startsWith('@');
    final token = raw.replaceFirst(RegExp(r'^@+'), '').trim();
    final tooShort = hasAt ? token.isEmpty : token.length < 2;
    if (tooShort) {
      if (_tgSearchHits.isNotEmpty || _tgSearchLoading) {
        setState(() {
          _tgSearchHits = const [];
          _tgSearchLoading = false;
        });
      }
      return;
    }
    final seq = ++_tgSearchSeq;
    setState(() => _tgSearchLoading = true);
    _tgSearchDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_runTgGlobalSearch(raw, seq));
    });
  }

  Future<void> _runTgGlobalSearch(String query, int seq) async {
    final svc = ref.read(telegramTdlibServiceProvider);
    List<TdlibGlobalSearchHit> hits = const [];
    try {
      hits = await svc.searchTelegramGlobal(query);
    } catch (e) {
      debugPrint('[hub] tg global search failed: $e');
    }
    if (!mounted || seq != _tgSearchSeq) return;
    setState(() {
      _tgSearchHits = hits;
      _tgSearchLoading = false;
    });
    _scheduleTgSearchAvatarPrefetch(hits);
  }

  /// Sharp avatars for global TG search rows (same hub-avatar budget as list).
  void _scheduleTgSearchAvatarPrefetch(List<TdlibGlobalSearchHit> hits) {
    if (hits.isEmpty) return;
    if (!widget.hasIndividualPremium || !_tdlibReady) return;
    final ids = <int>[
      for (final h in hits)
        if (h.chatId != 0) h.chatId,
    ];
    if (ids.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tdlib = ref.read(telegramTdlibServiceProvider);
      if (tdlib.isUiScrollBusy) {
        _hubAvatarPrefetchTimer?.cancel();
        _hubAvatarPrefetchTimer = Timer(const Duration(milliseconds: 420), () {
          if (!mounted) return;
          _scheduleTgSearchAvatarPrefetch(hits);
        });
        return;
      }
      tdlib.prefetchVisibleHubAvatars(ids);
    });
  }

  Set<int> _tdlibChatIdsInRows(Iterable<Map<String, dynamic>> rows) {
    final out = <int>{};
    for (final t in rows) {
      final top = (t['tdlib_chat_id'] as num?)?.toInt();
      if (top != null && top != 0) out.add(top);
      final tg = t['telegram'];
      if (tg is Map && tg['linked'] == true) {
        final id = (tg['tg_chat_id'] as num?)?.toInt() ??
            int.tryParse('${tg['tg_chat_id'] ?? ''}');
        if (id != null && id != 0) out.add(id);
      }
    }
    return out;
  }

  List<TdlibGlobalSearchHit> _tgHitsNotInLocal(
    List<Map<String, dynamic>> localRows,
  ) {
    final known = _tdlibChatIdsInRows(localRows);
    return [
      for (final h in _tgSearchHits)
        if (!known.contains(h.chatId)) h,
    ];
  }

  Future<void> _openTgGlobalHit(TdlibGlobalSearchHit hit) async {
    await _openThread({
      'id': -hit.chatId.abs(),
      'kind': 'tdlib_chat',
      'title': hit.title,
      'tdlib_chat_id': hit.chatId,
      if (hit.userId > 0 && !hit.isGroup && !hit.isChannel)
        'tdlib_user_id': hit.userId,
      'tdlib_photo_path': hit.photoLocalPath,
      'tdlib_photo_bytes': hit.photoMinithumbnailBytes,
      'tdlib_photo_file_id': hit.photoFileId,
      'unread_count': 0,
      'last_message': {
        'body': hit.subtitle,
      },
    });
  }

  Widget _tgGlobalSearchHeader(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'Telegram',
        style: theme.textTheme.titleSmall?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _tgGlobalSearchTile(
    TdlibGlobalSearchHit hit, {
    required ThemeData theme,
    required ColorScheme scheme,
  }) {
    // Live path: search hit is a snapshot; hub-avatar download updates cache.
    final live = ref.read(telegramTdlibServiceProvider).chatPreviewById(hit.chatId);
    final path = (live?.photoLocalPath?.trim().isNotEmpty == true)
        ? live!.photoLocalPath
        : hit.photoLocalPath;
    final mini = (live?.photoMinithumbnailBytes != null &&
            live!.photoMinithumbnailBytes!.isNotEmpty)
        ? live.photoMinithumbnailBytes
        : hit.photoMinithumbnailBytes;
    return ListTile(
      leading: ChatAvatar(
        key: ValueKey<String>('tg-search-av-${hit.chatId}-${path ?? ''}'),
        name: hit.title,
        localFilePath: path,
        memoryBytes: mini,
        radius: 24,
      ),
      title: Text(
        hit.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        hit.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      onTap: () => unawaited(_openTgGlobalHit(hit)),
    );
  }

  /// Обновить список чатов (например при возврате на вкладку).
  Future<void> refresh({bool silent = true}) async {
    unawaited(_loadCustomFolders());
    if (_localFirst) {
      final repo = ref.read(familychatRepositoryProvider);
      // Shell resume already ran one catch-up (reconnect + open thread).
      if (!ChatSyncService.instance.resumeCatchUpFresh) {
        await ChatSyncService.instance.syncHub(
          prefetchMessages: false,
          force: true,
        );
      }
      unawaited(ChatOfflineSync.instance.run(repo));
      return;
    }
    await _load(silent: silent);
  }

  /// Native: re-read hub rows from SQLite (e.g. after app resume).
  Future<void> _refreshFromLocalStore() async {
    if (!_localFirst) return;
    final threads = await ChatLocalReads.threads();
    await _onThreadsUpdated(threads);
    final members = await ChatLocalReads.members();
    if (!mounted || members.isEmpty) return;
    setState(() => _applyMembers(members));
  }

  @override
  void initState() {
    super.initState();
    // Frame-0: full FC from SQLite warm + TG from last-session snapshot.
    final warmFc = HubFirstPaintSnapshot.warmedFcThreads;
    final warm = HubFirstPaintSnapshot.warmed;
    final warmFolders = HubFirstPaintSnapshot.warmedFolders;
    if (warmFolders != null && warmFolders.isNotEmpty) {
      _customFolders = warmFolders.map(ChatFolderData.fromJson).toList();
      _fcFoldersLoaded = true;
    }
    if ((warmFc != null && warmFc.isNotEmpty) ||
        (warm != null && warm.rows.isNotEmpty)) {
      _applyColdStartPaint(
        fcThreads: warmFc,
        snapshot: warm,
        notify: false,
      );
    } else {
      // No warm snapshot: show FC ASAP; TG rows arrive via incremental hydrate.
      _pendingFirstPaint = false;
      _fcFoldersLoaded = true;
      _tdlibMatchesLoaded = true;
      _mirrorStateLoaded = true;
    }
    // Still async-hydrate in case warm missed (bootstrap race).
    unawaited(_hydrateFromSnapshot());
    unawaited(_reloadTdlibMatches());
    TelegramMatchStore.instance.revision.addListener(_onTdlibMatchesChanged);
    // Cold-start: paint hub from SQLite first; start TDLib after 2 frames so
    // params/proxy CPU does not compete with first list layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(ref.read(telegramTdlibServiceProvider).ensureStarted());
        unawaited(
          ref.read(telegramTdlibServiceProvider).reconcileFamilyIdentities(),
        );
      });
    });
    WidgetsBinding.instance.addObserver(this);
    unawaited(HubFolderMuteStore.ensureLoaded().then((_) {
      if (!mounted) return;
      setState(() => _folderMuteUiEpoch++);
      _armFolderMuteReconcileTimer();
      unawaited(_reconcileAllFolderMutes());
    }));
    final baseChips = _systemChipsFor(
      hasIndividualPremium: widget.hasIndividualPremium,
      // Phase may already be ready from a previous session.
      telegramConnected: widget.telegramConnected ||
          ref.read(telegramTdlibServiceProvider).phase == TdlibAuthPhase.ready,
    );
    // Frame-0: restore full chip bar (FC + TG folders) from last session.
    final warmChips = HubFirstPaintSnapshot.chipsFromWarm();
    _chips = warmChips.isNotEmpty
        ? warmChips
        : (_customFolders.isNotEmpty
            ? _composeChips(orderKeys: baseChips.map((c) => c.key).toList())
            : baseChips);
    _tabController = TabController(length: _chips.length, vsync: this);
    _tabController.addListener(_onFilterTabChanged);
    FamilyChatRealtime.instance.addListener(_onRealtime);
    ChatOfflineSync.instance.addListener(_onOfflineSync);
    _lastKnownOnline = ChatOfflineSync.instance.isOnline;
    unawaited(_restoreTabOrder());
    unawaited(_restorePinnedOrder());
    unawaited(_loadMirrorState());
    unawaited(_loadCustomFolders());
    if (_localFirst) {
      _bindLocalStore();
      unawaited(_bootstrapLocalHub());
    } else {
      _load();
    }
  }

  void _applyColdStartPaint({
    List<Map<String, dynamic>>? fcThreads,
    HubFirstPaintData? snapshot,
    required bool notify,
  }) {
    final fc = <Map<String, dynamic>>[];
    final tg = <Map<String, dynamic>>[];
    final archive = <Map<String, dynamic>>[];
    if (fcThreads != null && fcThreads.isNotEmpty) {
      for (final row in fcThreads) {
        fc.add(Map<String, dynamic>.from(row));
      }
    }
    if (snapshot != null) {
      final snapFcById = <int, Map<String, dynamic>>{};
      if (widget.hasIndividualPremium) {
        final split = HubFirstPaintSnapshot.splitTgRows(snapshot.rows);
        tg.addAll(split.main);
        archive.addAll(split.archive);
      }
      for (final row in snapshot.rows) {
        final kind = row['kind']?.toString() ?? '';
        if (kind == 'tdlib_dm' ||
            kind == 'tdlib_chat' ||
            kind == 'tdlib_archive_chat' ||
            kind == 'tdlib_archive') {
          continue;
        }
        final id = chatAsInt(row['id']);
        if (id != null) snapFcById[id] = row;
        if (fc.isEmpty) {
          // SQLite miss — fall back to snapshot FC rows.
          final copy = Map<String, dynamic>.from(row);
          fc.add(copy);
          final sid = chatAsInt(copy['id']);
          if (sid != null) _rememberMatchedFcTip(sid, copy);
        }
      }
      // Overlay snapshot last_message onto SQLite FC when snap tip is fresher
      // (matched FC+TG like Киса: FC tip stale, real activity on TG / snap).
      if (fc.isNotEmpty && snapFcById.isNotEmpty) {
        for (var i = 0; i < fc.length; i++) {
          final id = chatAsInt(fc[i]['id']);
          if (id == null) continue;
          final snap = snapFcById[id];
          if (snap == null) continue;
          final snapLast = snap['last_message'];
          if (snapLast is! Map) continue;
          final applied = _applyFresherLastMessage(
            fc[i],
            Map<String, dynamic>.from(snapLast),
          );
          if (applied != null) {
            fc[i] = applied;
            _rememberMatchedFcTip(id, fc[i]);
          } else if (_isLinkedFcDm(fc[i])) {
            final cur = fc[i]['last_message'];
            if (cur is Map) {
              _matchedFcSnapTips[id] = Map<String, dynamic>.from(cur);
            }
          }
        }
      }
    }
    if (fc.isEmpty && tg.isEmpty && archive.isEmpty) return;
    // TG-style: never hold the whole hub for hydrate — paint snapshot now;
    // live rows replace incrementally as loadChats pages land.
    _tdlibRevealTimeout?.cancel();
    _tdlibRevealTimeout = null;
    void apply() {
      if (fc.isNotEmpty) {
        _threads = _sortedThreads(fc);
      }
      _snapshotTgRows = tg;
      _snapshotArchiveRows = archive;
      _paintedFromSnapshot = true;
      _loading = false;
      _pendingFirstPaint = false;
      _coldStartCoalesce = false;
      _fcFoldersLoaded = true;
      _tdlibMatchesLoaded = true;
      _mirrorStateLoaded = true;
      _hubAvatarPrefetchAfter =
          DateTime.now().add(const Duration(milliseconds: 1200));
    }

    if (notify && mounted) {
      setState(apply);
    } else {
      apply();
    }
    if (fc.isNotEmpty) {
      unawaited(_seedMatchesFromFcThreads(fc));
      unawaited(_persistMatchedFcTipsToSqlite(fc));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastHubAvatarPrefetchKey = null;
      _debounceHubAvatarPrefetch(_filteredBy(_selectedChip));
    });
  }

  List<Map<String, dynamic>> _tgRowsFromSnapshot(HubFirstPaintData? data) {
    if (data == null || data.rows.isEmpty) return const [];
    return HubFirstPaintSnapshot.splitTgRows(data.rows).main;
  }

  List<Map<String, dynamic>> _archiveRowsFromSnapshot(HubFirstPaintData? data) {
    if (data == null || data.rows.isEmpty) return const [];
    return HubFirstPaintSnapshot.splitTgRows(data.rows).archive;
  }

  /// Cold start: paint last-session hub (FC+TG) without waiting for TDLib.
  ///
  /// Frame-0 may paint FC-only when [warmWithBudget] returns before the
  /// hub snapshot is loaded — still merge TG when warm finishes.
  Future<void> _hydrateFromSnapshot() async {
    await HubFirstPaintSnapshot.warm();
    if (!mounted) return;
    final fc = HubFirstPaintSnapshot.warmedFcThreads;
    final data =
        HubFirstPaintSnapshot.warmed ?? await HubFirstPaintSnapshot.read();
    if (!mounted) return;
    if (_paintedFromSnapshot) {
      // FC already on screen; fill missing TG overlay from durable snapshot.
      if (!widget.hasIndividualPremium) return;
      if (_liveTgListReady()) return;
      final tg = _tgRowsFromSnapshot(data);
      final archive = _archiveRowsFromSnapshot(data);
      if (_snapshotTgRows.isNotEmpty && _snapshotArchiveRows.isNotEmpty) {
        return;
      }
      if (tg.isEmpty && archive.isEmpty) return;
      setState(() {
        if (_snapshotTgRows.isEmpty && tg.isNotEmpty) {
          _snapshotTgRows = tg;
        }
        if (_snapshotArchiveRows.isEmpty && archive.isNotEmpty) {
          _snapshotArchiveRows = archive;
        }
        _pendingFirstPaint = false;
        _coldStartCoalesce = false;
      });
      return;
    }
    if ((fc == null || fc.isEmpty) && (data == null || data.rows.isEmpty)) {
      return;
    }
    _applyColdStartPaint(fcThreads: fc, snapshot: data, notify: true);
  }

  /// Live TG rows may merge into the hub (TG incremental after first page).
  ///
  /// Empty chatOrder after soft-restart keeps the snapshot until the first
  /// loadChats page promotes [TelegramTdlibService.hubSurfaceReady].
  bool _liveTgListReady([TelegramTdlibService? tdlib]) {
    if (!widget.hasIndividualPremium) return true;
    final TelegramTdlibService svc =
        tdlib ?? ref.read(telegramTdlibServiceProvider);
    return svc.hubSurfaceReady || svc.hubHasLiveChats;
  }

  /// Drop frozen TG overlay once live hub list is actually populated.
  void _releaseSnapshotOverlayIfReady([TelegramTdlibService? tdlib]) {
    if (!_paintedFromSnapshot || !mounted) return;
    if (!_liveTgListReady(tdlib)) return;
    // One-shot: mark not painted so we don't re-enter while hydrating.
    _paintedFromSnapshot = false;
    unawaited(_releaseSnapshotOverlayBody());
  }

  Future<void> _releaseSnapshotOverlayBody() async {
    if (!mounted) return;
    try {
      if (_threads.isNotEmpty) {
        final hydrated =
            await HubFirstPaintSnapshot.hydrateFcThreadsLastMessages(_threads);
        // hydrate fills empty-body tips from FC messages — don't let that
        // demote a matched snap/TG tip (Киса).
        _threads = _sortedThreads(_mergeIncomingKeepFresherTips(hydrated));
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      // Keep [_snapshotTgRows] as soft-restart fallback — merge only uses
      // them while live TG list is empty / not ready.
      _pendingFirstPaint = false;
      _coldStartCoalesce = false;
      _hubAvatarPrefetchAfter =
          DateTime.now().add(const Duration(milliseconds: 1200));
    });
    unawaited(_persistMatchedFcTipsToSqlite(_threads));
    _scheduleSnapshotPersist();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastHubAvatarPrefetchKey = null;
      _debounceHubAvatarPrefetch(_filteredBy(_selectedChip));
    });
  }

  /// Soft-restart / missed warm: re-read last-session TG rows so the hub
  /// does not sit on FC-only while loadChats runs.
  Future<void> _restoreSnapshotTgFallbackIfNeeded([
    TelegramTdlibService? tdlib,
  ]) async {
    if (!widget.hasIndividualPremium || !mounted) return;
    if (_liveTgListReady(tdlib)) return;
    if (_snapshotTgRows.isNotEmpty) return;
    final data =
        HubFirstPaintSnapshot.warmed ?? await HubFirstPaintSnapshot.read();
    if (!mounted || data == null || data.rows.isEmpty) return;
    if (_liveTgListReady(tdlib)) return;
    final tg = _tgRowsFromSnapshot(data);
    final archive = _archiveRowsFromSnapshot(data);
    if ((tg.isEmpty && archive.isEmpty) || !mounted) return;
    if (_liveTgListReady(tdlib)) return;
    setState(() {
      if (_snapshotTgRows.isEmpty && tg.isNotEmpty) {
        _snapshotTgRows = tg;
      }
      if (_snapshotArchiveRows.isEmpty && archive.isNotEmpty) {
        _snapshotArchiveRows = archive;
      }
    });
  }

  /// Skeleton only when we have nothing durable to show yet.
  bool get _showHubSkeleton =>
      (_loading || _pendingFirstPaint) && !_paintedFromSnapshot;

  /// Reveal FC+TG hub in one paint: sync folder chips, then drop the skeleton.
  void _forceFirstPaintReveal() {
    if (!mounted || !_pendingFirstPaint) return;
    _fcFoldersLoaded = true;
    _tdlibMatchesLoaded = true;
    _mirrorStateLoaded = true;
    _applyFirstPaintReveal();
  }

  void _tryFirstPaintReveal([TelegramTdlibService? tdlib]) {
    if (!_pendingFirstPaint || !mounted) return;
    if (_loading) return;
    if (!_fcFoldersLoaded || !_tdlibMatchesLoaded || !_mirrorStateLoaded) {
      return;
    }

    // Snapshot already painted — reveal chrome without waiting full hydrate.
    // Live merge still gated by [_liveTgListReady] in [_hubMergedThreads].
    if (_paintedFromSnapshot || _liveTgListReady(tdlib)) {
      _applyFirstPaintReveal();
    }
  }

  void _applyFirstPaintReveal() {
    if (!mounted || !_pendingFirstPaint) return;
    _tdlibRevealTimeout?.cancel();
    _tdlibRevealTimeout = null;
    final svc = ref.read(telegramTdlibServiceProvider);
    _lastTgFoldersEpoch = svc.chatFoldersEpoch;
    if (svc.phase == TdlibAuthPhase.ready &&
        svc.manualChatFolders.isNotEmpty) {
      _tgFoldersLiveOnce = true;
    }
    final next = _composeChips(orderKeys: _chips.map((c) => c.key).toList());
    final selected = _selectedChip;
    final same = next.length == _chips.length &&
        List.generate(next.length, (i) => next[i] == _chips[i])
            .every((ok) => ok);
    if (same) {
      setState(() {
        _pendingFirstPaint = false;
        _coldStartCoalesce = false;
        // Keep snapshot TG rows for soft-restart fallback (see merge).
        _paintedFromSnapshot = false;
        _hubAvatarPrefetchAfter =
            DateTime.now().add(const Duration(milliseconds: 1200));
      });
      unawaited(_pullMirroredMembershipFromTg());
      // Hub history warm stays off (warmHubChatLimit=0) — FakeTLS slot.
      // First paint: force avatar prefetch (key gate may have armed with
      // need=0 before TG rows existed).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastHubAvatarPrefetchKey = null;
        _debounceHubAvatarPrefetch(
          _filteredBy(_selectedChip),
        );
      });
      _scheduleSnapshotPersist();
      return;
    }
    final oldController = _tabController;
    oldController.removeListener(_onFilterTabChanged);
    final allChip = const HubChip.system(ChatHubSystemFilter.all);
    final initialIndex = next.contains(selected)
        ? next.indexOf(selected)
        : (next.contains(allChip) ? next.indexOf(allChip) : 0);
    final newController = TabController(
      length: next.length,
      vsync: this,
      initialIndex: initialIndex.clamp(0, next.isEmpty ? 0 : next.length - 1),
    );
    newController.addListener(_onFilterTabChanged);
    setState(() {
      _pendingFirstPaint = false;
      _coldStartCoalesce = false;
      // Keep snapshot TG rows for soft-restart fallback (see merge).
      _paintedFromSnapshot = false;
      _hubAvatarPrefetchAfter =
          DateTime.now().add(const Duration(milliseconds: 1200));
      _chips = next;
      _tabController = newController;
    });
    oldController.dispose();
    unawaited(_pullMirroredMembershipFromTg());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastHubAvatarPrefetchKey = null;
      _debounceHubAvatarPrefetch(_filteredBy(_selectedChip));
    });
    _scheduleSnapshotPersist();
  }

  Future<void> _reloadTdlibMatches() async {
    final matches = await TelegramMatchStore.instance.loadAll();
    if (!mounted) return;
    setState(() {
      _tdlibMatches = matches;
      _tdlibMatchesLoaded = true;
    });
    unawaited(
      ref.read(telegramTdlibServiceProvider).refreshMatchedTgUserIds(),
    );
    _tryFirstPaintReveal();
  }

  void _onTdlibMatchesChanged() {
    unawaited(_reloadTdlibMatches());
  }

  List<Map<String, dynamic>> _tdlibHubEntries() {
    if (!widget.hasIndividualPremium) return const [];
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase != TdlibAuthPhase.ready) return const [];
    final byUser = {
      for (final c in svc.privateChats) c.userId: c,
    };
    final out = <Map<String, dynamic>>[];
    for (final m in _tdlibMatches.values) {
      final preview = byUser[m.tgUserId];
      final created = preview != null && preview.lastMessageDate > 0
          ? DateTime.fromMillisecondsSinceEpoch(preview.lastMessageDate * 1000)
              .toIso8601String()
          : null;
      final member = _memberByUserId[m.fcUserId];
      final memberName = member?['display_name']?.toString().trim() ?? '';
      final memberAvatar = member?['avatar_url']?.toString().trim() ?? '';
      final title = memberName.isNotEmpty
          ? memberName
          : (m.displayName.isNotEmpty
              ? m.displayName
              : (preview?.title ?? 'Telegram'));
      final avatar = memberAvatar.isNotEmpty
          ? memberAvatar
          : (m.avatarUrl.isNotEmpty ? m.avatarUrl : '');
      out.add({
        'id': -m.tgChatId.abs(),
        'kind': 'tdlib_dm',
        'title': title,
        'peer_user_id': m.fcUserId,
        'peer_avatar_url': avatar,
        'tdlib_chat_id': m.tgChatId,
        'tdlib_user_id': m.tgUserId,
        // Only when FC has no photo — ChatAvatar prefers local over URL.
        if (memberAvatar.isEmpty) ...{
          'tdlib_photo_path': preview?.photoLocalPath,
          'tdlib_photo_bytes': preview?.photoMinithumbnailBytes,
          'tdlib_photo_file_id': preview?.photoFileId,
        },
        'telegram': {'linked': true},
        'notifications_enabled': !svc.isChatMuted(m.tgChatId),
        'unread_count': preview?.unreadCount ?? 0,
        'last_message': {
          'body': preview?.lastMessageText ?? '',
          if (created != null) 'created_at': created,
          if (preview?.lastMessageReadStatus != null)
            'read_status': preview!.lastMessageReadStatus,
          if (preview?.lastMessageOutgoing == true) 'is_mine': true,
        },
      });
    }
    return out;
  }

  /// TG rows for «Все»: same membership as [TelegramChatsPane]
  /// (groups + unmatched privates). Matched privates stay as
  /// FC DM / synthetic [tdlib_dm] and are excluded here to avoid dupes.
  /// Linked dual FC↔TG groups are also excluded (shown as one FC group).
  List<Map<String, dynamic>> _telegramListEntries() {
    if (!widget.hasIndividualPremium) return const [];
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase != TdlibAuthPhase.ready) return const [];
    final linkedTgChatIds = _fcLinkedTgChatIds();
    final out = <Map<String, dynamic>>[];
    for (final c in svc.hubChats) {
      // Same gate as TelegramChatsPane: groups/channels always; privates only
      // if unmatched. (Channels have isGroup=false — must not use !isGroup alone.)
      final isPrivate = !c.isGroup && !c.isChannel;
      if (isPrivate && _tdlibMatches.containsKey(c.userId)) continue;
      if (linkedTgChatIds.contains(c.chatId)) continue;
      if (_matchedTgChatIds.contains(c.chatId)) continue;
      if (svc.isSavedMessagesChat(c.chatId)) continue;
      final created = c.lastMessageDate > 0
          ? DateTime.fromMillisecondsSinceEpoch(c.lastMessageDate * 1000)
              .toIso8601String()
          : null;
      out.add({
        'id': -c.chatId.abs(),
        'kind': 'tdlib_chat',
        'title': c.title,
        'tdlib_chat_id': c.chatId,
        if (!c.isGroup && !c.isChannel) 'tdlib_user_id': c.userId,
        'tdlib_photo_path': c.photoLocalPath,
        'tdlib_photo_bytes': c.photoMinithumbnailBytes,
        'tdlib_photo_file_id': c.photoFileId,
        'notifications_enabled': !svc.isChatMuted(c.chatId),
        'unread_count': c.unreadCount,
        'last_message': {
          'body': c.lastMessageText,
          if (created != null) 'created_at': created,
          if (c.lastMessageReadStatus != null)
            'read_status': c.lastMessageReadStatus,
          if (c.lastMessageOutgoing) 'is_mine': true,
        },
      });
    }
    return out;
  }

  Set<int> _fcLinkedTgChatIds() {
    final out = <int>{};
    for (final t in _threads) {
      final kind = t['kind']?.toString() ?? '';
      // Groups + DMs that the server already linked to a TG chat must not
      // also appear as a raw TDLib row (Киса: FC dm + tdlib_chat split).
      if (kind != 'group' &&
          kind != 'dm' &&
          kind != 'friend_dm' &&
          kind != 'saved') {
        continue;
      }
      final tg = t['telegram'];
      if (tg is! Map || tg['linked'] != true) continue;
      final id = (tg['tg_chat_id'] as num?)?.toInt() ??
          int.tryParse('${tg['tg_chat_id'] ?? ''}');
      if (id != null && id != 0) out.add(id);
    }
    return out;
  }

  bool _isTdlibHubKind(String? kind) =>
      kind == 'tdlib_dm' || kind == 'tdlib_chat';

  Future<void> _bootstrapLocalHub() async {
    final db = await ChatLocalStore.instance.ensureOpen();
    if (!mounted) return;
    if (db == null) {
      _hubBootstrapDone = true;
      await _load(silent: false);
      return;
    }
    // Paint SQLite first — do not await network sync before first frame.
    final localThreads = await ChatLocalReads.threads();
    if (!mounted) return;
    _hubBootstrapDone = true;
    if (localThreads.isNotEmpty) {
      await _onThreadsUpdated(localThreads);
    } else if (_paintedFromSnapshot) {
      if (_loading) setState(() => _loading = false);
      _tryFirstPaintReveal();
    }
    final members = await ChatLocalReads.members();
    if (mounted && members.isNotEmpty) {
      setState(() => _applyMembers(members));
    }

    // List/members only — message windows are deferred in ChatSyncService
    // (parallel syncThread during TDLib hydrate froze the first ~10s).
    unawaited(() async {
      await ChatSyncService.instance.syncHub(
        prefetchMessages: false,
        force: true,
      );
      if (!mounted) return;
      final repo = ref.read(familychatRepositoryProvider);
      unawaited(ChatOfflineSync.instance.run(repo));
      final threads = await ChatLocalReads.threads();
      if (!mounted) return;
      await _onThreadsUpdated(threads);
      if (!mounted) return;
      if (_loading) setState(() => _loading = false);
      _tryFirstPaintReveal();
    }());
  }

  @override
  void didUpdateWidget(covariant ChatHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hasIndividualPremium != widget.hasIndividualPremium ||
        oldWidget.telegramConnected != widget.telegramConnected) {
      if (widget.hasIndividualPremium && !oldWidget.hasIndividualPremium) {
        _pendingFirstPaint = true;
        _fcFoldersLoaded = false;
        _tdlibMatchesLoaded = false;
        _mirrorStateLoaded = false;
        _tdlibRevealTimeout?.cancel();
        _tdlibRevealTimeout = Timer(const Duration(seconds: 12), () {
          if (!mounted || !_pendingFirstPaint) return;
          _forceFirstPaintReveal();
        });
        unawaited(_reloadTdlibMatches());
        unawaited(_loadMirrorState());
        unawaited(_loadCustomFolders());
      } else if (!widget.hasIndividualPremium) {
        _pendingFirstPaint = false;
        _fcFoldersLoaded = true;
        _tdlibMatchesLoaded = true;
        _mirrorStateLoaded = true;
      }
      _syncFiltersWithPremium();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    TelegramMatchStore.instance.revision.removeListener(_onTdlibMatchesChanged);
    _hubAvatarPrefetchTimer?.cancel();
    _hubScrollBusyClearTimer?.cancel();
    _snapshotPersistTimer?.cancel();
    _folderMuteReconcileTimer?.cancel();
    _tgSearchDebounce?.cancel();
    // Do not drop a pending debounce — flush so kill/close keeps the list.
    unawaited(_persistHubSnapshot());
    _tdlibRevealTimeout?.cancel();
    ref.read(telegramTdlibServiceProvider).setUiScrollBusy(false);
    _tabController.dispose();
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    ChatOfflineSync.instance.removeListener(_onOfflineSync);
    unawaited(_threadsSub?.cancel() ?? Future<void>.value());
    unawaited(_membersSub?.cancel() ?? Future<void>.value());
    _searchController.dispose();
    super.dispose();
  }

  /// Live TDLib auth — prefer over [widget.telegramConnected] so the Telegram
  /// folder hides as soon as phase becomes ready (prop can lag one frame).
  bool get _tdlibReady =>
      ref.read(telegramTdlibServiceProvider).phase == TdlibAuthPhase.ready;

  void _syncFiltersWithPremium() {
    _rebuildChips(preferSelected: _selectedChip);
  }

  HubChip get _selectedChip {
    final idx = _tabController.index;
    if (idx >= 0 && idx < _chips.length) return _chips[idx];
    return const HubChip.system(ChatHubSystemFilter.all);
  }

  /// TG folder chips from last session (RAM warm or current bar).
  List<HubChip> _cachedTelegramFolderChips() {
    if (!widget.hasIndividualPremium) return const [];
    final fromBar = [
      for (final c in _chips)
        if (c.tgFolderId != null) c,
    ];
    if (fromBar.isNotEmpty) return fromBar;
    return [
      for (final c in HubFirstPaintSnapshot.chipsFromWarm())
        if (c.tgFolderId != null) c,
    ];
  }

  List<HubChip> _composeChips({List<String>? orderKeys}) {
    final cachedTg = _cachedTelegramFolderChips();
    // Last session had TG folders — do not flash the lone «Telegram» chip
    // while TDLib is still starting (reveal used to strip warm folders).
    final telegramConnected = _tdlibReady ||
        widget.telegramConnected ||
        cachedTg.isNotEmpty;
    final system = _systemChipsFor(
      hasIndividualPremium: widget.hasIndividualPremium,
      telegramConnected: telegramConnected,
    );
    final mirroredTgIds = _fcToTgFolder.values.toSet();
    final liveFolders = _tdlibReady && widget.hasIndividualPremium
        ? ref.read(telegramTdlibServiceProvider).manualChatFolders
        : const <TdlibChatFolderInfo>[];
    final custom = [
      for (final f in _customFolders)
        HubChip.custom(id: f.id, name: f.name),
    ];
    final telegram = <HubChip>[
      for (final f in liveFolders)
        if (!mirroredTgIds.contains(f.id))
          HubChip.telegram(id: f.id, name: f.title),
    ];
    // Keep SQLite-warmed TG chips until the first live folder list arrives
    // (Ready alone is not enough — folders hydrate a tick later).
    if (telegram.isEmpty &&
        cachedTg.isNotEmpty &&
        !_tgFoldersLiveOnce) {
      for (final c in cachedTg) {
        final id = c.tgFolderId;
        if (id == null || mirroredTgIds.contains(id)) continue;
        telegram.add(c);
      }
    }
    final allUser = [...custom, ...telegram];
    if (orderKeys == null || orderKeys.isEmpty) {
      return [...system, ...allUser];
    }
    final byKey = <String, HubChip>{
      for (final c in [...system, ...allUser]) c.key: c,
    };
    final out = <HubChip>[];
    for (final key in orderKeys) {
      final chip = byKey.remove(key);
      if (chip != null) out.add(chip);
    }
    // Remaining system first (stable), then any leftover user chips (new at end).
    for (final c in system) {
      if (byKey.remove(c.key) != null) out.add(c);
    }
    for (final c in allUser) {
      if (byKey.remove(c.key) != null) out.add(c);
    }
    return out;
  }

  Set<int> get _matchedTgChatIds => {
        for (final m in _tdlibMatches.values)
          if (m.fcUserId > 0 && m.tgChatId != 0) m.tgChatId,
      };

  Future<void> _loadMirrorState() async {
    final fcToTg = await ChatHubFolderMirrorStore.loadFcToTg();
    final extras = await ChatHubFolderMirrorStore.loadTgExtras();
    if (!mounted) return;
    setState(() {
      _fcToTgFolder = fcToTg;
      _tgFolderExtras = extras;
      _mirrorStateLoaded = true;
    });
    if (!_pendingFirstPaint) {
      _rebuildChips(preferSelected: _selectedChip);
    }
    _tryFirstPaintReveal();
  }

  void _rebuildChips({HubChip? preferSelected}) {
    // Chip churn during first-paint hold is what the user sees as "flash".
    if (_pendingFirstPaint) return;
    final next = _composeChips(orderKeys: _chips.map((c) => c.key).toList());
    _replaceChips(next, preferSelected: preferSelected);
  }

  void _replaceChips(List<HubChip> next, {HubChip? preferSelected}) {
    final same = next.length == _chips.length &&
        List.generate(next.length, (i) => next[i] == _chips[i])
            .every((ok) => ok);
    if (same) return;

    final selected = preferSelected ??
        (_tabController.index >= 0 && _tabController.index < _chips.length
            ? _chips[_tabController.index]
            : next.first);
    final oldController = _tabController;
    oldController.removeListener(_onFilterTabChanged);
    final allChip = const HubChip.system(ChatHubSystemFilter.all);
    final initialIndex = next.contains(selected)
        ? next.indexOf(selected)
        : (next.contains(allChip) ? next.indexOf(allChip) : 0);
    final newController = TabController(
      length: next.length,
      vsync: this,
      initialIndex: initialIndex.clamp(0, next.isEmpty ? 0 : next.length - 1),
    );
    newController.addListener(_onFilterTabChanged);
    setState(() {
      _chips = next;
      _tabController = newController;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  void _onFilterTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (!mounted) return;
    final idx = _tabController.index;
    if (idx < 0 || idx >= _chips.length) return;
    final chip = _chips[idx];
    if (chip.system == ChatHubSystemFilter.telegram) {
      unawaited(AppActions.refreshStatus());
    } else {
      setState(() {});
    }
    final tgFolderId = chip.tgFolderId;
    if (tgFolderId != null && _tdlibReady) {
      unawaited(
        ref
            .read(telegramTdlibServiceProvider)
            .ensureFolderChatsLoaded(tgFolderId),
      );
    }
  }

  bool get _telegramFilterSelected {
    final idx = _tabController.index;
    return idx >= 0 &&
        idx < _chips.length &&
        _chips[idx].system == ChatHubSystemFilter.telegram;
  }

  String _chipLabel(HubChip chip) {
    if (chip.isCustom || chip.isTelegramFolder) return chip.label;
    if (chip.system == ChatHubSystemFilter.telegram && widget.telegramGrace) {
      return 'Telegram · чтение';
    }
    return chip.label;
  }

  Future<void> _loadCustomFolders() async {
    try {
      final raw = await ref.read(familychatRepositoryProvider).chatFolders();
      if (!mounted) return;
      unawaited(
        HubFirstPaintSnapshot.persistFolders([
          for (final e in raw) Map<String, dynamic>.from(e as Map),
        ]),
      );
      final folders = raw.map(ChatFolderData.fromJson).toList()
        ..sort((a, b) {
          final c = a.position.compareTo(b.position);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      // During cold-start hold: store silently — chip bar rebuilds once on reveal.
      _customFolders = folders;
      _fcFoldersLoaded = true;
      if (_pendingFirstPaint || _coldStartCoalesce) {
        _tryFirstPaintReveal();
        return;
      }
      setState(() {});
      _rebuildChips(preferSelected: _selectedChip);
      for (final f in folders) {
        if (f.hasUnmatchedTgMember(_matchedTgChatIds) &&
            !_fcToTgFolder.containsKey(f.id)) {
          unawaited(_ensureFcFolderMirroredToTg(f.id));
        }
      }
      _tryFirstPaintReveal();
    } catch (_) {
      // Hub still works with system folders only.
      if (!mounted) return;
      _fcFoldersLoaded = true;
      if (!(_pendingFirstPaint || _coldStartCoalesce)) {
        setState(() {});
      }
      _tryFirstPaintReveal();
    }
  }

  Future<void> _restoreTabOrder() async {
    final saved = await ChatHubTabOrderStorage.load();
    if (!mounted || saved == null || saved.isEmpty) return;
    if (_pendingFirstPaint) {
      // Applied together with TG folders on first paint.
      _chips = _composeChips(orderKeys: saved);
      return;
    }
    final next = _composeChips(orderKeys: saved);
    _replaceChips(next);
  }

  Future<void> _restorePinnedOrder() async {
    final saved = await ChatHubPinStorage.load();
    if (!mounted) return;
    setState(() => _pinnedOrder = saved);
  }

  Future<void> _persistPinnedOrder() async {
    await ChatHubPinStorage.save(_pinnedOrder);
  }

  bool _isHubRowPinned(Map<String, dynamic> thread) {
    final key = ChatFolderMemberKey.forHubRow(thread);
    return key != null && _pinnedOrder.contains(key);
  }

  int _pinRank(Map<String, dynamic> thread) {
    final key = ChatFolderMemberKey.forHubRow(thread);
    if (key == null) return -1;
    return _pinnedOrder.indexOf(key);
  }

  Future<void> _persistTabOrder() async {
    await ChatHubTabOrderStorage.save(_chips.map((c) => c.key).toList());
    var pos = 0;
    final repo = ref.read(familychatRepositoryProvider);
    final byId = <int, ChatFolderData>{
      for (final f in _customFolders) f.id: f,
    };
    for (final chip in _chips) {
      if (!chip.isCustom) continue;
      final id = chip.folderId!;
      final current = byId[id];
      if (current == null) {
        pos++;
        continue;
      }
      if (current.position != pos) {
        try {
          await repo.updateChatFolder(id, position: pos);
          byId[id] = ChatFolderData(
            id: current.id,
            name: current.name,
            position: pos,
            memberKeys: current.memberKeys,
          );
        } catch (_) {}
      }
      pos++;
    }
    if (!mounted) return;
    setState(() {
      _customFolders = byId.values.toList()
        ..sort((a, b) {
          final c = a.position.compareTo(b.position);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
    });
  }

  /// Switch hub filter to Telegram (no-op if tab not available).
  void selectTelegramTab() {
    final i = _chips.indexWhere((c) => c.system == ChatHubSystemFilter.telegram);
    if (i < 0) return;
    if (_tabController.index != i) {
      _tabController.index = i;
    }
  }

  void _onReorderTabs(int oldIndex, int newIndex) {
    if (!_folderReorderMode) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final selected = _chips[_tabController.index];
    setState(() {
      final item = _chips.removeAt(oldIndex);
      _chips.insert(newIndex, item);
    });
    final nextIndex = _chips.indexOf(selected);
    if (nextIndex >= 0 && _tabController.index != nextIndex) {
      _tabController.index = nextIndex;
    }
  }

  void _enterFolderReorderMode() {
    if (_folderReorderMode) return;
    setState(() {
      _folderReorderMode = true;
      if (_searchVisible) {
        _searchVisible = false;
        _searchQuery = '';
        _searchController.clear();
        _clearTgGlobalSearch();
      }
    });
  }

  Future<void> _finishFolderReorder() async {
    if (!_folderReorderMode) return;
    setState(() => _folderReorderMode = false);
    await _persistTabOrder();
  }

  Future<void> _showFolderChipMenu(
    BuildContext chipContext,
    HubChip chip,
  ) async {
    if (_folderReorderMode) return;
    final box = chipContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight =
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final position = RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlay.size,
    );
    final canDelete = chip.isCustom || chip.isTelegramFolder;
    final canMute = chip.isCustom || chip.isTelegramFolder;
    final muteActive = canMute && HubFolderMuteStore.isActive(chip.key);
    final scheme = Theme.of(context).colorScheme;
    final action = await showMenu<String>(
      context: context,
      position: position,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        const PopupMenuItem(
          value: 'reorder',
          child: _HubOverflowMenuRow(
            icon: LucideIcons.list_ordered,
            label: 'Изменить порядок',
          ),
        ),
        if (canMute)
          PopupMenuItem(
            value: 'notifications',
            child: _HubOverflowMenuRow(
              icon: muteActive ? LucideIcons.bell_off : LucideIcons.bell,
              label: 'Уведомления',
            ),
          ),
        if (canDelete)
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(LucideIcons.trash, size: 22, color: scheme.error),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Удалить папку',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: scheme.error,
                        ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'reorder') {
      _enterFolderReorderMode();
    } else if (action == 'notifications') {
      await _showFolderNotificationsFlow(chip);
    } else if (action == 'delete') {
      await _deleteFolderChip(chip);
    }
  }

  void _armFolderMuteReconcileTimer() {
    _folderMuteReconcileTimer?.cancel();
    _folderMuteReconcileTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (!mounted) return;
        unawaited(_reconcileAllFolderMutes());
      },
    );
  }

  Future<void> _reconcileAllFolderMutes() async {
    await HubFolderMute.reconcileAll(
      repo: ref.read(familychatRepositoryProvider),
      tdlib: ref.read(telegramTdlibServiceProvider),
      fcFolders: _customFolders,
      tgFolderExtras: _tgFolderExtras,
    );
    if (mounted) setState(() => _folderMuteUiEpoch++);
  }

  Future<void> _showFolderNotificationsFlow(HubChip chip) async {
    if (!chip.isCustom && !chip.isTelegramFolder) return;
    final active = HubFolderMuteStore.isActive(chip.key);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                active ? LucideIcons.bell_off : LucideIcons.bell,
              ),
              title: Text(
                active
                    ? 'Уведомления папки выключены'
                    : 'Уведомления папки включены',
              ),
              subtitle: Text(
                active
                    ? 'Можно снова включить или изменить срок'
                    : 'Можно выключить для всех чатов в папке',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(LucideIcons.bell),
              title: const Text('Включить'),
              onTap: () => Navigator.pop(ctx, 'enable'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.bell_off),
              title: const Text('Выключить'),
              onTap: () => Navigator.pop(ctx, 'disable'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'enable') {
      await HubFolderMute.clearFolder(
        folderKey: chip.key,
        repo: ref.read(familychatRepositoryProvider),
        tdlib: ref.read(telegramTdlibServiceProvider),
        fcFolders: _customFolders,
        tgFolderExtras: _tgFolderExtras,
      );
      if (!mounted) return;
      setState(() => _folderMuteUiEpoch++);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Уведомления папки включены')),
      );
      return;
    }
    await _showFolderMuteDurationSheet(chip);
  }

  Future<void> _showFolderMuteDurationSheet(HubChip chip) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Выключить уведомления')),
            const Divider(height: 1),
            for (final e in const [
              ('1h', 'На час'),
              ('2h', 'На 2 часа'),
              ('6h', 'На 6 часов'),
              ('24h', 'На 24 часа'),
              ('quiet', 'По расписанию'),
              ('forever', 'Навсегда'),
            ])
              ListTile(
                title: Text(e.$2),
                onTap: () => Navigator.pop(ctx, e.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked == 'quiet') {
      await _editFolderQuietHours(chip);
      return;
    }
    final until = HubFolderMuteState.mutedUntilForMode(picked);
    final state = HubFolderMuteState(mode: picked, mutedUntilMs: until);
    await HubFolderMute.applyFolderState(
      folderKey: chip.key,
      state: state,
      repo: ref.read(familychatRepositoryProvider),
      tdlib: ref.read(telegramTdlibServiceProvider),
      fcFolders: _customFolders,
      tgFolderExtras: _tgFolderExtras,
    );
    if (!mounted) return;
    setState(() => _folderMuteUiEpoch++);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Уведомления папки выключены')),
    );
  }

  Future<void> _editFolderQuietHours(HubChip chip) async {
    final prev = HubFolderMuteStore.get(chip.key);
    var start = _parseFolderHm(
      prev?.quietStart,
      const TimeOfDay(hour: 22, minute: 0),
    );
    var end = _parseFolderHm(
      prev?.quietEnd,
      const TimeOfDay(hour: 8, minute: 0),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Future<void> pickStart() async {
              final picked = await showTimePicker(
                context: ctx,
                initialTime: start,
                helpText: 'С какого времени не беспокоить',
              );
              if (picked != null) setLocal(() => start = picked);
            }

            Future<void> pickEnd() async {
              final picked = await showTimePicker(
                context: ctx,
                initialTime: end,
                helpText: 'До какого времени не беспокоить',
              );
              if (picked != null) setLocal(() => end = picked);
            }

            String fmt(TimeOfDay t) =>
                '${t.hour.toString().padLeft(2, '0')}:'
                '${t.minute.toString().padLeft(2, '0')}';

            return AlertDialog(
              title: const Text('По расписанию'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'В выбранном промежутке уведомления папки выключены. '
                    'Вне промежутка — включены.',
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('С'),
                    trailing: TextButton(
                      onPressed: pickStart,
                      child: Text(fmt(start)),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('До'),
                    trailing: TextButton(
                      onPressed: pickEnd,
                      child: Text(fmt(end)),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );
    if (saved != true || !mounted) return;
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final state = HubFolderMuteState(
      mode: 'quiet',
      quietStart: fmt(start),
      quietEnd: fmt(end),
      utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
    );
    await HubFolderMute.applyFolderState(
      folderKey: chip.key,
      state: state,
      repo: ref.read(familychatRepositoryProvider),
      tdlib: ref.read(telegramTdlibServiceProvider),
      fcFolders: _customFolders,
      tgFolderExtras: _tgFolderExtras,
    );
    if (!mounted) return;
    setState(() => _folderMuteUiEpoch++);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Тихие часы папки: с ${fmt(start)} до ${fmt(end)}',
        ),
      ),
    );
  }

  TimeOfDay _parseFolderHm(String? raw, TimeOfDay fallback) {
    final parts = (raw ?? '').split(':');
    if (parts.length < 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return fallback;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  Future<void> _createFolderFlow() async {
    final name = await _promptFolderName();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final created = await ref
          .read(familychatRepositoryProvider)
          .createChatFolder(name: name);
      if (!mounted) return;
      final folder = ChatFolderData.fromJson(created);
      setState(() {
        _customFolders = [..._customFolders, folder];
      });
      final chip = HubChip.custom(id: folder.id, name: folder.name);
      // New FC folder always goes to the end of the tab strip.
      final next = _composeChips(
        orderKeys: [..._chips.map((c) => c.key), chip.key],
      );
      _replaceChips(next, preferSelected: chip);
      unawaited(_persistTabOrder());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать папку: $e')),
      );
    }
  }

  Future<String?> _promptFolderName({
    String initial = '',
    String title = 'Новая папка',
    String confirmLabel = 'Создать',
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 64,
            decoration: const InputDecoration(
              hintText: 'Название',
              counterText: '',
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final name = result?.trim() ?? '';
    return name.isEmpty ? null : name;
  }

  List<ChatFolderData> _foldersContaining(Map<String, dynamic> thread) {
    return _customFolders.where((f) => f.containsHubRow(thread)).toList();
  }

  List<TdlibChatFolderInfo> _tgFoldersContaining(Map<String, dynamic> thread) {
    if (!_tdlibReady) return const [];
    final svc = ref.read(telegramTdlibServiceProvider);
    final key = ChatFolderMemberKey.forHubRow(thread);
    final tgChatId = (thread['tdlib_chat_id'] as num?)?.toInt();
    final out = <TdlibChatFolderInfo>[];
    for (final f in svc.manualChatFolders) {
      if (_fcToTgFolder.values.contains(f.id)) continue;
      final extras = _tgFolderExtras[f.id];
      if (key != null && extras != null && extras.contains(key)) {
        out.add(f);
        continue;
      }
      if (tgChatId != null && svc.isChatInFolder(tgChatId, f.id)) {
        out.add(f);
      }
    }
    return out;
  }

  bool _rowInTgFolder(Map<String, dynamic> thread, int tgFolderId) {
    final key = ChatFolderMemberKey.forHubRow(thread);
    final extras = _tgFolderExtras[tgFolderId];
    if (key != null && extras != null && extras.contains(key)) return true;
    final tgChatId = (thread['tdlib_chat_id'] as num?)?.toInt();
    if (tgChatId == null) return false;
    return ref
        .read(telegramTdlibServiceProvider)
        .isChatInFolder(tgChatId, tgFolderId);
  }

  Future<void> _onThreadLongPress(Map<String, dynamic> thread) async {
    final key = ChatFolderMemberKey.forHubRow(thread);
    if (key == null) return;
    if (_searchVisible) {
      _searchVisible = false;
      _searchQuery = '';
      _searchController.clear();
      _clearTgGlobalSearch();
    }
    setState(() {
      _selectionMode = true;
      _selectedKeys
        ..clear()
        ..add(key);
      _selectedRows
        ..clear()
        ..[key] = Map<String, dynamic>.from(thread);
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedKeys.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
      _selectedRows.clear();
    });
  }

  void _toggleThreadSelection(Map<String, dynamic> thread) {
    final key = ChatFolderMemberKey.forHubRow(thread);
    if (key == null) return;
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
        _selectedRows.remove(key);
        if (_selectedKeys.isEmpty) _selectionMode = false;
      } else {
        _selectionMode = true;
        _selectedKeys.add(key);
        _selectedRows[key] = Map<String, dynamic>.from(thread);
      }
    });
  }

  List<Map<String, dynamic>> get _selectedThreads =>
      _selectedKeys.map((k) => _selectedRows[k]).whereType<Map<String, dynamic>>().toList();

  bool get _selectionAnyNotificationsOn =>
      _selectedThreads.any(_threadNotificationsEnabled);

  bool get _selectionAnyPinned => _selectedThreads.any(_isHubRowPinned);

  Future<void> _pinSelectedThreads() async {
    final keys = _selectedThreads
        .map(ChatFolderMemberKey.forHubRow)
        .whereType<String>()
        .toList();
    if (keys.isEmpty) return;
    final remaining =
        _pinnedOrder.where((k) => !keys.contains(k)).toList(growable: false);
    setState(() {
      // Selected chats go to the top of the pinned block.
      _pinnedOrder = [...keys, ...remaining];
    });
    await _persistPinnedOrder();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          keys.length == 1 ? 'Чат закреплён' : 'Чаты закреплены',
        ),
      ),
    );
  }

  Future<void> _unpinSelectedThreads() async {
    final keys = _selectedThreads
        .map(ChatFolderMemberKey.forHubRow)
        .whereType<String>()
        .toSet();
    if (keys.isEmpty) return;
    final before = _pinnedOrder.length;
    setState(() {
      _pinnedOrder = _pinnedOrder.where((k) => !keys.contains(k)).toList();
    });
    if (_pinnedOrder.length == before) return;
    await _persistPinnedOrder();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Чаты откреплены')),
    );
  }

  Future<void> _muteSelectedThreads() async {
    final threads = _selectedThreads;
    if (threads.isEmpty) return;
    final mute = _selectionAnyNotificationsOn;
    final repo = ref.read(familychatRepositoryProvider);
    final svc = ref.read(telegramTdlibServiceProvider);
    var ok = 0;
    for (final thread in threads) {
      try {
        final kind = thread['kind']?.toString() ?? '';
        if (_isTdlibHubKind(kind)) {
          final chatId = (thread['tdlib_chat_id'] as num?)?.toInt();
          if (chatId == null || chatId == 0) continue;
          await svc.setChatMuted(chatId, muted: mute);
          ok++;
          continue;
        }
        final threadId = chatAsInt(thread['id']);
        if (threadId == null || threadId <= 0) continue;
        if (ChatLocalStore.isSupported) {
          await ChatLocalMutations.patchThreadNotificationsLocal(
            threadId,
            {'notifications_enabled': !mute},
          );
          await ChatOfflineOutbox.enqueueMute(
            threadId: threadId,
            muteKey: mute ? 'forever' : 'off',
          );
          ChatMutationCoordinator.scheduleSync(repo);
        } else {
          await repo.setThreadMute(threadId, mute ? 'forever' : 'off');
        }
        // Keep matched TG DM mute in sync with FC mute.
        final peer = _dmPeerUserId(thread);
        if (peer != null && peer > 0 && svc.isReady) {
          for (final m in _tdlibMatches.values) {
            if (m.fcUserId != peer || m.tgChatId == 0) continue;
            await svc.setChatMuted(m.tgChatId, muted: mute);
            break;
          }
        }
        final key = ChatFolderMemberKey.forHubRow(thread);
        if (key != null) {
          final next = Map<String, dynamic>.from(thread);
          next['notifications_enabled'] = !mute;
          _selectedRows[key] = next;
        }
        final idx = _threads.indexWhere((t) => chatAsInt(t['id']) == threadId);
        if (idx >= 0) {
          final next = Map<String, dynamic>.from(_threads[idx]);
          next['notifications_enabled'] = !mute;
          _threads[idx] = next;
        }
        ok++;
      } catch (e) {
        debugPrint('[hub] mute selected failed: $e');
      }
    }
    if (!mounted) return;
    setState(() {});
    if (ok > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mute ? 'Уведомления отключены' : 'Уведомления включены',
          ),
        ),
      );
    }
  }

  Future<void> _onSelectionMenuAction(String action) async {
    final threads = _selectedThreads;
    if (threads.isEmpty) return;
    if (action == 'pin') {
      await _pinSelectedThreads();
    } else if (action == 'unpin') {
      await _unpinSelectedThreads();
    } else if (action == 'add_folder') {
      await _pickFolderAndAddMany(threads);
    } else if (action == 'remove_folder') {
      await _removeSelectedFromFolders(threads);
    } else if (action == 'archive') {
      await _archiveSelectedThreads();
    }
  }

  /// Resolve the Telegram chat id for archive actions (TG row / linked FC).
  int? _tgChatIdForArchive(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString() ?? '';
    if (kind == 'tdlib_archive') return null;
    if (_isTdlibHubKind(kind)) {
      final id = (thread['tdlib_chat_id'] as num?)?.toInt();
      return (id != null && id != 0) ? id : null;
    }
    final matched = _matchedTgOpenTarget(thread);
    if (matched != null) return matched.chatId;
    final tg = thread['telegram'];
    if (tg is Map && tg['linked'] == true) {
      final id = (tg['tg_chat_id'] as num?)?.toInt() ??
          int.tryParse('${tg['tg_chat_id'] ?? ''}');
      if (id != null && id != 0) return id;
    }
    final saved = _savedMessagesTgChatId(thread);
    if (saved != null) return null; // Saved Messages can't be archived
    return null;
  }

  bool _isHubRowInTgArchive(Map<String, dynamic> thread) {
    if (thread['kind']?.toString() == 'tdlib_archive') return false;
    if (HubFirstPaintSnapshot.isArchivedTgRow(thread)) return true;
    final id = _tgChatIdForArchive(thread);
    if (id != null) {
      for (final r in _snapshotArchiveRows) {
        final snapId = (r['tdlib_chat_id'] as num?)?.toInt();
        if (snapId == id) return true;
      }
    }
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase != TdlibAuthPhase.ready) return false;
    if (id == null) return false;
    return svc.isChatArchived(id);
  }

  Future<void> _archiveSelectedThreads() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    if (!_tdlibReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Telegram ещё не подключён')),
      );
      return;
    }
    final ids = <int>[];
    for (final t in _selectedThreads) {
      final id = _tgChatIdForArchive(t);
      if (id == null || id == 0) continue;
      if (svc.isSavedMessagesChat(id)) continue;
      if (!ids.contains(id)) ids.add(id);
    }
    if (ids.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Выберите чаты Telegram для архива'),
        ),
      );
      return;
    }
    await svc.archiveChats(ids);
    if (!mounted) return;
    _syncSnapshotArchiveFromLive();
    _exitSelection();
    _scheduleSnapshotPersist();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ids.length == 1 ? 'Чат добавлен в архив' : 'Чаты добавлены в архив',
        ),
      ),
    );
  }

  /// Keep cold-start Archive RAM in sync with live TDLib Archive list.
  void _syncSnapshotArchiveFromLive() {
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase != TdlibAuthPhase.ready) return;
    final next = <Map<String, dynamic>>[];
    for (final c in svc.hubArchiveChats) {
      final row = svc.hubSnapshotRowForChat(c.chatId);
      if (row != null) next.add(row);
    }
    _snapshotArchiveRows = next;
    // Drop those chats from main snapshot overlay if present.
    if (_snapshotTgRows.isNotEmpty && next.isNotEmpty) {
      final archivedIds = {
        for (final r in next) (r['tdlib_chat_id'] as num?)?.toInt(),
      }..removeWhere((e) => e == null);
      _snapshotTgRows = [
        for (final r in _snapshotTgRows)
          if (!archivedIds.contains((r['tdlib_chat_id'] as num?)?.toInt()))
            r,
      ];
    }
  }

  List<Map<String, dynamic>> _archiveRowsForPersist() {
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase == TdlibAuthPhase.ready && svc.hubArchiveChats.isNotEmpty) {
      final out = <Map<String, dynamic>>[];
      for (final c in svc.hubArchiveChats) {
        final row = svc.hubSnapshotRowForChat(c.chatId);
        if (row != null) out.add(row);
      }
      return out;
    }
    return [
      for (final r in _snapshotArchiveRows)
        {
          ...Map<String, dynamic>.from(r),
          'tdlib_archived': true,
        },
    ];
  }

  Future<void> _openTelegramArchive() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TelegramArchiveScreen(
          snapshotRows: [
            for (final r in _snapshotArchiveRows)
              Map<String, dynamic>.from(r),
          ],
        ),
      ),
    );
    if (!mounted) return;
    // Live archive may have changed while inside the screen.
    _scheduleSnapshotPersist();
    setState(() {});
  }

  Widget _buildArchiveHubTile(
    Map<String, dynamic> t, {
    required ThemeData theme,
    required ColorScheme scheme,
  }) {
    final unread = chatAsInt(t['unread_count']) ?? 0;
    final preview = _preview(t);
    return ListTile(
      key: const ValueKey('tdlib_archive'),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: scheme.primaryContainer,
        child: Icon(
          LucideIcons.archive,
          color: scheme.onPrimaryContainer,
          size: 22,
        ),
      ),
      title: Text(
        t['title']?.toString() ?? 'Архив чатов',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      subtitle: preview.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
      trailing: unread > 0
          ? CircleAvatar(
              radius: 10,
              backgroundColor: scheme.primary,
              child: Text(
                '$unread',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 11,
                ),
              ),
            )
          : null,
      onTap: () => unawaited(_openTelegramArchive()),
    );
  }

  Map<String, dynamic>? _archiveHubRow() {
    if (!widget.hasIndividualPremium) return null;
    final svc = ref.read(telegramTdlibServiceProvider);
    final liveReady = _tdlibReady && svc.hasArchivedChats;
    final snapReady = _snapshotArchiveRows.isNotEmpty;
    if (!liveReady && !snapReady) return null;

    String subtitle;
    var unread = 0;
    if (liveReady) {
      final archived = svc.hubArchiveChats;
      unread = svc.archiveUnreadChatCount;
      if (archived.isNotEmpty) {
        final tip = archived.first;
        final body = tip.lastMessageText.trim();
        subtitle = body.isNotEmpty ? '${tip.title}: $body' : tip.title;
      } else {
        final n = svc.archiveChatCount;
        subtitle = n > 0 ? '$n чатов' : 'Архив';
      }
    } else {
      final tip = _snapshotArchiveRows.first;
      unread = chatAsInt(tip['unread_count']) ?? 0;
      // Sum unmuted-ish unread from snapshot archive for cold badge.
      var sum = 0;
      for (final r in _snapshotArchiveRows) {
        sum += chatAsInt(r['unread_count']) ?? 0;
      }
      unread = sum;
      final title = tip['title']?.toString() ?? '';
      final lm = tip['last_message'];
      final body = lm is Map ? lm['body']?.toString().trim() ?? '' : '';
      subtitle = body.isNotEmpty && title.isNotEmpty
          ? '$title: $body'
          : (title.isNotEmpty ? title : '${_snapshotArchiveRows.length} чатов');
    }
    return {
      'id': -900001,
      'kind': 'tdlib_archive',
      'title': 'Архив чатов',
      'notifications_enabled': true,
      'unread_count': unread,
      'last_message': {
        'body': subtitle,
      },
    };
  }

  Future<void> _removeSelectedFromFolders(
    List<Map<String, dynamic>> threads,
  ) async {
    final selected = _selectedChip;
    if (selected.isCustom && selected.folderId != null) {
      for (final t in threads) {
        await _removeFromFolder(selected.folderId!, t, silent: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Удалено из папки')),
      );
      return;
    }
    if (selected.isTelegramFolder && selected.tgFolderId != null) {
      for (final t in threads) {
        await _removeFromTgFolder(selected.tgFolderId!, t, silent: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Удалено из папки')),
      );
      return;
    }

    // Union of folders that contain any selected chat.
    final fcById = <int, ChatFolderData>{};
    final tgById = <int, TdlibChatFolderInfo>{};
    for (final t in threads) {
      for (final f in _foldersContaining(t)) {
        fcById[f.id] = f;
      }
      for (final f in _tgFoldersContaining(t)) {
        tgById[f.id] = f;
      }
    }
    if (fcById.isEmpty && tgById.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выбранные чаты не в папках')),
      );
      return;
    }
    if (fcById.length + tgById.length == 1) {
      if (fcById.length == 1) {
        final id = fcById.keys.first;
        for (final t in threads) {
          if (_foldersContaining(t).any((f) => f.id == id)) {
            await _removeFromFolder(id, t, silent: true);
          }
        }
      } else {
        final id = tgById.keys.first;
        for (final t in threads) {
          if (_rowInTgFolder(t, id)) {
            await _removeFromTgFolder(id, t, silent: true);
          }
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Удалено из папки')),
      );
      return;
    }
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Удалить из папки')),
              for (final f in fcById.values)
                ListTile(
                  leading: const Icon(LucideIcons.folder_minus),
                  title: Text(f.name),
                  onTap: () => Navigator.of(ctx).pop({'fc': f.id}),
                ),
              for (final f in tgById.values)
                ListTile(
                  leading: const Icon(LucideIcons.folder_minus),
                  title: Text(f.title),
                  onTap: () => Navigator.of(ctx).pop({'tg': f.id}),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || picked is! Map) return;
    final fc = picked['fc'];
    final tg = picked['tg'];
    if (fc is int) {
      for (final t in threads) {
        if (_foldersContaining(t).any((f) => f.id == fc)) {
          await _removeFromFolder(fc, t, silent: true);
        }
      }
    }
    if (tg is int) {
      for (final t in threads) {
        if (_rowInTgFolder(t, tg)) {
          await _removeFromTgFolder(tg, t, silent: true);
        }
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Удалено из папки')),
    );
  }

  Future<void> _pickFolderAndAddMany(List<Map<String, dynamic>> threads) async {
    if (threads.isEmpty) return;
    // Folders that still miss at least one selected chat.
    final fcChoices = _customFolders.where((f) {
      return threads.any((t) => !f.containsHubRow(t));
    }).toList();
    final tgChoices = _tdlibReady
        ? ref
            .read(telegramTdlibServiceProvider)
            .manualChatFolders
            .where((f) {
              if (_fcToTgFolder.values.contains(f.id)) return false;
              return threads.any((t) => !_rowInTgFolder(t, f.id));
            })
            .toList()
        : const <TdlibChatFolderInfo>[];
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Добавить в папку'),
              ),
              for (final f in fcChoices)
                ListTile(
                  leading: const Icon(LucideIcons.folder),
                  title: Text(f.name),
                  onTap: () => Navigator.of(ctx).pop({'fc': f.id}),
                ),
              for (final f in tgChoices)
                ListTile(
                  leading: const Icon(LucideIcons.folder),
                  title: Text(f.title),
                  onTap: () => Navigator.of(ctx).pop({'tg': f.id}),
                ),
              ListTile(
                leading: const Icon(LucideIcons.plus),
                title: const Text('Создать папку'),
                onTap: () => Navigator.of(ctx).pop('create'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    if (picked == 'create') {
      final name = await _promptFolderName();
      if (name == null || !mounted) return;
      try {
        final created = await ref
            .read(familychatRepositoryProvider)
            .createChatFolder(name: name);
        final folder = ChatFolderData.fromJson(created);
        for (final t in threads) {
          await _addToFolder(folder.id, t, silent: true);
        }
        await _loadCustomFolders();
        final chip = HubChip.custom(id: folder.id, name: folder.name);
        final next = _composeChips(
          orderKeys: [..._chips.map((c) => c.key), chip.key],
        );
        _replaceChips(next, preferSelected: chip);
        unawaited(_persistTabOrder());
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Добавлено в папку')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
      return;
    }
    if (picked is Map) {
      final fc = picked['fc'];
      final tg = picked['tg'];
      if (fc is int) {
        for (final t in threads) {
          if (!_foldersContaining(t).any((f) => f.id == fc)) {
            await _addToFolder(fc, t, silent: true);
          }
        }
      }
      if (tg is int) {
        for (final t in threads) {
          if (!_rowInTgFolder(t, tg)) {
            await _addToTgFolder(tg, t, silent: true);
          }
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавлено в папку')),
      );
    }
  }

  Future<void> _addToFolder(
    int folderId,
    Map<String, dynamic> thread, {
    bool silent = false,
  }) async {
    final ids = ChatFolderMemberKey.apiIds(thread);
    if (ids == null) return;
    try {
      await ref.read(familychatRepositoryProvider).addChatFolderMember(
            folderId,
            threadId: ids.threadId,
            tgChatId: ids.tgChatId,
          );
      await _loadCustomFolders();
      unawaited(
        HubFolderMute.onMemberAdded(
          folderKey: 'custom:$folderId',
          threadId: ids.threadId,
          tgChatId: ids.tgChatId,
          repo: ref.read(familychatRepositoryProvider),
          tdlib: ref.read(telegramTdlibServiceProvider),
        ),
      );
      final tgChatId = ids.tgChatId;
      if (tgChatId != null && !_matchedTgChatIds.contains(tgChatId)) {
        await _ensureFcFolderMirroredToTg(folderId);
      } else {
        await _syncMirroredFolderToTg(folderId);
      }
      if (!mounted || silent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавлено в папку')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось добавить: $e')),
      );
    }
  }

  Future<void> _removeFromFolder(
    int folderId,
    Map<String, dynamic> thread, {
    bool silent = false,
  }) async {
    final ids = ChatFolderMemberKey.apiIds(thread);
    if (ids == null) return;
    try {
      await ref.read(familychatRepositoryProvider).removeChatFolderMember(
            folderId,
            threadId: ids.threadId,
            tgChatId: ids.tgChatId,
          );
      await _loadCustomFolders();
      await _syncMirroredFolderToTg(folderId);
      if (!mounted || silent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Удалено из папки')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить: $e')),
      );
    }
  }

  Future<void> _addToTgFolder(
    int tgFolderId,
    Map<String, dynamic> thread, {
    bool silent = false,
  }) async {
    final key = ChatFolderMemberKey.forHubRow(thread);
    final tgChatId = (thread['tdlib_chat_id'] as num?)?.toInt();
    try {
      if (tgChatId != null && _tdlibReady) {
        await ref.read(telegramTdlibServiceProvider).setChatIncludedInFolder(
              folderId: tgFolderId,
              chatId: tgChatId,
              included: true,
            );
        unawaited(
          HubFolderMute.onMemberAdded(
            folderKey: 'tg:$tgFolderId',
            tgChatId: tgChatId,
            repo: ref.read(familychatRepositoryProvider),
            tdlib: ref.read(telegramTdlibServiceProvider),
          ),
        );
      } else if (key != null) {
        await ChatHubFolderMirrorStore.addTgExtra(
          tgFolderId: tgFolderId,
          memberKey: key,
        );
        final extras = Map<int, Set<String>>.from(_tgFolderExtras);
        extras.putIfAbsent(tgFolderId, () => <String>{}).add(key);
        setState(() => _tgFolderExtras = extras);
        final extraTg = key.startsWith('tg:')
            ? int.tryParse(key.substring(3))
            : null;
        unawaited(
          HubFolderMute.onMemberAdded(
            folderKey: 'tg:$tgFolderId',
            tgChatId: extraTg ?? tgChatId,
            repo: ref.read(familychatRepositoryProvider),
            tdlib: ref.read(telegramTdlibServiceProvider),
          ),
        );
      } else {
        return;
      }
      if (!mounted) return;
      setState(() {});
      if (silent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавлено в папку')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось добавить: $e')),
      );
    }
  }

  Future<void> _removeFromTgFolder(
    int tgFolderId,
    Map<String, dynamic> thread, {
    bool silent = false,
  }) async {
    final key = ChatFolderMemberKey.forHubRow(thread);
    final tgChatId = (thread['tdlib_chat_id'] as num?)?.toInt();
    try {
      if (key != null) {
        await ChatHubFolderMirrorStore.removeTgExtra(
          tgFolderId: tgFolderId,
          memberKey: key,
        );
        final extras = Map<int, Set<String>>.from(_tgFolderExtras);
        extras[tgFolderId]?.remove(key);
        if (extras[tgFolderId]?.isEmpty ?? false) extras.remove(tgFolderId);
        setState(() => _tgFolderExtras = extras);
      }
      if (tgChatId != null && _tdlibReady) {
        await ref.read(telegramTdlibServiceProvider).setChatIncludedInFolder(
              folderId: tgFolderId,
              chatId: tgChatId,
              included: false,
            );
      }
      if (!mounted) return;
      setState(() {});
      if (silent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Удалено из папки')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить: $e')),
      );
    }
  }

  Future<void> _ensureFcFolderMirroredToTg(int fcFolderId) async {
    if (!_tdlibReady) return;
    ChatFolderData? folder;
    for (final f in _customFolders) {
      if (f.id == fcFolderId) {
        folder = f;
        break;
      }
    }
    if (folder == null) return;
    if (!folder.hasUnmatchedTgMember(_matchedTgChatIds)) return;

    final svc = ref.read(telegramTdlibServiceProvider);
    var tgId = _fcToTgFolder[fcFolderId];
    final includable = folder.tgChatIds();
    try {
      if (tgId == null) {
        tgId = await svc.createChatFolder(
          name: folder.name,
          includedChatIds: includable,
        );
        await ChatHubFolderMirrorStore.link(
          fcFolderId: fcFolderId,
          tgFolderId: tgId,
        );
        setState(() {
          _fcToTgFolder = {..._fcToTgFolder, fcFolderId: tgId!};
        });
        _rebuildChips(preferSelected: _selectedChip);
      } else {
        await svc.replaceFolderIncludedChats(
          folderId: tgId,
          includedChatIds: includable,
        );
      }
    } catch (e) {
      debugPrint('[hub] mirror folder $fcFolderId → TG failed: $e');
    }
  }

  Future<void> _syncMirroredFolderToTg(int fcFolderId) async {
    final tgId = _fcToTgFolder[fcFolderId];
    if (tgId == null || !_tdlibReady) return;
    ChatFolderData? folder;
    for (final f in _customFolders) {
      if (f.id == fcFolderId) {
        folder = f;
        break;
      }
    }
    if (folder == null) return;
    try {
      await ref.read(telegramTdlibServiceProvider).replaceFolderIncludedChats(
            folderId: tgId,
            includedChatIds: folder.tgChatIds(),
          );
    } catch (e) {
      debugPrint('[hub] sync mirror $fcFolderId → TG failed: $e');
    }
  }

  /// TG → FC for mirrored folders (membership + rename; drop link if TG gone).
  Future<void> _pullMirroredMembershipFromTg() async {
    if (!_tdlibReady || _fcToTgFolder.isEmpty) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final repo = ref.read(familychatRepositoryProvider);
    var changed = false;
    final staleFc = <int>[];

    for (final entry in _fcToTgFolder.entries) {
      final fcId = entry.key;
      final tgId = entry.value;
      if (!svc.hasChatFolder(tgId)) {
        staleFc.add(fcId);
        continue;
      }
      ChatFolderData? folder;
      for (final f in _customFolders) {
        if (f.id == fcId) {
          folder = f;
          break;
        }
      }
      if (folder == null) continue;

      final tgTitle = svc.chatFolderTitle(tgId)?.trim() ?? '';
      if (tgTitle.isNotEmpty && tgTitle != folder.name) {
        try {
          await repo.updateChatFolder(fcId, name: tgTitle);
          changed = true;
        } catch (_) {}
      }

      final tgChats = svc.chatIdsInFolder(tgId);
      final localTg = folder.tgChatIds().toSet();
      for (final chatId in tgChats) {
        if (localTg.contains(chatId)) continue;
        try {
          await repo.addChatFolderMember(fcId, tgChatId: chatId);
          changed = true;
        } catch (_) {}
      }
      for (final chatId in localTg) {
        if (tgChats.contains(chatId)) continue;
        try {
          await repo.removeChatFolderMember(fcId, tgChatId: chatId);
          changed = true;
        } catch (_) {}
      }
    }

    if (staleFc.isNotEmpty) {
      for (final fcId in staleFc) {
        await ChatHubFolderMirrorStore.unlinkFc(fcId);
      }
      setState(() {
        _fcToTgFolder = {
          for (final e in _fcToTgFolder.entries)
            if (!staleFc.contains(e.key)) e.key: e.value,
        };
      });
      _rebuildChips(preferSelected: _selectedChip);
    }
    if (changed) await _loadCustomFolders();
  }


  void _onOfflineSync() {
    if (!mounted) return;
    final online = ChatOfflineSync.instance.isOnline;
    final becameOnline = online && !_lastKnownOnline;
    _lastKnownOnline = online;
    // Only react to offline→online. Calling run() on every notifyListeners
    // (deliveries / sync boundaries) caused an infinite outbox loop.
    if (!becameOnline) return;
    if (_localFirst) {
      unawaited(ChatSyncService.instance.syncHub(prefetchMessages: false));
      final repo = ref.read(familychatRepositoryProvider);
      unawaited(ChatOfflineSync.instance.run(repo));
    } else {
      unawaited(_load(silent: true));
    }
  }

  void _bindLocalStore() {
    _threadsSub = ChatLocalStore.instance.watchThreads().listen((threads) {
      unawaited(_onThreadsUpdated(threads));
    });
    _membersSub = ChatLocalStore.instance.watchMembers().listen((members) {
      if (!mounted) return;
      if (members.isEmpty && _memberByUserId.isNotEmpty) return;
      setState(() => _applyMembers(members));
    });
  }

  Future<void> _onThreadsUpdated(List<Map<String, dynamic>> threads) async {
    if (!mounted) return;
    if (threads.isEmpty) {
      // Don't bump generation: a transient empty must not cancel in-flight
      // enrich of a populated snapshot.
      if (_threads.isNotEmpty) return;
      if (!_hubBootstrapDone) return;
      if (_loading) {
        setState(() => _loading = false);
        _tryFirstPaintReveal();
      }
      return;
    }
    final gen = ++_threadsEnrichGen;
    // Keep snap/TG-overlay tips: SQLite FC tip for matched DMs is often weeks
    // behind (activity lives on Telegram).
    final preserved = _mergeIncomingKeepFresherTips(threads);
    final enriched = _localFirst
        ? await enrichChatThreadsLastMessages(preserved)
        : preserved;
    if (!mounted || gen != _threadsEnrichGen) return;
    final sorted = _sortedThreads(enriched);
    final same = _threadsFingerprint(_threads) == _threadsFingerprint(sorted);
    final nextLoading = false;
    // During frozen snapshot + TG wait: update RAM silently — one paint when
    // live TG is ready (avoids FC length drip then TG drip then avatars).
    if (_coldStartCoalesce && _paintedFromSnapshot) {
      if (!same) _threads = sorted;
      _loading = nextLoading;
      unawaited(_seedMatchesFromFcThreads(sorted));
      _tryFirstPaintReveal();
      return;
    }
    if (same && _loading == nextLoading) {
      _tryFirstPaintReveal();
      return;
    }
    setState(() {
      if (!same) _threads = sorted;
      _loading = nextLoading;
    });
    unawaited(_seedMatchesFromFcThreads(sorted));
    unawaited(
      ShareDirectTargetService.syncFromThreads(
        sorted,
        memberByUserId: _memberByUserId,
      ),
    );
    _tryFirstPaintReveal();
    if (!_pendingFirstPaint) {
      _scheduleSnapshotPersist();
    }
  }

  Future<void> _seedMatchesFromFcThreads(
    List<Map<String, dynamic>> threads,
  ) async {
    try {
      final n =
          await TelegramMatchStore.instance.seedFromFcLinkedThreads(threads);
      if (n > 0 && mounted) {
        await _reloadTdlibMatches();
      }
    } catch (e) {
      debugPrint('[hub] seed matches from FC threads failed: $e');
    }
  }

  void _scheduleSnapshotPersist() {
    _snapshotPersistTimer?.cancel();
    _snapshotPersistTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_persistHubSnapshot());
    });
  }

  Future<void> _persistHubSnapshot() async {
    // Capture rows sync — dispose may tear down controllers right after.
    if (_threads.isEmpty &&
        _snapshotTgRows.isEmpty &&
        _snapshotArchiveRows.isEmpty) {
      return;
    }
    List<Map<String, dynamic>> rows;
    try {
      rows = _filteredBy(const HubChip.system(ChatHubSystemFilter.all));
      // Archived chats are hidden from All — append for the same SQLite flow.
      rows = [
        ...rows,
        ..._archiveRowsForPersist(),
      ];
    } catch (_) {
      rows = [
        ..._threads.map((e) => Map<String, dynamic>.from(e)),
        ..._snapshotTgRows.map((e) => Map<String, dynamic>.from(e)),
        ..._archiveRowsForPersist(),
      ];
    }
    if (rows.isEmpty) return;
    final avatarUrl = widget.profileAvatarUrl;
    final avatarPath = widget.profileAvatarLocalPath;
    try {
      await HubFirstPaintSnapshot.write(
        rows: rows,
        profileAvatarUrl: avatarUrl,
        profileAvatarSourcePath:
            avatarPath.isNotEmpty ? avatarPath : null,
      );
      await HubFirstPaintSnapshot.persistChips(_chips);
    } catch (e) {
      debugPrint('[hub] snapshot persist failed: $e');
    }
  }

  void _applyMembers(List<Map<String, dynamic>> members) {
    final byUserId = <int, Map<String, dynamic>>{};
    for (final m in members) {
      final uid = m['user_id'];
      final userId = uid is int ? uid : int.tryParse('$uid');
      if (userId == null) continue;
      byUserId[userId] = m;
    }
    _memberByUserId
      ..clear()
      ..addAll(byUserId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _snapshotPersistTimer?.cancel();
      unawaited(_persistHubSnapshot());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshFromLocalStore());
      unawaited(_reloadTdlibMatches());
      unawaited(
        ref.read(telegramTdlibServiceProvider).reconcileFamilyIdentities(),
      );
      unawaited(_reconcileAllFolderMutes());
      _armFolderMuteReconcileTimer();
      if (_localFirst) {
        final repo = ref.read(familychatRepositoryProvider);
        if (!ChatSyncService.instance.resumeCatchUpFresh) {
          unawaited(ChatSyncService.instance.syncHub(prefetchMessages: false));
        }
        unawaited(ChatOfflineSync.instance.run(repo));
      }
    }
  }

  Future<void> _hydrateFromLocalStore() async {
    final cachedThreads = await ChatLocalReads.threads();
    if (cachedThreads.isEmpty) return;
    await _onThreadsUpdated(cachedThreads);
    final cachedMembers = await ChatLocalReads.members();
    if (!mounted || cachedMembers.isEmpty) return;
    setState(() => _applyMembers(cachedMembers));
  }

  void _onRealtime(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == 'chat_message' ||
        ev == 'chat_messages_read' ||
        ev == 'chat_refresh' ||
        ev == 'chat_messages_deleted' ||
        ev == 'chat_message_reactions') {
      if (_localFirst) {
        // DB already updated by ChatSyncService; hub watches SQLite.
        return;
      }
      unawaited(_load(silent: true));
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      await _hydrateFromLocalStore();
    }
    final gen = ++_threadsEnrichGen;
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final results = await Future.wait([
        repo.chatThreads(),
        repo.members(),
      ]);
      final list = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await ChatLocalReads.saveThreadsAndMembers(
        threads: list,
        members: members,
      );
      if (!mounted || gen != _threadsEnrichGen) return;
      final sorted = _sortedThreads(list);
      final sameThreads = _threadsFingerprint(_threads) ==
          _threadsFingerprint(sorted);
      if (sameThreads && !_loading) {
        setState(() => _applyMembers(members));
        unawaited(ChatOfflineSync.instance.refreshOnline(repo));
        return;
      }
      setState(() {
        _threads = sorted;
        _applyMembers(members);
        _loading = false;
      });
      TelegramGroupBridge.instance.bindRepository(repo);
      TelegramGroupBridge.instance.syncFromThreads(sorted);
      unawaited(TelegramGroupBridge.instance.flushPending());
      TelegramSavedBridge.instance.bindRepository(repo);
      TelegramSavedBridge.instance.syncFromThreads(sorted);
      unawaited(TelegramSavedBridge.instance.ensureLinkedAndSync());
      unawaited(
        ShareDirectTargetService.syncFromThreads(
          sorted,
          memberByUserId: _memberByUserId,
        ),
      );
      unawaited(ChatOfflineSync.instance.refreshOnline(repo));
      _tryFirstPaintReveal();
    } catch (_) {
      if (!mounted || gen != _threadsEnrichGen) return;
      if (_threads.isEmpty) {
        await _hydrateFromLocalStore();
      }
      if (!mounted || gen != _threadsEnrichGen) return;
      setState(() {
        _loading = false;
      });
      _tryFirstPaintReveal();
    }
  }

  String _threadsFingerprint(List<Map<String, dynamic>> threads) {
    return threads.map((t) {
      final last = t['last_message'] as Map<String, dynamic>?;
      return '${t['id']}|${t['unread_count']}|${t['notifications_enabled']}|${last?['id']}|${last?['read_status']}|${t['title']}|${t['custom_title']}|${chatMessagePreviewText(last)}';
    }).join(';');
  }

  int? _dmPeerUserId(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString();
    if (kind != 'dm' && kind != 'friend_dm' && kind != 'tdlib_dm') {
      return null;
    }
    final raw = thread['peer_user_id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  /// Hide synthetic TDLib hub rows when an FC DM already exists for that peer.
  /// FC DM keeps send modes (TG / FC / auto); TDLib tab still lists unmatched.
  bool _isHiddenTdlibDuplicate(Map<String, dynamic> thread) {
    if (thread['kind']?.toString() != 'tdlib_dm') return false;
    final peer = _dmPeerUserId(thread);
    if (peer == null || peer <= 0) return false;
    for (final t in _threads) {
      final kind = t['kind']?.toString() ?? '';
      if (kind != 'dm' && kind != 'friend_dm') continue;
      if (_dmPeerUserId(t) == peer) return true;
    }
    return false;
  }

  /// FC DM row for a matched peer: overlay TDLib unread + fresher last message.
  /// Otherwise push arrives (TG) but the hub badge stays empty (FC unread=0).
  Map<String, dynamic> _enrichFcDmWithMatchedTg(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString() ?? '';
    if (kind != 'dm' && kind != 'friend_dm') return thread;
    final peer = _dmPeerUserId(thread);
    if (peer == null || peer <= 0) return thread;
    TelegramMatch? match;
    for (final m in _tdlibMatches.values) {
      if (m.fcUserId == peer && m.tgChatId != 0) {
        match = m;
        break;
      }
    }
    var tgChatId = match?.tgChatId ?? 0;
    // Server-linked FC DM (secretary/tdlib) even when MatchStore is empty.
    if (tgChatId == 0) {
      final tg = thread['telegram'];
      if (tg is Map && tg['linked'] == true) {
        tgChatId = (tg['tg_chat_id'] as num?)?.toInt() ??
            int.tryParse('${tg['tg_chat_id'] ?? ''}') ??
            0;
      }
    }
    if (tgChatId == 0) return thread;

    final threadId = chatAsInt(thread['id']);
    final svc = ref.read(telegramTdlibServiceProvider);
    // Before TDLib Ready: keep last-session tip so Киса sorts with the rest.
    if (svc.phase != TdlibAuthPhase.ready) {
      if (threadId == null) return thread;
      final snapTip = _matchedFcSnapTips[threadId];
      if (snapTip == null) return thread;
      final applied = _applyFresherLastMessage(thread, snapTip);
      return applied ?? thread;
    }
    final preview = svc.chatPreviewById(tgChatId);
    if (preview == null) {
      if (threadId == null) return thread;
      final snapTip = _matchedFcSnapTips[threadId];
      if (snapTip == null) return thread;
      return _applyFresherLastMessage(thread, snapTip) ?? thread;
    }

    final fcUnread = chatAsInt(thread['unread_count']) ?? 0;
    final tgUnread = preview.unreadCount;
    final muted = svc.isChatMutedIfKnown(tgChatId);
    var changed = false;
    var next = Map<String, dynamic>.from(thread);

    if (tgUnread > fcUnread) {
      next['unread_count'] = tgUnread;
      changed = true;
    }
    // Don't invent "unmuted" while TDLib mute is still unknown — that
    // turned gray snapshot badges blue on cold start.
    if (muted != null) {
      final tgNotifications = !muted;
      if (thread['notifications_enabled'] != tgNotifications) {
        next['notifications_enabled'] = tgNotifications;
        changed = true;
      }
    }

    if (preview.lastMessageDate > 0) {
      final fcMs = _lastMessageCreatedMs(thread['last_message']);
      final tgMs = preview.lastMessageDate * 1000;
      if (tgMs > fcMs + 500) {
        next['last_message'] = {
          'body': preview.lastMessageText,
          'created_at':
              DateTime.fromMillisecondsSinceEpoch(tgMs).toIso8601String(),
          if (preview.lastMessageReadStatus != null)
            'read_status': preview.lastMessageReadStatus,
          if (preview.lastMessageOutgoing) 'is_mine': true,
        };
        changed = true;
        if (threadId != null) {
          _matchedFcSnapTips[threadId] =
              Map<String, dynamic>.from(next['last_message'] as Map);
          unawaited(_persistOneMatchedFcTip(next));
        }
      }
    }

    // FC avatar wins; if FC has none, fall back to TG chat photo.
    // Trust TDLib path cache — never existsSync here (_filteredBy /
    // unreadOf × every rebuild mid-scroll). ChatAvatar errorBuilder covers
    // a missing file.
    if (!_hasFcPeerAvatar(thread)) {
      final path = preview.photoLocalPath?.trim() ?? '';
      final prevPath = next['tdlib_photo_path']?.toString() ?? '';
      if (path.isNotEmpty && path != prevPath) {
        next['tdlib_photo_path'] = path;
        changed = true;
      }
      final bytes = preview.photoMinithumbnailBytes;
      if (bytes != null &&
          bytes.isNotEmpty &&
          next['tdlib_photo_bytes'] != bytes &&
          (next['tdlib_photo_path'] == null ||
              next['tdlib_photo_path'].toString().isEmpty)) {
        next['tdlib_photo_bytes'] = bytes;
        changed = true;
      }
      final fid = preview.photoFileId;
      if (fid != null &&
          fid > 0 &&
          next['tdlib_photo_file_id'] != fid) {
        next['tdlib_photo_file_id'] = fid;
        changed = true;
      }
    }
    if (next['tdlib_chat_id'] != tgChatId) {
      next['tdlib_chat_id'] = tgChatId;
      changed = true;
    }

    return changed ? next : thread;
  }

  bool _isLinkedFcDm(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString() ?? '';
    if (kind != 'dm' && kind != 'friend_dm') return false;
    final tg = thread['telegram'];
    if (tg is Map && tg['linked'] == true) {
      final id = (tg['tg_chat_id'] as num?)?.toInt() ??
          int.tryParse('${tg['tg_chat_id'] ?? ''}') ??
          0;
      if (id != 0) return true;
    }
    return chatAsInt(thread['tdlib_chat_id']) != null;
  }

  int _lastMessageCreatedMs(Object? last) {
    if (last is! Map) return 0;
    final raw = last['created_at']?.toString() ?? '';
    final parsed = DateTime.tryParse(raw);
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  /// Returns updated thread when [candidate] tip is fresher; else null.
  Map<String, dynamic>? _applyFresherLastMessage(
    Map<String, dynamic> thread,
    Map<String, dynamic> candidate,
  ) {
    final candMs = _lastMessageCreatedMs(candidate);
    if (candMs <= 0) return null;
    final curMs = _lastMessageCreatedMs(thread['last_message']);
    final candBody = candidate['body']?.toString().trim() ?? '';
    final curLast = thread['last_message'];
    final curBody =
        curLast is Map ? curLast['body']?.toString().trim() ?? '' : '';
    // Prefer newer date; also fill empty local body from snap even if dates
    // are close (attachment-only FC tip vs TG text preview).
    final newer = candMs > curMs + 500;
    final fillEmpty = curBody.isEmpty && candBody.isNotEmpty && candMs >= curMs;
    if (!newer && !fillEmpty) return null;
    return {
      ...thread,
      'last_message': Map<String, dynamic>.from(candidate),
    };
  }

  void _rememberMatchedFcTip(int threadId, Map<String, dynamic> thread) {
    if (!_isLinkedFcDm(thread)) return;
    final last = thread['last_message'];
    if (last is! Map) return;
    final body = last['body']?.toString().trim() ?? '';
    final ms = _lastMessageCreatedMs(last);
    if (body.isEmpty && ms <= 0) return;
    final prev = _matchedFcSnapTips[threadId];
    if (prev != null && _lastMessageCreatedMs(prev) > ms) return;
    _matchedFcSnapTips[threadId] = Map<String, dynamic>.from(last);
  }

  List<Map<String, dynamic>> _mergeIncomingKeepFresherTips(
    List<Map<String, dynamic>> incoming,
  ) {
    final prevById = <int, Map<String, dynamic>>{
      for (final t in _threads)
        if (chatAsInt(t['id']) != null) chatAsInt(t['id'])!: t,
    };
    final out = <Map<String, dynamic>>[];
    for (final raw in incoming) {
      var row = Map<String, dynamic>.from(raw);
      final id = chatAsInt(row['id']);
      if (id != null) {
        final prev = prevById[id];
        if (prev != null) {
          final prevLast = prev['last_message'];
          if (prevLast is Map) {
            final applied = _applyFresherLastMessage(
              row,
              Map<String, dynamic>.from(prevLast),
            );
            if (applied != null) row = applied;
          }
        }
        final snapTip = _matchedFcSnapTips[id];
        if (snapTip != null) {
          final applied = _applyFresherLastMessage(row, snapTip);
          if (applied != null) {
            row = applied;
            _rememberMatchedFcTip(id, row);
          }
        } else {
          _rememberMatchedFcTip(id, row);
        }
      }
      out.add(row);
    }
    return out;
  }

  Future<void> _persistMatchedFcTipsToSqlite(
    List<Map<String, dynamic>> threads,
  ) async {
    if (!_localFirst) return;
    try {
      for (final t in threads) {
        if (!_isLinkedFcDm(t)) continue;
        final id = chatAsInt(t['id']);
        if (id == null) continue;
        final tip = _matchedFcSnapTips[id] ?? t['last_message'];
        if (tip is! Map) continue;
        final body = tip['body']?.toString().trim() ?? '';
        if (body.isEmpty) continue;
        final cur = t['last_message'];
        final curBody =
            cur is Map ? cur['body']?.toString().trim() ?? '' : '';
        final curMs = _lastMessageCreatedMs(cur);
        final tipMs = _lastMessageCreatedMs(tip);
        if (curBody == body && (tipMs - curMs).abs() < 1000) {
          // Still write if SQLite may have older tip without body.
        }
        await ChatLocalStore.instance.upsertThread({
          ...t,
          'last_message': Map<String, dynamic>.from(tip),
        });
      }
    } catch (e) {
      debugPrint('[hub] persist matched FC tips failed: $e');
    }
  }

  Future<void> _persistOneMatchedFcTip(Map<String, dynamic> thread) async {
    if (!_localFirst || !_isLinkedFcDm(thread)) return;
    try {
      await ChatLocalStore.instance.upsertThread(
        Map<String, dynamic>.from(thread),
      );
    } catch (_) {}
  }

  bool _hasFcPeerAvatar(Map<String, dynamic> thread) {
    final fromThread = thread['peer_avatar_url']?.toString().trim();
    if (fromThread != null && fromThread.isNotEmpty) return true;
    final peerId = _dmPeerUserId(thread);
    if (peerId == null) return false;
    final url = _memberByUserId[peerId]?['avatar_url']?.toString().trim();
    return url != null && url.isNotEmpty;
  }

  String? _dmAvatarUrl(Map<String, dynamic> thread) {
    final fromThread = thread['peer_avatar_url']?.toString().trim();
    if (fromThread != null && fromThread.isNotEmpty) return fromThread;
    final peerId = _dmPeerUserId(thread);
    if (peerId == null) return null;
    final member = _memberByUserId[peerId];
    final url = member?['avatar_url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  String _avatarName(Map<String, dynamic> thread) {
    final peerId = _dmPeerUserId(thread);
    if (peerId != null) {
      final member = _memberByUserId[peerId];
      final display = member?['display_name']?.toString().trim();
      if (display != null && display.isNotEmpty) return display;
    }
    return thread['title']?.toString() ?? 'Чат';
  }

  List<Map<String, dynamic>> _sortedThreads(List<Map<String, dynamic>> threads) {
    final sorted = List<Map<String, dynamic>>.from(threads);
    sorted.sort((a, b) {
      // Official TG: Archive folder is always pinned above everything in All.
      final aArch = a['kind']?.toString() == 'tdlib_archive';
      final bArch = b['kind']?.toString() == 'tdlib_archive';
      if (aArch != bArch) return aArch ? -1 : 1;
      final aPin = _pinRank(a);
      final bPin = _pinRank(b);
      final aPinned = aPin >= 0;
      final bPinned = bPin >= 0;
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      if (aPinned && bPinned && aPin != bPin) return aPin.compareTo(bPin);
      return _lastActivityAt(b).compareTo(_lastActivityAt(a));
    });
    return sorted;
  }

  DateTime _lastActivityAt(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    return DateTime.tryParse(last?['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool _isBirthdayCelebration(Map<String, dynamic> thread) {
    return thread['is_birthday_celebration'] == true;
  }

  /// Dual groups that include TG-only peers stay out of «Семья».
  bool _familyFolderOk(Map<String, dynamic> thread) {
    final tg = thread['telegram'];
    if (tg is! Map) return true;
    if (tg['linked'] != true) return true;
    if (tg.containsKey('family_folder_eligible')) {
      return tg['family_folder_eligible'] != false;
    }
    return true;
  }

  bool _matchesChip(Map<String, dynamic> thread, HubChip chip) {
    if (chip.isTelegramFolder) {
      final id = chip.tgFolderId;
      if (id == null) return false;
      return _rowInTgFolder(thread, id);
    }
    if (chip.isCustom) {
      ChatFolderData? folder;
      for (final f in _customFolders) {
        if (f.id == chip.folderId) {
          folder = f;
          break;
        }
      }
      return folder?.containsHubRow(thread) ?? false;
    }
    final kind = thread['kind']?.toString() ?? '';
    return switch (chip.system!) {
      // All = FC threads + TG hub rows (incl. friend_dm; no Friends folder).
      ChatHubSystemFilter.all => true,
      // Семья = FC family world only (family/group + family DMs).
      // Exclude friend_dm, TG synthetics, and dual groups with TG-only peers.
      ChatHubSystemFilter.family =>
        (kind == 'family' ||
                kind == 'group' ||
                kind == 'dm' ||
                _isBirthdayCelebration(thread)) &&
            _familyFolderOk(thread),
      ChatHubSystemFilter.telegram => false,
    };
  }

  List<Map<String, dynamic>> _hubMergedThreads({
    required bool includeTelegramList,
    int? tgFolderId,
  }) {
    // Live TG as soon as the first loadChats page lands; keep snapshot rows
    // for chat ids not yet in RAM until hydrate completes (TG progressive).
    final liveTg = _liveTgListReady();
    final svc = ref.read(telegramTdlibServiceProvider);
    final hydrateDone = svc.hubHydrateComplete;
    final linkedTgChatIds = _fcLinkedTgChatIds();
    var liveDm = liveTg ? _tdlibHubEntries() : const <Map<String, dynamic>>[];
    var liveList = (liveTg && includeTelegramList)
        ? _telegramListEntries()
        : const <Map<String, dynamic>>[];
    var liveFolder = (liveTg && tgFolderId != null)
        ? _tdlibFolderEntries(tgFolderId)
        : const <Map<String, dynamic>>[];
    // Until hydrate finishes, soft-blend snapshot unread/tip into live rows so
    // the first loadChats page does not flash badges/previews to 0 / stale.
    if (liveTg && !hydrateDone && _snapshotTgRows.isNotEmpty) {
      liveDm = _softBlendLiveWithSnapshot(liveDm);
      liveList = _softBlendLiveWithSnapshot(liveList);
      liveFolder = _softBlendLiveWithSnapshot(liveFolder);
    }
    final liveTgIds = <int>{
      ...linkedTgChatIds,
      ..._matchedTgChatIds,
      for (final r in liveDm)
        if ((r['tdlib_chat_id'] as num?) != null)
          (r['tdlib_chat_id'] as num).toInt(),
      for (final r in liveList)
        if ((r['tdlib_chat_id'] as num?) != null)
          (r['tdlib_chat_id'] as num).toInt(),
      for (final r in liveFolder)
        if ((r['tdlib_chat_id'] as num?) != null)
          (r['tdlib_chat_id'] as num).toInt(),
    };
    final keepSnapshotGaps = !hydrateDone || !liveTg;
    final snapshotTg = (keepSnapshotGaps && _snapshotTgRows.isNotEmpty)
        ? [
            for (final r in _snapshotTgRows)
              if (!_snapshotTgCoveredByFc(r, linkedTgChatIds) &&
                  !_snapshotTgCoveredByLive(r, liveTgIds) &&
                  !_snapshotTgIsArchived(r, svc))
                r,
          ]
        : const <Map<String, dynamic>>[];
    return [
      ..._threads,
      ...liveDm,
      ...liveList,
      // Snapshot fills gaps until pages/folders catch up; soft-restart fallback.
      if (snapshotTg.isNotEmpty) ...snapshotTg,
      ...liveFolder,
    ];
  }

  /// Prefer fresher tip + higher unread from the durable snapshot while the
  /// first live pages are still catching up (official TG: local DB first).
  List<Map<String, dynamic>> _softBlendLiveWithSnapshot(
    List<Map<String, dynamic>> live,
  ) {
    if (live.isEmpty || _snapshotTgRows.isEmpty) return live;
    final snapByTg = <int, Map<String, dynamic>>{};
    for (final r in _snapshotTgRows) {
      final id = (r['tdlib_chat_id'] as num?)?.toInt() ??
          chatAsInt(r['tdlib_chat_id']);
      if (id != null && id != 0) snapByTg[id] = r;
    }
    if (snapByTg.isEmpty) return live;
    return [
      for (final row in live) _blendOneLiveRow(row, snapByTg),
    ];
  }

  Map<String, dynamic> _blendOneLiveRow(
    Map<String, dynamic> live,
    Map<int, Map<String, dynamic>> snapByTg,
  ) {
    final tgId = (live['tdlib_chat_id'] as num?)?.toInt() ??
        chatAsInt(live['tdlib_chat_id']);
    if (tgId == null) return live;
    final snap = snapByTg[tgId];
    if (snap == null) return live;
    final out = Map<String, dynamic>.from(live);
    final liveUnread = chatAsInt(live['unread_count']) ?? 0;
    final snapUnread = chatAsInt(snap['unread_count']) ?? 0;
    if (snapUnread > liveUnread) {
      out['unread_count'] = snapUnread;
    }
    final snapLm = snap['last_message'];
    if (snapLm is Map) {
      final snapMs = _hubRowActivityMs(snap);
      final liveMs = _hubRowActivityMs(live);
      if (snapMs > liveMs || live['last_message'] == null) {
        out['last_message'] = Map<String, dynamic>.from(snapLm);
      }
    }
    final snapTitle = snap['title']?.toString().trim() ?? '';
    final liveTitle = live['title']?.toString().trim() ?? '';
    if (snapTitle.isNotEmpty &&
        (liveTitle.isEmpty || liveTitle == 'Telegram')) {
      out['title'] = snapTitle;
    }
    return out;
  }

  int _hubRowActivityMs(Map<String, dynamic> row) {
    final lm = row['last_message'];
    if (lm is! Map) return 0;
    final raw = lm['created_at']?.toString();
    final dt = DateTime.tryParse(raw ?? '');
    if (dt != null) return dt.millisecondsSinceEpoch;
    final date = (lm['date'] as num?)?.toInt();
    if (date != null && date > 0) {
      return date > 1e12 ? date : date * 1000;
    }
    return 0;
  }

  bool _snapshotTgCoveredByLive(
    Map<String, dynamic> row,
    Set<int> liveTgIds,
  ) {
    final tgId = (row['tdlib_chat_id'] as num?)?.toInt() ??
        chatAsInt(row['tdlib_chat_id']);
    if (tgId != null && liveTgIds.contains(tgId)) return true;
    final tgUser = (row['tdlib_user_id'] as num?)?.toInt();
    if (tgUser != null && _tdlibMatches.containsKey(tgUser)) {
      final chatId = _tdlibMatches[tgUser]?.tgChatId;
      if (chatId != null && liveTgIds.contains(chatId)) return true;
    }
    return false;
  }

  /// Snapshot TG private/group already mirrored by an FC linked row.
  bool _snapshotTgCoveredByFc(
    Map<String, dynamic> row,
    Set<int> linkedTgChatIds,
  ) {
    final tgId = (row['tdlib_chat_id'] as num?)?.toInt() ??
        chatAsInt(row['tdlib_chat_id']);
    if (tgId != null && linkedTgChatIds.contains(tgId)) return true;
    if (tgId != null && _matchedTgChatIds.contains(tgId)) return true;
    final tgUser = (row['tdlib_user_id'] as num?)?.toInt();
    if (tgUser != null && _tdlibMatches.containsKey(tgUser)) return true;
    return false;
  }

  bool _snapshotTgIsArchived(
    Map<String, dynamic> row,
    TelegramTdlibService svc,
  ) {
    // Durable flag from hub SQLite — works before TDLib Ready.
    if (HubFirstPaintSnapshot.isArchivedTgRow(row)) return true;
    if (svc.phase != TdlibAuthPhase.ready) return false;
    final tgId = (row['tdlib_chat_id'] as num?)?.toInt() ??
        chatAsInt(row['tdlib_chat_id']);
    if (tgId != null && tgId != 0 && svc.isChatArchived(tgId)) return true;
    final tgUser = (row['tdlib_user_id'] as num?)?.toInt();
    if (tgUser != null) {
      final match = _tdlibMatches[tgUser];
      if (match != null &&
          match.tgChatId != 0 &&
          svc.isChatArchived(match.tgChatId)) {
        return true;
      }
    }
    return false;
  }

  /// Rows for chats that live in a TG folder (may be absent from main list).
  List<Map<String, dynamic>> _tdlibFolderEntries(int folderId) {
    if (!widget.hasIndividualPremium || !_tdlibReady) return const [];
    final svc = ref.read(telegramTdlibServiceProvider);
    final linkedTgChatIds = _fcLinkedTgChatIds();
    final out = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final chatId in svc.chatIdsInFolder(folderId)) {
      if (!seen.add(chatId)) continue;
      if (linkedTgChatIds.contains(chatId)) continue;
      if (_matchedTgChatIds.contains(chatId)) continue;
      if (svc.isSavedMessagesChat(chatId)) continue;
      final c = svc.chatPreviewById(chatId);
      if (c == null) continue;
      final isPrivate = !c.isGroup && !c.isChannel;
      if (isPrivate && _tdlibMatches.containsKey(c.userId)) {
        // Represented via matched tdlib_dm / FC DM.
        continue;
      }
      final created = c.lastMessageDate > 0
          ? DateTime.fromMillisecondsSinceEpoch(c.lastMessageDate * 1000)
              .toIso8601String()
          : null;
      out.add({
        'id': -c.chatId.abs(),
        'kind': 'tdlib_chat',
        'title': c.title,
        'tdlib_chat_id': c.chatId,
        if (!c.isGroup && !c.isChannel) 'tdlib_user_id': c.userId,
        'tdlib_photo_path': c.photoLocalPath,
        'tdlib_photo_bytes': c.photoMinithumbnailBytes,
        'tdlib_photo_file_id': c.photoFileId,
        'notifications_enabled': !svc.isChatMuted(c.chatId),
        'unread_count': c.unreadCount,
        'last_message': {
          'body': c.lastMessageText,
          if (created != null) 'created_at': created,
          if (c.lastMessageReadStatus != null)
            'read_status': c.lastMessageReadStatus,
          if (c.lastMessageOutgoing) 'is_mine': true,
        },
      });
    }
    return out;
  }

  bool _chipIncludesTelegramList(HubChip chip) {
    if (chip.isCustom || chip.isTelegramFolder) return true;
    return chip.system == ChatHubSystemFilter.all;
  }

  List<Map<String, dynamic>> _filteredBy(HubChip chip) {
    final q = _searchQuery.trim().toLowerCase();
    final merged = _hubMergedThreads(
      includeTelegramList: _chipIncludesTelegramList(chip),
      tgFolderId: chip.tgFolderId,
    );
    final seenKeys = <String>{};
    final filtered = <Map<String, dynamic>>[];
    for (final raw in merged) {
      final t = _enrichFcDmWithMatchedTg(raw);
      // One row per person: FC DM (send modes) wins over synthetic tdlib_dm.
      if (_isHiddenTdlibDuplicate(t)) continue;
      if (!_matchesChip(t, chip)) continue;
      // Archived TG chats live only inside «Архив чатов» (like official TG).
      // Folder tabs may still show them if the folder includes them.
      if (chip.system == ChatHubSystemFilter.all && _isHubRowInTgArchive(t)) {
        continue;
      }
      final dedupe = ChatFolderMemberKey.forHubRow(t) ??
          '${t['kind']}:${t['id']}';
      if (!seenKeys.add(dedupe)) continue;
      if (q.isNotEmpty) {
        final title = t['title']?.toString().toLowerCase() ?? '';
        final defaultTitle = t['default_title']?.toString().toLowerCase() ?? '';
        if (!title.contains(q) && !defaultTitle.contains(q)) continue;
      }
      filtered.add(t);
    }
    // System Archive row — only on «Все», not while searching.
    if (chip.system == ChatHubSystemFilter.all && q.isEmpty) {
      final archive = _archiveHubRow();
      if (archive != null) filtered.add(archive);
    }
    return _sortedThreads(filtered);
  }

  /// Whether this hub row should contribute to folder / tab unread badges.
  bool _threadNotificationsEnabled(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString();
    final snapOn = thread['notifications_enabled'] as bool?;
    if (_isTdlibHubKind(kind)) {
      final chatId = (thread['tdlib_chat_id'] as num?)?.toInt();
      if (chatId != null) {
        final muted =
            ref.read(telegramTdlibServiceProvider).isChatMutedIfKnown(chatId);
        // Prefer live mute once known; until then keep first-paint snapshot
        // so muted rows don't flash blue on cold start.
        if (muted != null) return !muted;
      }
      return snapOn ?? true;
    }
    final fcOn = snapOn ?? true;
    if (!fcOn) return false;
    // Matched FC DM: honor Telegram mute so the row stays gray and is
    // excluded from folder totals even when FC notifications_enabled is true.
    final peer = _dmPeerUserId(thread);
    if (peer != null && peer > 0) {
      final svc = ref.read(telegramTdlibServiceProvider);
      for (final m in _tdlibMatches.values) {
        if (m.fcUserId != peer || m.tgChatId == 0) continue;
        final muted = svc.isChatMutedIfKnown(m.tgChatId);
        if (muted == true) return false;
        if (muted == false) return true;
        break;
      }
    }
    return fcOn;
  }

  /// Unread total for a folder chip: unmuted chats only (no search filter).
  int _notifiedUnreadForChip(HubChip chip) {
    if (chip.system == ChatHubSystemFilter.telegram) {
      // Folder is only visible while disconnected — no TG unread yet.
      return 0;
    }
    var total = 0;
    final merged = _hubMergedThreads(
      includeTelegramList: _chipIncludesTelegramList(chip),
      tgFolderId: chip.tgFolderId,
    );
    final seen = <String>{};
    for (final raw in merged) {
      final t = _enrichFcDmWithMatchedTg(raw);
      if (_isHiddenTdlibDuplicate(t)) continue;
      if (!_matchesChip(t, chip)) continue;
      if (chip.system == ChatHubSystemFilter.all && _isHubRowInTgArchive(t)) {
        continue;
      }
      final dedupe = ChatFolderMemberKey.forHubRow(t) ??
          '${t['kind']}:${t['id']}';
      if (!seen.add(dedupe)) continue;
      if (!_threadNotificationsEnabled(t)) continue;
      total += chatAsInt(t['unread_count']) ?? 0;
    }
    return total;
  }

  String _preview(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    return chatMessagePreviewText(last);
  }

  /// Статус только для своих последних сообщений (сервер кладёт read_status).
  String? _lastMessageReadStatus(Map<String, dynamic>? last) {
    if (last == null || last['is_system'] == true) return null;
    if (last['is_mine'] == false) return null;
    final status = last['read_status']?.toString().trim();
    if (status == null || status.isEmpty) return null;
    return status;
  }

  List<int> _participantIdsOf(Map<String, dynamic> thread) {
    return (thread['participant_user_ids'] as List?)
            ?.map((e) => e is int ? e : int.tryParse('$e'))
            .whereType<int>()
            .toList() ??
        const [];
  }

  Future<void> _openThread(Map<String, dynamic> thread) async {
    if (_isTdlibHubKind(thread['kind']?.toString())) {
      final chatId = (thread['tdlib_chat_id'] as num?)?.toInt();
      if (chatId == null) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TelegramConversationScreen(
            chatId: chatId,
            title: thread['title']?.toString() ?? 'Telegram',
            tgUserId: (thread['tdlib_user_id'] as num?)?.toInt(),
            fcUserId: (thread['peer_user_id'] as num?)?.toInt(),
            peerAvatarUrl: _dmAvatarUrl(thread) ?? '',
          ),
        ),
      );
      await _reloadTdlibMatches();
      return;
    }

    // Matched FC↔TG DM: always open TG when Ready — FC transcript is the
    // secretary bridge archive; live chat (and hub tip after enrich) is TG.
    // Do not gate on tgAhead: enrich write-back equalizes timestamps and used
    // to fall through to FC-only history (Киса: «пропали сообщения ТГ»).
    final matchedTg = _matchedTgOpenTarget(thread);
    if (matchedTg != null) {
      final fcThreadId = (thread['id'] as num?)?.toInt();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TelegramConversationScreen(
            chatId: matchedTg.chatId,
            title: thread['title']?.toString() ?? 'Telegram',
            tgUserId: matchedTg.tgUserId,
            fcUserId: _dmPeerUserId(thread),
            fcThreadId: (fcThreadId != null && fcThreadId > 0)
                ? fcThreadId
                : null,
            peerAvatarUrl: _dmAvatarUrl(thread) ?? '',
          ),
        ),
      );
      await _reloadTdlibMatches();
      return;
    }

    // FC «Избранное» linked to TG Saved Messages — open the TDLib chat so
    // GIF / stickers / PDF render (the text bridge only stores placeholders).
    if (thread['kind']?.toString() == 'saved') {
      final tgChatId = _savedMessagesTgChatId(thread);
      if (tgChatId != null) {
        final svc = ref.read(telegramTdlibServiceProvider);
        final fcThreadId = (thread['id'] as num?)?.toInt();
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TelegramConversationScreen(
              chatId: tgChatId,
              title: thread['title']?.toString() ?? 'Избранное',
              tgUserId: svc.myUserId,
              fcThreadId: (fcThreadId != null && fcThreadId > 0)
                  ? fcThreadId
                  : null,
            ),
          ),
        );
        await refresh();
        return;
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatConversationScreen(
          threadId: thread['id'] as int,
          title: thread['title']?.toString() ?? 'Чат',
          defaultTitle: thread['default_title']?.toString() ??
              thread['title']?.toString() ??
              'Чат',
          customTitle: thread['custom_title']?.toString() ?? '',
          kind: thread['kind']?.toString() ?? 'family',
          peerUserId: thread['peer_user_id'] as int?,
          initialHasLeft: thread['has_left'] == true,
          initialCanRejoin: thread['can_rejoin'] == true,
          initialCanLeave: thread['can_leave'] == true,
          initialParticipantUserIds: _participantIdsOf(thread),
          initialIsBirthdayCelebration: thread['is_birthday_celebration'] == true,
          initialPeerAvatarUrl: _dmAvatarUrl(thread),
          initialCanSend: thread['can_send'] != false,
          expectedLastMessageId: () {
            final last = thread['last_message'];
            if (last is Map) {
              final id = last['id'];
              if (id is int) return id;
              return int.tryParse('$id');
            }
            return null;
          }(),
        ),
      ),
    );
    await refresh();
  }

  /// Matched FC↔TG DM → open the TG chat (live transcript), not FC archive.
  ({int chatId, int? tgUserId})? _matchedTgOpenTarget(
    Map<String, dynamic> thread,
  ) {
    final kind = thread['kind']?.toString() ?? '';
    if (kind != 'dm' && kind != 'friend_dm') return null;
    if (!widget.hasIndividualPremium) return null;
    final peer = _dmPeerUserId(thread);
    if (peer == null || peer <= 0) return null;
    TelegramMatch? match;
    for (final m in _tdlibMatches.values) {
      if (m.fcUserId == peer && m.tgChatId != 0) {
        match = m;
        break;
      }
    }
    var tgChatId = match?.tgChatId ?? 0;
    var tgUserId = match?.tgUserId;
    // Server-linked FC DM even when MatchStore is still empty.
    if (tgChatId == 0) {
      final tg = thread['telegram'];
      if (tg is Map && tg['linked'] == true) {
        tgChatId = (tg['tg_chat_id'] as num?)?.toInt() ??
            int.tryParse('${tg['tg_chat_id'] ?? ''}') ??
            0;
      }
    }
    if (tgChatId == 0) return null;
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase != TdlibAuthPhase.ready) return null;
    // Prefer a known chat row, but linked tg_chat_id is enough to open.
    final preview = svc.chatPreviewById(tgChatId);
    if (preview == null && match == null) return null;
    if (tgUserId == null &&
        preview != null &&
        !preview.isGroup &&
        !preview.isChannel &&
        preview.userId > 0) {
      tgUserId = preview.userId;
    }
    return (chatId: tgChatId, tgUserId: tgUserId);
  }

  int? _savedMessagesTgChatId(Map<String, dynamic> thread) {
    final tg = thread['telegram'];
    if (tg is! Map) return null;
    if (tg['linked'] != true && tg['saved_messages'] != true) return null;
    final id = (tg['tg_chat_id'] as num?)?.toInt() ??
        int.tryParse('${tg['tg_chat_id'] ?? ''}');
    if (id == null || id == 0) return null;
    return id;
  }

  Future<void> createGroup() async {
    final created = await Navigator.of(context, rootNavigator: true)
        .push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
    );
    if (created != null && mounted) {
      await _openThread(created);
      return;
    }
    await refresh();
  }

  Future<void> _onHubMenuAction(String action) async {
    if (action == 'group') {
      await createGroup();
    } else if (action == 'folder') {
      await _createFolderFlow();
    } else if (action == 'rename') {
      await _renameSelectedFolder();
    } else if (action == 'proxy') {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const TelegramProxySettingsScreen(),
        ),
      );
    }
  }

  List<PopupMenuEntry<String>> _hubOverflowMenuItems() {
    final canManageFolder =
        _selectedChip.isCustom || _selectedChip.isTelegramFolder;
    return [
      const PopupMenuItem(
        value: 'group',
        child: _HubOverflowMenuRow(
          icon: LucideIcons.users,
          label: 'Создать группу',
        ),
      ),
      const PopupMenuItem(
        value: 'folder',
        child: _HubOverflowMenuRow(
          icon: LucideIcons.folder_plus,
          label: 'Создать папку',
        ),
      ),
      if (_tdlibReady)
        const PopupMenuItem(
          value: 'proxy',
          child: _HubOverflowMenuRow(
            icon: LucideIcons.shield,
            label: 'Прокси',
          ),
        ),
      if (canManageFolder) ...[
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'rename',
          child: _HubOverflowMenuRow(
            icon: LucideIcons.pencil,
            label: 'Переименовать папку',
          ),
        ),
      ],
    ];
  }

  Future<void> _renameSelectedFolder() async {
    final selected = _selectedChip;
    final currentName = selected.folderName ?? selected.label;
    final name = await _promptFolderName(
      initial: currentName,
      title: 'Переименовать папку',
      confirmLabel: 'Сохранить',
    );
    if (name == null || !mounted) return;
    try {
      if (selected.isCustom && selected.folderId != null) {
        await ref.read(familychatRepositoryProvider).updateChatFolder(
              selected.folderId!,
              name: name,
            );
        final tgId = _fcToTgFolder[selected.folderId!];
        if (tgId != null && _tdlibReady) {
          await ref
              .read(telegramTdlibServiceProvider)
              .renameChatFolder(tgId, name);
        }
        await _loadCustomFolders();
      } else if (selected.isTelegramFolder && selected.tgFolderId != null) {
        await ref
            .read(telegramTdlibServiceProvider)
            .renameChatFolder(selected.tgFolderId!, name);
        _rebuildChips(
          preferSelected: HubChip.telegram(
            id: selected.tgFolderId!,
            name: name,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось переименовать: $e')),
      );
    }
  }

  Future<void> _deleteFolderChip(HubChip chip) async {
    if (!chip.isCustom && !chip.isTelegramFolder) return;
    unawaited(HubFolderMuteStore.clear(chip.key));
    final label = chip.folderName ?? chip.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить папку?'),
        content: Text('Папка «$label» будет удалена. Чаты останутся.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (chip.isCustom && chip.folderId != null) {
        final fcId = chip.folderId!;
        final tgId = _fcToTgFolder[fcId];
        await ref.read(familychatRepositoryProvider).deleteChatFolder(fcId);
        if (tgId != null && _tdlibReady) {
          try {
            await ref.read(telegramTdlibServiceProvider).deleteChatFolder(tgId);
          } catch (_) {}
          await ChatHubFolderMirrorStore.unlinkFc(fcId);
          setState(() {
            _fcToTgFolder = Map<int, int>.from(_fcToTgFolder)..remove(fcId);
          });
        }
        await _loadCustomFolders();
      } else if (chip.isTelegramFolder && chip.tgFolderId != null) {
        final tgId = chip.tgFolderId!;
        await ref.read(telegramTdlibServiceProvider).deleteChatFolder(tgId);
        await ChatHubFolderMirrorStore.clearTgExtras(tgId);
        await ChatHubFolderMirrorStore.unlinkTg(tgId);
        setState(() {
          _tgFolderExtras = Map<int, Set<String>>.from(_tgFolderExtras)
            ..remove(tgId);
          _fcToTgFolder = {
            for (final e in _fcToTgFolder.entries)
              if (e.value != tgId) e.key: e.value,
          };
        });
        _rebuildChips(
          preferSelected: const HubChip.system(ChatHubSystemFilter.all),
        );
        if (!_folderReorderMode) {
          unawaited(_persistTabOrder());
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить: $e')),
      );
    }
  }

  String _emptyLabel(HubChip chip) {
    if (_searchQuery.trim().isNotEmpty) {
      if (_tgSearchLoading) return 'Поиск в Telegram…';
      return 'Ничего не найдено';
    }
    if (chip.isCustom || chip.isTelegramFolder) {
      return 'В папке пока нет чатов';
    }
    return switch (chip.system!) {
      ChatHubSystemFilter.all => 'Нет чатов',
      ChatHubSystemFilter.family => 'Нет семейных чатов',
      ChatHubSystemFilter.telegram => 'Нет чатов Telegram',
    };
  }

  /// Visible TG rows on the main hub (Все / custom folders) — TelegramChatsPane
  /// has its own prefetch; this covers the merged list where blunt minithumbs
  /// otherwise stay forever.
  /// Chat ids in the current viewport that still show minithumb / need download.
  List<int> _hubAvatarNeedSharpIds(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const [];
    // Prefetch the viewport (+ a few below), NOT the top of the full list —
    // scrolling to older rows left minithumbs forever while the queue burned
    // on already-offscreen chats (or cooldown give-ups at the head).
    const rowExtent = 72.0;
    final first =
        (_hubListScrollPixels / rowExtent).floor().clamp(0, rows.length - 1);
    final window = rows.skip(first).take(28);
    final needSharp = <int>[];
    for (final t in window) {
      final kind = t['kind']?.toString() ?? '';
      final isTdlibRow = kind == 'tdlib_chat' || kind == 'tdlib_dm';
      // Matched FC DM without FC avatar may carry tdlib_chat_id for TG fallback.
      if (!isTdlibRow && _hasFcPeerAvatar(t)) continue;
      final id = chatAsInt(t['tdlib_chat_id']);
      if (id == null || id == 0) continue;
      // Already have a local path painted — don't re-enter prefetch every
      // ScrollEnd (FakeTLS slot=1 + notify per done hitch scroll).
      final existingPath = t['tdlib_photo_path']?.toString().trim() ?? '';
      if (existingPath.isNotEmpty) continue;
      final bytes = t['tdlib_photo_bytes'];
      final hasMini = bytes is List && bytes.isNotEmpty;
      final photoFileId = chatAsInt(t['tdlib_photo_file_id']);
      final hasPhotoId = photoFileId != null && photoFileId > 0;
      // photoFileId is the preferred size (big). Soft minithumb alone still
      // queues until a path lands — then we skip (above).
      if (!hasMini && !hasPhotoId) continue;
      needSharp.add(id);
      if (needSharp.length >= 16) break;
    }
    return needSharp;
  }

  void _scheduleHubAvatarPrefetch(List<Map<String, dynamic>> rows) {
    if (!widget.hasIndividualPremium || !_tdlibReady) return;
    final after = _hubAvatarPrefetchAfter;
    if (after != null && DateTime.now().isBefore(after)) {
      final wait = after.difference(DateTime.now()) +
          const Duration(milliseconds: 50);
      _hubAvatarPrefetchTimer?.cancel();
      _hubAvatarPrefetchTimer = Timer(wait, () {
        if (!mounted) return;
        _scheduleHubAvatarPrefetch(rows);
      });
      return;
    }
    final tdlib = ref.read(telegramTdlibServiceProvider);
    // Never fight a fling — avatar getChat/download mid-ballistic is the
    // classic hub "stutter then catch up" feel. Retry once scroll settles.
    if (tdlib.isUiScrollBusy) {
      _hubAvatarPrefetchTimer?.cancel();
      _hubAvatarPrefetchTimer = Timer(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        _scheduleHubAvatarPrefetch(rows);
      });
      return;
    }
    final needSharp = _hubAvatarNeedSharpIds(rows);
    if (needSharp.isEmpty) return;
    tdlib.prefetchVisibleHubAvatars(needSharp);
  }

  void _debounceHubAvatarPrefetch(List<Map<String, dynamic>> rows) {
    _hubAvatarPrefetchTimer?.cancel();
    // After scroll-end wait longer so FakeTLS getFile/download can't race
    // the next fling (SessionLog 20:54 Skipped 1950).
    _hubAvatarPrefetchTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      _scheduleHubAvatarPrefetch(rows);
    });
  }

  Widget _buildFilterPage(HubChip chip) {
    if (chip.system == ChatHubSystemFilter.telegram) {
      return Padding(
        padding: const EdgeInsets.only(top: _ChatFilterTabBar.overlayExtent),
        child: TelegramChatsPane(
          hasIndividualPremium: widget.hasIndividualPremium,
          telegramConnected: widget.telegramConnected,
          telegramGrace: widget.telegramGrace,
          searchQuery: _searchQuery,
          globalHits: _tgSearchHits,
          globalLoading: _tgSearchLoading,
          onOpenGlobalHit: _openTgGlobalHit,
        ),
      );
    }
    return _buildThreadList(chip);
  }

  Widget _buildThreadList(HubChip chip) {
    final filtered = _filteredBy(chip);
    final searching = _searchQuery.trim().isNotEmpty;
    final tgExtra = searching ? _tgHitsNotInLocal(filtered) : const <TdlibGlobalSearchHit>[];
    final showTgSection = searching &&
        widget.hasIndividualPremium &&
        _tdlibReady &&
        (_tgSearchLoading || tgExtra.isNotEmpty);
    final listPadding = EdgeInsets.only(
      top: _ChatFilterTabBar.overlayExtent,
      bottom: ShellNavBar.contentBottomInset(
        context,
        showLabels: ref.watch(appSettingsProvider).menuLabels,
      ),
    );

    if (_showHubSkeleton) {
      return const ChatHubListSkeleton();
    }

    // Prefetch when the visible muddy set changes — NOT on every rebuild
    // (ref.watch TDLib used to re-fire this every last-message tick and
    // mid-scroll). Key includes:
    // - mediaReadyEpoch: Connecting→Ready re-queues skipped avatars
    // - needSig: minithumbs that appear AFTER first paint (chat photo
    //   metadata arrives late) must invalidate the key or they stay muddy
    //   forever with no ScrollEnd.
    // - tg search hits: global rows are not in [filtered] but still need wire.
    if (identical(chip, _selectedChip) || chip.key == _selectedChip.key) {
      final mediaEpoch = ref
          .read(telegramTdlibServiceProvider)
          .mediaReadyEpoch;
      final needIds = _hubAvatarNeedSharpIds(filtered);
      final needSig = needIds.isEmpty ? '0' : needIds.join(',');
      final tgSig = tgExtra.isEmpty
          ? '0'
          : tgExtra.map((h) => h.chatId).join(',');
      final prefetchKey =
          '${chip.key}:m$mediaEpoch:need=$needSig:tg=$tgSig:${filtered.length}';
      if (prefetchKey != _lastHubAvatarPrefetchKey) {
        _lastHubAvatarPrefetchKey = prefetchKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _debounceHubAvatarPrefetch(filtered);
          if (tgExtra.isNotEmpty) {
            _scheduleTgSearchAvatarPrefetch(tgExtra);
          }
        });
      }
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final localCount = filtered.length;
    final tgHeaderSlots = showTgSection ? 1 : 0;
    final tgLoadingSlots =
        showTgSection && _tgSearchLoading && tgExtra.isEmpty ? 1 : 0;
    final totalCount =
        localCount + tgHeaderSlots + tgExtra.length + tgLoadingSlots;
    final listEmpty = totalCount == 0;

    return RefreshIndicator(
      onRefresh: () => refresh(silent: false),
      child: listEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: listPadding,
              children: [
                const SizedBox(height: 120),
                Center(child: Text(_emptyLabel(chip))),
              ],
            )
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification) {
                  _hubListScrollPixels = n.metrics.pixels;
                  ref
                      .read(telegramTdlibServiceProvider)
                      .setUiScrollBusy(true);
                  _hubScrollBusyClearTimer?.cancel();
                  _hubScrollBusyClearTimer = Timer(
                    const Duration(milliseconds: 420),
                    () {
                      if (!mounted) return;
                      ref
                          .read(telegramTdlibServiceProvider)
                          .setUiScrollBusy(false);
                    },
                  );
                  // Do NOT prefetch on every drag tick — that queued getChat
                  // for missing avatars and hitching ballistic fling.
                } else if (n is ScrollEndNotification) {
                  _hubListScrollPixels = n.metrics.pixels;
                  _debounceHubAvatarPrefetch(filtered);
                  _hubScrollBusyClearTimer?.cancel();
                  _hubScrollBusyClearTimer = Timer(
                    const Duration(milliseconds: 600),
                    () {
                      if (!mounted) return;
                      ref
                          .read(telegramTdlibServiceProvider)
                          .setUiScrollBusy(false);
                    },
                  );
                }
                return false;
              },
              child: ListView.builder(
              key: PageStorageKey<String>('chat-hub-${chip.key}'),
              physics: const AlwaysScrollableScrollPhysics(),
              // Keep a modest cache — huge cacheExtent + avatar decodes
              // during fling was a source of hitch.
              cacheExtent: 480,
              padding: listPadding,
              itemCount: totalCount,
              itemBuilder: (context, i) {
                if (i >= localCount) {
                  var gi = i - localCount;
                  if (showTgSection) {
                    if (gi == 0) {
                      return _tgGlobalSearchHeader(theme, scheme);
                    }
                    gi -= 1;
                  }
                  if (gi < tgExtra.length) {
                    return _tgGlobalSearchTile(
                      tgExtra[gi],
                      theme: theme,
                      scheme: scheme,
                    );
                  }
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final t = filtered[i];
                final title = t['title']?.toString() ?? 'Чат';
                final kind = t['kind']?.toString() ?? '';
                if (kind == 'tdlib_archive') {
                  return _buildArchiveHubTile(
                    t,
                    theme: theme,
                    scheme: scheme,
                  );
                }
                final unread = chatAsInt(t['unread_count']) ?? 0;
                final notificationsOn = _threadNotificationsEnabled(t);
                final last = t['last_message'] as Map<String, dynamic>?;
                final isSaved = isSavedMessagesThread(kind);
                final lastStatus = _lastMessageReadStatus(last);
                final created = last != null
                    ? DateTime.tryParse(last['created_at']?.toString() ?? '')
                    : null;
                final isBirthday = _isBirthdayCelebration(t);
                final avatarAsset = chatThreadAvatarAsset(
                  kind: kind,
                  isBirthdayCelebration: isBirthday,
                );
                final previewStyle = theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                );
                final timeStyle = theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                );
                // Neutral gray — scheme.onSurface / onSurfaceVariant inherit the
                // blue seed and read as "active" next to the mute icon.
                final unreadBadgeColor = notificationsOn
                    ? scheme.primary
                    : const Color(0xFFB0B0B0);
                final tdlibPhotoPath = t['tdlib_photo_path']?.toString();
                final tdlibPhotoBytes = t['tdlib_photo_bytes'];
                final rowKey = ChatFolderMemberKey.forHubRow(t);
                final isSelected =
                    rowKey != null && _selectedKeys.contains(rowKey);
                final isPinned = rowKey != null && _pinnedOrder.contains(rowKey);
                final fcAvatarUrl =
                    avatarAsset != null ? null : _dmAvatarUrl(t);
                // FC photo wins; TG local/mini only when FC has none
                // (ChatAvatar prefers localFilePath over avatarUrl).
                final useTgPhoto =
                    fcAvatarUrl == null || fcAvatarUrl.isEmpty;

                final avatar = isSaved
                    ? const SavedMessagesAvatar(radius: 24)
                    : ChatAvatar(
                        key: ValueKey<String>(
                          'hub-av-${t['id']}-'
                          '${useTgPhoto ? (tdlibPhotoPath ?? '') : (fcAvatarUrl ?? '')}-'
                          '${useTgPhoto && tdlibPhotoBytes is List ? (tdlibPhotoBytes as List).length : 0}',
                        ),
                        name: _avatarName(t),
                        avatarUrl: fcAvatarUrl,
                        userId:
                            avatarAsset != null ? null : _dmPeerUserId(t),
                        assetPath: avatarAsset,
                        localFilePath: useTgPhoto ? tdlibPhotoPath : null,
                        memoryBytes: useTgPhoto && tdlibPhotoBytes is List<int>
                            ? tdlibPhotoBytes
                            : null,
                        radius: 24,
                      );

                return ListTile(
                  key: ValueKey(t['id']),
                  selected: isSelected,
                  selectedTileColor:
                      scheme.primaryContainer.withValues(alpha: 0.35),
                  leading: SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        avatar,
                        if (_selectionMode)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? scheme.primary
                                    : scheme.surface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? scheme.primary
                                      : scheme.outline,
                                  width: 2,
                                ),
                              ),
                              child: isSelected
                                  ? Icon(
                                      LucideIcons.check,
                                      size: 12,
                                      color: scheme.onPrimary,
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight:
                                unread > 0 ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (isPinned) ...[
                        const SizedBox(width: 6),
                        Icon(
                          LucideIcons.pin,
                          size: 14,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (lastStatus != null) ...[
                                ChatMessageReadStatusIcon(
                                  status: lastStatus,
                                  color: scheme.onSurfaceVariant,
                                  size: 15,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  _preview(t),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: previewStyle,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (created != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            formatChatHubLastMessageTime(created),
                            style: timeStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: unread > 0
                      ? CircleAvatar(
                          radius: 10,
                          backgroundColor: unreadBadgeColor,
                          child: Text(
                            '$unread',
                            style: TextStyle(
                              color: notificationsOn
                                  ? scheme.onPrimary
                                  : scheme.surface,
                              fontSize: 11,
                            ),
                          ),
                        )
                      : null,
                  onTap: () {
                    if (_selectionMode) {
                      _toggleThreadSelection(t);
                    } else {
                      _openThread(t);
                    }
                  },
                  onLongPress: () {
                    if (_selectionMode) {
                      _toggleThreadSelection(t);
                    } else {
                      unawaited(_onThreadLongPress(t));
                    }
                  },
                );
              },
            ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Rebuild list + folder badges whenever TDLib chat/mute/unread changes.
    // (A nested Builder-only watch would leave TabBarView stale.)
    final tdlib = ref.watch(telegramTdlibServiceProvider);
    // Never setState during build — reveal on the next frame.
    if (_pendingFirstPaint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _tryFirstPaintReveal(tdlib);
      });
    } else if (_paintedFromSnapshot) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Frame-0 may be FC-only — pull TG from durable snapshot while
        // waiting for live hydrate (do not wait for release).
        if (_snapshotTgRows.isEmpty) {
          unawaited(_restoreSnapshotTgFallbackIfNeeded(tdlib));
        }
        _releaseSnapshotOverlayIfReady(tdlib);
      });
    } else if (!_liveTgListReady(tdlib)) {
      // Soft-restart cleared live chats — restore snapshot TG if needed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_restoreSnapshotTgFallbackIfNeeded(tdlib));
      });
    } else if (tdlib.hubSurfaceReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Keep Archive cold-start rows aligned with live chatListArchive.
        if (tdlib.hasArchivedChats || tdlib.hubArchiveChats.isNotEmpty) {
          final before = _snapshotArchiveRows.length;
          _syncSnapshotArchiveFromLive();
          if (_snapshotArchiveRows.length != before) {
            setState(() {});
          }
        }
        _scheduleSnapshotPersist();
      });
    }
    final connected = tdlib.phase == TdlibAuthPhase.ready;
    // Warm TG folders mean «was linked» — skip the temporary «Telegram» chip
    // that used to replace the folder bar until Ready.
    final shouldShowTelegram = widget.hasIndividualPremium &&
        !connected &&
        !_chips.any((c) => c.tgFolderId != null) &&
        !HubFirstPaintSnapshot.chipsFromWarm()
            .any((c) => c.tgFolderId != null);
    final showingTelegram = _chips.any(
      (c) => c.system == ChatHubSystemFilter.telegram,
    );
    if (shouldShowTelegram != showingTelegram) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncFiltersWithPremium();
      });
    }
    final foldersEpoch = tdlib.chatFoldersEpoch;
    // While holding the first paint, defer chip rebuilds so FC folders don't
    // appear alone and then jump when TG folders arrive.
    if (!_pendingFirstPaint && foldersEpoch != _lastTgFoldersEpoch) {
      _lastTgFoldersEpoch = foldersEpoch;
      if (tdlib.phase == TdlibAuthPhase.ready) {
        _tgFoldersLiveOnce = true;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _rebuildChips(preferSelected: _selectedChip);
        // Persist chip bar as soon as live TG folders arrive (not only with
        // hub rows) so the next cold start has folders before TDLib Ready.
        unawaited(HubFirstPaintSnapshot.persistChips(_chips));
        unawaited(_pullMirroredMembershipFromTg());
        // New TG folder members may have appeared — re-apply folder mute flags.
        unawaited(_reconcileAllFolderMutes());
      });
    }

    final showHubSkeleton = _showHubSkeleton;

    return PopScope(
      canPop: !_searchVisible && !_folderReorderMode && !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelection();
          return;
        }
        if (_folderReorderMode) {
          unawaited(_finishFolderReorder());
          return;
        }
        if (_searchVisible) toggleSearch();
      },
      child: Scaffold(
        appBar: FamilyAppBar.build(
          title: _selectionMode
              ? '${_selectedKeys.length} выбрано'
              : 'Family Space',
          profileName: _selectionMode ? '' : widget.profileName,
          profileAvatarUrl: _selectionMode ? '' : widget.profileAvatarUrl,
          profileAvatarLocalPath:
              _selectionMode ? '' : widget.profileAvatarLocalPath,
          onProfileTap: _selectionMode ? null : widget.onProfileTap,
          automaticallyImplyLeading: false,
          leading: _selectionMode
              ? IconButton(
                  tooltip: 'Отменить выбор',
                  onPressed: _exitSelection,
                  icon: const Icon(LucideIcons.x),
                )
              : null,
          titleStyle: theme.textTheme.titleLarge?.copyWith(
            color: const Color(0xFF4A9ED8),
            fontWeight: FontWeight.w600,
          ),
          actions: _selectionMode
              ? [
                  IconButton(
                    tooltip: _selectionAnyNotificationsOn
                        ? 'Выключить уведомления'
                        : 'Включить уведомления',
                    onPressed: _selectedKeys.isEmpty
                        ? null
                        : () => unawaited(_muteSelectedThreads()),
                    icon: Icon(
                      _selectionAnyNotificationsOn
                          ? LucideIcons.bell_off
                          : LucideIcons.bell,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Ещё',
                    icon: const Icon(LucideIcons.ellipsis_vertical),
                    offset: const Offset(0, 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 8,
                    shadowColor: Colors.black.withValues(alpha: 0.18),
                    onSelected: (value) =>
                        unawaited(_onSelectionMenuAction(value)),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'pin',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(LucideIcons.pin),
                          title: Text('Закрепить'),
                        ),
                      ),
                      if (_selectionAnyPinned)
                        const PopupMenuItem(
                          value: 'unpin',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(LucideIcons.pin_off),
                            title: Text('Открепить'),
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'add_folder',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(LucideIcons.folder_plus),
                          title: Text('Добавить в папку'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'remove_folder',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(LucideIcons.folder_minus),
                          title: Text('Удалить из папки'),
                        ),
                      ),
                      if (_tdlibReady)
                        const PopupMenuItem(
                          value: 'archive',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(LucideIcons.archive),
                            title: Text('Добавить в Архив'),
                          ),
                        ),
                    ],
                  ),
                ]
              : _folderReorderMode
                  ? [
                      TextButton(
                        onPressed: () => unawaited(_finishFolderReorder()),
                        child: Text(
                          'ГОТОВО',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ]
                  : [
                      IconButton(
                        icon: Icon(
                          _searchVisible ? LucideIcons.x : LucideIcons.search,
                        ),
                        tooltip: _searchVisible ? 'Закрыть' : 'Поиск',
                        onPressed: toggleSearch,
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Ещё',
                        icon: const Icon(LucideIcons.ellipsis_vertical),
                        offset: const Offset(0, 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 8,
                        shadowColor: Colors.black.withValues(alpha: 0.18),
                        onSelected: (value) =>
                            unawaited(_onHubMenuAction(value)),
                        itemBuilder: (_) => _hubOverflowMenuItems(),
                      ),
                    ],
        ),
        body: Column(
          children: [
            if (_searchVisible)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Поиск чатов',
                    prefixIcon: const Icon(LucideIcons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchController.clear();
                              _onHubSearchChanged('');
                            },
                            icon: const Icon(LucideIcons.x),
                          )
                        : null,
                    isDense: true,
                  ),
                  onChanged: _onHubSearchChanged,
                ),
              ),
            Expanded(
              child: showHubSkeleton
                  ? const ColoredBox(
                      // Immediate skeleton — DeferredPlaceholder blanked 1s
                      // and made the FC→TG flash look worse.
                      color: Colors.transparent,
                      child: ChatHubListSkeleton(),
                    )
                  : Stack(
                      children: [
                        TabBarView(
                          controller: _tabController,
                          // Horizontal swipe switches folders (Все / Семья / …).
                          // Keep locked while reordering chips or multi-select.
                          physics: (_folderReorderMode || _selectionMode)
                              ? const NeverScrollableScrollPhysics()
                              : const PageScrollPhysics(),
                          children: _chips.map((chip) {
                            // Material (not ColoredBox): ListTile paints ink
                            // on the nearest Material; an opaque ColoredBox
                            // between tile and Scaffold floods debug with
                            // "ListTile background color or ink splashes may
                            // be invisible" on every hub rebuild.
                            return Material(
                              color: theme.scaffoldBackgroundColor,
                              child: _buildFilterPage(chip),
                            );
                          }).toList(),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: _ChatFilterTabBar(
                            chips: _chips,
                            controller: _tabController,
                            labelOf: _chipLabel,
                            unreadOf: _notifiedUnreadForChip,
                            mutedOf: (chip) =>
                                (chip.isCustom || chip.isTelegramFolder) &&
                                HubFolderMuteStore.isActive(chip.key),
                            reorderMode: _folderReorderMode,
                            onReorder: _onReorderTabs,
                            onChipLongPress: _showFolderChipMenu,
                            onDeleteChip: (chip) =>
                                unawaited(_deleteFolderChip(chip)),
                            muteUiEpoch: _folderMuteUiEpoch,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatFilterTabBar extends StatelessWidget {
  const _ChatFilterTabBar({
    required this.chips,
    required this.controller,
    required this.labelOf,
    required this.unreadOf,
    required this.mutedOf,
    required this.reorderMode,
    required this.onReorder,
    required this.onChipLongPress,
    required this.onDeleteChip,
    this.muteUiEpoch = 0,
  });

  final List<HubChip> chips;
  final TabController controller;
  final String Function(HubChip chip) labelOf;
  final int Function(HubChip chip) unreadOf;
  final bool Function(HubChip chip) mutedOf;
  final bool reorderMode;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(BuildContext chipContext, HubChip chip) onChipLongPress;
  final void Function(HubChip chip) onDeleteChip;
  final int muteUiEpoch;

  static const double _pillHeight = 40;
  static const EdgeInsets _outerPadding = EdgeInsets.fromLTRB(14, 8, 14, 8);

  /// Высота оверлея (отступы + таблетка), чтобы список не прятался под ней.
  static const double overlayExtent = 8 + _pillHeight + 8;

  static bool _canDeleteChip(HubChip chip) =>
      chip.isCustom || chip.isTelegramFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = Color.alphaBlend(
      scheme.onSurface.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.16 : 0.09,
      ),
      scheme.surface,
    );
    final indicatorColor = scheme.secondaryContainer;
    final selectedColor = scheme.primary;
    final unselectedColor = scheme.onSurfaceVariant;
    final count = chips.length;
    if (count == 0) return const SizedBox.shrink();

    return Padding(
      padding: _outerPadding,
      child: Material(
        type: MaterialType.transparency,
        child: Material(
          color: background,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: StadiumBorder(
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: _pillHeight,
            child: AnimatedBuilder(
              animation: Listenable.merge([
                controller,
                if (controller.animation != null) controller.animation!,
              ]),
              builder: (context, _) {
                final selectedIndex = controller.index;
                return ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  clipBehavior: Clip.hardEdge,
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) {
                        final t =
                            Curves.easeInOut.transform(animation.value);
                        return Material(
                          elevation: 2 + 4 * t,
                          color: Colors.transparent,
                          shadowColor:
                              scheme.shadow.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(20),
                          child: child,
                        );
                      },
                    );
                  },
                  onReorder: onReorder,
                  itemCount: count,
                  itemBuilder: (context, index) {
                    final chip = chips[index];
                    final selected = selectedIndex == index;
                    final unread = unreadOf(chip);
                    final muted = mutedOf(chip);
                    final showDelete =
                        reorderMode && _canDeleteChip(chip);
                    final pill = Builder(
                      key: ValueKey('hub-chip:$index:$muteUiEpoch'),
                      builder: (chipContext) {
                        return InkWell(
                          onTap: () {
                            if (controller.index != index) {
                              controller.index = index;
                            }
                          },
                          onLongPress: reorderMode
                              ? null
                              : () {
                                  if (controller.index != index) {
                                    controller.index = index;
                                  }
                                  onChipLongPress(chipContext, chip);
                                },
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          overlayColor: const WidgetStatePropertyAll(
                            Colors.transparent,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 4,
                            ),
                            child: AnimatedContainer(
                              duration: selected
                                  ? const Duration(milliseconds: 180)
                                  : Duration.zero,
                              curve: Curves.easeOut,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: ShapeDecoration(
                                color: selected
                                    ? indicatorColor
                                    : Colors.transparent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!reorderMode && muted) ...[
                                    Icon(
                                      LucideIcons.bell_off,
                                      size: 12,
                                      color: selected
                                          ? selectedColor
                                          : unselectedColor,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    labelOf(chip),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelLarge
                                        ?.copyWith(
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: selected
                                          ? selectedColor
                                          : unselectedColor,
                                    ),
                                  ),
                                  if (!reorderMode && unread > 0) ...[
                                    const SizedBox(width: 4),
                                    CircleAvatar(
                                      radius: 8,
                                      backgroundColor: scheme.primary,
                                      child: Text(
                                        unread > 99 ? '99+' : '$unread',
                                        style: TextStyle(
                                          color: scheme.onPrimary,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w600,
                                          height: 1,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (showDelete) ...[
                                    const SizedBox(width: 2),
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => onDeleteChip(chip),
                                      child: Padding(
                                        padding: const EdgeInsets.all(2),
                                        child: Icon(
                                          LucideIcons.x,
                                          size: 14,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                    if (reorderMode) {
                      return ReorderableDragStartListener(
                        key: ValueKey(chip.key),
                        index: index,
                        child: pill,
                      );
                    }
                    return KeyedSubtree(
                      key: ValueKey(chip.key),
                      child: pill,
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _HubOverflowMenuRow extends StatelessWidget {
  const _HubOverflowMenuRow({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 22, color: scheme.onSurface),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ],
    );
  }
}
