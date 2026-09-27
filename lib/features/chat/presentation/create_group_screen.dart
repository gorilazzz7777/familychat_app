import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../../telegram_tdlib/tdlib_config.dart';
import '../../telegram_tdlib/telegram_group_bridge.dart';
import '../../telegram_tdlib/telegram_match_store.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';

/// How a picker row relates to FamilyChat / Telegram.
enum _PickKind {
  /// FC contact without known Telegram link.
  fcOnly,

  /// FC contact that also has a TG identity/match.
  fcWithTg,

  /// Telegram private chat with no FC user.
  tgOnly,
}

class _PickCandidate {
  _PickCandidate({
    required this.key,
    required this.displayName,
    required this.kind,
    this.subtitle = '',
    this.avatarUrl = '',
    this.fcUserId,
    this.tgUserId,
  });

  final String key;
  final String displayName;
  final String subtitle;
  final String avatarUrl;
  final int? fcUserId;
  final int? tgUserId;
  final _PickKind kind;

  bool get hasFc => fcUserId != null && fcUserId! > 0;
  bool get hasTg => tgUserId != null && tgUserId! > 0;
}

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _title = TextEditingController();
  final _search = TextEditingController();
  List<_PickCandidate> _candidates = [];
  final Set<String> _selected = {};
  final Set<int> _familyUserIds = {};
  bool _loading = true;
  bool _saving = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    super.dispose();
  }

  int? _asInt(dynamic raw) {
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final status = await repo.status();
      final myId = _asInt(status['user_id']);
      final members = await repo.members();
      List<Map<String, dynamic>> friends = const [];
      try {
        friends = await repo.listFriends();
      } catch (_) {}

      final matches = await TelegramMatchStore.instance.loadAll();
      final fcToTg = <int, int>{};
      for (final m in matches.values) {
        if (m.fcUserId > 0 && m.tgUserId > 0) {
          fcToTg[m.fcUserId] = m.tgUserId;
        }
      }

      // Verified family identities (may not yet have private chat match).
      try {
        final identities = await repo.listFamilyTdlibIdentities();
        for (final row in identities) {
          final fc = _asInt(row['user_id']);
          final tg = _asInt(row['tg_user_id']);
          if (fc != null && tg != null && fc > 0 && tg > 0) {
            fcToTg.putIfAbsent(fc, () => tg);
          }
        }
      } catch (_) {}

      final byKey = <String, _PickCandidate>{};

      void addFc({
        required int userId,
        required String name,
        String subtitle = '',
        String avatar = '',
      }) {
        if (myId != null && userId == myId) return;
        final tg = fcToTg[userId];
        final kind = (tg != null && tg > 0) ? _PickKind.fcWithTg : _PickKind.fcOnly;
        final key = 'fc:$userId';
        byKey[key] = _PickCandidate(
          key: key,
          displayName: name.isNotEmpty ? name : 'Участник',
          subtitle: subtitle.isNotEmpty
              ? subtitle
              : (kind == _PickKind.fcWithTg ? 'FamilyChat · Telegram' : 'FamilyChat'),
          avatarUrl: avatar,
          fcUserId: userId,
          tgUserId: tg,
          kind: kind,
        );
      }

      for (final m in members) {
        final uid = _asInt(m['user_id']);
        if (uid == null) continue;
        addFc(
          userId: uid,
          name: m['display_name']?.toString() ?? '',
          subtitle: m['kinship_label']?.toString() ?? '',
          avatar: m['avatar_url']?.toString() ?? '',
        );
      }

      for (final f in friends) {
        final uid = _asInt(f['user_id'] ?? f['peer_user_id']);
        if (uid == null) continue;
        if (byKey.containsKey('fc:$uid')) continue;
        addFc(
          userId: uid,
          name: f['display_name']?.toString() ?? f['title']?.toString() ?? '',
          subtitle: 'Друг',
          avatar: f['avatar_url']?.toString() ?? '',
        );
      }

      final tdlib = ref.read(telegramTdlibServiceProvider);
      if (TdlibConfig.isEnabled && tdlib.isReady) {
        for (final chat in tdlib.privateChats) {
          if (chat.userId <= 0) continue;
          if (myId != null && chat.userId == tdlib.myUserId) continue;
          final match = matches[chat.userId];
          if (match != null && match.fcUserId > 0) {
            // Already represented as FC(+TG) if in members/friends; else add as fcWithTg.
            final fcKey = 'fc:${match.fcUserId}';
            if (!byKey.containsKey(fcKey)) {
              byKey[fcKey] = _PickCandidate(
                key: fcKey,
                displayName: match.displayName.isNotEmpty
                    ? match.displayName
                    : chat.title,
                subtitle: 'FamilyChat · Telegram',
                avatarUrl: match.avatarUrl,
                fcUserId: match.fcUserId,
                tgUserId: chat.userId,
                kind: _PickKind.fcWithTg,
              );
            }
            continue;
          }
          // Also skip if some FC row already claims this tg user.
          final already = byKey.values.any((c) => c.tgUserId == chat.userId);
          if (already) continue;
          final key = 'tg:${chat.userId}';
          byKey[key] = _PickCandidate(
            key: key,
            displayName: chat.title.isNotEmpty ? chat.title : 'Telegram',
            subtitle: 'Только Telegram',
            avatarUrl: chat.photoLocalPath ?? '',
            tgUserId: chat.userId,
            kind: _PickKind.tgOnly,
          );
        }
      }

      final list = byKey.values.toList()
        ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _candidates = list;
        _familyUserIds
          ..clear()
          ..addAll({
            for (final m in members)
              if (_asInt(m['user_id']) != null) _asInt(m['user_id'])!,
          });
        _loading = false;
        _hint = tdlib.isReady
            ? null
            : 'Telegram не подключён — можно создать только группу FamilyChat';
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<_PickCandidate> get _selectedCandidates => [
        for (final c in _candidates)
          if (_selected.contains(c.key)) c,
      ];

  bool get _hasFcOnlySelected =>
      _selectedCandidates.any((c) => c.kind == _PickKind.fcOnly);

  bool get _hasTgOnlySelected =>
      _selectedCandidates.any((c) => c.kind == _PickKind.tgOnly);

  bool _isBlocked(_PickCandidate c) {
    if (_selected.contains(c.key)) return false;
    if (_hasFcOnlySelected && c.kind == _PickKind.tgOnly) return true;
    if (_hasTgOnlySelected && c.kind == _PickKind.fcOnly) return true;
    return false;
  }

  bool get _allHaveTg {
    final sel = _selectedCandidates;
    if (sel.isEmpty) return false;
    return sel.every((c) => c.hasTg);
  }

  bool get _familyFolderEligible {
    // «Семья» only when every member is internal FC (no TG-only peers).
    return !_selectedCandidates.any((c) => c.kind == _PickKind.tgOnly);
  }

  List<_PickCandidate> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _candidates;
    return [
      for (final c in _candidates)
        if (c.displayName.toLowerCase().contains(q) ||
            c.subtitle.toLowerCase().contains(q))
          c,
    ];
  }

  Future<void> _create() async {
    final name = _title.text.trim();
    final selected = _selectedCandidates;
    if (name.isEmpty || selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Укажите название и участников')),
      );
      return;
    }

    // FC group API accepts family members only.
    final fcMemberIds = <int>{
      for (final c in selected)
        if (c.fcUserId != null &&
            c.fcUserId! > 0 &&
            _familyUserIds.contains(c.fcUserId))
          c.fcUserId!,
    };
    if (fcMemberIds.isEmpty && !_allHaveTg) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Выберите участников семьи FamilyChat, '
            'или контакты Telegram (связанная группа)',
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(familychatRepositoryProvider);
    final tdlib = ref.read(telegramTdlibServiceProvider);

    try {
      var thread = await repo.createGroupChat(
        title: name,
        memberUserIds: fcMemberIds.toList(),
      );

      final threadId = _asInt(thread['id']);
      String? tgWarning;

      if (_allHaveTg &&
          TdlibConfig.isEnabled &&
          tdlib.isReady &&
          threadId != null) {
        final tgUserIds = <int>{
          for (final c in selected)
            if (c.tgUserId != null && c.tgUserId! > 0) c.tgUserId!,
        };
        final tgChatId = await tdlib.createBasicGroupChat(
          title: name,
          userIds: tgUserIds.toList(),
        );
        if (tgChatId != null && tgChatId != 0) {
          try {
            final linked = await repo.linkTelegramGroup(
              threadId: threadId,
              tgChatId: tgChatId,
              chatType: 'group',
              title: name,
              familyFolderEligible: _familyFolderEligible,
            );
            final refreshed = linked['thread'];
            if (refreshed is Map) {
              thread = Map<String, dynamic>.from(refreshed);
            } else {
              thread = {
                ...thread,
                'telegram': {
                  'linked': true,
                  'owner': true,
                  'will_send_to_telegram': true,
                  'can_force_telegram': false,
                  'bridge_mode': 'tdlib',
                  'tg_chat_id': tgChatId,
                  'family_folder_eligible': _familyFolderEligible,
                },
              };
            }
            TelegramGroupBridge.instance.bindRepository(repo);
            TelegramGroupBridge.instance.registerLink(
              threadId: threadId,
              tgChatId: tgChatId,
            );
          } catch (e) {
            tgWarning = 'Группа FC создана, но связка с Telegram не сохранилась: $e';
          }
        } else {
          tgWarning =
              'Группа FamilyChat создана. Telegram-группу создать не удалось '
              '(проверьте прокси/сеть).';
        }
      }

      if (!mounted) return;
      if (tgWarning != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tgWarning)),
        );
      }
      Navigator.pop(context, thread);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dual = _allHaveTg && _selected.isNotEmpty;
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Новая группа',
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: 'Название группы',
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Поиск контактов',
                    ),
                  ),
                ),
                if (_hint != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _hint!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                if (_selected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        dual
                            ? 'Будет создана связанная группа FamilyChat + Telegram'
                            : 'Будет создана группа FamilyChat',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Участники'),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (context, i) {
                      final c = _filtered[i];
                      final blocked = _isBlocked(c);
                      final checked = _selected.contains(c.key);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: blocked
                            ? null
                            : (v) {
                                setState(() {
                                  if (v == true) {
                                    _selected.add(c.key);
                                  } else {
                                    _selected.remove(c.key);
                                  }
                                });
                              },
                        secondary: ChatAvatar(
                          name: c.displayName,
                          avatarUrl: (c.avatarUrl.startsWith('http') ||
                                  c.avatarUrl.startsWith('/media'))
                              ? c.avatarUrl
                              : null,
                          localFilePath: (c.avatarUrl.startsWith('/') &&
                                  !c.avatarUrl.startsWith('/media'))
                              ? c.avatarUrl
                              : null,
                          radius: 22,
                        ),
                        title: Text(
                          c.displayName,
                          style: blocked
                              ? TextStyle(
                                  color: Theme.of(context)
                                      .disabledColor,
                                )
                              : null,
                        ),
                        subtitle: Text(
                          blocked
                              ? '${c.subtitle} · недоступно для текущего выбора'
                              : c.subtitle,
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: _saving ? null : _create,
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(dual ? 'Создать связанную группу' : 'Создать'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
