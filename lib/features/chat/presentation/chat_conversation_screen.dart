import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/face_tagging_sheet.dart';
import '../data/active_chat_context.dart';
import '../data/chat_realtime_utils.dart';
import '../data/familychat_realtime.dart';
import 'chat_forward_screen.dart';
import 'chat_info_sheet.dart';
import 'widgets/chat_compose_input.dart';
import 'widgets/chat_image_viewer.dart';
import 'widgets/chat_media_compose_sheet.dart';
import 'widgets/chat_message_actions_sheet.dart';
import 'widgets/chat_message_bubble.dart';
import 'widgets/chat_message_reactions.dart';
import 'widgets/chat_message_search_sheet.dart';
import 'widgets/chat_network_image.dart';
import 'widgets/chat_pending_file_chip.dart';
import 'widgets/chat_reply_compose_bar.dart';

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

String? _imageContentTypeForFilename(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  return null;
}

class ChatConversationScreen extends ConsumerStatefulWidget {
  const ChatConversationScreen({
    super.key,
    required this.threadId,
    required this.title,
    required this.kind,
    this.defaultTitle,
    this.customTitle = '',
    this.peerUserId,
    this.initialMessageId,
  });

  final int threadId;
  final String title;
  final String kind;
  final String? defaultTitle;
  final String customTitle;
  final int? peerUserId;
  final int? initialMessageId;

  @override
  ConsumerState<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends ConsumerState<ChatConversationScreen>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollController = ScrollController();
  final _messageKeys = <int, GlobalKey>{};
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasMoreOlder = false;
  bool _offlineMode = false;
  int? _currentUserId;
  int? _highlightMessageId;
  int? _lastMarkedReadId;
  _PendingFileDraft? _pendingFileDraft;
  int _tempIdCounter = -1;
  bool _selectionMode = false;
  final Set<int> _selectedMessageIds = {};
  Map<String, dynamic>? _replyTo;
  late String _title;
  String _customTitle = '';
  double _lastKeyboardInset = 0;

  bool get _isGroupLike => widget.kind == 'group' || widget.kind == 'family';

  bool get _isDm => widget.kind == 'dm';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _customTitle = widget.customTitle;
    WidgetsBinding.instance.addObserver(this);
    _inputFocus.addListener(_onInputFocusChanged);
    ActiveChatContext.instance.setOpenThread(widget.threadId);
    FamilyChatRealtime.instance.addListener(_onRealtime);
    _scrollController.addListener(_onScroll);
    _init();
  }

  Future<void> _init() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      _currentUserId = st['user_id'] as int?;
    } catch (_) {}
    final cached = await FamilyChatLocalCache.readThreadMessages(widget.threadId);
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _messages = cached;
        _loading = false;
        _offlineMode = true;
      });
    }
    await _load(silent: cached != null && cached.isNotEmpty);
    final targetId = widget.initialMessageId;
    if (targetId != null) {
      await _scrollToMessage(targetId);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingOlder || !_hasMoreOlder) return;
    if (_scrollController.position.pixels <= 72) {
      unawaited(_loadOlder());
    }
  }

  Future<void> _persistMessageCache() async {
    if (_messages.isEmpty) return;
    final real = _messages.where((m) {
      final id = chatAsInt(m['id']);
      return id != null && id > 0;
    }).toList();
    if (real.isEmpty) return;
    final slice = real.length > FamilyChatLocalCache.maxCachedMessagesPerThread
        ? real.sublist(real.length - FamilyChatLocalCache.maxCachedMessagesPerThread)
        : real;
    await FamilyChatLocalCache.saveThreadMessages(widget.threadId, slice);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    if (ActiveChatContext.instance.openThreadId == widget.threadId) {
      ActiveChatContext.instance.setOpenThread(null);
    }
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _syncScrollForKeyboard();
  }

  void _onInputFocusChanged() {
    if (_inputFocus.hasFocus) {
      _syncScrollForKeyboard();
    }
  }

  void _syncScrollForKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bottom = MediaQuery.viewInsetsOf(context).bottom;
      if ((bottom - _lastKeyboardInset).abs() < 1) return;
      _lastKeyboardInset = bottom;
      _scrollToBottom();
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted) return;
        _scrollToBottom(jump: true);
      });
    });
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (jump) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _scrollToMessage(int messageId) async {
    final exists = _messages.any((m) => chatAsInt(m['id']) == messageId);
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

    if (event['event'] == 'chat_refresh') {
      if (eventThreadId != widget.threadId) return;
      unawaited(_load(silent: true));
      return;
    }

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
      unawaited(_persistMessageCache());
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
      return;
    }

    if (event['event'] == 'chat_messages_deleted') {
      if (eventThreadId != widget.threadId) return;
      final ids = chatAsIntList(event['message_ids']);
      if (ids.isEmpty || !mounted) return;
      _removeMessagesLocally(ids);
      return;
    }

    if (event['event'] == 'chat_message_reactions') {
      if (eventThreadId != widget.threadId) return;
      final messageId = chatAsInt(event['message_id']);
      if (messageId == null || !mounted) return;
      final reactions = chatParseReactions(
        event['reactions'],
        currentUserId: _currentUserId,
      );
      _applyMessageReactions(messageId, reactions);
    }
  }

  void _applyMessageReactions(
    int messageId,
    List<Map<String, dynamic>> reactions,
  ) {
    setState(() {
      _messages = _messages.map((m) {
        final id = chatAsInt(m['id']);
        if (id == messageId) {
          return {...m, 'reactions': reactions};
        }
        return m;
      }).toList();
    });
  }

  void _removeMessagesLocally(List<int> ids) {
    setState(() {
      _messages = _messages.where((m) {
        final id = chatAsInt(m['id']);
        return id == null || !ids.contains(id);
      }).toList();
      _selectedMessageIds.removeWhere(ids.contains);
      if (_selectedMessageIds.isEmpty) _selectionMode = false;
    });
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

  Future<void> _load({bool silent = false}) async {
    if (!silent && _messages.isEmpty) setState(() => _loading = true);
    try {
      final page = await ref.read(familychatRepositoryProvider).threadMessages(
            widget.threadId,
            limit: 20,
          );
      if (!mounted) return;
      setState(() {
        if (silent && _messages.length > 20) {
          _messages = _mergeLatestMessages(_messages, page.messages);
        } else {
          _messages = page.messages;
        }
        _hasMoreOlder = page.hasMore;
        _loading = false;
        _offlineMode = false;
      });
      unawaited(_persistMessageCache());
      unawaited(_markLatestRead());
      if (silent || widget.initialMessageId == null) {
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted && _messages.isEmpty) {
        setState(() => _loading = false);
      }
    }
  }

  List<Map<String, dynamic>> _mergeLatestMessages(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> latest,
  ) {
    if (latest.isEmpty) return current;
    final oldestLatestId = chatAsInt(latest.first['id']);
    if (oldestLatestId == null) return latest;
    final olderKept = current.where((m) {
      final id = chatAsInt(m['id']);
      return id != null && id > 0 && id < oldestLatestId;
    }).toList();
    final latestIds = latest.map((m) => chatAsInt(m['id'])).whereType<int>().toSet();
    final mergedOlder = olderKept.where((m) => !latestIds.contains(chatAsInt(m['id']))).toList();
    return [...mergedOlder, ...latest];
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder || _messages.isEmpty) return;
    final firstId = chatAsInt(_messages.first['id']);
    if (firstId == null || firstId <= 0) return;

    setState(() => _loadingOlder = true);
    final previousExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final previousPixels = _scrollController.hasClients
        ? _scrollController.position.pixels
        : 0.0;

    try {
      final page = await ref.read(familychatRepositoryProvider).threadMessages(
            widget.threadId,
            limit: 20,
            beforeId: firstId,
          );
      if (!mounted) return;
      final existingIds = _messages.map((m) => chatAsInt(m['id'])).whereType<int>().toSet();
      final older = page.messages
          .where((m) {
            final id = chatAsInt(m['id']);
            return id != null && !existingIds.contains(id);
          })
          .toList();
      setState(() {
        _messages = [...older, ..._messages];
        _hasMoreOlder = page.hasMore;
        _loadingOlder = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final newExtent = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(previousPixels + (newExtent - previousExtent));
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  int _nextTempId() => _tempIdCounter--;

  void _addOptimisticMessage(
    int tempId, {
    required String body,
    required List<Map<String, dynamic>> attachments,
    Map<String, dynamic>? replyTo,
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
          if (replyTo != null) 'reply_to': replyTo,
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
    int? replyToMessageId,
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
        replyToMessageId: replyToMessageId,
      );
      if (!mounted) return;
      _replaceOptimisticMessage(tempId, msg);
      _scrollToBottom();
      for (var i = 0; i < attachments.length; i++) {
        if (i >= ids.length) break;
        final att = attachments[i];
        final isImage = att.contentType?.startsWith('image/') ??
            _imageContentTypeForFilename(att.filename)?.startsWith('image/') ??
            false;
        if (isImage) {
          unawaited(_pollFaceTaggingPrompt(ids[i]));
        }
      }
    } catch (_) {
      if (!mounted) return;
      _markOptimisticFailed(tempId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить сообщение')),
      );
    }
  }

  Future<void> _pollFaceTaggingPrompt(int attachmentId) async {
    final repo = ref.read(familychatRepositoryProvider);
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final status = await repo.attachmentTaggingStatus(widget.threadId, attachmentId);
        final taggingStatus = status['photo_tagging_status']?.toString() ?? '';
        if (taggingStatus == 'failed') return;
        if (taggingStatus != 'done') continue;
        if (status['should_prompt_face_tagging'] != true) return;
        if (!mounted) return;
        final attachment = {
          'id': attachmentId,
          'thread_id': widget.threadId,
        };
        await FaceTaggingSheet.show(
          context,
          threadId: widget.threadId,
          attachmentId: attachmentId,
          promptMode: true,
          imageChild: faceTaggingAttachmentPreview(
            threadId: widget.threadId,
            attachment: attachment,
          ),
        );
        return;
      } catch (_) {
        // retry until timeout
      }
    }
  }

  Future<void> _sendImageWithCaption(
    Uint8List bytes,
    String filename,
    String caption, {
    String? contentType,
  }) async {
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
          contentType: contentType ?? _imageContentTypeForFilename(filename) ?? 'image/jpeg',
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
        final picked = await FilePicker.platform.pickFiles(withData: true, allowMultiple: true);
        if (picked == null || picked.files.isEmpty) return;
        if (picked.files.length == 1) {
          final f = picked.files.first;
          if (f.bytes == null) return;
          setState(() {
            _pendingFileDraft = _PendingFileDraft(
              bytes: f.bytes!,
              filename: f.name,
              contentType: null,
            );
          });
          return;
        }
        final atts = <_OutgoingAttachment>[];
        for (final f in picked.files) {
          if (f.bytes == null) continue;
          atts.add(_OutgoingAttachment(bytes: f.bytes!, filename: f.name, contentType: null));
        }
        if (atts.isEmpty) return;
        await _uploadAndSend(_nextTempId(), caption: '', attachments: atts);
      } else {
        final picker = ImagePicker();
        final source = action == 'camera' ? ImageSource.camera : ImageSource.gallery;
        // Без imageQuality: иначе image_picker перекодирует JPEG и удаляет EXIF (GPS, дата).
        final galleryItems = source == ImageSource.gallery
            ? await picker.pickMultiImage(requestFullMetadata: true)
            : const <XFile>[];
        final picked = source == ImageSource.gallery
            ? null
            : await picker.pickImage(
                source: source,
                requestFullMetadata: true,
              );
        if (source == ImageSource.gallery && galleryItems.isEmpty) return;
        if (source != ImageSource.gallery && picked == null) return;
        if (source == ImageSource.gallery && galleryItems.length > 1) {
          final atts = <_OutgoingAttachment>[];
          for (final file in galleryItems) {
            final bytes = await file.readAsBytes();
            atts.add(
              _OutgoingAttachment(
                bytes: bytes,
                filename: file.name,
                contentType: file.mimeType ?? _imageContentTypeForFilename(file.name) ?? 'image/jpeg',
              ),
            );
          }
          await _uploadAndSend(_nextTempId(), caption: '', attachments: atts);
          return;
        }
        final image = source == ImageSource.gallery ? galleryItems.first : picked!;
        final bytes = await image.readAsBytes();
        final contentType =
            image.mimeType ?? _imageContentTypeForFilename(image.name) ?? 'image/jpeg';
        if (!mounted) return;
        await ChatMediaComposeSheet.show(
          context,
          imageBytes: bytes,
          filename: image.name,
          onSend: (caption) => _sendImageWithCaption(
            bytes,
            image.name,
            caption,
            contentType: contentType,
          ),
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

    final replyTo = _replyTo;
    final replyId = chatAsInt(replyTo?['message_id']);
    _controller.clear();
    setState(() {
      _pendingFileDraft = null;
      _replyTo = null;
    });

    final tempId = _nextTempId();
    final attachments = fileDraft == null
        ? <Map<String, dynamic>>[]
        : [
            {
              'kind': 'file',
              'filename': fileDraft.filename,
            },
          ];

    _addOptimisticMessage(
      tempId,
      body: body,
      attachments: attachments,
      replyTo: replyTo,
    );

    if (fileDraft == null) {
      await _uploadAndSend(
        tempId,
        caption: body,
        attachments: const [],
        replyToMessageId: replyId,
      );
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
      replyToMessageId: replyId,
    );
  }

  String _messagePreviewText(Map<String, dynamic> message) {
    final body = message['body']?.toString().trim() ?? '';
    if (body.isNotEmpty) return body;
    final atts = chatAttachmentsOf(message);
    if (atts.any((a) => a['kind'] == 'image')) return 'Фото';
    if (atts.isNotEmpty) return 'Файл';
    return 'Сообщение';
  }

  Map<String, dynamic>? _messageById(int id) {
    for (final m in _messages) {
      if (chatAsInt(m['id']) == id) return m;
    }
    return null;
  }

  void _enterSelection(int messageId) {
    setState(() {
      _selectionMode = true;
      _selectedMessageIds
        ..clear()
        ..add(messageId);
      _replyTo = null;
    });
  }

  void _toggleSelection(int messageId) {
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
        if (_selectedMessageIds.isEmpty) _selectionMode = false;
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
  }

  List<int> get _selectableMessageIds => _messages
      .map((m) => chatAsInt(m['id']))
      .whereType<int>()
      .where((id) => _messageById(id)?['_pending'] != true)
      .toList();

  bool get _allMessagesSelected {
    final ids = _selectableMessageIds;
    return ids.isNotEmpty && ids.every(_selectedMessageIds.contains);
  }

  void _toggleSelectAllMessages() {
    final ids = _selectableMessageIds;
    setState(() {
      if (_allMessagesSelected) {
        _selectedMessageIds.removeAll(ids);
        if (_selectedMessageIds.isEmpty) _selectionMode = false;
      } else {
        _selectionMode = true;
        _selectedMessageIds.addAll(ids);
      }
    });
  }

  bool _canDeleteMessage(Map<String, dynamic> message) {
    return _isMine(message) && message['_pending'] != true;
  }

  bool _canDeleteMessageId(int id) {
    final message = _messageById(id);
    return message != null && _canDeleteMessage(message);
  }

  bool get _canDeleteSelection =>
      _selectedMessageIds.isNotEmpty &&
      _selectedMessageIds.every(_canDeleteMessageId);

  Future<void> _openMessageMenu(Map<String, dynamic> message) async {
    if (message['_pending'] == true) return;
    final result = await ChatMessageActionsSheet.show(
      context,
      canDelete: _canDeleteMessage(message),
    );
    if (!mounted || result == null) return;

    if (result.reactionEmoji != null) {
      final id = chatAsInt(message['id']);
      if (id != null) {
        await _toggleReaction(id, result.reactionEmoji!);
      }
      return;
    }

    switch (result.action) {
      case 'reply':
        _startReply(message);
      case 'copy':
        await _copyMessages([message]);
      case 'forward':
        final id = chatAsInt(message['id']);
        if (id != null) await _forwardMessageIds([id]);
      case 'delete':
        final id = chatAsInt(message['id']);
        if (id != null) await _deleteMessages([id]);
    }
  }

  Future<void> _toggleReaction(int messageId, String emoji) async {
    try {
      final raw = await ref.read(familychatRepositoryProvider).toggleMessageReaction(
            widget.threadId,
            messageId,
            emoji,
          );
      if (!mounted) return;
      _applyMessageReactions(
        messageId,
        chatParseReactions(raw, currentUserId: _currentUserId),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось поставить реакцию')),
      );
    }
  }

  Future<void> _copyMessages(List<Map<String, dynamic>> messages) async {
    final parts = messages.map(_messagePreviewText).where((t) => t.isNotEmpty).toList();
    if (parts.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: parts.join('\n\n')));
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скопировано')),
    );
  }

  Future<void> _deleteMessages(List<int> messageIds) async {
    if (messageIds.isEmpty) return;
    final count = messageIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщения?'),
        content: Text(
          count == 1
              ? 'Сообщение будет удалено у всех участников чата.'
              : 'Выбранные сообщения ($count) будут удалены у всех участников чата.',
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
    if (ok != true || !mounted) return;

    try {
      final deleted = await ref.read(familychatRepositoryProvider).deleteMessages(
            widget.threadId,
            messageIds,
          );
      if (!mounted) return;
      _removeMessagesLocally(deleted);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сообщение удалено')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить')),
      );
    }
  }

  Future<void> _copySelected() async {
    final messages = _messages
        .where((m) => _selectedMessageIds.contains(chatAsInt(m['id'])))
        .toList();
    await _copyMessages(messages);
  }

  void _startReply(Map<String, dynamic> message) {
    final id = chatAsInt(message['id']);
    if (id == null) return;
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
      _replyTo = {
        'message_id': id,
        'sender_name': message['sender_name']?.toString() ?? 'Сообщение',
        'body': _messagePreviewText(message),
      };
    });
  }

  Future<void> _forwardMessageIds(List<int> ids) async {
    if (ids.isEmpty) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ChatForwardScreen(
          sourceThreadId: widget.threadId,
          messageIds: ids,
        ),
      ),
    );
    if (ok == true && mounted) {
      _exitSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Переслано')),
      );
    }
  }

  Future<void> _forwardSelected() async {
    await _forwardMessageIds(_selectedMessageIds.toList()..sort());
  }

  Future<void> _deleteSelected() async {
    await _deleteMessages(_selectedMessageIds.toList()..sort());
  }

  Future<void> _openInfo() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChatInfoSheet(
        threadId: widget.threadId,
        title: _title,
        defaultTitle: widget.defaultTitle ?? widget.title,
        customTitle: _customTitle,
        onTitleChanged: (title, customTitle) {
          if (!mounted) return;
          setState(() {
            _title = title;
            _customTitle = customTitle;
          });
        },
        onGoToMessage: _scrollToMessage,
        onOpenImage: _openImage,
      ),
    );
  }

  void _openImage({
    required String imageUrl,
    String? filename,
    int? messageId,
    Map<String, dynamic>? attachment,
  }) {
    unawaited(_openImageAsync(
      imageUrl: imageUrl,
      filename: filename,
      messageId: messageId,
      attachment: attachment,
    ));
  }

  Future<void> _openImageAsync({
    required String imageUrl,
    String? filename,
    int? messageId,
    Map<String, dynamic>? attachment,
  }) async {
    final headers = await chatImageAuthHeaders(ref);
    if (!mounted) return;
    await ChatImageViewer.open(
      context,
      imageUrl: imageUrl,
      threadId: widget.threadId,
      attachmentId: chatAsInt(attachment?['id']),
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
      attachment: attachment,
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
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                tooltip: 'Отменить выбор',
                onPressed: _exitSelection,
                icon: const Icon(Icons.close),
              ),
              title: Text('${_selectedMessageIds.length} выбрано'),
              actions: [
                TextButton(
                  onPressed: _selectableMessageIds.isEmpty ? null : _toggleSelectAllMessages,
                  child: Text(_allMessagesSelected ? 'Снять все' : 'Выбрать все'),
                ),
                if (_canDeleteSelection)
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: _deleteSelected,
                    icon: const Icon(Icons.delete_outline),
                  ),
                IconButton(
                  tooltip: 'Скопировать',
                  onPressed: _selectedMessageIds.isEmpty ? null : _copySelected,
                  icon: const Icon(Icons.copy),
                ),
              ],
            )
          : AppBar(
              title: InkWell(
                onTap: _openInfo,
                child: Text(_title),
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
          if (_offlineMode)
            MaterialBanner(
              content: const Text('Показаны сохранённые сообщения. Обновление при появлении сети.'),
              actions: [
                TextButton(onPressed: _load, child: const Text('Обновить')),
              ],
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      controller: _scrollController,
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _messages.length + (_loadingOlder ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (_loadingOlder && i == 0) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final msgIndex = _loadingOlder ? i - 1 : i;
                        final m = _messages[msgIndex];
                        final msgId = chatAsInt(m['id']) ?? 0;
                        _messageKeys.putIfAbsent(msgId, GlobalKey.new);
                        final created = DateTime.tryParse(m['created_at']?.toString() ?? '');
                        final atts = chatAttachmentsOf(m);
                        final isMine = _isMine(m);
                        final senderUserId = _senderId(m);
                        final replyTo = m['reply_to'] as Map<String, dynamic>?;
                        final forward = m['forward'] as Map<String, dynamic>?;
                        final reactions = chatParseReactions(
                          m['reactions'],
                          currentUserId: _currentUserId,
                        );
                        final replyMessageId = chatAsInt(replyTo?['message_id']);
                        return KeyedSubtree(
                          key: _messageKeys[msgId],
                          child: ChatMessageBubble(
                            threadId: widget.threadId,
                            isMine: isMine,
                            body: m['body']?.toString() ?? '',
                            attachments: atts,
                            createdAt: created,
                            replyTo: replyTo,
                            forward: forward,
                            reactions: reactions,
                            isGroupLike: _isGroupLike,
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
                            selectionMode: _selectionMode,
                            selected: _selectedMessageIds.contains(msgId),
                            onTap: _selectionMode
                                ? () => _toggleSelection(msgId)
                                : () => _openMessageMenu(m),
                            onLongPress: m['_pending'] == true
                                ? null
                                : () => _enterSelection(msgId),
                            onReplyTap: replyMessageId != null
                                ? () => _scrollToMessage(replyMessageId)
                                : null,
                            onReactionTap: m['_pending'] == true
                                ? null
                                : (emoji) => _toggleReaction(msgId, emoji),
                            onImageTap: (a) => _openImageFromAttachment(a, messageId: msgId),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          if (_selectionMode)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (_selectedMessageIds.length == 1) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final msg = _messageById(_selectedMessageIds.first);
                            if (msg != null) _startReply(msg);
                          },
                          icon: const Icon(Icons.reply_outlined),
                          label: const Text('Ответить'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            _selectedMessageIds.isEmpty ? null : _forwardSelected,
                        icon: const Icon(Icons.forward_outlined),
                        label: const Text('Переслать'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTo != null)
                    ChatReplyComposeBar(
                      senderName: _replyTo!['sender_name']?.toString() ?? '',
                      body: _replyTo!['body']?.toString() ?? '',
                      onCancel: () => setState(() => _replyTo = null),
                    ),
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
                    child: ChatComposeInput(
                      controller: _controller,
                      focusNode: _inputFocus,
                      onAttach: _pickAttachment,
                      onSend: _send,
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
