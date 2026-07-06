import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/app_providers.dart';
import 'widgets/chat_network_image.dart';

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
    this.onTitleChanged,
    this.onGoToMessage,
    this.onOpenImage,
  });

  final int threadId;
  final String title;
  final String defaultTitle;
  final String customTitle;
  final ChatTitleChanged? onTitleChanged;
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _customTitle = widget.customTitle;
    _tabs = TabController(length: 3, vsync: this);
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
      final results = await Future.wait([
        repo.threadMedia(widget.threadId),
        repo.threadFiles(widget.threadId),
        repo.threadLinks(widget.threadId),
      ]);
      if (!mounted) return;
      setState(() {
        _media = results[0];
        _files = results[1];
        _links = results[2];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _mute(String key) async {
    try {
      await ref.read(familychatRepositoryProvider).setThreadMute(widget.threadId, key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(key == 'off' ? 'Уведомления включены' : 'Уведомления отключены')),
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
      final data = await ref.read(familychatRepositoryProvider).setThreadCustomTitle(
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

  Future<void> _showMuteOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text('1 час'), onTap: () { Navigator.pop(ctx); _mute('1h'); }),
            ListTile(title: const Text('4 часа'), onTap: () { Navigator.pop(ctx); _mute('4h'); }),
            ListTile(title: const Text('8 часов'), onTap: () { Navigator.pop(ctx); _mute('8h'); }),
            ListTile(title: const Text('24 часа'), onTap: () { Navigator.pop(ctx); _mute('24h'); }),
            ListTile(title: const Text('Навсегда'), onTap: () { Navigator.pop(ctx); _mute('forever'); }),
            ListTile(title: const Text('Включить уведомления'), onTap: () { Navigator.pop(ctx); _mute('off'); }),
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
                  if (_customTitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        widget.defaultTitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _renameChat,
                    icon: const Icon(Icons.drive_file_rename_outline),
                    label: const Text('Переименовать'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _showMuteOptions,
                    icon: const Icon(Icons.notifications_off_outlined),
                    label: const Text('Уведомления'),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: 'Галерея'),
                Tab(text: 'Ссылки'),
                Tab(text: 'Файлы'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabs,
                      children: [
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
                                    leading: const Icon(Icons.insert_drive_file_outlined),
                                    title: Text(f['filename']?.toString() ?? 'Файл'),
                                    onTap: () => _showItemActions(
                                      title: 'Открыть файл',
                                      onOpen: url != null
                                          ? () => launchUrl(
                                                Uri.parse(url),
                                                mode: LaunchMode.externalApplication,
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
