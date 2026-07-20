import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../contract/chat_call_repository.dart';
import '../../contract/chat_capabilities.dart';
import '../../contract/chat_host.dart';
import '../../contract/chat_repository.dart';
import '../../contract/chat_send_options.dart';
import '../../realtime/gorila_chat_realtime.dart';
import '../../util/active_chat_context.dart';
import '../../util/chat_realtime_utils.dart';
import '../attach/chat_attach_sheet.dart';
import '../calls/chat_call_screen.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/chat_compose_input.dart';
import '../widgets/chat_message_actions_sheet.dart';
import '../widgets/chat_pinned_bar.dart';
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
  final _messageKeys = <int, GlobalKey>{};

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _pinnedMessages = [];
  int _pinnedIndex = 0;
  int? _myUserId;
  int? _highlightMessageId;
  bool _loading = true;
  bool _sending = false;
  bool _notificationsEnabled = true;
  bool _selectionMode = false;
  final Set<int> _selectedIds = {};
  String? _headerAvatarUrl;

  ChatCapabilities get _caps => widget.capabilities;

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

    if (name == 'chat_messages_deleted') {
      if (eventThreadId != widget.threadId) return;
      final ids = chatAsIntList(event['message_ids']);
      if (ids.isEmpty || !mounted) return;
      _removeMessagesLocally(ids);
      return;
    }

    if (name == 'chat_pins_updated') {
      if (eventThreadId != widget.threadId) return;
      final raw = event['pinned_messages'];
      if (raw is! List || !mounted) return;
      _setPinned(
        raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
      );
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
      var pins = <Map<String, dynamic>>[];
      if (_caps.supportsPin) {
        try {
          pins = await widget.repository.loadPinnedMessages(widget.threadId);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _messages = silent ? chatMergeMessageLists(_messages, list) : list;
        if (_caps.supportsPin) {
          _pinnedMessages = pins;
          if (_pinnedIndex >= _pinnedMessages.length) {
            _pinnedIndex =
                _pinnedMessages.isEmpty ? 0 : _pinnedMessages.length - 1;
          }
        }
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

  void _setPinned(List<Map<String, dynamic>> pins) {
    setState(() {
      _pinnedMessages = pins;
      if (_pinnedIndex >= _pinnedMessages.length) {
        _pinnedIndex = _pinnedMessages.isEmpty ? 0 : _pinnedMessages.length - 1;
      }
    });
  }

  void _removeMessagesLocally(List<int> ids) {
    setState(() {
      _messages = _messages.where((m) {
        final id = chatAsInt(m['id']);
        return id == null || !ids.contains(id);
      }).toList();
      _selectedIds.removeWhere(ids.contains);
      if (_selectedIds.isEmpty) _selectionMode = false;
      _pinnedMessages = _pinnedMessages.where((m) {
        final id = chatAsInt(m['id']);
        return id == null || !ids.contains(id);
      }).toList();
      if (_pinnedIndex >= _pinnedMessages.length) {
        _pinnedIndex = _pinnedMessages.isEmpty ? 0 : _pinnedMessages.length - 1;
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _scrollToMessage(int messageId) async {
    final msgIndex =
        _messages.indexWhere((m) => chatAsInt(m['id']) == messageId);
    if (msgIndex < 0 || !mounted) return;
    setState(() => _highlightMessageId = messageId);

    if (_scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      const avg = 88.0;
      final estimated = (msgIndex * avg).clamp(0.0, max);
      _scroll.jumpTo(estimated);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    for (var attempt = 0; attempt < 8; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final key = _messageKeys.putIfAbsent(messageId, GlobalKey.new);
      final ctx = key.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.35,
        );
        break;
      }
      if (_scroll.hasClients) {
        final pos = _scroll.position;
        final step = 240.0 * (attempt.isEven ? 1 : -1);
        _scroll.jumpTo((pos.pixels + step).clamp(0.0, pos.maxScrollExtent));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _highlightMessageId == messageId) {
        setState(() => _highlightMessageId = null);
      }
    });
  }

  Future<void> _cyclePinnedOrScroll() async {
    if (_pinnedMessages.isEmpty) return;
    final current = _pinnedIndex.clamp(0, _pinnedMessages.length - 1);
    final id = chatAsInt(_pinnedMessages[current]['id']);
    if (id != null) await _scrollToMessage(id);
    if (!mounted || _pinnedMessages.length <= 1) return;
    setState(() => _pinnedIndex = (current + 1) % _pinnedMessages.length);
  }

  void _enterSelection(int messageId) {
    if (!_caps.supportsSelect) return;
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(messageId);
    });
  }

  void _toggleSelection(int messageId) {
    setState(() {
      if (_selectedIds.contains(messageId)) {
        _selectedIds.remove(messageId);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(messageId);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  bool _isMine(Map<String, dynamic> m) =>
      chatAsInt(m['sender_user_id']) == _myUserId;

  bool _isPinned(int? id) =>
      id != null && _pinnedMessages.any((m) => chatAsInt(m['id']) == id);

  Future<void> _openMessageMenu(Map<String, dynamic> message) async {
    if (message['is_system'] == true) return;
    final id = chatAsInt(message['id']);
    final mine = _isMine(message);
    final result = await ChatMessageActionsSheet.show(
      context,
      showReactions: _caps.supportsReactions,
      canReply: _caps.supportsReply,
      canEdit: _caps.supportsEdit && mine,
      canForward: _caps.supportsForward,
      canSelect: _caps.supportsSelect,
      canPin: _caps.supportsPin && id != null,
      isPinned: _isPinned(id),
      canDeleteForEveryone: _caps.supportsDelete && mine,
      canDeleteForMe: _caps.supportsDeleteForMe && !mine,
    );
    if (!mounted || result == null) return;

    if (result.reactionEmoji != null) {
      // Host must implement reactions via extended repository later.
      return;
    }

    switch (result.action) {
      case 'copy':
        final body = message['body']?.toString() ?? '';
        if (body.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: body));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Скопировано')),
          );
        }
      case 'select':
        if (id != null) _enterSelection(id);
      case 'pin':
        if (id != null) await _pinMessage(id);
      case 'unpin':
        if (id != null) await _unpinMessage(id);
      case 'delete':
        if (id != null) await _deleteMessages([id], forEveryone: true);
      case 'delete_for_me':
        if (id != null) await _deleteMessages([id], forEveryone: false);
      case 'reply':
      case 'edit':
      case 'forward':
        // Full flows live in Family Chat; stubs until repository expands.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Действие пока доступно в Family Chat'),
          ),
        );
    }
  }

  Future<void> _pinMessage(int messageId) async {
    try {
      final pins = await widget.repository.pinMessage(
        threadId: widget.threadId,
        messageId: messageId,
      );
      if (!mounted) return;
      _setPinned(pins);
      final idx =
          _pinnedMessages.indexWhere((m) => chatAsInt(m['id']) == messageId);
      if (idx >= 0) setState(() => _pinnedIndex = idx);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось закрепить')),
      );
    }
  }

  Future<void> _unpinMessage(int messageId) async {
    try {
      final pins = await widget.repository.unpinMessage(
        threadId: widget.threadId,
        messageId: messageId,
      );
      if (!mounted) return;
      _setPinned(pins);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открепить')),
      );
    }
  }

  Future<void> _deleteMessages(
    List<int> ids, {
    required bool forEveryone,
  }) async {
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщения?'),
        content: Text(
          forEveryone
              ? 'Сообщение будет удалено у всех участников чата.'
              : 'Сообщение будет удалено только из вашей истории.',
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
      final removed = forEveryone
          ? await widget.repository.deleteMessages(
              threadId: widget.threadId,
              messageIds: ids,
            )
          : await widget.repository.hideMessagesForMe(
              threadId: widget.threadId,
              messageIds: ids,
            );
      if (!mounted) return;
      _removeMessagesLocally(removed);
      _exitSelection();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить')),
      );
    }
  }

  Future<void> _runAiAssistCompose() async {
    final draft = _ctrl.text.trim();
    if (draft.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final suggestion = await widget.repository.aiComposeMessage(
        threadId: widget.threadId,
        task: draft,
      );
      if (!mounted) return;
      final text = suggestion.trim();
      if (text.isEmpty) return;
      setState(() {
        _ctrl
          ..text = text
          ..selection = TextSelection.collapsed(offset: text.length);
      });
      _focus.requestFocus();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось составить сообщение. Попробуйте ещё раз.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _handleComposeSend(ChatSendOptions options) async {
    if (options.aiAssist) {
      if (!_caps.supportsAiAssist) return;
      await _runAiAssistCompose();
      return;
    }
    if (options.silent || options.isScheduled) {
      // Silent / schedule: Family Chat owns full flows; shared screen sends normally.
    }
    await _send();
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
    if (widget.isNotifications || !_caps.supportsAttachments) {
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
    if (calls == null || !_caps.supportsCalls || widget.peerUserId == null) {
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
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        appBar: _selectionMode
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelection,
                ),
                title: Text('${_selectedIds.length} выбрано'),
                actions: [
                  if (_caps.supportsDelete || _caps.supportsDeleteForMe)
                    IconButton(
                      tooltip: 'Удалить',
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : () {
                              final ids = _selectedIds.toList();
                              final allMine = ids.every((id) {
                                for (final m in _messages) {
                                  if (chatAsInt(m['id']) == id) {
                                    return _isMine(m);
                                  }
                                }
                                return false;
                              });
                              unawaited(
                                _deleteMessages(
                                  ids,
                                  forEveryone:
                                      allMine && _caps.supportsDelete,
                                ),
                              );
                            },
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              )
            : AppBar(
                title: _buildTitle(),
                actions: [
                  if (_caps.supportsCalls &&
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
            if (!_selectionMode &&
                _caps.supportsPin &&
                _pinnedMessages.isNotEmpty)
              ChatPinnedBar(
                message: _pinnedMessages[
                    _pinnedIndex.clamp(0, _pinnedMessages.length - 1)],
                index: _pinnedIndex.clamp(0, _pinnedMessages.length - 1),
                total: _pinnedMessages.length,
                onTap: () => unawaited(_cyclePinnedOrScroll()),
                onClose: () {
                  final pin = _pinnedMessages[
                      _pinnedIndex.clamp(0, _pinnedMessages.length - 1)];
                  final id = chatAsInt(pin['id']);
                  if (id != null) unawaited(_unpinMessage(id));
                },
              ),
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
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 0,
                            vertical: 8,
                          ),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final m = _messages[i];
                            final system =
                                widget.systemMessageBuilder?.call(context, m);
                            if (system != null) return system;
                            final msgId = chatAsInt(m['id']) ?? 0;
                            _messageKeys.putIfAbsent(msgId, GlobalKey.new);
                            final selected = _selectedIds.contains(msgId);
                            final highlighted = _highlightMessageId == msgId;
                            return KeyedSubtree(
                              key: _messageKeys[msgId],
                              child: _MessageBubble(
                                message: m,
                                isMine: _isMine(m),
                                selectionMode: _selectionMode,
                                selected: selected,
                                highlighted: highlighted,
                                onTap: _selectionMode
                                    ? () => _toggleSelection(msgId)
                                    : () => unawaited(_openMessageMenu(m)),
                                onLongPress: _selectionMode
                                    ? () => _toggleSelection(msgId)
                                    : () => unawaited(_openMessageMenu(m)),
                              ),
                            );
                          },
                        ),
            ),
            if (!widget.isNotifications && !_selectionMode)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: ChatComposeInput(
                    controller: _ctrl,
                    focusNode: _focus,
                    sending: _sending,
                    showAttach: _caps.supportsAttachments,
                    showAiAssist: _caps.supportsAiAssist,
                    showSilent: false,
                    showSchedule: _caps.supportsScheduledSend,
                    onAttach: () => unawaited(_showAttach()),
                    onSend: (options) => unawaited(_handleComposeSend(options)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.selectionMode = false,
    this.selected = false,
    this.highlighted = false,
    this.onTap,
    this.onLongPress,
  });

  final Map<String, dynamic> message;
  final bool isMine;
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = message['body']?.toString() ?? '';
    final name = message['sender_name']?.toString() ?? '';
    final created = DateTime.tryParse(message['created_at']?.toString() ?? '');
    final attachments = chatAttachmentsOf(message);
    final bg = isMine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final rowTint = (highlighted || selected)
        ? scheme.primary.withValues(alpha: 0.12)
        : Colors.transparent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: double.infinity,
      color: rowTint,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (selectionMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, bottom: 8),
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      onPressed: onTap,
                      icon: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        color: selected ? scheme.primary : scheme.outline,
                      ),
                    ),
                  ),
                Expanded(
                  child: Align(
                    alignment:
                        isMine ? Alignment.centerRight : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.78,
                      ),
                      child: Card(
                        color: bg,
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isMine && name.isNotEmpty)
                                Text(
                                  name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
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
                                    DateFormat('HH:mm')
                                        .format(created.toLocal()),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
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
