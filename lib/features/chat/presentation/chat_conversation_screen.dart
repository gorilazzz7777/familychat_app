import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/image_upload_pipeline.dart';
import '../../../core/media/video_upload_pipeline.dart';
import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/network/offline_ui.dart';
import '../../../core/notifications/familychat_notifications.dart';
import '../../../core/widgets/gallery_video_player.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/presence/user_presence.dart';
import '../../../core/providers/app_providers.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/face_tagging_sheet.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../data/chat_attach_local_cache.dart';
import '../data/chat_location_utils.dart';
import '../data/active_chat_context.dart';
import '../data/chat_network_status.dart';
import '../data/chat_offline_outbox.dart';
import '../data/chat_offline_sync.dart';
import '../data/chat_realtime_utils.dart';
import '../data/chat_scheduled_send_service.dart';
import '../data/chat_send_options.dart';
import '../data/chat_typing_utils.dart';
import '../data/chat_voice_transcription.dart';
import '../data/chat_voice_utils.dart';
import '../data/familychat_realtime.dart';
import 'chat_thread_avatars.dart';
import 'chat_forward_screen.dart';
import 'chat_info_sheet.dart';
import 'chat_call_screen.dart';
import 'widgets/chat_attach_sheet/chat_attach_models.dart';
import 'widgets/chat_attach_sheet/chat_attach_sheet.dart';
import 'widgets/chat_compose_input.dart';
import 'widgets/chat_mention_compose_input.dart';
import 'widgets/chat_image_viewer.dart';
import 'widgets/chat_message_actions_sheet.dart';
import 'widgets/chat_message_bubble.dart';
import 'widgets/chat_message_reactions.dart';
import 'widgets/chat_message_search_sheet.dart';
import 'widgets/chat_network_image.dart';
import 'widgets/chat_pending_file_chip.dart';
import 'widgets/chat_reply_compose_bar.dart';
import 'widgets/chat_call_history_banner.dart';
import 'widgets/chat_birthday_welcome_banner.dart';
import 'widgets/chat_system_message_banner.dart';

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
    this.photoExif,
    this.kind = 'file',
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
  final Map<String, dynamic>? photoExif;
  final String kind;
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
    this.initialHasLeft = false,
    this.initialCanRejoin = false,
    this.initialCanLeave = false,
    this.initialParticipantUserIds = const [],
    this.initialIsBirthdayCelebration = false,
    this.initialPeerAvatarUrl,
    this.initialCanSend = true,
  });

  final int threadId;
  final String title;
  final String kind;
  final String? defaultTitle;
  final String customTitle;
  final int? peerUserId;
  final int? initialMessageId;
  final bool initialHasLeft;
  final bool initialCanRejoin;
  final bool initialCanLeave;
  final List<int> initialParticipantUserIds;
  final bool initialIsBirthdayCelebration;
  final String? initialPeerAvatarUrl;
  final bool initialCanSend;

  @override
  ConsumerState<ChatConversationScreen> createState() =>
      _ChatConversationScreenState();
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
  String? _loadError;
  int? _currentUserId;
  int? _highlightMessageId;
  int? _lastMarkedReadId;
  _PendingFileDraft? _pendingFileDraft;
  int _tempIdCounter = -1;
  int _loadGeneration = 0;
  bool _selectionMode = false;
  final Set<int> _selectedMessageIds = {};
  Map<String, dynamic>? _replyTo;
  int? _editingMessageId;
  late String _title;
  String _customTitle = '';
  bool _hasLeft = false;
  bool _canRejoin = false;
  bool _canLeave = false;
  List<int> _participantUserIds = [];
  bool _isBirthdayCelebration = false;
  Map<String, dynamic>? _birthdayScheduled;
  bool _birthdayScheduledSaving = false;
  String? _headerAvatarUrl;
  List<ChatMentionParticipant> _mentionParticipants = [];
  bool _voiceTranscriptionEnabled = false;
  bool _viewerIndividualPremium = false;
  bool _canSend = true;
  double _lastKeyboardInset = 0;
  final Map<int, String> _typingNames = {};
  final Map<int, Timer> _typingExpiry = {};
  Timer? _typingEmitTimer;
  Timer? _typingStopTimer;
  Timer? _transcriptPollTimer;
  final Map<int, int> _transcriptPollAttempts = {};
  bool _typingEmitted = false;
  DateTime? _lastTypingEmitAt;

  bool get _isGroupLike => widget.kind == 'group' || widget.kind == 'family';

  bool get _isDm => widget.kind == 'dm' || widget.kind == 'friend_dm';

  bool get _isFriendDm => widget.kind == 'friend_dm';

  void _startOutgoingCall() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatCallScreen(
            threadId: widget.threadId,
            title: _title,
            isCaller: true,
          ),
        ),
      ),
    );
  }

  String? _peerStatusLabel;
  Timer? _peerStatusTimer;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _customTitle = widget.customTitle;
    _hasLeft = widget.initialHasLeft;
    _canRejoin = widget.initialCanRejoin;
    _canLeave = widget.initialCanLeave;
    _canSend = widget.initialCanSend;
    _participantUserIds = List<int>.from(widget.initialParticipantUserIds);
    _isBirthdayCelebration = widget.initialIsBirthdayCelebration;
    _headerAvatarUrl = widget.initialPeerAvatarUrl;
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onComposeTextChanged);
    _inputFocus.addListener(_onInputFocusChanged);
    ActiveChatContext.instance.setOpenThread(widget.threadId);
    FamilyChatRealtime.instance.addListener(_onRealtime);
    ChatOfflineSync.instance.addListener(_onOfflineSync);
    _scrollController.addListener(_onScroll);
    unawaited(
      FamilyChatNotifications.clearChatNotifications(threadId: widget.threadId),
    );
    if (_hasLeft) {
      _loading = false;
    } else {
      _init();
      if (_isGroupLike) {
        unawaited(_refreshParticipantsMeta());
      }
    }
    if (_isDm && widget.peerUserId != null) {
      unawaited(_loadPeerStatus(widget.peerUserId!));
      _peerStatusTimer = Timer.periodic(const Duration(seconds: 45), (_) {
        unawaited(_loadPeerStatus(widget.peerUserId!));
      });
    }
    ChatScheduledSendService.instance.addListener(_onScheduledSend);
  }

  void _onScheduledSend() {
    if (!mounted) return;
    unawaited(_applyScheduledSendResults());
  }

  Future<void> _applyScheduledSendResults() async {
    final deliveries = ChatScheduledSendService.instance.consumeDeliveries();
    if (deliveries.isEmpty) return;

    var changed = false;
    for (final delivery in deliveries) {
      if (delivery.threadId != widget.threadId) continue;
      _messages = _messages
          .where((m) => m['schedule_id']?.toString() != delivery.scheduleId)
          .toList();
      changed = true;
    }
    if (changed && mounted) {
      setState(() {});
      await _persistMessageCache();
    }
    if (!mounted) return;
    if (deliveries.any((d) => d.threadId == widget.threadId)) {
      await _load(silent: true);
    }
  }

  void _onOfflineSync() {
    if (!mounted) return;
    unawaited(_applyOfflineSyncResults());
  }

  Future<void> _applyOfflineSyncResults() async {
    final deliveries = ChatOfflineSync.instance.consumeDeliveries();
    var changed = false;
    for (final delivery in deliveries) {
      if (delivery.threadId != widget.threadId) continue;
      if (delivery.tempMessageId != null && delivery.message != null) {
        _replaceOptimisticMessage(delivery.tempMessageId!, delivery.message!);
        changed = true;
      }
      if (delivery.messageId != null && delivery.reactions != null) {
        _applyMessageReactions(
          delivery.messageId!,
          chatParseReactions(
            delivery.reactions,
            currentUserId: _currentUserId,
          ),
        );
        changed = true;
      }
    }
    if (changed) {
      await _persistMessageCache();
    }
    if (!mounted) return;
    if (ChatOfflineSync.instance.isOnline) {
      await _load(silent: true);
    }
  }

  Future<void> _loadPeerStatus(int userId) async {
    try {
      final profile =
          await ref.read(familychatRepositoryProvider).memberProfile(userId);
      if (!mounted) return;
      setState(() {
        _peerStatusLabel = userPresenceFromProfile(profile).label;
        final url = profile['avatar_url']?.toString().trim();
        _headerAvatarUrl = url != null && url.isNotEmpty ? url : _headerAvatarUrl;
      });
    } catch (_) {}
  }

  Future<void> _init() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      _currentUserId = st['user_id'] as int?;
      final entitlements = st['entitlements'];
      if (entitlements is Map) {
        _viewerIndividualPremium = entitlements['individual_premium'] == true;
      }
    } catch (_) {}
    // Модель Vosk заранее (без сети) — на случай отправки в premium-треде.
    unawaited(ChatVoiceTranscription.instance.preloadModelToDisk());
    final skipCache = widget.initialMessageId != null;
    List<Map<String, dynamic>>? cached;
    if (!skipCache) {
      cached = await FamilyChatLocalCache.readThreadMessages(widget.threadId);
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() {
          _messages = sortChatMessages(cached!);
          _loading = false;
        });
        _scrollToBottom(jump: true, settle: true);
      }
    }
    await _load(silent: !skipCache && cached != null && cached.isNotEmpty);
    await _injectScheduledMessages();
    final targetId = widget.initialMessageId;
    if (targetId != null) {
      await _ensureMessageLoaded(targetId);
      await _scrollToMessage(targetId);
    } else {
      _scrollToBottom(jump: true, settle: true);
    }
  }

  Future<void> _ensureMessageLoaded(int messageId) async {
    if (_messages.any((m) => chatAsInt(m['id']) == messageId)) return;
    var guard = 0;
    while (_hasMoreOlder && guard < 30) {
      guard += 1;
      await _loadOlder();
      if (_messages.any((m) => chatAsInt(m['id']) == messageId)) return;
    }
  }

  Future<void> _refreshParticipantsMeta() async {
    try {
      final list =
          await ref.read(familychatRepositoryProvider).threadParticipants(
                widget.threadId,
              );
      if (!mounted) return;
      setState(() {
        _participantUserIds = list
            .map((p) => p['user_id'])
            .map((id) => id is int ? id : int.tryParse('$id'))
            .whereType<int>()
            .toList();
        _mentionParticipants = list
            .map((p) {
              final userId = p['user_id'];
              final parsedId = userId is int ? userId : int.tryParse('$userId');
              if (parsedId == null) return null;
              return ChatMentionParticipant(
                userId: parsedId,
                displayName: p['display_name']?.toString() ?? 'Участник',
                avatarUrl: p['avatar_url']?.toString() ?? '',
              );
            })
            .whereType<ChatMentionParticipant>()
            .toList();
      });
    } catch (_) {}
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingOlder || !_hasMoreOlder)
      return;
    if (_scrollController.position.pixels <= 72) {
      unawaited(_loadOlder());
    }
  }

  Future<void> _persistMessageCache() async {
    if (_messages.isEmpty) return;
    final kept = _messages.where((m) {
      final id = chatAsInt(m['id']);
      if (id == null) return false;
      if (id > 0) return true;
      return m['_pending'] == true || m['read_status'] == 'queued';
    }).toList();
    if (kept.isEmpty) return;
    final slice = kept.length > FamilyChatLocalCache.maxCachedMessagesPerThread
        ? kept.sublist(kept.length - FamilyChatLocalCache.maxCachedMessagesPerThread)
        : kept;
    await FamilyChatLocalCache.saveThreadMessages(widget.threadId, slice);
  }

  @override
  void dispose() {
    _stopTypingLocal();
    _clearRemoteTyping();
    _peerStatusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onComposeTextChanged);
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    if (ActiveChatContext.instance.openThreadId == widget.threadId) {
      ActiveChatContext.instance.setOpenThread(null);
    }
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    ChatOfflineSync.instance.removeListener(_onOfflineSync);
    ChatScheduledSendService.instance.removeListener(_onScheduledSend);
    _transcriptPollTimer?.cancel();
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
    } else if (_controller.text.trim().isEmpty) {
      _stopTypingLocal();
    }
  }

  void _onComposeTextChanged() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _typingStopTimer?.cancel();
      _typingStopTimer = Timer(const Duration(milliseconds: 800), () {
        _stopTypingLocal();
      });
      return;
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    _emitTypingPulse();
    _typingStopTimer = Timer(const Duration(seconds: 3), () {
      _stopTypingLocal();
    });
  }

  void _emitTypingPulse() {
    final now = DateTime.now();
    final last = _lastTypingEmitAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      _typingEmitTimer ??= Timer(const Duration(seconds: 2), () {
        _typingEmitTimer = null;
        if (_controller.text.trim().isNotEmpty) {
          _emitTypingPulse();
        }
      });
      return;
    }
    _lastTypingEmitAt = now;
    _typingEmitted = true;
    FamilyChatRealtime.instance.sendTyping(
      threadId: widget.threadId,
      isTyping: true,
    );
  }

  void _stopTypingLocal() {
    _typingEmitTimer?.cancel();
    _typingEmitTimer = null;
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    if (!_typingEmitted) return;
    FamilyChatRealtime.instance.sendTyping(
      threadId: widget.threadId,
      isTyping: false,
    );
    _typingEmitted = false;
    _lastTypingEmitAt = null;
  }

  void _clearRemoteTyping() {
    for (final timer in _typingExpiry.values) {
      timer.cancel();
    }
    _typingExpiry.clear();
    _typingNames.clear();
  }

  void _onRemoteTyping({
    required int userId,
    required String displayName,
    required bool isTyping,
  }) {
    if (_currentUserId != null && userId == _currentUserId) return;
    _typingExpiry[userId]?.cancel();
    if (!isTyping) {
      _typingExpiry.remove(userId);
      if (!_typingNames.containsKey(userId)) return;
      setState(() => _typingNames.remove(userId));
      return;
    }
    final changed = _typingNames[userId] != displayName ||
        !_typingNames.containsKey(userId);
    _typingNames[userId] = displayName.isNotEmpty ? displayName : 'Участник';
    _typingExpiry[userId] = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _typingNames.remove(userId);
        _typingExpiry.remove(userId);
      });
    });
    if (changed && mounted) setState(() {});
  }

  String? get _headerStatusSubtitle {
    if (_typingNames.isNotEmpty) {
      final label = chatTypingSubtitle(
        isDm: _isDm,
        displayNames: _typingNames.values.toList(),
      );
      if (label.isNotEmpty) return label;
    }
    if (_isGroupLike && !_hasLeft && _participantUserIds.isNotEmpty) {
      return chatParticipantCountLabel(_participantUserIds.length);
    }
    if (_isDm) return _peerStatusLabel;
    return null;
  }

  void _syncScrollForKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bottom = MediaQuery.viewInsetsOf(context).bottom;
      if ((bottom - _lastKeyboardInset).abs() < 1) return;
      _lastKeyboardInset = bottom;
      _scrollToBottom(jump: true, settle: true);
    });
  }

  void _scrollToBottom({bool jump = false, bool settle = false}) {
    void apply() {
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
    }

    void scheduleSettle(int framesLeft, double? previousExtent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final extent = _scrollController.position.maxScrollExtent;
        apply();
        if (framesLeft <= 0) return;
        if (previousExtent != null && (extent - previousExtent).abs() < 1) {
          if (framesLeft > 1) {
            scheduleSettle(1, extent);
          }
          return;
        }
        scheduleSettle(framesLeft - 1, extent);
      });
    }

    if (settle) {
      scheduleSettle(8, null);
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted) return;
        apply();
      });
      Future<void>.delayed(const Duration(milliseconds: 320), () {
        if (!mounted) return;
        apply();
      });
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }

  Future<void> _scrollToMessage(int messageId) async {
    final exists = _messages.any((m) => chatAsInt(m['id']) == messageId);
    if (!exists) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Сообщение не найдено в загруженной истории')),
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

    if (event['event'] == 'chat_typing') {
      if (eventThreadId != null && eventThreadId != widget.threadId) return;
      final userId = chatAsInt(event['user_id']);
      if (userId == null) return;
      final isTyping = event['is_typing'] != false;
      _onRemoteTyping(
        userId: userId,
        displayName: event['display_name']?.toString() ?? '',
        isTyping: isTyping,
      );
      return;
    }

    if (event['event'] == 'chat_refresh') {
      // Без thread_id — глобальный refresh (web poll / reconnect).
      if (eventThreadId != null && eventThreadId != widget.threadId) return;
      unawaited(_load(silent: true));
      return;
    }

    if (event['event'] == 'chat_message') {
      final msg = event['message'];
      if (msg is! Map) return;
      final map = chatNormalizeMap(Map<dynamic, dynamic>.from(msg));
      if (chatAsInt(map['thread_id']) != widget.threadId) return;
      final senderId = chatAsInt(map['sender_user_id']);
      if (senderId != null) {
        _onRemoteTyping(userId: senderId, displayName: '', isTyping: false);
      }
      if (!mounted) return;
      setState(() {
        var next = _messages;
        if (_currentUserId != null && senderId == _currentUserId) {
          next = next.where((m) => m['_pending'] != true).toList();
        }
        _messages = chatUpsertMessage(next, map);
      });
      _maybeScheduleVoiceTranscriptPoll(map);
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
    final generation = ++_loadGeneration;
    if (!silent && _messages.isEmpty) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final page = await ref.read(familychatRepositoryProvider).threadMessages(
            widget.threadId,
            limit: FamilyChatLocalCache.maxCachedMessagesPerThread,
          );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (silent && _messages.length > FamilyChatLocalCache.maxCachedMessagesPerThread) {
          _messages = _mergeLatestMessages(_messages, page.messages);
        } else if (silent) {
          _messages = chatMergeMessageLists(_messages, page.messages);
        } else {
          _messages = sortChatMessages(page.messages);
        }
        _hasMoreOlder = page.hasMore;
        _voiceTranscriptionEnabled = page.voiceTranscriptionEnabled;
        _loading = false;
        _loadError = null;
        if (_isBirthdayCelebration) {
          _birthdayScheduled = page.birthdayScheduled;
        }
      });
      unawaited(_persistMessageCache());
      unawaited(_markLatestRead());
      for (final message in _messages) {
        _maybeScheduleVoiceTranscriptPoll(message);
      }
      if (silent || widget.initialMessageId == null) {
        _scrollToBottom(jump: true, settle: true);
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      if (_messages.isNotEmpty) {
        setState(() {
          _loading = false;
          _loadError = null;
        });
      } else {
        setState(() {
          _loading = false;
          _loadError = OfflineUi.loadErrorMessage(
            e,
            fallback: 'Не удалось загрузить сообщения',
          );
        });
      }
    }
  }

  bool _voiceMessageNeedsTranscriptPoll(Map<String, dynamic> message) {
    if (!_viewerIndividualPremium || !_voiceTranscriptionEnabled) return false;
    final voice = message['metadata']?['voice'];
    if (voice is! Map) return false;
    final text = voice['transcript']?.toString().trim();
    if (text != null && text.isNotEmpty) return false;
    final status = voice['transcript_status']?.toString();
    if (status == 'failed') return false;
    return true;
  }

  void _maybeScheduleVoiceTranscriptPoll(Map<String, dynamic> message) {
    final id = chatAsInt(message['id']);
    if (id == null || id <= 0) return;
    if (!_voiceMessageNeedsTranscriptPoll(message)) {
      _transcriptPollAttempts.remove(id);
      return;
    }
    if (_transcriptPollAttempts.containsKey(id)) return;
    _transcriptPollAttempts[id] = 0;
    _ensureTranscriptPollTimer();
  }

  void _ensureTranscriptPollTimer() {
    _transcriptPollTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (_transcriptPollAttempts.isEmpty) {
        _transcriptPollTimer?.cancel();
        _transcriptPollTimer = null;
        return;
      }
      unawaited(_pollVoiceTranscripts());
    });
  }

  Future<void> _pollVoiceTranscripts() async {
    if (!mounted || _transcriptPollAttempts.isEmpty) return;
    const maxAttempts = 15;

    final pendingIds = _transcriptPollAttempts.keys.toList();
    for (final id in pendingIds) {
      final count = (_transcriptPollAttempts[id] ?? 0) + 1;
      if (count > maxAttempts) {
        _transcriptPollAttempts.remove(id);
        continue;
      }
      _transcriptPollAttempts[id] = count;
    }
    if (_transcriptPollAttempts.isEmpty) {
      _transcriptPollTimer?.cancel();
      _transcriptPollTimer = null;
      return;
    }

    try {
      final page = await ref.read(familychatRepositoryProvider).threadMessages(
            widget.threadId,
            limit: FamilyChatLocalCache.maxCachedMessagesPerThread,
          );
      if (!mounted) return;
      var updated = false;
      for (final incoming in page.messages) {
        final id = chatAsInt(incoming['id']);
        if (id == null || !_transcriptPollAttempts.containsKey(id)) continue;
        if (!_voiceMessageNeedsTranscriptPoll(incoming)) {
          _transcriptPollAttempts.remove(id);
        }
        final idx = _messages.indexWhere((m) => chatAsInt(m['id']) == id);
        if (idx >= 0) {
          final currentVoice = _messages[idx]['metadata']?['voice'];
          final incomingVoice = incoming['metadata']?['voice'];
          if (incomingVoice != currentVoice) {
            updated = true;
          }
        }
      }
      if (updated) {
        setState(() {
          _messages = chatMergeMessageLists(_messages, page.messages);
        });
        unawaited(_persistMessageCache());
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> _mergeLatestMessages(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> latest,
  ) {
    if (latest.isEmpty) return sortChatMessages(current);
    final oldestLatestId = chatAsInt(latest.first['id']);
    if (oldestLatestId == null) return sortChatMessages(latest);
    final olderKept = current.where((m) {
      final id = chatAsInt(m['id']);
      return id != null && id > 0 && id < oldestLatestId;
    }).toList();
    final latestIds =
        latest.map((m) => chatAsInt(m['id'])).whereType<int>().toSet();
    final mergedOlder = olderKept
        .where((m) => !latestIds.contains(chatAsInt(m['id'])))
        .toList();
    return sortChatMessages([...mergedOlder, ...latest]);
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder || _messages.isEmpty) return;
    final firstId = chatAsInt(_messages.first['id']);
    if (firstId == null || firstId <= 0) return;

    setState(() => _loadingOlder = true);
    final previousExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final previousPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;

    try {
      final page = await ref.read(familychatRepositoryProvider).threadMessages(
            widget.threadId,
            limit: FamilyChatLocalCache.maxCachedMessagesPerThread,
            beforeId: firstId,
          );
      if (!mounted) return;
      final existingIds =
          _messages.map((m) => chatAsInt(m['id'])).whereType<int>().toSet();
      final older = page.messages.where((m) {
        final id = chatAsInt(m['id']);
        return id != null && !existingIds.contains(id);
      }).toList();
      setState(() {
        _messages = sortChatMessages([...older, ..._messages]);
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

  Future<void> _openBirthdayCongratulationDialog() async {
    final mine = (_birthdayScheduled?['mine'] as Map<String, dynamic>?) ?? {};
    final initial = mine['body']?.toString() ?? '';
    await showBirthdayScheduledCongratulationDialog(
      context: context,
      initialText: initial,
      onSave: (body) async {
        setState(() => _birthdayScheduledSaving = true);
        try {
          final data = await ref
              .read(familychatRepositoryProvider)
              .saveBirthdayScheduledCongratulation(
                widget.threadId,
                body: body,
              );
          if (!mounted) return;
          setState(() => _birthdayScheduled = data);
        } finally {
          if (mounted) setState(() => _birthdayScheduledSaving = false);
        }
      },
      onDelete: initial.trim().isEmpty
          ? null
          : () async {
              setState(() => _birthdayScheduledSaving = true);
              try {
                final data = await ref
                    .read(familychatRepositoryProvider)
                    .deleteBirthdayScheduledCongratulation(widget.threadId);
                if (!mounted) return;
                setState(() => _birthdayScheduled = data);
              } finally {
                if (mounted) setState(() => _birthdayScheduledSaving = false);
              }
            },
    );
  }

  int _nextTempId() => _tempIdCounter--;

  Future<void> _injectScheduledMessages() async {
    final items = await ChatScheduledSendService.itemsForThread(widget.threadId);
    if (!mounted || items.isEmpty) return;
    var changed = false;
    final merged = [..._messages];
    for (final item in items) {
      final scheduleId = item['id']?.toString();
      if (scheduleId == null || scheduleId.isEmpty) continue;
      if (merged.any((m) => m['schedule_id']?.toString() == scheduleId)) {
        continue;
      }
      merged.add(_scheduledItemToMessage(item));
      changed = true;
    }
    if (!changed || !mounted) return;
    setState(() => _messages = sortChatMessages(merged));
    _scrollToBottom(jump: true, settle: true);
  }

  Map<String, dynamic> _scheduledItemToMessage(Map<String, dynamic> item) {
    final attachments = <Map<String, dynamic>>[];
    final rawAttachments = item['attachments'];
    if (rawAttachments is List) {
      for (final raw in rawAttachments) {
        if (raw is! Map) continue;
        attachments.add({
          'kind': 'file',
          'filename': raw['filename']?.toString() ?? 'Файл',
        });
      }
    }
    return {
      'id': _nextTempId(),
      'schedule_id': item['id']?.toString(),
      '_scheduled': true,
      '_pending': true,
      'thread_id': widget.threadId,
      'body': item['body']?.toString() ?? '',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'scheduled_at': item['send_at']?.toString(),
      'sender_user_id': _currentUserId,
      'sender_name': '',
      'sender_avatar_url': '',
      'attachments': attachments,
      'read_status': 'scheduled',
      if (item['reply_to_message_id'] != null)
        'reply_to': {
          'message_id': item['reply_to_message_id'],
          'sender_name': '',
          'body': '',
        },
    };
  }

  void _addOptimisticMessage(
    int tempId, {
    required String body,
    required List<Map<String, dynamic>> attachments,
    Map<String, dynamic>? replyTo,
    Map<String, dynamic>? metadata,
  }) {
    setState(() {
      _messages = sortChatMessages([
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
          if (metadata != null) 'metadata': metadata,
        },
      ]);
    });
    _scrollToBottom();
  }

  void _replaceOptimisticMessage(int tempId, Map<String, dynamic> msg) {
    setState(() {
      Map<String, dynamic>? optimistic;
      for (final m in _messages) {
        if (m['id'] == tempId) {
          optimistic = m;
          break;
        }
      }
      final merged = _mergeVoiceMessageFromOptimistic(
        serverMessage: msg,
        optimistic: optimistic,
      );
      final withoutTemp =
          _messages.where((m) => m['id'] != tempId).toList();
      final msgId = chatAsInt(merged['id']);
      if (msgId == null || !withoutTemp.any((m) => chatAsInt(m['id']) == msgId)) {
        _messages = chatUpsertMessage(withoutTemp, merged);
      } else {
        _messages = sortChatMessages(withoutTemp);
      }
    });
  }

  Map<String, dynamic> _mergeVoiceMessageFromOptimistic({
    required Map<String, dynamic> serverMessage,
    Map<String, dynamic>? optimistic,
  }) {
    if (optimistic == null) return serverMessage;

    final optimisticMeta = (optimistic['metadata'] as Map?)
            ?.map((key, value) => MapEntry(key.toString(), value)) ??
        const <String, dynamic>{};
    final serverMeta = (serverMessage['metadata'] as Map?)
            ?.map((key, value) => MapEntry(key.toString(), value)) ??
        const <String, dynamic>{};
    final mergedMeta = {
      ...serverMeta,
      if (optimisticMeta['voice'] is Map && serverMeta['voice'] == null)
        'voice': optimisticMeta['voice'],
    };

    final optimisticAtts = chatAttachmentsOf(optimistic);
    final serverAtts = chatAttachmentsOf(serverMessage);
    if (optimisticAtts.isEmpty || serverAtts.isEmpty) {
      return {
        ...serverMessage,
        if (mergedMeta.isNotEmpty) 'metadata': mergedMeta,
      };
    }

    final mergedAtts = serverAtts.asMap().entries.map((entry) {
      final att = Map<String, dynamic>.from(entry.value);
      if (entry.key < optimisticAtts.length) {
        final local = optimisticAtts[entry.key]['local_bytes'];
        if (local is Uint8List && local.isNotEmpty) {
          att['local_bytes'] = local;
        }
      }
      return att;
    }).toList();

    return {
      ...serverMessage,
      'metadata': mergedMeta,
      'attachments': mergedAtts,
    };
  }

  void _markOptimisticQueued(int tempId) {
    setState(() {
      _messages = _messages.map((m) {
        if (m['id'] == tempId) {
          return {...m, 'read_status': 'queued'};
        }
        return m;
      }).toList();
    });
  }

  Future<bool> _enqueueOfflineMessage({
    required int tempId,
    required String caption,
    required List<_OutgoingAttachment> attachments,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
  }) async {
    await ChatOfflineOutbox.enqueueMessage(
      threadId: widget.threadId,
      tempMessageId: tempId,
      body: caption.isEmpty ? null : caption,
      replyToMessageId: replyToMessageId,
      mentionedUserIds: mentionedUserIds,
      attachments: attachments
          .map(
            (att) => ChatOutboxAttachment(
              bytes: att.bytes,
              filename: att.filename,
              contentType: att.contentType,
            ),
          )
          .toList(),
    );
    _markOptimisticQueued(tempId);
    await _persistMessageCache();
    if (!mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Сообщение будет отправлено при появлении сети'),
      ),
    );
    return true;
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

  Future<bool> _uploadAndSend(
    int tempId, {
    required String caption,
    required List<_OutgoingAttachment> attachments,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
    bool notifySilent = false,
    int? voiceDurationMs,
    String? voiceTranscript,
  }) async {
    final repo = ref.read(familychatRepositoryProvider);
    final online = await ChatOfflineSync.instance.refreshOnline(repo);
    if (!online) {
      await _enqueueOfflineMessage(
        tempId: tempId,
        caption: caption,
        attachments: attachments,
        replyToMessageId: replyToMessageId,
        mentionedUserIds: mentionedUserIds,
      );
      return true;
    }
    try {
      final ids = <int>[];
      for (final att in attachments) {
        final uploaded = await repo.uploadChatAttachmentBytes(
          widget.threadId,
          bytes: att.bytes,
          filename: att.filename,
          contentType: att.contentType,
          photoExif: att.photoExif,
        );
        final id = chatAsInt(uploaded['id']);
        if (id != null) ids.add(id);
      }
      final msg = await repo.sendThreadMessage(
        widget.threadId,
        body: caption.isEmpty ? null : caption,
        attachmentIds: ids.isEmpty ? null : ids,
        replyToMessageId: replyToMessageId,
        mentionedUserIds:
            mentionedUserIds.isEmpty ? null : mentionedUserIds,
        notifySilent: notifySilent,
        voiceDurationMs: voiceDurationMs,
        voiceTranscript: voiceTranscript,
      );
      if (!mounted) return true;
      _replaceOptimisticMessage(tempId, msg);
      _scrollToBottom();
      await _persistMessageCache();
      for (var i = 0; i < attachments.length; i++) {
        if (i >= ids.length) break;
        final att = attachments[i];
        final isImage = att.kind == 'image' ||
            (att.contentType?.startsWith('image/') ??
                _imageContentTypeForFilename(att.filename)
                    ?.startsWith('image/') ??
                false);
        if (isImage) {
          unawaited(
            FamilyChatLocalCache.saveAttachmentBytes(
              widget.threadId,
              ids[i],
              att.bytes,
            ),
          );
          unawaited(_pollFaceTaggingPrompt(ids[i]));
        }
      }
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (ChatNetworkStatus.looksOffline(error)) {
        await _enqueueOfflineMessage(
          tempId: tempId,
          caption: caption,
          attachments: attachments,
          replyToMessageId: replyToMessageId,
          mentionedUserIds: mentionedUserIds,
        );
        return true;
      }
      _markOptimisticFailed(tempId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить сообщение')),
      );
      return false;
    }
  }

  Future<void> _sendVoiceMessage(
    Uint8List bytes,
    int durationMs, {
    String? encoderName,
  }) async {
    if (durationMs < 400) {
      return;
    }

    String? transcript;
    if (_voiceTranscriptionEnabled) {
      transcript =
          await ChatVoiceTranscription.instance.transcribeWavBytes(bytes);
    }

    final tempId = _nextTempId();
    final replySnapshot = _replyTo;
    final replyId = chatAsInt(replySnapshot?['message_id']);
    final extension = voiceExtensionForEncoder(encoderName ?? (kIsWeb ? 'wav' : 'm4a'));
    final filename = voiceMessageFilename(durationMs, extension: extension);
    final contentType = voiceContentTypeForExtension(extension);
    final voiceMeta = <String, dynamic>{'duration_ms': durationMs};
    if (transcript != null && transcript.trim().isNotEmpty) {
      voiceMeta['transcript'] = transcript.trim();
      voiceMeta['transcript_status'] = 'ready';
    }
    final metadata = {'voice': voiceMeta};

    _addOptimisticMessage(
      tempId,
      body: '',
      attachments: [
        {
          'kind': 'file',
          'filename': filename,
          'content_type': contentType,
          'local_bytes': bytes,
        },
      ],
      replyTo: replySnapshot,
      metadata: metadata,
    );
    if (_replyTo != null) {
      setState(() => _replyTo = null);
    }

    await _uploadAndSend(
      tempId,
      caption: '',
      attachments: [
        _OutgoingAttachment(
          bytes: bytes,
          filename: filename,
          contentType: contentType,
        ),
      ],
      replyToMessageId: replyId,
      voiceDurationMs: durationMs,
      voiceTranscript: transcript,
    );
  }

  Future<void> _sendLocationMessage(ChatLocationPoint point) async {
    final tempId = _nextTempId();
    final replySnapshot = _replyTo;
    final replyMessageId = chatAsInt(replySnapshot?['message_id']);
    final location = point.toJson();
    _addOptimisticMessage(
      tempId,
      body: '',
      attachments: const [],
      replyTo: replySnapshot,
      metadata: {'location': location},
    );
    if (_replyTo != null) {
      setState(() => _replyTo = null);
    }

    final repo = ref.read(familychatRepositoryProvider);
    final online = await ChatOfflineSync.instance.refreshOnline(repo);
    if (!online) {
      _markOptimisticFailed(tempId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Геолокацию можно отправить только при наличии сети'),
        ),
      );
      return;
    }

    try {
      final msg = await repo.sendThreadMessage(
        widget.threadId,
        location: location,
        replyToMessageId: replyMessageId,
      );
      if (!mounted) return;
      _replaceOptimisticMessage(tempId, msg);
      _scrollToBottom();
      await _persistMessageCache();
    } catch (_) {
      if (!mounted) return;
      _markOptimisticFailed(tempId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить геолокацию')),
      );
    }
  }

  Map<String, dynamic> _attachmentForFaceTagging(int attachmentId) {
    for (final m in _messages) {
      for (final a in chatAttachmentsOf(m)) {
        if (chatAsInt(a['id']) == attachmentId) {
          return Map<String, dynamic>.from(a);
        }
      }
    }
    return {
      'id': attachmentId,
      'thread_id': widget.threadId,
    };
  }

  Future<void> _pollFaceTaggingPrompt(int attachmentId) async {
    final repo = ref.read(familychatRepositoryProvider);
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final status =
            await repo.attachmentTaggingStatus(widget.threadId, attachmentId);
        final taggingStatus = status['photo_tagging_status']?.toString() ?? '';
        if (taggingStatus == 'failed') return;
        if (taggingStatus != 'done') continue;
        if (status['should_prompt_face_tagging'] != true) return;
        if (!mounted) return;
        final attachment = _attachmentForFaceTagging(attachmentId);
        Uint8List? localBytes;
        final rawLocal = attachment['local_bytes'];
        if (rawLocal is Uint8List && rawLocal.isNotEmpty) {
          localBytes = rawLocal;
        } else {
          localBytes = await FamilyChatLocalCache.readAttachmentBytes(
            widget.threadId,
            attachmentId,
          );
        }
        if (!mounted) return;
        await FaceTaggingSheet.show(
          context,
          threadId: widget.threadId,
          attachmentId: attachmentId,
          promptMode: true,
          imageChild: faceTaggingAttachmentPreview(
            threadId: widget.threadId,
            attachment: attachment,
            localBytes: localBytes,
          ),
        );
        return;
      } catch (_) {
        // retry until timeout
      }
    }
  }

  Future<void> _sendMediaDrafts(
    String caption,
    List<MediaUploadDraft> drafts,
  ) async {
    final uploadable = drafts.where((d) => d.canUpload).toList();
    if (uploadable.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нет файлов для отправки (проверьте размер видео)'),
          ),
        );
      }
      return;
    }

    final tempId = _nextTempId();
    final replySnapshot = _replyTo;
    final replyId = chatAsInt(replySnapshot?['message_id']);
    _addOptimisticMessage(
      tempId,
      body: caption,
      attachments: [
        for (final d in uploadable)
          {
            'kind': d.isVideo ? 'video' : (d.isImage ? 'image' : 'file'),
            'filename': d.filename,
            'content_type': d.contentType,
            if (d.thumbnailBytes != null) 'local_bytes': d.thumbnailBytes,
            if (d.isImage) 'local_bytes': d.bytesForUpload,
          },
      ],
      replyTo: replySnapshot,
    );
    if (_replyTo != null) {
      setState(() => _replyTo = null);
    }

    final ok = await _uploadAndSend(
      tempId,
      caption: caption,
      attachments: [
        for (final d in uploadable)
          _OutgoingAttachment(
            bytes: d.bytesForUpload,
            filename: d.filename,
            contentType: d.contentType,
            photoExif: d.geo?.toPhotoExif(),
            kind: d.isVideo ? 'video' : (d.isImage ? 'image' : 'file'),
          ),
      ],
      replyToMessageId: replyId,
    );
    if (!ok) {
      throw StateError('upload failed');
    }
  }

  /// Быстрая отправка из in-app шторки: сразу bubble + loader, сжатие в фоне.
  Future<void> _sendAttachItems(
    String caption,
    List<ChatAttachSelectionItem> items,
  ) async {
    if (items.isEmpty) return;

    final tempId = _nextTempId();
    final replySnapshot = _replyTo;
    final replyId = chatAsInt(replySnapshot?['message_id']);

    for (final item in items) {
      await ChatAttachLocalCache.storeBytes(
        id: item.id,
        bytes: item.bytes,
        filename: item.filename,
      );
    }

    _addOptimisticMessage(
      tempId,
      body: caption,
      attachments: [
        for (final item in items)
          {
            'kind': item.kind,
            'filename': item.filename,
            'content_type': item.contentType,
            'local_bytes': item.previewBytes,
          },
      ],
      replyTo: replySnapshot,
    );
    if (_replyTo != null) {
      setState(() => _replyTo = null);
    }

    try {
      final drafts = <MediaUploadDraft>[];
      for (final item in items) {
        if (item.kind == 'video') {
          drafts.add(
            await prepareVideoUploadDraft(
              originalBytes: item.bytes,
              filename: item.filename,
              contentType: item.contentType,
              localPath: item.localPath,
            ),
          );
        } else if (item.kind == 'image') {
          drafts.add(
            await prepareImageUploadDraft(
              originalBytes: item.bytes,
              filename: item.filename,
              contentType: item.contentType,
              previewBytes: item.thumbnailBytes,
              localPath: item.localPath,
            ),
          );
        } else {
          drafts.add(
            MediaUploadDraft(
              id: item.id,
              kind: MediaDraftKind.file,
              filename: item.filename,
              contentType: item.contentType ?? contentTypeForFilename(item.filename),
              originalBytes: item.bytes,
              preparedBytes: item.bytes,
              localPath: item.localPath,
            ),
          );
        }
      }

      final uploadable = drafts.where((d) => d.canUpload).toList();
      if (uploadable.isEmpty) {
        if (!mounted) return;
        _markOptimisticFailed(tempId);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нет файлов для отправки (проверьте размер)'),
          ),
        );
        return;
      }

      await _uploadAndSend(
        tempId,
        caption: caption,
        attachments: [
          for (final d in uploadable)
            _OutgoingAttachment(
              bytes: d.bytesForUpload,
              filename: d.filename,
              contentType: d.contentType,
              photoExif: d.geo?.toPhotoExif(),
              kind: d.isVideo ? 'video' : (d.isImage ? 'image' : 'file'),
            ),
        ],
        replyToMessageId: replyId,
      );
    } catch (_) {
      if (!mounted) return;
      _markOptimisticFailed(tempId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить вложение')),
      );
    }
  }

  // ignore: unused_element — kept for share/legacy callers
  Future<void> _sendImageWithCaption(
    Uint8List bytes,
    String filename,
    String caption, {
    String? contentType,
  }) async {
    final draft = await prepareImageUploadDraft(
      originalBytes: bytes,
      filename: filename,
      contentType: contentType ??
          _imageContentTypeForFilename(filename) ??
          'image/jpeg',
    );
    await _sendMediaDrafts(caption, [draft]);
  }

  Future<void> _pickAttachment() async {
    await ChatAttachSheet.show(
      context,
      onSendMedia: _sendAttachItems,
      onSendLocation: _sendLocationMessage,
    );
  }

  Future<void> _send({
    List<int> mentionedUserIds = const [],
    ChatSendOptions options = ChatSendOptions.normal,
  }) async {
    final body = _controller.text.trim();
    final fileDraft = _pendingFileDraft;
    if (body.isEmpty && fileDraft == null) return;

    final editingId = _editingMessageId;
    if (editingId != null && fileDraft == null) {
      // Редактирование существующего текстового сообщения.
      if (body.isEmpty) return;
      _stopTypingLocal();
      _controller.clear();
      setState(() {
        _editingMessageId = null;
      });
      try {
        final repo = ref.read(familychatRepositoryProvider);
        final updated = await repo.updateThreadMessage(
          widget.threadId,
          editingId,
          body: body,
        );
        if (!mounted) return;
        setState(() {
          _messages = _messages.map((m) {
            final id = chatAsInt(m['id']);
            if (id == editingId) {
              return {...m, ...updated};
            }
            return m;
          }).toList();
        });
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось изменить сообщение')),
        );
      }
      return;
    }

    final replyTo = _replyTo;
    final replyId = chatAsInt(replyTo?['message_id']);
    _stopTypingLocal();
    _controller.clear();
    setState(() {
      _pendingFileDraft = null;
      _replyTo = null;
      _editingMessageId = null;
    });

    if (options.isScheduled) {
      final outboxAttachments = fileDraft == null
          ? const <ChatOutboxAttachment>[]
          : [
              ChatOutboxAttachment(
                bytes: fileDraft.bytes,
                filename: fileDraft.filename,
                contentType: fileDraft.contentType,
              ),
            ];
      await ChatScheduledSendService.enqueue(
        threadId: widget.threadId,
        sendAt: options.scheduledAt!,
        body: body.isEmpty ? null : body,
        replyToMessageId: replyId,
        mentionedUserIds: mentionedUserIds,
        silent: options.silent,
        attachments: outboxAttachments,
      );
      await _injectScheduledMessages();
      if (!mounted) return;
      final when = DateFormat('d MMM, HH:mm', 'ru')
          .format(options.scheduledAt!.toLocal());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Сообщение будет отправлено $when')),
      );
      return;
    }

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
        mentionedUserIds: mentionedUserIds,
        notifySilent: options.silent,
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
      mentionedUserIds: mentionedUserIds,
      notifySilent: options.silent,
    );
  }

  String _messagePreviewText(Map<String, dynamic> message) {
    final body = message['body']?.toString().trim() ?? '';
    if (body.isNotEmpty) return body;
    final metadata = (message['metadata'] as Map?)
            ?.map((key, value) => MapEntry(key.toString(), value)) ??
        const <String, dynamic>{};
    if (metadata['voice'] is Map) return 'Голосовое сообщение';
    if (metadata['location'] is Map) return 'Геолокация';
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
      _editingMessageId = null;
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
      _editingMessageId = null;
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

  bool _canEditMessage(Map<String, dynamic> message) {
    if (!_isMine(message)) return false;
    if (message['_pending'] == true) return false;
    if (message['is_system'] == true) return false;
    return true;
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
      canEdit: _canEditMessage(message),
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
      case 'edit':
        _startEdit(message);
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

  void _startEdit(Map<String, dynamic> message) {
    final id = chatAsInt(message['id']);
    if (id == null) return;
    final body = message['body']?.toString() ?? '';
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
      _replyTo = null;
      _editingMessageId = id;
    });
    _controller
      ..text = body
      ..selection = TextSelection.collapsed(offset: body.length);
    _inputFocus.requestFocus();
  }

  Future<void> _toggleReaction(int messageId, String emoji) async {
    if (messageId <= 0) return;
    _applyReactionToggleLocal(messageId, emoji);
    final repo = ref.read(familychatRepositoryProvider);
    final online = await ChatOfflineSync.instance.refreshOnline(repo);
    if (!online) {
      await ChatOfflineOutbox.enqueueReaction(
        threadId: widget.threadId,
        messageId: messageId,
        emoji: emoji,
      );
      await _persistMessageCache();
      return;
    }
    try {
      final raw = await repo.toggleMessageReaction(
        widget.threadId,
        messageId,
        emoji,
      );
      if (!mounted) return;
      _applyMessageReactions(
        messageId,
        chatParseReactions(raw, currentUserId: _currentUserId),
      );
      await _persistMessageCache();
    } catch (error) {
      if (!mounted) return;
      if (ChatNetworkStatus.looksOffline(error)) {
        await ChatOfflineOutbox.enqueueReaction(
          threadId: widget.threadId,
          messageId: messageId,
          emoji: emoji,
        );
        await _persistMessageCache();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось поставить реакцию')),
      );
    }
  }

  void _applyReactionToggleLocal(int messageId, String emoji) {
    if (_currentUserId == null) return;
    setState(() {
      _messages = _messages.map((m) {
        if (chatAsInt(m['id']) != messageId) return m;
        final reactions = chatParseReactions(
          m['reactions'],
          currentUserId: _currentUserId,
        ).map((r) => Map<String, dynamic>.from(r)).toList();
        final idx = reactions.indexWhere((r) => r['emoji'] == emoji);
        if (idx >= 0) {
          final row = Map<String, dynamic>.from(reactions[idx]);
          final userIds = List<int>.from(row['user_ids'] as List? ?? []);
          if (userIds.contains(_currentUserId)) {
            userIds.remove(_currentUserId);
            if (userIds.isEmpty) {
              reactions.removeAt(idx);
            } else {
              row['user_ids'] = userIds;
              row['count'] = userIds.length;
              row['reacted_by_me'] = false;
              reactions[idx] = row;
            }
          } else {
            userIds.add(_currentUserId!);
            row['user_ids'] = userIds;
            row['count'] = userIds.length;
            row['reacted_by_me'] = true;
            reactions[idx] = row;
          }
        } else {
          reactions.add({
            'emoji': emoji,
            'count': 1,
            'user_ids': [_currentUserId!],
            'reacted_by_me': true,
          });
        }
        return {...m, 'reactions': reactions};
      }).toList();
    });
  }

  Future<void> _copyMessages(List<Map<String, dynamic>> messages) async {
    final parts =
        messages.map(_messagePreviewText).where((t) => t.isNotEmpty).toList();
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
      final deleted =
          await ref.read(familychatRepositoryProvider).deleteMessages(
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
    final targets = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute<List<int>>(
        builder: (_) => ChatForwardScreen(
          sourceThreadId: widget.threadId,
          messageIds: ids,
        ),
      ),
    );
    if (targets != null && targets.isNotEmpty && mounted) {
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

  void _applyThreadMeta(Map<String, dynamic> thread) {
    setState(() {
      _title = thread['title']?.toString() ?? _title;
      _customTitle = thread['custom_title']?.toString() ?? '';
      _hasLeft = thread['has_left'] == true;
      _canRejoin = thread['can_rejoin'] == true;
      _canLeave = thread['can_leave'] == true;
      _participantUserIds = (thread['participant_user_ids'] as List?)
              ?.map((e) => e is int ? e : int.tryParse('$e'))
              .whereType<int>()
              .toList() ??
          _participantUserIds;
      _isBirthdayCelebration = thread['is_birthday_celebration'] == true;
    });
  }

  Future<void> _rejoinChat() async {
    try {
      final thread = await ref
          .read(familychatRepositoryProvider)
          .rejoinChatThread(widget.threadId);
      if (!mounted) return;
      _applyThreadMeta(thread);
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _openInfo() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: true,
      builder: (_) => ChatInfoSheet(
        threadId: widget.threadId,
        title: _title,
        defaultTitle: widget.defaultTitle ?? widget.title,
        customTitle: _customTitle,
        kind: widget.kind,
        hasLeft: _hasLeft,
        canRejoin: _canRejoin,
        canLeave: _canLeave,
        participantUserIds: _participantUserIds,
        peerUserId: widget.peerUserId,
        isBirthdayCelebration: _isBirthdayCelebration,
        initialHeaderAvatarUrl: _headerAvatarUrl,
        onFriendHidden: () {
          if (!mounted) return;
          Navigator.of(context).pop();
        },
        onTitleChanged: (title, customTitle) {
          if (!mounted) return;
          setState(() {
            _title = title;
            _customTitle = customTitle;
          });
        },
        onMembershipChanged: () async {
          try {
            final threads =
                await ref.read(familychatRepositoryProvider).chatThreads();
            final thread = threads.cast<Map<String, dynamic>?>().firstWhere(
                  (t) => t?['id'] == widget.threadId,
                  orElse: () => null,
                );
            if (thread == null) {
              if (mounted) Navigator.of(context).pop();
              return;
            }
            if (!mounted) return;
            _applyThreadMeta(thread);
            await _refreshParticipantsMeta();
            if (_hasLeft) {
              setState(() => _messages = []);
            } else {
              setState(() => _loading = true);
              await _load();
            }
          } catch (_) {}
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
      onGoToMessage:
          messageId != null ? () => _scrollToMessage(messageId) : null,
      httpHeaders: headers,
    );
  }

  void _openImageFromAttachment(Map<String, dynamic> attachment,
      {int? messageId}) {
    if (isVideoAttachment(attachment)) {
      final repo = ref.read(familychatRepositoryProvider);
      final url = chatAttachmentImageUrl(
        repo: repo,
        threadId: widget.threadId,
        attachment: attachment,
      );
      if (url.isEmpty) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(12),
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: Stack(
              children: [
                GalleryVideoPlayer(url: url, autoplay: true),
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return;
    }
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
    if (_isMine(_messages[index]) != _isMine(_messages[nextIndex]))
      return false;
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
            ? FamilyAppBar.build(
                title: '${_selectedMessageIds.length} выбрано',
                automaticallyImplyLeading: false,
                leading: IconButton(
                  tooltip: 'Отменить выбор',
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close),
                ),
                actions: [
                  TextButton(
                    onPressed: _selectableMessageIds.isEmpty
                        ? null
                        : _toggleSelectAllMessages,
                    child: Text(
                        _allMessagesSelected ? 'Снять все' : 'Выбрать все'),
                  ),
                  if (_canDeleteSelection)
                    IconButton(
                      tooltip: 'Удалить',
                      onPressed: _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  IconButton(
                    tooltip: 'Скопировать',
                    onPressed:
                        _selectedMessageIds.isEmpty ? null : _copySelected,
                    icon: const Icon(Icons.copy),
                  ),
                ],
              )
            : FamilyAppBar.buildCustom(
                title: InkWell(
                  onTap: _openInfo,
                  child: Row(
                    children: [
                      ChatAvatar(
                        name: _title,
                        avatarUrl: _headerAvatarUrl,
                        userId: widget.peerUserId,
                        assetPath: chatThreadAvatarAsset(
                          kind: widget.kind,
                          isBirthdayCelebration: _isBirthdayCelebration,
                        ),
                        radius: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_headerStatusSubtitle != null)
                              Text(
                                _headerStatusSubtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: _typingNames.isNotEmpty
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                    ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  if (_isDm && _canSend && !_loading)
                    IconButton(
                      tooltip: 'Аудиозвонок',
                      onPressed: _startOutgoingCall,
                      icon: const Icon(Icons.call_outlined),
                    ),
                  IconButton(
                    tooltip: 'Поиск',
                    onPressed: _loading ? null : _openSearch,
                    icon: const Icon(Icons.search),
                  ),
                ],
              ),
        body: Column(
          children: [
            if (_hasLeft)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.logout, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          widget.kind == 'family'
                              ? 'Вы покинули общий чат семьи'
                              : 'Вы не состоите в этой группе',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_canRejoin) ...[
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _rejoinChat,
                            child: const Text('Вернуться в чат'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              )
            else ...[
              Expanded(
                child: _loading
                    ? const ChatMessagesSkeleton()
                    : _loadError != null && _messages.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _loadError!,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton(
                                    onPressed: _load,
                                    child: const Text('Повторить'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              controller: _scrollController,
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              itemCount:
                                  _messages.length + (_loadingOlder ? 1 : 0),
                              itemBuilder: (context, i) {
                                if (_loadingOlder && i == 0) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      ),
                                    ),
                                  );
                                }
                                final msgIndex = _loadingOlder ? i - 1 : i;
                                final m = _messages[msgIndex];
                                final msgId = chatAsInt(m['id']) ?? 0;
                                _messageKeys.putIfAbsent(msgId, GlobalKey.new);
                                final created = DateTime.tryParse(
                                    m['created_at']?.toString() ?? '');
                                final atts = chatAttachmentsOf(m);
                                final isMine = _isMine(m);
                                final senderUserId = _senderId(m);
                                final replyTo =
                                    m['reply_to'] as Map<String, dynamic>?;
                                final forward =
                                    m['forward'] as Map<String, dynamic>?;
                                final reactions = chatParseReactions(
                                  m['reactions'],
                                  currentUserId: _currentUserId,
                                );
                                final mentions = (m['mentions'] as List?)
                                        ?.map((e) =>
                                            Map<String, dynamic>.from(e as Map))
                                        .toList() ??
                                    const <Map<String, dynamic>>[];
                                final replyMessageId =
                                    chatAsInt(replyTo?['message_id']);
                                final messageMetadata =
                                    (m['metadata'] as Map?)
                                            ?.map(
                                              (key, value) => MapEntry(
                                                key.toString(),
                                                value,
                                              ),
                                            ) ??
                                        const <String, dynamic>{};
                                final location = ChatLocationPoint.fromMetadata(
                                  messageMetadata,
                                );
                                final isSystem = m['is_system'] == true;
                                if (isSystem) {
                                  final metadata = messageMetadata;
                                  if (metadata['kind']?.toString() == 'call' &&
                                      _currentUserId != null) {
                                    return KeyedSubtree(
                                      key: _messageKeys[msgId],
                                      child: ChatCallHistoryBanner(
                                        metadata: metadata,
                                        currentUserId: _currentUserId!,
                                        createdAt: created,
                                        onRedial: _isDm ? _startOutgoingCall : null,
                                      ),
                                    );
                                  }
                                  if (_isBirthdayCelebration &&
                                      metadata['subtype']?.toString() ==
                                          'welcome_prep') {
                                    return KeyedSubtree(
                                      key: _messageKeys[msgId],
                                      child: ChatBirthdayWelcomeBanner(
                                        body: m['body']?.toString() ?? '',
                                        createdAt: created,
                                        scheduled: _birthdayScheduled,
                                        saving: _birthdayScheduledSaving,
                                        onCompose: _birthdayScheduled?['can_write'] == true
                                            ? _openBirthdayCongratulationDialog
                                            : null,
                                      ),
                                    );
                                  }
                                  return KeyedSubtree(
                                    key: _messageKeys[msgId],
                                    child: ChatSystemMessageBanner(
                                      body: m['body']?.toString() ?? '',
                                      createdAt: created,
                                      highlighted: _highlightMessageId == msgId,
                                    ),
                                  );
                                }
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
                                    mentions: mentions,
                                    location: location,
                                    messageMetadata: messageMetadata,
                                    canToggleVoiceTranscript:
                                        _viewerIndividualPremium,
                                    isGroupLike: _isGroupLike,
                                    readStatus: isMine
                                        ? m['read_status']?.toString() ??
                                            (m['_scheduled'] == true
                                                ? 'scheduled'
                                                : m['_pending'] == true
                                                    ? 'sending'
                                                    : 'sent')
                                        : null,
                                    scheduledAt: m['scheduled_at'] != null
                                        ? DateTime.tryParse(
                                            m['scheduled_at']?.toString() ?? '',
                                          )
                                        : null,
                                    showGroupAvatarColumn:
                                        _showGroupAvatarColumn(i),
                                    showSenderAvatar: _showSenderAvatar(i),
                                    senderName: m['sender_name']?.toString(),
                                    senderAvatarUrl:
                                        m['sender_avatar_url']?.toString(),
                                    onSenderAvatarTap: senderUserId != null
                                        ? () => _openSenderProfile(senderUserId)
                                        : null,
                                    compactWithNext: _clusteredWithNext(i),
                                    highlighted: _highlightMessageId == msgId,
                                    selectionMode: _selectionMode,
                                    selected:
                                        _selectedMessageIds.contains(msgId),
                                    onTap: _selectionMode
                                        ? () => _toggleSelection(msgId)
                                        : m['_scheduled'] == true
                                            ? null
                                            : () => _openMessageMenu(m),
                                    onLongPress: m['_pending'] == true
                                        ? null
                                        : () => _enterSelection(msgId),
                                    onReplyTap: replyMessageId != null
                                        ? () => _scrollToMessage(replyMessageId)
                                        : null,
                                    onSwipeReply: _selectionMode ||
                                            m['_pending'] == true ||
                                            m['_scheduled'] == true
                                        ? null
                                        : () => _startReply(m),
                                    onReactionTap: m['_pending'] == true
                                        ? null
                                        : (emoji) =>
                                            _toggleReaction(msgId, emoji),
                                    onImageTap: (a) => _openImageFromAttachment(
                                        a,
                                        messageId: msgId),
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
                                final msg =
                                    _messageById(_selectedMessageIds.first);
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
                            onPressed: _selectedMessageIds.isEmpty
                                ? null
                                : _forwardSelected,
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
                      if (_isFriendDm && !_canSend)
                        Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                            child: Text(
                              'Переписка недоступна: нужен Individual Premium '
                              'у одного из участников. История сохранена.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      if (_replyTo != null)
                        ChatReplyComposeBar(
                          senderName:
                              _replyTo!['sender_name']?.toString() ?? '',
                          body: _replyTo!['body']?.toString() ?? '',
                          onCancel: () => setState(() => _replyTo = null),
                        ),
                      if (_editingMessageId != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Редактирование сообщения',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ),
                              TextButton(
                                onPressed: () => setState(
                                  () => _editingMessageId = null,
                                ),
                                child: const Text('Отмена'),
                              ),
                            ],
                          ),
                        ),
                      if (_pendingFileDraft != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                          child: ChatPendingFileChip(
                            filename: _pendingFileDraft!.filename,
                            onRemove: () =>
                                setState(() => _pendingFileDraft = null),
                          ),
                        ),
                      if (_canSend)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: _isGroupLike
                              ? ChatMentionComposeInput(
                                  controller: _controller,
                                  focusNode: _inputFocus,
                                  onAttach: _pickAttachment,
                                  onSend: (options, mentionedUserIds) =>
                                      unawaited(
                                    _send(
                                      mentionedUserIds: mentionedUserIds,
                                      options: options,
                                    ),
                                  ),
                                  onVoiceComplete: _sendVoiceMessage,
                                  forceSendButton: _pendingFileDraft != null ||
                                      _editingMessageId != null,
                                  voiceTranscriptionEnabled:
                                      _voiceTranscriptionEnabled,
                                  participants: _mentionParticipants,
                                  currentUserId: _currentUserId,
                                )
                              : ChatComposeInput(
                                  controller: _controller,
                                  focusNode: _inputFocus,
                                  onAttach: _pickAttachment,
                                  onSend: (options) =>
                                      unawaited(_send(options: options)),
                                  onVoiceComplete: _sendVoiceMessage,
                                  forceSendButton: _pendingFileDraft != null ||
                                      _editingMessageId != null,
                                  voiceTranscriptionEnabled:
                                      _voiceTranscriptionEnabled,
                                ),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
