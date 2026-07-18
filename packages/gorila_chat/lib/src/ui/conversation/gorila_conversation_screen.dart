import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../contract/chat_call_repository.dart';
import '../../contract/chat_capabilities.dart';
import '../../contract/chat_host.dart';
import '../../contract/chat_repository.dart';
import '../../realtime/gorila_chat_realtime.dart';
import '../../util/active_chat_context.dart';
import '../../util/chat_realtime_utils.dart';
import '../attach/chat_attach_sheet.dart';
import '../calls/chat_call_screen.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/chat_compose_input.dart';
import 'chat_info_sheet.dart';

typedef GorilaSystemMessageBuilder = Widget? Function(
  BuildContext context,
  Map<String, dynamic> message,
);

/// Shared conversation screen — same UI for all apps; API via [ChatRepository].
class GorilaConversationScreen extends StatefulWidget {
  const GorilaConversationScreen({
    super.key,
    required this.threadId,
    required this.title,
    required this.repository,
    required this.realtime,
    required this.capabilities,
    this.callRepository,
    this.host,
    this.peerUserId,
    this.peerAvatarUrl,
    this.threadKind = 'dm',
    this.isNotifications = false,
    this.systemMessageBuilder,
    this.loadMessagesOverride,
  });

  final int threadId;
  final String title;
  final ChatRepository repository;
  final GorilaChatRealtime realtime;
  final ChatCapabilities capabilities;
  final ChatCallRepository? callRepository;
  final ChatHost? host;
  final int? peerUserId;
  final String? peerAvatarUrl;
  final String threadKind;
  final bool isNotifications;
  final GorilaSystemMessageBuilder? systemMessageBuilder;

  /// Optional override when messages are loaded by kind (team/dm/notifications)
  /// instead of thread id alone.
  final Future<List<Map<String, dynamic>>> Function()? loadMessagesOverride;

  @override
  State<GorilaConversationScreen> createState() =>
      _GorilaConversationScreenState();
}

class _GorilaConversationScreenState extends State<GorilaConversationScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  int? _myUserId;
  bool _loading = true;
  bool _sending = false;
  bool _notificationsEnabled = true;
  String? _headerAvatarUrl;

  @override
  void initState() {
    super.initState();
    _headerAvatarUrl = widget.peerAvatarUrl;
    ActiveChatContext.instance.setOpenThread(widget.threadId);
    widget.realtime.addListener(_onRealtime);
    unawaited(_init());
  }

  @override
  void dispose() {
    if (ActiveChatContext.instance.openThreadId == widget.threadId) {
      ActiveChatContext.instance.setOpenThread(null);
    }
    widget.realtime.removeListener(_onRealtime);
    _ctrl.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _myUserId = await widget.repository.currentUserId();
    if (widget.peerUserId != null &&
        (_headerAvatarUrl == null || _headerAvatarUrl!.isEmpty)) {
      final profile =
          await widget.repository.resolvePeerProfile(widget.peerUserId!);
      final url = profile?['avatar_url']?.toString();
      if (url != null && url.isNotEmpty && mounted) {
        setState(() => _headerAvatarUrl = url);
      }
    }
    try {
      _notificationsEnabled = await widget.repository.notificationsEnabled(
        threadId: widget.threadId,
        kind: widget.threadKind,
        peerUserId: widget.peerUserId,
      );
    } catch (_) {}
    await _load();
  }

  void _onRealtime(Map<String, dynamic> event) {
    final name = event['event']?.toString();
    final eventThreadId = chatAsInt(event['thread_id']);

    if (name == 'chat_refresh') {
      if (eventThreadId != null && eventThreadId != widget.threadId) return;
      unawaited(_load(silent: true));
      return;
    }
    if (name != 'chat_message') return;
    final raw = event['message'];
    if (raw is! Map) return;
    final msg = chatNormalizeMap(Map<dynamic, dynamic>.from(raw));
    if (!chatMessageBelongsToThread(msg, widget.threadId)) return;
    final id = chatAsInt(msg['id']);
    if (id != null && _messages.any((m) => chatAsInt(m['id']) == id)) return;
    if (!mounted) return;
    setState(() => _messages = chatUpsertMessage(_messages, msg));
    _scrollToBottom();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final list = widget.loadMessagesOverride != null
          ? await widget.loadMessagesOverride!()
          : await widget.repository.loadMessages(threadId: widget.threadId);
      if (!mounted) return;
      setState(() {
        _messages = silent ? chatMergeMessageLists(_messages, list) : list;
      });
      if (!silent) _scrollToBottom();
      final lastId = chatNewestServerMessageId(_messages);
      if (lastId != null) {
        unawaited(
          widget.repository.markRead(
            threadId: widget.threadId,
            lastReadMessageId: lastId,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send({List<int>? attachmentIds}) async {
    final text = _ctrl.text.trim();
    if (text.isEmpty && (attachmentIds == null || attachmentIds.isEmpty)) {
      return;
    }
    setState(() => _sending = true);
    final pendingBody = text;
    _ctrl.clear();
    try {
      await widget.repository.sendText(
        threadId: widget.threadId,
        body: pendingBody,
        attachmentIds: attachmentIds,
      );
      await _load(silent: true);
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      _ctrl.text = pendingBody;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не отправлено: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _uploadAndSend({
    required Uint8List bytes,
    required String filename,
    String? contentType,
    String caption = '',
  }) async {
    setState(() => _sending = true);
    try {
      final uploaded = await widget.repository.sendAttachment(
        threadId: widget.threadId,
        bytes: bytes,
        filename: filename,
        contentType: contentType,
        caption: caption,
      );
      final id = chatAsInt(uploaded['id']);
      if (id != null) {
        await widget.repository.sendText(
          threadId: widget.threadId,
          body: caption,
          attachmentIds: [id],
        );
        await _load(silent: true);
        _scrollToBottom();
      } else if (caption.isNotEmpty) {
        await widget.repository.sendText(
          threadId: widget.threadId,
          body: caption,
        );
        await _load(silent: true);
      } else {
        await _load(silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showAttach() async {
    if (widget.isNotifications || !widget.capabilities.supportsAttachments) {
      return;
    }
    await ChatAttachSheet.show(
      context,
      onSendMedia: (caption, items) async {
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          await _uploadAndSend(
            bytes: item.bytes,
            filename: item.filename,
            contentType: item.contentType,
            caption: i == items.length - 1 ? caption : '',
          );
        }
      },
    );
  }

  void _openInfo() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChatInfoSheet(
        threadId: widget.threadId,
        title: widget.title,
        kind: widget.threadKind,
        peerUserId: widget.peerUserId,
        peerName: widget.title,
        peerAvatarUrl: _headerAvatarUrl,
        repository: widget.repository,
        callRepository: widget.callRepository,
        realtime: widget.realtime,
        capabilities: widget.capabilities,
        myUserId: _myUserId,
        initialNotificationsEnabled: _notificationsEnabled,
        onNotificationsChanged: (v) {
          if (mounted) setState(() => _notificationsEnabled = v);
        },
      ),
    );
  }

  void _startCall() {
    final calls = widget.callRepository;
    if (calls == null ||
        !widget.capabilities.supportsCalls ||
        widget.peerUserId == null) {
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatCallScreen(
          threadId: widget.threadId,
          title: widget.title,
          isCaller: true,
          callRepository: calls,
          realtime: widget.realtime,
          myUserId: _myUserId,
        ),
      ),
    );
  }

  Widget _buildTitle() {
    final isDm = widget.peerUserId != null;
    final content = isDm
        ? Row(
            children: [
              ChatAvatar(
                name: widget.title,
                avatarUrl: _headerAvatarUrl,
                radius: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.title, overflow: TextOverflow.ellipsis),
              ),
            ],
          )
        : Text(widget.title, overflow: TextOverflow.ellipsis);
    return InkWell(onTap: _openInfo, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: _buildTitle(),
        actions: [
          if (widget.capabilities.supportsCalls &&
              widget.peerUserId != null &&
              widget.callRepository != null)
            IconButton(
              tooltip: 'Позвонить',
              onPressed: _startCall,
              icon: const Icon(Icons.call_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Text(
                          widget.isNotifications
                              ? 'Пока нет уведомлений'
                              : 'Нет сообщений\nНапишите первым',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) {
                          final m = _messages[i];
                          final system = widget.systemMessageBuilder
                              ?.call(context, m);
                          if (system != null) return system;
                          return _MessageBubble(
                            message: m,
                            isMine: chatAsInt(m['sender_user_id']) == _myUserId,
                          );
                        },
                      ),
          ),
          if (!widget.isNotifications)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: ChatComposeInput(
                  controller: _ctrl,
                  focusNode: _focus,
                  sending: _sending,
                  showAttach: widget.capabilities.supportsAttachments,
                  onAttach: () => unawaited(_showAttach()),
                  onSend: () => unawaited(_send()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMine});

  final Map<String, dynamic> message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = message['body']?.toString() ?? '';
    final name = message['sender_name']?.toString() ?? '';
    final created = DateTime.tryParse(message['created_at']?.toString() ?? '');
    final attachments = chatAttachmentsOf(message);
    final bg = isMine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final align = isMine ? Alignment.centerRight : Alignment.centerLeft;

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Card(
          color: bg,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMine && name.isNotEmpty)
                  Text(
                    name,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                if (body.isNotEmpty) Text(body),
                for (final a in attachments) ...[
                  const SizedBox(height: 6),
                  _AttachmentPreview(attachment: a),
                ],
                if (created != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      DateFormat('HH:mm').format(created.toLocal()),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.attachment});

  final Map<String, dynamic> attachment;

  @override
  Widget build(BuildContext context) {
    final url = attachment['file_url']?.toString() ??
        attachment['url']?.toString() ??
        '';
    final kind = attachment['kind']?.toString() ?? '';
    final name = attachment['filename']?.toString() ?? 'файл';
    if (url.isNotEmpty && (kind == 'image' || url.contains('image'))) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: url,
          height: 160,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Text(name),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_outlined, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
