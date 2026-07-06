import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../data/chat_realtime_utils.dart';
import '../data/familychat_realtime.dart';
import 'chat_info_sheet.dart';
import 'widgets/chat_image_viewer.dart';
import 'widgets/chat_media_compose_sheet.dart';
import 'widgets/chat_message_bubble.dart';
import 'widgets/chat_message_search_sheet.dart';
import 'widgets/chat_network_image.dart';
import 'widgets/chat_pending_file_chip.dart';

class _PendingFileDraft {
  const _PendingFileDraft({
    required this.bytes,
    required this.filename,
    this.contentType,
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
}

class _OutgoingAttachment {
  const _OutgoingAttachment({
    required this.bytes,
    required this.filename,
    this.contentType,
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
}

class ChatConversationScreen extends ConsumerStatefulWidget {
  const ChatConversationScreen({
    super.key,
    required this.threadId,
    required this.title,
    required this.kind,
    this.peerUserId,
    this.initialMessageId,
  });

  final int threadId;
  final String title;
  final String kind;
  final int? peerUserId;
  final int? initialMessageId;

  @override
  ConsumerState<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends ConsumerState<ChatConversationScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _messageKeys = <int, GlobalKey>{};
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  int? _currentUserId;
  int? _highlightMessageId;
  int? _lastMarkedReadId;
  _PendingFileDraft? _pendingFileDraft;
  int _tempIdCounter = -1;

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
    final targetId = widget.initialMessageId;
    if (targetId != null) {
      await _scrollToMessage(targetId);
    }
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

  Future<void> _scrollToMessage(int messageId) async {
    final exists = _messages.any((m) => m['id'] == messageId);
    if (!exists) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сообщение не найдено в загруженной истории')),
      );
      return;
    }

    setState(() => _highlightMessageId = messageId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.35,
      );
    }

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _highlightMessageId == messageId) {
        setState(() => _highlightMessageId = null);
      }
    });
  }

  void _onRealtime(Map<String, dynamic> event) {
    final eventThreadId = chatAsInt(event['thread_id']);

    if (event['event'] == 'chat_message') {
      final msg = event['message'];
      if (msg is! Map) return;
      final map = chatNormalizeMap(Map<dynamic, dynamic>.from(msg));
      if (chatAsInt(map['thread_id']) != widget.threadId) return;
      if (!mounted) return;
      final msgId = chatAsInt(map['id']);
      setState(() {
        if (_currentUserId != null && chatAsInt(map['sender_user_id']) == _currentUserId) {
          final pendingIdx = _messages.indexWhere((m) => m['_pending'] == true);
          if (pendingIdx >= 0) {
            _messages = List<Map<String, dynamic>>.from(_messages)..removeAt(pendingIdx);
          }
        }
        if (msgId == null || !_messages.any((m) => chatAsInt(m['id']) == msgId)) {
          _messages = [..._messages, map];
        }
      });
      _scrollToBottom();
      unawaited(_markLatestRead());
      return;
    }

    if (event['event'] == 'chat_messages_read') {
      if (eventThreadId != null && eventThreadId != widget.threadId) return;
      final ids = chatAsIntList(event['message_ids']);
      if (ids.isEmpty || !mounted) return;
      setState(() {
        _messages = _messages.map((m) {
          final id = chatAsInt(m['id']);
          if (id != null && ids.contains(id)) {
            return {...m, 'read_status': 'read'};
          }
          return m;
        }).toList();
      });
    }
  }

  Future<void> _markLatestRead() async {
    if (_messages.isEmpty) return;
    final lastId = chatAsInt(_messages.last['id']);
    if (lastId == null || lastId == _lastMarkedReadId) return;
    _lastMarkedReadId = lastId;
    try {
      await ref.read(familychatRepositoryProvider).markThreadRead(
            widget.threadId,
            lastMessageId: lastId,
          );
    } catch (_) {
      _lastMarkedReadId = null;
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
      unawaited(_markLatestRead());
      if (widget.initialMessageId == null) {
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _nextTempId() => _tempIdCounter--;

  void _addOptimisticMessage(
    int tempId, {
    required String body,
    required List<Map<String, dynamic>> attachments,
  }) {
    setState(() {
      _messages = [
        ..._messages,
        {
          'id': tempId,
          '_pending': true,
          'thread_id': widget.threadId,
          'body': body,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'sender_user_id': _currentUserId,
          'sender_name': '',
          'sender_avatar_url': '',
          'attachments': attachments,
          'read_status': 'sending',
        },
      ];
    });
    _scrollToBottom();
  }

  void _replaceOptimisticMessage(int tempId, Map<String, dynamic> msg) {
    setState(() {
      _messages = _messages.where((m) => m['id'] != tempId).toList();
      final msgId = chatAsInt(msg['id']);
      if (msgId == null || !_messages.any((m) => chatAsInt(m['id']) == msgId)) {
        _messages = [..._messages, msg];
      }
    });
  }

  void _markOptimisticFailed(int tempId) {
    setState(() {
      _messages = _messages.map((m) {
        if (m['id'] == tempId) {
          return {...m, 'read_status': 'failed'};
        }
        return m;
      }).toList();
    });
  }

  Future<void> _uploadAndSend(
    int tempId, {
    required String caption,
    required List<_OutgoingAttachment> attachments,
  }) async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final ids = <int>[];
      for (final att in attachments) {
        final uploaded = await repo.uploadChatAttachmentBytes(
          widget.threadId,
          bytes: att.bytes,
          filename: att.filename,
          contentType: att.contentType,
        );
        final id = chatAsInt(uploaded['id']);
        if (id != null) ids.add(id);
      }
      final msg = await repo.sendThreadMessage(
        widget.threadId,
        body: caption.isEmpty ? null : caption,
        attachmentIds: ids.isEmpty ? null : ids,
      );
      if (!mounted) return;
      _replaceOptimisticMessage(tempId, msg);
      _scrollToBottom();
    } catch (_) {
      if (!mounted) return;
      _markOptimisticFailed(tempId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить сообщение')),
      );
    }
  }

  Future<void> _sendImageWithCaption(
    Uint8List bytes,
    String filename,
    String caption,
  ) async {
    final tempId = _nextTempId();
    _addOptimisticMessage(
      tempId,
      body: caption,
      attachments: [
        {
          'kind': 'image',
          'filename': filename,
          'local_bytes': bytes,
        },
      ],
    );
    await _uploadAndSend(
      tempId,
      caption: caption,
      attachments: [
        _OutgoingAttachment(
          bytes: bytes,
          filename: filename,
          contentType: 'image/jpeg',
        ),
      ],
    );
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
        setState(() {
          _pendingFileDraft = _PendingFileDraft(
            bytes: f.bytes!,
            filename: f.name,
            contentType: null,
          );
        });
      } else {
        final picker = ImagePicker();
        final source = action == 'camera' ? ImageSource.camera : ImageSource.gallery;
        final picked = await picker.pickImage(source: source, imageQuality: 90);
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        if (!mounted) return;
        await ChatMediaComposeSheet.show(
          context,
          imageBytes: bytes,
          filename: picked.name,
          onSend: (caption) => _sendImageWithCaption(bytes, picked.name, caption),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    final fileDraft = _pendingFileDraft;
    if (body.isEmpty && fileDraft == null) return;

    _controller.clear();
    setState(() => _pendingFileDraft = null);

    final tempId = _nextTempId();
    final attachments = fileDraft == null
        ? <Map<String, dynamic>>[]
        : [
            {
              'kind': 'file',
              'filename': fileDraft.filename,
            },
          ];

    _addOptimisticMessage(tempId, body: body, attachments: attachments);

    if (fileDraft == null) {
      await _uploadAndSend(tempId, caption: body, attachments: const []);
      return;
    }

    await _uploadAndSend(
      tempId,
      caption: body,
      attachments: [
        _OutgoingAttachment(
          bytes: fileDraft.bytes,
          filename: fileDraft.filename,
          contentType: fileDraft.contentType,
        ),
      ],
    );
  }

  Future<void> _openInfo() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChatInfoSheet(
        threadId: widget.threadId,
        title: widget.title,
        onGoToMessage: _scrollToMessage,
        onOpenImage: _openImage,
      ),
    );
  }

  void _openImage({
    required String imageUrl,
    String? filename,
    int? messageId,
  }) {
    unawaited(_openImageAsync(
      imageUrl: imageUrl,
      filename: filename,
      messageId: messageId,
    ));
  }

  Future<void> _openImageAsync({
    required String imageUrl,
    String? filename,
    int? messageId,
  }) async {
    final headers = await chatImageAuthHeaders(ref);
    if (!mounted) return;
    await ChatImageViewer.open(
      context,
      imageUrl: imageUrl,
      filename: filename,
      messageId: messageId,
      onGoToMessage: messageId != null ? () => _scrollToMessage(messageId) : null,
      httpHeaders: headers,
    );
  }

  void _openImageFromAttachment(Map<String, dynamic> attachment, {int? messageId}) {
    final repo = ref.read(familychatRepositoryProvider);
    _openImage(
      imageUrl: chatAttachmentImageUrl(
        repo: repo,
        threadId: widget.threadId,
        attachment: attachment,
      ),
      filename: attachment['filename']?.toString(),
      messageId: messageId ?? chatAsInt(attachment['message_id']),
    );
  }

  Future<void> _openSearch() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (_, __) => ChatMessageSearchSheet(
          messages: _messages,
          onSelect: (id) {
            Navigator.pop(ctx);
            _scrollToMessage(id);
          },
        ),
      ),
    );
  }

  bool _isMine(Map<String, dynamic> m) {
    final senderId = m['sender_user_id'] as int?;
    return _currentUserId != null && senderId == _currentUserId;
  }

  int? _senderId(Map<String, dynamic> m) => m['sender_user_id'] as int?;

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
        actions: [
          IconButton(
            tooltip: 'Поиск',
            onPressed: _loading ? null : _openSearch,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
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
                        final msgId = chatAsInt(m['id']) ?? 0;
                        _messageKeys.putIfAbsent(msgId, GlobalKey.new);
                        final created = DateTime.tryParse(m['created_at']?.toString() ?? '');
                        final atts = chatAttachmentsOf(m);
                        final isMine = _isMine(m);
                        final senderUserId = _senderId(m);
                        return KeyedSubtree(
                          key: _messageKeys[msgId],
                          child: ChatMessageBubble(
                            threadId: widget.threadId,
                            isMine: isMine,
                            body: m['body']?.toString() ?? '',
                            attachments: atts,
                            createdAt: created,
                            readStatus: isMine
                                ? m['read_status']?.toString() ??
                                    (m['_pending'] == true ? 'sending' : 'sent')
                                : null,
                            showGroupAvatarColumn: _showGroupAvatarColumn(i),
                            showSenderAvatar: _showSenderAvatar(i),
                            senderName: m['sender_name']?.toString(),
                            senderAvatarUrl: m['sender_avatar_url']?.toString(),
                            onSenderAvatarTap: senderUserId != null
                                ? () => _openSenderProfile(senderUserId)
                                : null,
                            compactWithNext: _clusteredWithNext(i),
                            highlighted: _highlightMessageId == msgId,
                            onImageTap: (a) => _openImageFromAttachment(a, messageId: msgId),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_pendingFileDraft != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: ChatPendingFileChip(
                      filename: _pendingFileDraft!.filename,
                      onRemove: () => setState(() => _pendingFileDraft = null),
                    ),
                  ),
                Padding(
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
