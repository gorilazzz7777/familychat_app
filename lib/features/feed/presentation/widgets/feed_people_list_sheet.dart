import 'package:flutter/material.dart';

import '../../../chat/data/chat_local_reads.dart';
import '../../../members/presentation/member_profile_screen.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
import 'feed_reactions.dart';

Map<int, Map<String, dynamic>> _membersByUserId = {};
DateTime? _membersByUserIdAt;

int? feedPersonUserId(Map<String, dynamic> person) {
  return mediaReactionUserId(person['user_id']) ??
      mediaReactionUserId(person['id']);
}

String feedPersonDisplayName(Map<String, dynamic> person) {
  for (final key in const ['display_name', 'name', 'first_name']) {
    final value = person[key]?.toString().trim() ?? '';
    if (value.isNotEmpty && !_isPlaceholderPersonName(value)) return value;
  }
  final first = person['first_name']?.toString().trim() ?? '';
  final last = person['last_name']?.toString().trim() ?? '';
  final combined = [first, last].where((e) => e.isNotEmpty).join(' ');
  if (combined.isNotEmpty && !_isPlaceholderPersonName(combined)) {
    return combined;
  }
  return '';
}

bool _isPlaceholderPersonName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final lower = trimmed.toLowerCase();
  if (lower == 'участник' || lower == 'participant') return true;
  return RegExp(r'^user\s+\d+$', caseSensitive: false).hasMatch(trimmed);
}

bool _peopleNeedNames(dynamic raw) {
  if (raw is! List) return false;
  for (final item in raw) {
    if (item is! Map) continue;
    final person = Map<String, dynamic>.from(item);
    if (feedPersonUserId(person) == null) continue;
    if (feedPersonDisplayName(person).isEmpty) return true;
  }
  return false;
}

bool _reactionsNeedNames(dynamic raw) {
  if (raw is! List) return false;
  for (final item in raw) {
    if (item is! Map) continue;
    final users = item['users'];
    final ids = item['user_ids'];
    if (_peopleNeedNames(users)) return true;
    final idCount = ids is List ? ids.where((e) => mediaReactionUserId(e) != null).length : 0;
    final userCount = users is List ? users.length : 0;
    if (idCount > 0 && userCount < idCount) return true;
  }
  return false;
}

/// True when any person still resolves to the «Участник» placeholder.
bool feedPeopleHaveUnresolvedNames(List<Map<String, dynamic>> people) {
  for (final person in people) {
    if (feedPersonUserId(person) == null) continue;
    if (feedPersonDisplayName(person).isEmpty) return true;
  }
  return false;
}

/// True when a cached event still has reaction/view people without real names.
bool feedEventNeedsPeopleRefresh(Map<String, dynamic> event) {
  if (_reactionsNeedNames(event['reactions'])) return true;
  if (_peopleNeedNames(event['viewed_by'])) return true;
  final payload = event['payload'];
  if (payload is! Map) return false;
  if (_reactionsNeedNames(payload['reactions'])) return true;
  final attachments = payload['attachments'];
  if (attachments is! List) return false;
  for (final item in attachments) {
    if (item is Map && _reactionsNeedNames(item['reactions'])) return true;
  }
  return false;
}

bool _hasAvatar(Map<String, dynamic> person) =>
    (person['avatar_url']?.toString().trim() ?? '').isNotEmpty;

TextStyle? feedTappableCountStyle(ThemeData theme, {TextStyle? base}) {
  return (base ?? theme.textTheme.labelLarge)?.copyWith(
    color: theme.colorScheme.primary,
    fontWeight: FontWeight.w700,
  );
}

void _indexMembers(Iterable<Map<String, dynamic>> members) {
  for (final member in members) {
    if (member['is_child'] == true) continue;
    final id = mediaReactionUserId(member['user_id']);
    if (id == null || id <= 0) continue;
    _membersByUserId[id] = member;
  }
}

bool _membersCacheFresh() {
  final at = _membersByUserIdAt;
  if (_membersByUserId.isEmpty || at == null) return false;
  return DateTime.now().difference(at) < const Duration(minutes: 5);
}

Map<String, dynamic> _mergePerson(
  Map<String, dynamic> person,
  Map<String, dynamic>? member,
) {
  if (member == null) return person;
  final merged = Map<String, dynamic>.from(person);
  if (feedPersonDisplayName(merged).isEmpty) {
    final name = feedPersonDisplayName(member);
    if (name.isNotEmpty) merged['display_name'] = name;
  }
  if (!_hasAvatar(merged)) {
    final memberAvatar = member['avatar_url']?.toString().trim() ?? '';
    if (memberAvatar.isNotEmpty) merged['avatar_url'] = memberAvatar;
  }
  // Local family members can open a profile even on older cached payloads.
  if (merged['in_family'] != false) {
    merged['in_family'] = true;
  }
  return merged;
}

bool feedPersonCanOpenProfile(Map<String, dynamic> person) {
  if (person['in_family'] == false) return false;
  if (person['in_family'] == true) return true;
  final id = feedPersonUserId(person);
  return id != null && _membersByUserId.containsKey(id);
}

void _hydrateReactions(dynamic raw) {
  if (raw is! List) return;
  for (final item in raw) {
    if (item is! Map) continue;
    final reaction = item.cast<String, dynamic>();
    final seen = <int>{};
    final users = <Map<String, dynamic>>[];
    final rawUsers = reaction['users'];
    if (rawUsers is List) {
      for (final user in rawUsers) {
        if (user is! Map) continue;
        final map = Map<String, dynamic>.from(user);
        final id = feedPersonUserId(map);
        final merged = _mergePerson(map, id == null ? null : _membersByUserId[id]);
        final mergedId = feedPersonUserId(merged);
        if (mergedId != null) seen.add(mergedId);
        users.add(merged);
      }
    }
    final rawIds = reaction['user_ids'];
    if (rawIds is List) {
      for (final rawId in rawIds) {
        final id = mediaReactionUserId(rawId);
        if (id == null || seen.contains(id)) continue;
        seen.add(id);
        users.add(_mergePerson({'user_id': id}, _membersByUserId[id]));
      }
    }
    reaction['users'] = users;
  }
}

void _hydratePeopleList(dynamic raw) {
  if (raw is! List) return;
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) continue;
    final person = Map<String, dynamic>.from(item);
    final id = feedPersonUserId(person);
    raw[i] = _mergePerson(person, id == null ? null : _membersByUserId[id]);
  }
}

void hydrateFeedEventPeople(Map<String, dynamic> event) {
  _hydrateReactions(event['reactions']);
  _hydratePeopleList(event['viewed_by']);
  final payload = event['payload'];
  if (payload is! Map) return;
  _hydrateReactions(payload['reactions']);
  final attachments = payload['attachments'];
  if (attachments is! List) return;
  for (final item in attachments) {
    if (item is! Map) continue;
    _hydrateReactions(item['reactions']);
  }
}

Future<void> hydrateFeedEventsPeople(
  Iterable<Map<String, dynamic>> events,
) async {
  try {
    final local = await ChatLocalReads.members();
    _indexMembers(local);
    if (local.isNotEmpty) {
      _membersByUserIdAt = DateTime.now();
    }
  } catch (_) {}
  for (final event in events) {
    hydrateFeedEventPeople(event);
  }
}

Future<List<Map<String, dynamic>>> resolveFeedPeopleLocally(
  List<Map<String, dynamic>> people,
) async {
  if (people.isEmpty) return people;
  final missing = people.any((person) {
    final id = feedPersonUserId(person);
    if (id == null) return false;
    return feedPersonDisplayName(person).isEmpty || !_hasAvatar(person);
  });
  if (!missing && _membersCacheFresh()) {
    return [
      for (final person in people)
        _mergePerson(person, _membersByUserId[feedPersonUserId(person)]),
    ];
  }
  try {
    final local = await ChatLocalReads.members();
    _indexMembers(local);
    if (local.isNotEmpty) _membersByUserIdAt = DateTime.now();
  } catch (_) {}
  return [
    for (final person in people)
      _mergePerson(
        Map<String, dynamic>.from(person),
        _membersByUserId[feedPersonUserId(person)],
      ),
  ];
}

class FeedPeopleListSheet extends StatefulWidget {
  const FeedPeopleListSheet({
    super.key,
    required this.title,
    required this.people,
    this.emptyText = 'Пока никого нет',
  });

  final String title;
  final List<Map<String, dynamic>> people;
  final String emptyText;

  static Future<void> show(
    BuildContext context, {
    required String title,
    required List<Map<String, dynamic>> people,
    String emptyText = 'Пока никого нет',
    bool resolveLocally = true,
  }) async {
    final resolved =
        resolveLocally ? await resolveFeedPeopleLocally(people) : people;
    if (!context.mounted) return;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => FeedPeopleListSheet(
        title: title,
        people: resolved,
        emptyText: emptyText,
      ),
    );
  }

  @override
  State<FeedPeopleListSheet> createState() =>
      _FeedPeopleListSheetState();
}

class _FeedPeopleListSheetState extends State<FeedPeopleListSheet> {
  late List<Map<String, dynamic>> _people;
  String? _emojiFilter;

  @override
  void initState() {
    super.initState();
    _people = widget.people
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  List<String> get _emojis {
    final seen = <String>{};
    final list = <String>[];
    for (final person in _people) {
      final emoji = person['emoji']?.toString() ?? '';
      if (emoji.isEmpty || seen.contains(emoji)) continue;
      seen.add(emoji);
      list.add(emoji);
    }
    return list;
  }

  List<Map<String, dynamic>> get _visiblePeople {
    final emoji = _emojiFilter;
    if (emoji == null || emoji.isEmpty) return _people;
    return _people
        .where((p) => (p['emoji']?.toString() ?? '') == emoji)
        .toList();
  }

  void _openProfile(int userId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(userId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emojis = _emojis;
    final visible = _visiblePeople;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.55,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (emojis.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                scrollDirection: Axis.horizontal,
                children: [
                  _EmojiFilterChip(
                    label: 'Все',
                    selected: _emojiFilter == null,
                    onTap: () => setState(() => _emojiFilter = null),
                  ),
                  for (final emoji in emojis)
                    _EmojiFilterChip(
                      label: emoji,
                      selected: _emojiFilter == emoji,
                      onTap: () => setState(() => _emojiFilter = emoji),
                    ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      widget.emptyText,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                        itemCount: visible.length,
                        separatorBuilder: (_, index) => Divider(
                          height: 1,
                          indent: 72,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.4),
                        ),
                        itemBuilder: (context, index) {
                          final person = visible[index];
                          final name = feedPersonDisplayName(person);
                          final displayName =
                              name.isEmpty ? 'Участник' : name;
                          final userId = feedPersonUserId(person);
                          final emoji = person['emoji']?.toString() ?? '';
                          final canOpenProfile =
                              feedPersonCanOpenProfile(person);
                          return ListTile(
                            leading: ChatAvatar(
                              name: displayName,
                              avatarUrl: person['avatar_url']?.toString(),
                              userId: canOpenProfile ? userId : null,
                              radius: 20,
                            ),
                            title: Text(displayName),
                            trailing: emoji.isEmpty
                                ? (canOpenProfile
                                    ? const Icon(Icons.chevron_right, size: 20)
                                    : null)
                                : Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 20),
                                  ),
                            onTap: !canOpenProfile || userId == null
                                ? null
                                : () => _openProfile(userId),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _EmojiFilterChip extends StatelessWidget {
  const _EmojiFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        selectedColor: cs.primaryContainer,
        onSelected: (_) => onTap(),
      ),
    );
  }
}
