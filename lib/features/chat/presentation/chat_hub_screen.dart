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
import '../data/chat_hub_last_message_time.dart';
import '../data/chat_hub_tab_order_storage.dart';
import '../data/chat_local_reads.dart';
import '../data/chat_message_preview.dart';
import '../data/chat_realtime_utils.dart';
import '../data/familychat_realtime.dart';
import '../data/chat_sync_service.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/share/share_direct_target_service.dart';
import 'chat_conversation_screen.dart';
import 'chat_thread_avatars.dart';
import 'create_group_screen.dart';
import '../../telegram_tdlib/presentation/telegram_conversation_screen.dart';
import '../../telegram_tdlib/telegram_group_bridge.dart';
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
  List<Map<String, dynamic>> _threads = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  Map<int, TelegramMatch> _tdlibMatches = {};
  bool _loading = true;
  bool _hubBootstrapDone = false;
  bool _lastKnownOnline = true;
  bool _searchVisible = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  StreamSubscription<List<Map<String, dynamic>>>? _threadsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _membersSub;
  int _threadsEnrichGen = 0;
  bool get _localFirst => ChatSyncService.isSupported;

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
    final custom = [
      for (final f in _customFolders)
        HubChip.custom(id: f.id, name: f.name),
    ];
    if (orderKeys == null || orderKeys.isEmpty) {
      return [...system, ...custom];
    }
    final byKey = <String, HubChip>{
      for (final c in [...system, ...custom]) c.key: c,
    };
    final out = <HubChip>[];
    for (final key in orderKeys) {
      final chip = byKey.remove(key);
      if (chip != null) out.add(chip);
    }
    // Remaining system first (stable), then custom by position.
    for (final c in system) {
      if (byKey.remove(c.key) != null) out.add(c);
    }
    for (final c in custom) {
      if (byKey.remove(c.key) != null) out.add(c);
    }
    return out;
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
    if (_chips[idx].system == ChatHubSystemFilter.telegram) {
      unawaited(AppActions.refreshStatus());
    } else {
      setState(() {});
    }
  }

  bool get _telegramFilterSelected {
    final idx = _tabController.index;
    return idx >= 0 &&
        idx < _chips.length &&
        _chips[idx].system == ChatHubSystemFilter.telegram;
  }

  String _chipLabel(HubChip chip) {
    if (chip.isCustom) return chip.label;
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
    unawaited(_persistTabOrder());
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
      _rebuildChips(preferSelected: chip);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать папку: $e')),
      );
    }
  }

  Future<String?> _promptFolderName({String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Новая папка'),
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
              child: const Text('Создать'),
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

  Future<void> _onThreadLongPress(Map<String, dynamic> thread) async {
    final ids = ChatFolderMemberKey.apiIds(thread);
    if (ids == null) return;
    final inFolders = _foldersContaining(thread);
    final selected = _selectedChip;
    final inCurrentCustom = selected.isCustom &&
        _customFolders.any(
          (f) => f.id == selected.folderId && f.containsHubRow(thread),
        );

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.folder_plus),
                title: const Text('Добавить в папку'),
                onTap: () => Navigator.of(ctx).pop('add'),
              ),
              if (inCurrentCustom)
                ListTile(
                  leading: const Icon(LucideIcons.folder_minus),
                  title: const Text('Удалить из папки'),
                  onTap: () => Navigator.of(ctx).pop('remove_current'),
                )
              else if (inFolders.isNotEmpty)
                ListTile(
                  leading: const Icon(LucideIcons.folder_minus),
                  title: const Text('Удалить из папки'),
                  onTap: () => Navigator.of(ctx).pop('remove_pick'),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await _pickFolderAndAdd(thread);
    } else if (action == 'remove_current' && selected.folderId != null) {
      await _removeFromFolder(selected.folderId!, thread);
    } else if (action == 'remove_pick') {
      await _pickFolderAndRemove(thread, inFolders);
    }
  }

  Future<void> _pickFolderAndAdd(Map<String, dynamic> thread) async {
    final already = {
      for (final f in _foldersContaining(thread)) f.id,
    };
    final choices = _customFolders.where((f) => !already.contains(f.id)).toList();
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
              for (final f in choices)
                ListTile(
                  leading: const Icon(LucideIcons.folder),
                  title: Text(f.name),
                  onTap: () => Navigator.of(ctx).pop(f.id),
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
        await _addToFolder(folder.id, thread);
        await _loadCustomFolders();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
      return;
    }
    if (picked is int) {
      await _addToFolder(picked, thread);
    }
  }

  Future<void> _pickFolderAndRemove(
    Map<String, dynamic> thread,
    List<ChatFolderData> folders,
  ) async {
    if (folders.length == 1) {
      await _removeFromFolder(folders.first.id, thread);
      return;
    }
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Удалить из папки')),
              for (final f in folders)
                ListTile(
                  leading: const Icon(LucideIcons.folder_minus),
                  title: Text(f.name),
                  onTap: () => Navigator.of(ctx).pop(f.id),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    await _removeFromFolder(picked, thread);
  }

  Future<void> _addToFolder(int folderId, Map<String, dynamic> thread) async {
    final ids = ChatFolderMemberKey.apiIds(thread);
    if (ids == null) return;
    try {
      await ref.read(familychatRepositoryProvider).addChatFolderMember(
            folderId,
            threadId: ids.threadId,
            tgChatId: ids.tgChatId,
          );
      await _loadCustomFolders();
      if (!mounted) return;
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

  Future<void> _removeFromFolder(int folderId, Map<String, dynamic> thread) async {
    final ids = ChatFolderMemberKey.apiIds(thread);
    if (ids == null) return;
    try {
      await ref.read(familychatRepositoryProvider).removeChatFolderMember(
            folderId,
            threadId: ids.threadId,
            tgChatId: ids.tgChatId,
          );
      await _loadCustomFolders();
      if (!mounted) return;
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
      final aSaved = isSavedMessagesThread(a['kind']?.toString()) ? 0 : 1;
      final bSaved = isSavedMessagesThread(b['kind']?.toString()) ? 0 : 1;
      if (aSaved != bSaved) return aSaved.compareTo(bSaved);
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

  List<Map<String, dynamic>> _hubMergedThreads({required bool includeTelegramList}) {
    return [
      ..._threads,
      ..._tdlibHubEntries(),
      if (includeTelegramList) ..._telegramListEntries(),
    ];
  }

  bool _chipIncludesTelegramList(HubChip chip) {
    if (chip.isCustom) return true;
    return chip.system == ChatHubSystemFilter.all;
  }

  List<Map<String, dynamic>> _filteredBy(HubChip chip) {
    final q = _searchQuery.trim().toLowerCase();
    final merged = _hubMergedThreads(
      includeTelegramList: _chipIncludesTelegramList(chip),
    );
    final filtered = merged.where((t) {
      // One row per person: FC DM (send modes) wins over synthetic tdlib_dm.
      if (_isHiddenTdlibDuplicate(t)) return false;
      if (!_matchesChip(t, chip)) return false;
      if (q.isEmpty) return true;
      final title = t['title']?.toString().toLowerCase() ?? '';
      final defaultTitle = t['default_title']?.toString().toLowerCase() ?? '';
      return title.contains(q) || defaultTitle.contains(q);
    }).toList();
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
    );
    for (final t in merged) {
      if (_isHiddenTdlibDuplicate(t)) continue;
      if (!_matchesChip(t, chip)) continue;
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

  Future<void> openCreateMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.users),
                title: const Text('Создать группу'),
                onTap: () => Navigator.of(ctx).pop('group'),
              ),
              ListTile(
                leading: const Icon(LucideIcons.folder_plus),
                title: const Text('Создать папку'),
                onTap: () => Navigator.of(ctx).pop('folder'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'group') {
      await createGroup();
    } else if (action == 'folder') {
      await _createFolderFlow();
    }
  }

  String _emptyLabel(HubChip chip) {
    if (_searchQuery.trim().isNotEmpty) return 'Чаты не найдены';
    if (chip.isCustom) return 'В папке пока нет чатов';
    return switch (chip.system!) {
      ChatHubSystemFilter.all => 'Нет чатов',
      ChatHubSystemFilter.family => 'Нет семейных чатов',
      ChatHubSystemFilter.telegram => 'Нет чатов Telegram',
    };
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
          : ListView.builder(
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

                return ListTile(
                  key: ValueKey(t['id']),
                  leading: isSaved
                      ? const SavedMessagesAvatar(radius: 24)
                      : ChatAvatar(
                          name: _avatarName(t),
                          avatarUrl:
                              avatarAsset != null ? null : _dmAvatarUrl(t),
                          userId:
                              avatarAsset != null ? null : _dmPeerUserId(t),
                          assetPath: avatarAsset,
                          localFilePath: tdlibPhotoPath,
                          memoryBytes: tdlibPhotoBytes is List<int>
                              ? tdlibPhotoBytes
                              : null,
                          radius: 24,
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
                      if (!notificationsOn) ...[
                        const SizedBox(width: 4),
                        Icon(
                          LucideIcons.bell_off,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                      if (t['telegram'] is Map &&
                          (t['telegram'] as Map)['linked'] == true) ...[
                        const SizedBox(width: 6),
                        Icon(
                          LucideIcons.send,
                          size: 14,
                          color: scheme.primary,
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
                  onTap: () => _openThread(t),
                  onLongPress: () => unawaited(_onThreadLongPress(t)),
                );
              },
            ),
    );
  }

  void _onCreatePressed() {
    unawaited(openCreateMenu());
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

    return PopScope(
      canPop: !_searchVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchVisible) toggleSearch();
      },
      child: Scaffold(
        appBar: FamilyAppBar.build(
          title: 'Family Space',
          profileName: widget.profileName,
          profileAvatarUrl: widget.profileAvatarUrl,
          onProfileTap: widget.onProfileTap,
          titleStyle: theme.textTheme.titleLarge?.copyWith(
            color: const Color(0xFF4A9ED8),
            fontWeight: FontWeight.w600,
          ),
          actions: [
            IconButton(
              icon: Icon(
                _searchVisible ? LucideIcons.x : LucideIcons.search,
              ),
              tooltip: _searchVisible ? 'Закрыть' : 'Поиск',
              onPressed: toggleSearch,
            ),
            IconButton(
              icon: const Icon(LucideIcons.plus),
              tooltip: 'Создать',
              onPressed: _onCreatePressed,
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
                      onReorder: _onReorderTabs,
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
    required this.onReorder,
  });

  final List<HubChip> chips;
  final TabController controller;
  final String Function(HubChip chip) labelOf;
  final int Function(HubChip chip) unreadOf;
  final void Function(int oldIndex, int newIndex) onReorder;

  static const double _pillHeight = 40;
  static const EdgeInsets _outerPadding = EdgeInsets.fromLTRB(14, 8, 14, 8);

  /// Высота оверлея (отступы + таблетка), чтобы список не прятался под ней.
  static const double overlayExtent = 8 + _pillHeight + 8;

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
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final slotWidth = constraints.maxWidth / count;
                      return ReorderableListView.builder(
                        scrollDirection: Axis.horizontal,
                        buildDefaultDragHandles: false,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
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
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(chip.key),
                        index: index,
                        child: SizedBox(
                          width: slotWidth,
                          child: InkWell(
                            onTap: () {
                              if (controller.index != index) {
                                controller.index = index;
                              }
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
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                decoration: ShapeDecoration(
                                  color: selected
                                      ? indicatorColor
                                      : Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        labelOf(chip),
                                        maxLines: 1,
                                        softWrap: false,
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
                                      if (unread > 0) ...[
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
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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
