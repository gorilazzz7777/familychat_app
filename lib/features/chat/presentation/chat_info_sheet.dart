import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'widgets/chat_network_image.dart';

String chatParticipantCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod100 >= 11 && mod100 <= 14) return '$count участников';
  if (mod10 == 1) return '$count участник';
  if (mod10 >= 2 && mod10 <= 4) return '$count участника';
  return '$count участников';
}

typedef ChatGoToMessage = Future<void> Function(int messageId);
typedef ChatOpenImage = void Function({
  required String imageUrl,
  String? filename,
  int? messageId,
  Map<String, dynamic>? attachment,
});
typedef ChatTitleChanged = void Function(String title, String customTitle);

class ChatInfoSheet extends ConsumerStatefulWidget {
  const ChatInfoSheet({
    super.key,
    required this.threadId,
    required this.title,
    required this.defaultTitle,
    this.customTitle = '',
    this.kind = 'family',
    this.hasLeft = false,
    this.canRejoin = false,
    this.canLeave = false,
    this.participantUserIds = const [],
    this.onTitleChanged,
    this.onMembershipChanged,
    this.onGoToMessage,
    this.onOpenImage,
  });

  final int threadId;
  final String title;
  final String defaultTitle;
  final String customTitle;
  final String kind;
  final bool hasLeft;
  final bool canRejoin;
  final bool canLeave;
  final List<int> participantUserIds;
  final ChatTitleChanged? onTitleChanged;
  final VoidCallback? onMembershipChanged;
  final ChatGoToMessage? onGoToMessage;
  final ChatOpenImage? onOpenImage;

  @override
  ConsumerState<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends ConsumerState<ChatInfoSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late String _title;
  late String _customTitle;
  List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _links = [];
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;

  bool get _showParticipants =>
      (widget.kind == 'group' || widget.kind == 'family') && !widget.hasLeft;

  int get _tabCount => _showParticipants ? 4 : 3;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _customTitle = widget.customTitle;
    _tabs = TabController(length: _tabCount, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(familychatRepositoryProvider);
    try {
      final futures = <Future<dynamic>>[
        repo.threadMedia(widget.threadId),
        repo.threadFiles(widget.threadId),
        repo.threadLinks(widget.threadId),
      ];
      if (_showParticipants) {
        futures.add(repo.threadParticipants(widget.threadId));
      }
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _media = (results[0] as List).cast<Map<String, dynamic>>();
        _files = (results[1] as List).cast<Map<String, dynamic>>();
        _links = (results[2] as List).cast<Map<String, dynamic>>();
        if (_showParticipants) {
          _participants = (results[3] as List).cast<Map<String, dynamic>>();
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadParticipants() async {
    if (!_showParticipants) return;
    try {
      final list =
          await ref.read(familychatRepositoryProvider).threadParticipants(
                widget.threadId,
              );
      if (!mounted) return;
      setState(() => _participants = list);
    } catch (_) {}
  }

  Future<void> _mute(String key) async {
    try {
      await ref
          .read(familychatRepositoryProvider)
          .setThreadMute(widget.threadId, key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(key == 'off'
                ? 'Уведомления включены'
                : 'Уведомления отключены')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _renameChat() async {
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => _RenameChatDialog(
        initialTitle: _customTitle,
        defaultTitle: widget.defaultTitle,
        canReset: _customTitle.isNotEmpty,
      ),
    );
    if (!mounted || result == null) return;

    try {
      final data =
          await ref.read(familychatRepositoryProvider).setThreadCustomTitle(
                widget.threadId,
                result,
              );
      if (!mounted) return;
      final title = data['title']?.toString() ?? widget.defaultTitle;
      final customTitle = data['custom_title']?.toString() ?? '';
      setState(() {
        _title = title;
        _customTitle = customTitle;
      });
      widget.onTitleChanged?.call(title, customTitle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            customTitle.isEmpty ? 'Название сброшено' : 'Название сохранено',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _leaveChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Покинуть чат?'),
        content: Text(
          widget.kind == 'family'
              ? 'Вы не будете получать сообщения общего чата. Вернуться можно в любой момент из списка чатов.'
              : 'Вы перестанете видеть сообщения этой группы. Вернуть вас сможет любой участник.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Покинуть')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(familychatRepositoryProvider)
          .leaveChatThread(widget.threadId);
      if (!mounted) return;
      widget.onMembershipChanged?.call();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вы покинули чат')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _rejoinChat() async {
    try {
      await ref
          .read(familychatRepositoryProvider)
          .rejoinChatThread(widget.threadId);
      if (!mounted) return;
      widget.onMembershipChanged?.call();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вы снова в общем чате семьи')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _addMembers() async {
    if (widget.kind != 'group') return;
    final members = await ref.read(familychatRepositoryProvider).members();
    final existing = _participants
        .map((p) => p['user_id'])
        .map((id) => id is int ? id : int.tryParse('$id'))
        .whereType<int>()
        .toSet();
    final status = await ref.read(familychatRepositoryProvider).status();
    final myUserId = status['user_id'] is int ? status['user_id'] as int : null;
    final candidates = members.where((m) {
      final uid = m['user_id'];
      final userId = uid is int ? uid : int.tryParse('$uid');
      if (userId == null || existing.contains(userId)) return false;
      return true;
    }).toList();
    if (!mounted) return;
    final selected = await showDialog<Set<int>>(
      context: context,
      builder: (ctx) => _AddMembersDialog(
        members: candidates,
        myUserId: myUserId,
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    try {
      await ref.read(familychatRepositoryProvider).addChatThreadMembers(
            widget.threadId,
            selected.toList(),
          );
      if (!mounted) return;
      await _reloadParticipants();
      widget.onMembershipChanged?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Добавлено: ${selected.length}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _openParticipantProfile(int userId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(userId: userId),
      ),
    );
  }

  Future<void> _showMuteOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                title: const Text('1 час'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('1h');
                }),
            ListTile(
                title: const Text('4 часа'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('4h');
                }),
            ListTile(
                title: const Text('8 часов'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('8h');
                }),
            ListTile(
                title: const Text('24 часа'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('24h');
                }),
            ListTile(
                title: const Text('Навсегда'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('forever');
                }),
            ListTile(
                title: const Text('Включить уведомления'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('off');
                }),
          ],
        ),
      ),
    );
  }

  int? _messageIdOf(Map<String, dynamic> item) {
    final id = item['message_id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  Future<void> _goToMessage(int messageId) async {
    Navigator.of(context).pop();
    await widget.onGoToMessage?.call(messageId);
  }

  Future<void> _showItemActions({
    required String title,
    required VoidCallback? onOpen,
    int? messageId,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onOpen != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(title),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
            if (messageId != null && widget.onGoToMessage != null)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Перейти к сообщению'),
                onTap: () => Navigator.pop(ctx, 'goto'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'open') onOpen?.call();
    if (action == 'goto' && messageId != null) {
      await _goToMessage(messageId);
    }
  }

  void _openGalleryItem(Map<String, dynamic> item) {
    final repo = ref.read(familychatRepositoryProvider);
    final url = chatAttachmentImageUrl(
      repo: repo,
      threadId: widget.threadId,
      attachment: item,
    );
    final messageId = _messageIdOf(item);
    final openImage = widget.onOpenImage;
    if (openImage == null) return;

    Navigator.of(context).pop();
    openImage(
      imageUrl: url,
      filename: item['filename']?.toString(),
      messageId: messageId,
      attachment: item,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(_title, style: Theme.of(context).textTheme.titleLarge),
                  if (_showParticipants && _participants.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        chatParticipantCountLabel(_participants.length),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                  if (_customTitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        widget.defaultTitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      shrinkWrap: true,
                      children: [
                        _InfoCompactAction(
                          icon: Icons.drive_file_rename_outline,
                          label: 'Переименовать',
                          onTap: _renameChat,
                        ),
                        const SizedBox(width: 8),
                        _InfoCompactAction(
                          icon: Icons.notifications_off_outlined,
                          label: 'Уведомления',
                          onTap: _showMuteOptions,
                        ),
                        if (widget.canRejoin) ...[
                          const SizedBox(width: 8),
                          _InfoCompactAction(
                            icon: Icons.login,
                            label: 'Вернуться в чат',
                            onTap: _rejoinChat,
                          ),
                        ],
                        if (widget.canLeave && !widget.hasLeft) ...[
                          const SizedBox(width: 8),
                          _InfoCompactAction(
                            icon: Icons.logout,
                            label: 'Покинуть чат',
                            onTap: _leaveChat,
                          ),
                        ],
                        if (widget.kind == 'group' && !widget.hasLeft) ...[
                          const SizedBox(width: 8),
                          _InfoCompactAction(
                            icon: Icons.person_add_outlined,
                            label: 'Добавить участников',
                            onTap: _addMembers,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabs,
              isScrollable: _showParticipants,
              tabs: [
                if (_showParticipants) const Tab(text: 'Участники'),
                const Tab(text: 'Галерея'),
                const Tab(text: 'Ссылки'),
                const Tab(text: 'Файлы'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        if (_showParticipants) _participantsTab(),
                        _media.isEmpty
                            ? const Center(child: Text('Нет изображений'))
                            : GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                ),
                                itemCount: _media.length,
                                itemBuilder: (_, i) {
                                  final item = _media[i];
                                  return GestureDetector(
                                    onTap: () => _openGalleryItem(item),
                                    onLongPress: () {
                                      final messageId = _messageIdOf(item);
                                      if (messageId != null) {
                                        _showItemActions(
                                          title: 'Открыть фото',
                                          onOpen: () => _openGalleryItem(item),
                                          messageId: messageId,
                                        );
                                      }
                                    },
                                    child: ChatNetworkImage(
                                      threadId: widget.threadId,
                                      attachment: item,
                                      fit: BoxFit.cover,
                                    ),
                                  );
                                },
                              ),
                        _links.isEmpty
                            ? const Center(child: Text('Нет ссылок'))
                            : ListView.builder(
                                itemCount: _links.length,
                                itemBuilder: (_, i) {
                                  final item = _links[i];
                                  final url = item['url']?.toString() ?? '';
                                  final messageId = _messageIdOf(item);
                                  return ListTile(
                                    title: Text(
                                      url,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => _showItemActions(
                                      title: 'Открыть ссылку',
                                      onOpen: () => launchUrl(
                                        Uri.parse(url),
                                        mode: LaunchMode.externalApplication,
                                      ),
                                      messageId: messageId,
                                    ),
                                  );
                                },
                              ),
                        _files.isEmpty
                            ? const Center(child: Text('Нет файлов'))
                            : ListView.builder(
                                itemCount: _files.length,
                                itemBuilder: (_, i) {
                                  final f = _files[i];
                                  final url = f['file_url']?.toString();
                                  final messageId = _messageIdOf(f);
                                  return ListTile(
                                    leading: const Icon(
                                        Icons.insert_drive_file_outlined),
                                    title: Text(
                                        f['filename']?.toString() ?? 'Файл'),
                                    onTap: () => _showItemActions(
                                      title: 'Открыть файл',
                                      onOpen: url != null
                                          ? () => launchUrl(
                                                Uri.parse(url),
                                                mode: LaunchMode
                                                    .externalApplication,
                                              )
                                          : null,
                                      messageId: messageId,
                                    ),
                                  );
                                },
                              ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _participantsTab() {
    if (_participants.isEmpty) {
      return const Center(child: Text('Нет участников'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _participants.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        indent: 72,
        color:
            Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
      ),
      itemBuilder: (context, index) {
        final participant = _participants[index];
        final name = participant['display_name']?.toString() ?? 'Участник';
        final uid = participant['user_id'];
        final userId = uid is int ? uid : int.tryParse('$uid');
        if (userId == null) return const SizedBox.shrink();
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: ChatAvatar(
            name: name,
            avatarUrl: participant['avatar_url']?.toString(),
            radius: 24,
          ),
          title: Text(name),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _openParticipantProfile(userId),
        );
      },
    );
  }
}

class _AddMembersDialog extends StatefulWidget {
  const _AddMembersDialog({
    required this.members,
    this.myUserId,
  });

  final List<Map<String, dynamic>> members;
  final int? myUserId;

  @override
  State<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<_AddMembersDialog> {
  final _selected = <int>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить участников'),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.members.isEmpty
            ? const Text('Нет доступных участников семьи')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.members.length,
                itemBuilder: (context, index) {
                  final member = widget.members[index];
                  final uid = member['user_id'];
                  final userId = uid is int ? uid : int.tryParse('$uid');
                  if (userId == null) return const SizedBox.shrink();
                  final name = member['display_name']?.toString() ?? 'Участник';
                  return CheckboxListTile(
                    value: _selected.contains(userId),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(userId);
                        } else {
                          _selected.remove(userId);
                        }
                      });
                    },
                    secondary: ChatAvatar(
                      name: name,
                      avatarUrl: member['avatar_url']?.toString(),
                      radius: 20,
                    ),
                    title: Text(name),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected),
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({
    required this.initialTitle,
    required this.defaultTitle,
    required this.canReset,
  });

  final String initialTitle;
  final String defaultTitle;
  final bool canReset;

  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Название чата'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 300,
        decoration: InputDecoration(
          hintText: widget.defaultTitle,
          helperText: 'Видно только вам',
        ),
      ),
      actions: [
        if (widget.canReset)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Сбросить'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _InfoCompactAction extends StatelessWidget {
  const _InfoCompactAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
