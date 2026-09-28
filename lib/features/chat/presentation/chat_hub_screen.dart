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
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/share/share_direct_target_service.dart';
import '../data/chat_local_mutations.dart';
import '../data/chat_mutation_coordinator.dart';
import '../data/chat_offline_outbox.dart';
import 'chat_conversation_screen.dart';
import 'chat_thread_avatars.dart';
import 'create_group_screen.dart';
import '../../telegram_tdlib/presentation/telegram_conversation_screen.dart';
import '../../telegram_tdlib/tdlib_chat_folder.dart';
import '../../telegram_tdlib/telegram_group_bridge.dart';
import '../../telegram_tdlib/telegram_saved_bridge.dart';
import '../../telegram_tdlib/telegram_match_store.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';
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
    this.onProfileTap,
  });

  /// Individual Premium gates TG features (folder when disconnected, rows in «Все»).
  /// friend_dm threads remain visible under «Все».
  final bool hasIndividualPremium;
  /// TDLib authorization ready (logged in). When true, «Telegram» folder is hidden.
  final bool telegramConnected;
  /// Grace после окончания Premium (read-only TG).
  final bool telegramGrace;
  final String profileName;
  final String profileAvatarUrl;
  final VoidCallback? onProfileTap;

  @override
  ConsumerState<ChatHubScreen> createState() => ChatHubScreenState();
}

class ChatHubScreenState extends ConsumerState<ChatHubScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// System chips: «Telegram» only while Premium and TDLib is not logged in.
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
  List<Map<String, dynamic>> _threads = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  Map<int, TelegramMatch> _tdlibMatches = {};
  bool _loading = true;
  bool _hubBootstrapDone = false;
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
  StreamSubscription<List<Map<String, dynamic>>>? _threadsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _membersSub;
  int _threadsEnrichGen = 0;
  bool get _localFirst => ChatSyncService.isSupported;
  Timer? _hubAvatarPrefetchTimer;
  Timer? _hubScrollBusyClearTimer;

  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
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
    unawaited(_reloadTdlibMatches());
    TelegramMatchStore.instance.revision.addListener(_onTdlibMatchesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(telegramTdlibServiceProvider).ensureStarted());
      unawaited(
        ref.read(telegramTdlibServiceProvider).reconcileFamilyIdentities(),
      );
    });
    WidgetsBinding.instance.addObserver(this);
    _chips = _systemChipsFor(
      hasIndividualPremium: widget.hasIndividualPremium,
      // Phase may already be ready from a previous session.
      telegramConnected: widget.telegramConnected ||
          ref.read(telegramTdlibServiceProvider).phase == TdlibAuthPhase.ready,
    );
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

  Future<void> _reloadTdlibMatches() async {
    final matches = await TelegramMatchStore.instance.loadAll();
    if (!mounted) return;
    setState(() => _tdlibMatches = matches);
    unawaited(
      ref.read(telegramTdlibServiceProvider).refreshMatchedTgUserIds(),
    );
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
    final linkedTgChatIds = _linkedTelegramGroupChatIds();
    final out = <Map<String, dynamic>>[];
    for (final c in svc.hubChats) {
      // Same gate as TelegramChatsPane: groups/channels always; privates only
      // if unmatched. (Channels have isGroup=false — must not use !isGroup alone.)
      final isPrivate = !c.isGroup && !c.isChannel;
      if (isPrivate && _tdlibMatches.containsKey(c.userId)) continue;
      if (linkedTgChatIds.contains(c.chatId)) continue;
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

  Set<int> _linkedTelegramGroupChatIds() {
    final out = <int>{};
    for (final t in _threads) {
      if (t['kind']?.toString() != 'group') continue;
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
    await ChatSyncService.instance.syncHub(
      prefetchMessages: true,
      force: true,
    );
    if (!mounted) return;
    final repo = ref.read(familychatRepositoryProvider);
    unawaited(ChatOfflineSync.instance.run(repo));
    _hubBootstrapDone = true;
    final threads = await ChatLocalReads.threads();
    if (!mounted) return;
    await _onThreadsUpdated(threads);
    if (!mounted || !_loading) return;
    setState(() => _loading = false);
  }

  @override
  void didUpdateWidget(covariant ChatHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hasIndividualPremium != widget.hasIndividualPremium ||
        oldWidget.telegramConnected != widget.telegramConnected) {
      _syncFiltersWithPremium();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    TelegramMatchStore.instance.revision.removeListener(_onTdlibMatchesChanged);
    _hubAvatarPrefetchTimer?.cancel();
    _hubScrollBusyClearTimer?.cancel();
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

  List<HubChip> _composeChips({List<String>? orderKeys}) {
    final system = _systemChipsFor(
      hasIndividualPremium: widget.hasIndividualPremium,
      telegramConnected: _tdlibReady || widget.telegramConnected,
    );
    final mirroredTgIds = _fcToTgFolder.values.toSet();
    final tgFolders = _tdlibReady && widget.hasIndividualPremium
        ? ref.read(telegramTdlibServiceProvider).manualChatFolders
        : const <TdlibChatFolderInfo>[];
    final custom = [
      for (final f in _customFolders)
        HubChip.custom(id: f.id, name: f.name),
    ];
    final telegram = [
      for (final f in tgFolders)
        if (!mirroredTgIds.contains(f.id))
          HubChip.telegram(id: f.id, name: f.title),
    ];
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
    });
    _rebuildChips(preferSelected: _selectedChip);
  }

  void _rebuildChips({HubChip? preferSelected}) {
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
      final folders = raw.map(ChatFolderData.fromJson).toList()
        ..sort((a, b) {
          final c = a.position.compareTo(b.position);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      setState(() => _customFolders = folders);
      _rebuildChips(preferSelected: _selectedChip);
      for (final f in folders) {
        if (f.hasUnmatchedTgMember(_matchedTgChatIds) &&
            !_fcToTgFolder.containsKey(f.id)) {
          unawaited(_ensureFcFolderMirroredToTg(f.id));
        }
      }
    } catch (_) {
      // Hub still works with system folders only.
    }
  }

  Future<void> _restoreTabOrder() async {
    final saved = await ChatHubTabOrderStorage.load();
    if (!mounted || saved == null || saved.isEmpty) return;
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
    } else if (action == 'delete') {
      await _deleteFolderChip(chip);
    }
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
    }
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
      } else if (key != null) {
        await ChatHubFolderMirrorStore.addTgExtra(
          tgFolderId: tgFolderId,
          memberKey: key,
        );
        final extras = Map<int, Set<String>>.from(_tgFolderExtras);
        extras.putIfAbsent(tgFolderId, () => <String>{}).add(key);
        setState(() => _tgFolderExtras = extras);
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
      if (_loading) setState(() => _loading = false);
      return;
    }
    final gen = ++_threadsEnrichGen;
    final enriched = _localFirst
        ? await enrichChatThreadsLastMessages(threads)
        : threads;
    if (!mounted || gen != _threadsEnrichGen) return;
    final sorted = _sortedThreads(enriched);
    final same = _threadsFingerprint(_threads) == _threadsFingerprint(sorted);
    final nextLoading = false;
    if (same && _loading == nextLoading) return;
    setState(() {
      if (!same) _threads = sorted;
      _loading = nextLoading;
    });
    unawaited(
      ShareDirectTargetService.syncFromThreads(
        sorted,
        memberByUserId: _memberByUserId,
      ),
    );
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
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshFromLocalStore());
      unawaited(_reloadTdlibMatches());
      unawaited(
        ref.read(telegramTdlibServiceProvider).reconcileFamilyIdentities(),
      );
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
    } catch (_) {
      if (!mounted || gen != _threadsEnrichGen) return;
      if (_threads.isEmpty) {
        await _hydrateFromLocalStore();
      }
      if (!mounted || gen != _threadsEnrichGen) return;
      setState(() {
        _loading = false;
      });
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
    if (match == null) return thread;
    final svc = ref.read(telegramTdlibServiceProvider);
    if (svc.phase != TdlibAuthPhase.ready) return thread;
    final preview = svc.chatPreviewById(match.tgChatId);
    if (preview == null) return thread;

    final fcUnread = chatAsInt(thread['unread_count']) ?? 0;
    final tgUnread = preview.unreadCount;
    final muted = svc.isChatMuted(match.tgChatId);
    var changed = false;
    final next = Map<String, dynamic>.from(thread);

    if (tgUnread > fcUnread) {
      next['unread_count'] = tgUnread;
      changed = true;
    }
    final tgNotifications = !muted;
    if (thread['notifications_enabled'] != tgNotifications) {
      next['notifications_enabled'] = tgNotifications;
      changed = true;
    }

    if (preview.lastMessageDate > 0) {
      final last = thread['last_message'];
      var fcMs = 0;
      if (last is Map) {
        final raw = last['created_at']?.toString() ?? '';
        final parsed = DateTime.tryParse(raw);
        if (parsed != null) fcMs = parsed.millisecondsSinceEpoch;
      }
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
      }
    }

    // FC avatar wins; if FC has none, fall back to TG chat photo.
    if (!_hasFcPeerAvatar(thread)) {
      final path = preview.photoLocalPath?.trim() ?? '';
      if (path.isNotEmpty && next['tdlib_photo_path']?.toString() != path) {
        next['tdlib_photo_path'] = path;
        changed = true;
      }
      final bytes = preview.photoMinithumbnailBytes;
      if (bytes != null &&
          bytes.isNotEmpty &&
          next['tdlib_photo_bytes'] != bytes) {
        next['tdlib_photo_bytes'] = bytes;
        changed = true;
      }
      if (next['tdlib_chat_id'] != match.tgChatId) {
        next['tdlib_chat_id'] = match.tgChatId;
        changed = true;
      }
    }

    return changed ? next : thread;
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
    return [
      ..._threads,
      ..._tdlibHubEntries(),
      if (includeTelegramList) ..._telegramListEntries(),
      if (tgFolderId != null) ..._tdlibFolderEntries(tgFolderId),
    ];
  }

  /// Rows for chats that live in a TG folder (may be absent from main list).
  List<Map<String, dynamic>> _tdlibFolderEntries(int folderId) {
    if (!widget.hasIndividualPremium || !_tdlibReady) return const [];
    final svc = ref.read(telegramTdlibServiceProvider);
    final linkedTgChatIds = _linkedTelegramGroupChatIds();
    final out = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final chatId in svc.chatIdsInFolder(folderId)) {
      if (!seen.add(chatId)) continue;
      if (linkedTgChatIds.contains(chatId)) continue;
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
    return _sortedThreads(filtered);
  }

  /// Whether this hub row should contribute to folder / tab unread badges.
  bool _threadNotificationsEnabled(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString();
    if (_isTdlibHubKind(kind)) {
      final chatId = (thread['tdlib_chat_id'] as num?)?.toInt();
      if (chatId == null) return true;
      return !ref.read(telegramTdlibServiceProvider).isChatMuted(chatId);
    }
    final fcOn = thread['notifications_enabled'] as bool? ?? true;
    if (!fcOn) return false;
    // Matched FC DM: honor Telegram mute so the row stays gray and is
    // excluded from folder totals even when FC notifications_enabled is true.
    final peer = _dmPeerUserId(thread);
    if (peer != null && peer > 0) {
      final svc = ref.read(telegramTdlibServiceProvider);
      for (final m in _tdlibMatches.values) {
        if (m.fcUserId != peer || m.tgChatId == 0) continue;
        if (svc.isChatMuted(m.tgChatId)) return false;
        break;
      }
    }
    return true;
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

    // FC «Избранное» linked to TG Saved Messages — open the TDLib chat so
    // GIF / stickers / PDF render (the text bridge only stores placeholders).
    if (thread['kind']?.toString() == 'saved') {
      final tgChatId = _savedMessagesTgChatId(thread);
      if (tgChatId != null) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TelegramConversationScreen(
              chatId: tgChatId,
              title: thread['title']?.toString() ?? 'Избранное',
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
    if (_searchQuery.trim().isNotEmpty) return 'Чаты не найдены';
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
  void _scheduleHubAvatarPrefetch(List<Map<String, dynamic>> rows) {
    if (!widget.hasIndividualPremium || !_tdlibReady) return;
    // Prefer rows that already show a soft minithumb (user sees blur) over
    // chats with no photo at all (initials — nothing to download).
    final needSharp = <int>[];
    final noPhoto = <int>[];
    for (final t in rows) {
      final kind = t['kind']?.toString() ?? '';
      final isTdlibRow = kind == 'tdlib_chat' || kind == 'tdlib_dm';
      // Matched FC DM without FC avatar may carry tdlib_chat_id for TG fallback.
      if (!isTdlibRow && _hasFcPeerAvatar(t)) continue;
      final path = t['tdlib_photo_path']?.toString().trim() ?? '';
      if (path.isNotEmpty) continue; // already have a local file
      final id = chatAsInt(t['tdlib_chat_id']);
      if (id == null || id == 0) continue;
      final bytes = t['tdlib_photo_bytes'];
      final hasMini = bytes is List && bytes.isNotEmpty;
      if (hasMini) {
        needSharp.add(id);
      } else {
        noPhoto.add(id);
      }
    }
    final ids = <int>[
      ...needSharp,
      ...noPhoto,
    ];
    if (ids.isEmpty) return;
    ref
        .read(telegramTdlibServiceProvider)
        .prefetchVisibleHubAvatars(ids.take(16));
  }

  void _debounceHubAvatarPrefetch(List<Map<String, dynamic>> rows) {
    _hubAvatarPrefetchTimer?.cancel();
    _hubAvatarPrefetchTimer = Timer(const Duration(milliseconds: 120), () {
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
        ),
      );
    }
    return _buildThreadList(chip);
  }

  Widget _buildThreadList(HubChip chip) {
    final filtered = _filteredBy(chip);
    final listPadding = EdgeInsets.only(
      top: _ChatFilterTabBar.overlayExtent,
      bottom: ShellNavBar.contentBottomInset(
        context,
        showLabels: ref.watch(appSettingsProvider).menuLabels,
      ),
    );

    if (_loading) {
      return const DeferredPlaceholder(child: ChatHubListSkeleton());
    }

    // Prefetch after first frame — only for the visible chip (TabBarView
    // also builds neighbors; don't fan out downloads on every rebuild).
    if (identical(chip, _selectedChip) || chip.key == _selectedChip.key) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _debounceHubAvatarPrefetch(filtered);
      });
    }

    return RefreshIndicator(
      onRefresh: () => refresh(silent: false),
      child: filtered.isEmpty
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
                  if (n.dragDetails != null) {
                    _debounceHubAvatarPrefetch(filtered);
                  }
                } else if (n is ScrollEndNotification) {
                  _debounceHubAvatarPrefetch(filtered);
                  _hubScrollBusyClearTimer?.cancel();
                  _hubScrollBusyClearTimer = Timer(
                    const Duration(milliseconds: 280),
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
              padding: listPadding,
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final t = filtered[i];
                final title = t['title']?.toString() ?? 'Чат';
                final kind = t['kind']?.toString() ?? '';
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
                final theme = Theme.of(context);
                final scheme = theme.colorScheme;
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
    final connected = tdlib.phase == TdlibAuthPhase.ready;
    final shouldShowTelegram = widget.hasIndividualPremium && !connected;
    final showingTelegram = _chips.any(
      (c) => c.system == ChatHubSystemFilter.telegram,
    );
    if (shouldShowTelegram != showingTelegram) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncFiltersWithPremium();
      });
    }
    final foldersEpoch = tdlib.chatFoldersEpoch;
    if (foldersEpoch != _lastTgFoldersEpoch) {
      _lastTgFoldersEpoch = foldersEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _rebuildChips(preferSelected: _selectedChip);
        unawaited(_pullMirroredMembershipFromTg());
      });
    }

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
                    hintText: _telegramFilterSelected
                        ? 'Поиск чатов Telegram'
                        : 'Поиск по названию чата',
                    prefixIcon: const Icon(LucideIcons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(LucideIcons.x),
                          )
                        : null,
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  TabBarView(
                    controller: _tabController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: _chips.map((chip) {
                      return ColoredBox(
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
                      reorderMode: _folderReorderMode,
                      onReorder: _onReorderTabs,
                      onChipLongPress: _showFolderChipMenu,
                      onDeleteChip: (chip) => unawaited(_deleteFolderChip(chip)),
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
    required this.reorderMode,
    required this.onReorder,
    required this.onChipLongPress,
    required this.onDeleteChip,
  });

  final List<HubChip> chips;
  final TabController controller;
  final String Function(HubChip chip) labelOf;
  final int Function(HubChip chip) unreadOf;
  final bool reorderMode;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(BuildContext chipContext, HubChip chip) onChipLongPress;
  final void Function(HubChip chip) onDeleteChip;

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
                    final showDelete =
                        reorderMode && _canDeleteChip(chip);
                    final pill = Builder(
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
