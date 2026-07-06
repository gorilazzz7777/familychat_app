import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../data/familychat_realtime.dart';
import 'chat_info_sheet.dart';
import 'widgets/chat_message_bubble.dart';

class ChatConversationScreen extends ConsumerStatefulWidget {
  const ChatConversationScreen({
    super.key,
    required this.threadId,
    required this.title,
    required this.kind,
    this.peerUserId,
  });

  final int threadId;
  final String title;
  final String kind;
  final int? peerUserId;

  @override
  ConsumerState<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends ConsumerState<ChatConversationScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  int? _currentUserId;
  final List<int> _pendingAttachmentIds = [];

  bool get _isGroupLike => widget.kind == 'group' || widget.kind == 'family';

  bool get _isDm => widget.kind == 'dm';

  @override
  void initState() {
    super.initState();
    FamilyChatRealtime.instance.addListener(_onRealtime);
    _init();
  }

  Future<void> _init() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      _currentUserId = st['user_id'] as int?;
    } catch (_) {}
    await _load();
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _onRealtime(Map<String, dynamic> event) {
    final threadId = event['thread_id'];
    if (threadId != null && threadId != widget.threadId) return;

    if (event['event'] == 'chat_message') {
      final msg = event['message'];
      if (msg is! Map) return;
      final map = Map<String, dynamic>.from(msg);
      if (map['thread_id'] != widget.threadId) return;
      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m['id'] == map['id'])) {
          _messages = [..._messages, map];
        }
      });
      _scrollToBottom();
      return;
    }

    if (event['event'] == 'chat_messages_read') {
      final ids = (event['message_ids'] as List?)?.cast<int>() ??
          (event['message_ids'] as List?)?.map((e) => e as int).toList() ??
          [];
      if (ids.isEmpty || !mounted) return;
      setState(() {
        _messages = _messages.map((m) {
          final id = m['id'] as int?;
          if (id != null && ids.contains(id)) {
            return {...m, 'read_status': 'read'};
          }
          return m;
        }).toList();
      });
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(familychatRepositoryProvider).threadMessages(widget.threadId);
      if (!mounted) return;
      setState(() {
        _messages = list;
        _loading = false;
      });
      _scrollToBottom();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAttachment() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Галерея'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Камера'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Файл'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    try {
      if (action == 'file') {
        final picked = await FilePicker.platform.pickFiles(withData: true);
        if (picked == null || picked.files.isEmpty) return;
        final f = picked.files.first;
        if (f.bytes == null) return;
        final att = await ref.read(familychatRepositoryProvider).uploadChatAttachmentBytes(
              widget.threadId,
              bytes: f.bytes!,
              filename: f.name,
              contentType: null,
            );
        setState(() => _pendingAttachmentIds.add(att['id'] as int));
      } else {
        final picker = ImagePicker();
        final source = action == 'camera' ? ImageSource.camera : ImageSource.gallery;
        final picked = await picker.pickImage(source: source, imageQuality: 90);
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        final att = await ref.read(familychatRepositoryProvider).uploadChatAttachmentBytes(
              widget.threadId,
              bytes: bytes,
              filename: picked.name,
              contentType: 'image/jpeg',
            );
        setState(() => _pendingAttachmentIds.add(att['id'] as int));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Вложение добавлено — нажмите отправить')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки: $e')),
      );
    }
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty && _pendingAttachmentIds.isEmpty) return;
    _controller.clear();
    final ids = List<int>.from(_pendingAttachmentIds);
    setState(() => _pendingAttachmentIds.clear());
    try {
      final msg = await ref.read(familychatRepositoryProvider).sendThreadMessage(
            widget.threadId,
            body: body.isEmpty ? null : body,
            attachmentIds: ids.isEmpty ? null : ids,
          );
      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m['id'] == msg['id'])) {
          _messages = [..._messages, msg];
        }
      });
      _scrollToBottom();
    } catch (_) {}
  }

  Future<void> _openInfo() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChatInfoSheet(
        threadId: widget.threadId,
        title: widget.title,
      ),
    );
  }

  bool _isMine(Map<String, dynamic> m) {
    final senderId = m['sender_user_id'] as int?;
    return _currentUserId != null && senderId == _currentUserId;
  }

  int? _senderId(Map<String, dynamic> m) => m['sender_user_id'] as int?;

  /// Аватар в группе — только у последнего сообщения в серии от одного автора.
  bool _showSenderAvatar(int index) {
    if (_isDm || _isMine(_messages[index])) return false;
    final senderId = _senderId(_messages[index]);
    if (senderId == null) return false;
    final nextIndex = index + 1;
    if (nextIndex >= _messages.length) return true;
    if (_isMine(_messages[nextIndex])) return true;
    return _senderId(_messages[nextIndex]) != senderId;
  }

  bool _clusteredWithNext(int index) {
    final nextIndex = index + 1;
    if (nextIndex >= _messages.length) return false;
    if (_isMine(_messages[index]) != _isMine(_messages[nextIndex])) return false;
    return _senderId(_messages[index]) == _senderId(_messages[nextIndex]);
  }

  bool _showGroupAvatarColumn(int index) {
    return _isGroupLike && !_isDm && !_isMine(_messages[index]);
  }

  Future<void> _openSenderProfile(int userId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(userId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _openInfo,
          child: Text(widget.title),
        ),
      ),
      body: Column(
        children: [
          if (_pendingAttachmentIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('К отправке: ${_pendingAttachmentIds.length} влож.'),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        final created = DateTime.tryParse(m['created_at']?.toString() ?? '');
                        final atts =
                            (m['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [];
                        final isMine = _isMine(m);
                        final senderUserId = _senderId(m);
                        return ChatMessageBubble(
                          isMine: isMine,
                          body: m['body']?.toString() ?? '',
                          attachments: atts,
                          createdAt: created,
                          readStatus: isMine ? m['read_status']?.toString() ?? 'sent' : null,
                          showGroupAvatarColumn: _showGroupAvatarColumn(i),
                          showSenderAvatar: _showSenderAvatar(i),
                          senderName: m['sender_name']?.toString(),
                          senderAvatarUrl: m['sender_avatar_url']?.toString(),
                          onSenderAvatarTap: senderUserId != null
                              ? () => _openSenderProfile(senderUserId)
                              : null,
                          compactWithNext: _clusteredWithNext(i),
                        );
                      },
                    ),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _pickAttachment,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Сообщение...',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
