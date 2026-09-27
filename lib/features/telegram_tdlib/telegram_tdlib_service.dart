import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/network/chat_network_link.dart';
import '../../core/network/api_client.dart';
import '../../core/notifications/familychat_notifications.dart';
import '../../firebase_options.dart';
import '../chat/data/chat_media_display_policy.dart';
import '../familychat/data/familychat_repository.dart';
import 'tdlib_config.dart';
import 'tdlib_json_client.dart';
import 'telegram_link_utils.dart';
import 'telegram_match_store.dart';
import 'telegram_tdlib_push.dart';

enum TdlibAuthPhase {
  unavailable,
  starting,
  waitPhone,
  waitCode,
  waitPassword,
  ready,
  loggingOut,
  error,
}

class _TdlibDownloadJob {
  _TdlibDownloadJob({
    required this.fileId,
    required this.priority,
    required this.background,
    this.chatId,
    this.reason = '',
  });

  final int fileId;
  int priority;
  bool background;
  int? chatId;
  String reason;
}

class _TdlibDownloadTrace {
  _TdlibDownloadTrace({
    required this.fileId,
    required this.reason,
    required this.priority,
    required this.background,
    this.chatId,
  }) : enqueuedAt = DateTime.now();

  final int fileId;
  String reason;
  int priority;
  bool background;
  int? chatId;
  final DateTime enqueuedAt;
  DateTime? startedAt;
  DateTime? lastProgressAt;
  DateTime? lastStartAt;
  int expectedSize = 0;
  int lastBytes = 0;
  bool fromDiskCache = false;
  bool downloadAcked = false;
  bool recoverAttempted = false;
  /// How many size-downgrade attempts after a 0B stall for this focus.
  int sizeFallbackAttempt = 0;
  String remoteUniqueId = '';
}

class TdlibChatPreview {
  const TdlibChatPreview({
    required this.chatId,
    required this.title,
    required this.userId,
    this.isGroup = false,
    this.isChannel = false,
    this.photoFileId,
    this.photoLocalPath,
    this.photoMinithumbnailBytes,
    this.lastMessageText = '',
    this.lastMessageDate = 0,
    this.unreadCount = 0,
    this.lastMessageOutgoing = false,
    this.lastMessageReadStatus,
  });

  final int chatId;
  /// Peer user id for private chats; 0 for groups/channels.
  final int userId;
  final bool isGroup;
  final bool isChannel;
  final String title;
  final int? photoFileId;
  final String? photoLocalPath;
  /// Low-res JPEG from TDLib until file download completes.
  final List<int>? photoMinithumbnailBytes;
  final String lastMessageText;
  final int lastMessageDate;
  final int unreadCount;
  final bool lastMessageOutgoing;
  /// `sent` / `read` for own last message; null otherwise.
  final String? lastMessageReadStatus;
}

class TdlibUserProfile {
  const TdlibUserProfile({
    required this.userId,
    required this.displayName,
    this.username = '',
    this.phoneNumber = '',
    this.bio = '',
    this.statusText = '',
    this.avatarLocalPath,
    this.avatarFileId,
  });

  final int userId;
  final String displayName;
  final String username;
  final String phoneNumber;
  final String bio;
  final String statusText;
  final String? avatarLocalPath;
  final int? avatarFileId;
}

/// Channel / group profile for the TG info sheet (tap avatar in app bar).
class TdlibChatProfile {
  const TdlibChatProfile({
    required this.chatId,
    required this.title,
    required this.isChannel,
    this.memberCount = 0,
    this.username = '',
    this.description = '',
    this.inviteLink = '',
    this.linkedChatId = 0,
    this.avatarLocalPath,
    this.avatarFileId,
    this.avatarMinithumbnailBytes,
  });

  final int chatId;
  final String title;
  final bool isChannel;
  final int memberCount;
  final String username;
  final String description;
  final String inviteLink;
  final int linkedChatId;
  final String? avatarLocalPath;
  final int? avatarFileId;
  final List<int>? avatarMinithumbnailBytes;

  String get kindLabel => isChannel ? 'канал' : 'группа';

  String get memberCountLabel {
    final n = memberCount;
    if (n <= 0) return kindLabel;
    final mod10 = n % 10;
    final mod100 = n % 100;
    final word = isChannel
        ? (mod100 >= 11 && mod100 <= 14
            ? 'подписчиков'
            : mod10 == 1
                ? 'подписчик'
                : (mod10 >= 2 && mod10 <= 4 ? 'подписчика' : 'подписчиков'))
        : (mod100 >= 11 && mod100 <= 14
            ? 'участников'
            : mod10 == 1
                ? 'участник'
                : (mod10 >= 2 && mod10 <= 4 ? 'участника' : 'участников'));
    final formatted = n >= 1000
        ? n.toString().replaceAllMapped(
              RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
              (m) => '${m[1]},',
            )
        : '$n';
    return '$formatted $word';
  }

  String get publicLink {
    final u = username.trim();
    if (u.isNotEmpty) return 't.me/$u';
    final inv = inviteLink.trim();
    if (inv.isEmpty) return '';
    return inv
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^www\.'), '');
  }
}

/// Active live stream / video chat bound to a chat (TDLib `videoChat` + `groupCall`).
class TdlibVideoChat {
  const TdlibVideoChat({
    required this.chatId,
    required this.groupCallId,
    this.title = '',
    this.participantCount = 0,
    this.isRtmpStream = false,
    this.isActive = true,
    this.username = '',
  });

  final int chatId;
  final int groupCallId;
  final String title;
  final int participantCount;
  final bool isRtmpStream;
  final bool isActive;
  /// Public @username of the channel/group when known (for t.me deep link).
  final String username;

  String get viewerCountLabel {
    final n = participantCount;
    if (n <= 0) return 'трансляция';
    final mod10 = n % 10;
    final mod100 = n % 100;
    final word = (mod100 >= 11 && mod100 <= 14)
        ? 'зрителей'
        : mod10 == 1
            ? 'зритель'
            : (mod10 >= 2 && mod10 <= 4 ? 'зрителя' : 'зрителей');
    return '$n $word';
  }
}

/// Target chat / message resolved from a `t.me` / `tg://` link.
class TdlibLinkTarget {
  const TdlibLinkTarget({
    required this.chatId,
    this.messageId,
    this.title = '',
  });

  final int chatId;
  final int? messageId;
  final String title;
}

class TdlibMessage {
  const TdlibMessage({
    required this.id,
    required this.chatId,
    required this.senderUserId,
    required this.isOutgoing,
    required this.date,
    this.text = '',
    this.photoLocalPath,
    this.photoRemoteId,
    this.photoSizeType,
    this.photoWidth,
    this.photoHeight,
    this.photoFallbackFileIds = const [],
    this.photoThumbBytes,
    this.voiceFileId,
    this.voiceLocalPath,
    this.voiceDurationMs,
    this.videoNoteFileId,
    this.videoNoteLocalPath,
    this.videoNoteDurationMs,
    this.videoNoteThumbFileId,
    this.videoNoteThumbLocalPath,
    this.videoNoteThumbBytes,
    this.videoFileId,
    this.videoLocalPath,
    this.videoDurationMs,
    this.videoWidth,
    this.videoHeight,
    this.videoThumbFileId,
    this.videoThumbLocalPath,
    this.videoThumbBytes,
    this.isAnimation = false,
    this.reactions = const [],
    this.replyToMessageId,
    this.replyPreviewText = '',
    this.canBeEdited = false,
    this.canBeDeletedForAllUsers = false,
    this.canBeDeletedOnlyForSelf = false,
    this.isPinned = false,
    this.isService = false,
    this.mediaAlbumId,
    this.textEntities = const [],
    this.forwardOriginName,
    this.forwardOriginChatTitle,
    this.forwardFromChatId,
    this.forwardFromMessageId,
  });

  final int id;
  final int chatId;
  final int senderUserId;
  final bool isOutgoing;
  final int date;
  final String text;
  /// TDLib service/system content (video chat started/ended, etc.).
  final bool isService;
  /// TDLib `media_album_id` — shared by album siblings; null/0 = not in album.
  final int? mediaAlbumId;
  /// TDLib text/caption entities as maps (offset/length/bold/url/…). UTF-16.
  final List<Map<String, dynamic>> textEntities;
  final String? forwardOriginName;
  final String? forwardOriginChatTitle;
  final int? forwardFromChatId;
  final int? forwardFromMessageId;
  final String? photoLocalPath;
  final int? photoRemoteId;
  /// TDLib photoSize.type (`y`/`x`/`w`/`m`/…).
  final String? photoSizeType;
  final int? photoWidth;
  final int? photoHeight;
  /// Smaller sizes to try if [photoRemoteId] stalls at 0B (usually `m`, then `x`).
  final List<int> photoFallbackFileIds;
  /// JPEG minithumbnail while the full photo downloads.
  final List<int>? photoThumbBytes;
  final int? voiceFileId;
  final String? voiceLocalPath;
  final int? voiceDurationMs;
  final int? videoNoteFileId;
  final String? videoNoteLocalPath;
  final int? videoNoteDurationMs;
  final int? videoNoteThumbFileId;
  final String? videoNoteThumbLocalPath;
  final List<int>? videoNoteThumbBytes;
  /// Regular channel/chat video or GIF (messageVideo / messageAnimation).
  final int? videoFileId;
  final String? videoLocalPath;
  final int? videoDurationMs;
  final int? videoWidth;
  final int? videoHeight;
  final int? videoThumbFileId;
  final String? videoThumbLocalPath;
  final List<int>? videoThumbBytes;
  final bool isAnimation;
  final List<TdlibReaction> reactions;
  final int? replyToMessageId;
  final String replyPreviewText;
  final bool canBeEdited;
  final bool canBeDeletedForAllUsers;
  final bool canBeDeletedOnlyForSelf;
  final bool isPinned;

  bool get isPhoto => photoRemoteId != null || photoLocalPath != null;
  bool get isVoiceNote => voiceFileId != null || voiceLocalPath != null;
  bool get isVideoNote =>
      videoNoteFileId != null || videoNoteLocalPath != null;
  bool get isVideo =>
      !isVideoNote &&
      (videoFileId != null ||
          videoLocalPath != null ||
          videoThumbFileId != null);
  bool get isForwarded =>
      forwardOriginName != null ||
      forwardFromChatId != null ||
      forwardFromMessageId != null;
}

class TdlibReaction {
  const TdlibReaction({
    required this.emoji,
    required this.count,
    required this.chosen,
  });

  final String emoji;
  final int count;
  final bool chosen;
}

/// Device-local Telegram client (TDLib) for FamilyChat.
class TelegramTdlibService extends ChangeNotifier {
  TelegramTdlibService();

  static final instance = TelegramTdlibService();

  static const _dbKeyStorageKey = 'tdlib_database_encryption_key_v1';

  TdlibJsonClient? _client;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _secure = const FlutterSecureStorage();
  bool _parametersApplied = false;
  bool _didWipeForEncryption = false;
  Future<void>? _authJob;
  /// Serializes [ensureStarted] — hub + pane + conversation all call it.
  Future<void>? _ensureStartedGate;
  Future<void>? _setParamsJob;
  bool _tearingDown = false;
  bool _recoveringClient = false;
  DateTime? _lastDeadClientRecoverAt;

  TdlibAuthPhase phase = TdlibAuthPhase.unavailable;
  String? errorMessage;
  String? phoneHint;
  bool codeViaApp = true;

  final Map<int, Map<String, dynamic>> _chats = {};
  final Map<int, Map<String, dynamic>> _users = {};
  final Map<int, Map<String, dynamic>> _supergroups = {};
  final Set<int> _supergroupFetchQueued = {};
  final List<int> _chatOrder = [];
  /// TG user ids (and private chat ids) matched to an FC peer — excluded from
  /// [notifiedUnreadTotal] so Chat-tab badges do not double-count FC DMs.
  final Set<int> _matchedTgUserIds = {};
  /// Scope defaults for [isChatMuted] when `use_default_mute_for` is set.
  final Map<String, Map<String, dynamic>> _scopeNotificationSettings = {};

  int? _openChatId;
  int? _myUserId;
  /// Self [chatMember.status] per chat — used for send permissions.
  final Map<int, Map<String, dynamic>> _chatMemberStatus = {};
  /// Explicit can-send cache (null = unknown / not refreshed yet).
  final Map<int, bool> _canSendMessages = {};
  final Map<int, List<TdlibMessage>> _messagesByChat = {};
  final Map<int, String> _filePathCache = {};
  final Set<int> _downloadQueued = {};
  final Set<int> _downloadInFlight = {};
  final Set<int> _downloadBackgroundIds = {};
  final Map<int, Completer<String?>> _downloadWaiters = {};
  final List<_TdlibDownloadJob> _downloadQueue = [];
  var _downloadActive = 0;
  /// TDLib itself opens ~2–4 download workers per DC (same idea as official
  /// Telegram MultiplexedRequestManager). We only bound how many downloadFile
  /// requests we pile on; concurrency of parts is inside TDLib.
  /// https://github.com/tdlib/td/issues/786
  /// https://hubo.dev/2020-06-05-source-code-walkthrough-of-telegram-ios-part-4/
  static const _maxConcurrentDownloads = 2;
  /// One CDN download while a chat is open. Parallel focus+focus-tail both
  /// stalled at 0B; exclusive 1 keeps the focused photo as the only request.
  static const _maxConcurrentWhenChatOpen = 1;
  /// TDLib priorities (1 = highest … 32 = lowest).
  // TDLib downloadFile priority: 1..32, HIGHER = earlier download.
  static const prioFocused = 32;
  static const prioOpenChat = 24;
  static const prioOpenChatMedia = 16;
  /// Hub list avatars (visible rows only) — above generic background warm.
  static const prioHubAvatar = 10;
  static const prioBackground = 4;
  /// Hang with no new bytes → cancelDownloadFile + size fallback.
  ///
  /// Official guidance (levlam / td#2585): there are no "stalled" downloads —
  /// TDLib keeps retrying internally. Aggressive cancel+re-enableProxy makes
  /// MTProto worse (Ready→Connecting). Only recover after a long idle.
  /// Async + CancelDownloadFile: https://github.com/tdlib/td/issues/3017
  static const _stallZeroBytes = Duration(seconds: 45);
  static const _stallZeroBytesFocus = Duration(seconds: 25);
  /// Full videos are larger; give origin-DC pull more time before give-up.
  static const _stallZeroBytesVideo = Duration(seconds: 90);
  /// Hub list avatars are tiny — don't hold both download slots for 45s at 0B.
  static const _stallZeroBytesHubAvatar = Duration(seconds: 12);
  static const _stallProgressIdle = Duration(seconds: 45);
  /// Auto-download / background warm window (same as FamilyChat media policy).
  static const mediaAutoAge = ChatMediaDisplayPolicy.deferredFullMediaAge;
  /// Hub warm disabled in exclusive-focus mode.
  static const warmHubChatLimit = 0;
  static const warmHubMediaPerChat = 0;
  /// Open-chat: only the focused message (no band prefetch).
  /// Open-chat: focused photo first; one neighbor max after focus starts.
  static const viewportMediaRadius = 1;
  /// Ordered exclusive focus queue (first = actively downloading).
  List<int> _focusDownloadOrder = const [];
  int? _focusMessageId;
  /// Hold exclusive focus while a download is in flight so scroll jitter
  /// cannot cancel→restart 0B downloads forever.
  DateTime? _focusHoldUntil;
  /// 0..1 while downloading; removed on complete/cancel.
  final Map<int, double> _fileDownloadProgress = {};
  final Map<int, _TdlibDownloadTrace> _downloadTrace = {};
  /// remote.unique_id → our tracked file id (TDLib may emit updateFile under a new id).
  final Map<String, int> _remoteUniqueToFileId = {};
  Timer? _downloadWatchdog;
  /// Batches high-frequency media UI notifies (progress / completes mid-fling).
  Timer? _uiNotifyTimer;
  bool _uiNotifyPending = false;
  bool _uiScrollBusy = false;
  DateTime? _uiScrollBusyUntil;
  /// Per-chat last outgoing message id that peer has read.
  final Map<int, int> _lastReadOutboxId = {};
  final Map<int, int> _pinnedMessageId = {};
  /// chat_id → active video chat / livestream info.
  final Map<int, TdlibVideoChat> _videoChats = {};
  /// Active peer chat actions (typing / recording), keyed by chat id.
  final Map<int, String> _chatActions = {};
  /// notification_group_id → chat_id for local Android banners.
  final Map<int, int> _notifGroupChatId = {};
  String? _registeredFcmToken;
  StreamSubscription<String>? _fcmTokenSub;
  int? _pushReceiverId;
  String _connectionState = '';
  DateTime? _connectingSince;
  DateTime? _lastPumpWaitLogAt;
  String? _lastPumpWaitLogConn;
  DateTime? _readyAt;
  Timer? _connectingTimeoutTimer;
  Future<void>? _connectionReadyJob;
  /// Last successfully enabled MTProto proxy id (for stuck-Connecting kick).
  int? _enabledProxyId;
  DateTime? _lastConnectionKickAt;
  int _connectionKickCount = 0;
  StreamSubscription<ChatNetworkLinkKind>? _networkLinkSub;
  ChatNetworkLinkKind _networkKind = ChatNetworkLinkKind.unknown;
  DateTime? _lastSetNetworkTypeAt;
  Future<void>? _setNetworkTypeJob;

  List<TdlibChatPreview> get privateChats =>
      hubChats.where((c) => !c.isGroup && !c.isChannel).toList();

  /// Sum of unread messages in main-list chats that are not muted.
  ///
  /// Matched private DMs are omitted — those unreads live on the FC DM row
  /// (and in [chatUnreadTotalProvider]), so counting them here would inflate
  /// the Chat tab / folder totals.
  int get notifiedUnreadTotal {
    var total = 0;
    for (final c in hubChats) {
      if (isChatMuted(c.chatId)) continue;
      if (!c.isGroup &&
          !c.isChannel &&
          _matchedTgUserIds.contains(c.userId)) {
        continue;
      }
      total += c.unreadCount;
    }
    return total;
  }

  /// Private DMs + groups + channels for the TG hub tab.
  /// Only chats that are actually on the main Telegram chat list
  /// (not archived / left / deleted / folder-only).
  List<TdlibChatPreview> get hubChats {
    final out = <TdlibChatPreview>[];
    for (final id in _chatOrder) {
      final chat = _chats[id];
      if (chat == null) continue;
      if (!_isInMainChatList(chat)) continue;
      final type = chat['type'];
      if (type is! Map) continue;
      final typeName = type['@type']?.toString() ?? '';

      var userId = 0;
      var isGroup = false;
      var isChannel = false;
      Map<String, dynamic>? user;

      if (typeName == 'chatTypePrivate') {
        userId = (type['user_id'] as num?)?.toInt() ?? 0;
        if (userId <= 0) continue;
        user = _users[userId];
        // Keep bots (e.g. BotFather) and service chats visible in the hub.
      } else if (typeName == 'chatTypeBasicGroup') {
        isGroup = true;
      } else if (typeName == 'chatTypeSupergroup') {
        isChannel = type['is_channel'] == true;
        isGroup = !isChannel;
        final sgId = (type['supergroup_id'] as num?)?.toInt();
        if (sgId != null) {
          _ensureSupergroupCached(sgId);
          if (_shouldHideLinkedChannelSideChat(
            isChannel: isChannel,
            supergroupId: sgId,
          )) {
            continue;
          }
          if (_isLeftOrBannedSupergroup(sgId, chatId: id)) continue;
        }
      } else {
        continue;
      }

      final last = chat['last_message'];
      final miniBytes = _photoMinithumbnailBytes(chat);
      // Hub tiles are ~48dp — prefer `small`, and any already-cached size.
      final smallId = _tdlibPhotoFileId(chat['photo'], 'small') ??
          (user != null
              ? _tdlibPhotoFileId(user['profile_photo'], 'small')
              : null);
      final bigId = _tdlibPhotoFileId(chat['photo'], 'big') ??
          (user != null
              ? _tdlibPhotoFileId(user['profile_photo'], 'big')
              : null);
      final resolvedId = _resolveChatAvatarFileId(
        chat,
        user: (isGroup || isChannel) ? null : user,
      );
      int? photoId;
      String? photoPath;
      for (final id in [smallId, bigId, resolvedId]) {
        if (id == null || id <= 0) continue;
        final path = _filePathCache[id];
        if (path != null && path.isNotEmpty) {
          photoId = id;
          photoPath = path;
          break;
        }
        photoId ??= id;
      }
      final lastOutbox = _lastReadOutboxId[id] ??
          (chat['last_read_outbox_message_id'] as num?)?.toInt() ??
          0;
      if (lastOutbox > 0) _lastReadOutboxId[id] = lastOutbox;

      var lastOutgoing = false;
      String? lastReadStatus;
      if (last is Map) {
        lastOutgoing = last['is_outgoing'] == true;
        if (lastOutgoing) {
          final mid = (last['id'] as num?)?.toInt() ?? 0;
          if (mid > 0 && lastOutbox > 0 && mid <= lastOutbox) {
            lastReadStatus = 'read';
          } else {
            lastReadStatus = 'sent';
          }
        }
      }

      out.add(
        TdlibChatPreview(
          chatId: id,
          userId: userId,
          isGroup: isGroup,
          isChannel: isChannel,
          title: _chatTitle(chat, user),
          photoFileId: photoId,
          photoLocalPath: photoPath,
          photoMinithumbnailBytes: miniBytes,
          lastMessageText: _previewText(last),
          lastMessageDate:
              (last is Map ? last['date'] as num? : null)?.toInt() ?? 0,
          unreadCount: (chat['unread_count'] as num?)?.toInt() ?? 0,
          lastMessageOutgoing: lastOutgoing,
          lastMessageReadStatus: lastReadStatus,
        ),
      );
      // Do not enqueue downloads here — hubChats is a getter and may rebuild
      // often. Visible-row prefetch: [prefetchVisibleHubAvatars].
    }
    out.sort((a, b) => b.lastMessageDate.compareTo(a.lastMessageDate));
    return out;
  }

  /// Sharp avatars for hub rows currently on screen (not the whole 500+ list).
  /// No-op while a chat is open so message media keeps the download slot.
  void prefetchVisibleHubAvatars(
    Iterable<int> chatIds, {
    int limit = 16,
  }) {
    if (_openChatId != null) return;
    if (!_tdlibReadyForMedia) return;

    // Cap how many hub-avatar jobs sit waiting — otherwise scroll floods the
    // queue while the first two CDN downloads sit at 0B.
    final hubQueued = _downloadQueue
        .where((j) => j.reason == 'hub-avatar')
        .length;
    final hubInflight = _downloadInFlight.where((id) {
      final r = _downloadTrace[id]?.reason ?? '';
      return r == 'hub-avatar';
    }).length;
    final hubBudget = limit - hubQueued - hubInflight;
    if (hubBudget <= 0) {
      _pumpDownloadQueue();
      return;
    }

    var n = 0;
    for (final chatId in chatIds) {
      if (n >= hubBudget) break;
      if (chatId == 0) continue;
      final chat = _chats[chatId];
      if (chat == null) continue;

      Map<String, dynamic>? user;
      final type = chat['type'];
      if (type is Map && type['@type'] == 'chatTypePrivate') {
        final uid = _tdlibInt(type['user_id']);
        if (uid > 0) user = _users[uid];
      }

      // Prefer small (hub circle ~48dp); big is for open-chat header.
      final photoId = _tdlibPhotoFileId(chat['photo'], 'small') ??
          (user != null
              ? _tdlibPhotoFileId(user['profile_photo'], 'small')
              : null) ??
          _resolveChatAvatarFileId(chat, user: user);
      if (photoId == null || photoId <= 0) {
        _refreshChatPhotoIfMissing(chatId);
        continue;
      }
      if (_filePathCache.containsKey(photoId)) continue;
      if (_downloadInFlight.contains(photoId) ||
          _downloadQueued.contains(photoId)) {
        continue;
      }

      _queueFileDownload(
        photoId,
        priority: prioHubAvatar,
        background: true,
        chatId: chatId,
        reason: 'hub-avatar',
      );
      n++;
    }
    if (n > 0) {
      _mediaLog(
        'hub-avatar prefetch queued=$n '
        'budget=$hubBudget inflight=$hubInflight waiting=$hubQueued',
      );
      _pumpDownloadQueue();
    }
  }

  /// True if chat has a non-zero order on Telegram's main list (not archive/folder-only).
  bool _isInMainChatList(Map chat) {
    final positions = chat['positions'];
    if (positions is! List || positions.isEmpty) return false;
    for (final p in positions) {
      if (p is! Map) continue;
      final list = p['list'];
      final listType = list is Map ? list['@type']?.toString() ?? '' : '';
      if (listType != 'chatListMain') continue;
      // TDLib int64 often arrives as String in JSON.
      if (_tdlibInt64NonZero(p['order'])) return true;
    }
    return false;
  }

  /// TDLib int64 fields (e.g. chatPosition.order) may be [num] or [String].
  static bool _tdlibInt64NonZero(dynamic v) {
    if (v == null) return false;
    if (v is num) return v != 0;
    final s = v.toString().trim();
    if (s.isEmpty || s == '0') return false;
    return true;
  }

  /// TDLib int/int53/int64 JSON values may arrive as [num] or [String].
  static int _tdlibInt(dynamic v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim()) ?? fallback;
  }

  bool _isLeftOrBannedSupergroup(int supergroupId, {required int chatId}) {
    final st = _chatMemberStatus[chatId] ?? _supergroups[supergroupId]?['status'];
    if (st is! Map) return false;
    final name = st['@type']?.toString() ?? '';
    return name == 'chatMemberStatusLeft' ||
        name == 'chatMemberStatusBanned';
  }

  void _syncChatOrderMembership(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) {
      _chatOrder.remove(chatId);
      return;
    }
    final inMain = _isInMainChatList(chat);
    if (inMain) {
      if (!_chatOrder.contains(chatId)) _chatOrder.add(chatId);
    } else {
      _chatOrder.remove(chatId);
    }
  }

  /// Apply a single [chatPosition] update (order 0 = remove from that list).
  void _applyChatPosition(int chatId, Map position) {
    final chat = _chats[chatId];
    if (chat == null) return;
    final list = position['list'];
    final listType = list is Map ? list['@type']?.toString() ?? '' : '';
    final keep = _tdlibInt64NonZero(position['order']);

    final existing = chat['positions'];
    final next = <Map<String, dynamic>>[];
    if (existing is List) {
      for (final p in existing) {
        if (p is! Map) continue;
        final pl = p['list'];
        final pt = pl is Map ? pl['@type']?.toString() ?? '' : '';
        if (pt == listType) continue; // replace this list's position
        next.add(Map<String, dynamic>.from(p));
      }
    }
    if (keep) {
      next.add(Map<String, dynamic>.from(position));
    }
    chat['positions'] = next;
    _syncChatOrderMembership(chatId);
  }

  /// Discussion group / channel DM side-chat linked to a channel — hide from hub.
  bool _shouldHideLinkedChannelSideChat({
    required bool isChannel,
    required int supergroupId,
  }) {
    if (isChannel) return false;
    final sg = _supergroups[supergroupId];
    if (sg == null) return false;
    if (sg['is_direct_messages_group'] == true) return true;
    // Designated discussion group for a channel.
    if (sg['has_linked_chat'] == true) return true;
    return false;
  }

  void _ensureSupergroupCached(int supergroupId) {
    if (supergroupId <= 0 ||
        _supergroups.containsKey(supergroupId) ||
        _supergroupFetchQueued.contains(supergroupId)) {
      return;
    }
    final c = _client;
    if (c == null) return;
    _supergroupFetchQueued.add(supergroupId);
    unawaited(() async {
      try {
        final res = await c.sendAwait({
          '@type': 'getSupergroup',
          'supergroup_id': supergroupId,
        });
        if (res['@type'] == 'supergroup') {
          _supergroups[supergroupId] = Map<String, dynamic>.from(res);
          notifyListeners();
        }
      } catch (e) {
        debugPrint('[tdlib] getSupergroup failed: $e');
      } finally {
        _supergroupFetchQueued.remove(supergroupId);
      }
    }());
  }

  bool isGroupChat(int chatId) {
    final type = _chats[chatId]?['type'];
    if (type is! Map) return false;
    final name = type['@type']?.toString() ?? '';
    if (name == 'chatTypeBasicGroup') return true;
    if (name == 'chatTypeSupergroup' && type['is_channel'] != true) return true;
    return false;
  }

  bool isChannelChat(int chatId) {
    final type = _chats[chatId]?['type'];
    if (type is! Map) return false;
    return type['@type']?.toString() == 'chatTypeSupergroup' &&
        type['is_channel'] == true;
  }

  /// Whether the current user may send messages in [chatId].
  /// Channels/restricted chats return false until [refreshCanSendMessages] runs.
  bool canSendMessages(int chatId) {
    final cached = _canSendMessages[chatId];
    if (cached != null) return cached;
    return _computeCanSendMessages(chatId);
  }

  bool _computeCanSendMessages(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return false;

    final type = chat['type'];
    final typeName = type is Map ? type['@type']?.toString() ?? '' : '';
    if (typeName == 'chatTypePrivate' || typeName == 'chatTypeSecret') {
      return true;
    }

    final status = _chatMemberStatus[chatId];
    if (status != null) {
      final st = status['@type']?.toString() ?? '';
      if (st == 'chatMemberStatusCreator') return true;
      if (st == 'chatMemberStatusLeft' ||
          st == 'chatMemberStatusBanned') {
        return false;
      }
      if (st == 'chatMemberStatusAdministrator') {
        final rights = status['rights'];
        if (rights is Map) {
          if (isChannelChat(chatId)) {
            return rights['can_post_messages'] == true;
          }
          // Group admins can send unless rights explicitly deny basic messages.
          if (rights.containsKey('can_send_basic_messages')) {
            return rights['can_send_basic_messages'] == true;
          }
          return true;
        }
        return !isChannelChat(chatId);
      }
      if (st == 'chatMemberStatusRestricted') {
        final perms = status['permissions'];
        if (perms is Map) {
          return perms['can_send_basic_messages'] == true ||
              perms['can_send_messages'] == true;
        }
        return false;
      }
      // chatMemberStatusMember — fall through to chat.permissions
    }

    final perms = chat['permissions'];
    if (perms is Map) {
      return perms['can_send_basic_messages'] == true ||
          perms['can_send_messages'] == true;
    }

    // Channels without known permissions: treat as read-only.
    if (isChannelChat(chatId)) return false;
    return false;
  }

  Future<void> refreshCanSendMessages(int chatId) async {
    final c = _client;
    if (c == null || chatId == 0) return;

    try {
      if (_myUserId == null) {
        final me = await c.sendAwait({'@type': 'getMe'});
        if (me['@type'] == 'user') {
          final id = (me['id'] as num?)?.toInt();
          if (id != null) {
            _myUserId = id;
            _users[id] = Map<String, dynamic>.from(me);
          }
        }
      }
      final myId = _myUserId;
      if (myId == null) return;

      final type = _chats[chatId]?['type'];
      final typeName = type is Map ? type['@type']?.toString() ?? '' : '';
      if (typeName == 'chatTypePrivate' || typeName == 'chatTypeSecret') {
        _canSendMessages[chatId] = true;
        notifyListeners();
        return;
      }

      // Prefer getSupergroup.status — getChatMember often fails on channels
      // with "Member list is inaccessible".
      if (type is Map && typeName == 'chatTypeSupergroup') {
        final sgId = (type['supergroup_id'] as num?)?.toInt();
        if (sgId != null && sgId > 0) {
          Map<String, dynamic>? sg = _supergroups[sgId];
          if (sg == null) {
            try {
              final res = await c.sendAwait({
                '@type': 'getSupergroup',
                'supergroup_id': sgId,
              });
              if (res['@type'] == 'supergroup') {
                sg = Map<String, dynamic>.from(res);
                _supergroups[sgId] = sg;
              }
            } catch (e) {
              debugPrint('[tdlib] getSupergroup($sgId) for canSend: $e');
            }
          }
          final st = sg?['status'];
          if (st is Map) {
            _chatMemberStatus[chatId] = Map<String, dynamic>.from(st);
          }
        }
      } else {
        try {
          final member = await c.sendAwait({
            '@type': 'getChatMember',
            'chat_id': chatId,
            'member_id': {
              '@type': 'messageSenderUser',
              'user_id': myId,
            },
          });
          if (member['@type'] == 'chatMember') {
            final st = member['status'];
            if (st is Map) {
              _chatMemberStatus[chatId] = Map<String, dynamic>.from(st);
            }
          }
        } catch (e) {
          // Fall through to chat.permissions.
          debugPrint('[tdlib] getChatMember($chatId): $e');
        }
      }
    } catch (e) {
      debugPrint('[tdlib] refreshCanSendMessages($chatId): $e');
    }

    final next = _computeCanSendMessages(chatId);
    if (_canSendMessages[chatId] != next) {
      _canSendMessages[chatId] = next;
      notifyListeners();
    } else {
      _canSendMessages[chatId] = next;
    }
  }

  String? cachedFilePath(int fileId) {
    final path = _filePathCache[fileId];
    if (path == null || path.isEmpty) return null;
    return path;
  }

  /// Local path for a message photo, including stall-fallback `m` sizes.
  String? resolvedPhotoPath(TdlibMessage m) {
    if (m.photoLocalPath != null && m.photoLocalPath!.isNotEmpty) {
      return m.photoLocalPath;
    }
    final primary = m.photoRemoteId;
    if (primary != null) {
      final p = cachedFilePath(primary);
      if (p != null) return p;
    }
    for (final id in m.photoFallbackFileIds) {
      final p = cachedFilePath(id);
      if (p != null) return p;
    }
    return null;
  }

  /// Drop a stale cache entry so the next request re-queues the download.
  void invalidateCachedFile(int fileId) {
    if (fileId <= 0) return;
    _filePathCache.remove(fileId);
  }

  /// Download progress 0..1, or null if idle / unknown.
  double? fileDownloadProgress(int fileId) => _fileDownloadProgress[fileId];

  bool isFileDownloading(int fileId) =>
      _downloadInFlight.contains(fileId) ||
      _downloadQueued.contains(fileId) ||
      _fileDownloadProgress.containsKey(fileId);

  /// Conversation list sets this while the user is dragging/flinging so media
  /// progress/completes don't rebuild the whole ListView mid-ballistic.
  void setUiScrollBusy(bool busy) {
    if (busy) {
      _uiScrollBusy = true;
      // Extend window on every scroll tick (drag + fling).
      _uiScrollBusyUntil =
          DateTime.now().add(const Duration(milliseconds: 520));
      return;
    }
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    _flushPendingUiNotify();
  }

  bool get _deferMediaUiNotify {
    if (!_uiScrollBusy) return false;
    final until = _uiScrollBusyUntil;
    if (until != null && DateTime.now().isBefore(until)) return true;
    // Auto-expire if the conversation forgot to clear after fling.
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    return false;
  }

  /// Coalesce high-frequency media notifies. [immediate] bypasses throttle
  /// (auth / new messages). [media] respects scroll-busy deferral.
  void _notifyUi({bool immediate = false, bool media = false}) {
    if (immediate) {
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = null;
      _uiNotifyPending = false;
      notifyListeners();
      return;
    }
    if (media && _deferMediaUiNotify) {
      _uiNotifyPending = true;
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = Timer(const Duration(milliseconds: 160), () {
        _uiNotifyTimer = null;
        if (_deferMediaUiNotify) {
          // Still flinging — wait again.
          _notifyUi(media: true);
          return;
        }
        _flushPendingUiNotify();
      });
      return;
    }
    _uiNotifyPending = true;
    _uiNotifyTimer ??= Timer(const Duration(milliseconds: 48), () {
      _uiNotifyTimer = null;
      _flushPendingUiNotify();
    });
  }

  void _flushPendingUiNotify() {
    if (!_uiNotifyPending) return;
    _uiNotifyPending = false;
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    notifyListeners();
  }

  /// True when nothing is queued/in-flight (safe for bubble to seed focus).
  bool get isMediaDownloadIdle =>
      _downloadQueue.isEmpty && _downloadInFlight.isEmpty;

  /// Drop queued/in-flight sharper photo sizes once a soft size paints.
  void _dropPendingFocusUpgrades(Set<int> dropIds, {required int keepFileId}) {
    if (dropIds.isEmpty) return;
    dropIds.remove(keepFileId);
    if (dropIds.isEmpty) return;
    final dropQueued = _downloadQueue
        .where((j) => dropIds.contains(j.fileId))
        .toList();
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      _mediaLog('drop-upgrade-queued file=${j.fileId} keep=$keepFileId');
    }
    _focusDownloadOrder =
        _focusDownloadOrder.where((id) => !dropIds.contains(id)).toList();
    for (final id in dropIds.toList()) {
      if (!_downloadInFlight.contains(id)) continue;
      unawaited(() async {
        await _cancelTdlibDownload(id);
        _releaseDownloadSlot(id, failed: true);
        _downloadTrace.remove(id);
        _fileDownloadProgress.remove(id);
        _mediaLog('drop-upgrade-inflight file=$id keep=$keepFileId');
      }());
    }
  }

  /// Cancel queued/in-flight avatar downloads so focused chat media owns the slot.
  Future<void> _purgeAvatarDownloads() async {
    final dropQueued = _downloadQueue
        .where(
          (j) =>
              j.reason == 'peer-avatar' ||
              j.reason == 'avatar' ||
              j.reason.startsWith('stall-retry:peer-avatar') ||
              j.reason.startsWith('stall-retry:avatar'),
        )
        .toList();
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }
    for (final id in _downloadInFlight.toList()) {
      final t = _downloadTrace[id];
      final reason = t?.reason ?? '';
      if (reason == 'peer-avatar' ||
          reason == 'avatar' ||
          reason.contains('peer-avatar') ||
          reason.contains('avatar')) {
        await _cancelTdlibDownload(id);
        _releaseDownloadSlot(id, failed: true);
        _downloadTrace.remove(id);
        _fileDownloadProgress.remove(id);
        _mediaLog('purge-avatar file=$id reason=$reason');
      }
    }
  }

  void _queueAvatarDownload(int fileId) {
    // Mass hub enqueue is disabled (see prefetchVisibleHubAvatars).
    // Keep this as a no-op so stray callers cannot refill the queue.
    if (fileId <= 0) return;
  }

  void _mediaLog(String msg) {
    debugPrint('[tdlib-media] $msg');
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)}MB';
  }

  static String _fmtDur(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) {
      return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    }
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m${s}s';
  }

  String _downloadQueueStats() {
    final inflight = _downloadInFlight.toList()..sort();
    return 'slots=$_downloadActive/$_downloadSlotLimit '
        'queued=${_downloadQueue.length} '
        'inflight=${inflight.length}${(inflight.isEmpty ? '' : ':$inflight')} '
        'waiters=${_downloadWaiters.length} '
        'conn=$_connectionState '
        'openChat=$_openChatId';
  }

  void _ensureDownloadWatchdog() {
    _downloadWatchdog ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => _logStuckDownloads(),
    );
  }

  void _logStuckDownloads() {
    if (_downloadInFlight.isEmpty && _downloadQueue.isEmpty) return;
    final now = DateTime.now();
    _mediaLog('watchdog ${_downloadQueueStats()}');
    for (final id in _downloadInFlight.toList()) {
      final t = _downloadTrace[id];
      if (t == null) {
        _mediaLog('watchdog file=$id inFlight (no trace)');
        continue;
      }
      final started = t.startedAt ?? t.enqueuedAt;
      final idle = t.lastProgressAt == null
          ? now.difference(started)
          : now.difference(t.lastProgressAt!);
      final elapsed = now.difference(started);
      final rate = elapsed.inMilliseconds > 0 && t.lastBytes > 0
          ? (t.lastBytes / (elapsed.inMilliseconds / 1000.0))
          : 0.0;
      final isFocus = t.reason.startsWith('focus:') ||
          t.reason.startsWith('stall-fallback:') ||
          t.reason.startsWith('stall-retry:') ||
          t.reason.startsWith('stall-lastchance:') ||
          t.reason.startsWith('tap:');
      final isVideo = t.reason.contains('video:') ||
          t.reason.startsWith('auto:video:') ||
          t.reason.startsWith('tap:video:');
      final isHubAvatar = t.reason == 'hub-avatar';
      final zeroLimit = isHubAvatar
          ? _stallZeroBytesHubAvatar
          : (isVideo
              ? _stallZeroBytesVideo
              : (isFocus ? _stallZeroBytesFocus : _stallZeroBytes));
      // Zero-byte hang OR mid-file hang (got some bytes, then silence).
      final stalledZero = idle >= zeroLimit && t.lastBytes <= 0;
      final stalledProgress = idle >= _stallProgressIdle &&
          t.lastBytes > 0 &&
          (t.expectedSize <= 0 || t.lastBytes < t.expectedSize);
      final stalled = stalledZero || stalledProgress;
      _mediaLog(
        'watchdog file=$id reason=${t.reason} '
        'prio=${t.priority} bg=${t.background} chat=${t.chatId} '
        'elapsed=${_fmtDur(elapsed)} idle=${_fmtDur(idle)} '
        'got=${_fmtBytes(t.lastBytes)}/'
        '${t.expectedSize > 0 ? _fmtBytes(t.expectedSize) : '?'} '
        'rate=${rate > 0 ? '${_fmtBytes(rate.round())}/s' : '?'} '
        'acked=${t.downloadAcked} remote=${t.remoteUniqueId} '
        '${stalledZero ? 'STALL-0B?' : ''}'
        '${stalledProgress ? 'STALL-IDLE?' : ''}',
      );
      if (stalled) {
        // Maybe TDLib finished under another file id — re-probe.
        unawaited(() async {
          if (await _probeLocalFile(id)) {
            final path = _filePathCache[id];
            if (path != null && path.isNotEmpty) {
              _mediaLog('watchdog-probe-hit file=$id → complete');
              _completeFileDownload(id, path);
            }
          }
        }());
      }
      if (stalled) {
        if (!_tdlibReadyForMedia) {
          _mediaLog(
            'stall-defer file=$id (conn=$_connectionState, wait Ready)',
          );
        } else {
          unawaited(_recoverStalledDownload(id));
        }
      }
    }
    if (_downloadQueue.isNotEmpty) {
      final head = _downloadQueue.take(8).map((j) {
        return '${j.fileId}(p${j.priority}${j.background ? ',bg' : ''}'
            '${j.reason.isEmpty ? '' : ',${j.reason}'})';
      }).join(', ');
      _mediaLog('watchdog queueHead=[$head]');
    }
  }

  Future<void> _nudgeCdnAfterStall(String why) async {
    // Soft nudge only while Ready: pingProxy. Connection recovery uses
    // setNetworkType separately (see _maybeKickStuckMtproto).
    final c = _client;
    final proxyId = _enabledProxyId;
    if (c == null || proxyId == null || !_tdlibReadyForMedia) {
      _mediaLog('cdn-nudge skip why=$why (no proxy/ready)');
      return;
    }
    try {
      await c.sendAwait(
        {'@type': 'pingProxy', 'proxy_id': proxyId},
        timeout: const Duration(seconds: 4),
      );
      _mediaLog('cdn-nudge pingProxy ok why=$why');
    } catch (e) {
      _mediaLog('cdn-nudge pingProxy soft-fail why=$why err=$e');
    }
  }

  /// Cancel a hung download and free the slot.
  ///
  /// Prefer switching to a smaller photo size for a 0B hang. For mid-file
  /// idle hangs, cancel + re-downloadFile (TDLib resumes) — recommended by
  /// TDLib maintainers instead of waiting forever on synchronous downloads.
  Future<void> _recoverStalledDownload(int fileId) async {
    if (!_downloadInFlight.contains(fileId)) return;
    if (!_tdlibReadyForMedia) {
      _mediaLog('stall-recover-skip file=$fileId conn=$_connectionState');
      return;
    }
    final t = _downloadTrace[fileId];
    final hadProgress = t != null && t.lastBytes > 0;
    final reason = t?.reason ?? '';
    final isAvatar = reason == 'peer-avatar' ||
        reason == 'avatar' ||
        reason.contains('peer-avatar') ||
        reason.contains('avatar');
    // Never stall-retry avatars while a chat is open — they steal the
    // exclusive media slot from the focused photo.
    // Hub-avatar 0B: drop and let the next visible row take the slot
    // (retrying the same CDN id just blocks the list longer).
    if (isAvatar && (_openChatId != null || reason == 'hub-avatar') &&
        !hadProgress) {
      _mediaLog('stall-drop-avatar file=$fileId reason=$reason');
      _downloadInFlight.remove(fileId);
      _downloadBackgroundIds.remove(fileId);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(fileId);
      _fileDownloadProgress.remove(fileId);
      await _cancelTdlibDownload(fileId);
      if (reason == 'hub-avatar') {
        unawaited(_nudgeCdnAfterStall('hub-avatar-0B'));
      }
      _pumpDownloadQueue();
      notifyListeners();
      return;
    }
    final chatId = t?.chatId ?? _openChatId;
    // Mid-file hang: cancel and retry the SAME file once (resume). Do not
    // jump to a smaller size — we already have useful bytes on disk.
    if (hadProgress) {
      _mediaLog(
        'stall-recover-progress file=$fileId reason=$reason '
        'got=${_fmtBytes(t!.lastBytes)}/'
        '${t.expectedSize > 0 ? _fmtBytes(t.expectedSize) : '?'} '
        'retried=${t.recoverAttempted == true}',
      );
      final recoverAttempted = t.recoverAttempted;
      _downloadInFlight.remove(fileId);
      _downloadBackgroundIds.remove(fileId);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(fileId);
      _fileDownloadProgress.remove(fileId);
      await _cancelTdlibDownload(fileId);
      await _nudgeCdnAfterStall('stall-progress:$fileId');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!recoverAttempted && _openChatId != null) {
        _queueFileDownload(
          fileId,
          priority: prioFocused,
          background: false,
          chatId: chatId ?? _openChatId,
          reason: reason.startsWith('stall-retry:')
              ? reason
              : 'stall-retry:$reason',
        );
        _downloadTrace[fileId]?.recoverAttempted = true;
      } else {
        _mediaLog('stall-progress-give-up file=$fileId');
        _pumpDownloadQueue();
      }
      notifyListeners();
      return;
    }
    final fallbackId = chatId == null
        ? null
        : _nextPhotoFallbackFileId(
            chatId: chatId,
            stalledFileId: fileId,
            reason: reason,
          );
    _mediaLog(
      'stall-recover file=$fileId reason=$reason '
      'fallback=${fallbackId ?? '-'} '
      'conn=$_connectionState retried=${t?.recoverAttempted == true}',
    );
    // Mark out of flight first so cancel's updateFile doesn't double-release.
    _downloadInFlight.remove(fileId);
    _downloadBackgroundIds.remove(fileId);
    _downloadActive = (_downloadActive - 1).clamp(0, 100);
    final prevFallbackAttempt = t?.sizeFallbackAttempt ?? 0;
    final recoverAttempted = t?.recoverAttempted == true;
    final focusMsgId = () {
      // Strip diagnostic suffixes (e.g. |cdn-bypass-offset1) before parsing.
      final clean = reason.split('|').first;
      final m = RegExp(
        r'(?:focus(?:-tail)?:|stall-fallback:|stall-retry:|stall-lastchance:|tap:(?:video|photo):|auto:video:|neighbor:)(\d+)',
      ).firstMatch(clean);
      if (m != null) return int.tryParse(m.group(1)!);
      final tail = RegExp(r'(\d+)\s*$').firstMatch(clean);
      return tail != null ? int.tryParse(tail.group(1)!) : null;
    }();
    _downloadTrace.remove(fileId);
    _fileDownloadProgress.remove(fileId);
    await _cancelTdlibDownload(fileId);
    // CDN often needs a network/proxy nudge when Ready but 0B forever.
    await _nudgeCdnAfterStall('stall:$fileId');
    // Give TDLib time to drop the stuck CDN request before re-downloadFile.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final waiter = _downloadWaiters.remove(fileId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(_filePathCache[fileId]);
    }
    _mediaLog(
      'stall-recover-done file=$fileId ${_downloadQueueStats()}',
    );

    // Neighbor / demoted 0B stalls — drop, never promote to focus priority.
    final isNeighborish = reason.startsWith('neighbor:') ||
        reason.startsWith('demoted-after-focus') ||
        reason.contains('neighbor:');
    if (isNeighborish) {
      _mediaLog('stall-drop-neighbor file=$fileId reason=$reason');
      _pumpDownloadQueue();
      notifyListeners();
      return;
    }

    if (fallbackId != null &&
        fallbackId > 0 &&
        chatId != null &&
        prevFallbackAttempt < 2) {
      // Drop demoted thumbs so the visible photo wins the free slot.
      final demoted = _downloadQueue
          .where((j) => j.reason.startsWith('demoted-after-focus'))
          .toList();
      for (final j in demoted) {
        _downloadQueue.remove(j);
        _downloadQueued.remove(j.fileId);
        _downloadTrace.remove(j.fileId);
        _fileDownloadProgress.remove(j.fileId);
      }
      if (focusMsgId != null && focusMsgId > 0) {
        await _openMessageContent(chatId, focusMsgId);
      }
      // Also cancel any 0B neighbor still holding a slot.
      await _yieldSlotsToFocus({
        fallbackId,
        if (fileId > 0) fileId,
      });
      _queueFileDownload(
        fallbackId,
        priority: prioFocused,
        background: false,
        chatId: chatId,
        reason: reason.contains('focus:')
            ? reason.replaceFirst('focus:', 'stall-fallback:')
            : reason.startsWith('tap:')
                ? 'stall-fallback:$reason'
                : 'stall-fallback:$reason',
      );
      _downloadTrace[fallbackId]?.sizeFallbackAttempt = prevFallbackAttempt + 1;
      _downloadTrace[fallbackId]?.recoverAttempted = true;
      notifyListeners();
      return;
    }

    // Last chance: only for focus/tap — never for neighbors.
    if (chatId != null &&
        focusMsgId != null &&
        focusMsgId > 0 &&
        !reason.startsWith('stall-lastchance:') &&
        (reason.contains('focus:') || reason.startsWith('tap:')) &&
        prevFallbackAttempt < 3) {
      await _openMessageContent(chatId, focusMsgId);
      await _yieldSlotsToFocus({fallbackId ?? fileId});
      final retryId = fallbackId ?? fileId;
      _mediaLog(
        'stall-lastchance file=$retryId msg=$focusMsgId '
        'after=$fileId',
      );
      _queueFileDownload(
        retryId,
        priority: prioFocused,
        background: false,
        chatId: chatId,
        reason: 'stall-lastchance:$focusMsgId',
      );
      _downloadTrace[retryId]?.sizeFallbackAttempt = prevFallbackAttempt + 1;
      _downloadTrace[retryId]?.recoverAttempted = true;
      notifyListeners();
      return;
    }

    // Give up — don't ping-pong sizes forever.
    if (prevFallbackAttempt >= 2 || recoverAttempted) {
      _mediaLog('stall-give-up file=$fileId after $prevFallbackAttempt fallbacks');
      _pumpDownloadQueue();
      notifyListeners();
      return;
    }

    final shouldRetry = t != null &&
        !recoverAttempted &&
        _openChatId != null &&
        (reason.contains('focus:') || reason.startsWith('tap:'));
    if (shouldRetry) {
      await _yieldSlotsToFocus({fileId});
      _queueFileDownload(
        fileId,
        priority: prioFocused,
        background: false,
        chatId: chatId ?? _openChatId,
        reason: 'stall-retry:$reason',
      );
      _downloadTrace[fileId]?.recoverAttempted = true;
    } else {
      _pumpDownloadQueue();
    }
    notifyListeners();
  }

  /// Next smaller photo size for a stalled download, if we know the message.
  int? _nextPhotoFallbackFileId({
    required int chatId,
    required int stalledFileId,
    required String reason,
  }) {
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return null;

    TdlibMessage? msg;
    final focusMatch = RegExp(r'(?:focus|stall-fallback|stall-retry):(\d+)');
    final m = focusMatch.firstMatch(reason);
    if (m != null) {
      final mid = int.tryParse(m.group(1)!);
      if (mid != null) {
        for (final item in list) {
          if (item.id == mid) {
            msg = item;
            break;
          }
        }
      }
    }
    msg ??= () {
      for (final item in list) {
        if (item.photoRemoteId == stalledFileId ||
            item.photoFallbackFileIds.contains(stalledFileId)) {
          return item;
        }
      }
      return null;
    }();

    if (msg == null) return null;

    // Only move to SMALLER sizes. Never bounce back up to the stalled primary.
    final fallbacks = msg.photoFallbackFileIds;
    final primary = msg.photoRemoteId;
    final List<int> candidates;
    if (primary != null && stalledFileId == primary) {
      candidates = List<int>.from(fallbacks);
    } else {
      // Already on a fallback — try remaining smaller ones only.
      candidates = [
        for (final id in fallbacks)
          if (id != stalledFileId) id,
      ];
    }

    for (final id in candidates) {
      if (id <= 0 || id == stalledFileId) continue;
      if (_hasCachedPath(id)) continue;
      if (_downloadInFlight.contains(id)) continue;
      return id;
    }
    return null;
  }

  /// Right after Ready/Updating: drop truly hung 0B inflight and pump.
  Future<void> _nudgeDownloadsAfterReconnect() async {
    if (!_tdlibReadyForMedia) return;
    _mediaLog('nudge-after-ready ${_downloadQueueStats()}');
    // Do NOT cancel jobs that just started on this Ready transition —
    // give them a few seconds before treating 0B as a stall.
    final hung = _downloadInFlight.where((id) {
      final t = _downloadTrace[id];
      if (t == null || t.lastBytes > 0) return false;
      if (!t.downloadAcked) return false;
      final started = t.startedAt ?? t.lastStartAt ?? t.enqueuedAt;
      return DateTime.now().difference(started) >= const Duration(seconds: 5);
    }).toList();
    for (final id in hung) {
      final t = _downloadTrace[id];
      if (t != null) t.recoverAttempted = false;
      await _recoverStalledDownload(id);
    }
    _pumpDownloadQueue();
  }

  /// Async TDLib download with concurrency limit. Slot held until [updateFile]
  /// completes (not merely until downloadFile is acknowledged).
  void _queueFileDownload(
    int fileId, {
    int priority = prioBackground,
    bool background = false,
    int? chatId,
    String reason = '',
  }) {
    if (fileId <= 0) return;
    final cached = _filePathCache[fileId];
    if (cached != null && cached.isNotEmpty) {
      // Silent: UI rebuilds hit this often.
      return;
    }

    // While a chat is open, ignore new background work (hub avatars etc.).
    if (background && _openChatId != null) {
      _mediaLog(
        'skip file=$fileId reason=$reason bgBlockedWhileChatOpen '
        'open=$_openChatId',
      );
      return;
    }

    if (_downloadInFlight.contains(fileId)) {
      // CRITICAL: do NOT re-call downloadFile on an active transfer.
      // Logs showed boost→probe→downloadFile spam leaving active=true at 0B.
      final t = _downloadTrace[fileId];
      if (t != null && reason.isNotEmpty) t.reason = reason;
      if (t != null && priority > t.priority) t.priority = priority;
      return;
    }
    if (_downloadQueued.contains(fileId)) {
      final idx = _downloadQueue.indexWhere((j) => j.fileId == fileId);
      if (idx >= 0) {
        final job = _downloadQueue[idx];
        final oldPrio = job.priority;
        if (priority > job.priority) job.priority = priority;
        if (!background) job.background = false;
        if (chatId != null) job.chatId = chatId;
        if (reason.isNotEmpty) job.reason = reason;
        final t = _downloadTrace[fileId];
        if (t != null) {
          t.priority = job.priority;
          t.background = job.background;
          if (chatId != null) t.chatId = chatId;
          if (reason.isNotEmpty) t.reason = reason;
        }
        if (job.priority != oldPrio) {
          _mediaLog(
            'requeue file=$fileId reason=$reason '
            'prio $oldPrio→${job.priority} ${_downloadQueueStats()}',
          );
        }
        _pumpDownloadQueue();
      }
      return;
    }

    _downloadQueued.add(fileId);
    _downloadQueue.add(
      _TdlibDownloadJob(
        fileId: fileId,
        priority: priority,
        background: background,
        chatId: chatId ?? _openChatId,
        reason: reason,
      ),
    );
    _downloadTrace[fileId] = _TdlibDownloadTrace(
      fileId: fileId,
      reason: reason,
      priority: priority,
      background: background,
      chatId: chatId ?? _openChatId,
    );
    _fileDownloadProgress.putIfAbsent(fileId, () => 0);
    _mediaLog(
      'enqueue file=$fileId reason=$reason prio=$priority '
      'bg=$background chat=${chatId ?? _openChatId} '
      '${_downloadQueueStats()}',
    );
    _ensureDownloadWatchdog();
    _pumpDownloadQueue();
  }

  int get _downloadSlotLimit =>
      _openChatId != null ? _maxConcurrentWhenChatOpen : _maxConcurrentDownloads;

  bool get _tdlibReadyForMedia {
    // Bytes only flow once MTProto is up. Forcing downloads during
    // Connecting just burns slots on 0B acks until Ready.
    return _connectionState == 'connectionStateReady' ||
        _connectionState == 'connectionStateUpdating';
  }

  void _noteConnectionState(String name) {
    final connecting = name == 'connectionStateConnecting' ||
        name == 'connectionStateConnectingToProxy' ||
        name == 'connectionStateWaitingForNetwork';
    if (connecting) {
      _connectingSince ??= DateTime.now();
      _readyAt = null;
      _ensureConnectingWaitLogTimer();
    } else if (name == 'connectionStateReady' ||
        name == 'connectionStateUpdating') {
      final since = _connectingSince;
      _readyAt = DateTime.now();
      if (since != null) {
        _mediaLog(
          'mtproto-up after ${_fmtDur(_readyAt!.difference(since))} '
          'via $name (media can flow)',
        );
      }
      _connectingSince = null;
      _connectionKickCount = 0;
      _lastConnectionKickAt = null;
      _connectingTimeoutTimer?.cancel();
      _connectingTimeoutTimer = null;
    } else {
      _connectingSince = null;
      _connectingTimeoutTimer?.cancel();
      _connectingTimeoutTimer = null;
    }
  }

  /// Log slow Connecting waits + escalate recovery (official TDLib pattern).
  /// Downloads stay paused until Ready (0B until then).
  void _ensureConnectingWaitLogTimer() {
    _connectingTimeoutTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (_tdlibReadyForMedia) return;
        final since = _connectingSince;
        if (since == null) return;
        final waited = DateTime.now().difference(since);
        if (_downloadQueue.isNotEmpty || _downloadInFlight.isNotEmpty) {
          _mediaLog(
            'waiting-mtproto ${_fmtDur(waited)} conn=$_connectionState '
            'queued=${_downloadQueue.length} (no download until Ready)',
          );
        } else if (waited >= const Duration(seconds: 15)) {
          // Even with an empty queue, stuck Connecting blanks channels
          // (history remote fill + photos). Still log so we notice.
          _mediaLog(
            'waiting-mtproto ${_fmtDur(waited)} conn=$_connectionState '
            '(idle queue)',
          );
        }
        _maybeKickStuckMtproto(waited);
      },
    );
  }

  /// Escalating recovery for wedged Connecting (official guidance):
  /// 1) ~15s — `setNetworkType` reopen (same as Telegram on route change)
  /// 2) ~45s — disableProxy → enableProxy (fresh FakeTLS)
  /// 3) ~90s — soft-restart TDLib client (last resort; rare)
  ///
  /// Do not spam enableProxy/addProxy mid-handshake — that floods mtg with
  /// half-open FakeTLS (`cannot read client hello`).
  void _maybeKickStuckMtproto(Duration waited) {
    if (_tdlibReadyForMedia) return;
    if (_connectionState == 'connectionStateConnectingToProxy' &&
        waited < const Duration(seconds: 25)) {
      // Let FakeTLS finish the first attempt.
      return;
    }
    int nextStage;
    Duration minWait;
    Duration minGap;
    if (_connectionKickCount <= 0) {
      nextStage = 1;
      minWait = const Duration(seconds: 15);
      minGap = Duration.zero;
    } else if (_connectionKickCount == 1) {
      nextStage = 2;
      minWait = const Duration(seconds: 45);
      minGap = const Duration(seconds: 20);
    } else if (_connectionKickCount == 2) {
      nextStage = 3;
      minWait = const Duration(seconds: 90);
      minGap = const Duration(seconds: 30);
    } else {
      return;
    }
    if (waited < minWait) return;
    final last = _lastConnectionKickAt;
    if (last != null && DateTime.now().difference(last) < minGap) return;
    _lastConnectionKickAt = DateTime.now();
    _connectionKickCount = nextStage;
    unawaited(_kickStuckMtproto(waited, stage: nextStage));
  }

  Future<void> _kickStuckMtproto(
    Duration waited, {
    required int stage,
  }) async {
    final c = _client;
    if (c == null || _tdlibReadyForMedia) return;
    _mediaLog(
      'mtproto-kick #$stage after ${_fmtDur(waited)} '
      'conn=$_connectionState proxyId=${_enabledProxyId ?? '?'} '
      'net=$_networkKind',
    );
    switch (stage) {
      case 1:
        await _reopenNetworkConnections(why: 'stuck-connecting');
        return;
      case 2:
        await _cycleEnabledProxy(why: 'stuck-connecting');
        return;
      case 3:
        _mediaLog('mtproto-kick soft-restart TDLib after ${_fmtDur(waited)}');
        await _recoverDeadClient('stuck-connecting:${_fmtDur(waited)}');
        return;
      default:
        return;
    }
  }

  /// Shell / lifecycle: app returned to foreground.
  ///
  /// Official TDLib: set option "online"=true for fast recovery, and call
  /// setNetworkType when connectivity may have changed (td#2690, td#3144).
  Future<void> onAppResumed() async {
    if (_client == null || _tearingDown) return;
    await _setTdlibOnline(true);
    _ensureNetworkLinkWatch();
    final prevKind = _networkKind;
    final kind = await ChatNetworkLink.current();
    _networkKind = kind;
    if (!_tdlibReadyForMedia) {
      // Stuck Connecting / WaitingForNetwork — force socket reopen now.
      await _reopenNetworkConnections(why: 'app-resume-not-ready');
    } else if (prevKind != kind) {
      await _applyNetworkTypeFromDevice(why: 'app-resume', force: true);
    }
  }

  /// Shell / lifecycle: app backgrounded.
  Future<void> onAppPaused() async {
    if (_client == null || _tearingDown) return;
    await _setTdlibOnline(false);
  }

  Future<void> _setTdlibOnline(bool online) async {
    final c = _client;
    if (c == null || _tearingDown) return;
    // Always send: TDLib uses online=true as a reconnect aggressiveness nudge.
    try {
      await c.sendAwait({
        '@type': 'setOption',
        'name': 'online',
        'value': {'@type': 'optionValueBoolean', 'value': online},
      }, timeout: const Duration(seconds: 3));
      _mediaLog('setOption online=$online ok');
    } catch (e) {
      _mediaLog('setOption online=$online err=$e');
    }
  }

  void _ensureNetworkLinkWatch() {
    if (kIsWeb || _networkLinkSub != null) return;
    _networkLinkSub = ChatNetworkLink.watch().listen((kind) {
      if (_tearingDown || _client == null) return;
      final prev = _networkKind;
      _networkKind = kind;
      if (prev == kind && prev != ChatNetworkLinkKind.unknown) return;
      unawaited(_applyNetworkTypeFromDevice(why: 'link:$kind'));
    });
  }

  Future<void> _applyNetworkTypeFromDevice({
    required String why,
    bool force = false,
  }) async {
    final kind = force ? await ChatNetworkLink.current() : _networkKind;
    if (force) _networkKind = kind;
    final type = switch (kind) {
      ChatNetworkLinkKind.offline => 'networkTypeNone',
      ChatNetworkLinkKind.wifi => 'networkTypeWiFi',
      ChatNetworkLinkKind.mobile => 'networkTypeMobile',
      ChatNetworkLinkKind.unknown => 'networkTypeOther',
    };
    await _setNetworkType(type, why: why, force: force);
  }

  /// Forces TDLib to reopen all sockets (official reconnect).
  Future<void> _reopenNetworkConnections({required String why}) async {
    // Bounce None → current so even "same type" always reopens.
    await _setNetworkType('networkTypeNone', why: '$why:down', force: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_tearingDown || _client == null || _tdlibReadyForMedia) return;
    await _applyNetworkTypeFromDevice(why: '$why:up', force: true);
  }

  Future<void> _setNetworkType(
    String typeName, {
    required String why,
    bool force = false,
  }) async {
    if (_client == null || _tearingDown) return;
    final last = _lastSetNetworkTypeAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    final prev = _setNetworkTypeJob;
    final mine = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      final c = _client;
      if (c == null || _tearingDown) return;
      _lastSetNetworkTypeAt = DateTime.now();
      try {
        await c.sendAwait({
          '@type': 'setNetworkType',
          'type': {'@type': typeName},
        }, timeout: const Duration(seconds: 5));
        _mediaLog('setNetworkType $typeName why=$why ok');
      } catch (e) {
        _mediaLog('setNetworkType $typeName why=$why err=$e');
      }
    }();
    _setNetworkTypeJob = mine;
    await mine;
  }

  Future<void> _cycleEnabledProxy({required String why}) async {
    final c = _client;
    final proxyId = _enabledProxyId;
    if (c == null || _tdlibReadyForMedia) return;
    if (proxyId == null) {
      await _ensureProxy();
      return;
    }
    try {
      await c.sendAwait({
        '@type': 'disableProxy',
      }, timeout: const Duration(seconds: 5));
      _mediaLog('proxy-cycle disableProxy why=$why ok');
    } catch (e) {
      _mediaLog('proxy-cycle disableProxy why=$why err=$e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_client == null || _tearingDown || _tdlibReadyForMedia) return;
    try {
      await c.sendAwait({
        '@type': 'enableProxy',
        'proxy_id': proxyId,
      }, timeout: const Duration(seconds: 5));
      _mediaLog('proxy-cycle enableProxy id=$proxyId why=$why ok');
    } catch (e) {
      // Do NOT addProxy — stacking produces hello-timeout floods on mtg.
      _mediaLog('proxy-cycle enableProxy id=$proxyId why=$why err=$e');
    }
  }

  void _pumpDownloadQueue() {
    // Network downloads need Ready. Local disk hits (getFile → already
    // completed) must NOT wait — cold boot sits in Connecting ~60s+ and the
    // UI looks "broken" even when the jpg is already on disk (log: file=1287
    // queued=1m1s then source=disk dl=17ms).
    if (!_tdlibReadyForMedia) {
      _pumpLocalDiskHitsWhileConnecting();
      final now = DateTime.now();
      final shouldLog = _lastPumpWaitLogConn != _connectionState ||
          _lastPumpWaitLogAt == null ||
          now.difference(_lastPumpWaitLogAt!) >= const Duration(seconds: 5);
      if (shouldLog && _downloadQueue.isNotEmpty) {
        _lastPumpWaitLogConn = _connectionState;
        _lastPumpWaitLogAt = now;
        final since = _connectingSince;
        _mediaLog(
          'pump-wait-ready queued=${_downloadQueue.length} '
          'inflight=${_downloadInFlight.length} conn=$_connectionState '
          'connectingFor=${since == null ? '?' : _fmtDur(now.difference(since))}',
        );
      }
      return;
    }

    _downloadQueue.sort((a, b) {
      // Foreground first, then higher TDLib priority wins.
      if (a.background != b.background) return a.background ? 1 : -1;
      return b.priority.compareTo(a.priority);
    });

    while (_downloadActive < _downloadSlotLimit && _downloadQueue.isNotEmpty) {
      // Skip background jobs while a chat is open.
      final idx = _downloadQueue.indexWhere(
        (j) => _openChatId == null || !j.background,
      );
      if (idx < 0) break;
      final job = _downloadQueue.removeAt(idx);
      _downloadQueued.remove(job.fileId);
      if (_filePathCache.containsKey(job.fileId) ||
          _downloadInFlight.contains(job.fileId)) {
        _mediaLog(
          'pump-skip file=${job.fileId} reason=${job.reason} '
          '(cachedOrInFlight)',
        );
        continue;
      }
      _downloadInFlight.add(job.fileId);
      if (job.background) {
        _downloadBackgroundIds.add(job.fileId);
      } else {
        _downloadBackgroundIds.remove(job.fileId);
      }
      _downloadActive++;
      _mediaLog(
        'pump-start file=${job.fileId} reason=${job.reason} '
        'prio=${job.priority} ${_downloadQueueStats()}',
      );
      unawaited(
        _startAsyncDownload(
          job.fileId,
          job.priority,
          reason: job.reason,
        ),
      );
    }
  }

  /// While Connecting, still resolve files already on disk via getFile.
  void _pumpLocalDiskHitsWhileConnecting() {
    if (_downloadQueue.isEmpty) return;
    // Prefer the focused / highest-prio foreground job.
    _downloadQueue.sort((a, b) {
      if (a.background != b.background) return a.background ? 1 : -1;
      return b.priority.compareTo(a.priority);
    });
    final candidates = _downloadQueue
        .where((j) => !j.background && !_downloadInFlight.contains(j.fileId))
        .take(2)
        .toList();
    for (final job in candidates) {
      if (_filePathCache.containsKey(job.fileId)) {
        _downloadQueue.remove(job);
        _downloadQueued.remove(job.fileId);
        continue;
      }
      if (_downloadActive >= _downloadSlotLimit) break;
      _downloadQueue.remove(job);
      _downloadQueued.remove(job.fileId);
      _downloadInFlight.add(job.fileId);
      _downloadActive++;
      _mediaLog(
        'pump-local-probe file=${job.fileId} reason=${job.reason} '
        'conn=$_connectionState ${_downloadQueueStats()}',
      );
      unawaited(_probeDiskOrRequeue(job));
    }
  }

  Future<void> _probeDiskOrRequeue(_TdlibDownloadJob job) async {
    final fileId = job.fileId;
    final t = _downloadTrace[fileId];
    try {
      if (await _probeLocalFile(fileId)) {
        final path = _filePathCache[fileId]!;
        if (t != null) t.fromDiskCache = true;
        _mediaLog(
          'disk-hit-connecting file=$fileId reason=${job.reason} '
          'path=${p.basename(path)}',
        );
        _completeFileDownload(fileId, path);
        return;
      }
    } catch (e) {
      _mediaLog('disk-probe-connecting fail file=$fileId err=$e');
    }
    // Not on disk yet — put back and wait for Ready for network download.
    _downloadInFlight.remove(fileId);
    _downloadActive = (_downloadActive - 1).clamp(0, 100);
    if (!_downloadQueued.contains(fileId) && !_hasCachedPath(fileId)) {
      _downloadQueued.add(fileId);
      _downloadQueue.add(job);
    }
    _mediaLog(
      'disk-miss-requeue file=$fileId reason=${job.reason} '
      'conn=$_connectionState',
    );
  }

  /// True if we already know a local path (RAM cache) and the file exists.
  bool _hasCachedPath(int fileId) {
    final path = _filePathCache[fileId];
    if (path == null || path.isEmpty) return false;
    if (File(path).existsSync()) return true;
    // Stale TDLib path — drop so focus/tap can re-download.
    _filePathCache.remove(fileId);
    return false;
  }

  /// Ask TDLib whether the file is already on disk; seeds [_filePathCache].
  Future<bool> _probeLocalFile(int fileId) async {
    if (_hasCachedPath(fileId)) return true;
    final c = _client;
    if (c == null || fileId <= 0) return false;
    try {
      final res = await c.sendAwait(
        {'@type': 'getFile', 'file_id': fileId},
        timeout: const Duration(seconds: 5),
      );
      if (res['@type'] != 'file') return false;
      final expected = _tdlibInt(res['expected_size']);
      final size = expected > 0 ? expected : _tdlibInt(res['size']);
      final t = _downloadTrace[fileId];
      if (t != null && size > 0) t.expectedSize = size;
      final remote = res['remote'];
      if (remote is Map) {
        final uid = remote['id']?.toString() ?? '';
        if (uid.isNotEmpty) {
          if (t != null) t.remoteUniqueId = uid;
          _remoteUniqueToFileId[uid] = fileId;
        }
      }
      final local = res['local'];
      if (local is! Map) return false;
      final canDownload = local['can_be_downloaded'] != false;
      final downloaded = _tdlibInt(local['downloaded_size']);
      final active = local['is_downloading_active'] == true;
      final completed = local['is_downloading_completed'] == true;
      if (completed) {
        final path = local['path']?.toString();
        if (path == null || path.isEmpty) return false;
        _filePathCache[fileId] = path;
        _mediaLog(
          'probe-hit file=$fileId size=${size > 0 ? _fmtBytes(size) : '?'} '
          'path=${p.basename(path)}',
        );
        return true;
      }
      _mediaLog(
        'probe-miss file=$fileId size=${size > 0 ? _fmtBytes(size) : '?'} '
        'downloaded=${_fmtBytes(downloaded)} active=$active '
        'canDownload=$canDownload '
        'remote=${t?.remoteUniqueId.isNotEmpty == true ? t!.remoteUniqueId : '?'}',
      );
      return false;
    } catch (e) {
      _mediaLog('probe-error file=$fileId err=$e');
      return false;
    }
  }

  /// Map an updateFile id back to the id we enqueued (handles TDLib id remap).
  int _trackedFileIdForUpdate(int updateId, String remoteUniqueId) {
    if (_downloadTrace.containsKey(updateId) ||
        _downloadInFlight.contains(updateId)) {
      return updateId;
    }
    if (remoteUniqueId.isNotEmpty) {
      final mapped = _remoteUniqueToFileId[remoteUniqueId];
      if (mapped != null &&
          (_downloadTrace.containsKey(mapped) ||
              _downloadInFlight.contains(mapped))) {
        return mapped;
      }
      for (final e in _downloadTrace.entries) {
        if (e.value.remoteUniqueId == remoteUniqueId) return e.key;
      }
    }
    return updateId;
  }

  Future<void> _startAsyncDownload(
    int fileId,
    int priority, {
    bool forceRestart = true,
    String reason = '',
  }) async {
    final c = _client;
    final t = _downloadTrace[fileId];
    if (!_tdlibReadyForMedia) {
      _mediaLog(
        'start-defer file=$fileId reason=${t?.reason ?? reason} '
        'conn=$_connectionState',
      );
      // Return slot to queue until Ready.
      _downloadInFlight.remove(fileId);
      _downloadBackgroundIds.remove(fileId);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      if (!_downloadQueued.contains(fileId)) {
        _downloadQueued.add(fileId);
        _downloadQueue.add(
          _TdlibDownloadJob(
            fileId: fileId,
            priority: priority,
            background: false,
            chatId: t?.chatId ?? _openChatId,
            reason: t?.reason ?? reason,
          ),
        );
      }
      return;
    }
    // Only one downloadFile per in-flight job (unless forced recover).
    if (t != null && t.downloadAcked && !forceRestart) {
      _mediaLog('start-skip file=$fileId alreadyAcked');
      return;
    }
    if (t != null &&
        t.lastStartAt != null &&
        DateTime.now().difference(t.lastStartAt!) <
            const Duration(seconds: 3) &&
        !forceRestart) {
      _mediaLog('start-skip file=$fileId debounce');
      return;
    }
    t?.startedAt ??= DateTime.now();
    t?.lastStartAt = DateTime.now();
    t?.priority = priority;
    if (reason.isNotEmpty) t?.reason = reason;

    if (c == null) {
      _mediaLog('start-fail file=$fileId noClient');
      _releaseDownloadSlot(fileId, failed: true);
      return;
    }
    // Disk cache hit (cold start / RAM empty) — don't re-fetch from network.
    if (await _probeLocalFile(fileId)) {
      final path = _filePathCache[fileId]!;
      if (t != null) t.fromDiskCache = true;
      _mediaLog(
        'disk-hit file=$fileId reason=${t?.reason ?? reason} '
        'waited=${_fmtDur(DateTime.now().difference(t?.enqueuedAt ?? DateTime.now()))}',
      );
      _completeFileDownload(fileId, path);
      return;
    }
    try {
      final reasonNow = t?.reason ?? reason;
      // MTProto FakeTLS relays origin DCs, but TDLib's CDN path
      // (upload.getCdnFile → CDN DCs) often stalls at 0B forever while Ready.
      // TDLib sets cdn_supported only when downloadFile offset==0
      // (FileDownloader.cpp); offset=1 disables CDN for every part while the
      // parts manager still fills the full file from byte 0.
      final bypassCdn = _enabledProxyId != null;
      final dlOffset = bypassCdn ? 1 : 0;
      _mediaLog(
        'net-downloadFile file=$fileId reason=$reasonNow '
        'prio=$priority size=${t != null && t.expectedSize > 0 ? _fmtBytes(t.expectedSize) : '?'} '
        'offset=$dlOffset cdnBypass=$bypassCdn sync=false '
        '${_downloadQueueStats()}',
      );
      await c.sendAwait(
        {
          '@type': 'downloadFile',
          'file_id': fileId,
          'priority': priority.clamp(1, 32),
          'offset': dlOffset,
          'limit': 0,
          'synchronous': false,
        },
        timeout: const Duration(seconds: 20),
      );
      t?.downloadAcked = true;
      // Keep reason parseable for stall recovery (no |suffix with trailing digits).
      _mediaLog(
        'net-ack file=$fileId (TDLib accepted; waiting updateFile) '
        'conn=$_connectionState bypassCdn=$bypassCdn',
      );
    } catch (e) {
      _mediaLog('net-start-error file=$fileId err=$e');
      debugPrint('[tdlib] downloadFile($fileId) start: $e');
      _releaseDownloadSlot(fileId, failed: true);
      final waiter = _downloadWaiters.remove(fileId);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(_filePathCache[fileId]);
      }
    }
  }

  void _releaseDownloadSlot(int fileId, {bool failed = false}) {
    final wasInFlight = _downloadInFlight.remove(fileId);
    _downloadBackgroundIds.remove(fileId);
    if (wasInFlight) {
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
    }
    if (failed) {
      final t = _downloadTrace.remove(fileId);
      if (!wasInFlight && t == null) {
        // Duplicate fail from cancel/updateFile race — ignore.
        return;
      }
      final elapsed = t == null
          ? null
          : DateTime.now().difference(t.startedAt ?? t.enqueuedAt);
      _mediaLog(
        'slot-fail file=$fileId reason=${t?.reason ?? ''} '
        'elapsed=${elapsed == null ? '?' : _fmtDur(elapsed)} '
        'got=${_fmtBytes(t?.lastBytes ?? 0)}/${t != null && t.expectedSize > 0 ? _fmtBytes(t.expectedSize) : '?'} '
        '${_downloadQueueStats()}',
      );
      _fileDownloadProgress.remove(fileId);
    }
    _pumpDownloadQueue();
  }

  void _completeFileDownload(int fileId, String path) {
    final t = _downloadTrace.remove(fileId);
    final now = DateTime.now();
    final started = t?.startedAt ?? t?.enqueuedAt;
    final elapsed = started == null ? null : now.difference(started);
    final queued = t == null ? null : now.difference(t.enqueuedAt);
    final bytes = t?.lastBytes ?? 0;
    final size = t?.expectedSize ?? 0;
    final effectiveBytes = size > 0 ? size : bytes;
    final rate = elapsed != null &&
            elapsed.inMilliseconds > 0 &&
            effectiveBytes > 0 &&
            t?.fromDiskCache != true
        ? effectiveBytes / (elapsed.inMilliseconds / 1000.0)
        : 0.0;
    _mediaLog(
      'done file=$fileId reason=${t?.reason ?? ''} '
      '${t?.fromDiskCache == true ? 'source=disk' : 'source=net'} '
      'size=${size > 0 ? _fmtBytes(size) : (bytes > 0 ? _fmtBytes(bytes) : '?')} '
      'dl=${elapsed == null ? '?' : _fmtDur(elapsed)} '
      'queued=${queued == null ? '?' : _fmtDur(queued)} '
      '${rate > 0 ? 'rate=${_fmtBytes(rate.round())}/s ' : ''}'
      'path=${p.basename(path)} ${_downloadQueueStats()}',
    );
    _filePathCache[fileId] = path;
    _fileDownloadProgress.remove(fileId);
    final waiter = _downloadWaiters.remove(fileId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(path);
    }
    _releaseDownloadSlot(fileId);

    final reason = t?.reason ?? '';
    final chatId = t?.chatId ?? _openChatId;

    // Release focus hold once this focus set is fully local / idle.
    if (_focusDownloadOrder.contains(fileId)) {
      final stillPending = _focusDownloadOrder.any(
        (id) =>
            id != fileId &&
            !_hasCachedPath(id) &&
            (_downloadInFlight.contains(id) || _downloadQueued.contains(id)),
      );
      if (!stillPending) {
        _focusHoldUntil = null;
        final openId = _openChatId;
        if (openId != null) {
          _flushPendingNeighbors(openId);
        }
        // Safe to polish header avatar once focus media owns nothing.
        if (openId != null &&
            _downloadInFlight.isEmpty &&
            !_downloadQueue.any((j) => j.reason.startsWith('focus:'))) {
          _ensurePeerAvatarDownloading(openId, foreground: true);
        }
      }
    }

    // After tiny `m` paints, do NOT auto-upgrade to `x`/`y` — channel CDN
    // upgrades often sit at 0B for 20s+ and block the exclusive slot. Tap /
    // ensureFileLocal still fetches the full size for the viewer.

    // Soft focus / neighbor / stall-fallback succeeded — stamp path on the
    // message that OWNS this file (album sibling), not always the focus id.
    if (chatId != null) {
      TdlibMessage? msg;
      // Prefer owner-by-file-id so album cells each get their own path.
      for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[]) {
        if (m.photoRemoteId == fileId ||
            m.photoFallbackFileIds.contains(fileId) ||
            m.videoThumbFileId == fileId ||
            m.videoNoteThumbFileId == fileId) {
          msg = m;
          break;
        }
      }
      if (msg == null) {
        final focusMatch =
            RegExp(r'(?:focus(?:-tail)?:|neighbor:|stall-[^:]+:)(\d+)')
                .firstMatch(reason);
        final msgId =
            focusMatch != null ? int.tryParse(focusMatch.group(1)!) : null;
        if (msgId != null) {
          for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[]) {
            if (m.id == msgId) {
              msg = m;
              break;
            }
          }
        }
      }
      if (msg != null) {
        final primary = msg.photoRemoteId;
        final softDone = msg.photoSizeType == 'm' ||
            msg.photoSizeType == 's' ||
            msg.photoSizeType == null;
        // When a sharper size lands, point primary at it for resolvedPhotoPath.
        // Never stamp a soft path onto upgrade file ids — that blocks upgrades.
        if (primary != null &&
            primary > 0 &&
            primary != fileId &&
            !softDone) {
          _filePathCache[primary] = path;
          _mediaLog(
            'focus-alias primary=$primary ← file=$fileId msg=${msg.id}',
          );
        } else if (primary != null &&
            primary > 0 &&
            primary == fileId) {
          _filePathCache[primary] = path;
        }
        final patched = _messageWithDownloadedFile(msg, fileId, path);
        if (patched != null) {
          _upsertMessage(patched);
        }
        // Soft size paints quickly — then queue x/y upgrades.
        if (softDone &&
            (msg.photoRemoteId == fileId ||
                msg.photoFallbackFileIds.contains(fileId))) {
          final upgrades = msg.photoFallbackFileIds
              .where((id) => id != fileId && !_hasCachedPath(id))
              .toList();
          if (upgrades.isNotEmpty) {
            _mediaLog(
              'focus-upgrade-soft msg=${msg.id} from=$fileId → $upgrades',
            );
            for (final id in upgrades) {
              _queueFileDownload(
                id,
                priority: prioFocused,
                background: false,
                chatId: chatId,
                reason: 'focus-upgrade:${msg.id}',
              );
            }
          }
        } else if (!softDone &&
            (msg.photoRemoteId == fileId ||
                msg.photoFallbackFileIds.contains(fileId))) {
          final dropIds = <int>{
            if (primary != null && primary != fileId) primary,
            ...msg.photoFallbackFileIds.where((id) => id != fileId),
          };
          _dropPendingFocusUpgrades(dropIds, keepFileId: fileId);
        }
      }
    }
    _notifyUi(media: true);
  }

  TdlibMessage _messageWithPhotoPath(TdlibMessage m, String path) {
    return _copyMessage(
      m,
      photoLocalPath: path,
    );
  }

  /// Stamp the downloaded path onto the matching media field (photo vs video thumb).
  TdlibMessage? _messageWithDownloadedFile(
    TdlibMessage m,
    int fileId,
    String path,
  ) {
    if (m.videoThumbFileId == fileId) {
      if (m.videoThumbLocalPath == path) return null;
      return _copyMessage(m, videoThumbLocalPath: path);
    }
    if (m.videoNoteThumbFileId == fileId) {
      if (m.videoNoteThumbLocalPath == path) return null;
      return _copyMessage(m, videoNoteThumbLocalPath: path);
    }
    if (m.videoFileId == fileId) {
      if (m.videoLocalPath == path) return null;
      return _copyMessage(m, videoLocalPath: path);
    }
    if (m.videoNoteFileId == fileId) {
      if (m.videoNoteLocalPath == path) return null;
      return _copyMessage(m, videoNoteLocalPath: path);
    }
    if (m.voiceFileId == fileId) {
      if (m.voiceLocalPath == path) return null;
      return _copyMessage(m, voiceLocalPath: path);
    }
    if (m.photoRemoteId == fileId || m.photoFallbackFileIds.contains(fileId)) {
      if (m.photoLocalPath == path) return null;
      return _copyMessage(m, photoLocalPath: path);
    }
    // Fallback: treat as photo path (legacy callers).
    if (m.photoLocalPath == path) return null;
    return _copyMessage(m, photoLocalPath: path);
  }

  TdlibMessage _copyMessage(
    TdlibMessage m, {
    String? photoLocalPath,
    String? voiceLocalPath,
    String? videoNoteLocalPath,
    String? videoNoteThumbLocalPath,
    String? videoLocalPath,
    String? videoThumbLocalPath,
  }) {
    return TdlibMessage(
      id: m.id,
      chatId: m.chatId,
      senderUserId: m.senderUserId,
      isOutgoing: m.isOutgoing,
      date: m.date,
      text: m.text,
      textEntities: m.textEntities,
      photoLocalPath: photoLocalPath ?? m.photoLocalPath,
      photoRemoteId: m.photoRemoteId,
      photoSizeType: m.photoSizeType,
      photoWidth: m.photoWidth,
      photoHeight: m.photoHeight,
      photoFallbackFileIds: m.photoFallbackFileIds,
      photoThumbBytes: m.photoThumbBytes,
      voiceFileId: m.voiceFileId,
      voiceLocalPath: voiceLocalPath ?? m.voiceLocalPath,
      voiceDurationMs: m.voiceDurationMs,
      videoNoteFileId: m.videoNoteFileId,
      videoNoteLocalPath: videoNoteLocalPath ?? m.videoNoteLocalPath,
      videoNoteDurationMs: m.videoNoteDurationMs,
      videoNoteThumbFileId: m.videoNoteThumbFileId,
      videoNoteThumbLocalPath:
          videoNoteThumbLocalPath ?? m.videoNoteThumbLocalPath,
      videoNoteThumbBytes: m.videoNoteThumbBytes,
      videoFileId: m.videoFileId,
      videoLocalPath: videoLocalPath ?? m.videoLocalPath,
      videoDurationMs: m.videoDurationMs,
      videoWidth: m.videoWidth,
      videoHeight: m.videoHeight,
      videoThumbFileId: m.videoThumbFileId,
      videoThumbLocalPath: videoThumbLocalPath ?? m.videoThumbLocalPath,
      videoThumbBytes: m.videoThumbBytes,
      isAnimation: m.isAnimation,
      reactions: m.reactions,
      replyToMessageId: m.replyToMessageId,
      replyPreviewText: m.replyPreviewText,
      canBeEdited: m.canBeEdited,
      canBeDeletedForAllUsers: m.canBeDeletedForAllUsers,
      canBeDeletedOnlyForSelf: m.canBeDeletedOnlyForSelf,
      isPinned: m.isPinned,
      isService: m.isService,
      mediaAlbumId: m.mediaAlbumId,
      forwardOriginName: m.forwardOriginName,
      forwardOriginChatTitle: m.forwardOriginChatTitle,
      forwardFromChatId: m.forwardFromChatId,
      forwardFromMessageId: m.forwardFromMessageId,
    );
  }

  void _updateFileDownloadProgress(int fileId, Map local, {int expectedSize = 0}) {
    final downloaded = (local['downloaded_size'] as num?)?.toInt() ?? 0;
    final completed = local['is_downloading_completed'] == true;
    final active = local['is_downloading_active'] == true;
    final t = _downloadTrace[fileId];
    if (t != null) {
      if (expectedSize > 0) t.expectedSize = expectedSize;
      final prev = t.lastBytes;
      t.lastBytes = downloaded;
      final now = DateTime.now();
      // Log meaningful progress (~every 10% or ≥256KB step).
      final step = expectedSize > 0
          ? (expectedSize / 10).clamp(64 * 1024, 512 * 1024)
          : 256 * 1024;
      final shouldLog = downloaded - prev >= step ||
          (t.lastProgressAt == null && downloaded > 0) ||
          (!active && downloaded > 0);
      if (shouldLog) {
        final started = t.startedAt ?? t.enqueuedAt;
        final elapsed = now.difference(started);
        final rate = elapsed.inMilliseconds > 0 && downloaded > 0
            ? downloaded / (elapsed.inMilliseconds / 1000.0)
            : 0.0;
        _mediaLog(
          'progress file=$fileId reason=${t.reason} '
          '${_fmtBytes(downloaded)}/${expectedSize > 0 ? _fmtBytes(expectedSize) : '?'} '
          'active=$active '
          'elapsed=${_fmtDur(elapsed)} '
          '${rate > 0 ? 'rate=${_fmtBytes(rate.round())}/s' : 'rate=?'} '
          'conn=$_connectionState',
        );
      }
      t.lastProgressAt = now;
    }
    if (completed) {
      _fileDownloadProgress.remove(fileId);
      return;
    }
    if (!active && downloaded <= 0) {
      // TDLib often emits a transient active=false/0B right after downloadFile
      // ack (and after our own cancel). Don't free the slot for a grace window —
      // the watchdog handles true stalls.
      final started = t?.startedAt ?? t?.lastStartAt;
      final acked = t?.downloadAcked == true;
      if (acked &&
          started != null &&
          DateTime.now().difference(started) < const Duration(seconds: 15)) {
        return;
      }
      if (_downloadInFlight.contains(fileId) && !active) {
        _mediaLog(
          'stalled-cancel file=$fileId reason=${t?.reason ?? ''} '
          'conn=$_connectionState ${_downloadQueueStats()}',
        );
        _releaseDownloadSlot(fileId, failed: true);
        final waiter = _downloadWaiters.remove(fileId);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(_filePathCache[fileId]);
        }
        _notifyUi(media: true);
      }
      return;
    }
    final total = expectedSize > 0 ? expectedSize : 0;
    final next = total > 0 ? (downloaded / total).clamp(0.0, 0.99) : 0.0;
    if (_fileDownloadProgress[fileId] == next) return;
    // Only push UI on meaningful steps (~8%) to avoid ListView rebuild spam.
    final prevUi = _fileDownloadProgress[fileId] ?? -1.0;
    _fileDownloadProgress[fileId] = next;
    if ((next - prevUi).abs() < 0.08 && next < 0.95) return;
    _notifyUi(media: true);
  }

  /// Drop pending background jobs for other chats. In-flight downloads that
  /// belong to the open chat are promoted to foreground instead of cancelled
  /// (cancel→requeue was leaving TDLib at active=true, 0B).
  Future<void> _suspendBackgroundDownloads() async {
    final openId = _openChatId;
    final pendingBg = _downloadQueue.where((j) => j.background).toList();
    for (final j in pendingBg) {
      if (openId != null && j.chatId == openId) {
        j.background = false;
        j.priority = prioFocused;
        _downloadBackgroundIds.remove(j.fileId);
        final t = _downloadTrace[j.fileId];
        if (t != null) {
          t.background = false;
          t.priority = prioFocused;
        }
        continue;
      }
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadBackgroundIds.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }

    final inflightBg = _downloadBackgroundIds.toList();
    for (final id in inflightBg) {
      final t = _downloadTrace[id];
      if (openId != null && t?.chatId == openId) {
        _downloadBackgroundIds.remove(id);
        if (t != null) {
          t.background = false;
          t.priority = prioFocused;
        }
        // Boost the already-running transfer with higher priority (do not cancel).
        unawaited(_startAsyncDownload(
          id,
          prioFocused,
          forceRestart: true,
          reason: 'promote-open:${t?.reason ?? ''}',
        ));
        continue;
      }
      await _cancelTdlibDownload(id);
      _releaseDownloadSlot(id, failed: true);
      final waiter = _downloadWaiters.remove(id);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(_filePathCache[id]);
      }
    }
    if (pendingBg.isNotEmpty || inflightBg.isNotEmpty) {
      debugPrint(
        '[tdlib] suspended bg downloads pending=${pendingBg.length} '
        'inflight=${inflightBg.length}',
      );
      _pumpDownloadQueue();
      notifyListeners();
    }
  }

  Future<void> _cancelTdlibDownload(int fileId) async {
    final c = _client;
    if (c == null) return;
    try {
      await c.sendAwait({
        '@type': 'cancelDownloadFile',
        'file_id': fileId,
        'only_if_pending': false,
      }, timeout: const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[tdlib] cancelDownloadFile($fileId): $e');
    }
  }

  bool get isReady => phase == TdlibAuthPhase.ready;
  bool get isConnected => isReady;

  /// Own Telegram user id after getMe (null until ready).
  int? get myUserId => _myUserId;

  /// Optional hook for FC↔TG group bridge (TG→FC ingest).
  void Function(TdlibMessage msg)? onBridgeNewMessage;

  /// True when MTProto can carry media bytes (Ready / Updating).
  bool get isMtprotoReadyForMedia => _tdlibReadyForMedia;

  /// Raw TDLib connection state name (`connectionStateReady`, …).
  String get mtprotoConnectionState => _connectionState;

  /// App-bar subtitle when media is blocked on connection — empty when Ready.
  /// FamilyChat always routes MTProto through the proxy, so non-Ready states
  /// are shown as waiting on proxy (except explicit "no network").
  String get connectionStatusLabel {
    switch (_connectionState) {
      case 'connectionStateReady':
      case 'connectionStateUpdating':
        return '';
      case 'connectionStateWaitingForNetwork':
        return 'нет сети…';
      case 'connectionStateConnectingToProxy':
      case 'connectionStateConnecting':
      default:
        return 'ожидание подключения к прокси…';
    }
  }

  List<TdlibMessage> messagesFor(int chatId) =>
      List.unmodifiable(_messagesByChat[chatId] ?? const []);

  int lastReadOutboxId(int chatId) => _lastReadOutboxId[chatId] ?? 0;

  /// Last inbox message the user has read (TDLib `last_read_inbox_message_id`).
  int lastReadInboxMessageId(int chatId) =>
      _tdlibInt(_chats[chatId]?['last_read_inbox_message_id']);

  int unreadCountFor(int chatId) =>
      _tdlibInt(_chats[chatId]?['unread_count']);

  /// First (oldest) unread message id, or null if none / not loaded yet.
  int? firstUnreadMessageId(int chatId) {
    final lastRead = lastReadInboxMessageId(chatId);
    final unread = unreadCountFor(chatId);
    if (unread <= 0) return null;
    for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[]) {
      if (m.id > lastRead) return m.id;
    }
    return null;
  }

  Future<void> markMessagesRead(int chatId, List<int> messageIds) async {
    final c = _client;
    if (c == null || !isReady || messageIds.isEmpty) return;
    try {
      await c.sendAwait({
        '@type': 'viewMessages',
        'chat_id': chatId,
        'message_ids': messageIds,
        'force_read': true,
      });
    } catch (e) {
      debugPrint('[tdlib] markMessagesRead failed: $e');
    }
  }

  /// Auto-mark incoming tip only when the inbox is already caught up. Otherwise
  /// opening a chat / syncing the tip would wipe the unread divider.
  void _maybeAutoMarkRead(int chatId, int messageId) {
    if (chatId != _openChatId || messageId <= 0) return;
    if (unreadCountFor(chatId) > 0) return;
    unawaited(_client?.sendAwait({
      '@type': 'viewMessages',
      'chat_id': chatId,
      'message_ids': [messageId],
      'force_read': true,
    }));
  }

  String outgoingReadStatus(TdlibMessage m) {
    if (!m.isOutgoing) return '';
    final last = _lastReadOutboxId[m.chatId] ?? 0;
    if (last > 0 && m.id <= last) return 'read';
    return 'sent';
  }

  int? pinnedMessageId(int chatId) => _pinnedMessageId[chatId];

  /// Active livestream / video chat for [chatId], if any.
  TdlibVideoChat? videoChatFor(int chatId) {
    final vc = _videoChats[chatId];
    if (vc == null || !vc.isActive || vc.groupCallId <= 0) return null;
    return vc;
  }

  /// Refresh video chat state from `getChat` + `getGroupCall`.
  Future<void> refreshVideoChat(int chatId) async {
    final c = _client;
    if (c == null || !isReady || chatId == 0) return;
    try {
      Map<String, dynamic>? chat = _chats[chatId];
      if (chat == null) {
        final raw = await c.sendAwait({
          '@type': 'getChat',
          'chat_id': chatId,
        });
        if (raw['@type'] == 'chat') {
          chat = Map<String, dynamic>.from(raw);
          _chats[chatId] = chat;
        }
      }
      if (chat == null) return;
      await _applyVideoChatFromChat(chatId, chat['video_chat']);
    } catch (e) {
      debugPrint('[tdlib] refreshVideoChat($chatId): $e');
    }
  }

  /// Invite / deep-link URL to open the livestream (Telegram app or t.me).
  ///
  /// In-app WebRTC playback needs tgcalls; until then we open Telegram's join
  /// link so «Вступить» actually starts the stream.
  Future<String?> videoChatJoinUrl(int chatId) async {
    final c = _client;
    if (c == null || !isReady) return null;
    var vc = videoChatFor(chatId);
    if (vc == null) {
      await refreshVideoChat(chatId);
      vc = videoChatFor(chatId);
    }
    if (vc == null) return null;

    try {
      final link = await c.sendAwait({
        '@type': 'getVideoChatInviteLink',
        'group_call_id': vc.groupCallId,
        'can_self_unmute': false,
      });
      final url = link['url']?.toString().trim() ?? '';
      if (url.isNotEmpty) return url;
    } catch (e) {
      debugPrint('[tdlib] getVideoChatInviteLink: $e');
    }

    final username = vc.username.trim();
    if (username.isNotEmpty) {
      return 'https://t.me/$username?livestream';
    }

    // Last resort: public link from profile cache.
    try {
      final profile = await loadChatProfile(chatId);
      final u = profile?.username.trim() ?? '';
      if (u.isNotEmpty) return 'https://t.me/$u?livestream';
    } catch (_) {}
    return null;
  }

  /// Resolve a `t.me` / `tg://` link to a chat (+ optional message) via TDLib.
  /// Upserts the linked message into the local transcript when present.
  Future<TdlibLinkTarget?> resolveTelegramLink(String rawUrl) async {
    final c = _client;
    if (c == null || !isReady) return null;
    if (!TelegramLinkUtils.looksLikeTelegramLink(rawUrl)) return null;
    final url = TelegramLinkUtils.normalize(rawUrl);

    try {
      final info = await c.sendAwait({
        '@type': 'getMessageLinkInfo',
        'url': url,
      });
      if (info['@type']?.toString() == 'messageLinkInfo') {
        final chatId = _tdlibInt(info['chat_id']);
        if (chatId != 0) {
          int? messageId;
          final message = info['message'];
          if (message is Map) {
            final map = Map<String, dynamic>.from(message);
            map.putIfAbsent('chat_id', () => chatId);
            final parsed = _parseMessage(map);
            if (parsed != null) {
              _upsertMessage(parsed);
              messageId = parsed.id;
              notifyListeners();
            } else {
              messageId = _tdlibInt(map['id']);
              if (messageId == 0) messageId = null;
            }
          }
          // Ensure chat is cached for title / navigation.
          if (!_chats.containsKey(chatId)) {
            try {
              final chat = await c.sendAwait({
                '@type': 'getChat',
                'chat_id': chatId,
              });
              if (chat['@type'] == 'chat') {
                _chats[chatId] = Map<String, dynamic>.from(chat);
              }
            } catch (_) {}
          }
          return TdlibLinkTarget(
            chatId: chatId,
            messageId: messageId,
            title: peerTitle(chatId),
          );
        }
      }
    } catch (e) {
      debugPrint('[tdlib] getMessageLinkInfo: $e');
    }

    // Username-only (or message link TDLib couldn't resolve): open the chat.
    final username = TelegramLinkUtils.usernameFromLink(url);
    if (username == null || username.isEmpty) return null;
    try {
      final chat = await c.sendAwait({
        '@type': 'searchPublicChat',
        'username': username,
      });
      if (chat['@type'] != 'chat') return null;
      final chatId = _tdlibInt(chat['id']);
      if (chatId == 0) return null;
      _chats[chatId] = Map<String, dynamic>.from(chat);
      notifyListeners();
      return TdlibLinkTarget(
        chatId: chatId,
        title: peerTitle(chatId),
      );
    } catch (e) {
      debugPrint('[tdlib] searchPublicChat($username): $e');
      return null;
    }
  }

  /// Load a single message into the transcript (e.g. after a deep link jump).
  Future<TdlibMessage?> ensureMessageLoaded(int chatId, int messageId) async {
    final c = _client;
    if (c == null || !isReady || chatId == 0 || messageId <= 0) return null;
    final existing = _messagesByChat[chatId]
        ?.where((m) => m.id == messageId)
        .firstOrNull;
    if (existing != null) return existing;
    try {
      final raw = await c.sendAwait({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
      if (raw['@type'] != 'message') return null;
      final map = Map<String, dynamic>.from(raw);
      map.putIfAbsent('chat_id', () => chatId);
      final parsed = _parseMessage(map);
      if (parsed != null) {
        _upsertMessage(parsed);
        notifyListeners();
      }
      return parsed;
    } catch (e) {
      debugPrint('[tdlib] getMessage($chatId,$messageId): $e');
      return null;
    }
  }

  String senderDisplayName(int userId) {
    final user = _users[userId];
    if (user == null) return 'Telegram';
    final first = user['first_name']?.toString() ?? '';
    final last = user['last_name']?.toString() ?? '';
    final name = ('$first $last').trim();
    return name.isEmpty ? 'Telegram' : name;
  }

  Future<void> ensureStarted({bool forceRestart = false}) {
    final prev = _ensureStartedGate ?? Future<void>.value();
    late final Future<void> mine;
    mine = prev
        .catchError((_) {})
        .then((_) => _ensureStartedBody(forceRestart: forceRestart));
    _ensureStartedGate = mine;
    return mine;
  }

  Future<void> _ensureStartedBody({bool forceRestart = false}) async {
    if (!TdlibConfig.isEnabled) {
      phase = TdlibAuthPhase.unavailable;
      errorMessage = !TdlibConfig.isSupportedPlatform
          ? 'Telegram TDLib пока только на Android'
          : 'Нет Telegram API credentials';
      notifyListeners();
      return;
    }
    if (forceRestart) {
      _didWipeForEncryption = false;
      await _tearDown(wipeDatabase: true);
    }
    if (_client != null) {
      // Recover if we missed the first updateAuthorizationState (race on subscribe).
      if (phase == TdlibAuthPhase.starting ||
          phase == TdlibAuthPhase.error ||
          phase == TdlibAuthPhase.unavailable) {
        phase = TdlibAuthPhase.starting;
        errorMessage = null;
        notifyListeners();
        await _syncAuthorizationState();
      }
      _ensureNetworkLinkWatch();
      return;
    }
    phase = TdlibAuthPhase.starting;
    errorMessage = null;
    notifyListeners();
    try {
      TdlibJsonClient.onNeedsParameters = _onNeedsTdlibParameters;
      _client = await TdlibJsonClient.create();
      _sub = _client!.updates.listen(_onUpdate);
      _ensureNetworkLinkWatch();
      unawaited(_setTdlibOnline(true));
      unawaited(_applyNetworkTypeFromDevice(why: 'client-start', force: true));
      // Critical: first WaitTdlibParameters may arrive before listen attaches.
      await _syncAuthorizationState();
    } catch (e) {
      phase = TdlibAuthPhase.error;
      errorMessage = e.toString();
      notifyListeners();
    }
  }

  /// Hook from [TdlibJsonClient] when native client is uninitialized.
  void _onNeedsTdlibParameters(TdlibApiException error) {
    // Don't tear down while we're deliberately applying parameters.
    if (_tearingDown || _recoveringClient || _setParamsJob != null) return;
    unawaited(_recoverDeadClient('api:${error.message}'));
  }

  /// Native client closed / reset while Dart still thought Ready.
  Future<void> _recoverDeadClient(String why) async {
    if (_tearingDown || _recoveringClient) return;
    final last = _lastDeadClientRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastDeadClientRecoverAt = DateTime.now();
    _recoveringClient = true;
    _mediaLog('recover-dead-client why=$why phase=$phase conn=$_connectionState');
    try {
      _parametersApplied = false;
      await _tearDown(wipeDatabase: false);
      phase = TdlibAuthPhase.starting;
      notifyListeners();
      await ensureStarted();
    } catch (e) {
      _mediaLog('recover-dead-client FAIL $e');
      phase = TdlibAuthPhase.error;
      errorMessage = e.toString();
      notifyListeners();
    } finally {
      _recoveringClient = false;
    }
  }

  Future<void> _tearDown({bool wipeDatabase = false}) async {
    _tearingDown = true;
    try {
      await _tearDownBody(wipeDatabase: wipeDatabase);
    } finally {
      _tearingDown = false;
    }
  }

  Future<void> _tearDownBody({bool wipeDatabase = false}) async {
    await _fcmTokenSub?.cancel();
    _fcmTokenSub = null;
    _registeredFcmToken = null;
    _pushReceiverId = null;
    await _sub?.cancel();
    _sub = null;
    await _client?.dispose();
    _client = null;
    _parametersApplied = false;
    _setParamsJob = null;
    _authJob = null;
    _chats.clear();
    _users.clear();
    _supergroups.clear();
    _supergroupFetchQueued.clear();
    _chatOrder.clear();
    _messagesByChat.clear();
    _chatActions.clear();
    _notifGroupChatId.clear();
    _chatMemberStatus.clear();
    _canSendMessages.clear();
    _myUserId = null;
    _filePathCache.clear();
    _downloadQueued.clear();
    _downloadInFlight.clear();
    _downloadBackgroundIds.clear();
    _downloadQueue.clear();
    _downloadActive = 0;
    _fileDownloadProgress.clear();
    _downloadTrace.clear();
    _remoteUniqueToFileId.clear();
    _downloadWatchdog?.cancel();
    _downloadWatchdog = null;
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    _uiNotifyPending = false;
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    _connectingTimeoutTimer?.cancel();
    _connectingTimeoutTimer = null;
    _connectingSince = null;
    _readyAt = null;
    _enabledProxyId = null;
    _lastConnectionKickAt = null;
    _connectionKickCount = 0;
    _lastSetNetworkTypeAt = null;
    _setNetworkTypeJob = null;
    await _networkLinkSub?.cancel();
    _networkLinkSub = null;
    for (final w in _downloadWaiters.values) {
      if (!w.isCompleted) w.complete(null);
    }
    _downloadWaiters.clear();
    if (wipeDatabase) {
      // Full local TG wipe / force restart — drop server self-link too.
      unawaited(_deactivateTdlibIdentityOnServer());
      await _wipeTdlibFiles();
    }
  }

  Future<void> _wipeTdlibFiles() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      for (final name in ['tdlib', 'tdlib_files']) {
        final dir = Directory(p.join(docs.path, name));
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
      await _secure.delete(key: _dbKeyStorageKey);
    } catch (e) {
      debugPrint('[tdlib] wipe failed: $e');
    }
  }

  Future<void> _syncAuthorizationState() async {
    final c = _client;
    if (c == null) return;
    try {
      final state = await c.sendAwait({'@type': 'getAuthorizationState'});
      await _enqueueAuth(state);
    } on TdlibApiException catch (e) {
      if (e.isNeedsTdlibParameters) {
        await _recoverDeadClient('sync-auth');
        return;
      }
      debugPrint('[tdlib] getAuthorizationState failed: $e');
      phase = TdlibAuthPhase.error;
      errorMessage = e.toString();
      notifyListeners();
    } catch (e) {
      debugPrint('[tdlib] getAuthorizationState failed: $e');
      phase = TdlibAuthPhase.error;
      errorMessage = e.toString();
      notifyListeners();
    }
  }

  Future<void> _enqueueAuth(dynamic state) {
    final prev = _authJob ?? Future<void>.value();
    _authJob = prev.then((_) => _handleAuthState(state));
    return _authJob!;
  }

  Future<void> submitPhone(String phone) async {
    await ensureStarted();
    // Wait until TDLib asks for phone (after setTdlibParameters).
    for (var i = 0; i < 100 && phase == TdlibAuthPhase.starting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (phase != TdlibAuthPhase.waitPhone) {
      throw StateError(
        'Telegram ещё не готов к вводу номера (phase=$phase). Подождите.',
      );
    }
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phone.trim(),
      'settings': {
        '@type': 'phoneNumberAuthenticationSettings',
        'allow_flash_call': false,
        'allow_missed_call': false,
        'is_current_phone_number': false,
        'allow_sms_retriever_api': false,
      },
    });
  }

  Future<void> submitCode(String code) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'checkAuthenticationCode',
      'code': code.trim(),
    });
  }

  Future<void> submitPassword(String password) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
  }

  Future<void> logOut() async {
    final c = _client;
    if (c == null) return;
    phase = TdlibAuthPhase.loggingOut;
    notifyListeners();
    await _unregisterPushDevice();
    // Explicit TG disconnect — deactivate server identity (keep FC threads).
    unawaited(_deactivateTdlibIdentityOnServer());
    await c.sendAwait({'@type': 'logOut'});
  }

  FamilyChatRepository _familychatRepo() => FamilyChatRepository(ApiClient());

  static String _tdlibUsernameFromUser(Map<String, dynamic> user) {
    final usernames = user['usernames'];
    if (usernames is Map) {
      var username = usernames['editable_username']?.toString() ?? '';
      if (username.isEmpty) {
        final active = usernames['active_usernames'];
        if (active is List && active.isNotEmpty) {
          username = active.first.toString();
        }
      }
      return username;
    }
    return user['username']?.toString() ?? '';
  }

  /// After TDLib Ready: getMe → PUT identity → reconcile family matches.
  Future<void> _syncTdlibIdentityAfterReady() async {
    final c = _client;
    if (c == null || phase != TdlibAuthPhase.ready) return;
    try {
      final me = await c.sendAwait({'@type': 'getMe'});
      if (me['@type'] != 'user') return;
      final id = (me['id'] as num?)?.toInt();
      if (id == null || id <= 0) return;
      _myUserId = id;
      _users[id] = Map<String, dynamic>.from(me);
      final username = _tdlibUsernameFromUser(me);
      final firstName = me['first_name']?.toString() ?? '';
      await _familychatRepo().putTdlibIdentity(
        tgUserId: id,
        tgUsername: username,
        tgFirstName: firstName,
      );
      await reconcileFamilyIdentities();
    } catch (e) {
      debugPrint('[tdlib] identity sync failed: $e');
    }
  }

  Future<void> _deactivateTdlibIdentityOnServer() async {
    try {
      await _familychatRepo().deleteTdlibIdentity();
    } catch (e) {
      debugPrint('[tdlib] identity deactivate failed: $e');
    }
  }

  /// Fetch shared-family TDLib identities and upsert local hub matches.
  Future<int> reconcileFamilyIdentities() async {
    try {
      final identities = await _familychatRepo().listFamilyTdlibIdentities();
      final privateMap = <int, int>{};
      for (final c in privateChats) {
        if (c.userId > 0) privateMap[c.userId] = c.chatId;
      }
      final n = await TelegramMatchStore.instance.reconcileFromFamilyIdentities(
        identities: identities,
        privateTgUserToChatId: privateMap,
      );
      await refreshMatchedTgUserIds();
      if (n > 0) {
        debugPrint('[tdlib] reconciled $n identity matches');
        notifyListeners();
      }
      return n;
    } catch (e) {
      debugPrint('[tdlib] family identity reconcile failed: $e');
      return 0;
    }
  }

  /// Feed an Android FCM payload into TDLib (foreground or background isolate).
  Future<void> processPushNotificationPayload(String payloadJson) async {
    if (kIsWeb || !Platform.isAndroid) return;
    await ensureStarted();
    final c = _client;
    if (c == null) return;
    try {
      await c.sendAwait({
        '@type': 'processPushNotification',
        'payload': payloadJson,
      });
    } on TdlibApiException catch (e) {
      // 406 = unsupported / need full sync — refresh chat list as fallback.
      debugPrint('[tdlib] processPushNotification: $e');
      if (e.code == 406 && isReady) {
        unawaited(refreshChatList());
      }
    } catch (e) {
      debugPrint('[tdlib] processPushNotification failed: $e');
    }
  }

  Future<void> _enableNotificationApiAndRegisterDevice() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final c = _client;
    if (c == null || !isReady) return;
    try {
      await c.sendAwait({
        '@type': 'setOption',
        'name': 'notification_group_count_max',
        'value': {'@type': 'optionValueInteger', 'value': 25},
      });
      await c.sendAwait({
        '@type': 'setOption',
        'name': 'notification_group_size_max',
        'value': {'@type': 'optionValueInteger', 'value': 10},
      });
    } catch (e) {
      debugPrint('[tdlib] setOption notifications failed: $e');
    }
    await _registerFcmDevice();
    _fcmTokenSub ??= FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(_registerFcmDevice(tokenOverride: token));
    });
  }

  Future<void> _registerFcmDevice({String? tokenOverride}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    final c = _client;
    if (c == null || !isReady) return;
    try {
      if (Firebase.apps.isEmpty) {
        final options = DefaultFirebaseOptions.currentPlatform;
        if (options != null) {
          await Firebase.initializeApp(options: options);
        } else {
          await Firebase.initializeApp();
        }
      }
      final token =
          tokenOverride ?? await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      if (token == _registeredFcmToken && _pushReceiverId != null) return;
      final res = await c.sendAwait({
        '@type': 'registerDevice',
        'device_token': {
          '@type': 'deviceTokenFirebaseCloudMessaging',
          'token': token,
          'encrypt': true,
        },
        'other_user_ids': <int>[],
      });
      _registeredFcmToken = token;
      _pushReceiverId = _tdlibInt(res['id']);
      if (_pushReceiverId == 0) _pushReceiverId = null;
      debugPrint('[tdlib] registerDevice ok receiver=$_pushReceiverId');
    } catch (e) {
      debugPrint('[tdlib] registerDevice failed: $e');
    }
  }

  Future<void> _unregisterPushDevice() async {
    await _fcmTokenSub?.cancel();
    _fcmTokenSub = null;
    final token = _registeredFcmToken;
    _registeredFcmToken = null;
    _pushReceiverId = null;
    final c = _client;
    if (c == null || token == null || token.isEmpty) return;
    try {
      await c.sendAwait({
        '@type': 'unregisterDevice',
        'device_token': {
          '@type': 'deviceTokenFirebaseCloudMessaging',
          'token': token,
          'encrypt': true,
        },
        'only_current_device': true,
      });
    } catch (e) {
      debugPrint('[tdlib] unregisterDevice failed: $e');
    }
  }

  Future<void> refreshChatList() async {
    final c = _client;
    if (c == null || !isReady) return;
    // TDLib loads the main list in pages; keep going until "Have no more chats".
    var timeoutStreak = 0;
    for (var i = 0; i < 40; i++) {
      try {
        await c.sendAwait(
          {
            '@type': 'loadChats',
            'chat_list': {'@type': 'chatListMain'},
            'limit': 100,
          },
          timeout: const Duration(seconds: 45),
        );
        timeoutStreak = 0;
      } on TdlibApiException catch (e) {
        if (e.code == 404) break; // Have no more chats to load
        debugPrint('[tdlib] loadChats failed: $e');
        break;
      } on TimeoutException catch (e) {
        timeoutStreak++;
        debugPrint('[tdlib] loadChats timeout ($timeoutStreak): $e');
        if (timeoutStreak >= 3) break;
        await Future<void>.delayed(
          Duration(milliseconds: 400 * timeoutStreak),
        );
      } catch (e) {
        debugPrint('[tdlib] loadChats failed: $e');
        break;
      }
    }
    notifyListeners();
  }

  Future<void> openChat(int chatId) async {
    final c = _client;
    if (c == null || !isReady) return;
    _openChatId = chatId;
    unawaited(_suspendBackgroundDownloads());
    unawaited(_cancelLocalTdlibNotification(chatId));
    // Drop leftover non-focus downloads (e.g. avatar from a previous open).
    _purgeNonFocusDownloads(keepChatId: chatId);

    try {
      final chat = await c.sendAwait({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      if (chat['@type'] == 'chat') {
        _chats[chatId] = Map<String, dynamic>.from(chat);
        final lastOut = (chat['last_read_outbox_message_id'] as num?)?.toInt();
        if (lastOut != null) _lastReadOutboxId[chatId] = lastOut;
        try {
          final pinned = await c.sendAwait({
            '@type': 'getChatPinnedMessage',
            'chat_id': chatId,
          });
          if (pinned['@type'] == 'message') {
            final id = (pinned['id'] as num?)?.toInt();
            if (id != null) _pinnedMessageId[chatId] = id;
          }
        } catch (_) {}
        unawaited(_applyVideoChatFromChat(chatId, chat['video_chat']));
      }
    } on TdlibApiException catch (e) {
      if (e.isNeedsTdlibParameters) {
        await _recoverDeadClient('openChat-getChat');
        return;
      }
    } catch (_) {}

    // Seed last_message immediately so UI isn't blank while history loads.
    final last = _chats[chatId]?['last_message'];
    if (last is Map) {
      final lastMap = Map<String, dynamic>.from(last);
      lastMap.putIfAbsent('chat_id', () => chatId);
      final seeded = _parseMessage(lastMap);
      if (seeded != null) {
        _upsertMessage(seeded);
        notifyListeners();
      }
    }

    try {
      await c.sendAwait({'@type': 'openChat', 'chat_id': chatId});
    } on TdlibApiException catch (e) {
      if (e.isNeedsTdlibParameters) {
        await _recoverDeadClient('openChat');
        return;
      }
    } catch (_) {}
    unawaited(refreshCanSendMessages(chatId));

    final peerUid = _privateUserId(chatId);
    if (peerUid != null) {
      await _refreshUser(peerUid, queueAvatar: false);
    }

    // Always paint local DB first (fast). A remote-only getChatHistory can
    // hang 45s+ through the proxy while the UI shows a single seeded
    // last_message — that looks like "empty channel" with no Connecting.
    if (!_tdlibReadyForMedia) {
      _mediaLog(
        'openChat=$chatId local history first — still $_connectionState '
        '(remote fill on Ready)',
      );
      _ensureConnectingWaitLogTimer();
    }
    await _loadChatHistory(chatId, preferLocal: true);
    if (_tdlibReadyForMedia) {
      unawaited(() async {
        await _loadChatHistory(chatId, preferLocal: false);
        await syncChatTail(chatId);
        _mediaLog(
          'openChat-remote-fill chat=$chatId '
          'msgs=${_messagesByChat[chatId]?.length ?? 0}',
        );
      }());
    } else {
      // When MTProto is Connecting, schedule a remote refill once Ready.
      unawaited(() async {
        final ok = await _waitForMediaConnection(
          timeout: const Duration(seconds: 90),
        );
        if (!ok || _openChatId != chatId) return;
        await _loadChatHistory(chatId, preferLocal: false);
        await syncChatTail(chatId);
        _mediaLog(
          'openChat-deferred-remote chat=$chatId '
          'msgs=${_messagesByChat[chatId]?.length ?? 0}',
        );
      }());
    }

    // Avatar AFTER transcript/media focus — never steal the download slot.
    // Header keeps minithumb until focus media finishes.
    // (Avatar kick deferred; see focusNewest / ready-catchup.)
  }

  /// Wait until TDLib can carry media/history bytes (Ready/Updating).
  Future<bool> _waitForMediaConnection({
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (_tdlibReadyForMedia) return true;
    final start = DateTime.now();
    _mediaLog(
      'wait-media-conn start conn=$_connectionState '
      'timeout=${timeout.inSeconds}s',
    );
    while (!_tdlibReadyForMedia) {
      if (DateTime.now().difference(start) >= timeout) {
        _mediaLog('wait-media-conn TIMEOUT conn=$_connectionState');
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _mediaLog(
      'wait-media-conn ok after '
      '${_fmtDur(DateTime.now().difference(start))} conn=$_connectionState',
    );
    return true;
  }

  /// Remove queued/inflight downloads that aren't exclusive-focus media.
  void _purgeNonFocusDownloads({int? keepChatId}) {
    final focus = _focusDownloadOrder.toSet();
    final dropQueued = _downloadQueue.where((j) {
      if (focus.contains(j.fileId)) return false;
      final r = j.reason;
      if (r.startsWith('focus:') ||
          r.startsWith('focus-tail:') ||
          r.startsWith('demoted-after-focus:') ||
          r.startsWith('tap:') ||
          r.startsWith('ensure') ||
          r.startsWith('stall-retry:')) {
        return false;
      }
      // Avatars / empty-reason leftovers.
      return true;
    }).toList();
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _mediaLog('purge-queue file=${j.fileId} reason=${j.reason}');
    }
    for (final id in _downloadInFlight.toList()) {
      if (focus.contains(id)) continue;
      final t = _downloadTrace[id];
      final r = t?.reason ?? '';
      if (r.startsWith('focus:') ||
          r.startsWith('focus-tail:') ||
          r.startsWith('tap:') ||
          r.startsWith('ensure')) {
        continue;
      }
      unawaited(() async {
        await _cancelTdlibDownload(id);
        _releaseDownloadSlot(id, failed: true);
        _downloadTrace.remove(id);
        _fileDownloadProgress.remove(id);
        _mediaLog('purge-inflight file=$id reason=$r');
      }());
    }
    if (dropQueued.isNotEmpty) {
      _mediaLog(
        'purge-non-focus dropped=${dropQueued.length} keepChat=$keepChatId '
        '${_downloadQueueStats()}',
      );
    }
  }

  Future<void> _loadChatHistory(
    int chatId, {
    int minCount = 20,
    bool? preferLocal,
  }) async {
    final c = _client;
    if (c == null) return;

    final isChannel = isChannelChat(chatId);
    // preferLocal=true → only_local (fast). Otherwise remote when Ready.
    final onlyLocal = preferLocal ?? !_tdlibReadyForMedia;
    // Channels need many round-trips while TDLib pulls remote history.
    final maxAttempts = onlyLocal
        ? (isChannel ? 12 : 6)
        : (isChannel ? 40 : 20);
    final emptyLimit = onlyLocal
        ? (isChannel ? 4 : 2)
        : (isChannel ? 12 : 4);
    // Cap so a busy channel from the last 5 days can't run forever.
    final maxCount = isChannel ? 200 : 120;
    // Proxy path often stalls remote channel pages — keep per-call timeout
    // modest and retry instead of one 45s hang with seed=1 on screen.
    final callTimeout = Duration(
      seconds: onlyLocal ? 8 : (isChannel ? 18 : 20),
    );

    final byId = <int, TdlibMessage>{
      for (final m in _messagesByChat[chatId] ?? const []) m.id: m,
    };

    // Seed from chat.last_message so UI isn't empty while history loads.
    final last = _chats[chatId]?['last_message'];
    if (last is Map) {
      final lastMap = Map<String, dynamic>.from(last);
      lastMap.putIfAbsent('chat_id', () => chatId);
      final seeded = _parseMessage(lastMap);
      if (seeded != null) byId[seeded.id] = seeded;
    }
    if (byId.isNotEmpty) {
      _messagesByChat[chatId] = byId.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      notifyListeners();
    }

    var fromMessageId = 0;
    var emptyStreak = 0;
    var stagnantStreak = 0;

    void mergeLiveIntoById() {
      for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[]) {
        byId[m.id] = m;
      }
    }

    bool reachedAgeFloor() {
      if (byId.length < minCount) return false;
      var oldest = 0;
      for (final m in byId.values) {
        if (oldest == 0 || m.date < oldest) oldest = m.date;
      }
      return oldest > 0 && !_isWithinMediaAutoAge(oldest);
    }

    _mediaLog(
      'loadHistory chat=$chatId onlyLocal=$onlyLocal '
      'seed=${byId.length} conn=$_connectionState',
    );

    for (var attempt = 0;
        attempt < maxAttempts && byId.length < maxCount && !reachedAgeFloor();
        attempt++) {
      if (_openChatId != chatId) return;
      Map<String, dynamic> res;
      final t0 = DateTime.now();
      try {
        res = await c.sendAwait({
          '@type': 'getChatHistory',
          'chat_id': chatId,
          'from_message_id': fromMessageId,
          'offset': 0,
          'limit': isChannel ? 100 : 50,
          'only_local': onlyLocal,
        }, timeout: callTimeout);
      } on TdlibApiException catch (e) {
        _mediaLog(
          'getChatHistory fail chat=$chatId attempt=$attempt '
          'onlyLocal=$onlyLocal after=${_fmtDur(DateTime.now().difference(t0))} '
          'err=$e',
        );
        if (e.isNeedsTdlibParameters) {
          await _recoverDeadClient('getChatHistory');
          return;
        }
        // Transient timeouts are common while TDLib syncs a channel — retry.
        emptyStreak++;
        if (emptyStreak >= emptyLimit) break;
        await Future<void>.delayed(
          Duration(milliseconds: 250 + emptyStreak * 80),
        );
        continue;
      } catch (e) {
        _mediaLog(
          'getChatHistory fail chat=$chatId attempt=$attempt '
          'onlyLocal=$onlyLocal after=${_fmtDur(DateTime.now().difference(t0))} '
          'err=$e',
        );
        // Transient timeouts are common while TDLib syncs a channel — retry.
        emptyStreak++;
        if (emptyStreak >= emptyLimit) break;
        await Future<void>.delayed(
          Duration(milliseconds: 250 + emptyStreak * 80),
        );
        continue;
      }

      // Updates may arrive during await — don't wipe them on write-back.
      mergeLiveIntoById();

      if (res['@type'] != 'messages') break;
      final list = res['messages'];
      if (list is! List || list.isEmpty) {
        emptyStreak++;
        if (emptyStreak >= emptyLimit) break;
        await Future<void>.delayed(
          Duration(milliseconds: isChannel ? 300 + emptyStreak * 60 : 120),
        );
        continue;
      }
      emptyStreak = 0;

      final beforeCount = byId.length;
      var oldestId = fromMessageId;
      for (final raw in list) {
        if (raw is! Map) continue;
        final map = raw is Map<String, dynamic>
            ? raw
            : Map<String, dynamic>.from(raw);
        map.putIfAbsent('chat_id', () => chatId);
        final msg = _parseMessage(map);
        if (msg == null) continue;
        byId[msg.id] = msg;
        if (oldestId == 0 || msg.id < oldestId) oldestId = msg.id;
      }

      mergeLiveIntoById();

      final sorted = byId.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      _messagesByChat[chatId] = sorted;
      notifyListeners();

      _mediaLog(
        'getChatHistory ok chat=$chatId attempt=$attempt '
        'page=${list.length} total=${byId.length} '
        'dt=${_fmtDur(DateTime.now().difference(t0))} '
        'onlyLocal=$onlyLocal',
      );

      // Always walk toward older ids when the page produced an older tip.
      final advanced = oldestId > 0 && oldestId != fromMessageId;
      if (advanced) {
        fromMessageId = oldestId;
        stagnantStreak = 0;
      } else if (byId.length == beforeCount) {
        stagnantStreak++;
        if (stagnantStreak >= (isChannel ? 6 : 3)) break;
        await Future<void>.delayed(
          Duration(milliseconds: isChannel ? 250 : 100),
        );
        continue;
      } else {
        // New msgs but oldest didn't move — stop to avoid loops.
        break;
      }

      if (list.length < 5) {
        await Future<void>.delayed(
          Duration(milliseconds: isChannel ? 120 : 40),
        );
      }
    }

    mergeLiveIntoById();
    final finalList = byId.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    _messagesByChat[chatId] = finalList;
    notifyListeners();
    _mediaLog(
      'history-done chat=$chatId count=${finalList.length} '
      'channel=$isChannel onlyLocal=$onlyLocal '
      'ageFloor=${reachedAgeFloor()}',
    );
  }

  /// Pull newest page and merge (never replaces existing messages wholesale).
  /// Retries until `getChat().last_message` is present in the transcript — that
  /// covers the case when local TDLib DB lags the server after a missed update.
  Future<void> syncChatTail(int chatId, {int limit = 40}) async {
    final c = _client;
    if (c == null || !isReady) return;
    try {
      for (var attempt = 0; attempt < 8; attempt++) {
        if (_openChatId != null && _openChatId != chatId && attempt > 0) {
          // Still allow hub-driven sync of non-open chats.
        }

        final chat = await c.sendAwait({
          '@type': 'getChat',
          'chat_id': chatId,
        });
        int? expectedLastId;
        if (chat['@type'] == 'chat') {
          _chats[chatId] = Map<String, dynamic>.from(chat);
          final lastOut =
              (chat['last_read_outbox_message_id'] as num?)?.toInt();
          if (lastOut != null) _lastReadOutboxId[chatId] = lastOut;

          final last = chat['last_message'];
          if (last is Map) {
            final lastMap = Map<String, dynamic>.from(last);
            lastMap.putIfAbsent('chat_id', () => chatId);
            expectedLastId = (lastMap['id'] as num?)?.toInt();
            final seeded = _parseMessage(lastMap);
            if (seeded != null) _upsertMessage(seeded);
          }
        }

        final res = await c.sendAwait({
          '@type': 'getChatHistory',
          'chat_id': chatId,
          'from_message_id': 0,
          'offset': 0,
          'limit': limit,
          'only_local': false,
        });
        if (res['@type'] == 'messages') {
          final list = res['messages'];
          if (list is List) {
            for (final raw in list) {
              if (raw is! Map) continue;
              final map = raw is Map<String, dynamic>
                  ? raw
                  : Map<String, dynamic>.from(raw);
              map.putIfAbsent('chat_id', () => chatId);
              final msg = _parseMessage(map);
              if (msg != null) _upsertMessage(msg);
            }
          }
        }

        // Explicitly fetch the tip message if history page still lags.
        if (expectedLastId != null &&
            expectedLastId > 0 &&
            !(_messagesByChat[chatId]?.any((m) => m.id == expectedLastId) ??
                false)) {
          try {
            final one = await c.sendAwait({
              '@type': 'getMessage',
              'chat_id': chatId,
              'message_id': expectedLastId,
            });
            if (one['@type'] == 'message') {
              final msg = _parseMessage(one);
              if (msg != null) _upsertMessage(msg);
            }
          } catch (_) {}
        }

        // Media for open chat is owned by history tip + viewport — not every
        // syncChatTail (that re-boosted inFlight downloads into a 0B stall).
        notifyListeners();

        final haveTip = expectedLastId == null ||
            expectedLastId <= 0 ||
            (_messagesByChat[chatId]?.any((m) => m.id == expectedLastId) ??
                false);
        if (haveTip) break;

        // Wait for TDLib to catch up from Telegram servers.
        await Future<void>.delayed(
          Duration(milliseconds: 150 + attempt * 120),
        );
      }
    } catch (e) {
      debugPrint('[tdlib] syncChatTail failed: $e');
    }
  }

  Future<void> _onConnectionReady() async {
    await refreshChatList();
    final openId = _openChatId;
    if (openId != null) {
      // Local-only openChat pass often left a thin transcript — refill from DC.
      final count = _messagesByChat[openId]?.length ?? 0;
      if (count < 40) {
        await _loadChatHistory(openId);
      }
      await syncChatTail(openId);
      // Focus media first — avatar only after focus queue is empty.
      if (_focusMessageId != null) {
        focusVisibleMessageMedia(
          chatId: openId,
          messageId: _focusMessageId!,
        );
      }
      if (_focusDownloadOrder.isEmpty && _downloadInFlight.isEmpty) {
        _ensurePeerAvatarDownloading(openId, foreground: true);
      }
      _mediaLog(
        'ready-catchup chat=$openId msgs='
        '${_messagesByChat[openId]?.length ?? 0}',
      );
    } else {
      unawaited(_warmRecentHubMedia());
    }
  }

  /// Background hub warm — disabled in exclusive-focus v1.
  Future<void> _warmRecentHubMedia() async {
    return;
  }

  bool _isWithinMediaAutoAge(int unixSec) {
    if (unixSec <= 0) return true;
    final created = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    return !ChatMediaDisplayPolicy.isOlderThanDeferredAge(created);
  }

  /// Neighbor message ids to enqueue AFTER focus claims download slots.
  /// Enqueuing them synchronously raced ahead of async openMessageContent
  /// and filled both slots with neighbor 0B jobs while focus waited.
  List<int> _pendingNeighborMessageIds = const [];

  /// Prefetch light media around the user's scroll focus in an open chat.
  ///
  /// Focus is applied first; neighbors are deferred until focus files are
  /// queued so they cannot steal both download slots.
  void prefetchOpenChatViewport({
    required int chatId,
    int? focusMessageId,
    int radius = viewportMediaRadius,
  }) {
    if (_openChatId != chatId) return;
    if (focusMessageId == null || focusMessageId <= 0) return;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    final idx = list.indexWhere((m) => m.id == focusMessageId);
    if (idx < 0) {
      _pendingNeighborMessageIds = const [];
      focusVisibleMessageMedia(chatId: chatId, messageId: focusMessageId);
      return;
    }
    final neighborIds = <int>[];
    if (radius > 0) {
      for (var dist = 1; dist <= radius; dist++) {
        for (final i in [idx - dist, idx + dist]) {
          if (i < 0 || i >= list.length) continue;
          final m = list[i];
          if (!_messageHasLightMedia(m)) continue;
          neighborIds.add(m.id);
        }
      }
    }
    _pendingNeighborMessageIds = neighborIds;
    focusVisibleMessageMedia(chatId: chatId, messageId: focusMessageId);
  }

  void _flushPendingNeighbors(int chatId) {
    final ids = _pendingNeighborMessageIds;
    _pendingNeighborMessageIds = const [];
    if (ids.isEmpty) return;
    // Only queue neighbors when focus already owns at least one slot / queue
    // head — otherwise they start first again.
    for (final mid in ids) {
      _enqueueNeighborMedia(chatId: chatId, messageId: mid);
    }
  }

  /// Free slots held by idle neighbor/demoted jobs so focus can start.
  Future<void> _yieldSlotsToFocus(Set<int> want) async {
    final blockers = <int>[];
    for (final id in _downloadInFlight.toList()) {
      if (want.contains(id)) continue;
      final t = _downloadTrace[id];
      final reason = t?.reason ?? '';
      if (reason.startsWith('tap:')) continue;
      if (reason.startsWith('focus:') ||
          reason.startsWith('focus-tail:') ||
          reason.startsWith('focus-upgrade:') ||
          reason.startsWith('stall-fallback:')) {
        continue;
      }
      // Neighbor / demoted / neighbor lastchance at 0B must free the slot.
      if ((t?.lastBytes ?? 0) > 0) continue;
      blockers.add(id);
    }
    // Also drop queued neighbors so they don't refill the slot.
    final dropQueued = _downloadQueue
        .where((j) =>
            !want.contains(j.fileId) &&
            (j.reason.startsWith('neighbor:') ||
                j.reason.startsWith('demoted-after-focus') ||
                (j.reason.startsWith('stall-lastchance:') &&
                    j.priority < prioFocused)))
        .toList();
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }
    if (blockers.isEmpty && dropQueued.isEmpty) return;
    _mediaLog(
      'yield-slots-to-focus cancel=${blockers.join(",")} '
      'dropQ=${dropQueued.map((j) => j.fileId).join(",")} '
      'want=${want.take(4).join(",")}',
    );
    for (final id in blockers) {
      await _cancelTdlibDownload(id);
      _downloadInFlight.remove(id);
      _downloadBackgroundIds.remove(id);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
    }
  }

  /// Queue one nearby message's light media at open-chat priority (not focus).
  void _enqueueNeighborMedia({
    required int chatId,
    required int messageId,
  }) {
    final list = _messagesByChat[chatId];
    if (list == null) return;
    TdlibMessage? m;
    for (final x in list) {
      if (x.id == messageId) {
        m = x;
        break;
      }
    }
    if (m == null || _photoHasUsablePath(m)) return;
    final ids = <int>[];
    void addId(int? id) {
      if (id == null || id <= 0) return;
      if (_hasCachedPath(id)) return;
      if (ids.contains(id)) return;
      ids.add(id);
    }
    if (m.photoRemoteId != null) {
      addId(m.photoRemoteId);
    } else if (m.photoFallbackFileIds.isNotEmpty) {
      addId(m.photoFallbackFileIds.first);
    }
    addId(m.videoThumbFileId);
    for (final id in ids) {
      if (_downloadInFlight.contains(id) || _downloadQueued.contains(id)) {
        continue;
      }
      _queueFileDownload(
        id,
        priority: prioOpenChatMedia,
        background: false,
        chatId: chatId,
        reason: 'neighbor:$messageId',
      );
    }
  }

  /// Exclusive media focus: download only this message's light media (1 at a time).
  ///
  /// If the user scrolls to another message mid-download, the previous file is
  /// demoted behind the new focus in the queue (not cancelled into the void —
  /// it resumes after the new focus finishes, unless replaced again).
  void focusVisibleMessageMedia({
    required int chatId,
    required int messageId,
    bool force = false,
  }) {
    if (_openChatId != chatId) return;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;

    // Scroll estimate jumps while history fills — hold the current focus until
    // its download finishes or the hold expires (tap uses force: true).
    // Claim is synchronous so concurrent openMessageContent races cannot steal.
    final holdUntil = _focusHoldUntil;
    if (!force &&
        holdUntil != null &&
        DateTime.now().isBefore(holdUntil) &&
        _focusMessageId != null &&
        _focusMessageId != messageId) {
      return;
    }

    var idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;

    // Scroll estimate often lands on a text bubble while a photo is on screen.
    // Prefer the nearest message that actually has downloadable light media.
    if (!_messageHasLightMedia(list[idx])) {
      final found = _nearestLightMediaIndex(list, idx);
      if (found != null) {
        idx = found;
        messageId = list[idx].id;
      }
    }

    // Re-check hold after nearest-media remap.
    if (!force &&
        holdUntil != null &&
        DateTime.now().isBefore(holdUntil) &&
        _focusMessageId != null &&
        _focusMessageId != messageId) {
      return;
    }

    final focus = list[idx];
    final members = <TdlibMessage>[focus];
    final albumId = focus.mediaAlbumId;
    if (albumId != null) {
      for (var i = idx - 1; i >= 0; i--) {
        if (list[i].mediaAlbumId != albumId) break;
        members.insert(0, list[i]);
      }
      for (var i = idx + 1; i < list.length; i++) {
        if (list[i].mediaAlbumId != albumId) break;
        members.add(list[i]);
      }
    }

    // Sync claim before any await — prevents tile/scroll races from enqueueing
    // a second focus while openMessageContent is in flight.
    _focusMessageId = messageId;
    _focusHoldUntil = DateTime.now().add(const Duration(seconds: 4));
    final claimedId = messageId;

    // openMessageContent before downloadFile — channel CDNs often need it.
    // Then re-fetch album members: video thumbnail file ids are frequently
    // missing until content is opened.
    unawaited(() async {
      await _openMessageContent(chatId, claimedId);
      if (_openChatId != chatId) return;
      if (_focusMessageId != claimedId) return;
      final refreshed = await _refreshAlbumMembersForFocus(
        chatId: chatId,
        messageId: claimedId,
        members: members,
      );
      if (_openChatId != chatId) return;
      if (_focusMessageId != claimedId) return;
      _enqueueFocusMedia(
        chatId: chatId,
        messageId: claimedId,
        members: refreshed,
      );
    }());
  }

  /// Re-getMessage for album siblings so video/photo file ids are populated
  /// after [openMessageContent].
  Future<List<TdlibMessage>> _refreshAlbumMembersForFocus({
    required int chatId,
    required int messageId,
    required List<TdlibMessage> members,
  }) async {
    final c = _client;
    if (c == null) return members;
    final needsRefresh = members.any((m) {
      final missingVideoThumb = m.isVideo &&
          (m.videoThumbFileId == null || m.videoThumbFileId! <= 0);
      final missingPhoto = m.isPhoto &&
          (m.photoRemoteId == null || m.photoRemoteId! <= 0);
      // Soft s/m (or unknown) — re-getMessage after openMessageContent so
      // TDLib exposes x/y sizes; otherwise we paint 7KB forever.
      final softPhoto = m.isPhoto &&
          (m.photoSizeType == null ||
              m.photoSizeType == 'm' ||
              m.photoSizeType == 's');
      return missingVideoThumb || missingPhoto || softPhoto;
    });
    if (!needsRefresh) return members;

    // Open each album item (CDN auth) then refresh file ids in parallel.
    await Future.wait([
      for (final m in members) _openMessageContent(chatId, m.id),
    ]);

    final futures = members.map((m) async {
      try {
        final res = await c.sendAwait({
          '@type': 'getMessage',
          'chat_id': chatId,
          'message_id': m.id,
        }, timeout: const Duration(seconds: 6));
        final parsed = _parseMessage(res);
        if (parsed != null) {
          _upsertMessage(parsed);
          return parsed;
        }
      } catch (_) {}
      return m;
    });
    final out = await Future.wait(futures);
    if (out.isNotEmpty) notifyListeners();
    return out;
  }

  void _enqueueFocusMedia({
    required int chatId,
    required int messageId,
    required List<TdlibMessage> members,
  }) {
    final ordered = <int>[];
    void addId(int? id) {
      if (id == null || id <= 0) return;
      if (_hasCachedPath(id)) return;
      if (ordered.contains(id)) return;
      ordered.add(id);
    }

    // Skip messages already sharp in the bubble.
    final need = members.where((m) => !_photoBubbleSharp(m)).toList();
    // Claimed (viewport) message photo first — same id tap uses.
    TdlibMessage? claimed;
    for (final m in members) {
      if (m.id == messageId) {
        claimed = m;
        break;
      }
    }
    claimed ??= members.isNotEmpty ? members.first : null;
    if (claimed != null && !_photoBubbleSharp(claimed)) {
      final soft = claimed.photoSizeType == null ||
          claimed.photoSizeType == 'm' ||
          claimed.photoSizeType == 's';
      if (soft && claimed.photoFallbackFileIds.isNotEmpty) {
        // One upgrade (x) — not y/w flood that starves the slot.
        addId(claimed.photoFallbackFileIds.first);
      } else if (claimed.photoRemoteId != null) {
        addId(claimed.photoRemoteId);
      }
    }
    for (final m in need) {
      if (claimed != null && m.id == claimed.id) continue;
      if (m.isPhoto || m.photoRemoteId != null) {
        final soft = m.photoSizeType == null ||
            m.photoSizeType == 'm' ||
            m.photoSizeType == 's';
        if (soft && m.photoFallbackFileIds.isNotEmpty) {
          addId(m.photoFallbackFileIds.first);
        } else {
          addId(m.photoRemoteId);
        }
      }
    }
    // Always queue thumbs when present (isVideo may be false on stubs).
    // Treat tiny/stale cache entries as missing — minithumb-sized files leave
    // the bubble blurry forever while focus-skip-empty thinks we're done.
    bool thumbNeedsDownload(int? id, String? messagePath) {
      if (id == null || id <= 0) return false;
      final path = (messagePath != null && messagePath.isNotEmpty)
          ? messagePath
          : _filePathCache[id];
      if (path == null || path.isEmpty) return true;
      try {
        final f = File(path);
        if (!f.existsSync()) {
          _filePathCache.remove(id);
          return true;
        }
        // Reject empty/corrupt stubs only. TDLib video thumbs are often
        // 6–15KB and still look far better than minithumb bytes.
        if (f.lengthSync() < 3 * 1024) {
          _filePathCache.remove(id);
          return true;
        }
      } catch (_) {
        _filePathCache.remove(id);
        return true;
      }
      return false;
    }

    for (final m in members) {
      if (thumbNeedsDownload(m.videoThumbFileId, m.videoThumbLocalPath)) {
        final id = m.videoThumbFileId!;
        if (!ordered.contains(id)) ordered.add(id);
      }
      if (thumbNeedsDownload(
        m.videoNoteThumbFileId,
        m.videoNoteThumbLocalPath,
      )) {
        final id = m.videoNoteThumbFileId!;
        if (!ordered.contains(id)) ordered.add(id);
      }
    }
    if (ordered.isEmpty) {
      for (final m in members) {
        addId(m.voiceFileId);
        addId(m.videoNoteFileId);
      }
    }

    if (ordered.isEmpty) {
      final m = members.first;
      final vt = m.videoThumbFileId;
      final cached = vt == null ? null : _filePathCache[vt];
      var cachedLen = -1;
      if (cached != null && cached.isNotEmpty) {
        try {
          cachedLen = File(cached).lengthSync();
        } catch (_) {}
      }
      _mediaLog(
        'focus-skip-empty msg=$messageId '
        'photoId=${m.photoRemoteId} photoPath=${m.photoLocalPath != null} '
        'isPhoto=${m.isPhoto} thumbBytes=${m.photoThumbBytes != null} '
        'fallbacks=${m.photoFallbackFileIds} '
        'vthumb=$vt vpath=${m.videoThumbLocalPath != null} '
        'cachePath=${cached != null} cacheLen=$cachedLen '
        '${_downloadQueueStats()}',
      );
      if ((m.photoThumbBytes != null || m.text == 'Фото') &&
          m.photoRemoteId == null) {
        unawaited(_refetchAndFocusMedia(chatId, messageId));
      }

      // Thumb already on disk but message field not stamped → bind so UI paints.
      // Tiny cached thumbs (<20KB) are minithumb-quality — force re-download.
      var stamped = false;
      for (final mem in members) {
        for (final id in <int?>[
          mem.videoThumbFileId,
          mem.videoNoteThumbFileId,
          mem.photoRemoteId,
          ...mem.photoFallbackFileIds,
        ]) {
          if (id == null || id <= 0) continue;
          final path = _filePathCache[id];
          if (path == null || path.isEmpty) continue;
          var len = -1;
          try {
            len = File(path).lengthSync();
          } catch (_) {}
          if (len >= 0 && len < 3 * 1024) {
            _filePathCache.remove(id);
            if (!ordered.contains(id)) ordered.add(id);
            _mediaLog(
              'focus-requeue-tiny id=$id len=$len msg=$messageId',
            );
            continue;
          }
          if (!_hasCachedPath(id)) continue;
          final patched = _messageWithDownloadedFile(mem, id, path);
          if (patched != null) {
            _upsertMessage(patched);
            stamped = true;
          }
        }
      }
      if (ordered.isNotEmpty) {
        // Fall through to enqueue tiny requeues below.
      } else if (stamped) {
        _mediaLog('focus-bind-cached msg=$messageId');
        notifyListeners();
        return;
      } else {
        // Truly empty stub — jump to nearest pending photo.
        final hasThumbId = members.any(
          (x) =>
              (x.videoThumbFileId != null && x.videoThumbFileId! > 0) ||
              (x.videoNoteThumbFileId != null && x.videoNoteThumbFileId! > 0),
        );
        if (!hasThumbId) {
          final list = _messagesByChat[chatId];
          if (list != null) {
            final idx = list.indexWhere((x) => x.id == messageId);
            final near =
                idx >= 0 ? _nearestPendingPhotoIndex(list, idx) : null;
            if (near != null && list[near].id != messageId) {
              final nm = list[near];
              _mediaLog(
                'focus-redirect empty=$messageId → photo=${nm.id} '
                'photoId=${nm.photoRemoteId}',
              );
              focusVisibleMessageMedia(
                chatId: chatId,
                messageId: nm.id,
                force: true,
              );
              return;
            }
          }
        }
        addId(m.videoThumbFileId);
        addId(m.videoNoteThumbFileId);
        if (ordered.isEmpty) return;
      }
    }

    // Exclusive focus: ONE file at a time. Parallel focus-tail (video thumb /
    // album sibling) competed for the CDN slot and both sat at 0B.
    if (ordered.length > 1) {
      _mediaLog(
        'focus-cap msg=$messageId ${ordered.length}→1 files '
        '(defer ${ordered.sublist(1)})',
      );
      ordered.removeRange(1, ordered.length);
    }

    _mediaLog(
      'focus-enqueue msg=$messageId files=$ordered '
      'type=${members.first.photoSizeType} '
      'fallbacks=${members.first.photoFallbackFileIds}',
    );

    unawaited(
      _applyExclusiveFocusQueue(
        ordered,
        chatId: chatId,
        messageId: messageId,
      ),
    );
  }

  /// Helps TDLib authorize CDN access for channel media (esp. through proxy).
  Future<void> _openMessageContent(int chatId, int messageId) async {
    final c = _client;
    if (c == null || messageId <= 0) return;
    try {
      await c.sendAwait({
        '@type': 'openMessageContent',
        'chat_id': chatId,
        'message_id': messageId,
      }, timeout: const Duration(seconds: 5));
    } catch (_) {
      // Non-fatal — download may still work without it.
    }
  }

  Future<void> _openMessageContentForFile(int chatId, int fileId) async {
    final list = _messagesByChat[chatId];
    if (list == null) return;
    for (final m in list) {
      if (m.videoFileId == fileId ||
          m.videoNoteFileId == fileId ||
          m.photoRemoteId == fileId ||
          m.photoFallbackFileIds.contains(fileId)) {
        await _openMessageContent(chatId, m.id);
        return;
      }
    }
  }

  /// Queue a full video for auto-download (settings-driven). Does not wait.
  /// Must not use [background]:true — open-chat mode drops background jobs.
  void queueAutoVideoDownload({
    required int fileId,
    required int chatId,
  }) {
    if (fileId <= 0) return;
    if (_hasCachedPath(fileId)) return;
    if (_downloadQueued.contains(fileId) || _downloadInFlight.contains(fileId)) {
      return;
    }
    _queueFileDownload(
      fileId,
      priority: prioOpenChatMedia,
      background: false,
      chatId: chatId,
      reason: 'auto:video:$fileId',
    );
  }

  /// Re-pull one message from TDLib when we saw a photo stub without file id.
  Future<void> _refetchAndFocusMedia(int chatId, int messageId) async {
    final c = _client;
    if (c == null) return;
    try {
      final res = await c.sendAwait({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      }, timeout: const Duration(seconds: 8));
      final msg = _parseMessage(res);
      if (msg == null) return;
      _upsertMessage(msg);
      _mediaLog(
        'refetch-msg=$messageId photoId=${msg.photoRemoteId} '
        'isPhoto=${msg.isPhoto} path=${msg.photoLocalPath != null}',
      );
      if (_messageHasLightMedia(msg)) {
        focusVisibleMessageMedia(chatId: chatId, messageId: messageId);
        notifyListeners();
      }
    } catch (e) {
      _mediaLog('refetch-msg fail id=$messageId err=$e');
    }
  }

  bool _messageHasLightMedia(TdlibMessage m) {
    // Nearest-media walk: photos or video thumbs that still need a file.
    if (m.photoRemoteId != null &&
        m.photoRemoteId! > 0 &&
        !_photoBubbleSharp(m)) {
      return true;
    }
    final vt = m.videoThumbFileId;
    if (vt != null && vt > 0 && !_hasCachedPath(vt)) return true;
    return false;
  }

  bool _photoHasUsablePath(TdlibMessage m) {
    if (m.photoLocalPath != null && m.photoLocalPath!.isNotEmpty) {
      // Soft s/m still counts as "has bytes to paint", but focus must upgrade.
      return true;
    }
    final primary = m.photoRemoteId;
    if (primary != null && _hasCachedPath(primary)) return true;
    for (final id in m.photoFallbackFileIds) {
      if (_hasCachedPath(id)) return true;
    }
    return false;
  }

  /// Sharp enough for a chat bubble — soft s/m alone is not.
  bool _photoBubbleSharp(TdlibMessage m) {
    if (!_photoHasUsablePath(m)) return false;
    final type = m.photoSizeType;
    if (type == 'x' || type == 'y' || type == 'w') return true;
    // Soft/unknown type: accept only if the on-disk file is already large
    // (upgrade stamped onto photoLocalPath).
    final path = m.photoLocalPath ??
        (m.photoRemoteId != null ? _filePathCache[m.photoRemoteId!] : null);
    if (path != null && path.isNotEmpty) {
      try {
        if (File(path).lengthSync() >= 30 * 1024) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Public for viewport prefetch — soft local path still needs upgrade.
  bool photoNeedsFocusDownload(TdlibMessage m) {
    if (m.photoRemoteId == null || m.photoRemoteId! <= 0) return false;
    return !_photoBubbleSharp(m);
  }

  int? _nearestLightMediaIndex(List<TdlibMessage> list, int from) {
    // Coarse viewport estimate (~160px/row) — look nearby only. Full-list
    // walks jumped focus across the channel and cancelled every download.
    const maxDist = 6;
    final limit = maxDist < list.length ? maxDist : list.length;
    for (var dist = 1; dist <= limit; dist++) {
      final lo = from - dist;
      if (lo >= 0 && _messageHasLightMedia(list[lo])) return lo;
      final hi = from + dist;
      if (hi < list.length && _messageHasLightMedia(list[hi])) return hi;
    }
    return null;
  }

  int? _nearestPendingPhotoIndex(List<TdlibMessage> list, int from) {
    const maxDist = 8;
    final limit = maxDist < list.length ? maxDist : list.length;
    for (var dist = 1; dist <= limit; dist++) {
      final lo = from - dist;
      if (lo >= 0 && photoNeedsFocusDownload(list[lo])) return lo;
      final hi = from + dist;
      if (hi < list.length && photoNeedsFocusDownload(list[hi])) return hi;
    }
    return null;
  }

  /// After history lands, focus the newest message that still needs media.
  void focusNewestPendingMedia(int chatId) {
    if (_openChatId != chatId) return;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    for (var i = list.length - 1; i >= 0; i--) {
      if (_messageHasLightMedia(list[i])) {
        focusVisibleMessageMedia(chatId: chatId, messageId: list[i].id);
        return;
      }
    }
  }

  Future<void> _applyExclusiveFocusQueue(
    List<int> ordered, {
    required int chatId,
    required int messageId,
  }) async {
    final sameFocus = _focusMessageId == messageId &&
        ordered.length == _focusDownloadOrder.length &&
        ordered.asMap().entries.every(
              (e) => e.value == _focusDownloadOrder[e.key],
            );
    if (sameFocus) {
      _pumpDownloadQueue();
      return;
    }

    final previousOrder = List<int>.from(_focusDownloadOrder);
    _focusMessageId = messageId;
    _focusDownloadOrder = List<int>.from(ordered);
    _focusHoldUntil = DateTime.now().add(const Duration(seconds: 4));

    _mediaLog(
      'focus-msg=$messageId files=${ordered.isEmpty ? '[]' : ordered} '
      'prev=${previousOrder.isEmpty ? '[]' : previousOrder} '
      '${_downloadQueueStats()}',
    );

    final want = ordered.toSet();

    // Drop queued jobs that aren't the new focus. Neighbors are re-flushed
    // after focus claims slots — keeping them queued let them pump first
    // when slots free mid-await.
    final dropped = _downloadQueue
        .where(
          (j) =>
              !want.contains(j.fileId) &&
              j.reason != 'ensure' &&
              !j.reason.startsWith('tap:'),
        )
        .toList();
    for (final j in dropped) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
    }

    // Demote previous-focus queued (not in-flight) behind the new focus.
    for (final id in previousOrder) {
      if (want.contains(id) || _hasCachedPath(id)) continue;
      if (_downloadInFlight.contains(id)) continue;
      final idx = _downloadQueue.indexWhere((j) => j.fileId == id);
      if (idx >= 0) {
        _downloadQueue[idx].priority = prioOpenChatMedia;
        _downloadQueue[idx].reason = 'demoted-after-focus:$messageId';
      }
    }

    // Enqueue focus order: head = prioFocused, rest slightly lower.
    unawaited(_purgeAvatarDownloads());
    await _yieldSlotsToFocus(want);
    for (var i = 0; i < ordered.length; i++) {
      final id = ordered[i];
      final priority = (prioFocused - i).clamp(1, 32);
      if (_downloadInFlight.contains(id)) {
        final t = _downloadTrace[id];
        if (t != null) {
          t.priority = priority;
          t.reason = 'focus:$messageId';
        }
        continue;
      }
      _queueFileDownload(
        id,
        priority: priority,
        background: false,
        chatId: chatId,
        reason: i == 0 ? 'focus:$messageId' : 'focus-tail:$messageId#$i',
      );
    }

    _pumpDownloadQueue();
    // Neighbors only after the focus head is local / finished — otherwise
    // they queue behind and still compete on the next free slot.
    final focusHeadDone = ordered.isEmpty || _hasCachedPath(ordered.first);
    if (focusHeadDone) {
      _flushPendingNeighbors(chatId);
    }
    notifyListeners();
  }

  /// Load older messages (scroll-up). Returns how many new messages were added.
  Future<int> loadOlderMessages(int chatId, {int pageSize = 50}) async {
    final c = _client;
    if (c == null || !isReady) return 0;
    final existing = _messagesByChat[chatId] ?? const <TdlibMessage>[];
    if (existing.isEmpty) {
      await _loadChatHistory(chatId);
      return _messagesByChat[chatId]?.length ?? 0;
    }
    final isChannel = isChannelChat(chatId);
    final onlyLocal = !_tdlibReadyForMedia;
    final oldestId = existing.first.id;
    final beforeIds = {for (final m in existing) m.id};
    final retries = onlyLocal ? 2 : (isChannel ? 8 : 1);
    var added = 0;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final res = await c.sendAwait({
          '@type': 'getChatHistory',
          'chat_id': chatId,
          'from_message_id': oldestId,
          'offset': 0,
          'limit': pageSize,
          'only_local': onlyLocal,
        }, timeout: Duration(
          seconds: onlyLocal ? 8 : (isChannel ? 45 : 30),
        ));
        if (res['@type'] != 'messages') return added;
        final list = res['messages'];
        if (list is! List || list.isEmpty) {
          if (attempt + 1 >= retries) break;
          await Future<void>.delayed(
            Duration(milliseconds: 280 + attempt * 120),
          );
          continue;
        }
        final before = _messagesByChat[chatId]?.length ?? 0;
        final newly = <TdlibMessage>[];
        for (final raw in list) {
          if (raw is! Map) continue;
          final map = raw is Map<String, dynamic>
              ? raw
              : Map<String, dynamic>.from(raw);
          map.putIfAbsent('chat_id', () => chatId);
          final msg = _parseMessage(map);
          if (msg == null) continue;
          _upsertMessage(msg);
          if (!beforeIds.contains(msg.id)) newly.add(msg);
        }
        // Scroll-up: no bulk download — exclusive focus handles visible media.
        notifyListeners();
        added = (_messagesByChat[chatId]?.length ?? 0) - before;
        if (added > 0 || newly.isNotEmpty) return newly.isNotEmpty ? newly.length : added;
        if (attempt + 1 >= retries) break;
        await Future<void>.delayed(
          Duration(milliseconds: 280 + attempt * 120),
        );
      } catch (e) {
        debugPrint('[tdlib] loadOlderMessages failed: $e');
        if (attempt + 1 >= retries) break;
        await Future<void>.delayed(
          Duration(milliseconds: 280 + attempt * 120),
        );
      }
    }
    return added;
  }

  void _upsertMessage(TdlibMessage msg) {
    final list = _messagesByChat.putIfAbsent(msg.chatId, () => []);
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      list[idx] = msg;
    } else {
      list.add(msg);
      list.sort((a, b) => a.id.compareTo(b.id));
    }
  }

  void _replaceMessageId({
    required int chatId,
    required int oldId,
    required TdlibMessage msg,
  }) {
    final list = _messagesByChat.putIfAbsent(chatId, () => []);
    list.removeWhere((m) => m.id == oldId || m.id == msg.id);
    list.add(msg);
    list.sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> closeChat(int chatId) async {
    final c = _client;
    if (c == null) return;
    if (_openChatId == chatId) {
      _openChatId = null;
      // Resume background jobs that were waiting; rebuild hub so avatars re-queue.
      _pumpDownloadQueue();
      // Never notify synchronously from a widget dispose path.
      scheduleMicrotask(() {
        notifyListeners();
      });
      unawaited(_warmRecentHubMedia());
    }
    try {
      await c.sendAwait({'@type': 'closeChat', 'chat_id': chatId});
    } catch (_) {}
  }

  Future<void> sendText(
    int chatId,
    String text, {
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null || text.trim().isEmpty) return;
    final res = await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': text.trim(),
        },
      },
    });
    if (res['@type'] == 'message') {
      final msg = _parseMessage(res);
      if (msg != null) {
        _upsertMessage(msg);
        notifyListeners();
      }
    }
  }

  /// Create a basic Telegram group and invite [userIds] (excluding self).
  ///
  /// Returns the new chat id, or null on failure.
  Future<int?> createBasicGroupChat({
    required String title,
    required List<int> userIds,
  }) async {
    final c = _client;
    if (c == null || !isReady) return null;
    final name = title.trim();
    if (name.isEmpty) return null;
    final myId = _myUserId;
    final ids = <int>{
      for (final id in userIds)
        if (id > 0 && id != myId) id,
    };
    // Ensure private chats exist so invites are allowed.
    for (final uid in ids) {
      try {
        await c.sendAwait({
          '@type': 'createPrivateChat',
          'user_id': uid,
          'force': true,
        }, timeout: const Duration(seconds: 15));
      } catch (e) {
        debugPrint('[tdlib] createPrivateChat($uid) before group: $e');
      }
    }
    try {
      final res = await c.sendAwait({
        '@type': 'createNewBasicGroupChat',
        'user_ids': ids.toList(),
        'title': name,
        'message_auto_delete_time': 0,
      }, timeout: const Duration(seconds: 30));
      final chatId = (res['id'] as num?)?.toInt() ??
          (res['chat_id'] as num?)?.toInt();
      if (chatId != null && chatId != 0) {
        debugPrint('[tdlib] created basic group chat_id=$chatId');
        return chatId;
      }
      // Some TDLib builds wrap as { "@type": "chat", ... }.
      if (res['@type'] == 'chat') {
        final id = (res['id'] as num?)?.toInt();
        if (id != null && id != 0) return id;
      }
      debugPrint('[tdlib] createNewBasicGroupChat unexpected: $res');
      return null;
    } catch (e) {
      debugPrint('[tdlib] createNewBasicGroupChat failed: $e');
      return null;
    }
  }

  /// Returns the new message id when available (for outbound map).
  Future<int?> sendTextReturningId(
    int chatId,
    String text, {
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null || text.trim().isEmpty) return null;
    final res = await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': text.trim(),
        },
      },
    });
    if (res['@type'] == 'message') {
      final msg = _parseMessage(res);
      if (msg != null) {
        _upsertMessage(msg);
        notifyListeners();
        return msg.id;
      }
    }
    return (res['id'] as num?)?.toInt();
  }

  Future<void> sendPhoto(
    int chatId,
    String localPath, {
    String caption = '',
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessagePhoto',
        'photo': {
          '@type': 'inputFileLocal',
          'path': localPath,
        },
        if (caption.isNotEmpty)
          'caption': {
            '@type': 'formattedText',
            'text': caption,
          },
      },
    });
  }

  Future<void> sendVideo(
    int chatId,
    String localPath, {
    String caption = '',
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageVideo',
        'video': {
          '@type': 'inputFileLocal',
          'path': localPath,
        },
        if (caption.isNotEmpty)
          'caption': {
            '@type': 'formattedText',
            'text': caption,
          },
      },
    });
  }

  Future<void> sendDocument(
    int chatId,
    String localPath, {
    String caption = '',
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageDocument',
        'document': {
          '@type': 'inputFileLocal',
          'path': localPath,
        },
        if (caption.isNotEmpty)
          'caption': {
            '@type': 'formattedText',
            'text': caption,
          },
      },
    });
  }

  Future<void> sendVideoNote(
    int chatId,
    String localPath, {
    int durationMs = 0,
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null) return;
    final durationSec = (durationMs / 1000).round().clamp(1, 60);
    await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageVideoNote',
        'video_note': {
          '@type': 'inputFileLocal',
          'path': localPath,
        },
        'duration': durationSec,
        'length': 384,
      },
    });
  }

  Future<void> sendVoiceNote(
    int chatId,
    String localPath, {
    int durationMs = 0,
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null) return;
    final durationSec = (durationMs / 1000).round().clamp(1, 3600);
    await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageVoiceNote',
        'voice_note': {
          '@type': 'inputFileLocal',
          'path': localPath,
        },
        'duration': durationSec,
      },
    });
  }

  Future<void> sendLocation(
    int chatId, {
    required double latitude,
    required double longitude,
    double? horizontalAccuracy,
    int? replyToMessageId,
  }) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyToMessageId != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyToMessageId,
        },
      'input_message_content': {
        '@type': 'inputMessageLocation',
        'location': {
          '@type': 'location',
          'latitude': latitude,
          'longitude': longitude,
          if (horizontalAccuracy != null)
            'horizontal_accuracy': horizontalAccuracy,
        },
      },
    });
  }

  /// Persist bytes to a temp file for TDLib inputFileLocal.
  Future<String> materializeTempFile({
    required List<int> bytes,
    required String filename,
  }) async {
    final dir = await getTemporaryDirectory();
    final safe = filename.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final file = File(
      p.join(
        dir.path,
        'tdlib_upload_${DateTime.now().microsecondsSinceEpoch}_$safe',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> editMessageText(
    int chatId,
    int messageId,
    String text,
  ) async {
    final c = _client;
    if (c == null || text.trim().isEmpty) return;
    await c.sendAwait({
      '@type': 'editMessageText',
      'chat_id': chatId,
      'message_id': messageId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': text.trim(),
        },
      },
    });
  }

  Future<void> deleteMessages(
    int chatId,
    List<int> messageIds, {
    bool revoke = false,
  }) async {
    final c = _client;
    if (c == null || messageIds.isEmpty) return;
    await c.sendAwait({
      '@type': 'deleteMessages',
      'chat_id': chatId,
      'message_ids': messageIds,
      'revoke': revoke,
    });
    final list = _messagesByChat[chatId];
    if (list != null) {
      list.removeWhere((m) => messageIds.contains(m.id));
      notifyListeners();
    }
  }

  Future<void> forwardMessages({
    required int fromChatId,
    required List<int> messageIds,
    required int toChatId,
  }) async {
    final c = _client;
    if (c == null || messageIds.isEmpty) return;
    await c.sendAwait({
      '@type': 'forwardMessages',
      'chat_id': toChatId,
      'from_chat_id': fromChatId,
      'message_ids': messageIds,
      'send_copy': false,
      'remove_caption': false,
    });
  }

  Future<void> pinMessage(int chatId, int messageId) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'pinChatMessage',
      'chat_id': chatId,
      'message_id': messageId,
      'disable_notification': false,
      'only_for_self': false,
    });
    _pinnedMessageId[chatId] = messageId;
    notifyListeners();
  }

  Future<void> unpinMessage(int chatId, {int? messageId}) async {
    final c = _client;
    if (c == null) return;
    if (messageId != null) {
      await c.sendAwait({
        '@type': 'unpinChatMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
    } else {
      await c.sendAwait({
        '@type': 'unpinAllChatMessages',
        'chat_id': chatId,
      });
    }
    if (_pinnedMessageId[chatId] == messageId || messageId == null) {
      _pinnedMessageId.remove(chatId);
    }
    notifyListeners();
  }

  Future<void> setChatMuted(int chatId, {required bool muted}) async {
    final c = _client;
    if (c == null) return;
    await c.sendAwait({
      '@type': 'setChatNotificationSettings',
      'chat_id': chatId,
      'notification_settings': {
        '@type': 'chatNotificationSettings',
        'use_default_mute_for': false,
        'mute_for': muted ? 366 * 24 * 3600 : 0,
        'use_default_sound': true,
        'use_default_show_preview': true,
        'use_default_mute_stories': true,
        'use_default_story_sound': true,
        'use_default_show_story_poster': true,
        'use_default_disable_pinned_message_notifications': true,
        'use_default_disable_mention_notifications': true,
      },
    });
  }

  /// Refresh cached FC↔TG matches used to dedupe unread badges.
  Future<void> refreshMatchedTgUserIds() async {
    try {
      final all = await TelegramMatchStore.instance.loadAll();
      _matchedTgUserIds
        ..clear()
        ..addAll(all.keys);
      for (final m in all.values) {
        if (m.tgUserId > 0) _matchedTgUserIds.add(m.tgUserId);
        if (m.tgChatId != 0) _matchedTgUserIds.add(m.tgChatId);
      }
    } catch (e) {
      debugPrint('[tdlib] refreshMatchedTgUserIds failed: $e');
    }
  }

  Future<void> _loadScopeNotificationSettings() async {
    final c = _client;
    if (c == null || !isReady) return;
    const scopes = <String>[
      'notificationSettingsScopePrivateChats',
      'notificationSettingsScopeGroupChats',
      'notificationSettingsScopeChannelChats',
    ];
    for (final scope in scopes) {
      try {
        final res = await c.sendAwait({
          '@type': 'getScopeNotificationSettings',
          'scope': {'@type': scope},
        });
        if (res['@type']?.toString() == 'scopeNotificationSettings') {
          _scopeNotificationSettings[scope] = Map<String, dynamic>.from(res);
        }
      } catch (e) {
        debugPrint('[tdlib] getScopeNotificationSettings($scope): $e');
      }
    }
  }

  String? _scopeTypeForChat(int chatId) {
    final type = _chats[chatId]?['type'];
    if (type is! Map) return null;
    final name = type['@type']?.toString() ?? '';
    if (name == 'chatTypePrivate' || name == 'chatTypeSecret') {
      return 'notificationSettingsScopePrivateChats';
    }
    if (name == 'chatTypeBasicGroup') {
      return 'notificationSettingsScopeGroupChats';
    }
    if (name == 'chatTypeSupergroup') {
      return type['is_channel'] == true
          ? 'notificationSettingsScopeChannelChats'
          : 'notificationSettingsScopeGroupChats';
    }
    return null;
  }

  bool isChatMuted(int chatId) {
    final chat = _chats[chatId];
    final settings = chat?['notification_settings'];
    if (settings is! Map) return false;
    // When the chat uses scope defaults, chat.mute_for is ignored (often 0)
    // even though the channel/group scope is muted — that made muted rows
    // look "active" (blue badge) and still contribute to folder totals.
    if (settings['use_default_mute_for'] == true) {
      final scopeType = _scopeTypeForChat(chatId);
      final scope =
          scopeType == null ? null : _scopeNotificationSettings[scopeType];
      if (scope != null) {
        final scopeMute = (scope['mute_for'] as num?)?.toInt() ?? 0;
        return scopeMute > 0;
      }
    }
    final muteFor = (settings['mute_for'] as num?)?.toInt() ?? 0;
    return muteFor > 0;
  }

  /// Media / link search for profile sheet tabs.
  Future<List<TdlibMessage>> searchChatMedia(int chatId, {int limit = 60}) async {
    final c = _client;
    if (c == null || !isReady) return const [];
    try {
      final res = await c.sendAwait({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': '',
        'from_message_id': 0,
        'offset': 0,
        'limit': limit.clamp(1, 100),
        'filter': {'@type': 'searchMessagesFilterPhotoAndVideo'},
      });
      final parsed = _parseMessagesList(res);
      // Warm thumbs so the grid isn't empty gray tiles.
      for (final m in parsed) {
        final photoId = m.photoRemoteId;
        if (photoId != null && !_filePathCache.containsKey(photoId)) {
          _queueFileDownload(
            photoId,
            priority: prioBackground,
            background: true,
            chatId: chatId,
            reason: 'sheet-media',
          );
        }
        final thumbId = m.videoThumbFileId;
        if (thumbId != null && !_filePathCache.containsKey(thumbId)) {
          _queueFileDownload(
            thumbId,
            priority: prioBackground,
            background: true,
            chatId: chatId,
            reason: 'sheet-media-thumb',
          );
        }
      }
      return parsed;
    } catch (e) {
      debugPrint('[tdlib] searchChatMedia($chatId): $e');
      return const [];
    }
  }

  Future<List<({int messageId, String url})>> searchChatLinks(
    int chatId, {
    int limit = 60,
  }) async {
    final c = _client;
    if (c == null || !isReady) return const [];
    try {
      final res = await c.sendAwait({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': '',
        'from_message_id': 0,
        'offset': 0,
        'limit': limit.clamp(1, 100),
        'filter': {'@type': 'searchMessagesFilterUrl'},
      });
      final out = <({int messageId, String url})>[];
      final seen = <String>{};
      for (final m in _parseMessagesList(res)) {
        for (final url in _urlsFromMessage(m)) {
          if (!seen.add(url)) continue;
          out.add((messageId: m.id, url: url));
        }
      }
      return out;
    } catch (e) {
      debugPrint('[tdlib] searchChatLinks($chatId): $e');
      return const [];
    }
  }

  List<String> _urlsFromMessage(TdlibMessage m) {
    final urls = <String>[];
    for (final e in m.textEntities) {
      final u = e['url']?.toString().trim() ?? '';
      if (u.startsWith('http://') || u.startsWith('https://')) {
        urls.add(u);
      }
    }
    final matches = RegExp(
      r'(?:https?:\/\/|www\.)[^\s<>"{}|\\^`\[\]]+',
      caseSensitive: false,
    ).allMatches(m.text);
    for (final match in matches) {
      var u = match.group(0)!;
      while (u.isNotEmpty && ')]}>.,;:!?»"\''.contains(u[u.length - 1])) {
        u = u.substring(0, u.length - 1);
      }
      if (u.startsWith('www.')) u = 'https://$u';
      if (u.startsWith('http://') || u.startsWith('https://')) {
        urls.add(u);
      }
    }
    return urls;
  }

  List<TdlibMessage> _parseMessagesList(Map<String, dynamic> res) {
    final type = res['@type']?.toString() ?? '';
    if (type != 'foundMessages' &&
        type != 'foundChatMessages' &&
        type != 'messages') {
      return const [];
    }
    final list = res['messages'];
    if (list is! List) return const [];
    final parsed = <TdlibMessage>[];
    for (final m in list) {
      if (m is Map<String, dynamic>) {
        final msg = _parseMessage(m);
        if (msg != null) parsed.add(msg);
      } else if (m is Map) {
        final msg = _parseMessage(Map<String, dynamic>.from(m));
        if (msg != null) parsed.add(msg);
      }
    }
    return parsed;
  }

  Future<void> toggleReaction({
    required int chatId,
    required int messageId,
    required String emoji,
    required bool add,
  }) async {
    final c = _client;
    if (c == null) return;
    if (add) {
      await c.sendAwait({
        '@type': 'addMessageReaction',
        'chat_id': chatId,
        'message_id': messageId,
        'reaction': {
          '@type': 'reactionTypeEmoji',
          'emoji': emoji,
        },
        'is_big': false,
        'update_recent_reactions': true,
      });
    } else {
      await c.sendAwait({
        '@type': 'removeMessageReaction',
        'chat_id': chatId,
        'message_id': messageId,
        'reaction': {
          '@type': 'reactionTypeEmoji',
          'emoji': emoji,
        },
      });
    }
  }

  /// Fire-and-forget async download (UI rebuilds on [updateFile]).
  ///
  /// [priority] — TDLib 1..32 (**higher** = more urgent). Prefer [prioFocused]
  /// for on-screen / tapped media, [prioOpenChat] for the open chat,
  /// [prioBackground] for hub warm / avatars.
  void requestFileDownload(
    int fileId, {
    int priority = prioOpenChat,
    bool background = false,
    int? chatId,
    String reason = 'ui',
  }) {
    _queueFileDownload(
      fileId,
      priority: priority,
      background: background,
      chatId: chatId,
      reason: reason,
    );
  }

  /// User tapped play/photo — cancel autofocus work and give them the slot.
  Future<void> preemptForUserTap({
    required int fileId,
    required int chatId,
    required String reason,
  }) async {
    if (fileId <= 0) return;
    _focusHoldUntil = null;
    _pendingNeighborMessageIds = const [];

    // Channel videos often need openMessageContent or CDN never unlocks.
    if (reason.contains('video:')) {
      await _openMessageContentForFile(chatId, fileId);
    }

    // Drop queued autofocus / neighbor jobs.
    final drop = _downloadQueue
        .where((j) =>
            j.fileId != fileId &&
            (j.reason.startsWith('focus:') ||
                j.reason.startsWith('focus-tail:') ||
                j.reason.startsWith('focus-upgrade:') ||
                j.reason.startsWith('neighbor:') ||
                j.reason.startsWith('auto:video:') ||
                j.reason.startsWith('stall-fallback:') ||
                j.reason.startsWith('demoted-after-focus')))
        .toList();
    for (final j in drop) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }

    // Cancel in-flight autofocus at 0B (or any non-tap) to free the slot.
    final blockers = <int>[];
    for (final id in _downloadInFlight.toList()) {
      if (id == fileId) continue;
      final t = _downloadTrace[id];
      final r = t?.reason ?? '';
      if (r.startsWith('tap:')) continue;
      blockers.add(id);
    }
    if (blockers.isNotEmpty || drop.isNotEmpty) {
      _mediaLog(
        'preempt-tap file=$fileId cancel=${blockers.join(",")} '
        'dropQ=${drop.map((j) => j.fileId).join(",")} '
        'reason=$reason',
      );
    }
    for (final id in blockers) {
      await _cancelTdlibDownload(id);
      _downloadInFlight.remove(id);
      _downloadBackgroundIds.remove(id);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
    }

    _queueFileDownload(
      fileId,
      priority: prioFocused,
      background: false,
      chatId: chatId,
      reason: reason,
    );
    _pumpDownloadQueue();
    notifyListeners();
  }

  Future<String?> downloadFile(int fileId, {int priority = prioFocused}) async {
    return ensureFileLocal(fileId, priority: priority);
  }

  /// Wait until file is local (via async download + [updateFile]), or null.
  Future<String?> ensureFileLocal(
    int fileId, {
    int priority = prioFocused,
    Duration waitFor = const Duration(seconds: 120),
    String reason = 'ensure',
  }) async {
    if (fileId <= 0) return null;
    final cached = _filePathCache[fileId];
    if (cached != null && cached.isNotEmpty) {
      _mediaLog('ensure-hit-ram file=$fileId reason=$reason');
      return cached;
    }

    final existing = _downloadWaiters[fileId];
    if (existing != null) {
      _mediaLog(
        'ensure-wait-existing file=$fileId reason=$reason '
        'timeout=${waitFor.inSeconds}s ${_downloadQueueStats()}',
      );
      try {
        return await existing.future.timeout(
          waitFor,
          onTimeout: () {
            _mediaLog('ensure-timeout file=$fileId reason=$reason');
            return _filePathCache[fileId];
          },
        );
      } catch (_) {
        return _filePathCache[fileId];
      }
    }

    final completer = Completer<String?>();
    _downloadWaiters[fileId] = completer;
    _mediaLog(
      'ensure-queue file=$fileId reason=$reason prio=$priority '
      'timeout=${waitFor.inSeconds}s ${_downloadQueueStats()}',
    );
    _queueFileDownload(
      fileId,
      priority: priority,
      background: false,
      chatId: _openChatId,
      reason: reason,
    );
    try {
      return await completer.future.timeout(
        waitFor,
        onTimeout: () {
          _mediaLog('ensure-timeout file=$fileId reason=$reason');
          return _filePathCache[fileId];
        },
      );
    } catch (e) {
      _mediaLog('ensure-error file=$fileId reason=$reason err=$e');
      debugPrint('[tdlib] ensureFileLocal($fileId): $e');
      return _filePathCache[fileId];
    } finally {
      final w = _downloadWaiters[fileId];
      if (identical(w, completer)) {
        _downloadWaiters.remove(fileId);
        if (!completer.isCompleted) completer.complete(_filePathCache[fileId]);
      }
    }
  }

  /// Profile for the TG user sheet (name, @username, phone, bio, status, avatar).
  Future<TdlibUserProfile?> loadUserProfile(int userId) async {
    final c = _client;
    if (c == null || userId <= 0) return null;
    Map<String, dynamic>? user = _users[userId];
    try {
      final res = await c.sendAwait({
        '@type': 'getUser',
        'user_id': userId,
      });
      if (res['@type'] == 'user') {
        user = Map<String, dynamic>.from(res);
        _users[userId] = user;
      }
    } catch (e) {
      debugPrint('[tdlib] getUser failed: $e');
    }
    if (user == null) return null;

    String bio = '';
    try {
      final full = await c.sendAwait({
        '@type': 'getUserFullInfo',
        'user_id': userId,
      });
      if (full['@type'] == 'userFullInfo') {
        final b = full['bio'];
        if (b is Map) {
          bio = b['text']?.toString() ?? '';
        } else {
          bio = full['bio']?.toString() ?? '';
        }
      }
    } catch (e) {
      debugPrint('[tdlib] getUserFullInfo failed: $e');
    }

    final first = user['first_name']?.toString() ?? '';
    final last = user['last_name']?.toString() ?? '';
    final display = ('$first $last').trim().isEmpty
        ? (user['usernames'] is Map
            ? ((user['usernames'] as Map)['editable_username']?.toString() ??
                'Telegram')
            : 'Telegram')
        : ('$first $last').trim();

    String username = '';
    final usernames = user['usernames'];
    if (usernames is Map) {
      username = usernames['editable_username']?.toString() ?? '';
      if (username.isEmpty) {
        final active = usernames['active_usernames'];
        if (active is List && active.isNotEmpty) {
          username = active.first.toString();
        }
      }
    } else {
      username = user['username']?.toString() ?? '';
    }

    final photoId = _resolveUserAvatarFileId(user);
    String? avatarPath;
    if (photoId != null) {
      avatarPath = await ensureFileLocal(photoId);
    }

    return TdlibUserProfile(
      userId: userId,
      displayName: display,
      username: username,
      phoneNumber: user['phone_number']?.toString() ?? '',
      bio: bio,
      statusText: _formatUserStatus(user['status']),
      avatarLocalPath: avatarPath,
      avatarFileId: photoId,
    );
  }

  /// Channel / group profile for the app-bar avatar sheet.
  Future<TdlibChatProfile?> loadChatProfile(int chatId) async {
    final c = _client;
    if (c == null || chatId == 0) return null;
    Map<String, dynamic>? chat = _chats[chatId];
    try {
      final res = await c.sendAwait({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      if (res['@type'] == 'chat') {
        chat = Map<String, dynamic>.from(res);
        _chats[chatId] = chat;
      }
    } catch (e) {
      debugPrint('[tdlib] getChat($chatId) profile: $e');
    }
    if (chat == null) return null;

    final type = chat['type'];
    if (type is! Map) return null;
    final typeName = type['@type']?.toString() ?? '';
    final isChannel =
        typeName == 'chatTypeSupergroup' && type['is_channel'] == true;
    final isGroup = typeName == 'chatTypeBasicGroup' ||
        (typeName == 'chatTypeSupergroup' && !isChannel);
    if (!isChannel && !isGroup) return null;

    var memberCount = 0;
    var description = '';
    var inviteLink = '';
    var linkedChatId = 0;
    var username = '';

    if (typeName == 'chatTypeSupergroup') {
      final sgId = _tdlibInt(type['supergroup_id']);
      if (sgId > 0) {
        try {
          final sg = await c.sendAwait({
            '@type': 'getSupergroup',
            'supergroup_id': sgId,
          });
          if (sg['@type'] == 'supergroup') {
            _supergroups[sgId] = Map<String, dynamic>.from(sg);
            memberCount = _tdlibInt(sg['member_count']);
            final usernames = sg['usernames'];
            if (usernames is Map) {
              username = usernames['editable_username']?.toString() ?? '';
              if (username.isEmpty) {
                final active = usernames['active_usernames'];
                if (active is List && active.isNotEmpty) {
                  username = active.first.toString();
                }
              }
            } else {
              username = sg['username']?.toString() ?? '';
            }
          }
        } catch (e) {
          debugPrint('[tdlib] getSupergroup profile: $e');
        }
        try {
          final full = await c.sendAwait({
            '@type': 'getSupergroupFullInfo',
            'supergroup_id': sgId,
          });
          if (full['@type'] == 'supergroupFullInfo') {
            if (memberCount <= 0) {
              memberCount = _tdlibInt(full['member_count']);
            }
            description = full['description']?.toString() ?? '';
            inviteLink = full['invite_link']?.toString() ?? '';
            linkedChatId = _tdlibInt(full['linked_chat_id']);
          }
        } catch (e) {
          debugPrint('[tdlib] getSupergroupFullInfo: $e');
        }
      }
    } else if (typeName == 'chatTypeBasicGroup') {
      final bgId = _tdlibInt(type['basic_group_id']);
      if (bgId > 0) {
        try {
          final full = await c.sendAwait({
            '@type': 'getBasicGroupFullInfo',
            'basic_group_id': bgId,
          });
          if (full['@type'] == 'basicGroupFullInfo') {
            final members = full['members'];
            if (members is List) memberCount = members.length;
            description = full['description']?.toString() ?? '';
            inviteLink = full['invite_link']?.toString() ?? '';
          }
        } catch (e) {
          debugPrint('[tdlib] getBasicGroupFullInfo: $e');
        }
      }
    }

    // Prefer big avatar for the sheet header.
    final photoId = _tdlibPhotoFileId(chat['photo'], 'big') ??
        _resolveChatAvatarFileId(chat);
    String? avatarPath;
    if (photoId != null) {
      avatarPath = await ensureFileLocal(photoId);
    }

    return TdlibChatProfile(
      chatId: chatId,
      title: _chatTitle(chat, null),
      isChannel: isChannel,
      memberCount: memberCount,
      username: username,
      description: description,
      inviteLink: inviteLink,
      linkedChatId: linkedChatId,
      avatarLocalPath: avatarPath,
      avatarFileId: photoId,
      avatarMinithumbnailBytes: _photoMinithumbnailBytes(chat),
    );
  }

  Future<void> leaveChat(int chatId) async {
    final c = _client;
    if (c == null || chatId == 0) return;
    await c.sendAwait({
      '@type': 'leaveChat',
      'chat_id': chatId,
    });
  }

  String peerTitle(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return 'Telegram';
    final type = chat['type'];
    Map<String, dynamic>? user;
    if (type is Map && type['@type'] == 'chatTypePrivate') {
      final uid = (type['user_id'] as num?)?.toInt();
      if (uid != null) user = _users[uid];
    }
    return _chatTitle(chat, user);
  }

  String? peerAvatarPath(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return null;
    final photoId = _resolveChatAvatarFileId(chat);
    if (photoId != null) {
      final cached = _filePathCache[photoId];
      if (cached != null) return cached;
      _ensurePeerAvatarDownloading(
        chatId,
        foreground: _openChatId == chatId,
      );
      return null;
    }
    final type = chat['type'];
    if (type is Map && type['@type'] == 'chatTypePrivate') {
      final uid = (type['user_id'] as num?)?.toInt();
      if (uid != null) {
        final id = _resolveUserAvatarFileId(_users[uid]);
        if (id != null) {
          final cached = _filePathCache[id];
          if (cached != null) return cached;
          _ensurePeerAvatarDownloading(
            chatId,
            foreground: _openChatId == chatId,
          );
        }
      }
    } else if (type is Map &&
        (type['@type'] == 'chatTypeSupergroup' ||
            type['@type'] == 'chatTypeBasicGroup')) {
      // Chat list sometimes has no photo until getChat — refresh once.
      _refreshChatPhotoIfMissing(chatId);
    }
    return null;
  }

  List<int>? peerAvatarMinithumbnailBytes(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return null;
    return _photoMinithumbnailBytes(chat);
  }

  final Set<int> _chatPhotoRefreshQueued = {};

  /// Download / cache chat (or private-peer) avatar. Use [foreground] while the
  /// chat is open so the header upgrades off the minithumbnail quickly.
  void _ensurePeerAvatarDownloading(int chatId, {required bool foreground}) {
    if (chatId == 0) return;
    final chat = _chats[chatId];
    if (chat == null) return;

    var photoId = _resolveChatAvatarFileId(chat);
    if (photoId == null) {
      final type = chat['type'];
      if (type is Map && type['@type'] == 'chatTypePrivate') {
        final uid = _tdlibInt(type['user_id']);
        if (uid > 0) photoId = _resolveUserAvatarFileId(_users[uid]);
      } else if (type is Map &&
          (type['@type'] == 'chatTypeSupergroup' ||
              type['@type'] == 'chatTypeBasicGroup')) {
        _refreshChatPhotoIfMissing(chatId);
        return;
      }
    }
    if (photoId == null) return;

    // Prefer fetching `big` (640) for sharp channel/group avatars; fall back
    // to whatever id we resolved (may already be local `small`).
    int? bigId = _tdlibPhotoFileId(chat['photo'], 'big');
    if (bigId == null) {
      final uid = _privateUserId(chatId);
      if (uid != null) {
        bigId = _tdlibPhotoFileId(_users[uid]?['profile_photo'], 'big');
      }
    }
    final idToFetch =
        (bigId != null && !_filePathCache.containsKey(bigId)) ? bigId : photoId;
    if (_filePathCache.containsKey(idToFetch)) return;

    if (foreground) {
      // Never compete with focused message media on the single download slot.
      if (!_tdlibReadyForMedia ||
          _downloadInFlight.isNotEmpty ||
          _focusDownloadOrder.isNotEmpty ||
          _focusMessageId != null) {
        _mediaLog(
          'defer peer-avatar file=$idToFetch chat=$chatId '
          'conn=$_connectionState inflight=${_downloadInFlight.length} '
          'focus=${_focusDownloadOrder.length} focusMsg=$_focusMessageId',
        );
        return;
      }
      _queueFileDownload(
        idToFetch,
        priority: prioBackground,
        background: false,
        chatId: chatId,
        reason: 'peer-avatar',
      );
    } else {
      _queueAvatarDownload(idToFetch);
    }
  }

  int? _tdlibPhotoFileId(dynamic photo, String key) {
    if (photo is! Map) return null;
    final f = photo[key];
    if (f is! Map) return null;
    final id = _tdlibInt(f['id']);
    return id > 0 ? id : null;
  }

  void _refreshChatPhotoIfMissing(int chatId) {
    if (chatId == 0 || _chatPhotoRefreshQueued.contains(chatId)) return;
    final existing = _chats[chatId];
    if (existing != null && _resolveChatAvatarFileId(existing) != null) return;
    final c = _client;
    if (c == null) return;
    _chatPhotoRefreshQueued.add(chatId);
    unawaited(() async {
      try {
        final chat = await c.sendAwait({
          '@type': 'getChat',
          'chat_id': chatId,
        });
        if (chat['@type'] == 'chat') {
          _chats[chatId] = Map<String, dynamic>.from(chat);
          _ensurePeerAvatarDownloading(
            chatId,
            foreground: _openChatId == chatId,
          );
          notifyListeners();
        }
      } catch (_) {
      } finally {
        _chatPhotoRefreshQueued.remove(chatId);
      }
    }());
  }

  String peerStatusSubtitle(int chatId) {
    final action = _chatActions[chatId];
    if (action != null && action.isNotEmpty) return action;

    final chat = _chats[chatId];
    if (chat == null) return '';
    final type = chat['type'];
    if (type is! Map) return '';
    final typeName = type['@type']?.toString() ?? '';
    if (typeName == 'chatTypeSupergroup' && type['is_channel'] == true) {
      return 'канал';
    }
    if (typeName == 'chatTypeBasicGroup' ||
        typeName == 'chatTypeSupergroup') {
      return 'группа';
    }
    if (typeName != 'chatTypePrivate') return '';
    final uid = (type['user_id'] as num?)?.toInt();
    if (uid == null) return '';
    return _formatUserStatus(_users[uid]?['status']);
  }

  int? _privateUserId(int chatId) {
    final type = _chats[chatId]?['type'];
    if (type is! Map) return null;
    if (type['@type']?.toString() != 'chatTypePrivate') return null;
    return (type['user_id'] as num?)?.toInt();
  }

  /// Private chat id for [userId], if that DM already exists in the cache.
  int? privateChatIdForUser(int userId) {
    if (userId <= 0) return null;
    for (final entry in _chats.entries) {
      final type = entry.value['type'];
      if (type is! Map) continue;
      if (type['@type']?.toString() != 'chatTypePrivate') continue;
      if (_tdlibInt(type['user_id']) == userId) return entry.key;
    }
    return null;
  }

  Future<void> _refreshUser(int userId, {bool queueAvatar = true}) async {
    if (userId <= 0) return;
    final c = _client;
    if (c == null) return;
    try {
      final res = await c.sendAwait({
        '@type': 'getUser',
        'user_id': userId,
      });
      if (res['@type'] == 'user') {
        _users[userId] = Map<String, dynamic>.from(res);
        final photoId = _resolveUserAvatarFileId(_users[userId]);
        if (queueAvatar &&
            photoId != null &&
            !_filePathCache.containsKey(photoId)) {
          final openPrivate = _openChatId != null &&
              _privateUserId(_openChatId!) == userId;
          if (openPrivate) {
            if (_tdlibReadyForMedia) {
              _queueFileDownload(
                photoId,
                priority: prioBackground,
                background: false,
                chatId: _openChatId,
                reason: 'peer-avatar',
              );
            }
          } else {
            _queueAvatarDownload(photoId);
          }
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  void _ensureUserCached(int userId) {
    if (userId <= 0 || _users.containsKey(userId)) return;
    unawaited(_refreshUser(userId));
  }

  void _applyUserStatus(int userId, dynamic status) {
    if (userId <= 0 || status is! Map) return;
    final existing = _users[userId];
    if (existing != null) {
      existing['status'] = Map<String, dynamic>.from(status);
    } else {
      _users[userId] = {
        'id': userId,
        'status': Map<String, dynamic>.from(status),
      };
      unawaited(_refreshUser(userId));
    }
    notifyListeners();
  }

  String _formatChatAction(dynamic action) {
    if (action is! Map) return '';
    switch (action['@type']?.toString() ?? '') {
      case 'chatActionTyping':
        return 'печатает…';
      case 'chatActionRecordingVoiceNote':
        return 'записывает голосовое…';
      case 'chatActionUploadingVoiceNote':
        return 'отправляет голосовое…';
      case 'chatActionRecordingVideoNote':
        return 'записывает кружок…';
      case 'chatActionUploadingVideoNote':
        return 'отправляет кружок…';
      case 'chatActionUploadingPhoto':
        return 'отправляет фото…';
      case 'chatActionUploadingVideo':
        return 'отправляет видео…';
      case 'chatActionUploadingDocument':
        return 'отправляет файл…';
      case 'chatActionChoosingSticker':
        return 'выбирает стикер…';
      case 'chatActionChoosingContact':
        return 'выбирает контакт…';
      case 'chatActionChoosingLocation':
        return 'выбирает геопозицию…';
      default:
        return '';
    }
  }

  Future<void> _onActiveNotifications(Map<String, dynamic> update) async {
    final groups = update['groups'];
    if (groups is! List) return;
    for (final g in groups) {
      if (g is! Map) continue;
      final groupId = (g['id'] as num?)?.toInt();
      final chatId = (g['chat_id'] as num?)?.toInt();
      final notifications = g['notifications'];
      if (groupId == null || chatId == null) continue;
      _notifGroupChatId[groupId] = chatId;
      if (notifications is! List || notifications.isEmpty) {
        await _cancelLocalTdlibNotification(chatId);
        continue;
      }
      final last = notifications.last;
      if (last is Map) {
        await _showOrSkipTdlibNotification(
          groupId: groupId,
          chatId: chatId,
          notification: Map<String, dynamic>.from(last),
          isSilent: last['is_silent'] == true,
        );
      }
    }
  }

  Future<void> _onNotificationGroup(Map<String, dynamic> update) async {
    final groupId = (update['notification_group_id'] as num?)?.toInt();
    final chatId = (update['chat_id'] as num?)?.toInt();
    if (groupId == null || chatId == null) return;
    _notifGroupChatId[groupId] = chatId;

    final type = update['type'];
    final typeName = type is Map ? type['@type']?.toString() ?? '' : '';
    if (typeName == 'notificationGroupTypeCalls' ||
        typeName == 'notificationGroupTypeSecretChat') {
      // v1: message notifications only
      return;
    }

    final removed = update['removed_notification_ids'];
    final added = update['added_notifications'];
    final total = (update['total_count'] as num?)?.toInt() ?? 0;

    if (removed is List && removed.isNotEmpty && (added == null ||
        (added is List && added.isEmpty)) &&
        total <= 0) {
      await _cancelLocalTdlibNotification(chatId);
      _notifGroupChatId.remove(groupId);
      return;
    }

    if (added is List && added.isNotEmpty) {
      final last = added.last;
      if (last is Map) {
        final silent = update['notification_sound_id'] == 0 ||
            last['is_silent'] == true;
        await _showOrSkipTdlibNotification(
          groupId: groupId,
          chatId: chatId,
          notification: Map<String, dynamic>.from(last),
          isSilent: silent,
        );
      }
    } else if (total <= 0) {
      await _cancelLocalTdlibNotification(chatId);
      _notifGroupChatId.remove(groupId);
    }
  }

  Future<void> _onNotificationUpdate(Map<String, dynamic> update) async {
    final groupId = (update['notification_group_id'] as num?)?.toInt();
    final notification = update['notification'];
    if (groupId == null || notification is! Map) return;
    final chatId = _notifGroupChatId[groupId];
    if (chatId == null) return;
    await _showOrSkipTdlibNotification(
      groupId: groupId,
      chatId: chatId,
      notification: Map<String, dynamic>.from(notification),
      isSilent: notification['is_silent'] == true,
    );
  }

  Future<bool> _shouldSkipTdlibLocalPush(int chatId) async {
    if (_openChatId == chatId) return true;
    // Matched private chats → FC/secretary push only.
    final matches = await TelegramMatchStore.instance.loadAll();
    if (matches.containsKey(chatId)) return true;
    final uid = _privateUserId(chatId);
    if (uid != null && matches.containsKey(uid)) return true;
    return false;
  }

  Future<void> _showOrSkipTdlibNotification({
    required int groupId,
    required int chatId,
    required Map<String, dynamic> notification,
    required bool isSilent,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;

    if (await _shouldSkipTdlibLocalPush(chatId)) {
      await _ackRemoveNotification(groupId, notification);
      await _cancelLocalTdlibNotification(chatId);
      return;
    }

    final parsed = _parseTdlibNotificationContent(chatId, notification);
    if (parsed == null) return;

    final data = <String, dynamic>{
      'type': kTdlibPushType,
      'chat_id': '$chatId',
      'notification_group_id': '$groupId',
      'title': parsed.title,
      'body': parsed.body,
      'thread_title': parsed.title,
    };

    await FamilyChatNotifications.showForegroundPush(
      title: parsed.title,
      body: parsed.body,
      data: data,
    );
  }

  ({String title, String body})? _parseTdlibNotificationContent(
    int chatId,
    Map<String, dynamic> notification,
  ) {
    final type = notification['type'];
    if (type is! Map) return null;
    final typeName = type['@type']?.toString() ?? '';
    final title = peerTitle(chatId).trim().isEmpty
        ? 'Telegram'
        : peerTitle(chatId);

    if (typeName == 'notificationTypeNewMessage') {
      final message = type['message'];
      if (message is Map) {
        final msg = _parseMessage(Map<String, dynamic>.from(message));
        final body = msg?.text.trim();
        if (body != null && body.isNotEmpty) {
          return (title: title, body: body);
        }
        return (title: title, body: _previewText(message));
      }
    }

    if (typeName == 'notificationTypeNewPushMessage') {
      final senderName = type['sender_name']?.toString().trim() ?? '';
      final content = type['content'];
      var body = _pushContentPreview(content);
      if (body.isEmpty) body = 'Новое сообщение';
      final displayTitle = senderName.isNotEmpty && title == 'Telegram'
          ? senderName
          : title;
      if (senderName.isNotEmpty &&
          displayTitle != senderName &&
          !body.startsWith(senderName)) {
        return (title: displayTitle, body: '$senderName: $body');
      }
      return (title: displayTitle, body: body);
    }

    return (title: title, body: 'Новое сообщение');
  }

  String _pushContentPreview(dynamic content) {
    if (content is! Map) return '';
    switch (content['@type']?.toString() ?? '') {
      case 'pushMessageContentText':
        return content['text']?.toString() ?? '';
      case 'pushMessageContentPhoto':
        return 'Фото';
      case 'pushMessageContentVideo':
        return 'Видео';
      case 'pushMessageContentVoiceNote':
        return 'Голосовое сообщение';
      case 'pushMessageContentVideoNote':
        return 'Видеосообщение';
      case 'pushMessageContentSticker':
        return 'Стикер';
      case 'pushMessageContentDocument':
        return 'Файл';
      case 'pushMessageContentAnimation':
        return 'GIF';
      case 'pushMessageContentLocation':
        return 'Геопозиция';
      case 'pushMessageContentContact':
        return 'Контакт';
      case 'pushMessageContentPoll':
        return 'Опрос';
      default:
        return content['text']?.toString() ?? '';
    }
  }

  Future<void> _ackRemoveNotification(
    int groupId,
    Map<String, dynamic> notification,
  ) async {
    final c = _client;
    final id = (notification['id'] as num?)?.toInt();
    if (c == null || id == null) return;
    try {
      await c.sendAwait({
        '@type': 'removeNotification',
        'notification_group_id': groupId,
        'notification_id': id,
      });
    } catch (_) {}
  }

  Future<void> _cancelLocalTdlibNotification(int chatId) async {
    try {
      await FamilyChatNotifications.clearTdlibChatNotifications(chatId: chatId);
    } catch (_) {}
  }

  String? senderAvatarPath(int userId) {
    if (userId <= 0) return null;
    _ensureUserCached(userId);
    final id = _resolveUserAvatarFileId(_users[userId]);
    if (id == null) return null;
    final cached = _filePathCache[id];
    if (cached != null) return cached;
    _ensureSenderAvatarDownloading(userId);
    return null;
  }

  List<int>? senderAvatarMinithumbnailBytes(int userId) {
    if (userId <= 0) return null;
    final user = _users[userId];
    if (user == null) return null;
    final photo = user['profile_photo'];
    if (photo is! Map) return null;
    return _minithumbnailBytes(photo['minithumbnail']);
  }

  void _ensureSenderAvatarDownloading(int userId) {
    if (userId <= 0) return;
    final id = _resolveUserAvatarFileId(_users[userId]);
    if (id == null || _filePathCache.containsKey(id)) return;
    // Prefer small for list bubbles — cheaper than big profile photo.
    final smallId = _tdlibPhotoFileId(_users[userId]?['profile_photo'], 'small');
    final idToFetch =
        (smallId != null && !_filePathCache.containsKey(smallId)) ? smallId : id;
    if (_filePathCache.containsKey(idToFetch)) return;
    if (!_tdlibReadyForMedia) return;
    _queueFileDownload(
      idToFetch,
      priority: prioBackground,
      background: true,
      chatId: _openChatId,
      reason: 'sender-avatar',
    );
  }

  void _onUpdate(Map<String, dynamic> update) {
    final type = update['@type']?.toString() ?? '';
    switch (type) {
      case 'updateAuthorizationState':
        unawaited(_enqueueAuth(update['authorization_state']));
        break;
      case 'updateNewChat':
        final chat = update['chat'];
        if (chat is Map) {
          final id = (chat['id'] as num?)?.toInt();
          if (id != null) {
            _chats[id] = Map<String, dynamic>.from(chat);
            _syncChatOrderMembership(id);
            final lastOut =
                (chat['last_read_outbox_message_id'] as num?)?.toInt();
            if (lastOut != null) _lastReadOutboxId[id] = lastOut;
            _resolveChatAvatarFileId(_chats[id]!);
            notifyListeners();
          }
        }
        break;
      case 'updateChatPosition':
        final chatId = (update['chat_id'] as num?)?.toInt();
        final position = update['position'];
        if (chatId != null && position is Map) {
          _applyChatPosition(chatId, Map<String, dynamic>.from(position));
          notifyListeners();
        }
        break;
      case 'updateChatTitle':
      case 'updateChatLastMessage':
      case 'updateChatReadInbox':
      case 'updateChatReadOutbox':
      case 'updateChatPhoto':
      case 'updateChatNotificationSettings':
      case 'updateChatPermissions':
        final chatId = (update['chat_id'] as num?)?.toInt();
        if (chatId == null) return;
        final chat = _chats[chatId];
        if (chat == null) return;
        if (type == 'updateChatTitle') {
          chat['title'] = update['title'];
        } else if (type == 'updateChatLastMessage') {
          chat['last_message'] = update['last_message'];
          final positions = update['positions'];
          if (positions is List) {
            chat['positions'] = positions
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            _syncChatOrderMembership(chatId);
            if (_isInMainChatList(chat)) {
              // Move chat to front of hub order.
              _chatOrder.remove(chatId);
              _chatOrder.insert(0, chatId);
            }
          }
          // Always merge last_message into the open transcript — reliable
          // even if updateNewMessage was dropped or raced with history load.
          final last = update['last_message'];
          if (last is Map) {
            final lastMap = Map<String, dynamic>.from(last);
            lastMap.putIfAbsent('chat_id', () => chatId);
            final msg = _parseMessage(lastMap);
            if (msg != null) {
              _upsertMessage(msg);
              if (msg.chatId == _openChatId) {
                _maybeAutoMarkRead(msg.chatId, msg.id);
                focusVisibleMessageMedia(
                  chatId: msg.chatId,
                  messageId: msg.id,
                );
              }
            }
          }
        } else if (type == 'updateChatReadInbox') {
          chat['unread_count'] = update['unread_count'];
          final lastIn = _tdlibInt(update['last_read_inbox_message_id']);
          if (lastIn > 0) {
            chat['last_read_inbox_message_id'] = lastIn;
          }
        } else if (type == 'updateChatReadOutbox') {
          final lastOut =
              (update['last_read_outbox_message_id'] as num?)?.toInt();
          if (lastOut != null) {
            _lastReadOutboxId[chatId] = lastOut;
            chat['last_read_outbox_message_id'] = lastOut;
          }
        } else if (type == 'updateChatPhoto') {
          chat['photo'] = update['photo'];
          _ensurePeerAvatarDownloading(
            chatId,
            foreground: _openChatId == chatId,
          );
        } else if (type == 'updateChatNotificationSettings') {
          chat['notification_settings'] = update['notification_settings'];
        } else if (type == 'updateChatPermissions') {
          chat['permissions'] = update['permissions'];
          final next = _computeCanSendMessages(chatId);
          if (_canSendMessages[chatId] != next) {
            _canSendMessages[chatId] = next;
          }
        }
        notifyListeners();
        break;
      case 'updateScopeNotificationSettings': {
        final scope = update['scope'];
        final settings = update['notification_settings'];
        if (scope is Map && settings is Map) {
          final scopeType = scope['@type']?.toString();
          if (scopeType != null && scopeType.isNotEmpty) {
            _scopeNotificationSettings[scopeType] =
                Map<String, dynamic>.from(settings);
            notifyListeners();
          }
        }
        break;
      }
      case 'updateChatVideoChat':
        final chatId = (update['chat_id'] as num?)?.toInt();
        if (chatId != null) {
          final chat = _chats[chatId];
          if (chat != null) {
            chat['video_chat'] = update['video_chat'];
          }
          unawaited(_applyVideoChatFromChat(chatId, update['video_chat']));
        }
        break;
      case 'updateGroupCall':
        final call = update['group_call'];
        if (call is Map) {
          unawaited(_applyGroupCallUpdate(Map<String, dynamic>.from(call)));
        }
        break;
      case 'updateChatMember':
        final chatId = (update['chat_id'] as num?)?.toInt();
        final member = update['new_chat_member'] ?? update['member'];
        if (chatId != null && member is Map) {
          final memberId = member['member_id'];
          final uid = memberId is Map
              ? (memberId['user_id'] as num?)?.toInt()
              : null;
          if (uid != null && uid == _myUserId) {
            final st = member['status'];
            if (st is Map) {
              _chatMemberStatus[chatId] = Map<String, dynamic>.from(st);
              _canSendMessages[chatId] = _computeCanSendMessages(chatId);
              notifyListeners();
            }
          }
        }
        break;
      case 'updateDeleteMessages':
        final chatId = (update['chat_id'] as num?)?.toInt();
        final ids = update['message_ids'];
        if (chatId != null && ids is List) {
          final idSet = ids
              .map((e) => (e as num?)?.toInt())
              .whereType<int>()
              .toSet();
          _messagesByChat[chatId]?.removeWhere((m) => idSet.contains(m.id));
          notifyListeners();
        }
        break;
      case 'updateUser':
        final user = update['user'];
        if (user is Map) {
          final id = (user['id'] as num?)?.toInt();
          if (id != null) {
            _users[id] = Map<String, dynamic>.from(user);
            notifyListeners();
          }
        }
        break;
      case 'updateSupergroup':
        final sg = update['supergroup'];
        if (sg is Map) {
          final id = (sg['id'] as num?)?.toInt();
          if (id != null) {
            _supergroups[id] = Map<String, dynamic>.from(sg);
            // Left/banned — drop from hub if we can find the chat.
            final st = sg['status'];
            final stName = st is Map ? st['@type']?.toString() ?? '' : '';
            if (stName == 'chatMemberStatusLeft' ||
                stName == 'chatMemberStatusBanned') {
              for (final entry in _chats.entries) {
                final t = entry.value['type'];
                if (t is Map &&
                    t['@type']?.toString() == 'chatTypeSupergroup' &&
                    (t['supergroup_id'] as num?)?.toInt() == id) {
                  _chatMemberStatus[entry.key] =
                      Map<String, dynamic>.from(st as Map);
                }
              }
            }
            notifyListeners();
          }
        }
        break;
      case 'updateUserStatus':
        final userId = (update['user_id'] as num?)?.toInt();
        if (userId != null) {
          _applyUserStatus(userId, update['status']);
        }
        break;
      case 'updateChatAction':
        final chatId = (update['chat_id'] as num?)?.toInt();
        if (chatId == null) break;
        final action = update['action'];
        final label = _formatChatAction(action);
        if (label.isEmpty) {
          if (_chatActions.remove(chatId) != null) notifyListeners();
        } else if (_chatActions[chatId] != label) {
          _chatActions[chatId] = label;
          notifyListeners();
        }
        break;
      case 'updateActiveNotifications':
        unawaited(_onActiveNotifications(update));
        break;
      case 'updateNotificationGroup':
        unawaited(_onNotificationGroup(update));
        break;
      case 'updateNotification':
        unawaited(_onNotificationUpdate(update));
        break;
      case 'updateNewMessage':
        final message = update['message'];
        if (message is Map) {
          final msg = _parseMessage(Map<String, dynamic>.from(message));
          if (msg != null) {
            _upsertMessage(msg);
            if (msg.isService) {
              unawaited(refreshVideoChat(msg.chatId));
            }
            if (msg.chatId == _openChatId) {
              _maybeAutoMarkRead(msg.chatId, msg.id);
              focusVisibleMessageMedia(
                chatId: msg.chatId,
                messageId: msg.id,
              );
            }
            final bridgeHook = onBridgeNewMessage;
            if (bridgeHook != null && !msg.isService) {
              try {
                bridgeHook(msg);
              } catch (e) {
                debugPrint('[tdlib] onBridgeNewMessage: $e');
              }
            }
            notifyListeners();
          }
        }
        break;
      case 'updateMessageSendSucceeded':
        final oldId = (update['old_message_id'] as num?)?.toInt();
        final message = update['message'];
        if (oldId != null && message is Map) {
          final msg = _parseMessage(Map<String, dynamic>.from(message));
          if (msg != null) {
            _replaceMessageId(chatId: msg.chatId, oldId: oldId, msg: msg);
            notifyListeners();
          }
        }
        break;
      case 'updateMessageSendFailed':
        final oldId = (update['old_message_id'] as num?)?.toInt();
        final message = update['message'];
        final chatId = message is Map
            ? (message['chat_id'] as num?)?.toInt()
            : null;
        if (oldId != null && chatId != null) {
          _messagesByChat[chatId]?.removeWhere((m) => m.id == oldId);
          notifyListeners();
        }
        final err = update['error'];
        if (err is Map) {
          debugPrint(
            '[tdlib] send failed: ${err['code']} ${err['message']}',
          );
        }
        break;
      case 'updateFile':
        final file = update['file'];
        if (file is Map) {
          final rawId = _tdlibInt(file['id']);
          final local = file['local'];
          final remote = file['remote'];
          final uniqueId =
              remote is Map ? (remote['id']?.toString() ?? '') : '';
          if (rawId > 0 && local is Map) {
            final trackedId = _trackedFileIdForUpdate(rawId, uniqueId);
            if (trackedId != rawId &&
                (_downloadInFlight.isNotEmpty ||
                    _downloadTrace.isNotEmpty)) {
              _mediaLog(
                'updateFile-remap raw=$rawId → tracked=$trackedId '
                'remote=$uniqueId',
              );
            } else if (_downloadInFlight.isNotEmpty &&
                !_downloadInFlight.contains(trackedId) &&
                !_downloadTrace.containsKey(trackedId)) {
              // Orphan update while we have downloads — useful for diagnosis.
              final downloaded = _tdlibInt(local['downloaded_size']);
              final completed = local['is_downloading_completed'] == true;
              if (completed || downloaded > 0) {
                _mediaLog(
                  'updateFile-orphan id=$rawId remote=$uniqueId '
                  'got=${_fmtBytes(downloaded)} done=$completed '
                  'inflight=${_downloadInFlight.toList()}',
                );
              }
            }
            if (uniqueId.isNotEmpty) {
              _remoteUniqueToFileId[uniqueId] = trackedId;
              _downloadTrace[trackedId]?.remoteUniqueId = uniqueId;
            }
            final expected = _tdlibInt(file['expected_size']);
            final size = expected > 0 ? expected : _tdlibInt(file['size']);
            if (local['is_downloading_completed'] == true) {
              final path = local['path']?.toString();
              if (path != null && path.isNotEmpty) {
                // Cache under both ids when remapped.
                if (rawId != trackedId) _filePathCache[rawId] = path;
                _completeFileDownload(trackedId, path);
              } else {
                _fileDownloadProgress.remove(trackedId);
                notifyListeners();
              }
            } else {
              _updateFileDownloadProgress(
                trackedId,
                local,
                expectedSize: size,
              );
            }
          }
        }
        break;
      case 'updateMessageContent':
      case 'updateMessageInteractionInfo':
        final chatId = (update['chat_id'] as num?)?.toInt();
        final messageId = (update['message_id'] as num?)?.toInt();
        if (chatId == null || messageId == null) return;
        unawaited(_reloadMessage(chatId, messageId));
        break;
      case 'updateConnectionState':
        final state = update['state'];
        final name = state is Map ? state['@type']?.toString() ?? '' : '';
        final prev = _connectionState;
        _connectionState = name;
        _noteConnectionState(name);
        if (prev != name) {
          _mediaLog(
            'connection $prev → $name auth=$phase '
            '${_downloadQueueStats()}',
          );
          notifyListeners();
        }
        if (name == 'connectionStateReady' ||
            name == 'connectionStateUpdating') {
          if (name == 'connectionStateReady') {
            _connectionReadyJob ??= _onConnectionReady().whenComplete(() {
              _connectionReadyJob = null;
            });
          }
          // Start queued media once the MTProto session can carry bytes.
          _pumpDownloadQueue();
          if (name == 'connectionStateReady') {
            unawaited(_nudgeDownloadsAfterReconnect());
          }
        }
        break;
      default:
        break;
    }
  }

  Future<void> _reloadMessage(int chatId, int messageId) async {
    final c = _client;
    if (c == null) return;
    try {
      final res = await c.sendAwait({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
      if (res['@type'] != 'message') return;
      final msg = _parseMessage(res);
      if (msg == null) return;
      final list = _messagesByChat.putIfAbsent(chatId, () => []);
      final idx = list.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        list[idx] = msg;
      } else {
        list.add(msg);
        list.sort((a, b) => a.id.compareTo(b.id));
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _handleAuthState(dynamic state) async {
    if (state is! Map) return;
    final type = state['@type']?.toString() ?? '';
    final c = _client;
    if (c == null) return;

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        // TDLib may deliver WaitTdlibParameters twice (update + getAuthorizationState
        // race). Re-apply only when this client has not yet applied successfully;
        // a stale flag is cleared on tearDown / Closed / dead-client recover.
        if (_parametersApplied) {
          if (_setParamsJob != null) {
            await _setParamsJob;
          } else {
            _mediaLog(
              'boot WaitTdlibParameters ignore (already applied) phase=$phase',
            );
          }
          break;
        }
        _mediaLog(
          'boot WaitTdlibParameters → setParameters '
          '(wasApplied=$_parametersApplied phase=$phase)',
        );
        _setParamsJob ??= () async {
          _parametersApplied = true;
          try {
            await _setParameters();
            _mediaLog('boot setParameters finished phase=$phase');
          } on TdlibApiException catch (e) {
            _parametersApplied = false;
            if (e.code == 401 ||
                e.message.toLowerCase().contains('encryption key')) {
              if (_didWipeForEncryption) {
                phase = TdlibAuthPhase.error;
                errorMessage = e.toString();
                notifyListeners();
                return;
              }
              _didWipeForEncryption = true;
              debugPrint(
                  '[tdlib] encryption key mismatch — wipe + retry params');
              await _wipeTdlibFiles();
              try {
                _parametersApplied = true;
                await _setParameters();
              } catch (e2) {
                _parametersApplied = false;
                phase = TdlibAuthPhase.error;
                errorMessage = e2.toString();
                notifyListeners();
              }
            } else if (_isDatabaseLockError(e)) {
              debugPrint('[tdlib] database locked — close orphans + retry');
              await TdlibJsonClient.closeOrphanedClients(
                exceptClientId: c.clientId,
              );
              try {
                _parametersApplied = true;
                await _setParameters();
              } catch (e2) {
                _parametersApplied = false;
                phase = TdlibAuthPhase.error;
                errorMessage = e2.toString();
                notifyListeners();
              }
            } else if (e.message.toLowerCase().contains(
                  'unexpected settdlibparameters',
                )) {
              // Harmless race: params already applied for this client.
              _parametersApplied = true;
              _mediaLog('boot setParameters already applied (ignore)');
            } else {
              phase = TdlibAuthPhase.error;
              errorMessage = e.toString();
              notifyListeners();
            }
          } catch (e) {
            _parametersApplied = false;
            _mediaLog('boot setParameters uncaught $e');
            phase = TdlibAuthPhase.error;
            errorMessage = e.toString();
            notifyListeners();
          }
        }().whenComplete(() {
          _setParamsJob = null;
        });
        await _setParamsJob;
        break;
      case 'authorizationStateWaitPhoneNumber':
        phase = TdlibAuthPhase.waitPhone;
        notifyListeners();
        break;
      case 'authorizationStateWaitCode':
        phase = TdlibAuthPhase.waitCode;
        final info = state['code_info'];
        if (info is Map) {
          phoneHint = info['phone_number']?.toString();
          final delivery = info['type'];
          codeViaApp = delivery is Map &&
              delivery['@type']?.toString() == 'authenticationCodeTypeTelegramMessage';
        }
        notifyListeners();
        break;
      case 'authorizationStateWaitPassword':
        phase = TdlibAuthPhase.waitPassword;
        notifyListeners();
        break;
      case 'authorizationStateWaitEncryptionKey':
        // MVP: no DB encryption (key set empty in setTdlibParameters).
        await c.sendAwait({
          '@type': 'checkDatabaseEncryptionKey',
          'encryption_key': '',
        });
        break;
      case 'authorizationStateReady':
        phase = TdlibAuthPhase.ready;
        errorMessage = null;
        _didWipeForEncryption = false;
        notifyListeners();
        unawaited(_setTdlibOnline(true));
        _ensureNetworkLinkWatch();
        await refreshChatList();
        unawaited(_loadScopeNotificationSettings());
        unawaited(refreshMatchedTgUserIds());
        unawaited(_enableNotificationApiAndRegisterDevice());
        unawaited(_syncTdlibIdentityAfterReady());
        break;
      case 'authorizationStateLoggingOut':
        phase = TdlibAuthPhase.loggingOut;
        notifyListeners();
        break;
      case 'authorizationStateClosing':
      case 'authorizationStateClosed':
        _parametersApplied = false;
        if (_tearingDown) {
          phase = TdlibAuthPhase.starting;
          notifyListeners();
          break;
        }
        _mediaLog('auth Closed unexpectedly — recovering client');
        phase = TdlibAuthPhase.starting;
        notifyListeners();
        unawaited(_recoverDeadClient('auth-closed'));
        break;
      default:
        break;
    }
  }

  Future<void> _setParameters() async {
    final c = _client;
    if (c == null) return;
    final docs = await getApplicationDocumentsDirectory();
    final dbDir = Directory(p.join(docs.path, 'tdlib'));
    final filesDir = Directory(p.join(docs.path, 'tdlib_files'));
    await dbDir.create(recursive: true);
    await filesDir.create(recursive: true);

    Future<void> sendParams() {
      return c.sendAwait({
        '@type': 'setTdlibParameters',
        'use_test_dc': false,
        'database_directory': dbDir.path,
        'files_directory': filesDir.path,
        // Empty key = no local DB encryption (MVP). Avoids SecureStorage races.
        'database_encryption_key': '',
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': false,
        'api_id': TdlibConfig.apiId,
        'api_hash': TdlibConfig.apiHash,
        'system_language_code': 'ru',
        'device_model': Platform.isAndroid ? 'Android' : Platform.operatingSystem,
        'system_version': Platform.operatingSystemVersion,
        'application_version': '1.6.1',
      });
    }

    try {
      _mediaLog('boot setTdlibParameters…');
      await sendParams();
      _mediaLog('boot setTdlibParameters ok');
      await _ensureProxy();
      _mediaLog('boot proxy step done conn=$_connectionState');
    } on TdlibApiException catch (e) {
      if (_isDatabaseLockError(e)) {
        debugPrint('[tdlib] setTdlibParameters lock — close orphans + retry');
        await TdlibJsonClient.closeOrphanedClients(exceptClientId: c.clientId);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await sendParams();
        await _ensureProxy();
      } else {
        _mediaLog('boot setParameters FAIL $e');
        rethrow;
      }
    } catch (e) {
      _mediaLog('boot setParameters FAIL $e');
      rethrow;
    }
  }

  bool _isDatabaseLockError(TdlibApiException e) {
    final m = e.message.toLowerCase();
    return m.contains('already in use') ||
        m.contains("can't lock") ||
        m.contains('cannot lock') ||
        m.contains('td.binlog');
  }


  /// Newer TDLib wraps proxy fields in an outer object (`proxy` key) for
  /// both [addProxy] results and [getProxies] entries. Flatten for matching.
  Map<String, dynamic> _flattenProxyEntry(Map raw) {
    final outer = Map<String, dynamic>.from(raw);
    final inner = outer['proxy'];
    if (inner is! Map) return outer;
    final flat = Map<String, dynamic>.from(inner);
    for (final k in ['id', 'is_enabled', 'last_used_date', 'comment']) {
      if (outer[k] != null) flat[k] = outer[k];
    }
    return flat;
  }

  Future<void> _ensureProxy() async {
    final c = _client;
    if (c == null) return;
    final server = TdlibConfig.proxyServer;
    final port = TdlibConfig.proxyPort;
    final secret = TdlibConfig.proxySecret;
    try {
      _mediaLog(
        'proxy ensure $server:$port (mtproto FakeTLS) '
        'secret=${secret.length}b ${secret.substring(0, 6)}…${secret.substring(secret.length - 8)}',
      );

      // Prefer a single enabled proxy. Repeated addProxy stacks duplicates;
      // TDLib then opens many half-dead sockets (mtg: cannot read client hello,
      // domain-fronting only — never proxy.relay).
      int? matchId;
      final existing = <Map<String, dynamic>>[];
      try {
        final list = await c.sendAwait({
          '@type': 'getProxies',
        }, timeout: const Duration(seconds: 5));
        final proxies = list['proxies'];
        if (proxies is List) {
          for (final raw in proxies) {
            if (raw is! Map) continue;
            final p = _flattenProxyEntry(raw);
            existing.add(p);
            final id = (p['id'] as num?)?.toInt();
            final pServer = p['server']?.toString() ?? '';
            final pPort = (p['port'] as num?)?.toInt() ?? -1;
            final type = p['type'];
            final pSecret = type is Map ? type['secret']?.toString() ?? '' : '';
            final typeName =
                type is Map ? type['@type']?.toString() ?? '' : '';
            _mediaLog(
              'proxy listed id=$id $pServer:$pPort '
              'enabled=${p['is_enabled']} type=$typeName '
              'secretLen=${pSecret.length}',
            );
            // TDLib may re-encode the MTProto secret (hex length changes).
            // Reuse any mtproto proxy on the same host:port — wipe+readd
            // every boot causes Ready↔Connecting flaps.
            if (id != null &&
                pServer == server &&
                pPort == port &&
                typeName == 'proxyTypeMtproto') {
              if (pSecret == secret) {
                matchId = id;
              } else {
                matchId ??= id;
              }
            }
          }
        }
      } catch (e) {
        _mediaLog('proxy getProxies soft-fail err=$e');
      }

      // Prefer existing matching proxy — remove+readd every boot tears MTProto
      // (Ready→Connecting flaps + Pong timeout within seconds).
      if (matchId != null) {
        for (final p in existing) {
          final id = (p['id'] as num?)?.toInt();
          if (id == null || id == matchId) continue;
          try {
            await c.sendAwait({
              '@type': 'removeProxy',
              'proxy_id': id,
            }, timeout: const Duration(seconds: 3));
            _mediaLog(
              'proxy removed stale id=$id ${p['server']}:${p['port']}',
            );
          } catch (e) {
            _mediaLog('proxy remove id=$id soft-fail err=$e');
          }
        }
        final alreadyOn = existing.any((p) {
          final id = (p['id'] as num?)?.toInt();
          return id == matchId && p['is_enabled'] == true;
        });
        if (!alreadyOn) {
          await c.sendAwait({
            '@type': 'enableProxy',
            'proxy_id': matchId,
          }, timeout: const Duration(seconds: 8));
        }
        _enabledProxyId = matchId;
        _mediaLog(
          'proxy enabled existing id=$matchId $server:$port '
          '(wasEnabled=$alreadyOn)',
        );
        unawaited(_pingProxyWhenReady(c, matchId));
        return;
      }

      // No match: drop leftovers, then add the configured proxy once.
      for (final p in existing) {
        final id = (p['id'] as num?)?.toInt();
        if (id == null) continue;
        try {
          await c.sendAwait({
            '@type': 'removeProxy',
            'proxy_id': id,
          }, timeout: const Duration(seconds: 3));
          _mediaLog(
            'proxy removed id=$id ${p['server']}:${p['port']}',
          );
        } catch (e) {
          _mediaLog('proxy remove id=$id soft-fail err=$e');
        }
      }

      // Newer TDLib: addProxy proxy:proxy enable:Bool
      // (flat server/port/type → "Proxy must be non-empty").
      final res = await c.sendAwait({
        '@type': 'addProxy',
        'enable': true,
        'proxy': {
          '@type': 'proxy',
          'server': server,
          'port': port,
          'type': {
            '@type': 'proxyTypeMtproto',
            'secret': secret,
          },
        },
      }, timeout: const Duration(seconds: 8));
      final flat = _flattenProxyEntry(res);
      final proxyId = (flat['id'] as num?)?.toInt() ??
          (res['id'] as num?)?.toInt();
      if (proxyId != null) _enabledProxyId = proxyId;
      _mediaLog(
        'proxy added id=${proxyId ?? '?'} enabled=${flat['is_enabled']} '
        'server=${flat['server']}:${flat['port']} $server:$port',
      );
      if (proxyId != null) {
        // pingProxy is diagnostic only; defer until Ready (race after add).
        unawaited(_pingProxyWhenReady(c, proxyId));
      }
    } catch (e) {
      _mediaLog('proxy FAIL err=$e');
      debugPrint('[tdlib] addProxy failed: $e');
    }
  }

  Future<void> _pingProxyWhenReady(TdlibJsonClient client, int proxyId) async {
    final ok = await _waitForMediaConnection(
      timeout: const Duration(seconds: 25),
    );
    if (!ok) {
      _mediaLog('proxy ping skip id=$proxyId (mtproto not ready)');
      return;
    }
    // Let the session settle — immediate ping races DC dial and false-fails.
    await Future<void>.delayed(const Duration(seconds: 8));
    if (!_tdlibReadyForMedia) {
      _mediaLog('proxy ping skip id=$proxyId (dropped Ready while waiting)');
      return;
    }
    try {
      final ping = await client.sendAwait(
        {'@type': 'pingProxy', 'proxy_id': proxyId},
        timeout: const Duration(seconds: 20),
      );
      final sec = ping['seconds'];
      _mediaLog('proxy ping ok id=$proxyId seconds=$sec');
    } on TdlibApiException catch (e) {
      // Pong timeout is noisy but not fatal — MTProto may still carry traffic.
      _mediaLog('proxy ping soft-fail id=$proxyId err=$e');
    } catch (e) {
      _mediaLog('proxy ping soft-fail id=$proxyId err=$e');
    }
  }

  TdlibMessage? _parseMessage(Map<String, dynamic> m) {
    final id = (m['id'] as num?)?.toInt();
    final chatId = (m['chat_id'] as num?)?.toInt();
    if (id == null || chatId == null) return null;
    final sender = m['sender_id'];
    var senderUserId = 0;
    if (sender is Map && sender['@type'] == 'messageSenderUser') {
      senderUserId = (sender['user_id'] as num?)?.toInt() ?? 0;
    }
    final content = m['content'];
    var text = '';
    var textEntities = <Map<String, dynamic>>[];
    String? photoPath;
    int? photoId;
    String? photoSizeType;
    int? photoWidth;
    int? photoHeight;
    List<int> photoFallbackFileIds = const [];
    List<int>? photoThumbBytes;
    int? voiceFileId;
    String? voicePath;
    int? voiceDurationMs;
    int? videoNoteFileId;
    String? videoNotePath;
    int? videoNoteDurationMs;
    int? videoNoteThumbFileId;
    String? videoNoteThumbPath;
    List<int>? videoNoteThumbBytes;
    int? videoFileId;
    String? videoPath;
    int? videoDurationMs;
    int? videoWidth;
    int? videoHeight;
    int? videoThumbFileId;
    String? videoThumbPath;
    List<int>? videoThumbBytes;
    var isAnimation = false;
    var isService = false;
    if (content is Map) {
      final ctype = content['@type']?.toString() ?? '';
      if (ctype == 'messageText') {
        final parsed = _parseFormattedText(content['text']);
        text = parsed.text;
        textEntities = parsed.entities;
      } else if (ctype == 'messagePhoto') {
        final parsed = _parseFormattedText(content['caption']);
        text = parsed.text;
        textEntities = parsed.entities;
        final photo = content['photo'];
        final photoParsed = _parsePhotoContent(photo);
        photoId = photoParsed.fileId;
        photoPath = photoParsed.localPath;
        photoSizeType = photoParsed.type;
        photoWidth = photoParsed.width;
        photoHeight = photoParsed.height;
        photoFallbackFileIds = photoParsed.fallbackFileIds;
        if (photo is Map) {
          photoThumbBytes = _minithumbnailBytes(photo['minithumbnail']);
        }
        if (photoId == null) {
          // Last-resort: any photo size file id (parse bug / odd TDLib shape).
          photoId = _firstPhotoSizeFileId(photo);
          final sizeTypes = <String>[];
          if (photo is Map && photo['sizes'] is List) {
            for (final s in photo['sizes'] as List) {
              if (s is Map) {
                sizeTypes.add(
                  '${s['type']}:${_tdlibInt((s['photo'] as Map?)?['id'] ?? (s['file'] as Map?)?['id'])}',
                );
              }
            }
          }
          _mediaLog(
            'photo-parse-fallback msg file=$photoId '
            'sizes=${sizeTypes.isEmpty ? 0 : sizeTypes.length} '
            'detail=${sizeTypes.join(",")}',
          );
        }
        if (text.isEmpty) {
          text = 'Фото';
          textEntities = const [];
        }
      } else if (ctype == 'messageVoiceNote') {
        final vn = content['voice_note'];
        if (vn is Map) {
          final durationSec = (vn['duration'] as num?)?.toInt() ?? 0;
          if (durationSec > 0) voiceDurationMs = durationSec * 1000;
          final voice = vn['voice'];
          if (voice is Map) {
            voiceFileId = (voice['id'] as num?)?.toInt();
            final local = voice['local'];
            if (local is Map && local['is_downloading_completed'] == true) {
              voicePath = local['path']?.toString();
            }
          }
        }
        final parsed = _parseFormattedText(content['caption']);
        if (parsed.text.isNotEmpty) {
          text = parsed.text;
          textEntities = parsed.entities;
        }
      } else if (ctype == 'messageVideoNote') {
        final vn = content['video_note'];
        if (vn is Map) {
          final durationSec = (vn['duration'] as num?)?.toInt() ?? 0;
          if (durationSec > 0) videoNoteDurationMs = durationSec * 1000;
          final video = vn['video'];
          if (video is Map) {
            videoNoteFileId = (video['id'] as num?)?.toInt();
            final local = video['local'];
            if (local is Map && local['is_downloading_completed'] == true) {
              videoNotePath = local['path']?.toString();
            }
          }
          videoNoteThumbBytes = _minithumbnailBytes(vn['minithumbnail']);
          final thumbParsed = _parseThumbnailFile(vn['thumbnail']);
          videoNoteThumbFileId = thumbParsed.fileId;
          videoNoteThumbPath = thumbParsed.localPath;
        }
      } else if (ctype == 'messageVideo' || ctype == 'messageAnimation') {
        isAnimation = ctype == 'messageAnimation';
        final parsed = _parseFormattedText(content['caption']);
        text = parsed.text;
        textEntities = parsed.entities;
        final media = isAnimation ? content['animation'] : content['video'];
        if (media is Map) {
          final durationSec = (media['duration'] as num?)?.toInt() ?? 0;
          if (durationSec > 0) videoDurationMs = durationSec * 1000;
          final w = (media['width'] as num?)?.toInt() ?? 0;
          final h = (media['height'] as num?)?.toInt() ?? 0;
          if (w > 0) videoWidth = w;
          if (h > 0) videoHeight = h;
          final file = media['video'] ?? media['animation'];
          if (file is Map) {
            videoFileId = (file['id'] as num?)?.toInt();
            final local = file['local'];
            if (local is Map && local['is_downloading_completed'] == true) {
              videoPath = local['path']?.toString();
            }
          }
          videoThumbBytes = _minithumbnailBytes(media['minithumbnail']);
          final thumbParsed = _parseThumbnailFile(media['thumbnail']);
          videoThumbFileId = thumbParsed.fileId;
          videoThumbPath = thumbParsed.localPath;
        }
        if (text.isEmpty) {
          text = isAnimation ? 'GIF' : 'Видео';
          textEntities = const [];
        }
      } else if (ctype == 'messageDocument') {
        final parsed = _parseFormattedText(content['caption']);
        text = parsed.text;
        textEntities = parsed.entities;
        final doc = content['document'];
        var name = '';
        if (doc is Map) {
          name = doc['file_name']?.toString() ?? '';
        }
        if (text.isEmpty) {
          text = name.isNotEmpty ? 'Файл: $name' : 'Файл';
          textEntities = const [];
        }
      } else if (ctype == 'messageAudio') {
        final parsed = _parseFormattedText(content['caption']);
        text = parsed.text;
        textEntities = parsed.entities;
        final audio = content['audio'];
        var title = '';
        if (audio is Map) {
          title = audio['title']?.toString() ??
              audio['file_name']?.toString() ??
              '';
        }
        if (text.isEmpty) {
          text = title.isNotEmpty ? '🎵 $title' : '🎵 Аудио';
          textEntities = const [];
        }
      } else if (ctype == 'messageSticker') {
        final sticker = content['sticker'];
        var emoji = '';
        if (sticker is Map) emoji = sticker['emoji']?.toString() ?? '';
        text = emoji.isNotEmpty ? emoji : 'Стикер';
      } else if (ctype == 'messagePoll') {
        final poll = content['poll'];
        var q = '';
        if (poll is Map) {
          final question = poll['question'];
          if (question is Map) {
            q = question['text']?.toString() ?? '';
          } else {
            q = poll['question']?.toString() ?? '';
          }
        }
        text = q.isNotEmpty ? '📊 $q' : '📊 Опрос';
      } else if (ctype == 'messageAnimatedEmoji') {
        final emoji = content['emoji']?.toString() ?? '';
        text = emoji.isNotEmpty ? emoji : 'Стикер';
      } else if (ctype == 'messageVideoChatStarted') {
        isService = true;
        text = 'Началась трансляция';
      } else if (ctype == 'messageVideoChatEnded') {
        isService = true;
        final durationSec = (content['duration'] as num?)?.toInt() ?? 0;
        text = durationSec > 0
            ? 'Трансляция завершена (${_formatDurationShort(durationSec)})'
            : 'Трансляция завершена';
      } else if (ctype == 'messageVideoChatScheduled') {
        isService = true;
        text = 'Трансляция запланирована';
      } else if (ctype == 'messageInviteVideoChatParticipants') {
        isService = true;
        text = 'Приглашение в трансляцию';
      } else {
        text = _friendlyContentLabel(ctype);
      }
    }
    final reactions = <TdlibReaction>[];
    final interaction = m['interaction_info'];
    if (interaction is Map) {
      final ri = interaction['reactions'];
      final list = ri is Map ? ri['reactions'] : null;
      if (list is List) {
        for (final r in list) {
          if (r is! Map) continue;
          final type = r['type'];
          var emoji = '';
          if (type is Map && type['@type'] == 'reactionTypeEmoji') {
            emoji = type['emoji']?.toString() ?? '';
          }
          if (emoji.isEmpty) continue;
          reactions.add(
            TdlibReaction(
              emoji: emoji,
              count: (r['total_count'] as num?)?.toInt() ?? 0,
              chosen: (r['is_chosen'] == true),
            ),
          );
        }
      }
    }

    int? replyToId;
    var replyPreview = '';
    final replyTo = m['reply_to'];
    if (replyTo is Map) {
      replyToId = (replyTo['message_id'] as num?)?.toInt();
      final quote = replyTo['quote'];
      if (quote is Map) {
        final qt = quote['text'];
        if (qt is Map) replyPreview = qt['text']?.toString() ?? '';
      }
    }
    if (replyToId != null && replyPreview.isEmpty) {
      final existing = _messagesByChat[chatId];
      final found = existing?.where((x) => x.id == replyToId).firstOrNull;
      if (found != null) {
        if (found.isVoiceNote) {
          replyPreview = 'Голосовое сообщение';
        } else if (found.isVideoNote) {
          replyPreview = 'Видеосообщение';
        } else {
          replyPreview = found.text;
        }
      }
    }

    if (photoId != null && photoPath != null && photoPath.isNotEmpty) {
      _filePathCache[photoId] = photoPath;
    }
    if (voiceFileId != null && voicePath != null && voicePath.isNotEmpty) {
      _filePathCache[voiceFileId] = voicePath;
    }
    if (videoNoteFileId != null &&
        videoNotePath != null &&
        videoNotePath.isNotEmpty) {
      _filePathCache[videoNoteFileId] = videoNotePath;
    }
    if (videoNoteThumbFileId != null &&
        videoNoteThumbPath != null &&
        videoNoteThumbPath.isNotEmpty) {
      _filePathCache[videoNoteThumbFileId] = videoNoteThumbPath;
    }
    if (videoFileId != null && videoPath != null && videoPath.isNotEmpty) {
      _filePathCache[videoFileId] = videoPath;
    }
    if (videoThumbFileId != null &&
        videoThumbPath != null &&
        videoThumbPath.isNotEmpty) {
      _filePathCache[videoThumbFileId] = videoThumbPath;
    }

    if (senderUserId > 0) _ensureUserCached(senderUserId);

    String? forwardOriginName;
    String? forwardOriginChatTitle;
    int? forwardFromChatId;
    int? forwardFromMessageId;
    final forwardInfo = m['forward_info'];
    if (forwardInfo is Map) {
      final fromChat = _tdlibInt(forwardInfo['from_chat_id']);
      final fromMsg = _tdlibInt(forwardInfo['from_message_id']);
      if (fromChat != 0) forwardFromChatId = fromChat;
      if (fromMsg != 0) forwardFromMessageId = fromMsg;
      final origin = forwardInfo['origin'];
      if (origin is Map) {
        final parsed = _parseForwardOrigin(origin);
        forwardOriginName = parsed.name;
        forwardOriginChatTitle = parsed.chatTitle;
      }
    }

    return TdlibMessage(
      id: id,
      chatId: chatId,
      senderUserId: senderUserId,
      isOutgoing: m['is_outgoing'] == true,
      date: (m['date'] as num?)?.toInt() ?? 0,
      text: text,
      textEntities: textEntities,
      photoLocalPath: photoPath ??
          (photoId == null ? null : _filePathCache[photoId]),
      photoRemoteId: photoId,
      photoSizeType: photoSizeType,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      photoFallbackFileIds: photoFallbackFileIds,
      photoThumbBytes: photoThumbBytes,
      voiceFileId: voiceFileId,
      voiceLocalPath: voicePath ??
          (voiceFileId == null ? null : _filePathCache[voiceFileId]),
      voiceDurationMs: voiceDurationMs,
      videoNoteFileId: videoNoteFileId,
      videoNoteLocalPath: videoNotePath ??
          (videoNoteFileId == null
              ? null
              : _filePathCache[videoNoteFileId]),
      videoNoteDurationMs: videoNoteDurationMs,
      videoNoteThumbFileId: videoNoteThumbFileId,
      videoNoteThumbLocalPath: videoNoteThumbPath ??
          (videoNoteThumbFileId == null
              ? null
              : _filePathCache[videoNoteThumbFileId]),
      videoNoteThumbBytes: videoNoteThumbBytes,
      videoFileId: videoFileId,
      videoLocalPath: videoPath ??
          (videoFileId == null ? null : _filePathCache[videoFileId]),
      videoDurationMs: videoDurationMs,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      videoThumbFileId: videoThumbFileId,
      videoThumbLocalPath: videoThumbPath ??
          (videoThumbFileId == null
              ? null
              : _filePathCache[videoThumbFileId]),
      videoThumbBytes: videoThumbBytes,
      isAnimation: isAnimation,
      reactions: reactions,
      replyToMessageId: replyToId,
      replyPreviewText: replyPreview,
      canBeEdited: m['can_be_edited'] == true,
      canBeDeletedForAllUsers: m['can_be_deleted_for_all_users'] == true,
      canBeDeletedOnlyForSelf: m['can_be_deleted_only_for_self'] == true,
      isPinned: m['is_pinned'] == true,
      isService: isService,
      mediaAlbumId: () {
        final v = _tdlibInt(m['media_album_id']);
        return v == 0 ? null : v;
      }(),
      forwardOriginName: forwardOriginName,
      forwardOriginChatTitle: forwardOriginChatTitle,
      forwardFromChatId: forwardFromChatId,
      forwardFromMessageId: forwardFromMessageId,
    );
  }

  ({String text, List<Map<String, dynamic>> entities}) _parseFormattedText(
    dynamic formatted,
  ) {
    if (formatted is! Map) {
      return (text: '', entities: const []);
    }
    final text = formatted['text']?.toString() ?? '';
    return (text: text, entities: _parseTextEntities(formatted['entities']));
  }

  List<Map<String, dynamic>> _parseTextEntities(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final offset = _tdlibInt(item['offset']);
      final length = _tdlibInt(item['length']);
      if (length <= 0) continue;
      final type = item['type'];
      if (type is! Map) continue;
      final t = type['@type']?.toString() ?? '';
      var bold = false;
      var italic = false;
      var underline = false;
      var strikethrough = false;
      var code = false;
      String? url;
      String? urlKind;
      if (t == 'textEntityTypeBold') {
        bold = true;
      } else if (t == 'textEntityTypeItalic') {
        italic = true;
      } else if (t == 'textEntityTypeUnderline') {
        underline = true;
      } else if (t == 'textEntityTypeStrikethrough') {
        strikethrough = true;
      } else if (t == 'textEntityTypeCode' ||
          t == 'textEntityTypePre' ||
          t == 'textEntityTypePreCode') {
        code = true;
      } else if (t == 'textEntityTypeTextUrl') {
        url = type['url']?.toString();
      } else if (t == 'textEntityTypeUrl') {
        urlKind = 'url';
      } else if (t == 'textEntityTypeEmailAddress') {
        urlKind = 'email';
      } else if (t == 'textEntityTypePhoneNumber') {
        urlKind = 'phone';
      } else if (t == 'textEntityTypeMention') {
        urlKind = 'mention';
      } else if (t == 'textEntityTypeHashtag' ||
          t == 'textEntityTypeCashtag' ||
          t == 'textEntityTypeBotCommand' ||
          t == 'textEntityTypeMentionName' ||
          t == 'textEntityTypeSpoiler' ||
          t == 'textEntityTypeCustomEmoji') {
        // Keep as plain text (no style flags).
      } else {
        continue;
      }
      out.add({
        'offset': offset,
        'length': length,
        if (bold) 'bold': true,
        if (italic) 'italic': true,
        if (underline) 'underline': true,
        if (strikethrough) 'strikethrough': true,
        if (code) 'code': true,
        if (url != null && url.isNotEmpty) 'url': url,
        if (urlKind != null) 'url_kind': urlKind,
      });
    }
    return out;
  }

  ({String? name, String? chatTitle}) _parseForwardOrigin(Map origin) {
    final t = origin['@type']?.toString() ?? '';
    switch (t) {
      case 'messageOriginUser':
      case 'messageForwardOriginUser':
        final uid = _tdlibInt(origin['sender_user_id']);
        if (uid > 0) {
          _ensureUserCached(uid);
          return (name: senderDisplayName(uid), chatTitle: null);
        }
        return (name: null, chatTitle: null);
      case 'messageOriginHiddenUser':
      case 'messageForwardOriginHiddenUser':
        final name = origin['sender_name']?.toString();
        return (
          name: (name != null && name.isNotEmpty) ? name : 'Пользователь',
          chatTitle: null,
        );
      case 'messageOriginChannel':
      case 'messageForwardOriginChannel':
        final chatId = _tdlibInt(origin['chat_id']);
        final title = chatId != 0 ? peerTitle(chatId) : '';
        final sig = origin['author_signature']?.toString() ?? '';
        return (
          name: sig.isNotEmpty
              ? sig
              : (title.isNotEmpty ? title : 'Канал'),
          chatTitle: title.isNotEmpty ? title : null,
        );
      case 'messageOriginChat':
      case 'messageForwardOriginChat':
        final chatId = _tdlibInt(
          origin['sender_chat_id'] ?? origin['chat_id'],
        );
        final title = chatId != 0 ? peerTitle(chatId) : '';
        final sig = origin['author_signature']?.toString() ?? '';
        return (
          name: sig.isNotEmpty
              ? sig
              : (title.isNotEmpty ? title : 'Чат'),
          chatTitle: title.isNotEmpty ? title : null,
        );
      default:
        return (name: null, chatTitle: null);
    }
  }

  /// Pick a displayable photo size.
  ///
  /// Prefer a high-res standard size (`y`/`x`/`w`) for both the bubble and the
  /// fullscreen viewer. Tiny `m`/`s` look pixelated on modern screens.
  /// Only reuse an already-downloaded local file when it is already mid/large.
  ({
    int? fileId,
    String? localPath,
    String? type,
    int? width,
    int? height,
    List<int> fallbackFileIds,
  }) _parsePhotoContent(dynamic photo) {
    if (photo is! Map) {
      return (
        fileId: null,
        localPath: null,
        type: null,
        width: null,
        height: null,
        fallbackFileIds: const [],
      );
    }
    final sizes = photo['sizes'];
    if (sizes is! List || sizes.isEmpty) {
      return (
        fileId: null,
        localPath: null,
        type: null,
        width: null,
        height: null,
        fallbackFileIds: const [],
      );
    }

    ({
      int fileId,
      String? localPath,
      int area,
      String type,
      int width,
      int height,
    })? bestLocalGood;
    ({
      int fileId,
      String? localPath,
      int area,
      String type,
      int width,
      int height,
    })? bestRemote;
    ({
      int fileId,
      String? localPath,
      int area,
      String type,
      int width,
      int height,
    })? bestAnyLocal;

    final byType = <String, int>{};
    final typeSummary = <String>[];
    for (final raw in sizes) {
      if (raw is! Map) continue;
      final type = raw['type']?.toString() ?? '';
      // i/j are special / incomplete variants — skip when others exist.
      if (type == 'i' || type == 'j') continue;
      final file = raw['photo'] ?? raw['file'];
      if (file is! Map) continue;
      final id = _tdlibInt(file['id']);
      if (id <= 0) continue;
      final w = (raw['width'] as num?)?.toInt() ?? 0;
      final h = (raw['height'] as num?)?.toInt() ?? 0;
      final area = w * h;
      typeSummary.add('$type:${w}x$h#$id');
      byType[type] = id;
      String? path;
      final local = file['local'];
      if (local is Map && local['is_downloading_completed'] == true) {
        final pth = local['path']?.toString();
        if (pth != null && pth.isNotEmpty) path = pth;
      }
      final entry = (
        fileId: id,
        localPath: path,
        area: area,
        type: type,
        width: w,
        height: h,
      );
      if (path != null) {
        if (bestAnyLocal == null || area > bestAnyLocal.area) {
          bestAnyLocal = entry;
        }
        // Accept local only if it's already decent (≥ ~800px class).
        if (_photoTypeRank(type) >= _photoTypeRank('x') || area >= 800 * 800) {
          if (bestLocalGood == null ||
              area > bestLocalGood.area ||
              (area == bestLocalGood.area &&
                  _photoTypeRank(type) > _photoTypeRank(bestLocalGood.type))) {
            bestLocalGood = entry;
          }
        }
      }
      // Never prefer s/m when a sharper size exists in the same photo.
      if (_photoTypeRank(type) < _photoTypeRank('x') &&
          bestRemote != null &&
          _photoTypeRank(bestRemote.type) >= _photoTypeRank('x')) {
        continue;
      }
      if (bestRemote == null ||
          _photoTypeRank(type) > _photoTypeRank(bestRemote.type) ||
          (_photoTypeRank(type) == _photoTypeRank(bestRemote.type) &&
              area > bestRemote.area)) {
        bestRemote = entry;
      }
    }

    List<int> fallbacksFor(int primaryId, String primaryType) {
      final out = <int>[];
      void add(String type) {
        final id = byType[type];
        if (id == null || id == primaryId || out.contains(id)) return;
        out.add(id);
      }
      final primaryRank = _photoTypeRank(primaryType);
      if (primaryRank < _photoTypeRank('x')) {
        // Soft primary — queue sharper upgrades (x first).
        for (final type in ['x', 'y', 'w']) {
          if (_photoTypeRank(type) > primaryRank) add(type);
        }
      } else {
        // Sharp primary — smaller sizes as stall fallback only.
        for (final type in ['m', 's', 'x']) {
          if (_photoTypeRank(type) < primaryRank) add(type);
        }
      }
      return out;
    }

    final chosen = bestLocalGood ?? bestRemote ?? bestAnyLocal;
    if (chosen != null) {
      if (chosen.type == 'm' || chosen.type == 's') {
        _mediaLog(
          'photo-pick-soft type=${chosen.type} ${chosen.width}x${chosen.height} '
          'file=${chosen.fileId} all=[${typeSummary.join(",")}]',
        );
      }
      return (
        fileId: chosen.fileId,
        localPath: chosen.localPath,
        type: chosen.type,
        width: chosen.width,
        height: chosen.height,
        fallbackFileIds: fallbacksFor(chosen.fileId, chosen.type),
      );
    }

    // Fallback: largest by area including exotic types.
    ({int fileId, String? localPath, int area, String type, int width, int height})?
        largest;
    for (final raw in sizes) {
      if (raw is! Map) continue;
      final file = raw['photo'] ?? raw['file'];
      if (file is! Map) continue;
      final id = _tdlibInt(file['id']);
      if (id <= 0) continue;
      final type = raw['type']?.toString() ?? '';
      final w = (raw['width'] as num?)?.toInt() ?? 0;
      final h = (raw['height'] as num?)?.toInt() ?? 0;
      final area = w * h;
      String? path;
      final local = file['local'];
      if (local is Map && local['is_downloading_completed'] == true) {
        path = local['path']?.toString();
      }
      if (largest == null || area > largest.area) {
        largest = (
          fileId: id,
          localPath: path,
          area: area,
          type: type,
          width: w,
          height: h,
        );
      }
    }
    if (largest == null) {
      return (
        fileId: null,
        localPath: null,
        type: null,
        width: null,
        height: null,
        fallbackFileIds: const [],
      );
    }
    return (
      fileId: largest.fileId,
      localPath: largest.localPath,
      type: largest.type,
      width: largest.width,
      height: largest.height,
      fallbackFileIds: fallbacksFor(largest.fileId, largest.type),
    );
  }

  /// Higher = better default download target for chat bubbles.
  /// Prefer `x` (~800px) over `y`/`w` — sharp on phone, much less stall-prone
  /// on channel DCs through the MTProto proxy.
  int _photoTypeRank(String type) {
    switch (type) {
      case 'x':
        return 80; // ~800px — best first paint for bubbles
      case 'y':
        return 70; // ~1280px
      case 'w':
        return 50; // often 2560-wide; save for fullscreen upgrade
      case 'm':
        return 30; // ~320px — soft but useful stall fallback
      case 's':
        return 10;
      default:
        return 5;
    }
  }

  /// Any file id from photo.sizes (ignores type ranking).
  int? _firstPhotoSizeFileId(dynamic photo) {
    if (photo is! Map) return null;
    final sizes = photo['sizes'];
    if (sizes is! List) return null;
    int? bestId;
    var bestArea = -1;
    for (final raw in sizes) {
      if (raw is! Map) continue;
      final file = raw['photo'] ?? raw['file'];
      if (file is! Map) continue;
      final id = _tdlibInt(file['id']);
      if (id <= 0) continue;
      final w = (raw['width'] as num?)?.toInt() ?? 0;
      final h = (raw['height'] as num?)?.toInt() ?? 0;
      final area = w * h;
      if (area >= bestArea) {
        bestArea = area;
        bestId = id;
      }
    }
    return bestId;
  }

  ({int? fileId, String? localPath}) _parseThumbnailFile(dynamic thumb) {
    if (thumb is! Map) return (fileId: null, localPath: null);
    final file = thumb['file'] ?? thumb['photo'];
    if (file is! Map) return (fileId: null, localPath: null);
    final id = (file['id'] as num?)?.toInt();
    String? path;
    final local = file['local'];
    if (local is Map && local['is_downloading_completed'] == true) {
      path = local['path']?.toString();
    }
    return (fileId: id, localPath: path);
  }

  List<int>? _minithumbnailBytes(dynamic mini) {
    if (mini is! Map) return null;
    final raw = mini['data'];
    if (raw is String && raw.isNotEmpty) {
      try {
        return base64Decode(raw);
      } catch (_) {
        return null;
      }
    }
    if (raw is List) return raw.cast<int>();
    return null;
  }

  Future<void> _applyVideoChatFromChat(int chatId, dynamic videoChat) async {
    final c = _client;
    if (videoChat is! Map) {
      if (_videoChats.remove(chatId) != null) notifyListeners();
      return;
    }
    final groupCallId = _tdlibInt(videoChat['group_call_id']);
    if (groupCallId <= 0) {
      if (_videoChats.remove(chatId) != null) notifyListeners();
      return;
    }

    var title = '';
    var participantCount = 0;
    var isRtmp = false;
    var isActive = true;
    if (c != null && isReady) {
      try {
        final call = await c.sendAwait({
          '@type': 'getGroupCall',
          'group_call_id': groupCallId,
        });
        if (call['@type'] == 'groupCall') {
          title = call['title']?.toString() ?? '';
          participantCount = _tdlibInt(call['participant_count']);
          isRtmp = call['is_rtmp_stream'] == true;
          isActive = call['is_active'] != false;
          if (call['scheduled_start_date'] is num &&
              (call['scheduled_start_date'] as num).toInt() > 0 &&
              call['is_active'] != true) {
            // Scheduled but not started yet — still show bar lightly.
            isActive = true;
          }
        }
      } catch (e) {
        debugPrint('[tdlib] getGroupCall($groupCallId): $e');
      }
    }

    var username = _videoChats[chatId]?.username ?? '';
    if (username.isEmpty) {
      username = await _chatUsername(chatId);
    }

    final next = TdlibVideoChat(
      chatId: chatId,
      groupCallId: groupCallId,
      title: title,
      participantCount: participantCount,
      isRtmpStream: isRtmp,
      isActive: isActive,
      username: username,
    );
    final prev = _videoChats[chatId];
    if (prev != null &&
        prev.groupCallId == next.groupCallId &&
        prev.participantCount == next.participantCount &&
        prev.title == next.title &&
        prev.isActive == next.isActive &&
        prev.username == next.username) {
      return;
    }
    _videoChats[chatId] = next;
    notifyListeners();
  }

  Future<void> _applyGroupCallUpdate(Map<String, dynamic> call) async {
    final groupCallId = _tdlibInt(call['id']);
    if (groupCallId <= 0) return;
    final isActive = call['is_active'] != false;
    final participantCount = _tdlibInt(call['participant_count']);
    final title = call['title']?.toString() ?? '';
    final isRtmp = call['is_rtmp_stream'] == true;

    var changed = false;
    for (final entry in _videoChats.entries.toList()) {
      if (entry.value.groupCallId != groupCallId) continue;
      if (!isActive) {
        _videoChats.remove(entry.key);
        changed = true;
        continue;
      }
      _videoChats[entry.key] = TdlibVideoChat(
        chatId: entry.key,
        groupCallId: groupCallId,
        title: title.isNotEmpty ? title : entry.value.title,
        participantCount: participantCount,
        isRtmpStream: isRtmp,
        isActive: true,
        username: entry.value.username,
      );
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<String> _chatUsername(int chatId) async {
    final chat = _chats[chatId];
    if (chat == null) return '';
    final type = chat['type'];
    if (type is! Map) return '';
    if (type['@type']?.toString() != 'chatTypeSupergroup') return '';
    final sgId = _tdlibInt(type['supergroup_id']);
    if (sgId <= 0) return '';
    final c = _client;
    if (c == null) return '';
    try {
      final sg = await c.sendAwait({
        '@type': 'getSupergroup',
        'supergroup_id': sgId,
      });
      final usernames = sg['usernames'];
      if (usernames is Map) {
        var u = usernames['editable_username']?.toString() ?? '';
        if (u.isEmpty) {
          final active = usernames['active_usernames'];
          if (active is List && active.isNotEmpty) {
            u = active.first.toString();
          }
        }
        return u;
      }
      return sg['username']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _friendlyContentLabel(String ctype) {
    switch (ctype) {
      case 'messageVideo':
        return 'Видео';
      case 'messageAnimation':
        return 'GIF';
      case 'messageDocument':
        return 'Файл';
      case 'messageAudio':
        return 'Аудио';
      case 'messageSticker':
        return 'Стикер';
      case 'messagePoll':
        return 'Опрос';
      case 'messageLocation':
        return 'Геопозиция';
      case 'messageVenue':
        return 'Место';
      case 'messageContact':
        return 'Контакт';
      case 'messageCall':
        return 'Звонок';
      case 'messageVideoChatStarted':
        return 'Началась трансляция';
      case 'messageVideoChatEnded':
        return 'Трансляция завершена';
      case 'messageVideoChatScheduled':
        return 'Трансляция запланирована';
      case 'messageInviteVideoChatParticipants':
        return 'Приглашение в трансляцию';
      case 'messageUnsupported':
        return 'Неподдерживаемое сообщение';
      default:
        return 'Вложение';
    }
  }

  String _formatDurationShort(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}с';
    final minutes = totalSeconds ~/ 60;
    if (minutes < 60) return '${minutes}м';
    final hours = minutes ~/ 60;
    final remMin = minutes % 60;
    if (remMin == 0) return '${hours}ч';
    return '${hours}ч ${remMin}м';
  }

  String _chatTitle(Map<String, dynamic> chat, Map<String, dynamic>? user) {
    final title = chat['title']?.toString().trim() ?? '';
    if (title.isNotEmpty) return title;
    if (user != null) {
      final first = user['first_name']?.toString() ?? '';
      final last = user['last_name']?.toString() ?? '';
      final name = ('$first $last').trim();
      if (name.isNotEmpty) return name;
    }
    return 'Telegram';
  }

  /// Prefer chat photo `big`, then `small` (channels look soft on mini/`small`
  /// alone at high DPI). Seeds [_filePathCache] when TDLib already has the file.
  int? _resolveChatAvatarFileId(
    Map<String, dynamic> chat, {
    Map<String, dynamic>? user,
  }) {
    final fromChat = _cacheTdlibPhotoFile(chat['photo'], preferBig: true);
    if (fromChat != null) return fromChat;
    return _resolveUserAvatarFileId(user);
  }

  int? _resolveUserAvatarFileId(Map<String, dynamic>? user) {
    if (user == null) return null;
    return _cacheTdlibPhotoFile(user['profile_photo'], preferBig: true);
  }

  /// Reads `small`/`big` File from chatPhotoInfo / profilePhoto, or `sizes`
  /// from chatPhoto. File ids may be String int64 in JSON.
  ///
  /// Returns the best file id to display/download: an already-local size if
  /// any, otherwise `big` (or `small`) so we can queue a sharp download.
  int? _cacheTdlibPhotoFile(dynamic photo, {required bool preferBig}) {
    if (photo is! Map) return null;

    int? firstId;
    int? localId;
    final keys = preferBig ? ['big', 'small'] : ['small', 'big'];
    for (final key in keys) {
      final f = photo[key];
      if (f is! Map) continue;
      final id = _tdlibInt(f['id']);
      if (id <= 0) continue;
      firstId ??= id;
      final local = f['local'];
      if (local is Map && local['is_downloading_completed'] == true) {
        final path = local['path']?.toString();
        if (path != null && path.isNotEmpty) {
          _filePathCache[id] = path;
          localId ??= id;
        }
      }
    }
    if (localId != null) return localId;
    if (firstId != null) return firstId;

    // Fallback: full chatPhoto with sizes[] (rare on chat.photo, common elsewhere).
    final sizes = photo['sizes'];
    if (sizes is List && sizes.isNotEmpty) {
      Map? best;
      Map? bestLocal;
      var bestArea = -1;
      var bestLocalArea = -1;
      for (final s in sizes) {
        if (s is! Map) continue;
        final file = s['photo'];
        if (file is! Map) continue;
        final id = _tdlibInt(file['id']);
        if (id <= 0) continue;
        final w = _tdlibInt(s['width']);
        final h = _tdlibInt(s['height']);
        final area = w * h;
        final local = file['local'];
        final path = local is Map && local['is_downloading_completed'] == true
            ? local['path']?.toString()
            : null;
        if (path != null && path.isNotEmpty) {
          _filePathCache[id] = path;
          if (area >= bestLocalArea) {
            bestLocalArea = area;
            bestLocal = file;
          }
        }
        if (area >= bestArea) {
          bestArea = area;
          best = file;
        }
      }
      final chosen = bestLocal ?? best;
      if (chosen != null) {
        final id = _tdlibInt(chosen['id']);
        if (id > 0) return id;
      }
    }
    return null;
  }

  List<int>? _photoMinithumbnailBytes(Map<String, dynamic> chat) {
    final photo = chat['photo'];
    if (photo is! Map) return null;
    final mini = photo['minithumbnail'];
    if (mini is! Map) return null;
    final raw = mini['data'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  String _formatUserStatus(dynamic status) {
    if (status is! Map) return '';
    final type = status['@type']?.toString() ?? '';
    switch (type) {
      case 'userStatusOnline':
        return 'в сети';
      case 'userStatusRecently':
        return 'был(а) недавно';
      case 'userStatusLastWeek':
        return 'был(а) на этой неделе';
      case 'userStatusLastMonth':
        return 'был(а) в этом месяце';
      case 'userStatusOffline':
        final was = (status['was_online'] as num?)?.toInt();
        if (was == null || was <= 0) return 'не в сети';
        final dt = DateTime.fromMillisecondsSinceEpoch(was * 1000);
        final now = DateTime.now();
        final sameDay =
            dt.year == now.year && dt.month == now.month && dt.day == now.day;
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        if (sameDay) return 'был(а) в $hh:$mm';
        return 'был(а) ${dt.day.toString().padLeft(2, '0')}.'
            '${dt.month.toString().padLeft(2, '0')} в $hh:$mm';
      default:
        return '';
    }
  }

  String _previewText(dynamic last) {
    if (last is! Map) return '';
    final content = last['content'];
    if (content is! Map) return '';
    final type = content['@type']?.toString() ?? '';
    if (type == 'messageText') {
      final t = content['text'];
      if (t is Map) return _firstPreviewLine(t['text']?.toString() ?? '');
    }
    final captionLine = _captionPreviewLine(content);
    if (type == 'messagePhoto') {
      return captionLine ?? '📷 Фото';
    }
    if (type == 'messageVoiceNote') {
      return captionLine ?? '🎤 Голосовое';
    }
    if (type == 'messageVideoNote') return '📹 Видеосообщение';
    if (type == 'messageVideo') {
      return captionLine ?? '🎬 Видео';
    }
    if (type == 'messageAnimation') {
      return captionLine ?? 'GIF';
    }
    if (type == 'messageDocument') {
      return captionLine ?? '📎 Файл';
    }
    if (type == 'messageAudio') {
      return captionLine ?? '🎵 Аудио';
    }
    if (type == 'messageSticker') return 'Стикер';
    if (type == 'messagePoll') return '📊 Опрос';
    if (type == 'messageVideoChatStarted') return 'Началась трансляция';
    if (type == 'messageVideoChatEnded') return 'Трансляция завершена';
    if (type == 'messageVideoChatScheduled') return 'Трансляция запланирована';
    if (type == 'messageInviteVideoChatParticipants') {
      return 'Приглашение в трансляцию';
    }
    return _friendlyContentLabel(type);
  }

  String? _captionPreviewLine(Map content) {
    final caption = content['caption'];
    if (caption is! Map) return null;
    final line = _firstPreviewLine(caption['text']?.toString() ?? '');
    return line.isEmpty ? null : line;
  }

  String _firstPreviewLine(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    for (final line in trimmed.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return trimmed;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel() ?? Future.value());
    unawaited(_client?.dispose() ?? Future.value());
    super.dispose();
  }
}
