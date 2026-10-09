import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/diagnostics/app_session_diagnostics.dart';
import '../../core/diagnostics/session_log.dart';
import '../../core/network/chat_network_link.dart';
import '../../core/network/api_client.dart';
import '../../core/notifications/familychat_notifications.dart';
import '../../firebase_options.dart';
import '../chat/data/chat_media_display_policy.dart';
import '../chat/data/link_preview_service.dart';
import '../familychat/data/familychat_repository.dart';
import 'tdlib_chat_folder.dart';
import 'tdlib_config.dart';
import 'tdlib_geo.dart';
import 'tdlib_io.dart';
import 'tdlib_json_client.dart';
import 'tg_jank_log.dart';
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
  /// Bytes at last ~5s sample (for SessionLog `bytesDelta5s`).
  int sampleBytes = 0;
  DateTime? sampleAt;
  int offset = 0;
  String netAtStart = '';
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

/// Member row for TG group info sheet.
class TdlibChatMember {
  const TdlibChatMember({
    required this.userId,
    required this.displayName,
    this.avatarLocalPath,
    this.avatarMinithumbnailBytes,
    this.isCreator = false,
    this.isAdmin = false,
  });

  final int userId;
  final String displayName;
  final String? avatarLocalPath;
  final List<int>? avatarMinithumbnailBytes;
  final bool isCreator;
  final bool isAdmin;
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
    this.videoSizeBytes,
    this.videoThumbFileId,
    this.videoThumbLocalPath,
    this.videoThumbBytes,
    this.isAnimation = false,
    this.isSticker = false,
    this.stickerEmoji,
    this.documentFileId,
    this.documentLocalPath,
    this.documentFileName,
    this.documentMimeType,
    this.documentSizeBytes,
    this.documentThumbFileId,
    this.documentThumbLocalPath,
    this.documentThumbBytes,
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
    this.sendingState,
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
  /// TDLib `sending_state`: `pending` / `failed`, or null when on server.
  final String? sendingState;
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
  /// Declared file size from TDLib (`size` / `expected_size`).
  final int? videoSizeBytes;
  final int? videoThumbFileId;
  final String? videoThumbLocalPath;
  final List<int>? videoThumbBytes;
  final bool isAnimation;
  /// Telegram sticker (webp / tgs / webm) — media via photo* or video* fields.
  final bool isSticker;
  final String? stickerEmoji;
  /// Generic file (messageDocument) — PDF, zip, etc.
  final int? documentFileId;
  final String? documentLocalPath;
  final String? documentFileName;
  final String? documentMimeType;
  final int? documentSizeBytes;
  final int? documentThumbFileId;
  final String? documentThumbLocalPath;
  final List<int>? documentThumbBytes;
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
      (isAnimation ||
          videoFileId != null ||
          videoLocalPath != null ||
          videoThumbFileId != null ||
          (videoThumbBytes != null && videoThumbBytes!.isNotEmpty));
  bool get isDocument =>
      documentFileId != null ||
      (documentLocalPath != null && documentLocalPath!.isNotEmpty) ||
      (documentFileName != null && documentFileName!.isNotEmpty);
  bool get isPdfDocument {
    if (!isDocument) return false;
    final mime = (documentMimeType ?? '').toLowerCase();
    if (mime.contains('pdf')) return true;
    final name = (documentFileName ?? documentLocalPath ?? '').toLowerCase();
    return name.endsWith('.pdf');
  }
  bool get isForwarded =>
      forwardOriginName != null ||
      forwardFromChatId != null ||
      forwardFromMessageId != null;

  /// Everything a bubble paints, hashed. Idle tail polling re-parses the same
  /// messages every few seconds; an unchanged fingerprint means the rebuild
  /// would paint the identical frame, so the notify can be skipped.
  int get uiFingerprint => Object.hash(
        id,
        date,
        text,
        textEntities.length,
        isPinned,
        isService,
        mediaAlbumId,
        replyToMessageId,
        replyPreviewText,
        Object.hashAll(
          reactions.map((r) => Object.hash(r.emoji, r.count, r.chosen)),
        ),
        photoRemoteId,
        photoSizeType,
        photoLocalPath,
        voiceLocalPath,
        videoLocalPath,
        videoNoteLocalPath,
        documentLocalPath,
        Object.hash(
          videoThumbLocalPath,
          videoNoteThumbLocalPath,
          documentThumbLocalPath,
        ),
        Object.hash(canBeEdited, isOutgoing, sendingState),
      );
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
  /// Folder tabs from [updateChatFolders] (id → basic info).
  final Map<int, TdlibChatFolderInfo> _chatFolderInfos = {};
  /// Full [chatFolder] payloads from [getChatFolder].
  final Map<int, Map<String, dynamic>> _chatFolderDetails = {};
  /// chat_folder_id → chat ids known to belong to that folder.
  final Map<int, Set<int>> _folderChatIds = {};
  int _chatFoldersEpoch = 0;
  /// First hub paint may wait on this: main chat list (+ folders) hydrated
  /// after [TdlibAuthPhase.ready], so FC rows don't flash before TG.
  bool _hubSurfaceReady = false;
  /// TG user ids (and private chat ids) matched to an FC peer — excluded from
  /// [notifiedUnreadTotal] so Chat-tab badges do not double-count FC DMs.
  final Set<int> _matchedTgUserIds = {};
  /// Local floor for inbox read progress. TDLib `getChat` / last-message
  /// updates can briefly regress `last_read_inbox_message_id` after
  /// `viewMessages`, which made the tip-heuristic revive hub badges.
  final Map<int, int> _readInboxFloor = {};
  /// Scope defaults for [isChatMuted] when `use_default_mute_for` is set.
  final Map<String, Map<String, dynamic>> _scopeNotificationSettings = {};

  int? _openChatId;
  /// Monotonic id for the current UI open session. Stale [closeChat] from a
  /// disposed route must carry the old token; otherwise a re-open of the same
  /// chat receives TDLib `closeChat` → `updateDeleteMessages(from_cache)` and
  /// the transcript collapses to `last_message`.
  int _openChatTokenSeq = 0;
  int? _activeOpenToken;
  /// Copy of the open chat transcript that survives soft TDLib restarts
  /// (`_tearDown` clears RAM but must not blank the visible conversation).
  final Map<int, List<TdlibMessage>> _openTranscriptPreserve = {};
  final Set<int> _historyWarmInFlight = {};
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
  ///
  /// Hub list: 3 is the sweet spot with FakeTLS proxy — faster than 2 for the
  /// visible avatar budget (16), without flooding mtg handshakes like 5+.
  /// Keep in sync with the hub-avatar inflight cap in [_pumpDownloadQueue].
  static const _maxConcurrentDownloads = 3;
  /// Chat-open downloads. With FakeTLS, parallel downloadFile floods mtg with
  /// domain-fronting handshakes (VPS: FC DF≫relay, no DC203; official TG
  /// had healthy DC203). Keep 1 media transfer at a time on proxy.
  static const _maxConcurrentWhenChatOpen = 1;
  /// TDLib priorities (1 = highest … 32 = lowest).
  // TDLib downloadFile priority: 1..32, HIGHER = earlier download.
  static const prioFocused = 32;
  static const prioOpenChat = 24;
  static const prioOpenChatMedia = 16;
  /// Hub list avatars (visible rows only) — above generic background warm.
  static const prioHubAvatar = 10;
  /// Alt-size / delayed retry after a hub-avatar 0B stall.
  /// Keep BELOW first-pass (10): poison remotes were jumping the queue at prio
  /// 18 and starving never-tried faces in the visible viewport for tens of
  /// seconds while Telegram/Шарий VPN etc. sat at 0B forever.
  static const prioHubAvatarRetry = 6;
  static const prioBackground = 4;
  /// Hang with no new bytes → cancelDownloadFile + requeue / size fallback.
  ///
  /// Official guidance (levlam / td#2585): there are no "stalled" downloads —
  /// TDLib keeps retrying internally. Client may cancel + async re-downloadFile
  /// (td#3017). FakeTLS: short 0B while Connecting; longer while Ready
  /// (official keeps live transfers; proxy-parity R6/R8). Do **not** re-add
  /// Ready-gate / stall-defer (invariants §1–2).
  static const _stallZeroBytes = Duration(seconds: 45);
  static const _stallZeroBytesFocus = Duration(seconds: 45);
  static const _stallZeroBytesVideo = Duration(seconds: 90);
  /// FakeTLS (proxy on), while NOT Ready: free the single slot fast.
  static const _stallZeroBytesProxy = Duration(seconds: 15);
  static const _stallZeroBytesFocusProxy = Duration(seconds: 12);
  static const _stallZeroBytesVideoProxy = Duration(seconds: 30);
  /// FakeTLS while Ready/Updating: give TDLib/CDN time (official does not
  /// cancel a **live** transfer at ~12s). SessionLog 20:26.
  /// R19 (SessionLog 15:32): never-progressed 0B is not live — video Ready
  /// budget aligned with focus (35s). Mid-file hangs: R22 progress-idle
  /// Ready+proxy ~15s (was 45s). Old 75s burned ~minute of dead CDN.
  static const _stallZeroBytesProxyReady = Duration(seconds: 40);
  static const _stallZeroBytesFocusProxyReady = Duration(seconds: 35);
  static const _stallZeroBytesVideoProxyReady = Duration(seconds: 35);
  /// Hub avatars are tiny; with proxy some remotes never leave 0B — rotate
  /// the single/dual slot quickly so the rest of the viewport can paint.
  static const _stallZeroBytesHubAvatar = Duration(seconds: 4);
  /// R22 (SessionLog 16:32–16:38): small thumbs (≤64KB) Ready+0B burned ~90s
  /// of the exclusive slot (CDN→origin→lastchance) while video taps waited.
  static const _stallZeroBytesThumbProxyReady = Duration(seconds: 12);
  static const _stallSmallFileBytes = 64 * 1024;
  static const _stallProgressIdle = Duration(seconds: 45);
  static const _stallProgressIdleProxy = Duration(seconds: 20);
  /// R22: mid-file idle under Ready+FakeTLS held the slot 45s at 14.5KB —
  /// align with Connecting-proxy idle (~15–20s).
  static const _stallProgressIdleProxyReady = Duration(seconds: 15);
  /// Auto-download / background warm window (same as FamilyChat media policy).
  static const mediaAutoAge = ChatMediaDisplayPolicy.deferredFullMediaAge;
  /// Hub warm disabled in exclusive-focus mode.
  static const warmHubChatLimit = 0;
  static const warmHubMediaPerChat = 0;
  /// Open-chat: only the focused message (no band prefetch).
  /// Open-chat: focused photo first; one neighbor max after focus starts.
  /// How many message-ids above/below focus to warm. Albums span several
  /// consecutive ids — radius 1 only hit the next album sibling, leaving the
  /// following post stuck on soft `m` / minithumb.
  static const viewportMediaRadius = 4;
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
  /// SessionLog `tg.proxy` / `plane` heartbeat (proxy-parity research).
  Timer? _proxyPlaneTimer;
  /// Last successful [pingProxy] RTT in ms; null if never / last failed.
  int? _lastPongMs;
  DateTime? _lastPongAt;
  /// Batches high-frequency media UI notifies (progress / completes mid-fling).
  Timer? _uiNotifyTimer;
  bool _uiNotifyPending = false;
  bool _uiScrollBusy = false;
  DateTime? _uiScrollBusyUntil;
  /// Cached [hubChats] until the next [notifyListeners] — build() used to
  /// re-walk/sort/decode minithumbs dozens of times per frame.
  List<TdlibChatPreview>? _hubChatsCache;
  /// chatId → decoded JPEG minithumb (null = known missing).
  final Map<int, List<int>?> _miniThumbByChatId = {};
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
  /// Delay before AppBar shows "ожидание прокси…" — short Ready↔Connecting
  /// flaps (mobile↔Wi‑Fi ~0.2–0.5s) must not flash the subtitle.
  static const _kConnectionStatusGrace = Duration(milliseconds: 1500);
  Timer? _connectionStatusRevealTimer;
  Future<void>? _connectionReadyJob;
  /// Last successfully enabled MTProto proxy id (for stuck-Connecting kick).
  int? _enabledProxyId;
  /// Geo policy: RU (or unknown) → proxy; other countries → direct.
  /// Debug AppBar OFF ([_debugMtprotoProxyPref]=false) forces direct.
  /// Debug AppBar ON = allow FakeTLS and **follow geo** (R18) — not force-on.
  bool _useMtprotoProxy = true;
  bool? _useMtprotoProxyResolved;
  /// Debug AppBar switch — **user intent only**, persisted; default ON.
  /// R18: geo must NOT write this (VPN leave-RU used to sticky-OFF the switch
  /// and then skip all future geo rechecks).
  static const _kDebugMtprotoProxyPref = 'tdlib_debug_mtproto_proxy';
  /// One-shot: clear sticky AppBar OFF written by pre-R18 geo-off.
  static const _kDebugMtprotoProxyR18Migrated =
      'tdlib_debug_mtproto_proxy_r18';
  bool _debugMtprotoProxyPref = true;
  bool _debugMtprotoProxyPrefLoaded = false;
  /// Serializes ensure/disable so geo-off cannot race AppBar/ensure (SessionLog
  /// 13:09: geo-off → switch ON → ensure → switch OFF + TDLib timeouts).
  Future<void> _proxyMutateTail = Future<void>.value();
  DateTime? _lastConnectionKickAt;
  int _connectionKickCount = 0;
  /// Last mobile↔Wi‑Fi (or offline) transition — accelerates soft-restart.
  DateTime? _lastBearerChangeAt;
  DateTime? _lastBearerRecoverAt;
  /// Last non-offline link kind — never leave TDLib on networkTypeNone after a
  /// reopen bounce (SessionLog 09:09 stuck-connecting:up → None → WaitingForNetwork).
  ChatNetworkLinkKind _lastNonOfflineKind = ChatNetworkLinkKind.wifi;
  StreamSubscription<ChatNetworkLinkKind>? _networkLinkSub;
  ChatNetworkLinkKind _networkKind = ChatNetworkLinkKind.unknown;
  DateTime? _lastSetNetworkTypeAt;
  Future<void>? _setNetworkTypeJob;
  /// Kick / wait timers only run in foreground (SessionLog overnight 498m/673m).
  bool _appInForeground = true;
  Timer? _appResumeRecoverTimer;
  DateTime? _lastAppResumeRecoverAt;
  /// After pause/resume: no proxy failover / None-bounce (official tgnet +
  /// levlam). See `_fc_diag/proxy_parity/06_OFFICIAL_PAUSE_RESUME.md`.
  DateTime? _softResumeGuardUntil;
  /// Delay [setNetworkType None] after pause — official tgnet pauseNetwork →
  /// suspendConnections (R26). Short switches cancel before suspend.
  /// Old online=false grace skipped when already Connecting → zombie FakeTLS.
  Timer? _pauseOfflineGraceTimer;
  static const _pauseSuspendGrace = Duration(seconds: 2);
  /// True after pause applied networkTypeNone until resume unsuspends.
  bool _appNetworkSuspended = false;
  /// Wall-clock when we entered background (for long-lock resume escalate).
  DateTime? _backgroundPausedAt;
  /// Resume after long lock (≥2m) **or** resume while already Connecting
  /// (R13: TDLib drops Ready ~5s into background — SessionLog 22:36 bg=52s
  /// never armed long-bg). Soft-nudge alone often fails — soft-restart ladder.
  bool _longBackgroundResume = false;
  /// Soft-restarts in the current long-bg cycle (cap [_longBgSoftRestartCap]).
  /// Cleared on Ready. SessionLog 22:12: pingProxy while Connecting times out
  /// on every hop → R12: reopen×2 then one no-ping hop try.
  int _longBackgroundSoftRestartCount = 0;
  /// R24: 3 same-hop soft-restarts before hop-try — SessionLog 14:15/14:26
  /// Ready landed on the 3rd soft-restart (~0.4s); hop-try+preferred-undo
  /// only burned ~35s. Cap was 2 → hop after #2 never got Ready on 8443.
  static const _longBgSoftRestartCap = 3;
  DateTime? _lastLongBgHopTryAt;
  static const _longBackgroundThreshold = Duration(minutes: 2);
  /// True long lock (bg ≥2m), not R13 synthetic escalate. SessionLog 23:36:
  /// enableProxy+quiet after 8m lock never helped — soft-restart first (R16).
  bool _resumeWasTrueLongBackground = false;
  /// Last-resort None→current after hop ladder exhausted (hibernation reopen).
  /// Not first recover — only hop-debounce / post-ladder (R16).
  DateTime? _lastLongBgSocketReopenAt;
  /// After soft-restart / hop-try / resume / boot+sync enableProxy /
  /// soft-nudge / bearer / proxy-cycle: suppress soft kicks + repeated
  /// `enableProxy` while Connecting so FakeTLS can finish handshake.
  /// Spamming enableProxy resets TDLib proxy sockets mid-TlsInit (levlam
  /// ConnectionCreator) — SessionLog 22:52 + 16:01 boot soft@35s + mtg
  /// `cannot read client hello` (R14).
  DateTime? _fakeTlsQuietUntil;
  static const _fakeTlsQuiet = Duration(seconds: 35);
  /// Long-bg quiet must still cover FakeTLS TlsInit. R24 cut this to 18s;
  /// SessionLog 16:56 Ready@20.6s after soft-restart, SessionLog 17:15
  /// soft-restart every ~20s with 18s quiet aborted the handshake (R30).
  static const _fakeTlsQuietLongBg = Duration(seconds: 35);
  /// Debounced public-IP / geo recheck (VPN can keep kind=wifi).
  Timer? _proxyGeoRecheckTimer;
  DateTime? _lastProxyGeoRecheckAt;
  /// Active entry in [_activeProxyEndpoints] (failover / pingProxy pick this).
  int _proxyEndpointIndex = 0;
  DateTime? _lastProxyFailoverAt;
  /// Failover while already Ready (session up, media/CDN dead).
  DateTime? _lastMediaHealthFailoverAt;
  /// Hub-avatar 0B give-ups in the current window (triggers media failover).
  int _avatarGiveUpStreak = 0;
  DateTime? _avatarGiveUpWindowAt;
  /// Endpoint index → TDLib proxy id (kept so [pingProxy] can probe without
  /// add/remove storms).
  final Map<int, int> _endpointProxyIds = {};
  bool _proxyProbeInFlight = false;
  DateTime? _lastProxyProbeAt;
  /// Server-provided FakeTLS list (null → compile-time [TdlibConfig.proxyEndpoints]).
  List<TdlibProxyEndpoint>? _remoteProxyEndpoints;
  int? _remoteProxyEpoch;
  DateTime? _lastRemoteProxyFetchAt;
  static const _remoteProxyCacheKey = 'tdlib_mtproto_remote_proxies_v1';
  static const _remoteProxyFetchMinInterval = Duration(minutes: 5);
  /// Last endpoint that passed [pingProxy] on this device (`server:port`).
  static const _preferredProxyKey = 'tdlib_mtproto_preferred_endpoint_v1';

  List<TdlibChatPreview> get privateChats =>
      hubChats.where((c) => !c.isGroup && !c.isChannel).toList();

  /// Sum of unread messages in main-list chats that are not muted.
  ///
  /// Includes matched private DMs: the hub shows the FC DM row (TG synthetic
  /// hidden), but FC `unread_count` often stays 0 for Telegram-delivered
  /// messages — TDLib is the source of truth for those unreads.
  int get notifiedUnreadTotal {
    var total = 0;
    for (final c in hubChats) {
      if (isChatMuted(c.chatId)) continue;
      total += c.unreadCount;
    }
    return total;
  }

  /// Private DMs + groups + channels for the TG hub tab.
  /// Only chats that are actually on the main Telegram chat list
  /// (not archived / left / deleted / folder-only).
  List<TdlibChatPreview> get hubChats =>
      _hubChatsCache ??= _buildHubChats();

  List<TdlibChatPreview> _buildHubChats() {
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
        // Saved Messages (chat-with-self) merges into FC «Избранное».
        if (_myUserId != null && userId == _myUserId) continue;
        user = _users[userId];
        // Keep bots (e.g. BotFather) and service chats visible in the hub.
      } else if (typeName == 'chatTypeBasicGroup') {
        isGroup = true;
      } else if (typeName == 'chatTypeSupergroup') {
        isChannel = type['is_channel'] == true;
        isGroup = !isChannel;
        final sgId = (type['supergroup_id'] as num?)?.toInt();
        if (sgId != null) {
          // Never kick network from a getter used during build — schedule.
          if (!_supergroups.containsKey(sgId) &&
              !_supergroupFetchQueued.contains(sgId)) {
            scheduleMicrotask(() => _ensureSupergroupCached(sgId));
          }
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
      final miniBytes = _photoMinithumbnailBytesCached(id, chat);
      // Hub tiles are ~48dp × 3–3.5 DPR ≈ 160–170px — Telegram `small` is
      // often soft/muddy at that size; prefer `big` (and any already-cached).
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
      for (final fid in [bigId, smallId, resolvedId]) {
        if (fid == null || fid <= 0) continue;
        final path = _filePathCache[fid];
        if (path != null && path.isNotEmpty) {
          photoId = fid;
          photoPath = path;
          break;
        }
        photoId ??= fid;
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
          unreadCount: unreadCountFor(id),
          lastMessageOutgoing: lastOutgoing,
          lastMessageReadStatus: lastReadStatus,
        ),
      );
    }
    out.sort((a, b) => b.lastMessageDate.compareTo(a.lastMessageDate));
    return out;
  }

  /// Bumps when Telegram folder list / membership changes (hub watches this).
  int get chatFoldersEpoch => _chatFoldersEpoch;

  /// Hub may show FC+TG together once this is true (or auth will not load chats).
  bool get hubSurfaceReady => _hubSurfaceReady;

  void _setHubSurfaceReady(bool value) {
    if (_hubSurfaceReady == value) return;
    _hubSurfaceReady = value;
    notifyListeners();
  }

  void _setAuthPhase(TdlibAuthPhase next, {String? why}) {
    final prev = phase;
    phase = next;
    AppSessionDiagnostics.instance.setTgState(phase: next.name);
    if (prev == next) return;
    _slog('tg.auth', 'phase', {
      'from': prev.name,
      'to': next.name,
      'why': why,
      'err': errorMessage,
    });
    AppSessionDiagnostics.instance.auth('tg', next.name, {
      'from': prev.name,
      'why': why,
    });
  }

  /// Wait for the first [updateChatFolders] so folder chips land with the
  /// initial TG row paint. Times out if the account has no folders.
  Future<void> _awaitInitialFolderInfos() async {
    if (_chatFoldersEpoch > 0) return;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      if (_chatFoldersEpoch > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Manual user folders only (no Unread/Channels-style filters).
  List<TdlibChatFolderInfo> get manualChatFolders {
    final out = _chatFolderInfos.values.where((f) => f.isManual).toList();
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  String? chatFolderTitle(int folderId) => _chatFolderInfos[folderId]?.title;

  bool hasChatFolder(int folderId) => _chatFolderInfos.containsKey(folderId);

  bool isChatInFolder(int chatId, int folderId) {
    final set = _folderChatIds[folderId];
    if (set != null && set.contains(chatId)) return true;
    final details = _chatFolderDetails[folderId];
    if (details != null) {
      if (TdlibChatFolderCodec.intIdList(details['included_chat_ids'])
          .contains(chatId)) {
        return true;
      }
      if (TdlibChatFolderCodec.intIdList(details['pinned_chat_ids'])
          .contains(chatId)) {
        return true;
      }
    }
    final chat = _chats[chatId];
    if (chat == null) return false;
    return _folderIdsFromChat(chat).contains(folderId);
  }

  Set<int> chatIdsInFolder(int folderId) {
    final out = <int>{};
    final tracked = _folderChatIds[folderId];
    if (tracked != null) out.addAll(tracked);
    final details = _chatFolderDetails[folderId];
    if (details != null) {
      out.addAll(TdlibChatFolderCodec.intIdList(details['included_chat_ids']));
      out.addAll(TdlibChatFolderCodec.intIdList(details['pinned_chat_ids']));
    }
    for (final entry in _chats.entries) {
      if (_folderIdsFromChat(entry.value).contains(folderId)) {
        out.add(entry.key);
      }
    }
    return out;
  }

  /// Build a hub preview for any known chat (main list or folder-only).
  TdlibChatPreview? chatPreviewById(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return null;
    final type = chat['type'];
    if (type is! Map) return null;
    final typeName = type['@type']?.toString() ?? '';
    var userId = 0;
    var isGroup = false;
    var isChannel = false;
    Map<String, dynamic>? user;
    if (typeName == 'chatTypePrivate') {
      userId = (type['user_id'] as num?)?.toInt() ?? 0;
      if (userId <= 0) return null;
      user = _users[userId];
    } else if (typeName == 'chatTypeBasicGroup') {
      isGroup = true;
    } else if (typeName == 'chatTypeSupergroup') {
      isChannel = type['is_channel'] == true;
      isGroup = !isChannel;
    } else {
      return null;
    }
    final last = chat['last_message'];
    final miniBytes = _photoMinithumbnailBytes(chat);
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
    for (final id in [bigId, smallId, resolvedId]) {
      if (id == null || id <= 0) continue;
      final path = _filePathCache[id];
      if (path != null && path.isNotEmpty) {
        photoId = id;
        photoPath = path;
        break;
      }
      photoId ??= id;
    }
    final lastOutbox = _lastReadOutboxId[chatId] ??
        (chat['last_read_outbox_message_id'] as num?)?.toInt() ??
        0;
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
    return TdlibChatPreview(
      chatId: chatId,
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
      unreadCount: unreadCountFor(chatId),
      lastMessageOutgoing: lastOutgoing,
      lastMessageReadStatus: lastReadStatus,
    );
  }

  Future<int> createChatFolder({
    required String name,
    List<int> includedChatIds = const [],
  }) async {
    final c = _client;
    if (c == null || !isReady) {
      throw StateError('TDLib not ready');
    }
    Map<String, dynamic> res;
    try {
      res = await c.sendAwait({
        '@type': 'createChatFolder',
        'folder': TdlibChatFolderCodec.folderPayload(
          title: name,
          includedChatIds: includedChatIds,
        ),
      });
    } catch (e) {
      // Fallback for older tdjson builds that still use `title: string`.
      debugPrint('[tdlib] createChatFolder modern payload failed: $e');
      res = await c.sendAwait({
        '@type': 'createChatFolder',
        'folder': {
          '@type': 'chatFolder',
          'title': TdlibChatFolderCodec.truncateTitle(name),
          'icon': {'@type': 'chatFolderIcon', 'name': ''},
          'is_shareable': false,
          'pinned_chat_ids': <int>[],
          'included_chat_ids': includedChatIds,
          'excluded_chat_ids': <int>[],
          'exclude_muted': false,
          'exclude_read': false,
          'exclude_archived': true,
          'include_contacts': false,
          'include_non_contacts': false,
          'include_bots': false,
          'include_groups': false,
          'include_channels': false,
        },
      });
    }
    final id = _tdlibInt(res['id']);
    if (id == 0) {
      throw StateError('createChatFolder returned no id');
    }
    await _refreshChatFolderDetails(id);
    unawaited(_loadChatsForFolder(id));
    _chatFoldersEpoch++;
    notifyListeners();
    return id;
  }

  Future<void> renameChatFolder(int folderId, String name) async {
    final details = await _ensureChatFolderDetails(folderId);
    final included = TdlibChatFolderCodec.intIdList(details['included_chat_ids']);
    final c = _client;
    if (c == null || !isReady) return;
    await c.sendAwait({
      '@type': 'editChatFolder',
      'chat_folder_id': folderId,
      'folder': TdlibChatFolderCodec.folderPayload(
        title: name,
        includedChatIds: included,
        base: details,
      ),
    });
    await _refreshChatFolderDetails(folderId);
    _chatFoldersEpoch++;
    notifyListeners();
  }

  Future<void> deleteChatFolder(int folderId) async {
    final c = _client;
    if (c == null || !isReady) return;
    await c.sendAwait({
      '@type': 'deleteChatFolder',
      'chat_folder_id': folderId,
      'leave_chat_ids': <int>[],
    });
    _chatFolderInfos.remove(folderId);
    _chatFolderDetails.remove(folderId);
    _folderChatIds.remove(folderId);
    _chatFoldersEpoch++;
    notifyListeners();
  }

  Future<void> setChatIncludedInFolder({
    required int folderId,
    required int chatId,
    required bool included,
  }) async {
    final details = await _ensureChatFolderDetails(folderId);
    final set = TdlibChatFolderCodec.intIdList(details['included_chat_ids'])
        .toSet();
    final pinned = TdlibChatFolderCodec.intIdList(details['pinned_chat_ids'])
        .toSet();
    if (included) {
      set.add(chatId);
    } else {
      set.remove(chatId);
      pinned.remove(chatId);
    }
    final title = TdlibChatFolderCodec.titleFromInfo(details);
    final infoTitle = _chatFolderInfos[folderId]?.title ?? title;
    final c = _client;
    if (c == null || !isReady) return;
    await c.sendAwait({
      '@type': 'editChatFolder',
      'chat_folder_id': folderId,
      'folder': TdlibChatFolderCodec.folderPayload(
        title: infoTitle.isNotEmpty ? infoTitle : title,
        includedChatIds: set.toList(),
        pinnedChatIds: pinned.toList(),
        base: details,
      ),
    });
    final tracked = _folderChatIds.putIfAbsent(folderId, () => <int>{});
    if (included) {
      tracked.add(chatId);
    } else {
      tracked.remove(chatId);
    }
    await _refreshChatFolderDetails(folderId);
    _chatFoldersEpoch++;
    notifyListeners();
  }

  Future<void> replaceFolderIncludedChats({
    required int folderId,
    required List<int> includedChatIds,
  }) async {
    final details = await _ensureChatFolderDetails(folderId);
    final title = TdlibChatFolderCodec.titleFromInfo(details);
    final infoTitle = _chatFolderInfos[folderId]?.title ?? title;
    final pinned = TdlibChatFolderCodec.intIdList(details['pinned_chat_ids'])
        .where(includedChatIds.contains)
        .toList();
    final c = _client;
    if (c == null || !isReady) return;
    await c.sendAwait({
      '@type': 'editChatFolder',
      'chat_folder_id': folderId,
      'folder': TdlibChatFolderCodec.folderPayload(
        title: infoTitle.isNotEmpty ? infoTitle : title,
        includedChatIds: includedChatIds,
        pinnedChatIds: pinned,
        base: details,
      ),
    });
    _folderChatIds[folderId] = includedChatIds.toSet();
    await _refreshChatFolderDetails(folderId);
    _chatFoldersEpoch++;
    notifyListeners();
  }

  Set<int> _folderIdsFromChat(Map chat) {
    final positions = chat['positions'];
    if (positions is! List) return const {};
    final out = <int>{};
    for (final p in positions) {
      if (p is! Map) continue;
      if (!_tdlibInt64NonZero(p['order'])) continue;
      final id = TdlibChatFolderCodec.folderIdFromPositionList(p['list']);
      if (id != null && id != 0) out.add(id);
    }
    return out;
  }

  void _reindexFolderMembership(int chatId) {
    final chat = _chats[chatId];
    // Don't wipe ids that still come from getChatFolder included/pinned —
    // positions alone are incomplete until loadChats(folder) finishes, and
    // updateChatPosition used to clobber other folders' chatListFolder slots.
    for (final entry in _folderChatIds.entries) {
      final folderId = entry.key;
      final set = entry.value;
      final inDetails = () {
        final details = _chatFolderDetails[folderId];
        if (details == null) return false;
        return TdlibChatFolderCodec.intIdList(details['included_chat_ids'])
                .contains(chatId) ||
            TdlibChatFolderCodec.intIdList(details['pinned_chat_ids'])
                .contains(chatId);
      }();
      final inPositions =
          chat != null && _folderIdsFromChat(chat).contains(folderId);
      if (inDetails || inPositions) {
        set.add(chatId);
      } else {
        set.remove(chatId);
      }
    }
    if (chat == null) return;
    for (final folderId in _folderIdsFromChat(chat)) {
      _folderChatIds.putIfAbsent(folderId, () => <int>{}).add(chatId);
    }
  }

  /// Fetch missing [chat] objects so hub rows can render folder membership.
  Future<void> ensureFolderChatsLoaded(int folderId) async {
    if (!isReady || folderId <= 0) return;
    await _refreshChatFolderDetails(folderId);
    unawaited(_loadChatsForFolder(folderId));
    // Don't await the full loadChats loop — getChat for known ids fills the
    // hub immediately even if the folder chat list is still paging in.
    final ids = chatIdsInFolder(folderId).toList();
    var fetched = 0;
    for (final chatId in ids) {
      if (_chats.containsKey(chatId)) continue;
      final ok = await _fetchChatIntoCache(chatId);
      if (ok) fetched++;
      if (fetched >= 80) break;
    }
    if (fetched > 0 || ids.isNotEmpty) {
      _chatFoldersEpoch++;
      notifyListeners();
    }
  }

  Future<bool> _fetchChatIntoCache(int chatId) async {
    final c = _client;
    if (c == null || chatId == 0) return false;
    try {
      final raw = await c.sendAwait({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      if (raw['@type'] != 'chat') return false;
      final chat = Map<String, dynamic>.from(raw);
      _chats[chatId] = chat;
      _syncChatOrderMembership(chatId);
      _reindexFolderMembership(chatId);
      _resolveChatAvatarFileId(chat);
      return true;
    } catch (e) {
      debugPrint('[tdlib] getChat($chatId) for folder failed: $e');
      return false;
    }
  }

  Future<void> _onChatFoldersUpdate(Map<String, dynamic> update) async {
    final raw = update['chat_folders'];
    final nextInfos = <int, TdlibChatFolderInfo>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final id = _tdlibInt(map['id']);
        if (id == 0) continue;
        final title = TdlibChatFolderCodec.titleFromInfo(map);
        // Assume manual until details arrive; hide if details say otherwise.
        final cached = _chatFolderDetails[id];
        final isManual = cached == null
            ? true
            : TdlibChatFolderCodec.isManualFolder(cached);
        nextInfos[id] = TdlibChatFolderInfo(
          id: id,
          title: title.isNotEmpty
              ? title
              : (_chatFolderInfos[id]?.title ?? 'Папка'),
          isManual: isManual,
        );
      }
    }
    final removed = _chatFolderInfos.keys
        .where((id) => !nextInfos.containsKey(id))
        .toList();
    for (final id in removed) {
      _chatFolderDetails.remove(id);
      _folderChatIds.remove(id);
    }
    _chatFolderInfos
      ..clear()
      ..addAll(nextInfos);
    _chatFoldersEpoch++;
    notifyListeners();
    for (final id in nextInfos.keys) {
      unawaited(ensureFolderChatsLoaded(id));
    }
  }

  Future<Map<String, dynamic>> _ensureChatFolderDetails(int folderId) async {
    final cached = _chatFolderDetails[folderId];
    if (cached != null) return cached;
    return _refreshChatFolderDetails(folderId);
  }

  Future<Map<String, dynamic>> _refreshChatFolderDetails(int folderId) async {
    final c = _client;
    if (c == null || !isReady) {
      return _chatFolderDetails[folderId] ?? <String, dynamic>{};
    }
    try {
      final res = await c.sendAwait({
        '@type': 'getChatFolder',
        'chat_folder_id': folderId,
      });
      final details = Map<String, dynamic>.from(res);
      _chatFolderDetails[folderId] = details;
      final title = TdlibChatFolderCodec.titleFromInfo(details);
      final isManual = TdlibChatFolderCodec.isManualFolder(details);
      final prev = _chatFolderInfos[folderId];
      _chatFolderInfos[folderId] = TdlibChatFolderInfo(
        id: folderId,
        title: title.isNotEmpty ? title : (prev?.title ?? 'Папка'),
        isManual: isManual,
      );
      final included = TdlibChatFolderCodec.intIdList(details['included_chat_ids']);
      final pinned = TdlibChatFolderCodec.intIdList(details['pinned_chat_ids']);
      final set = _folderChatIds.putIfAbsent(folderId, () => <int>{});
      set.addAll(included);
      set.addAll(pinned);
      _chatFoldersEpoch++;
      notifyListeners();
      return details;
    } catch (e) {
      debugPrint('[tdlib] getChatFolder($folderId) failed: $e');
      return _chatFolderDetails[folderId] ?? <String, dynamic>{};
    }
  }

  Future<void> _loadChatsForFolder(int folderId) async {
    final c = _client;
    if (c == null || !isReady) return;
    var timeoutStreak = 0;
    for (var i = 0; i < 20; i++) {
      try {
        await c.sendAwait(
          {
            '@type': 'loadChats',
            'chat_list': {
              '@type': 'chatListFolder',
              'chat_folder_id': folderId,
            },
            'limit': 100,
          },
          timeout: const Duration(seconds: 30),
        );
        timeoutStreak = 0;
      } on TdlibApiException catch (e) {
        if (e.code == 404) break;
        debugPrint('[tdlib] loadChats folder=$folderId failed: $e');
        break;
      } on TimeoutException catch (e) {
        timeoutStreak++;
        debugPrint('[tdlib] loadChats folder=$folderId timeout: $e');
        if (timeoutStreak >= 3) break;
      } catch (e) {
        debugPrint('[tdlib] loadChats folder=$folderId failed: $e');
        break;
      }
    }
    notifyListeners();
  }

  /// Sharp avatars for hub rows currently on screen (not the whole 500+ list).
  /// No-op while a chat is open so message media keeps the download slot.
  void prefetchVisibleHubAvatars(
    Iterable<int> chatIds, {
    int limit = 16,
  }) {
    if (_openChatId != null) {
      _mediaLog('hub-avatar skip: openChat=$_openChatId');
      return;
    }
    if (_enabledProxyId != null) {
      _mediaLog('hub-avatar skip: proxy exclusive');
      return;
    }
    if (isUiScrollBusy) {
      return;
    }
    if (!_tdlibReadyForMedia) {
      _mediaLog('hub-avatar skip: conn=$_connectionState');
      return;
    }

    // Cap how many hub-avatar jobs sit waiting — otherwise scroll floods the
    // queue while the in-flight CDN downloads sit at 0B.
    final hubQueued = _downloadQueue
        .where((j) => j.reason == 'hub-avatar')
        .length;
    final hubInflight = _downloadInFlight.where((id) {
      final r = _downloadTrace[id]?.reason ?? '';
      return r == 'hub-avatar';
    }).length;
    final hubBudget = limit - hubQueued - hubInflight;
    if (hubBudget <= 0) {
      _mediaLog(
        'hub-avatar budget-full queued=$hubQueued inflight=$hubInflight '
        '${_downloadQueueStats()}',
      );
      _pumpDownloadQueue();
      return;
    }

    var n = 0;
    var alreadyCached = 0;
    var missingId = 0;
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

      // Prefer big for hub (~48dp × high DPR); skip cooled/poisoned CDN ids.
      final photoId = _pickHubAvatarFileId(chat, user: user);
      if (photoId == null || photoId <= 0) {
        missingId++;
        // Diagnose once per chat: minithumb without small/big means we never
        // queue a download and the hub stays soft forever.
        if (!_hubAvatarMissingLogged.contains(chatId)) {
          _hubAvatarMissingLogged.add(chatId);
          final photo = chat['photo'];
          final keys = photo is Map
              ? photo.keys.map((k) => k.toString()).join(',')
              : 'null';
          final small = photo is Map ? photo['small'] : null;
          final smallId = small is Map ? small['id'] : null;
          final hasMini = photo is Map && photo['minithumbnail'] is Map;
          _mediaLog(
            'hub-avatar missing-id chat=$chatId photoKeys=$keys '
            'smallId=$smallId hasMini=$hasMini '
            'type=${(chat['type'] as Map?)?['@type']}',
          );
        }
        // Poisoned CDN ids still look "present" to getChat — refresh for a
        // new file_id instead of the missing-photo path.
        final rawId = _tdlibPhotoFileId(chat['photo'], 'big') ??
            _tdlibPhotoFileId(chat['photo'], 'small');
        if (rawId != null &&
            _hubAvatarPoisonFileIds.contains(rawId) &&
            !isUiScrollBusy) {
          unawaited(
            _forceRefreshHubAvatarAfterGiveUp(
              chatId: chatId,
              excludeFileIds: {..._hubAvatarPoisonFileIds},
            ),
          );
        } else if (!isUiScrollBusy) {
          _refreshChatPhotoIfMissing(chatId);
        }
        continue;
      }
      if (_filePathCache.containsKey(photoId)) {
        alreadyCached++;
        continue;
      }
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
    _mediaLog(
      'hub-avatar prefetch queued=$n cached=$alreadyCached '
      'missingId=$missingId visible=${chatIds.length} '
      'budget=$hubBudget ${_downloadQueueStats()}',
    );
    if (n > 0) _pumpDownloadQueue();
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
    final keep = _tdlibInt64NonZero(position['order']);

    final existing = chat['positions'];
    final next = <Map<String, dynamic>>[];
    if (existing is List) {
      for (final p in existing) {
        if (p is! Map) continue;
        // Match main/archive by @type, folder lists by folder id — otherwise
        // one chatListFolder update wiped every other folder position.
        if (_sameChatList(p['list'], list)) continue;
        next.add(Map<String, dynamic>.from(p));
      }
    }
    if (keep) {
      next.add(Map<String, dynamic>.from(position));
    }
    chat['positions'] = next;
    _syncChatOrderMembership(chatId);
    _reindexFolderMembership(chatId);
  }

  static bool _sameChatList(dynamic a, dynamic b) {
    if (a is! Map || b is! Map) return false;
    final ta = a['@type']?.toString() ?? '';
    final tb = b['@type']?.toString() ?? '';
    if (ta != tb) return false;
    if (ta == 'chatListFolder') {
      return _tdlibInt(a['chat_folder_id']) == _tdlibInt(b['chat_folder_id']);
    }
    return true;
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
          _notifyUi();
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

  bool isPrivateChat(int chatId) {
    final type = _chats[chatId]?['type'];
    if (type is! Map) return false;
    final name = type['@type']?.toString() ?? '';
    return name == 'chatTypePrivate' || name == 'chatTypeSecret';
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
    final soft = m.photoSizeType == null ||
        m.photoSizeType == 'm' ||
        m.photoSizeType == 's';
    // Soft primary path must not hide a sharper fallback already on disk —
    // that left album cells blurry until the viewer rebound the path.
    if (soft) {
      for (final id in m.photoFallbackFileIds) {
        final p = cachedFilePath(id);
        if (p != null && p.isNotEmpty) return p;
      }
    }
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

  /// Bytes received so far for an in-flight / traced download (0 if unknown).
  int fileDownloadedBytes(int fileId) => _downloadTrace[fileId]?.lastBytes ?? 0;

  /// Expected total size for a traced download (0 if unknown).
  int fileExpectedSize(int fileId) =>
      _downloadTrace[fileId]?.expectedSize ?? 0;

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
      LinkPreviewService.instance.deferNetworkFetches = true;
      return;
    }
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    if (LinkPreviewService.instance.linkPreviewGateOpen) {
      LinkPreviewService.instance.deferNetworkFetches = false;
    }
    _flushPendingUiNotify();
  }

  /// True while hub/conversation scroll/fling should suppress media + rebuilds.
  bool get isUiScrollBusy {
    if (!_uiScrollBusy) return false;
    final until = _uiScrollBusyUntil;
    if (until != null && DateTime.now().isBefore(until)) return true;
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    return false;
  }

  @override
  void notifyListeners() {
    if (_tearingDown) return;
    _hubChatsCache = null;
    if (TgJankLog.focusChatId != null && _openChatId == TgJankLog.focusChatId) {
      final tip = StackTrace.current
          .toString()
          .split('\n')
          .map((l) => l.trim())
          .where(
            (l) =>
                l.contains('telegram_tdlib') ||
                l.contains('TelegramTdlib') ||
                l.contains('_notify'),
          )
          .take(3)
          .join(' ← ');
      TgJankLog.notify(reason: tip.isEmpty ? 'ChangeNotifier' : tip);
    }
    if (!hasListeners) return;
    super.notifyListeners();
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
  /// (auth / new messages). While the open conversation is scrolling/flinging,
  /// defer ALL non-immediate notifies — any rebuild mid-ballistic feels like
  /// "inertia won't start" in media-heavy groups.
  ///
  /// While MTProto is Connecting (or just after soft-restart) use a longer
  /// coalesce — SessionLog showed ~200 NOTIFY/min from `_onUpdate` storms.
  void _notifyUi({bool immediate = false, bool media = false}) {
    if (immediate) {
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = null;
      _uiNotifyPending = false;
      notifyListeners();
      return;
    }
    if (_deferMediaUiNotify) {
      _uiNotifyPending = true;
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = Timer(const Duration(milliseconds: 160), () {
        _uiNotifyTimer = null;
        if (_deferMediaUiNotify) {
          // Still flinging — wait again.
          _notifyUi(media: media);
          return;
        }
        _flushPendingUiNotify();
      });
      return;
    }
    final coalesce = !_tdlibReadyForMedia
        ? const Duration(milliseconds: 200)
        : const Duration(milliseconds: 48);
    _uiNotifyPending = true;
    _uiNotifyTimer ??= Timer(coalesce, () {
      _uiNotifyTimer = null;
      _flushPendingUiNotify();
    });
  }

  /// Hub-row / other-chat noise must not rebuild an open conversation.
  /// Busy groups (ТП НСИС…) otherwise hitch scroll+buttons on every
  /// updateChatLastMessage / updateUserStatus from the rest of the account.
  void _notifyListenersForChat(int? chatId, {bool hubOnly = false}) {
    final openId = _openChatId;
    if (openId != null) {
      if (hubOnly) return;
      if (chatId != null && chatId != openId) return;
      // Open-chat updates: coalesce and defer while flinging.
      _notifyUi();
      return;
    }
    // Hub: same coalesce/scroll-busy gate — avatar completes + last-message
    // spam must not rebuild the whole list mid-fling.
    _notifyUi();
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

  /// Drop queued avatars. With FakeTLS, soft-release leaves TDLib still
  /// pulling the avatar on the wire and starves the focus media slot — cancel.
  Future<void> _purgeAvatarDownloads() async {
    final dropQueued = _downloadQueue
        .where(
          (j) =>
              j.reason == 'peer-avatar' ||
              j.reason == 'avatar' ||
              j.reason == 'hub-avatar' ||
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
    final hardCancel = _enabledProxyId != null;
    var cancelled = 0;
    for (final id in _downloadInFlight.toList()) {
      final t = _downloadTrace[id];
      final reason = t?.reason ?? '';
      if (reason == 'peer-avatar' ||
          reason == 'avatar' ||
          reason == 'hub-avatar' ||
          reason.contains('peer-avatar') ||
          reason.contains('avatar')) {
        _downloadInFlight.remove(id);
        _downloadBackgroundIds.remove(id);
        _downloadActive = (_downloadActive - 1).clamp(0, 100);
        _downloadTrace.remove(id);
        _fileDownloadProgress.remove(id);
        if (hardCancel) {
          await _cancelTdlibDownload(id);
          cancelled++;
          _mediaLog('purge-avatar-hard file=$id reason=$reason');
        } else {
          _mediaLog('purge-avatar-soft file=$id reason=$reason');
        }
      }
    }
    if (cancelled > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  void _queueAvatarDownload(int fileId, {int? chatId}) {
    if (fileId <= 0) return;
    // Don't compete with exclusive focus downloads inside an open chat.
    if (_openChatId != null) return;
    // FakeTLS: hub-avatar downloadFile acks at 0B forever and monopolizes the
    // single slot for tens of seconds before a channel can even start media
    // (Shariy: 40s of hub-avatar STALL-0B, then focus also 0B).
    if (_enabledProxyId != null) {
      _mediaLog('hub-avatar skip: proxy exclusive file=$fileId chat=$chatId');
      return;
    }
    if (_filePathCache.containsKey(fileId)) return;
    if (_downloadInFlight.contains(fileId) || _downloadQueued.contains(fileId)) {
      return;
    }
    _queueFileDownload(
      fileId,
      priority: prioHubAvatar,
      background: true,
      chatId: chatId,
      reason: 'hub-avatar',
    );
  }

  void _mediaLog(String msg) {
    debugPrint('[tdlib-media] $msg');
    SessionLog.instance.trace('tg.media', msg);
  }

  void _slog(String cat, String evt, [Map<String, Object?> fields = const {}]) {
    SessionLog.instance.event(cat, evt, {
      if (_openChatId != null) 'openChatId': _openChatId,
      if (_activeOpenToken != null) 'openToken': _activeOpenToken,
      'conn': _connectionState,
      'net': _networkKind.name,
      'proxyOn': _enabledProxyId != null,
      ...fields,
    });
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
    _ensureProxyPlaneHeartbeat();
  }

  void _ensureProxyPlaneHeartbeat() {
    _proxyPlaneTimer ??= Timer.periodic(
      const Duration(seconds: 12),
      (_) => _logProxyPlane(),
    );
  }

  /// Compact proxy/media plane snapshot for VPS↔client correlation.
  void _logProxyPlane() {
    if (!SessionLog.enabled) return;
    if (_enabledProxyId == null &&
        _downloadInFlight.isEmpty &&
        _downloadQueue.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final inflight = <Map<String, Object?>>[];
    for (final id in _downloadInFlight) {
      final t = _downloadTrace[id];
      if (t == null) {
        inflight.add({'fileId': id});
        continue;
      }
      final sampleAt = t.sampleAt;
      final bytesDelta5s = sampleAt == null
          ? t.lastBytes
          : (t.lastBytes - t.sampleBytes);
      if (sampleAt == null || now.difference(sampleAt) >= const Duration(seconds: 5)) {
        t.sampleBytes = t.lastBytes;
        t.sampleAt = now;
      }
      final started = t.startedAt ?? t.enqueuedAt;
      inflight.add({
        'fileId': id,
        'reason': t.reason,
        'downloaded': t.lastBytes,
        'size': t.expectedSize,
        'offset': t.offset,
        'bytesDelta5s': bytesDelta5s,
        'elapsedMs': now.difference(started).inMilliseconds,
        'acked': t.downloadAcked,
      });
    }
    final ep = _activeProxyEndpoints.isEmpty
        ? null
        : _activeProxyEndpoints[
            _proxyEndpointIndex.clamp(0, _activeProxyEndpoints.length - 1)];
    _slog('tg.proxy', 'plane', {
      'lastPongMs': _lastPongMs,
      'lastPongAgeMs': _lastPongAt == null
          ? null
          : now.difference(_lastPongAt!).inMilliseconds,
      'proxyId': _enabledProxyId,
      'endpoint': ep?.label,
      'slots': '$_downloadActive/$_downloadSlotLimit',
      'queued': _downloadQueue.length,
      'inflight': inflight,
      'mediaReady': _tdlibReadyForMedia,
      'fg': _appInForeground,
    });
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
      final isBareEnsure = t.reason == 'ensure' ||
          t.reason == 'peer-avatar' ||
          t.reason == 'avatar' ||
          t.reason.startsWith('ensure:');
      final proxyOn = _useMtprotoProxy && _enabledProxyId != null;
      final mediaReady = _tdlibReadyForMedia;
      final isSmallFile = t.expectedSize > 0 &&
          t.expectedSize <= _stallSmallFileBytes &&
          !isVideo;
      final zeroLimit = (isHubAvatar || isBareEnsure)
          ? _stallZeroBytesHubAvatar
          : (proxyOn && mediaReady && isSmallFile)
              ? _stallZeroBytesThumbProxyReady
              : proxyOn
                  ? (mediaReady
                      ? (isVideo
                          ? _stallZeroBytesVideoProxyReady
                          : (isFocus
                              ? _stallZeroBytesFocusProxyReady
                              : _stallZeroBytesProxyReady))
                      : (isVideo
                          ? _stallZeroBytesVideoProxy
                          : (isFocus
                              ? _stallZeroBytesFocusProxy
                              : _stallZeroBytesProxy)))
                  : (isVideo
                      ? _stallZeroBytesVideo
                      : (isFocus ? _stallZeroBytesFocus : _stallZeroBytes));
      final progressLimit = proxyOn
          ? (mediaReady
              ? _stallProgressIdleProxyReady
              : _stallProgressIdleProxy)
          : _stallProgressIdle;
      // Zero-byte hang, mid-file hang, OR bytes-full without completed flag
      // (proxy/CDN often leaves hub-avatar at 100% with no path forever).
      final stalledZero = idle >= zeroLimit && t.lastBytes <= 0;
      final stalledProgress = idle >= progressLimit &&
          t.lastBytes > 0 &&
          (t.expectedSize <= 0 || t.lastBytes < t.expectedSize);
      final fullHung = t.expectedSize > 0 &&
          t.lastBytes >= t.expectedSize &&
          idle >= const Duration(seconds: 2);
      final stalled = stalledZero || stalledProgress || fullHung;
      final sampleAt = t.sampleAt;
      final bytesDelta5s = sampleAt == null
          ? t.lastBytes
          : (t.lastBytes - t.sampleBytes);
      if (sampleAt == null ||
          now.difference(sampleAt) >= const Duration(seconds: 5)) {
        t.sampleBytes = t.lastBytes;
        t.sampleAt = now;
      }
      _mediaLog(
        'watchdog file=$id reason=${t.reason} '
        'prio=${t.priority} bg=${t.background} chat=${t.chatId} '
        'elapsed=${_fmtDur(elapsed)} idle=${_fmtDur(idle)} '
        'got=${_fmtBytes(t.lastBytes)}/'
        '${t.expectedSize > 0 ? _fmtBytes(t.expectedSize) : '?'} '
        'rate=${rate > 0 ? '${_fmtBytes(rate.round())}/s' : '?'} '
        'delta5s=${_fmtBytes(bytesDelta5s)} offset=${t.offset} '
        'net=${_networkKind.name} '
        'acked=${t.downloadAcked} remote=${t.remoteUniqueId} '
        '${stalledZero ? 'STALL-0B?' : ''}'
        '${stalledProgress ? 'STALL-IDLE?' : ''}'
        '${fullHung ? 'STALL-FULL?' : ''}',
      );
      if (stalled) {
        _slog('tg.media', stalledZero ? 'stall_0b' : 'stall_idle', {
          'fileId': id,
          'reason': t.reason,
          'downloaded': t.lastBytes,
          'size': t.expectedSize,
          'offset': t.offset,
          'elapsedMs': elapsed.inMilliseconds,
          'idleMs': idle.inMilliseconds,
          'bytesDelta5s': bytesDelta5s,
          'acked': t.downloadAcked,
          'chatId': t.chatId,
        });
      }
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
        // Never stall-defer waiting for connectionStateReady (td#1176 /
        // proxy-parity). Holding a slot for 40m+ with 0B was the FC bug.
        // pingProxy is NOT a media cure — only cancel / recover / free slot.
        if (!_canStartNetworkDownload || isHubAvatar || isBareEnsure) {
          unawaited(
            _dropInFlightWhileNotReady(
              id,
              requeue: !isHubAvatar &&
                  !isBareEnsure &&
                  (isFocus || t.reason.startsWith('stall-')),
            ),
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
    // pingProxy is for endpoint selection (see [_probeBestProxyEndpointIndex]),
    // not for curing 0B file stalls (levlam / td#2585). Never use it on
    // hub-avatar / media recover paths.
    if (why.startsWith('hub-avatar') || why.startsWith('stall')) {
      _mediaLog('cdn-nudge skip why=$why (not used for media stalls)');
      return;
    }
    final c = _client;
    final proxyId = _enabledProxyId;
    if (c == null || proxyId == null || !_tdlibReadyForMedia) {
      _mediaLog('cdn-nudge skip why=$why (no proxy/ready)');
      return;
    }
    try {
      final ping = await c.sendAwait(
        {'@type': 'pingProxy', 'proxy_id': proxyId},
        timeout: const Duration(milliseconds: 800),
      );
      final sec = (ping['seconds'] as num?)?.toDouble();
      if (sec != null && sec >= 0) {
        _lastPongMs = (sec * 1000).round();
        _lastPongAt = DateTime.now();
      }
      _mediaLog('cdn-nudge pingProxy ok why=$why seconds=$sec');
    } catch (e) {
      _mediaLog('cdn-nudge pingProxy soft-fail why=$why err=$e');
    }
  }

  /// Free a hung download slot (no pingProxy). Optionally requeue for later.
  Future<void> _dropInFlightWhileNotReady(
    int fileId, {
    bool requeue = false,
  }) async {
    if (!_downloadInFlight.contains(fileId)) return;
    final t = _downloadTrace[fileId];
    final reason = t?.reason ?? '';
    final priority = t?.priority ?? prioFocused;
    final chatId = t?.chatId ?? _openChatId;
    _mediaLog(
      'stall-drop-zombie file=$fileId reason=$reason '
      'conn=$_connectionState requeue=$requeue',
    );
    _slog('tg.media', 'stall_drop_zombie', {
      'fileId': fileId,
      'reason': reason,
      'requeue': requeue,
      'downloaded': t?.lastBytes,
    });
    _downloadInFlight.remove(fileId);
    _downloadBackgroundIds.remove(fileId);
    _downloadActive = (_downloadActive - 1).clamp(0, 100);
    _downloadTrace.remove(fileId);
    _fileDownloadProgress.remove(fileId);
    await _cancelTdlibDownload(fileId);
    if (requeue && reason.isNotEmpty) {
      _queueFileDownload(
        fileId,
        priority: priority,
        background: false,
        chatId: chatId,
        reason: reason.startsWith('stall-retry:')
            ? reason
            : 'stall-retry:$reason',
      );
    }
    _pumpDownloadQueue();
    notifyListeners();
  }

  /// Cancel a hung download and free the slot.
  ///
  /// Prefer switching to a smaller photo size for a 0B hang. For mid-file
  /// idle hangs, cancel + re-downloadFile (TDLib resumes) — recommended by
  /// TDLib maintainers instead of waiting forever on synchronous downloads.
  Future<void> _recoverStalledDownload(int fileId) async {
    if (!_downloadInFlight.contains(fileId)) return;
    final tEarly = _downloadTrace[fileId];
    final reasonEarly = tEarly?.reason ?? '';
    final isHubAvatarEarly = reasonEarly == 'hub-avatar';
    if (!_canStartNetworkDownload && !isHubAvatarEarly) {
      // Auth/offline: free slot only — do not wait on connectionState.
      unawaited(_dropInFlightWhileNotReady(fileId, requeue: true));
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
    // Hub-avatar 0B: free the slot immediately, then try alt size (big↔small)
    // once and a single delayed requeue — otherwise blurry/letter tiles stick
    // forever because prefetchKey does not change while the hub is idle.
    if (isAvatar && (reason == 'hub-avatar' || _openChatId != null) &&
        !hadProgress) {
      final chatId = t?.chatId;
      final attempts = _hubAvatarStallAttempts[fileId] ?? 0;
      final remoteUnique = t?.remoteUniqueId ?? '';
      _mediaLog(
        'stall-drop-avatar file=$fileId reason=$reason '
        'chat=$chatId attempt=$attempts',
      );
      _downloadInFlight.remove(fileId);
      _downloadBackgroundIds.remove(fileId);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(fileId);
      _fileDownloadProgress.remove(fileId);
      await _cancelTdlibDownload(fileId);
      if (reason == 'hub-avatar' && _tdlibReadyForMedia) {
        if (remoteUnique.isNotEmpty) {
          _hubAvatarPoisonRemotes.add(remoteUnique);
        }
        _hubAvatarPoisonFileIds.add(fileId);
        await _recoverHubAvatarAfterStall(
          fileId: fileId,
          chatId: chatId,
          attempts: attempts,
        );
      }
      _pumpDownloadQueue();
      notifyListeners();
      return;
    }
    if (!_canStartNetworkDownload) {
      unawaited(_dropInFlightWhileNotReady(fileId, requeue: true));
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

    final prevFallbackAttempt = t?.sizeFallbackAttempt ?? 0;
    final recoverAttempted = t?.recoverAttempted == true;
    final proxyOn = _useMtprotoProxy && _enabledProxyId != null;
    final isFocusish = reason.contains('focus:') ||
        reason.startsWith('tap:') ||
        reason.startsWith('stall-retry:') ||
        reason.startsWith('stall-fallback:') ||
        reason.startsWith('stall-lastchance:');

    // FakeTLS 0B: first recover = cancel + same fileId (td#3017).
    // Use chatId from trace — do not require _openChatId (SessionLog 20:27
    // openChat=null skipped same-file and jumped to size-fallback).
    final chatForRequeue = chatId ?? _openChatId;
    if (proxyOn &&
        !hadProgress &&
        !recoverAttempted &&
        isFocusish &&
        !reason.startsWith('stall-fallback:') &&
        !reason.startsWith('stall-lastchance:') &&
        chatForRequeue != null) {
      _mediaLog(
        'stall-recover-same file=$fileId reason=$reason '
        'conn=$_connectionState (proxy 0B → cancel+requeue)',
      );
      _downloadInFlight.remove(fileId);
      _downloadBackgroundIds.remove(fileId);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(fileId);
      _fileDownloadProgress.remove(fileId);
      await _cancelTdlibDownload(fileId);
      // Do NOT soft-nudge on Ready+0B here — SessionLog 21:19 show
      // stall-0B-ready → Ready→Connecting with still 0B. CDN→origin next;
      // hop probe only after ladder give-up (R10 / evenIfReady).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // First attempt is CDN (offset=0); after 0B force one origin try.
      if (_enabledProxyId != null &&
          !_downloadTriedBypassCdn.contains(fileId)) {
        _downloadForceBypassCdnOnce.add(fileId);
      }
      _queueFileDownload(
        fileId,
        priority: prioFocused,
        background: false,
        chatId: chatForRequeue,
        reason: reason.startsWith('stall-retry:')
            ? reason
            : 'stall-retry:$reason',
      );
      _downloadTrace[fileId]?.recoverAttempted = true;
      _downloadTrace[fileId]?.sizeFallbackAttempt = prevFallbackAttempt;
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
      'conn=$_connectionState retried=$recoverAttempted',
    );
    // Mark out of flight first so cancel's updateFile doesn't double-release.
    _downloadInFlight.remove(fileId);
    _downloadBackgroundIds.remove(fileId);
    _downloadActive = (_downloadActive - 1).clamp(0, 100);
    final focusMsgId = () {
      // Strip diagnostic suffixes (e.g. |cdn-bypass-offset1) before parsing.
      final clean = reason.split('|').first;
      // tap:photo:/tap:video: suffix is FILE id — never a message id
      // (SessionLog: openMessageContent msg=16518 → "Message not found").
      if (RegExp(r'^tap:(?:photo|video):\d+').hasMatch(clean) ||
          RegExp(r'^stall-fallback:tap:(?:photo|video):\d+').hasMatch(clean)) {
        return _focusMessageId;
      }
      final m = RegExp(
        r'(?:focus(?:-tail)?:|stall-fallback:|stall-retry:|stall-lastchance:|auto:video:|neighbor:)(\d+)',
      ).firstMatch(clean);
      if (m != null) return int.tryParse(m.group(1)!);
      return _focusMessageId;
    }();
    _downloadTrace.remove(fileId);
    _fileDownloadProgress.remove(fileId);
    await _cancelTdlibDownload(fileId);
    // Fire-and-forget nudge — never block stall-fallback on Pong timeout.
    unawaited(_nudgeCdnAfterStall('stall:$fileId'));
    // Give TDLib time to drop the stuck CDN request before re-downloadFile.
    await Future<void>.delayed(const Duration(milliseconds: 200));
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
      // CDN path stalled → try origin-only once on the next downloadFile.
      if (_enabledProxyId != null &&
          !_downloadTriedBypassCdn.contains(fallbackId)) {
        _downloadForceBypassCdnOnce.add(fallbackId);
      }
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

    // R22: small thumbs — skip lastchance (another ~35s 0B). One CDN + one
    // origin is enough; free the exclusive FakeTLS slot.
    final smallThumb = (t?.expectedSize ?? 0) > 0 &&
        (t!.expectedSize <= _stallSmallFileBytes) &&
        _enabledProxyId != null &&
        !reason.contains('video:');

    // Last chance: only for focus/tap — never for neighbors / small thumbs.
    if (!smallThumb &&
        chatId != null &&
        focusMsgId != null &&
        focusMsgId > 0 &&
        !reason.startsWith('stall-lastchance:') &&
        (reason.contains('focus:') ||
            reason.startsWith('tap:') ||
            reason.startsWith('stall-retry:')) &&
        prevFallbackAttempt < 3) {
      await _openMessageContent(chatId, focusMsgId);
      await _yieldSlotsToFocus({fallbackId ?? fileId});
      final retryId = fallbackId ?? fileId;
      // First stall → origin (offset=1). If origin already tried, leave
      // forceBypass unset so the next downloadFile uses CDN (offset=0).
      final wantOrigin = _enabledProxyId != null &&
          !_downloadTriedBypassCdn.contains(retryId);
      if (wantOrigin) {
        _downloadForceBypassCdnOnce.add(retryId);
      }
      _mediaLog(
        'stall-lastchance file=$retryId msg=$focusMsgId '
        'after=$fileId bypassCdn=$wantOrigin triedOrigin='
        '${_downloadTriedBypassCdn.contains(retryId)}',
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
      // No soft-nudge on Ready+0B (tears Ready, 0B remains — SessionLog 21:19).
      // After lastchance fails → give-up path probes better hop (R10).
      notifyListeners();
      return;
    }
    if (smallThumb) {
      _mediaLog(
        'stall-give-up-small file=$fileId size=${t?.expectedSize ?? 0} '
        'reason=$reason (skip lastchance under FakeTLS)',
      );
      _pumpDownloadQueue();
      notifyListeners();
      return;
    }

    // Give up — don't ping-pong sizes forever.
    // Under FakeTLS, recoverAttempted alone is not give-up (same-id retry is
    // step 1); only after fallbacks exhausted.
    if (prevFallbackAttempt >= 2) {
      _mediaLog('stall-give-up file=$fileId after $prevFallbackAttempt fallbacks');
      // CDN + origin + size-fallback exhausted while Ready → probe better hop
      // only (no blind RR). Soft-nudge is not a media cure (invariant §3).
      if (proxyOn && _tdlibReadyForMedia) {
        unawaited(_failoverProxy(why: 'media-0B-ready:$fileId', evenIfReady: true));
      }
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
      if (_enabledProxyId != null &&
          !_downloadTriedBypassCdn.contains(fileId)) {
        _downloadForceBypassCdnOnce.add(fileId);
      }
      _queueFileDownload(
        fileId,
        priority: prioFocused,
        background: false,
        chatId: chatId ?? _openChatId,
        reason: 'stall-retry:$reason',
      );
      _downloadTrace[fileId]?.recoverAttempted = true;
      _downloadTrace[fileId]?.sizeFallbackAttempt = prevFallbackAttempt;
    } else {
      _pumpDownloadQueue();
    }
    notifyListeners();
  }

  /// After a hub-avatar 0B stall: try the other size once, then one delayed
  /// requeue of the original id. Further failures cool down so they stop
  /// monopolizing the download slots.
  Future<void> _recoverHubAvatarAfterStall({
    required int fileId,
    required int? chatId,
    required int attempts,
  }) async {
    _hubAvatarStallAttempts[fileId] = attempts + 1;
    // CDN was the first path; next start tries origin-only once.
    if (_enabledProxyId != null &&
        !_downloadTriedBypassCdn.contains(fileId)) {
      _downloadForceBypassCdnOnce.add(fileId);
    }

    // Prefer switching small ↔ big — different CDN remote, often unblocks.
    if (attempts == 0 && chatId != null && chatId != 0) {
      final alt = _hubAvatarAltFileId(chatId, fileId);
      if (alt != null &&
          alt > 0 &&
          alt != fileId &&
          !_filePathCache.containsKey(alt) &&
          !_downloadInFlight.contains(alt) &&
          !_downloadQueued.contains(alt)) {
        _mediaLog(
          'stall-avatar-alt file=$fileId → $alt chat=$chatId',
        );
        // Seed attempt=1 so a stall on alt goes to delayed retry, not another alt.
        _hubAvatarStallAttempts[alt] = 1;
        if (_enabledProxyId != null &&
            !_downloadTriedBypassCdn.contains(alt)) {
          _downloadForceBypassCdnOnce.add(alt);
        }
        _queueFileDownload(
          alt,
          priority: prioHubAvatarRetry,
          background: true,
          chatId: chatId,
          reason: 'hub-avatar',
        );
        return;
      }
    }

    // One delayed retry of the same file (proxy/CDN often recovers).
    if (attempts < 2) {
      const delay = Duration(seconds: 2);
      _hubAvatarCooldownUntil[fileId] = DateTime.now().add(delay);
      _mediaLog(
        'stall-avatar-retry-sched file=$fileId chat=$chatId in=${delay.inSeconds}s',
      );
      unawaited(() async {
        await Future<void>.delayed(delay);
        if (_filePathCache.containsKey(fileId)) return;
        if (_openChatId != null) return;
        if (!_tdlibReadyForMedia) return;
        if (_downloadInFlight.contains(fileId) ||
            _downloadQueued.contains(fileId)) {
          return;
        }
        _hubAvatarCooldownUntil.remove(fileId);
        _mediaLog(
          'stall-avatar-retry file=$fileId chat=$chatId '
          '${_downloadQueueStats()}',
        );
        _queueFileDownload(
          fileId,
          priority: prioHubAvatarRetry,
          background: true,
          chatId: chatId,
          reason: 'hub-avatar',
        );
        _pumpDownloadQueue();
      }());
      return;
    }

    // Give up on this file_id for a while, then force-refresh chat.photo and
    // try any *new* size TDLib returns (poison CDN remotes often stick to the
    // same id forever — SessionLog 2026-10-04 Shariy file=4387).
    const cool = Duration(seconds: 60);
    _hubAvatarCoolUntil[fileId] = DateTime.now().add(cool);
    _hubAvatarPoisonFileIds.add(fileId);
    _mediaLog(
      'stall-avatar-give-up file=$fileId chat=$chatId cool=${cool.inSeconds}s',
    );
    _noteAvatarGiveUpForMediaHealth();
    if (chatId != null && chatId != 0) {
      unawaited(
        _forceRefreshHubAvatarAfterGiveUp(
          chatId: chatId,
          excludeFileIds: {fileId, ..._hubAvatarPoisonFileIds},
        ),
      );
    }
  }

  /// Ready + proxy can still be media-dead (acked downloadFile, 0B forever).
  /// After several hub-avatar give-ups, try a probed hop — never blind RR.
  void _noteAvatarGiveUpForMediaHealth() {
    if (!_useMtprotoProxy || !_tdlibReadyForMedia) return;
    if (phase != TdlibAuthPhase.ready) return;
    final readyAt = _readyAt;
    if (readyAt == null ||
        DateTime.now().difference(readyAt) < const Duration(seconds: 45)) {
      return;
    }
    final now = DateTime.now();
    final window = _avatarGiveUpWindowAt;
    if (window == null || now.difference(window) > const Duration(minutes: 2)) {
      _avatarGiveUpWindowAt = now;
      _avatarGiveUpStreak = 0;
    }
    _avatarGiveUpStreak++;
    if (_avatarGiveUpStreak < 5) return;
    _avatarGiveUpStreak = 0;
    _avatarGiveUpWindowAt = now;
    // After CDN/origin avatar ladder exhausted: probe better hop only
    // (evenIfReady). Probe-miss keeps current hop (no blind RR) — R10.
    _mediaLog(
      'media-0B-avatars streak — probe better hop (evenIfReady)',
    );
    unawaited(
      _failoverProxy(why: 'media-0B-avatars', evenIfReady: true),
    );
  }

  /// Re-fetch chat/user photo after a hub-avatar give-up and enqueue a fresh
  /// file id when TDLib exposes one that is not already poisoned.
  Future<void> _forceRefreshHubAvatarAfterGiveUp({
    required int chatId,
    required Set<int> excludeFileIds,
  }) async {
    final last = _hubAvatarPhotoRefreshAt[chatId];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      _mediaLog('stall-avatar-refresh skip debounce chat=$chatId');
      return;
    }
    final c = _client;
    if (c == null || _tearingDown || !_tdlibReadyForMedia) return;
    if (_openChatId != null) {
      _mediaLog('stall-avatar-refresh defer openChat=$_openChatId chat=$chatId');
      return;
    }
    _hubAvatarPhotoRefreshAt[chatId] = DateTime.now();
    try {
      final chat = await c.sendAwait({
        '@type': 'getChat',
        'chat_id': chatId,
      }, timeout: const Duration(seconds: 8));
      if (chat['@type'] != 'chat') return;
      _applyChatRow(chatId, Map<String, dynamic>.from(chat));

      final type = chat['type'];
      if (type is Map && type['@type'] == 'chatTypePrivate') {
        final uid = _tdlibInt(type['user_id']);
        if (uid > 0) {
          try {
            final user = await c.sendAwait({
              '@type': 'getUser',
              'user_id': uid,
            }, timeout: const Duration(seconds: 8));
            if (user['@type'] == 'user') {
              _users[uid] = Map<String, dynamic>.from(user);
            }
          } catch (e) {
            _mediaLog('stall-avatar-refresh getUser soft-fail chat=$chatId err=$e');
          }
        }
      }

      final refreshed = _chats[chatId];
      if (refreshed == null) return;
      Map<String, dynamic>? user;
      final t = refreshed['type'];
      if (t is Map && t['@type'] == 'chatTypePrivate') {
        final uid = _tdlibInt(t['user_id']);
        if (uid > 0) user = _users[uid];
      }

      final candidates = <(int?, String)>[
        (
          _tdlibPhotoFileId(refreshed['photo'], 'big'),
          _tdlibPhotoRemoteUnique(refreshed['photo'], 'big'),
        ),
        if (user != null)
          (
            _tdlibPhotoFileId(user['profile_photo'], 'big'),
            _tdlibPhotoRemoteUnique(user['profile_photo'], 'big'),
          ),
        (
          _tdlibPhotoFileId(refreshed['photo'], 'small'),
          _tdlibPhotoRemoteUnique(refreshed['photo'], 'small'),
        ),
        if (user != null)
          (
            _tdlibPhotoFileId(user['profile_photo'], 'small'),
            _tdlibPhotoRemoteUnique(user['profile_photo'], 'small'),
          ),
        (_resolveChatAvatarFileId(refreshed, user: user), ''),
      ];

      int? pick;
      for (final pair in candidates) {
        final id = pair.$1;
        if (id == null || id <= 0) continue;
        if (excludeFileIds.contains(id)) continue;
        if (_hubAvatarPoisonFileIds.contains(id)) continue;
        final remote = pair.$2;
        if (remote.isNotEmpty && _hubAvatarPoisonRemotes.contains(remote)) {
          continue;
        }
        if (_filePathCache.containsKey(id)) {
          // Already on disk under a different id — alias via notify.
          pick = id;
          break;
        }
        final coolUntil = _hubAvatarCoolUntil[id];
        if (coolUntil != null && coolUntil.isAfter(DateTime.now())) continue;
        pick = id;
        break;
      }

      if (pick == null) {
        _mediaLog(
          'stall-avatar-refresh no-new-id chat=$chatId '
          'exclude=${excludeFileIds.join(",")}',
        );
        notifyListeners();
        return;
      }

      if (_filePathCache.containsKey(pick)) {
        _mediaLog(
          'stall-avatar-refresh cached chat=$chatId file=$pick',
        );
        notifyListeners();
        return;
      }
      if (_downloadInFlight.contains(pick) || _downloadQueued.contains(pick)) {
        _mediaLog(
          'stall-avatar-refresh already-queued chat=$chatId file=$pick',
        );
        return;
      }

      _hubAvatarCoolUntil.remove(pick);
      _hubAvatarStallAttempts[pick] = 0;
      _mediaLog(
        'stall-avatar-refresh enqueue chat=$chatId file=$pick '
        'exclude=${excludeFileIds.join(",")}',
      );
      _queueFileDownload(
        pick,
        priority: prioHubAvatarRetry,
        background: true,
        chatId: chatId,
        reason: 'hub-avatar',
      );
      _pumpDownloadQueue();
      notifyListeners();
    } catch (e) {
      _mediaLog('stall-avatar-refresh FAIL chat=$chatId err=$e');
    }
  }

  /// Other chat-photo size for [stalledFileId] (small↔big), if any.
  int? _hubAvatarAltFileId(int chatId, int stalledFileId) {
    final chat = _chats[chatId];
    if (chat == null) return null;
    Map<String, dynamic>? user;
    final type = chat['type'];
    if (type is Map && type['@type'] == 'chatTypePrivate') {
      final uid = _tdlibInt(type['user_id']);
      if (uid > 0) user = _users[uid];
    }
    final small = _tdlibPhotoFileId(chat['photo'], 'small') ??
        (user != null
            ? _tdlibPhotoFileId(user['profile_photo'], 'small')
            : null);
    final big = _tdlibPhotoFileId(chat['photo'], 'big') ??
        (user != null
            ? _tdlibPhotoFileId(user['profile_photo'], 'big')
            : null);
    if (stalledFileId == small &&
        big != null &&
        big != stalledFileId &&
        !_hubAvatarPoisonFileIds.contains(big)) {
      return big;
    }
    if (stalledFileId == big &&
        small != null &&
        small != stalledFileId &&
        !_hubAvatarPoisonFileIds.contains(small)) {
      return small;
    }
    return null;
  }

  /// First usable hub-avatar file id, skipping cooled/poisoned CDN stalls.
  int? _pickHubAvatarFileId(
    Map chat, {
    Map<String, dynamic>? user,
  }) {
    final now = DateTime.now();
    bool usable(int? id, String remote) {
      if (id == null || id <= 0) return false;
      if (_hubAvatarPoisonFileIds.contains(id)) return false;
      if (remote.isNotEmpty && _hubAvatarPoisonRemotes.contains(remote)) {
        return false;
      }
      final coolUntil = _hubAvatarCoolUntil[id];
      if (coolUntil != null && coolUntil.isAfter(now)) return false;
      final coolShort = _hubAvatarCooldownUntil[id];
      if (coolShort != null && coolShort.isAfter(now)) return false;
      return true;
    }

    final chatMap = Map<String, dynamic>.from(chat);
    final pairs = <(int?, String)>[
      (
        _tdlibPhotoFileId(chatMap['photo'], 'big'),
        _tdlibPhotoRemoteUnique(chatMap['photo'], 'big'),
      ),
      if (user != null)
        (
          _tdlibPhotoFileId(user['profile_photo'], 'big'),
          _tdlibPhotoRemoteUnique(user['profile_photo'], 'big'),
        ),
      (
        _tdlibPhotoFileId(chatMap['photo'], 'small'),
        _tdlibPhotoRemoteUnique(chatMap['photo'], 'small'),
      ),
      if (user != null)
        (
          _tdlibPhotoFileId(user['profile_photo'], 'small'),
          _tdlibPhotoRemoteUnique(user['profile_photo'], 'small'),
        ),
      (_resolveChatAvatarFileId(chatMap, user: user), ''),
    ];
    for (final pair in pairs) {
      if (usable(pair.$1, pair.$2)) return pair.$1;
    }
    return null;
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
    // Silent: group ListView itemBuilders call sender-avatar every rebuild.
    if (background && _openChatId != null) {
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

  int get _downloadSlotLimit {
    if (_enabledProxyId != null) {
      // FakeTLS: one download at a time (hub or chat) — parallel opens
      // burn the proxy in domain-fronting and starve CDN DC203.
      return 1;
    }
    return _openChatId != null
        ? _maxConcurrentWhenChatOpen
        : _maxConcurrentDownloads;
  }

  /// Connection-plane hint for UI (subtitle / hub prefetch).
  ///
  /// **Not** a gate for `downloadFile` — levlam/td#1176: ignore
  /// `connectionState*` for requests; use [phase] == ready instead.
  bool get _tdlibReadyForMedia {
    return _connectionState == 'connectionStateReady' ||
        _connectionState == 'connectionStateUpdating';
  }

  /// May send TDLib media RPCs (downloadFile / cancel / recover).
  /// Auth ready + not offline. ConnectionStateReady is irrelevant here.
  bool get _canStartNetworkDownload =>
      phase == TdlibAuthPhase.ready &&
      _networkKind != ChatNetworkLinkKind.offline;

  /// Public: hub/UI may gate avatar prefetch on MTProto Ready.
  bool get readyForMedia => _tdlibReadyForMedia;

  /// Bumps on each Ready/Updating transition — hub watches to re-prefetch
  /// avatars that were skipped while Connecting.
  int get mediaReadyEpoch => _mediaReadyEpoch;
  int _mediaReadyEpoch = 0;

  void _noteConnectionState(String name) {
    final connecting = name == 'connectionStateConnecting' ||
        name == 'connectionStateConnectingToProxy' ||
        name == 'connectionStateWaitingForNetwork';
    if (connecting) {
      _connectingSince ??= DateTime.now();
      _readyAt = null;
      _ensureConnectingWaitLogTimer();
      _ensureConnectionStatusRevealTimer();
    } else if (name == 'connectionStateReady' ||
        name == 'connectionStateUpdating') {
      if (_fakeTlsQuietUntil != null) {
        _fakeTlsQuietUntil = null;
        _mediaLog('faketls-quiet clear (conn=$name)');
      }
      if (_softResumeGuardUntil != null ||
          _longBackgroundResume ||
          _longBackgroundSoftRestartCount > 0) {
        _softResumeGuardUntil = null;
        _longBackgroundResume = false;
        _longBackgroundSoftRestartCount = 0;
        _resumeWasTrueLongBackground = false;
        _mediaLog('soft-resume-guard clear (conn=$name)');
      }
      final since = _connectingSince;
      final wasWaiting = since != null;
      _readyAt = DateTime.now();
      if (since != null) {
        _mediaLog(
          'mtproto-up after ${_fmtDur(_readyAt!.difference(since))} '
          'via $name (media can flow)',
        );
      }
      // Do NOT persist preferred on Ready alone — SessionLog showed Ready with
      // dead media (Pong timeout + avatar 0B). Prefer only after pingProxy ok.
      _connectingSince = null;
      _connectionKickCount = 0;
      _lastConnectionKickAt = null;
      _lastBearerChangeAt = null;
      _connectingTimeoutTimer?.cancel();
      _connectingTimeoutTimer = null;
      _connectionStatusRevealTimer?.cancel();
      _connectionStatusRevealTimer = null;
      if (wasWaiting) {
        _mediaReadyEpoch++;
        // Hub watches mediaReadyEpoch to re-run avatar prefetch after Connecting.
        notifyListeners();
      }
    } else {
      _connectingSince = null;
      _connectingTimeoutTimer?.cancel();
      _connectingTimeoutTimer = null;
      _connectionStatusRevealTimer?.cancel();
      _connectionStatusRevealTimer = null;
    }
  }

  /// Notify UI once grace elapses so the connecting subtitle can appear.
  void _ensureConnectionStatusRevealTimer() {
    if (_connectionStatusRevealTimer != null) return;
    final since = _connectingSince;
    if (since == null) return;
    final remaining =
        _kConnectionStatusGrace - DateTime.now().difference(since);
    if (remaining <= Duration.zero) {
      notifyListeners();
      return;
    }
    _connectionStatusRevealTimer = Timer(remaining, () {
      _connectionStatusRevealTimer = null;
      if (!_tdlibReadyForMedia && _connectingSince != null) {
        notifyListeners();
      }
    });
  }

  /// Log slow Connecting waits + escalate recovery (official TDLib pattern).
  /// Downloads stay paused until Ready (0B until then).
  void _ensureConnectingWaitLogTimer() {
    if (!_appInForeground) return;
    _connectingTimeoutTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (!_appInForeground) return;
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

  /// Escalating recovery for wedged Connecting (official tgnet + levlam):
  /// 1) soft enableProxy / setNetworkType nudge
  /// 2) second soft nudge (same hop — NOT proxy failover)
  /// 3) proxy failover only if pingProxy found a better hop (no blind RR)
  /// 4) soft-restart TDLib client (last resort)
  ///
  /// After pause/resume ([_softResumeGuardUntil]): no failover / None-bounce
  /// (SessionLog 17:04 pause → 17:06 RR to 8443). Soft×2 → soft-restart same
  /// hop still allowed (R29 — not soft-nudge forever).
  ///
  /// Skip entirely while offline / WaitingForNetwork — kicks only flood mtg
  /// with half-open FakeTLS (`cannot read client hello`).
  ///
  /// R15 (SessionLog 23:18): under long-bg, soft×2 while [_inFakeTlsQuiet]
  /// only `skip enableProxy` — pure delay. Wait out quiet, then jump to
  /// soft-restart / probe / hop-try (what actually restored Ready).
  void _maybeKickStuckMtproto(Duration waited) {
    if (!_appInForeground) return;
    if (_tdlibReadyForMedia) return;
    if (_networkKind == ChatNetworkLinkKind.offline) return;
    if (_connectionState == 'connectionStateWaitingForNetwork') return;
    if (_connectionState == 'connectionStateConnectingToProxy' &&
        waited < const Duration(seconds: 40)) {
      // Let FakeTLS finish the first attempt (mobile RTT / DPI is slower).
      return;
    }
    final mobile = _networkKind == ChatNetworkLinkKind.mobile;
    final bearerAt = _lastBearerChangeAt;
    final recentBearer = bearerAt != null &&
        DateTime.now().difference(bearerAt) < const Duration(minutes: 3);
    final softResume = _softResumeGuardUntil != null &&
        DateTime.now().isBefore(_softResumeGuardUntil!);
    final longBg = _longBackgroundResume;

    // R14/R15: while quiet, do not burn soft kicks (boot enableProxy also
    // arms quiet — SessionLog 16:01: soft-nudge enableProxy @35s aborted
    // FakeTLS; mtg `cannot read client hello` / i/o timeout).
    if (_inFakeTlsQuiet && !_tdlibReadyForMedia) {
      return;
    }

    int nextStage;
    Duration minWait;
    Duration minGap;

    // R15: after quiet clears, collapse soft×2 → the escalate step that
    // matches restartCount (restart / hop), not another soft-nudge.
    // R24: skip stage-3 probe while Connecting (ping always times out) —
    // go soft-restart→soft-restart→…→hop (SessionLog 14:25 probe burn).
    final r15Collapse = longBg && softResume && _connectionKickCount < 2;
    // R30: minWait ≥ quiet (35s) + headroom — Ready@20.6s (16:56); 14–18s
    // minWait + 18s quiet → soft-restart@20s thrash (17:15).
    if (r15Collapse && _longBackgroundSoftRestartCount == 0) {
      nextStage = 4;
      minWait = Duration(seconds: mobile ? 45 : 40);
      minGap = const Duration(seconds: 12);
    } else if (r15Collapse &&
        _longBackgroundSoftRestartCount < _longBgSoftRestartCap) {
      // Soft-restart again (not probe — ping times out while Connecting).
      nextStage = 4;
      minWait = Duration(seconds: mobile ? 45 : 40);
      minGap = const Duration(seconds: 12);
    } else if (r15Collapse) {
      nextStage = 5;
      minWait = Duration(seconds: mobile ? 48 : 42);
      minGap = const Duration(seconds: 12);
    } else if (_connectionKickCount <= 0) {
      nextStage = 1;
      minWait = recentBearer
          ? Duration(seconds: mobile ? 30 : 28)
          : Duration(seconds: mobile ? 40 : 35);
      // After long lock, escalate soft sooner (SessionLog 21:05 stuck).
      if (longBg) {
        minWait = Duration(seconds: mobile ? 22 : 18);
      }
      minGap = Duration.zero;
    } else if (_connectionKickCount == 1) {
      // Stage 2 = second soft nudge (official: resume same proxy).
      nextStage = 2;
      minWait = recentBearer
          ? Duration(seconds: mobile ? 55 : 50)
          : Duration(seconds: mobile ? 75 : 60);
      if (longBg) {
        minWait = Duration(seconds: mobile ? 40 : 35);
      }
      minGap = Duration(seconds: recentBearer
          ? (mobile ? 18 : 14)
          : (mobile ? 25 : 18));
      if (longBg) minGap = const Duration(seconds: 12);
    } else if (_connectionKickCount == 2) {
      // Long-bg ladder (R9–R12):
      //   0 restarts → soft-restart
      //   1 restart  → probe better hop (ping may fail while Connecting)
      //   2 restarts → one no-ping hop try (user-switch analogue)
      if (softResume && longBg &&
          _longBackgroundSoftRestartCount >= _longBgSoftRestartCap) {
        nextStage = 5;
        minWait = Duration(seconds: mobile ? 28 : 24);
        minGap = const Duration(seconds: 8);
      } else if (softResume && longBg && _longBackgroundSoftRestartCount >= 1) {
        // R24: soft-restart again — not probe (ping unreliable while Connecting).
        nextStage = 4;
        minWait = Duration(seconds: mobile ? 28 : 24);
        minGap = const Duration(seconds: 8);
      } else if (softResume && longBg) {
        nextStage = 4;
        minWait = Duration(seconds: mobile ? 35 : 30);
        minGap = const Duration(seconds: 10);
      } else if (softResume) {
        // R29 (SessionLog 16:49): softResume used to pin stage=2 forever
        // (~5m soft-nudge) — official is resume once then wait / reconnect
        // same hop, never soft-only forever (06_OFFICIAL). Soft-restart
        // same hop after soft×2; still no RR/failover under soft-resume.
        nextStage = 4;
        minWait = Duration(seconds: mobile ? 100 : 90);
        minGap = const Duration(seconds: 40);
      } else {
        nextStage = 3;
        minWait = Duration(seconds: mobile ? 120 : 100);
        minGap = const Duration(seconds: 40);
      }
    } else if (_connectionKickCount == 3) {
      // After probe (#3): long-bg → soft-restart sooner if under cap; else
      // hop-try. Short path keeps soft-restart with longer wait.
      if (longBg && _longBackgroundSoftRestartCount < _longBgSoftRestartCap) {
        nextStage = 4;
        minWait = Duration(seconds: mobile ? 50 : 40);
        minGap = const Duration(seconds: 12);
      } else if (longBg) {
        nextStage = 5;
        minWait = Duration(seconds: mobile ? 45 : 35);
        minGap = const Duration(seconds: 15);
      } else {
        nextStage = 4;
        minWait = recentBearer
            ? Duration(seconds: mobile ? 160 : 140)
            : Duration(seconds: mobile ? 200 : 180);
        minGap = const Duration(seconds: 60);
      }
    } else if (_connectionKickCount == 4 || _connectionKickCount == 5) {
      if (waited < const Duration(minutes: 15)) return;
      final last = _lastConnectionKickAt;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 15)) {
        return;
      }
      nextStage = 1;
      _connectionKickCount = 0;
      _lastBearerChangeAt = null;
      minWait = Duration.zero;
      minGap = Duration.zero;
    } else {
      if (waited < const Duration(minutes: 15)) return;
      final last = _lastConnectionKickAt;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 15)) {
        return;
      }
      nextStage = 1;
      _connectionKickCount = 0;
      _lastBearerChangeAt = null;
      minWait = Duration.zero;
      minGap = Duration.zero;
    }
    if (waited < minWait) return;
    final last = _lastConnectionKickAt;
    if (last != null && DateTime.now().difference(last) < minGap) return;
    if (r15Collapse && nextStage >= 3) {
      _mediaLog(
        'mtproto-kick R15 collapse soft×2 → stage=$nextStage '
        'restartCount=$_longBackgroundSoftRestartCount '
        'after=${_fmtDur(waited)}'
        '${nextStage == 4 && _longBackgroundSoftRestartCount >= 1 ? ' R24-skip-probe' : ''}',
      );
    }
    _lastConnectionKickAt = DateTime.now();
    _connectionKickCount = nextStage;
    unawaited(_kickStuckMtproto(waited, stage: nextStage));
  }

  void _armSoftResumeGuard({required String why}) {
    _softResumeGuardUntil =
        DateTime.now().add(const Duration(minutes: 5));
    _mediaLog(
      'soft-resume-guard arm 5m why=$why '
      'until=${_softResumeGuardUntil!.toUtc().toIso8601String()}',
    );
  }

  Future<void> _kickStuckMtproto(
    Duration waited, {
    required int stage,
  }) async {
    final c = _client;
    if (c == null || _tdlibReadyForMedia) return;
    if (_networkKind == ChatNetworkLinkKind.offline) return;
    if (_connectionState == 'connectionStateWaitingForNetwork') return;
    final softResume = _softResumeGuardUntil != null &&
        DateTime.now().isBefore(_softResumeGuardUntil!);
    _mediaLog(
      'mtproto-kick #$stage after ${_fmtDur(waited)} '
      'conn=$_connectionState proxyId=${_enabledProxyId ?? '?'} '
      'net=$_networkKind softResume=$softResume longBg=$_longBackgroundResume',
    );
    switch (stage) {
      case 1:
      case 2:
        // Soft nudge only — same hop. Official tgnet resumeNetwork does this;
        // None→WiFi / proxy RR made 17:04 pause → long Connecting worse.
        if (_enabledProxyId != null && _useMtprotoProxy) {
          _mediaLog(
            'mtproto-kick #$stage soft-nudge (skip none-bounce / no failover)',
          );
          await _softNudgeMtproto(why: 'stuck-connecting-soft:$stage');
          return;
        }
        // Direct (no proxy): one soft setNetworkType, still no None-bounce.
        await _setTdlibOnline(true);
        await _applyNetworkTypeFromDevice(
          why: 'stuck-connecting-soft:$stage',
          force: true,
        );
        return;
      case 3:
        // Soft-resume normally blocks hop changes. Exception: long-bg after
        // ≥1 soft-restart still Connecting — probe better hop (R11).
        final allowLongBgProbe =
            _longBackgroundResume && _longBackgroundSoftRestartCount >= 1;
        if (softResume && !allowLongBgProbe) {
          _mediaLog('mtproto-kick #3 skip failover (soft-resume guard)');
          await _softNudgeMtproto(why: 'stuck-connecting-soft:guard');
          return;
        }
        await _failoverProxy(
          why: allowLongBgProbe
              ? 'stuck-connecting-longbg-probe'
              : 'stuck-connecting',
        );
        return;
      case 4:
        _mediaLog(
          'mtproto-kick soft-restart TDLib after ${_fmtDur(waited)} '
          'longBg=$_longBackgroundResume '
          'restartCount=$_longBackgroundSoftRestartCount',
        );
        if (_longBackgroundResume) {
          _longBackgroundSoftRestartCount =
              (_longBackgroundSoftRestartCount + 1).clamp(1, _longBgSoftRestartCap);
        }
        await _recoverDeadClient(
          _longBackgroundResume
              ? 'stuck-connecting-longbg:${_fmtDur(waited)}'
              : 'stuck-connecting:${_fmtDur(waited)}',
          preserveLongBgEscalation: _longBackgroundResume,
        );
        return;
      case 5:
        // After reopen×2 + ping still useless while Connecting: one hop try
        // without requiring pingProxy (manual proxy switch analogue) — R12.
        await _tryNextHopNoPing(why: 'stuck-connecting-longbg-hop');
        return;
      default:
        return;
    }
  }

  void _armFakeTlsQuiet({required String why, Duration? duration}) {
    final d = duration ??
        (_longBackgroundResume ? _fakeTlsQuietLongBg : _fakeTlsQuiet);
    _fakeTlsQuietUntil = DateTime.now().add(d);
    _mediaLog(
      'faketls-quiet arm ${d.inSeconds}s why=$why '
      'until=${_fakeTlsQuietUntil!.toUtc().toIso8601String()}',
    );
  }

  bool get _inFakeTlsQuiet =>
      _fakeTlsQuietUntil != null &&
      DateTime.now().isBefore(_fakeTlsQuietUntil!);

  /// Soft kick while already mid-FakeTLS — tgnet leaves the handshake alone.
  ///
  /// [forceEnableProxy]: only hop-try / failover when the hop actually changes.
  /// Soft kicks never `enableProxy` **or** `setNetworkType(force)` while
  /// Connecting (R14/R25/R28/R29) — both abort FakeTLS TlsInit
  /// (boot SessionLog 16:40 enableProxy; resume SessionLog 16:49 setNetworkType
  /// every ~40s under soft-resume forever). Official: resumeNetwork **once**.
  Future<void> _softNudgeMtproto({
    required String why,
    bool forceEnableProxy = false,
  }) async {
    final c = _client;
    if (c == null || _tearingDown) return;
    await _setTdlibOnline(true);
    // R29: while FakeTLS Connecting, setNetworkType(force) reopens sockets and
    // aborts TlsInit — same class as enableProxy (R28). Official resumeNetwork
    // runs once on foreground; soft kicks must not thrash.
    if (!forceEnableProxy && !_tdlibReadyForMedia && _useMtprotoProxy) {
      if (_inFakeTlsQuiet) {
        _mediaLog(
          'soft-nudge skip setNetworkType (faketls-quiet) why=$why',
        );
      } else {
        _mediaLog(
          'soft-nudge skip setNetworkType (Connecting) why=$why',
        );
      }
      return;
    }
    // TDLib: setNetworkType forces connections to reopen even if type unchanged
    // (levlam td#3144 / setNetworkType docs). Direct / forceEnableProxy only.
    await _applyNetworkTypeFromDevice(why: why, force: true);
    if (_tearingDown || _client == null) return;
    final proxyId = _enabledProxyId;
    if (proxyId == null || !_useMtprotoProxy) return;
    if (!forceEnableProxy && _inFakeTlsQuiet && !_tdlibReadyForMedia) {
      _mediaLog('soft-nudge skip enableProxy (faketls-quiet) why=$why');
      return;
    }
    // R28: any Connecting — not only soft-resume (R25). Boot quiet expires at
    // ~35s; next soft-nudge enableProxy tore the first FakeTLS handshake.
    if (!forceEnableProxy && !_tdlibReadyForMedia) {
      _mediaLog(
        'soft-nudge skip enableProxy (Connecting) why=$why',
      );
      return;
    }
    try {
      await c.sendAwait({
        '@type': 'enableProxy',
        'proxy_id': proxyId,
      }, timeout: const Duration(seconds: 5));
      _mediaLog('soft-nudge enableProxy id=$proxyId ok why=$why');
      if (!_tdlibReadyForMedia) {
        _armFakeTlsQuiet(why: 'soft-nudge:$why');
      }
    } catch (e) {
      _mediaLog('soft-nudge enableProxy id=$proxyId err=$e why=$why');
      await _ensureProxy();
    }
  }

  /// Shell / lifecycle: app returned to foreground.
  ///
  /// Official TDLib: set option "online"=true for fast recovery, and call
  /// setNetworkType when connectivity may have changed (td#2690, td#3144).
  Future<void> onAppResumed() async {
    _appInForeground = true;
    final pausedAt = _backgroundPausedAt;
    _backgroundPausedAt = null;
    final bgFor = pausedAt == null
        ? Duration.zero
        : DateTime.now().difference(pausedAt);
    // R23 (SessionLog 13:50): short re-lock while mid-ladder wiped
    // restartCount=2 → soft-nudge forever on preferred hop; hop-try never ran.
    final priorRestartCount = _longBackgroundSoftRestartCount;
    final midLadder = !_tdlibReadyForMedia && priorRestartCount > 0;
    // R27 (SessionLog 16:18): our R26 pause-suspend intentionally leaves
    // WaitingForNetwork / !Ready. That must NOT arm R13 longBg ladder —
    // official resumeNetwork only unsuspends; soft-restart@15s tore the
    // FakeTLS handshake ("connect ~10s then drop"). True long-bg (≥2m)
    // still escalates. Spontaneous !Ready without our suspend keeps R13.
    final pauseSuspended = _appNetworkSuspended;
    _longBackgroundResume = bgFor >= _longBackgroundThreshold;
    _resumeWasTrueLongBackground = _longBackgroundResume;
    if (_longBackgroundResume) {
      if (midLadder) {
        _mediaLog(
          'long-background-resume bg=${_fmtDur(bgFor)} '
          '→ longbg-ladder preserve restartCount=$priorRestartCount',
        );
      } else {
        // Fresh long-bg after Ready — official reopen first (R25); ladder later.
        _longBackgroundSoftRestartCount = 0;
        _mediaLog(
          'long-background-resume bg=${_fmtDur(bgFor)} '
          '→ official-reopen then kick ladder if needed',
        );
      }
    } else if (pauseSuspended) {
      // R27: !Ready is expected after networkTypeNone — unsuspend only.
      _longBackgroundSoftRestartCount = 0;
      _resumeWasTrueLongBackground = false;
      _mediaLog(
        'connecting-on-resume skip R13 (pause-suspend) '
        'bg=${_fmtDur(bgFor)} conn=$_connectionState → official-reopen only',
      );
    } else if (!_tdlibReadyForMedia) {
      // SessionLog 22:36: lock ~52s — TDLib already Connecting (+5s into
      // background) but bg < 2m so R9–R12 never armed; soft-nudge only.
      // Consensus: reopen ladder when resume finds not-Ready (R13).
      // R23: if already mid-ladder, keep restartCount (do not zero).
      // R27: only when we did NOT intentionally suspend (zombie path).
      _longBackgroundResume = true;
      if (midLadder) {
        _mediaLog(
          'connecting-on-resume escalate bg=${_fmtDur(bgFor)} '
          'conn=$_connectionState → longbg-ladder preserve '
          'restartCount=$priorRestartCount',
        );
      } else {
        _longBackgroundSoftRestartCount = 0;
        _mediaLog(
          'connecting-on-resume escalate bg=${_fmtDur(bgFor)} '
          'conn=$_connectionState → same ladder as long-bg',
        );
      }
    } else {
      _longBackgroundSoftRestartCount = 0;
      _resumeWasTrueLongBackground = false;
    }
    _armSoftResumeGuard(why: 'app-resume');
    // Cancel pending suspend; if already suspended, resume recover unsuspends.
    if (_pauseOfflineGraceTimer != null) {
      _pauseOfflineGraceTimer!.cancel();
      _pauseOfflineGraceTimer = null;
      _mediaLog('app-pause-suspend cancel (resume before None)');
    }
    if (_client == null || _tearingDown) return;
    await _setTdlibOnline(true);
    _ensureNetworkLinkWatch();
    final prevKind = _networkKind;
    final kind = await ChatNetworkLink.current();
    _networkKind = kind;
    if (kind == ChatNetworkLinkKind.offline) {
      // No FakeTLS attempts while offline — resume storms used to fire
      // bearer-recover with net=offline (SessionLog 2026-10-03 08:19).
      _mediaLog('app-resume offline — skip recover');
      await _applyNetworkTypeFromDevice(why: 'app-resume-offline', force: true);
      _appNetworkSuspended = false;
      return;
    }
    // VPN / public IP may change without a ChatNetworkLinkKind flip.
    _scheduleProxyGeoRecheck(why: 'app-resume');
    final needUnsuspend = _appNetworkSuspended || !_tdlibReadyForMedia;
    if (needUnsuspend) {
      // Fresh kick clock (do not inherit hours of background "waited").
      if (!_tdlibReadyForMedia) {
        _resetMtprotoKickClock(why: 'app-resume-not-ready');
        _ensureConnectingWaitLogTimer();
      }
      // R25/R26: online + setNetworkType after pause None (resumeNetwork).
      _scheduleAppResumeRecover();
    } else if (prevKind != kind) {
      await _applyNetworkTypeFromDevice(why: 'app-resume', force: true);
    } else {
      // Ready, never suspended — still soft-nudge network type (levlam).
      await _applyNetworkTypeFromDevice(why: 'app-resume-ready', force: true);
    }
  }

  void _scheduleAppResumeRecover() {
    _appResumeRecoverTimer?.cancel();
    _appResumeRecoverTimer = Timer(const Duration(seconds: 2), () {
      _appResumeRecoverTimer = null;
      unawaited(_runAppResumeRecover());
    });
  }

  Future<void> _runAppResumeRecover() async {
    if (!_appInForeground || _tearingDown || _client == null) return;
    // Still run when Ready if pause left networkTypeNone (unsuspend).
    if (_tdlibReadyForMedia && !_appNetworkSuspended) return;
    final kind = await ChatNetworkLink.current();
    _networkKind = kind;
    if (kind == ChatNetworkLinkKind.offline) {
      _mediaLog('app-resume-recover skip offline');
      _appNetworkSuspended = false;
      return;
    }
    final last = _lastAppResumeRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 12)) {
      _mediaLog('app-resume-recover skip debounce');
      return;
    }
    _lastAppResumeRecoverAt = DateTime.now();
    // R25/R26/R30 — official path (DrKLO resumeNetwork + levlam td#3144):
    //   online=true + setNetworkType(force) after pause None suspend.
    //   After None, one enableProxy reconnects FakeTLS (tgnet reconnects
    //   ConnectionTypeProxy). Soft kicks still never enableProxy (R28/R29).
    // Not soft-restart on resume recover (R14/R25).
    final wasSuspended = _appNetworkSuspended;
    _mediaLog(
      'app-resume-recover official-reopen '
      'suspended=$wasSuspended '
      'longBg=$_resumeWasTrueLongBackground '
      'restartCount=$_longBackgroundSoftRestartCount '
      'conn=$_connectionState',
    );
    await _setTdlibOnline(true);
    await _applyNetworkTypeFromDevice(
      why: wasSuspended ? 'app-resume-unsuspend' : 'app-resume-official',
      force: true,
    );
    _appNetworkSuspended = false;
    if (_tearingDown || _client == null) return;
    // R30 (SessionLog 17:08–17:16): setNetworkType alone after pause None
    // left Connecting; soft-restart thrash with 18s quiet never Ready.
    // One enableProxy = proxy socket reconnect (bearer-recover does this).
    if (wasSuspended &&
        !_tdlibReadyForMedia &&
        _useMtprotoProxy &&
        _enabledProxyId != null) {
      final proxyId = _enabledProxyId!;
      try {
        await _client!.sendAwait({
          '@type': 'enableProxy',
          'proxy_id': proxyId,
        }, timeout: const Duration(seconds: 5));
        _mediaLog(
          'app-resume-unsuspend enableProxy id=$proxyId ok (proxy reconnect)',
        );
      } catch (e) {
        _mediaLog(
          'app-resume-unsuspend enableProxy id=$proxyId err=$e',
        );
        await _ensureProxy();
      }
    }
    // R29/R30: leave FakeTLS alone after the one resume reconnect — quiet
    // always 35s (Ready@20.6s needs headroom; soft kicks skip thrash).
    if (!_tdlibReadyForMedia && _useMtprotoProxy) {
      _armFakeTlsQuiet(
        why: wasSuspended ? 'app-resume-unsuspend' : 'app-resume-official',
        duration: _fakeTlsQuiet,
      );
    }
  }

  /// Shell / lifecycle: app backgrounded.
  Future<void> onAppPaused() async {
    _appInForeground = false;
    _backgroundPausedAt ??= DateTime.now();
    _armSoftResumeGuard(why: 'app-pause');
    _appResumeRecoverTimer?.cancel();
    _appResumeRecoverTimer = null;
    // Stop kick escalation in background — otherwise overnight Connecting
    // accumulates 498m+ "waited" and resume immediately soft-restarts.
    _connectingTimeoutTimer?.cancel();
    _connectingTimeoutTimer = null;
    _connectionKickCount = 0;
    _lastConnectionKickAt = null;
    _connectingSince = null;
    _mediaLog(
      'app-pause freeze-kick conn=$_connectionState net=$_networkKind',
    );
    if (_client == null || _tearingDown) return;
    // R26: always arm suspend — even if already Connecting. Old path skipped
    // when !Ready → zombie FakeTLS until spontaneous Ready (SessionLog 15:35).
    _armPauseNetworkSuspend();
  }

  /// Official tgnet `pauseNetwork` → suspendConnections analogue for TDLib:
  /// `setNetworkType(networkTypeNone)` after a short grace (quick app switches
  /// cancel). Resume always unsuspends via setNetworkType(current) (R25/R26).
  void _armPauseNetworkSuspend() {
    _pauseOfflineGraceTimer?.cancel();
    final until = DateTime.now().add(_pauseSuspendGrace);
    _mediaLog(
      'app-pause-suspend arm ${_pauseSuspendGrace.inSeconds}s '
      'until=${until.toUtc().toIso8601String()} '
      'conn=$_connectionState',
    );
    _pauseOfflineGraceTimer = Timer(_pauseSuspendGrace, () {
      _pauseOfflineGraceTimer = null;
      if (_appInForeground || _tearingDown || _client == null) return;
      unawaited(_applyPauseNetworkSuspend());
    });
  }

  Future<void> _applyPauseNetworkSuspend() async {
    if (_appInForeground || _tearingDown || _client == null) return;
    // Remember last good link before None (resume must not leave None — 09:09).
    if (_networkKind == ChatNetworkLinkKind.wifi ||
        _networkKind == ChatNetworkLinkKind.mobile) {
      _lastNonOfflineKind = _networkKind;
    }
    _mediaLog(
      'app-pause-suspend fire networkTypeNone '
      'conn=$_connectionState fg=$_appInForeground',
    );
    await _setNetworkType(
      'networkTypeNone',
      why: 'app-pause-suspend',
      force: true,
    );
    if (_appInForeground || _tearingDown) return;
    _appNetworkSuspended = true;
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
      // VPN toggles often keep mapped kind=wifi — still recheck public IP/geo.
      if (kind != ChatNetworkLinkKind.offline) {
        _scheduleProxyGeoRecheck(why: 'link:$kind');
      }
      if (prev == kind && prev != ChatNetworkLinkKind.unknown) return;
      _lastBearerChangeAt = DateTime.now();
      // New bearer = new FakeTLS attempt; do not inherit mobile kick stages.
      _resetMtprotoKickClock(why: 'link:$kind');
      unawaited(_onNetworkBearerChanged(prev: prev, kind: kind));
    });
  }

  Future<void> _onNetworkBearerChanged({
    required ChatNetworkLinkKind prev,
    required ChatNetworkLinkKind kind,
  }) async {
    if (_tearingDown || _client == null) return;
    // R31b: ignore link churn until params+proxy finished (boot race).
    if (!_parametersApplied || _setParamsJob != null || _recoveringClient) {
      _mediaLog('link-change skip (boot/params) $prev→$kind');
      return;
    }
    if (kind == ChatNetworkLinkKind.offline) {
      await _applyNetworkTypeFromDevice(why: 'link:$kind', force: true);
      notifyListeners();
      return;
    }
    // mobile→Wi‑Fi: always full recover. Plain setNetworkType while still
    // Ready leaves a long Connecting hang (SessionLog 10:05).
    final backToWifi = kind == ChatNetworkLinkKind.wifi &&
        prev == ChatNetworkLinkKind.mobile;
    if (backToWifi || !_tdlibReadyForMedia) {
      await _recoverAfterBearerChange(why: 'link:$kind');
      return;
    }
    await _applyNetworkTypeFromDevice(why: 'link:$kind', force: true);
  }

  /// Re-resolve RU vs non-RU public IP after VPN / network changes.
  ///
  /// [_useMtprotoProxyResolved] is otherwise sticky; without this, leaving RU
  /// via VPN keeps FakeTLS on, and returning to RU keeps direct forever.
  void _scheduleProxyGeoRecheck({required String why}) {
    if (kIsWeb || _tearingDown) return;
    _proxyGeoRecheckTimer?.cancel();
    _proxyGeoRecheckTimer = Timer(const Duration(seconds: 2), () {
      _proxyGeoRecheckTimer = null;
      unawaited(_recheckProxyGeo(why: why));
    });
  }

  Future<void> _recheckProxyGeo({required String why}) async {
    if (_tearingDown || _client == null) return;
    if (_networkKind == ChatNetworkLinkKind.offline) return;
    await _loadDebugMtprotoProxyPref();
    // R18: user AppBar OFF = forced direct — skip geo. AppBar ON = follow geo
    // (VPN leave-RU drops FakeTLS; return-to-RU re-enables). Never write geo
    // into [_debugMtprotoProxyPref] (that sticky-OFF'd the switch forever).
    if (kDebugMode && !_debugMtprotoProxyPref) {
      _mediaLog('proxy geo recheck skip (user AppBar OFF) why=$why');
      return;
    }
    final last = _lastProxyGeoRecheckAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastProxyGeoRecheckAt = DateTime.now();
    final geoWant = await shouldUseTdlibMtprotoProxy();
    final want = geoWant;
    final was = _useMtprotoProxy;
    if (want == was && _useMtprotoProxyResolved == want) {
      _mediaLog('proxy geo recheck $why unchanged use=$want');
      return;
    }
    _mediaLog(
      'proxy geo recheck $why → use=$want (was $was) '
      'appBar=${kDebugMode ? _debugMtprotoProxyPref : "-"}',
    );
    _useMtprotoProxyResolved = want;
    _useMtprotoProxy = want;
    AppSessionDiagnostics.instance.setTgState(proxy: want);
    _slog('tg.conn', 'proxy_geo', {
      'why': why,
      'use': want,
      'was': was,
      'appBar': kDebugMode ? _debugMtprotoProxyPref : null,
    });
    notifyListeners();
    final c = _client;
    if (c == null) return;
    if (want) {
      await _ensureProxy();
      if (!_tdlibReadyForMedia) {
        await _recoverAfterBearerChange(why: 'geo-on:$why');
      }
    } else {
      await _disableAllProxies(c, why: 'geo-recheck-non-ru:$why');
      _enabledProxyId = null;
      // Nudge TDLib onto direct after tearing down FakeTLS.
      await _applyNetworkTypeFromDevice(why: 'geo-off:$why', force: true);
    }
    notifyListeners();
  }

  /// After mobile↔Wi‑Fi while not Ready: re-assert network type + re-enable
  /// proxy. Wi‑Fi also gets a socket reopen; mobile skips None-bounce (it
  /// aborted FakeTLS mid-handshake and never reached Ready — SessionLog
  /// 2026-10-02 08:41). Soft-restart follows via [_maybeKickStuckMtproto].
  Future<void> _recoverAfterBearerChange({required String why}) async {
    if (_tearingDown || _client == null) return;
    // R31b (SessionLog 17:28): first link event during boot fired
    // bearer-recover → None→WiFi while setParameters/ensureProxy still
    // running — aborted FakeTLS and left UI on «Подключение…».
    if (!_parametersApplied || _setParamsJob != null || _recoveringClient) {
      _mediaLog('bearer-recover skip (boot/params) why=$why');
      return;
    }
    final last = _lastBearerRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 8)) {
      _mediaLog('bearer-recover skip debounce why=$why');
      return;
    }
    _lastBearerRecoverAt = DateTime.now();
    final mobile = _networkKind == ChatNetworkLinkKind.mobile;
    _mediaLog(
      'bearer-recover start why=$why conn=$_connectionState '
      'proxyId=${_enabledProxyId ?? "?"} net=$_networkKind',
    );
    await _setTdlibOnline(true);
    await _applyNetworkTypeFromDevice(why: why, force: true);
    if (_tearingDown || _client == null) return;
    final proxyId = _enabledProxyId;
    if (proxyId != null && _useMtprotoProxy) {
      try {
        await _client!.sendAwait({
          '@type': 'enableProxy',
          'proxy_id': proxyId,
        }, timeout: const Duration(seconds: 5));
        _mediaLog('bearer-recover enableProxy id=$proxyId ok');
        if (!_tdlibReadyForMedia) {
          _armFakeTlsQuiet(why: 'bearer-recover:$why');
        }
      } catch (e) {
        _mediaLog('bearer-recover enableProxy id=$proxyId err=$e');
        await _ensureProxy();
      }
    } else if (_useMtprotoProxy) {
      await _ensureProxy();
    }
    if (_tearingDown || _client == null) return;
    // None→WiFi aborts an in-flight FakeTLS handshake (SessionLog 23:51:
    // resume bounce → WaitingForNetwork → another 40s+ Connecting). Mobile
    // already skipped this; same for app-resume while still Connecting —
    // online=true + enableProxy above is enough; kicks handle a true wedge.
    if (mobile || why.startsWith('app-resume')) {
      _mediaLog(
        'bearer-recover skip-none-bounce '
        '(${mobile ? 'mobile' : 'app-resume'}) why=$why',
      );
      return;
    }
    // Real bearer change on Wi‑Fi (mobile→wifi): bounce sockets.
    await _reopenNetworkConnections(why: 'bearer-recover:$why');
  }

  /// After mobile↔Wi‑Fi switches the old `_connectingSince` / kick stage made
  /// Wi‑Fi immediately hit proxy-cycle (stage 2) and look "stuck for minutes".
  void _resetMtprotoKickClock({required String why}) {
    _connectionKickCount = 0;
    _lastConnectionKickAt = null;
    if (!_tdlibReadyForMedia) {
      _connectingSince = DateTime.now();
    }
    _mediaLog('mtproto-kick-reset why=$why');
  }

  Future<void> _applyNetworkTypeFromDevice({
    required String why,
    bool force = false,
  }) async {
    final kind = force ? await ChatNetworkLink.current() : _networkKind;
    if (force) _networkKind = kind;
    if (kind == ChatNetworkLinkKind.wifi ||
        kind == ChatNetworkLinkKind.mobile) {
      _lastNonOfflineKind = kind;
    }
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
    if (_tearingDown || _client == null) return;
    // Never leave :up as None — brief offline flaps during Wi‑Fi toggle used
    // to park TDLib in WaitingForNetwork for minutes (SessionLog 09:09).
    var kind = await ChatNetworkLink.current();
    if (kind == ChatNetworkLinkKind.offline ||
        kind == ChatNetworkLinkKind.unknown) {
      kind = _lastNonOfflineKind;
      _mediaLog(
        'reopen-up fallback kind=$kind (link was offline/unknown) why=$why',
      );
    }
    _networkKind = kind;
    if (kind == ChatNetworkLinkKind.wifi ||
        kind == ChatNetworkLinkKind.mobile) {
      _lastNonOfflineKind = kind;
    }
    final type = switch (kind) {
      ChatNetworkLinkKind.wifi => 'networkTypeWiFi',
      ChatNetworkLinkKind.mobile => 'networkTypeMobile',
      ChatNetworkLinkKind.unknown => 'networkTypeOther',
      ChatNetworkLinkKind.offline => 'networkTypeWiFi',
    };
    await _setNetworkType(type, why: '$why:up', force: true);
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
    if (!_useMtprotoProxy) {
      _mediaLog('proxy-cycle skip why=$why (direct MTProto)');
      return;
    }
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
      if (!_tdlibReadyForMedia) {
        _armFakeTlsQuiet(why: 'proxy-cycle:$why');
      }
    } catch (e) {
      // Do NOT addProxy — stacking produces hello-timeout floods on mtg.
      _mediaLog('proxy-cycle enableProxy id=$proxyId why=$why err=$e');
    }
  }

  List<TdlibProxyEndpoint> get _activeProxyEndpoints =>
      _remoteProxyEndpoints ?? TdlibConfig.proxyEndpoints;

  int get _activeProxyEpoch =>
      _remoteProxyEpoch ?? TdlibConfig.proxySecretEpoch;

  /// Remote list may override compile-time endpoints only when its epoch is
  /// **≥** [TdlibConfig.proxySecretEpoch]. Older API/cache must not pin the
  /// client to a removed hop (e.g. `200.164:443` after epoch 9).
  bool _remoteEpochUsable(int epoch) =>
      epoch >= TdlibConfig.proxySecretEpoch;

  Future<void> _discardStaleRemoteProxyCache(String why) async {
    _remoteProxyEndpoints = null;
    _remoteProxyEpoch = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_remoteProxyCacheKey);
    } catch (_) {}
    _mediaLog(
      'proxy-remote discard why=$why '
      'built-in n=${TdlibConfig.proxyEndpoints.length} '
      'epoch=${TdlibConfig.proxySecretEpoch}',
    );
  }

  /// Pull ordered FakeTLS endpoints from FamilyChat API (auth required).
  /// On failure / empty / stale epoch keeps compile-time fallback.
  Future<void> _refreshRemoteProxyEndpoints({bool force = false}) async {
    final last = _lastRemoteProxyFetchAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _remoteProxyFetchMinInterval &&
        _remoteProxyEndpoints != null) {
      return;
    }
    // Warm from disk once so cold boot can rotate secrets before network.
    if (_remoteProxyEndpoints == null) {
      await _loadCachedRemoteProxyEndpoints();
    }
    try {
      final raw = await _familychatRepo()
          .fetchMtprotoProxies()
          .timeout(const Duration(seconds: 5));
      _lastRemoteProxyFetchAt = DateTime.now();
      final parsed = TdlibConfig.parseRemoteProxies(raw);
      if (parsed == null) {
        _mediaLog(
          'proxy-remote empty/invalid — using built-in '
          'n=${TdlibConfig.proxyEndpoints.length} epoch=${TdlibConfig.proxySecretEpoch}',
        );
        return;
      }
      if (!_remoteEpochUsable(parsed.epoch)) {
        await _discardStaleRemoteProxyCache(
          'api-epoch=${parsed.epoch}<${TdlibConfig.proxySecretEpoch}',
        );
        return;
      }
      _remoteProxyEndpoints = parsed.endpoints;
      _remoteProxyEpoch = parsed.epoch;
      if (_proxyEndpointIndex >= parsed.endpoints.length) {
        _proxyEndpointIndex = 0;
      }
      await _saveCachedRemoteProxyEndpoints(raw);
      _mediaLog(
        'proxy-remote ok n=${parsed.endpoints.length} epoch=${parsed.epoch} '
        'primary=${parsed.endpoints.first.label}',
      );
    } catch (e) {
      _mediaLog('proxy-remote fetch soft-fail err=$e');
    }
  }

  Future<void> _loadCachedRemoteProxyEndpoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(_remoteProxyCacheKey);
      if (text == null || text.isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final parsed = TdlibConfig.parseRemoteProxies(
        Map<String, dynamic>.from(decoded),
      );
      if (parsed == null) return;
      if (!_remoteEpochUsable(parsed.epoch)) {
        await _discardStaleRemoteProxyCache(
          'cache-epoch=${parsed.epoch}<${TdlibConfig.proxySecretEpoch}',
        );
        return;
      }
      _remoteProxyEndpoints = parsed.endpoints;
      _remoteProxyEpoch = parsed.epoch;
      _mediaLog(
        'proxy-remote cache hit n=${parsed.endpoints.length} '
        'epoch=${parsed.epoch}',
      );
    } catch (_) {}
  }

  Future<void> _saveCachedRemoteProxyEndpoints(Map<String, dynamic> raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_remoteProxyCacheKey, jsonEncode(raw));
    } catch (_) {}
  }

  Future<void> _loadPreferredProxyEndpointIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString(_preferredProxyKey);
      if (key == null || key.isEmpty) return;
      final endpoints = _activeProxyEndpoints;
      final idx = endpoints.indexWhere((e) => '${e.server}:${e.port}' == key);
      if (idx < 0) return;
      _proxyEndpointIndex = idx;
      _mediaLog('proxy preferred restore idx=$idx key=$key');
    } catch (_) {}
  }

  Future<void> _persistPreferredProxyEndpoint(int index) async {
    final endpoints = _activeProxyEndpoints;
    if (index < 0 || index >= endpoints.length) return;
    final e = endpoints[index];
    final key = '${e.server}:${e.port}';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_preferredProxyKey, key);
      _mediaLog('proxy preferred save idx=$index key=$key label=${e.label}');
    } catch (_) {}
  }

  Future<void> _clearPreferredProxyEndpoint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_preferredProxyKey);
      _mediaLog('proxy preferred cleared');
    } catch (_) {}
  }

  /// Official TDLib: [pingProxy] measures reachability through a proxy and can
  /// run before auth / without Ready. Pick the lowest RTT among candidates.
  Future<int?> _probeBestProxyEndpointIndex({
    required String why,
    int? excludeIndex,
  }) async {
    final c = _client;
    if (c == null || _tearingDown || !_useMtprotoProxy) return null;
    if (_proxyProbeInFlight) {
      _mediaLog('proxy-probe skip in-flight why=$why');
      return null;
    }
    final last = _lastProxyProbeAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 20)) {
      _mediaLog('proxy-probe skip debounce why=$why');
      return null;
    }
    final endpoints = _activeProxyEndpoints;
    if (endpoints.length <= 1) return null;

    _proxyProbeInFlight = true;
    _lastProxyProbeAt = DateTime.now();
    try {
      // Ensure every endpoint has a TDLib row so we can ping by id.
      await _syncAllProxyEndpointRows(
        enableIndex: _proxyEndpointIndex.clamp(0, endpoints.length - 1),
      );
      if (_client == null || _tearingDown) return null;

      final scores = <int, double>{};
      for (var i = 0; i < endpoints.length; i++) {
        if (_tearingDown || _client == null) break;
        if (excludeIndex != null && i == excludeIndex) continue;
        final id = _endpointProxyIds[i];
        final label = endpoints[i].label;
        if (id == null) {
          _mediaLog('proxy-probe skip idx=$i label=$label (no id) why=$why');
          continue;
        }
        try {
          final ping = await c.sendAwait(
            {'@type': 'pingProxy', 'proxy_id': id},
            timeout: const Duration(seconds: 6),
          );
          final sec = (ping['seconds'] as num?)?.toDouble();
          if (sec == null || sec < 0) {
            _mediaLog(
              'proxy-probe bad idx=$i label=$label id=$id seconds=$sec why=$why',
            );
            continue;
          }
          scores[i] = sec;
          _lastPongMs = (sec * 1000).round();
          _lastPongAt = DateTime.now();
          _mediaLog(
            'proxy-probe ok idx=$i label=$label id=$id seconds=$sec why=$why',
          );
        } catch (e) {
          _mediaLog(
            'proxy-probe fail idx=$i label=$label id=$id err=$e why=$why',
          );
        }
      }

      if (scores.isEmpty) {
        _mediaLog('proxy-probe none-ok why=$why exclude=$excludeIndex');
        return null;
      }
      var bestIdx = scores.keys.first;
      var bestSec = scores[bestIdx]!;
      for (final e in scores.entries) {
        if (e.value < bestSec) {
          bestIdx = e.key;
          bestSec = e.value;
        }
      }
      _mediaLog(
        'proxy-probe best idx=$bestIdx label=${endpoints[bestIdx].label} '
        'seconds=$bestSec nOk=${scores.length}/${endpoints.length} why=$why',
      );
      return bestIdx;
    } finally {
      _proxyProbeInFlight = false;
    }
  }

  /// Keep one TDLib proxy row per configured endpoint; enable only [enableIndex].
  /// Avoids add/remove storms while still allowing [pingProxy] on candidates.
  Future<void> _syncAllProxyEndpointRows({required int enableIndex}) async {
    final c = _client;
    if (c == null || _tearingDown) return;
    final endpoints = _activeProxyEndpoints;
    if (endpoints.isEmpty) return;
    final idx = enableIndex.clamp(0, endpoints.length - 1);

    final existing = <Map<String, dynamic>>[];
    try {
      final list = await c.sendAwait({
        '@type': 'getProxies',
      }, timeout: const Duration(seconds: 5));
      final proxies = list['proxies'];
      if (proxies is List) {
        for (final raw in proxies) {
          if (raw is! Map) continue;
          existing.add(_flattenProxyEntry(raw));
        }
      }
    } catch (e) {
      _mediaLog('proxy sync getProxies soft-fail err=$e');
    }

    final wantKeys = <String>{
      for (final e in endpoints) '${e.server}:${e.port}',
    };
    for (final p in existing) {
      final id = (p['id'] as num?)?.toInt();
      if (id == null) continue;
      final type = p['type'];
      final typeName = type is Map ? type['@type']?.toString() ?? '' : '';
      final key = '${p['server']}:${p['port']}';
      if (typeName == 'proxyTypeMtproto' && wantKeys.contains(key)) continue;
      try {
        await c.sendAwait({
          '@type': 'removeProxy',
          'proxy_id': id,
        }, timeout: const Duration(seconds: 3));
        _mediaLog('proxy sync removed stale id=$id $key');
      } catch (e) {
        _mediaLog('proxy sync remove id=$id soft-fail err=$e');
      }
    }

    // Refresh after removals.
    existing.clear();
    try {
      final list = await c.sendAwait({
        '@type': 'getProxies',
      }, timeout: const Duration(seconds: 5));
      final proxies = list['proxies'];
      if (proxies is List) {
        for (final raw in proxies) {
          if (raw is! Map) continue;
          existing.add(_flattenProxyEntry(raw));
        }
      }
    } catch (_) {}

    _endpointProxyIds.clear();
    for (var i = 0; i < endpoints.length; i++) {
      final endpoint = endpoints[i];
      final key = '${endpoint.server}:${endpoint.port}';
      int? matchId;
      for (final p in existing) {
        final id = (p['id'] as num?)?.toInt();
        final type = p['type'];
        final typeName = type is Map ? type['@type']?.toString() ?? '' : '';
        if (id != null &&
            '${p['server']}:${p['port']}' == key &&
            typeName == 'proxyTypeMtproto') {
          matchId = id;
          break;
        }
      }
      if (matchId == null) {
        try {
          final res = await c.sendAwait({
            '@type': 'addProxy',
            'enable': false,
            'proxy': {
              '@type': 'proxy',
              'server': endpoint.server,
              'port': endpoint.port,
              'type': {
                '@type': 'proxyTypeMtproto',
                'secret': endpoint.secret,
              },
            },
          }, timeout: const Duration(seconds: 8));
          final flat = _flattenProxyEntry(res);
          matchId = (flat['id'] as num?)?.toInt() ??
              (res['id'] as num?)?.toInt();
          _mediaLog(
            'proxy sync added idx=$i label=${endpoint.label} id=$matchId '
            '$key (enable=false)',
          );
        } catch (e) {
          _mediaLog(
            'proxy sync add FAIL idx=$i label=${endpoint.label} err=$e',
          );
          continue;
        }
      } else {
        _mediaLog(
          'proxy sync reuse idx=$i label=${endpoint.label} id=$matchId $key',
        );
      }
      if (matchId != null) _endpointProxyIds[i] = matchId;
    }

    // Only one enabled proxy at a time (TDLib + FakeTLS hygiene).
    try {
      await c.sendAwait({
        '@type': 'disableProxy',
      }, timeout: const Duration(seconds: 3));
    } catch (_) {}
    final enableId = _endpointProxyIds[idx];
    if (enableId == null) {
      _enabledProxyId = null;
      _mediaLog('proxy sync FAIL no id for enableIndex=$idx');
      return;
    }
    try {
      await c.sendAwait({
        '@type': 'enableProxy',
        'proxy_id': enableId,
      }, timeout: const Duration(seconds: 8));
      _enabledProxyId = enableId;
      _proxyEndpointIndex = idx;
      _mediaLog(
        'proxy sync enabled idx=$idx label=${endpoints[idx].label} '
        'id=$enableId ${endpoints[idx].server}:${endpoints[idx].port}',
      );
      // Boot / geo ensure: first FakeTLS handshake needs quiet — soft-kick
      // enableProxy @35s was aborting TlsInit (SessionLog 16:01 + mtg
      // client-hello timeout). Same R14 arm as resume / hop-try.
      _armFakeTlsQuiet(why: 'proxy-enable:${endpoints[idx].label}');
    } catch (e) {
      _mediaLog('proxy sync enable id=$enableId FAIL err=$e');
    }
  }

  /// R21: Ready may land during `await pingProxy` / sync — never soft-nudge
  /// or hop-switch a healthy Ready session unless [evenIfReady] (R10 media).
  bool _failoverAbortIfReady({
    required bool evenIfReady,
    required String why,
  }) {
    if (_client == null || _tearingDown) return true;
    if (_tdlibReadyForMedia && !evenIfReady) {
      _mediaLog('proxy-failover skip already-Ready why=$why');
      return true;
    }
    return false;
  }

  /// Pick a working FakeTLS hop via [pingProxy] (official health check).
  /// On probe-miss: soft-nudge same hop — never blind round-robin.
  ///
  /// [evenIfReady]: session can be Ready while media/CDN is dead (Pong
  /// timeout + avatar 0B). Default false keeps stuck-Connecting ladder from
  /// thrashing a healthy Ready session.
  Future<void> _failoverProxy({
    required String why,
    bool evenIfReady = false,
  }) async {
    if (!_useMtprotoProxy) {
      _mediaLog('proxy-failover skip why=$why (direct MTProto)');
      return;
    }
    if (_failoverAbortIfReady(evenIfReady: evenIfReady, why: why)) return;
    final endpoints = _activeProxyEndpoints;
    if (endpoints.length <= 1) {
      // Single hop: soft re-enable only (no None-bounce cycle).
      if (_failoverAbortIfReady(
        evenIfReady: evenIfReady,
        why: 'single-hop:$why',
      )) {
        return;
      }
      _mediaLog('proxy-failover single-hop soft-nudge why=$why');
      await _softNudgeMtproto(why: 'proxy-failover-single:$why');
      return;
    }
    final last = _lastProxyFailoverAt;
    final minGap = evenIfReady
        ? const Duration(seconds: 90)
        : const Duration(seconds: 45);
    if (last != null && DateTime.now().difference(last) < minGap) {
      _mediaLog('proxy-failover skip debounce why=$why evenIfReady=$evenIfReady');
      if (!evenIfReady &&
          !_failoverAbortIfReady(
            evenIfReady: evenIfReady,
            why: 'debounce:$why',
          )) {
        await _softNudgeMtproto(why: 'proxy-failover-debounce:$why');
      }
      return;
    }
    if (evenIfReady) {
      final mediaLast = _lastMediaHealthFailoverAt;
      if (mediaLast != null &&
          DateTime.now().difference(mediaLast) < const Duration(minutes: 2)) {
        _mediaLog('proxy-failover skip media-health debounce why=$why');
        return;
      }
      _lastMediaHealthFailoverAt = DateTime.now();
    }

    final fromIdx = _proxyEndpointIndex.clamp(0, endpoints.length - 1);
    final from = endpoints[fromIdx];
    final probed = await _probeBestProxyEndpointIndex(
      why: why,
      excludeIndex: fromIdx,
    );
    // R21 (SessionLog 16:15 lock-reopen): Ready landed during pingProxy;
    // probe-miss soft-nudge enableProxy tore Ready→Connecting.
    if (_failoverAbortIfReady(
      evenIfReady: evenIfReady,
      why: 'after-probe:$why',
    )) {
      return;
    }
    // Blind RR after probe-miss tore Ready (20:49) and pause-resume (17:06).
    // Official: user switches proxy manually; we only move on a better ping.
    // Exception R12: while long-bg Connecting, pingProxy often times out on
    // *every* hop (SessionLog 22:12) — reopen (soft-restart) if under cap,
    // else one no-ping hop try (manual switch analogue).
    if (probed == null) {
      _mediaLog(
        'proxy-failover skip probe-miss keep=${from.label} why=$why '
        'evenIfReady=$evenIfReady (no blind RR)',
      );
      if (_longBackgroundResume &&
          !_tdlibReadyForMedia &&
          _longBackgroundSoftRestartCount < _longBgSoftRestartCap) {
        _mediaLog(
          'proxy-failover probe-miss → soft-restart '
          '(longBg Connecting, ping unreliable) '
          'restartCount=$_longBackgroundSoftRestartCount',
        );
        _longBackgroundSoftRestartCount =
            (_longBackgroundSoftRestartCount + 1).clamp(1, _longBgSoftRestartCap);
        await _recoverDeadClient(
          'stuck-connecting-longbg-probe-miss:$why',
          preserveLongBgEscalation: true,
        );
        return;
      }
      if (_longBackgroundResume && !_tdlibReadyForMedia) {
        await _tryNextHopNoPing(why: 'probe-miss:$why');
        return;
      }
      // Still Connecting only — never enableProxy after Ready (R21).
      if (_failoverAbortIfReady(
        evenIfReady: evenIfReady,
        why: 'probe-miss:$why',
      )) {
        return;
      }
      await _softNudgeMtproto(why: 'proxy-failover-miss:$why');
      return;
    }
    final next = probed;
    final to = endpoints[next];
    if (next == fromIdx) {
      _mediaLog(
        'proxy-failover skip same-hop why=$why label=${from.label} '
        'evenIfReady=$evenIfReady',
      );
      return;
    }
    if (_failoverAbortIfReady(
      evenIfReady: evenIfReady,
      why: 'before-hop:${to.label}:$why',
    )) {
      return;
    }

    _lastProxyFailoverAt = DateTime.now();
    _proxyEndpointIndex = next;
    // Don't persist until the new hop proves media via pingProxy.
    unawaited(_clearPreferredProxyEndpoint());
    _mediaLog(
      'proxy-failover why=$why from=${from.label} to=${to.label} '
      'via=pingProxy evenIfReady=$evenIfReady '
      'conn=$_connectionState net=$_networkKind',
    );
    // Fresh wait clock; stage=3 so next escalate is soft-restart, not RR loop.
    _connectingSince = DateTime.now();
    _connectionKickCount = 3;
    _lastConnectionKickAt = DateTime.now();
    _mediaLog('mtproto-kick-reset why=proxy-failover:${to.label} stage=3');
    await _syncAllProxyEndpointRows(enableIndex: next);
    if (_client == null || _tearingDown) return;
    if (_failoverAbortIfReady(
      evenIfReady: evenIfReady,
      why: 'after-sync:${to.label}:$why',
    )) {
      return;
    }
    // Soft attach to new hop — no networkTypeNone bounce (official resume).
    await _softNudgeMtproto(
      why: 'proxy-failover:${to.label}',
      forceEnableProxy: true,
    );
    if (!_tdlibReadyForMedia) {
      _armFakeTlsQuiet(why: 'proxy-failover:${to.label}');
    }
    final proxyId = _enabledProxyId;
    if (proxyId != null && _client != null) {
      unawaited(_pingProxyWhenReady(_client!, proxyId));
    }
  }

  /// Last-resort after long-bg reopen×2 when pingProxy is useless while
  /// Connecting: enable the next FakeTLS hop once (user would switch manually).
  /// Not mid-download RR; only wedged Connecting after soft-restart cap.
  /// After switch: reset soft-restart count so the **new** hop gets its own
  /// soft→soft→soft-restart cycle (R14 — SessionLog 22:55 hop-try then only
  /// soft-nudge spam forever with restartCount stuck at cap).
  Future<void> _tryNextHopNoPing({required String why}) async {
    if (!_useMtprotoProxy || _client == null || _tearingDown) return;
    if (_tdlibReadyForMedia) {
      _mediaLog('longbg-hop-try skip (already Ready) why=$why');
      return;
    }
    final endpoints = _activeProxyEndpoints;
    if (endpoints.length <= 1) {
      _mediaLog('longbg-hop-try single-hop soft-nudge why=$why');
      await _softNudgeMtproto(
        why: 'longbg-hop-single:$why',
        forceEnableProxy: true,
      );
      _armFakeTlsQuiet(why: 'longbg-hop-single');
      return;
    }
    final last = _lastLongBgHopTryAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 5)) {
      _mediaLog('longbg-hop-try skip debounce why=$why');
      // R16: soft-nudge forever after hop exhaustion does nothing — one
      // None→current socket reopen (hibernation workaround), not first recover.
      await _longBgSocketReopenLastResort(why: 'hop-debounce:$why');
      return;
    }
    _lastLongBgHopTryAt = DateTime.now();
    final fromIdx = _proxyEndpointIndex.clamp(0, endpoints.length - 1);
    final nextIdx = (fromIdx + 1) % endpoints.length;
    final from = endpoints[fromIdx];
    final to = endpoints[nextIdx];
    _mediaLog(
      'longbg-hop-try why=$why from=${from.label} to=${to.label} '
      '(no ping — Connecting wedged after reopen×$_longBackgroundSoftRestartCount)',
    );
    _connectingSince = DateTime.now();
    _connectionKickCount = 0;
    _lastConnectionKickAt = null;
    // Fresh soft-restart budget on the new endpoint.
    _longBackgroundSoftRestartCount = 0;
    _mediaLog('longbg-hop-try reset restartCount for new hop');
    await _syncAllProxyEndpointRows(enableIndex: nextIdx);
    if (_client == null || _tearingDown) return;
    await _softNudgeMtproto(
      why: 'longbg-hop-try:${to.label}',
      forceEnableProxy: true,
    );
    _armFakeTlsQuiet(why: 'longbg-hop-try:${to.label}');
  }

  /// Post-ladder last resort: None→current reopen after hop-try exhausted.
  /// Forbidden as first recover (aborts mid-handshake); OK after reopen×2 +
  /// hop-try still Connecting (bugs.telegram hibernation / Unigram reopen).
  Future<void> _longBgSocketReopenLastResort({required String why}) async {
    if (!_useMtprotoProxy || _client == null || _tearingDown) return;
    if (_tdlibReadyForMedia) {
      _mediaLog('longbg-socket-reopen skip (already Ready) why=$why');
      return;
    }
    final last = _lastLongBgSocketReopenAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 5)) {
      _mediaLog('longbg-socket-reopen skip debounce why=$why');
      await _softNudgeMtproto(why: 'longbg-socket-reopen-debounce:$why');
      return;
    }
    _lastLongBgSocketReopenAt = DateTime.now();
    _mediaLog(
      'longbg-socket-reopen why=$why '
      '(post-ladder last resort — not first recover)',
    );
    await _reopenNetworkConnections(why: 'longbg-socket-reopen');
    if (_tearingDown || _client == null || _tdlibReadyForMedia) return;
    await _softNudgeMtproto(
      why: 'longbg-socket-reopen:$why',
      forceEnableProxy: true,
    );
    if (!_tdlibReadyForMedia) {
      _armFakeTlsQuiet(why: 'longbg-socket-reopen');
    }
    _connectingSince = DateTime.now();
    _connectionKickCount = 0;
    _lastConnectionKickAt = null;
    // Allow another soft-restart cycle after quiet if still wedged.
    if (_longBackgroundResume) {
      _longBackgroundSoftRestartCount = 0;
    }
  }

  void _pumpDownloadQueue() {
    // Local disk hits must never wait on connection state.
    // Network downloads: gate on auth ready (td#1176), NOT connectionStateReady.
    if (!_canStartNetworkDownload) {
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
          'pump-wait-auth queued=${_downloadQueue.length} '
          'inflight=${_downloadInFlight.length} conn=$_connectionState '
          'phase=$phase net=$_networkKind '
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
      // With MTProto proxy: cap hub-avatar parallelism to the hub slot limit.
      // Serial-only was worse — one 0B poison remote blocked the whole
      // viewport for 12s+ while good remotes waited unused behind it.
      final hubInflightCap = _enabledProxyId != null ? 1 : _maxConcurrentDownloads;
      final hubInflightCount = _enabledProxyId == null
          ? 0
          : _downloadInFlight.where((id) {
              final r = _downloadTrace[id]?.reason ?? '';
              return r == 'hub-avatar';
            }).length;
      final idx = _downloadQueue.indexWhere((j) {
        if (_openChatId != null && j.background) return false;
        if (_enabledProxyId != null &&
            j.reason == 'hub-avatar' &&
            hubInflightCount >= hubInflightCap) {
          return false;
        }
        return true;
      });
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

  /// True if we already know a local path (RAM cache).
  /// Do NOT existsSync here — download/queue paths call this often; sync disk
  /// I/O on the UI isolate stalls fling in photo-heavy chats.
  bool _hasCachedPath(int fileId) {
    final path = _filePathCache[fileId];
    return path != null && path.isNotEmpty;
  }

  /// Temp TDLib paths like `…/370` (no extension) are not paint-ready — completing
  /// the waiter with them opens the viewer stub (SessionLog 16:21 path=370 →
  /// real `_120.jpg` 3ms later).
  bool _isPaintReadyMediaPath(String path) {
    if (path.isEmpty) return false;
    final name = p.basename(path);
    if (!name.contains('.')) return false;
    final lower = name.toLowerCase();
    const ok = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.mp4', '.mov', '.webm'];
    return ok.any(lower.endsWith);
  }

  /// Bubble-sharp photo on disk (~x / ≥40KB). Sync I/O only on focus/tap paths.
  bool _isSharpPhotoPath(String path) {
    if (!_isPaintReadyMediaPath(path)) return false;
    try {
      return File(path).lengthSync() >= 40 * 1024;
    } catch (_) {
      return false;
    }
  }

  bool _hasSharpPhotoCached(int fileId) {
    final path = _filePathCache[fileId];
    if (path == null || path.isEmpty) return false;
    return _isSharpPhotoPath(path);
  }

  /// File id to download for a sharp bubble (prefer x/y/w fallback).
  int? _photoUpgradeFileId(TdlibMessage m) {
    if (_photoBubbleSharp(m)) return null;
    for (final id in m.photoFallbackFileIds) {
      if (id > 0 && !_hasSharpPhotoCached(id)) return id;
    }
    final primary = m.photoRemoteId;
    if (primary != null && primary > 0 && !_hasSharpPhotoCached(primary)) {
      return primary;
    }
    return null;
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
    if (!_canStartNetworkDownload) {
      _mediaLog(
        'start-defer file=$fileId reason=${t?.reason ?? reason} '
        'conn=$_connectionState phase=$phase net=$_networkKind',
      );
      // Return slot to queue until auth ready / online (not connectionState).
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
      // Official Telegram / stock TDLib: offset=0 → CDN allowed.
      // FC used to prefer offset=1 on every first FakeTLS attempt; that
      // diverged from official on the same proxy (Ready+0B while official OK).
      // Default CDN; after a 0B stall, stall-recover may force origin once.
      final forceBypass = _downloadForceBypassCdnOnce.remove(fileId);
      final bypassCdn = forceBypass;
      if (bypassCdn) {
        _downloadTriedBypassCdn.add(fileId);
      }
      final dlOffset = bypassCdn ? 1 : 0;
      if (t != null) {
        t.offset = dlOffset;
        t.netAtStart = _networkKind.name;
        t.sampleBytes = t.lastBytes;
        t.sampleAt = DateTime.now();
      }
      // Channel media: re-assert open/view right before downloadFile so CDN
      // auth is not lost to focus thrash / cancelled hub downloads.
      final chatForOpen = t?.chatId ?? _openChatId;
      if (chatForOpen != null && chatForOpen < 0) {
        await _openMessageContentForFile(chatForOpen, fileId);
      }
      _mediaLog(
        'net-downloadFile file=$fileId reason=$reasonNow '
        'prio=$priority size=${t != null && t.expectedSize > 0 ? _fmtBytes(t.expectedSize) : '?'} '
        'offset=$dlOffset cdnBypass=$bypassCdn forceBypass=$forceBypass sync=false '
        'net=${_networkKind.name} '
        '${_downloadQueueStats()}',
      );
      _slog('tg.media', 'download_start', {
        'fileId': fileId,
        'reason': reasonNow,
        'prio': priority,
        'size': t?.expectedSize,
        'offset': dlOffset,
        'cdnBypass': bypassCdn,
        'forceBypass': forceBypass,
        'chatId': t?.chatId ?? _openChatId,
        'slots': '$_downloadActive/$_downloadSlotLimit',
      });
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
        'conn=$_connectionState bypassCdn=$bypassCdn net=${_networkKind.name}',
      );
      _slog('tg.media', 'download_ack', {
        'fileId': fileId,
        'offset': dlOffset,
        'cdnBypass': bypassCdn,
      });
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
    if (!_isPaintReadyMediaPath(path)) {
      _mediaLog(
        'complete-defer file=$fileId path=${p.basename(path)} '
        '(unready — keep waiter)',
      );
      return;
    }
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
    _hubAvatarStallAttempts.remove(fileId);
    _hubAvatarCooldownUntil.remove(fileId);
    _hubAvatarCoolUntil.remove(fileId);
    _hubAvatarPoisonFileIds.remove(fileId);
    final doneRemote = t?.remoteUniqueId.trim() ?? '';
    if (doneRemote.isNotEmpty) {
      _hubAvatarPoisonRemotes.remove(doneRemote);
    }
    _downloadForceBypassCdnOnce.remove(fileId);
    _downloadTriedBypassCdn.remove(fileId);
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
        // Another soft bubble may be on-screen — let UI re-pick by layout.
        _notifyViewportMediaRescan();
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
            // One upgrade at a time — parallel x/y/w starved the CDN slot.
            final id = upgrades.first;
            _queueFileDownload(
              id,
              priority: prioFocused,
              background: false,
              chatId: chatId,
              reason: 'focus-upgrade:${msg.id}',
            );
          } else if (msg.photoSizeType == 'm' ||
              msg.photoSizeType == 's' ||
              msg.photoSizeType == null) {
            // Soft-only sizes list — refresh after open so TDLib exposes x/y.
            unawaited(
              _enqueueNeighborMediaAsync(chatId: chatId, messageId: msg.id),
            );
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
    // Hub avatars: TDLib often remaps file ids (download under 12xxx, chat.photo
    // later points at 18xxx). Alias the path onto the chat's current small/big
    // ids so hubChats/chatPreviewById find it — otherwise minithumbs stick
    // forever even after a successful download.
    if (reason == 'hub-avatar') {
      if (chatId != null && chatId != 0) {
        _aliasHubAvatarPath(chatId, fileId, path);
      }
      _notifyUi(immediate: true);
    } else {
      _notifyUi(media: true);
    }
  }

  /// Copy [path] onto [downloadedId] and the matching small/big File entry
  /// (same id only). Do NOT stamp onto the other size — that made soft
  /// `small` paths look like cached `big` and blocked sharp upgrades forever.
  void _aliasHubAvatarPath(int chatId, int downloadedId, String path) {
    _filePathCache[downloadedId] = path;
    final chat = _chats[chatId];
    if (chat == null) return;
    var aliased = 0;
    void stampPhoto(dynamic photo) {
      if (photo is! Map) return;
      for (final key in ['small', 'big']) {
        final f = photo[key];
        if (f is! Map) continue;
        final id = _tdlibInt(f['id']);
        if (id != downloadedId) continue;
        aliased++;
        final local = f['local'];
        if (local is Map) {
          local['is_downloading_completed'] = true;
          local['path'] = path;
        } else {
          f['local'] = <String, dynamic>{
            '@type': 'localFile',
            'path': path,
            'is_downloading_completed': true,
            'can_be_downloaded': true,
            'can_be_deleted': true,
            'is_downloading_active': false,
          };
        }
      }
    }

    stampPhoto(chat['photo']);
    final type = chat['type'];
    if (type is Map && type['@type']?.toString() == 'chatTypePrivate') {
      final uid = _tdlibInt(type['user_id']);
      if (uid > 0) stampPhoto(_users[uid]?['profile_photo']);
    }
    if (aliased > 0) {
      _mediaLog(
        'hub-avatar alias chat=$chatId file=$downloadedId '
        'aliased=$aliased path=${p.basename(path)}',
      );
    }
  }

  /// Stamp the downloaded path onto the matching media field (photo vs video thumb).
  TdlibMessage? _messageWithDownloadedFile(
    TdlibMessage m,
    int fileId,
    String path,
  ) {
    if (m.documentThumbFileId == fileId) {
      if (m.documentThumbLocalPath == path) return null;
      return _copyMessage(m, documentThumbLocalPath: path);
    }
    if (m.documentFileId == fileId) {
      if (m.documentLocalPath == path) return null;
      return _copyMessage(m, documentLocalPath: path);
    }
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
      // Fallback ids are x/y/w upgrades — stamp type so the bubble stops
      // treating a sharp file as soft `m` (same path may already be set).
      final upgraded = m.photoFallbackFileIds.contains(fileId) &&
          m.photoRemoteId != fileId &&
          (m.photoSizeType == null ||
              m.photoSizeType == 'm' ||
              m.photoSizeType == 's');
      if (m.photoLocalPath == path && !upgraded) return null;
      return _copyMessage(
        m,
        photoLocalPath: path,
        photoSizeType: upgraded ? 'x' : null,
      );
    }
    // Fallback: treat as photo path (legacy callers).
    if (m.photoLocalPath == path) return null;
    return _copyMessage(m, photoLocalPath: path);
  }

  TdlibMessage _copyMessage(
    TdlibMessage m, {
    String? photoLocalPath,
    String? photoSizeType,
    String? voiceLocalPath,
    String? videoNoteLocalPath,
    String? videoNoteThumbLocalPath,
    String? videoLocalPath,
    String? videoThumbLocalPath,
    String? documentLocalPath,
    String? documentThumbLocalPath,
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
      photoSizeType: photoSizeType ?? m.photoSizeType,
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
      videoSizeBytes: m.videoSizeBytes,
      videoThumbFileId: m.videoThumbFileId,
      videoThumbLocalPath: videoThumbLocalPath ?? m.videoThumbLocalPath,
      videoThumbBytes: m.videoThumbBytes,
      isAnimation: m.isAnimation,
      isSticker: m.isSticker,
      stickerEmoji: m.stickerEmoji,
      documentFileId: m.documentFileId,
      documentLocalPath: documentLocalPath ?? m.documentLocalPath,
      documentFileName: m.documentFileName,
      documentMimeType: m.documentMimeType,
      documentSizeBytes: m.documentSizeBytes,
      documentThumbFileId: m.documentThumbFileId,
      documentThumbLocalPath:
          documentThumbLocalPath ?? m.documentThumbLocalPath,
      documentThumbBytes: m.documentThumbBytes,
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
      sendingState: m.sendingState,
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
        final sampleAt = t.sampleAt;
        final bytesDelta5s = sampleAt == null
            ? downloaded
            : (downloaded - t.sampleBytes);
        if (sampleAt == null ||
            now.difference(sampleAt) >= const Duration(seconds: 5)) {
          t.sampleBytes = downloaded;
          t.sampleAt = now;
        }
        _mediaLog(
          'progress file=$fileId reason=${t.reason} '
          '${_fmtBytes(downloaded)}/${expectedSize > 0 ? _fmtBytes(expectedSize) : '?'} '
          'active=$active '
          'elapsed=${_fmtDur(elapsed)} '
          '${rate > 0 ? 'rate=${_fmtBytes(rate.round())}/s' : 'rate=?'} '
          'delta5s=${_fmtBytes(bytesDelta5s)} '
          'offset=${t.offset} net=${_networkKind.name} '
          'conn=$_connectionState',
        );
        _slog('tg.media', 'download_progress', {
          'fileId': fileId,
          'reason': t.reason,
          'downloaded': downloaded,
          'size': expectedSize > 0 ? expectedSize : t.expectedSize,
          'active': active,
          'elapsedMs': elapsed.inMilliseconds,
          'bytesDelta5s': bytesDelta5s,
          'offset': t.offset,
          'rateBps': rate.round(),
        });
      }
      t.lastProgressAt = now;
    }
    if (completed) {
      _fileDownloadProgress.remove(fileId);
      return;
    }
    // Proxy/CDN: bytes fill to 100% but is_downloading_completed never flips.
    // Finalize from path or getFile so the hub-avatar queue is not wedged.
    if (expectedSize > 0 && downloaded >= expectedSize) {
      final path = local['path']?.toString();
      if (path != null &&
          path.isNotEmpty &&
          _isPaintReadyMediaPath(path)) {
        _mediaLog(
          'progress-complete file=$fileId reason=${t?.reason ?? ''} '
          'size=${_fmtBytes(downloaded)} (bytes-full, no completed flag)',
        );
        _completeFileDownload(fileId, path);
        return;
      }
      if (path != null && path.isNotEmpty) {
        _mediaLog(
          'progress-complete defer file=$fileId '
          'reason=${t?.reason ?? ''} path=${p.basename(path)} '
          '(temp/unready path — wait rename)',
        );
      }
      unawaited(() async {
        if (!_downloadInFlight.contains(fileId)) return;
        if (await _probeLocalFile(fileId)) {
          final localPath = _filePathCache[fileId];
          if (localPath != null && localPath.isNotEmpty) {
            _mediaLog(
              'progress-probe-complete file=$fileId '
              'reason=${_downloadTrace[fileId]?.reason ?? ''} '
              'path=${p.basename(localPath)}',
            );
            _completeFileDownload(fileId, localPath);
          }
        }
      }());
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

  /// Drop pending/in-flight background jobs when opening a chat.
  /// Cancel TDLib transfers — leaving them running flooded FakeTLS with
  /// domain-fronting (VPS Shariy test: DF≫relay, zero DC203).
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
      _downloadTrace.remove(j.fileId);
    }

    final inflightBg = _downloadBackgroundIds.toList();
    var cancelled = 0;
    for (final id in inflightBg) {
      final t = _downloadTrace[id];
      if (openId != null && t?.chatId == openId) {
        _downloadBackgroundIds.remove(id);
        if (t != null) {
          t.background = false;
          t.priority = prioFocused;
        }
        continue;
      }
      await _cancelTdlibDownload(id);
      _releaseDownloadSlot(id, failed: true);
      cancelled++;
      final waiter = _downloadWaiters.remove(id);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(_filePathCache[id]);
      }
    }
    if (cancelled > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (pendingBg.isNotEmpty || inflightBg.isNotEmpty) {
      debugPrint(
        '[tdlib] suspended bg downloads pending=${pendingBg.length} '
        'inflight=${inflightBg.length} cancelled=$cancelled',
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

  /// Debug AppBar: user allow-FakeTLS intent (not the live geo result).
  /// Live wire state is [_useMtprotoProxy] (may be false under VPN while
  /// AppBar stays ON — R18).
  bool get mtprotoProxyEnabled =>
      kDebugMode ? _debugMtprotoProxyPref : _useMtprotoProxy;

  /// Debug AppBar toggle: user force-OFF vs allow-geo (persisted). Default ON.
  /// ON → clear user-off and re-resolve via [_ensureProxy] (geo). OFF → direct.
  Future<void> setMtprotoProxyEnabled(bool enabled) async {
    if (kDebugMode) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDebugMtprotoProxyPref, enabled);
      _debugMtprotoProxyPref = enabled;
      _debugMtprotoProxyPrefLoaded = true;
    }
    _useMtprotoProxyResolved = null;
    if (!enabled) {
      _useMtprotoProxy = false;
    }
    notifyListeners();

    final c = _client;
    if (c == null) return;
    if (enabled) {
      _mediaLog('proxy switch → ON (follow geo)');
      await _ensureProxy();
    } else {
      _mediaLog('proxy switch → OFF (user)');
      await _disableAllProxies(c, why: 'debug-switch-off');
      _enabledProxyId = null;
    }
    notifyListeners();
  }

  Future<void> _loadDebugMtprotoProxyPref() async {
    if (!kDebugMode || _debugMtprotoProxyPrefLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kDebugMtprotoProxyR18Migrated) != true) {
        // Pre-R18 geo wrote AppBar OFF and blocked all later rechecks.
        await prefs.setBool(_kDebugMtprotoProxyPref, true);
        await prefs.setBool(_kDebugMtprotoProxyR18Migrated, true);
        _debugMtprotoProxyPref = true;
        _mediaLog('proxy R18 migrate: reset sticky AppBar OFF → allow');
      } else {
        _debugMtprotoProxyPref =
            prefs.getBool(_kDebugMtprotoProxyPref) ?? true;
      }
    } catch (_) {
      _debugMtprotoProxyPref = true;
    }
    _debugMtprotoProxyPrefLoaded = true;
  }

  /// True when [chatId] is Telegram Saved Messages (private chat with self).
  bool isSavedMessagesChat(int chatId) {
    final myId = _myUserId;
    if (myId == null || myId <= 0) return false;
    final peer = _privateUserId(chatId);
    return peer != null && peer == myId;
  }

  /// Chat id for Saved Messages when known (usually equals [myUserId]).
  int? get savedMessagesChatId {
    final myId = _myUserId;
    if (myId == null || myId <= 0) return null;
    return privateChatIdForUser(myId) ?? myId;
  }

  /// Optional hook for FC↔TG group bridge (TG→FC ingest).
  final List<void Function(TdlibMessage msg)> _bridgeNewMessageListeners = [];

  /// Register a TG→FC bridge listener (group / saved). Multicast-safe.
  void addBridgeNewMessageListener(void Function(TdlibMessage msg) listener) {
    if (!_bridgeNewMessageListeners.contains(listener)) {
      _bridgeNewMessageListeners.add(listener);
    }
  }

  void removeBridgeNewMessageListener(void Function(TdlibMessage msg) listener) {
    _bridgeNewMessageListeners.remove(listener);
  }

  /// Legacy single-slot setter — prefer [addBridgeNewMessageListener].
  set onBridgeNewMessage(void Function(TdlibMessage msg)? listener) {
    _bridgeNewMessageListeners.clear();
    if (listener != null) _bridgeNewMessageListeners.add(listener);
  }

  /// True when MTProto can carry media bytes (Ready / Updating).
  bool get isMtprotoReadyForMedia => _tdlibReadyForMedia;

  /// Raw TDLib connection state name (`connectionStateReady`, …).
  String get mtprotoConnectionState => _connectionState;

  /// App-bar subtitle when media is blocked on connection — empty when Ready
  /// or still within [_kConnectionStatusGrace] (avoids flicker on short flaps).
  ///
  /// No network at all → empty: [FamilyAppBarTitle] / ChatUiConnectivity shows
  /// the shared «Ожидание соединения» loader (not proxy-waiting copy).
  String get connectionStatusLabel {
    if (_networkKind == ChatNetworkLinkKind.offline) return '';
    switch (_connectionState) {
      case 'connectionStateReady':
      case 'connectionStateUpdating':
        return '';
      case 'connectionStateWaitingForNetwork':
        // Device offline / no route — FC AppBar offline title owns this UX.
        return '';
      case 'connectionStateConnectingToProxy':
      case 'connectionStateConnecting':
      default:
        final since = _connectingSince;
        if (since == null ||
            DateTime.now().difference(since) < _kConnectionStatusGrace) {
          return '';
        }
        return _useMtprotoProxy
            ? 'ожидание подключения к прокси…'
            : 'подключение…';
    }
  }

  List<TdlibMessage> messagesFor(int chatId) =>
      List.unmodifiable(_messagesByChat[chatId] ?? const []);

  int lastReadOutboxId(int chatId) => _lastReadOutboxId[chatId] ?? 0;

  /// Last inbox message the user has read (TDLib + local mark-read floor).
  int lastReadInboxMessageId(int chatId) => _effectiveLastReadInbox(chatId);

  int _effectiveLastReadInbox(int chatId) {
    final fromChat = _tdlibInt(_chats[chatId]?['last_read_inbox_message_id']);
    final fromFloor = _readInboxFloor[chatId] ?? 0;
    return fromChat > fromFloor ? fromChat : fromFloor;
  }

  /// Merge a TDLib `chat` payload without regressing inbox read progress.
  void _applyChatRow(int chatId, Map<String, dynamic> incoming) {
    final prev = _chats[chatId];
    final next = Map<String, dynamic>.from(incoming);
    final prevRead =
        prev == null ? 0 : _tdlibInt(prev['last_read_inbox_message_id']);
    final incRead = _tdlibInt(next['last_read_inbox_message_id']);
    final floor = _readInboxFloor[chatId] ?? 0;
    var bestRead = prevRead;
    if (incRead > bestRead) bestRead = incRead;
    if (floor > bestRead) bestRead = floor;
    if (bestRead > 0) {
      next['last_read_inbox_message_id'] = bestRead;
      if (bestRead > floor) _readInboxFloor[chatId] = bestRead;
    }
    final last = next['last_message'] ?? prev?['last_message'];
    if (last is Map) {
      final tipId = _tdlibInt(last['id']);
      if (tipId > 0 && tipId <= bestRead) {
        next['unread_count'] = 0;
      }
    }
    _chats[chatId] = next;
  }

  /// Authoritative-enough unread for hub badges.
  ///
  /// TDLib sometimes delivers `updateChatLastMessage` (so the preview text
  /// moves) while `unread_count` stays 0 until a later `updateChatReadInbox`
  /// — or that update is dropped. For matched FC↔TG DMs that left the hub
  /// badge empty while the tip was clearly unread. If the tip is inbound and
  /// past `last_read_inbox_message_id`, treat as at least 1 unread.
  ///
  /// Once the tip is at/below the read floor (including optimistic local
  /// mark-read), always report 0 — even if a later stale `getChat` temporarily
  /// regresses TDLib's own last_read / unread fields.
  int unreadCountFor(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return 0;
    final last = chat['last_message'];
    final lastId = last is Map ? _tdlibInt(last['id']) : 0;
    final lastRead = _effectiveLastReadInbox(chatId);
    if (lastId > 0 && lastId <= lastRead) return 0;
    // Progressive read in an open chat: when the tip is in RAM, count inbound
    // messages past the floor. Stale `unread_count` from TDLib otherwise kept
    // the FAB badge stuck until the tip itself was marked (Mash scroll).
    final list = _messagesByChat[chatId];
    if (list != null && list.isNotEmpty) {
      final hasTip = lastId <= 0 || list.any((m) => m.id == lastId);
      if (hasTip) {
        var counted = 0;
        for (final m in list) {
          if (m.isOutgoing) continue;
          if (m.id > lastRead) counted++;
        }
        return counted;
      }
    }
    final reported = _tdlibInt(chat['unread_count']);
    if (reported > 0) return reported;
    if (last is! Map) return 0;
    if (last['is_outgoing'] == true) return 0;
    if (lastId <= 0) return 0;
    if (lastId > lastRead) return 1;
    return 0;
  }

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

  /// True when RAM already has enough history to jump to the unread frontier
  /// without waiting on getChatHistory at open.
  bool isUnreadHistoryWarm(int chatId) {
    final unread = unreadCountFor(chatId);
    if (unread <= 0) return true;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return false;
    // Hub preview comes from chat.last_message — if that tip isn't in RAM,
    // open would paint a stale transcript (Киса: list showed tip, chat didn't).
    final tip = _chats[chatId]?['last_message'];
    final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
    if (tipId > 0 && !list.any((m) => m.id == tipId)) return false;
    final lastRead = lastReadInboxMessageId(chatId);
    if (lastRead > 0 && list.first.id <= lastRead) return true;
    final loadedUnread =
        lastRead > 0 ? list.where((m) => m.id > lastRead).length : list.length;
    if (loadedUnread >= unread) return true;
    // Single unread at tip — reverse list already lands there.
    if (unread == 1 && tipId > 0 && list.any((m) => m.id == tipId)) {
      return true;
    }
    return false;
  }

  void _advanceReadInboxFloor(int chatId, int messageId) {
    if (chatId == 0 || messageId <= 0) return;
    final prev = _readInboxFloor[chatId] ?? 0;
    if (messageId > prev) _readInboxFloor[chatId] = messageId;
    final chat = _chats[chatId];
    if (chat == null) return;
    final cur = _tdlibInt(chat['last_read_inbox_message_id']);
    if (messageId > cur) {
      chat['last_read_inbox_message_id'] = messageId;
    }
    final tip = chat['last_message'];
    final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
    if (tipId > 0 && tipId <= messageId) {
      chat['unread_count'] = 0;
      return;
    }
    // Optimistic badge while TDLib's unread_count lags viewMessages.
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    final hasTip = tipId <= 0 || list.any((m) => m.id == tipId);
    if (hasTip) {
      var remaining = 0;
      for (final m in list) {
        if (m.isOutgoing) continue;
        if (m.id > messageId) remaining++;
      }
      chat['unread_count'] = remaining;
      return;
    }
    var justRead = 0;
    for (final m in list) {
      if (m.isOutgoing) continue;
      if (m.id > prev && m.id <= messageId) justRead++;
    }
    if (justRead <= 0) return;
    final reported = _tdlibInt(chat['unread_count']);
    if (reported > 0) {
      chat['unread_count'] = (reported - justRead).clamp(0, reported);
    }
  }

  Future<void> markMessagesRead(int chatId, List<int> messageIds) async {
    final c = _client;
    if (c == null || !isReady || messageIds.isEmpty) return;
    var maxId = 0;
    for (final id in messageIds) {
      if (id > maxId) maxId = id;
    }
    if (maxId > 0) {
      _advanceReadInboxFloor(chatId, maxId);
      _hubChatsCache = null;
      _notifyListenersForChat(chatId);
    }
    assert(() {
      debugPrint(
        '[unread-dbg] markMessagesRead chat=$chatId ids=$messageIds '
        'unread=${unreadCountFor(chatId)}\n${StackTrace.current}',
      );
      return true;
    }());
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

  /// Mark the current tip as read (matched FC DM / catch-up without opening TG).
  Future<void> markChatTipRead(int chatId) async {
    if (chatId == 0 || !isReady) return;
    final chat = _chats[chatId];
    if (chat == null) return;
    final last = chat['last_message'];
    if (last is! Map) return;
    final tipId = _tdlibInt(last['id']);
    if (tipId <= 0) return;
    if (tipId <= _effectiveLastReadInbox(chatId)) return;
    await markMessagesRead(chatId, [tipId]);
  }

  /// Auto-mark incoming tip only when the inbox is already caught up. Otherwise
  /// opening a chat / syncing the tip would wipe the unread divider.
  void _maybeAutoMarkRead(int chatId, int messageId) {
    if (chatId != _openChatId || messageId <= 0) return;
    if (unreadCountFor(chatId) > 0) return;
    assert(() {
      debugPrint('[unread-dbg] autoMarkRead chat=$chatId msg=$messageId');
      return true;
    }());
    _advanceReadInboxFloor(chatId, messageId);
    unawaited(_client?.sendAwait({
      '@type': 'viewMessages',
      'chat_id': chatId,
      'message_ids': [messageId],
      'force_read': true,
    }));
  }

  String outgoingReadStatus(TdlibMessage m) {
    if (!m.isOutgoing) return '';
    // Local / not-yet-acked: clock (or failed), never a premature ✓.
    if (m.sendingState == 'failed') return 'failed';
    if (m.sendingState == 'pending' ||
        (m.sendingState == null && m.id < 0)) {
      return 'sending';
    }
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
                _applyChatRow(chatId, Map<String, dynamic>.from(chat));
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
      _applyChatRow(chatId, Map<String, dynamic>.from(chat));
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
          ? 'Telegram TDLib поддерживается на Android и iOS'
          : 'Нет Telegram API credentials';
      _hubSurfaceReady = true;
      notifyListeners();
      return;
    }
    await _loadDebugMtprotoProxyPref();
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
      // Already authorized but hub never finished first list+folders pass
      // (e.g. previous Ready handler was interrupted). Hub holds skeleton
      // until hubSurfaceReady — complete hydration here.
      if (phase == TdlibAuthPhase.ready && !_hubSurfaceReady) {
        await refreshChatList();
        await _awaitInitialFolderInfos();
        await _loadScopeNotificationSettings();
        _setHubSurfaceReady(true);
      }
      TdlibJsonClient.onPushPayload = (payload) {
        unawaited(processPushNotificationPayload(payload));
      };
      _ensureNetworkLinkWatch();
      return;
    }
    phase = TdlibAuthPhase.starting;
    errorMessage = null;
    _hubSurfaceReady = false;
    notifyListeners();
    try {
      TdlibJsonClient.onNeedsParameters = _onNeedsTdlibParameters;
      TdlibJsonClient.onPushPayload = (payload) {
        unawaited(processPushNotificationPayload(payload));
      };
      _client = await TdlibJsonClient.create();
      _sub = _client!.updates.listen(_onUpdate);
      _ensureNetworkLinkWatch();
      // R31: do not go online / announce network before proxy is armed.
      // Old path: online+WiFi raced setParameters → Ready on direct, then
      // enableProxy tore session (SessionLog 17:21 Ready→Connecting +9s).
      // Official: proxy settings first, then connect.
      await _syncAuthorizationState();
      await _setTdlibOnline(true);
      await _applyNetworkTypeFromDevice(why: 'client-start', force: true);
    } catch (e) {
      phase = TdlibAuthPhase.error;
      errorMessage = e.toString();
      _hubSurfaceReady = true;
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
  Future<void> _recoverDeadClient(
    String why, {
    bool preserveLongBgEscalation = false,
  }) async {
    if (_tearingDown || _recoveringClient) return;
    final last = _lastDeadClientRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastDeadClientRecoverAt = DateTime.now();
    _recoveringClient = true;
    // Soft-restart must not wipe long-bg escalation (SessionLog 21:50:
    // soft-restart → longBg=false → slow soft ladder on same dead hop).
    final keepLongBg = preserveLongBgEscalation || _longBackgroundResume;
    final keepRestartCount = keepLongBg
        ? _longBackgroundSoftRestartCount.clamp(0, _longBgSoftRestartCap)
        : 0;
    _mediaLog(
      'recover-dead-client why=$why phase=$phase conn=$_connectionState '
      'preserveLongBg=$keepLongBg restartCount=$keepRestartCount',
    );
    _slog('tg.conn', 'recover_begin', {
      'why': why,
      'phase': phase.toString(),
      'openChatId': _openChatId,
      'preservedMsgs': _openChatId == null
          ? 0
          : (_messagesByChat[_openChatId!]?.length ?? 0),
      'preserveLongBg': keepLongBg,
      'restartCount': keepRestartCount,
    });
    try {
      _parametersApplied = false;
      await _tearDown(wipeDatabase: false);
      if (keepLongBg) {
        _longBackgroundResume = true;
        _longBackgroundSoftRestartCount = keepRestartCount;
        _armSoftResumeGuard(why: 'soft-restart-preserve-longbg');
        _mediaLog(
          'long-bg-escalation preserve after soft-restart '
          'restartCount=$_longBackgroundSoftRestartCount',
        );
      }
      phase = TdlibAuthPhase.starting;
      notifyListeners();
      await ensureStarted();
      // Fresh client already applied proxy via ensureStarted — quiet so
      // immediate soft-kick enableProxy does not abort FakeTLS (R14).
      if (!_tdlibReadyForMedia) {
        _armFakeTlsQuiet(why: 'soft-restart:$why');
      }
    } catch (e) {
      _mediaLog('recover-dead-client FAIL $e');
      _slog('tg.conn', 'recover_fail', {'why': why, 'err': e.toString()});
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
    _readInboxFloor.clear();
    _users.clear();
    _supergroups.clear();
    _supergroupFetchQueued.clear();
    _chatOrder.clear();
    _chatFolderInfos.clear();
    _chatFolderDetails.clear();
    _folderChatIds.clear();
    _chatFoldersEpoch = 0;
    _hubSurfaceReady = false;
    // Keep the open conversation painted across soft restart. TDLib local DB
    // will refill on Ready; until then UI must not fall back to tip-only seed.
    _preserveOpenTranscriptForRestart();
    _messagesByChat.clear();
    _restorePreservedTranscripts();
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
    _proxyPlaneTimer?.cancel();
    _proxyPlaneTimer = null;
    _lastPongMs = null;
    _lastPongAt = null;
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    _uiNotifyPending = false;
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    _hubChatsCache = null;
    _miniThumbByChatId.clear();
    _connectingTimeoutTimer?.cancel();
    _connectingTimeoutTimer = null;
    _connectionStatusRevealTimer?.cancel();
    _connectionStatusRevealTimer = null;
    _appResumeRecoverTimer?.cancel();
    _appResumeRecoverTimer = null;
    _pauseOfflineGraceTimer?.cancel();
    _pauseOfflineGraceTimer = null;
    _appNetworkSuspended = false;
    _backgroundPausedAt = null;
    _longBackgroundResume = false;
    _longBackgroundSoftRestartCount = 0;
    _resumeWasTrueLongBackground = false;
    _proxyGeoRecheckTimer?.cancel();
    _proxyGeoRecheckTimer = null;
    _lastProxyGeoRecheckAt = null;
    _connectingSince = null;
    _readyAt = null;
    _enabledProxyId = null;
    _lastConnectionKickAt = null;
    _connectionKickCount = 0;
    _lastBearerChangeAt = null;
    _lastBearerRecoverAt = null;
    _lastAppResumeRecoverAt = null;
    _softResumeGuardUntil = null;
    _fakeTlsQuietUntil = null;
    _lastLongBgSocketReopenAt = null;
    _lastProxyFailoverAt = null;
    _lastMediaHealthFailoverAt = null;
    _avatarGiveUpStreak = 0;
    _avatarGiveUpWindowAt = null;
    _lastProxyProbeAt = null;
    _proxyProbeInFlight = false;
    _endpointProxyIds.clear();
    _lastSetNetworkTypeAt = null;
    _setNetworkTypeJob = null;
    // Soft-restart keeps [_proxyEndpointIndex] so failover sticks across recover.
    if (wipeDatabase) {
      _proxyEndpointIndex = 0;
    }
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

  /// Feed an FCM payload into TDLib (foreground or background isolate).
  Future<void> processPushNotificationPayload(String payloadJson) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
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
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
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
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
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
    // Prefetch history for a few unread hub chats so open can jump faster.
    warmUnreadChatsFromHub();
  }

  /// Synchronously claim UI ownership before async [openChat] work starts.
  /// Always rotates the close-token so a previous route's dispose cannot close
  /// this session — even when re-opening the same [chatId].
  int claimOpenChat(int chatId) => _claimOpenChat(chatId, rotateToken: true);

  /// Opens [chatId] for the conversation UI.
  ///
  /// Returns an open-session token that must be passed to [closeChat]. A stale
  /// dispose after re-opening the same chat must not call TDLib `closeChat`.
  Future<int> openChat(int chatId) async {
    // Reuse token if [claimOpenChat] already ran for this chat; otherwise claim.
    final token = (_openChatId == chatId && _activeOpenToken != null)
        ? _activeOpenToken!
        : _claimOpenChat(chatId, rotateToken: false);
    final preCount = _messagesByChat[chatId]?.length ?? 0;
    _slog('tg.chat', 'open_begin', {
      'chatId': chatId,
      'token': token,
      'msgsBefore': preCount,
      'unread': unreadCountFor(chatId),
      'warm': isUnreadHistoryWarm(chatId),
      'title': peerTitle(chatId),
      'readyForMedia': _tdlibReadyForMedia,
    });
    final c = _client;
    if (c == null || !isReady) {
      _slog('tg.chat', 'open_abort', {
        'chatId': chatId,
        'token': token,
        'why': c == null ? 'no_client' : 'not_ready',
      });
      return token;
    }
    unawaited(_cancelLocalTdlibNotification(chatId));
    // Await cancel so FakeTLS is quiet before channel media opens
    // (unawaited suspend raced downloadFile → DF hello flood on mtg).
    await _suspendBackgroundDownloads();
    _purgeNonFocusDownloads(keepChatId: chatId);
    if (_enabledProxyId != null) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    try {
      final chat = await c.sendAwait({
        '@type': 'getChat',
        'chat_id': chatId,
      });
      // Re-open may have raced a dispose; abort if our token lost ownership.
      if (!_isActiveOpen(chatId, token)) return token;
      if (chat['@type'] == 'chat') {
        _applyChatRow(chatId, Map<String, dynamic>.from(chat));
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
        return token;
      }
    } catch (_) {}

    if (!_isActiveOpen(chatId, token)) return token;

    // Seed last_message immediately so UI isn't blank while history loads.
    // Upsert only — never replace an already-loaded transcript with tip-only.
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
        return token;
      }
    } catch (_) {}
    if (!_isActiveOpen(chatId, token)) return token;
    unawaited(refreshCanSendMessages(chatId));

    final peerUid = _privateUserId(chatId);
    if (peerUid != null) {
      await _refreshUser(peerUid, queueAvatar: false);
    }
    if (!_isActiveOpen(chatId, token)) return token;

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
    // Hub warm already covered the unread frontier — don't block open on
    // another full history walk (that was killing the "no loader" UX).
    final warm = isUnreadHistoryWarm(chatId) &&
        (_messagesByChat[chatId]?.length ?? 0) >= 16;
    if (warm) {
      _mediaLog(
        'openChat=$chatId skip-block-history warm=true '
        'msgs=${_messagesByChat[chatId]?.length ?? 0}',
      );
      _touchOpenTranscriptPreserve(chatId);
      notifyListeners();
      unawaited(_loadChatHistory(chatId, preferLocal: true, silent: true));
      if (_tdlibReadyForMedia) {
        unawaited(() async {
          await _loadChatHistory(chatId, preferLocal: false, silent: true);
          await syncChatTail(chatId);
        }());
      }
    } else {
      await _loadChatHistory(chatId, preferLocal: true);
      if (!_isActiveOpen(chatId, token)) return token;
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
          if (!ok || !_isActiveOpen(chatId, token)) return;
          await _loadChatHistory(chatId, preferLocal: false);
          await syncChatTail(chatId);
          _mediaLog(
            'openChat-deferred-remote chat=$chatId '
            'msgs=${_messagesByChat[chatId]?.length ?? 0}',
          );
        }());
      }
    }
    // Regardless of warm: hub last_message must appear in the transcript.
    await _ensureChatTipInTranscript(chatId);
    _touchOpenTranscriptPreserve(chatId);

    // Avatar AFTER transcript/media focus — never steal the download slot.
    // Header keeps minithumb until focus media finishes.
    // (Avatar kick deferred; see focusNewest / ready-catchup.)
    _slog('tg.chat', 'open_done', {
      'chatId': chatId,
      'token': token,
      'msgsAfter': _messagesByChat[chatId]?.length ?? 0,
      'unread': unreadCountFor(chatId),
      'tipInTranscript': () {
        final tip = _chats[chatId]?['last_message'];
        final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
        if (tipId <= 0) return null;
        return _messagesByChat[chatId]?.any((m) => m.id == tipId) ?? false;
      }(),
    });
    return token;
  }

  /// Claim UI ownership of [chatId].
  ///
  /// [rotateToken] true (new route): always mint a new token so a stale
  /// dispose of the previous screen cannot close this session.
  /// [rotateToken] false (same session refresh): keep the existing token when
  /// the same chat is already open.
  int _claimOpenChat(int chatId, {required bool rotateToken}) {
    final prevId = _openChatId;
    final prevToken = _activeOpenToken;
    if (!rotateToken && prevId == chatId && prevToken != null) {
      _slog('tg.chat', 'claim_reuse', {
        'chatId': chatId,
        'token': prevToken,
      });
      return prevToken;
    }
    final token = ++_openChatTokenSeq;
    _openChatId = chatId;
    _activeOpenToken = token;
    AppSessionDiagnostics.instance.setTgOpenChat(chatId);
    // TDLib: prefer a single opened chat (channel updates + unload rules).
    if (prevId != null && prevId != chatId) {
      _openTranscriptPreserve.remove(prevId);
      unawaited(_sendTdlibCloseChat(prevId));
    }
    _slog('tg.chat', 'claim', {
      'chatId': chatId,
      'token': token,
      'rotate': rotateToken,
      'prevChatId': prevId,
      'prevToken': prevToken,
      'msgs': _messagesByChat[chatId]?.length ?? 0,
    });
    return token;
  }

  bool _isActiveOpen(int chatId, int token) =>
      _openChatId == chatId && _activeOpenToken == token;

  void _preserveOpenTranscriptForRestart() {
    final id = _openChatId;
    if (id == null) return;
    final list = _messagesByChat[id];
    if (list == null || list.isEmpty) return;
    final prev = _openTranscriptPreserve[id];
    if (prev != null && prev.length > list.length) return;
    _openTranscriptPreserve[id] = List<TdlibMessage>.of(list);
    _slog('tg.history', 'preserve', {
      'chatId': id,
      'count': list.length,
      'oldestId': list.first.id,
      'newestId': list.last.id,
    });
  }

  void _restorePreservedTranscripts() {
    if (_openTranscriptPreserve.isEmpty) return;
    for (final entry in _openTranscriptPreserve.entries) {
      final chatId = entry.key;
      final preserved = entry.value;
      if (preserved.isEmpty) continue;
      final existing = _messagesByChat[chatId];
      if (existing == null || existing.isEmpty) {
        _messagesByChat[chatId] = List<TdlibMessage>.of(preserved);
        _slog('tg.history', 'restore', {
          'chatId': chatId,
          'count': preserved.length,
          'mode': 'replace_empty',
        });
        continue;
      }
      if (existing.length >= preserved.length) continue;
      final byId = <int, TdlibMessage>{
        for (final m in existing) m.id: m,
      };
      for (final m in preserved) {
        byId.putIfAbsent(m.id, () => m);
      }
      _messagesByChat[chatId] = byId.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      _slog('tg.history', 'restore', {
        'chatId': chatId,
        'before': existing.length,
        'after': _messagesByChat[chatId]?.length ?? 0,
        'mode': 'merge',
      });
    }
  }

  void _touchOpenTranscriptPreserve(int chatId) {
    if (_openChatId != chatId) return;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    final prev = _openTranscriptPreserve[chatId];
    if (prev != null && prev.length > list.length) return;
    _openTranscriptPreserve[chatId] = List<TdlibMessage>.of(list);
  }

  /// Write history pages without ever shrinking an already-painted transcript.
  void _writeChatMessages(int chatId, Map<int, TdlibMessage> byId) {
    final existing = _messagesByChat[chatId];
    if (existing != null) {
      for (final m in existing) {
        byId.putIfAbsent(m.id, () => m);
      }
    }
    final preserved = _openTranscriptPreserve[chatId];
    if (preserved != null) {
      for (final m in preserved) {
        byId.putIfAbsent(m.id, () => m);
      }
    }
    final sorted = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    _messagesByChat[chatId] = sorted;
    _touchOpenTranscriptPreserve(chatId);
  }

  Future<void> _sendTdlibCloseChat(int chatId) async {
    final c = _client;
    if (c == null) return;
    try {
      await c.sendAwait({'@type': 'closeChat', 'chat_id': chatId});
    } catch (_) {}
  }

  /// If chat.last_message isn't in RAM yet, pull the tip (seed + short sync).
  Future<void> _ensureChatTipInTranscript(int chatId) async {
    final last = _chats[chatId]?['last_message'];
    if (last is! Map) return;
    final tipId = _tdlibInt(last['id']);
    if (tipId <= 0) return;
    final list = _messagesByChat[chatId];
    if (list != null && list.any((m) => m.id == tipId)) return;

    final lastMap = Map<String, dynamic>.from(last);
    lastMap.putIfAbsent('chat_id', () => chatId);
    final seeded = _parseMessage(lastMap);
    if (seeded != null) {
      _upsertMessage(seeded);
      notifyListeners();
    }
    if (list != null && list.any((m) => m.id == tipId)) return;
    // Tip not parseable / still missing — fetch newest page from network.
    await syncChatTail(chatId, limit: 30);
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
  ///
  /// Foreign-chat `ensure` / stale tap jobs must die on open — otherwise they
  /// hold the FakeTLS slot for ~45s at 0B while the viewer shows minithumb
  /// (SessionLog: ensure chat=71606080 blocked Shariy tap:photo=16472).
  void _purgeNonFocusDownloads({int? keepChatId}) {
    final focus = _focusDownloadOrder.toSet();
    bool keepJob({required int? chatId, required String reason, required int fileId}) {
      if (focus.contains(fileId)) return true;
      final foreign = keepChatId != null && chatId != null && chatId != keepChatId;
      if (foreign) return false;
      return reason.startsWith('focus:') ||
          reason.startsWith('focus-tail:') ||
          reason.startsWith('demoted-after-focus:') ||
          reason.startsWith('tap:') ||
          reason.startsWith('ensure') ||
          reason.startsWith('stall-retry:') ||
          reason.startsWith('stall-fallback:') ||
          reason.startsWith('stall-lastchance:');
    }

    final dropQueued = _downloadQueue.where((j) {
      return !keepJob(chatId: j.chatId, reason: j.reason, fileId: j.fileId);
    }).toList();
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _mediaLog('purge-queue file=${j.fileId} reason=${j.reason} chat=${j.chatId}');
    }
    var cancelled = 0;
    for (final id in _downloadInFlight.toList()) {
      final t = _downloadTrace[id];
      final r = t?.reason ?? '';
      if (keepJob(chatId: t?.chatId, reason: r, fileId: id)) continue;
      unawaited(() async {
        await _cancelTdlibDownload(id);
        _releaseDownloadSlot(id, failed: true);
        _downloadTrace.remove(id);
        _fileDownloadProgress.remove(id);
        _mediaLog('purge-inflight file=$id reason=$r chat=${t?.chatId}');
      }());
      cancelled++;
    }
    if (dropQueued.isNotEmpty || cancelled > 0) {
      _mediaLog(
        'purge-non-focus droppedQ=${dropQueued.length} cancelInflight=$cancelled '
        'keepChat=$keepChatId ${_downloadQueueStats()}',
      );
    }
  }

  Future<void> _loadChatHistory(
    int chatId, {
    int minCount = 20,
    bool? preferLocal,
    bool silent = false,
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
      _writeChatMessages(chatId, byId);
      if (!silent) notifyListeners();
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
      'seed=${byId.length} conn=$_connectionState silent=$silent',
    );

    for (var attempt = 0;
        attempt < maxAttempts && byId.length < maxCount && !reachedAgeFloor();
        attempt++) {
      // Allow background warm when no chat is open; abort if another is open.
      if (_openChatId != null && _openChatId != chatId) return;
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

      _writeChatMessages(chatId, byId);
      // No notifyListeners per page — rebuilding the open conversation on
      // every getChatHistory chunk skips 50–150 frames and kills fling.

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
    _writeChatMessages(chatId, byId);
    // One coalesce after the full window is ready (skip for silent warm).
    if (!silent) _notifyUi();
    final count = _messagesByChat[chatId]?.length ?? 0;
    _mediaLog(
      'history-done chat=$chatId count=$count '
      'channel=$isChannel onlyLocal=$onlyLocal '
      'ageFloor=${reachedAgeFloor()} silent=$silent',
    );
    _slog('tg.history', 'load_done', {
      'chatId': chatId,
      'count': count,
      'channel': isChannel,
      'onlyLocal': onlyLocal,
      'silent': silent,
      'ageFloor': reachedAgeFloor(),
      'oldestId': byId.isEmpty
          ? null
          : byId.values.map((m) => m.id).reduce((a, b) => a < b ? a : b),
      'newestId': byId.isEmpty
          ? null
          : byId.values.map((m) => m.id).reduce((a, b) => a > b ? a : b),
    });
  }

  /// Prefetch local (+ a few older pages) for unread chats while the user is
  /// still on the hub — so open can jump to the unread frontier without a long
  /// empty wait. Skips only the currently open chat (other chats keep warming).
  Future<void> warmUnreadChatHistory(int chatId) async {
    if (chatId == 0 || !isReady) return;
    if (_openChatId == chatId) return;
    if (unreadCountFor(chatId) <= 0) return;
    if (_historyWarmInFlight.contains(chatId)) return;
    if (isUnreadHistoryWarm(chatId) &&
        (_messagesByChat[chatId]?.length ?? 0) >= 40) {
      return;
    }

    final lastRead = lastReadInboxMessageId(chatId);
    _historyWarmInFlight.add(chatId);
    _mediaLog(
      'warm-history start chat=$chatId unread=${unreadCountFor(chatId)}',
    );
    try {
      await _loadChatHistory(chatId, preferLocal: true, silent: true);
      if (_openChatId == chatId) return;
      if (_tdlibReadyForMedia) {
        await _loadChatHistory(chatId, preferLocal: false, silent: true);
      }
      // Walk older pages until we cover last_read (unread divider target).
      final unreadTarget = unreadCountFor(chatId);
      final maxWarmPages = (unreadTarget / 25).ceil().clamp(5, 12);
      for (var i = 0; i < maxWarmPages; i++) {
        if (_openChatId == chatId) break;
        final msgs = _messagesByChat[chatId];
        if (msgs == null || msgs.isEmpty) break;
        if (lastRead > 0 && msgs.first.id <= lastRead) break;
        final unread = unreadCountFor(chatId);
        final loadedUnread = lastRead > 0
            ? msgs.where((m) => m.id > lastRead).length
            : msgs.length;
        if (unread > 0 && loadedUnread >= unread) break;
        final added =
            await loadOlderMessages(chatId, pageSize: 40, silent: true);
        if (added <= 0) break;
      }
      _mediaLog(
        'warm-history done chat=$chatId '
        'msgs=${_messagesByChat[chatId]?.length ?? 0} '
        'warm=${isUnreadHistoryWarm(chatId)}',
      );
    } finally {
      _historyWarmInFlight.remove(chatId);
    }
  }

  /// Warm hub chats that already have unreads (after list load / new msgs).
  /// Prefers stacks with unread ≥ 2 — those need a scroll jump on open.
  void warmUnreadChatsFromHub({int maxChats = 8}) {
    if (!isReady) return;
    final candidates = <({int id, int unread})>[];
    for (final id in _chatOrder) {
      if (_openChatId == id) continue;
      final unread = unreadCountFor(id);
      if (unread <= 0) continue;
      candidates.add((id: id, unread: unread));
    }
    candidates.sort((a, b) {
      final aDeep = a.unread >= 2 ? 0 : 1;
      final bDeep = b.unread >= 2 ? 0 : 1;
      if (aDeep != bDeep) return aDeep.compareTo(bDeep);
      return b.unread.compareTo(a.unread);
    });
    var n = 0;
    for (final c in candidates) {
      unawaited(warmUnreadChatHistory(c.id));
      n++;
      if (n >= maxChats) break;
    }
  }

  /// Hub-row fields of a `chat` payload, hashed — [syncChatTail] re-reads
  /// getChat on a 4s timer and must not notify when no row moved.
  int _chatRowFingerprint(Map<String, dynamic>? chat) {
    if (chat == null) return 0;
    final last = chat['last_message'];
    return Object.hash(
      chat['title'],
      _tdlibInt(chat['unread_count']),
      _tdlibInt(chat['unread_mention_count']),
      _tdlibInt(chat['last_read_inbox_message_id']),
      _tdlibInt(chat['last_read_outbox_message_id']),
      last is Map ? _tdlibInt(last['id']) : 0,
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

        var changed = false;
        final prevRow = _chatRowFingerprint(_chats[chatId]);
        final chat = await c.sendAwait({
          '@type': 'getChat',
          'chat_id': chatId,
        });
        int? expectedLastId;
        if (chat['@type'] == 'chat') {
          _applyChatRow(chatId, Map<String, dynamic>.from(chat));
          if (_chatRowFingerprint(_chats[chatId]) != prevRow) changed = true;
          final lastOut =
              (chat['last_read_outbox_message_id'] as num?)?.toInt();
          if (lastOut != null) _lastReadOutboxId[chatId] = lastOut;

          final last = chat['last_message'];
          if (last is Map) {
            final lastMap = Map<String, dynamic>.from(last);
            lastMap.putIfAbsent('chat_id', () => chatId);
            expectedLastId = (lastMap['id'] as num?)?.toInt();
            final seeded = _parseMessage(lastMap);
            if (seeded != null && _upsertMessage(seeded)) changed = true;
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
              if (msg != null && _upsertMessage(msg)) changed = true;
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
              if (msg != null && _upsertMessage(msg)) changed = true;
            }
          } catch (_) {}
        }

        // Media for open chat is owned by history tip + viewport — not every
        // syncChatTail (that re-boosted inFlight downloads into a 0B stall).
        //
        // The 4s tail poll almost always re-delivers the identical tail; that
        // notify alone cost 150–220ms frames and hitched scroll mid-fling.
        // Only a real change notifies, and through the coalescing gate.
        if (changed) _notifyUi();

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
    unawaited(_setMessageUnloadDelay());
    final openId = _openChatId;
    if (openId != null) {
      _restorePreservedTranscripts();
      // Soft-restart / Connecting→Ready often left tip-only seed — always
      // refill from TDLib local DB first, then remote when possible.
      await _loadChatHistory(openId, preferLocal: true);
      if (_tdlibReadyForMedia) {
        await _loadChatHistory(openId, preferLocal: false);
      }
      await syncChatTail(openId);
      _touchOpenTranscriptPreserve(openId);
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

  /// Keep closed-chat messages in TDLib RAM longer so hub warm / reopen can
  /// hit `only_local` instead of waiting on the network (default is 60s).
  Future<void> _setMessageUnloadDelay() async {
    final c = _client;
    if (c == null || !isReady) return;
    try {
      await c.sendAwait({
        '@type': 'setOption',
        'name': 'message_unload_delay',
        'value': {'@type': 'optionValueInteger', 'value': 600},
      }, timeout: const Duration(seconds: 3));
    } catch (e) {
      _mediaLog('setOption message_unload_delay err=$e');
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
    bool forceFocus = false,
  }) {
    if (_openChatId != chatId) return;
    if (focusMessageId == null || focusMessageId <= 0) return;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    // FakeTLS: neighbor openMessageContent + downloadFile floods mtg with
    // domain-fronting (A/B 16:38: 118× neighbor / 37× open+view, DF=50).
    // Focus-only until we prove parallel is safe on this proxy.
    final effectiveRadius = _enabledProxyId != null ? 0 : radius;
    final idx = list.indexWhere((m) => m.id == focusMessageId);
    if (idx < 0) {
      _pendingNeighborMessageIds = const [];
      focusVisibleMessageMedia(
        chatId: chatId,
        messageId: focusMessageId,
        force: forceFocus,
      );
      return;
    }
    final neighborIds = <int>[];
    if (effectiveRadius > 0) {
      for (var dist = 1; dist <= effectiveRadius; dist++) {
        for (final i in [idx - dist, idx + dist]) {
          if (i < 0 || i >= list.length) continue;
          final m = list[i];
          if (!_messageHasLightMedia(m)) continue;
          neighborIds.add(m.id);
        }
      }
    }
    _pendingNeighborMessageIds = neighborIds;
    focusVisibleMessageMedia(
      chatId: chatId,
      messageId: focusMessageId,
      force: forceFocus,
    );
  }

  void _flushPendingNeighbors(int chatId) {
    final ids = _pendingNeighborMessageIds;
    _pendingNeighborMessageIds = const [];
    if (ids.isEmpty) return;
    // Serialize soft→sharp refresh; parallel getMessage races TDLib receive.
    unawaited(_flushPendingNeighborsAsync(chatId, ids));
  }

  Future<void> _flushPendingNeighborsAsync(int chatId, List<int> ids) async {
    for (final mid in ids) {
      if (_openChatId != chatId) return;
      await _enqueueNeighborMediaAsync(chatId: chatId, messageId: mid);
    }
  }

  /// Free slots held by idle neighbor/demoted jobs so focus can start.
  Future<void> _yieldSlotsToFocus(Set<int> want) async {
    // Drop queued neighbors so they don't steal the next free slot.
    final dropQueuedEarly = _downloadQueue
        .where((j) =>
            !want.contains(j.fileId) &&
            (j.reason.startsWith('neighbor:') ||
                j.reason.startsWith('demoted-after-focus')))
        .toList();
    for (final j in dropQueuedEarly) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }
    // With multi-slot chat downloads, only cancel when saturated — except
    // FakeTLS single-slot: a 0B focus thumb must not block tap:photo/video
    // (Ostashko SessionLog: focus=14965 @0B queued tap=14956 for 30s+).
    if (_downloadActive < _downloadSlotLimit && _enabledProxyId == null) {
      return;
    }
    final blockers = <int>[];
    for (final id in _downloadInFlight.toList()) {
      if (want.contains(id)) continue;
      final t = _downloadTrace[id];
      final reason = t?.reason ?? '';
      if (reason.startsWith('tap:')) continue;
      final zeroBytes = (t?.lastBytes ?? 0) <= 0;
      // Under proxy: cancel 0B focus so the tapped file can start.
      if (_enabledProxyId != null &&
          zeroBytes &&
          (reason.startsWith('focus:') ||
              reason.startsWith('focus-tail:') ||
              reason.startsWith('focus-upgrade:') ||
              reason.startsWith('stall-fallback:') ||
              reason.startsWith('stall-lastchance:') ||
              reason.startsWith('ensure'))) {
        blockers.add(id);
        if (blockers.length >= 1) break;
        continue;
      }
      if (reason.startsWith('focus:') ||
          reason.startsWith('focus-tail:') ||
          reason.startsWith('focus-upgrade:') ||
          reason.startsWith('stall-fallback:')) {
        continue;
      }
      // Neighbor / demoted / avatar at 0B may free one slot.
      if (!zeroBytes) continue;
      blockers.add(id);
      if (blockers.length >= 1) break; // free one slot, not a cancel storm
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
      'yield-slots-to-focus soft=${blockers.join(",")} '
      'dropQ=${dropQueued.map((j) => j.fileId).join(",")} '
      'want=${want.take(4).join(",")} '
      'hardCancel=${_enabledProxyId != null}',
    );
    for (final id in blockers) {
      _downloadInFlight.remove(id);
      _downloadBackgroundIds.remove(id);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
      // Soft-release left TDLib still pulling → FakeTLS DF flood on mtg.
      if (_enabledProxyId != null) {
        unawaited(_cancelTdlibDownload(id));
      }
    }
  }

  /// Queue one nearby message's light media at open-chat priority (not focus).
  void _enqueueNeighborMedia({
    required int chatId,
    required int messageId,
  }) {
    unawaited(
      _enqueueNeighborMediaAsync(chatId: chatId, messageId: messageId),
    );
  }

  Future<void> _enqueueNeighborMediaAsync({
    required int chatId,
    required int messageId,
  }) async {
    if (_openChatId != chatId) return;
    // See prefetchOpenChatViewport — no neighbor wire under FakeTLS.
    if (_enabledProxyId != null) return;
    final list = _messagesByChat[chatId];
    if (list == null) return;
    TdlibMessage? m;
    for (final x in list) {
      if (x.id == messageId) {
        m = x;
        break;
      }
    }
    if (m == null || _photoBubbleSharp(m)) return;

    final softPhoto = m.isPhoto &&
        (m.photoSizeType == null ||
            m.photoSizeType == 'm' ||
            m.photoSizeType == 's' ||
            m.photoFallbackFileIds.isEmpty);
    if (softPhoto) {
      await _openMessageContent(chatId, messageId);
      if (_openChatId != chatId) return;
      final c = _client;
      if (c != null) {
        try {
          final res = await c.sendAwait({
            '@type': 'getMessage',
            'chat_id': chatId,
            'message_id': messageId,
          }, timeout: const Duration(seconds: 6));
          final parsed = _parseMessage(res);
          if (parsed != null) {
            _upsertMessage(parsed);
            m = parsed;
          }
        } catch (_) {}
      }
      if (_photoBubbleSharp(m!)) return;
    }

    final ids = <int>[];
    void addId(int? id) {
      if (id == null || id <= 0) return;
      if (_hasCachedPath(id)) return;
      if (ids.contains(id)) return;
      ids.add(id);
    }

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
    if (ids.isNotEmpty) _pumpDownloadQueue();
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
    // Tip catch-up used to punch through the hold for live photo bursts, but
    // under FakeTLS it flip-flops two tip ids and burns openMessageContent /
    // cancel cycles (Shariy SessionLog: 63880… thrash → 0B).
    final holdUntil = _focusHoldUntil;
    if (!force &&
        holdUntil != null &&
        DateTime.now().isBefore(holdUntil) &&
        _focusMessageId != null &&
        _focusMessageId != messageId) {
      final held = _focusMessageId!;
      final tipCatchUp = messageId > held && _enabledProxyId == null;
      if (!tipCatchUp) {
        _slog('tg.media', 'focus_hold_block', {
          'chatId': chatId,
          'wantMsgId': messageId,
          'heldMsgId': held,
          'force': force,
        });
        return;
      }
    }

    var idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) {
      _slog('tg.media', 'focus_miss', {
        'chatId': chatId,
        'msgId': messageId,
        'force': force,
      });
      return;
    }

    // Scroll estimate often lands on a text bubble while a photo is on screen.
    // Prefer the nearest message that actually has downloadable light media.
    if (!_messageHasLightMedia(list[idx])) {
      final found = _nearestLightMediaIndex(list, idx);
      if (found != null) {
        idx = found;
        messageId = list[idx].id;
      }
    }

    // Re-check hold after nearest-media remap (allow newer tip catch-up).
    if (!force &&
        holdUntil != null &&
        DateTime.now().isBefore(holdUntil) &&
        _focusMessageId != null &&
        _focusMessageId != messageId &&
        messageId <= _focusMessageId!) {
      return;
    }

    // Same focus already claimed — do NOT re-openMessageContent / re-enqueue.
    // Idle rescan was spamming open+view every ~1s and starving FakeTLS media
    // (Shariy SessionLog 22:11: open/view 30× while downloadFile sat at 0B).
    if (_focusMessageId == messageId &&
        (_focusDownloadOrder.isNotEmpty ||
            _downloadInFlight.isNotEmpty ||
            _downloadQueue.any((j) => !j.background))) {
      _focusHoldUntil = DateTime.now().add(
        Duration(seconds: _enabledProxyId != null ? 45 : 8),
      );
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
    // FakeTLS: long hold so layout/tip cannot thrash the exclusive slot.
    _focusHoldUntil = DateTime.now().add(
      Duration(seconds: _enabledProxyId != null ? 45 : 8),
    );
    final claimedId = messageId;
    _slog('tg.media', 'focus_claim', {
      'chatId': chatId,
      'msgId': messageId,
      'force': force,
      'albumMembers': members.length,
      'photoId': focus.photoRemoteId,
      'photoType': focus.photoSizeType,
      'vthumb': focus.videoThumbFileId,
      'needsFocus': mediaNeedsViewportFocus(focus),
      'sharp': _photoBubbleSharp(focus),
      'isPhoto': focus.isPhoto,
      'isVideo': focus.isVideo,
      'preview': SessionLog.textPreview(focus.text),
    });

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

    // Open CDN auth for album items, then refresh file ids.
    // FakeTLS: one openMessageContent (claimed) — parallel open×N was DF fuel.
    if (_enabledProxyId != null) {
      await _openMessageContent(chatId, messageId);
    } else {
      await Future.wait([
        for (final m in members) _openMessageContent(chatId, m.id),
      ]);
    }

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
    void queuePhotoUpgrade(TdlibMessage m) {
      final up = _photoUpgradeFileId(m);
      if (up == null) return;
      if (_hasSharpPhotoCached(up)) {
        final path = _filePathCache[up]!;
        final patched = _messageWithDownloadedFile(m, up, path);
        if (patched != null) {
          _upsertMessage(patched);
          notifyListeners();
        }
        return;
      }
      // Drop tiny/soft cache so addId actually queues the sharp size.
      if (_hasCachedPath(up) && !_hasSharpPhotoCached(up)) {
        _filePathCache.remove(up);
      }
      addId(up);
    }

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

    void queueVideoPreview(TdlibMessage m, {bool preferFront = false}) {
      // Auto: first-frame / thumb only — never the full video body.
      void addThumb(int? id) {
        if (id == null || id <= 0) return;
        if (ordered.contains(id)) return;
        if (preferFront) {
          ordered.insert(0, id);
        } else {
          ordered.add(id);
        }
      }

      if (m.isVideoNote &&
          thumbNeedsDownload(
            m.videoNoteThumbFileId,
            m.videoNoteThumbLocalPath,
          )) {
        addThumb(m.videoNoteThumbFileId);
      }
      if ((m.isVideo || m.isAnimation) &&
          thumbNeedsDownload(m.videoThumbFileId, m.videoThumbLocalPath)) {
        addThumb(m.videoThumbFileId);
      }
    }

    // Focused video: thumb first so the slot is not stolen by album photos.
    if (claimed != null &&
        (claimed.isVideo || claimed.isAnimation || claimed.isVideoNote)) {
      queueVideoPreview(claimed, preferFront: true);
    }
    if (claimed != null && !_photoBubbleSharp(claimed)) {
      queuePhotoUpgrade(claimed);
    }
    for (final m in need) {
      if (claimed != null && m.id == claimed.id) continue;
      if (m.isPhoto || m.photoRemoteId != null) {
        queuePhotoUpgrade(m);
      }
    }

    for (final m in members) {
      if (claimed != null &&
          m.id == claimed.id &&
          (m.isVideo || m.isAnimation || m.isVideoNote)) {
        continue; // already queued at front
      }
      queueVideoPreview(m);
      // PDF / document first-page thumbnails (Telegram server-side).
      if (thumbNeedsDownload(
        m.documentThumbFileId,
        m.documentThumbLocalPath,
      )) {
        final id = m.documentThumbFileId!;
        if (!ordered.contains(id)) ordered.add(id);
      }
      // GIF / animated sticker — full media for inline autoplay (not "video").
      if (m.isAnimation || m.isSticker) {
        addId(m.videoFileId);
        addId(m.photoRemoteId);
      }
      // PDF body so first-page pdfrx preview can render when TG has no thumb.
      if (m.isPdfDocument) {
        addId(m.documentFileId);
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
      // Soft/minithumb on disk must still upgrade to x — never bind&return.
      if (photoNeedsFocusDownload(m)) {
        final up = _photoUpgradeFileId(m);
        if (up != null) {
          _mediaLog(
            'focus-force-upgrade msg=$messageId file=$up '
            'type=${m.photoSizeType} pathSoft=${m.photoLocalPath != null}',
          );
          addId(up);
        } else {
          unawaited(_refetchAndFocusMedia(chatId, messageId));
        }
      }
      // Video first-frame thumb missing — refetch sizes / queue thumb id.
      if (videoPreviewNeedsFocusDownload(m) && ordered.isEmpty) {
        final vt = m.isVideoNote ? m.videoNoteThumbFileId : m.videoThumbFileId;
        if (vt != null && vt > 0) {
          _mediaLog('focus-force-vthumb msg=$messageId file=$vt');
          addId(vt);
        } else {
          unawaited(_refetchAndFocusMedia(chatId, messageId));
        }
      }
      if ((m.photoThumbBytes != null || m.text == 'Фото') &&
          m.photoRemoteId == null) {
        unawaited(_refetchAndFocusMedia(chatId, messageId));
      }
      if ((m.isVideo || m.isAnimation) &&
          (m.videoThumbFileId == null || m.videoThumbFileId! <= 0)) {
        unawaited(_refetchAndFocusMedia(chatId, messageId));
      }

      // Thumb already on disk but message field not stamped → bind so UI paints.
      // Tiny cached thumbs / soft photos (<40KB) — force re-download for photos.
      var stamped = false;
      for (final mem in members) {
        for (final id in <int?>[
          mem.videoThumbFileId,
          mem.videoNoteThumbFileId,
          mem.documentThumbFileId,
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
          final isPhotoId = id == mem.photoRemoteId ||
              mem.photoFallbackFileIds.contains(id);
          final minLen = isPhotoId ? 40 * 1024 : 3 * 1024;
          if (len >= 0 && len < minLen) {
            _filePathCache.remove(id);
            if (!ordered.contains(id)) ordered.add(id);
            _mediaLog(
              'focus-requeue-tiny id=$id len=$len msg=$messageId '
              'photo=$isPhotoId',
            );
            continue;
          }
          if (!_hasCachedPath(id)) continue;
          // Soft photo path in cache — still need upgrade, don't stamp as done.
          if (isPhotoId && !_photoBubbleSharp(mem)) {
            continue;
          }
          final patched = _messageWithDownloadedFile(mem, id, path);
          if (patched != null) {
            _upsertMessage(patched);
            stamped = true;
          }
        }
      }
      if (ordered.isNotEmpty) {
        // Fall through to enqueue tiny requeues / force-upgrade below.
      } else if (stamped && !members.any(photoNeedsFocusDownload)) {
        _mediaLog('focus-bind-cached msg=$messageId');
        // Focus already local — still warm soft neighbors (albums span ids).
        _flushPendingNeighbors(chatId);
        notifyListeners();
        return;
      } else {
        // Truly empty stub — jump to nearest pending photo.
        final hasThumbId = members.any(
          (x) =>
              (x.videoThumbFileId != null && x.videoThumbFileId! > 0) ||
              (x.videoNoteThumbFileId != null &&
                  x.videoNoteThumbFileId! > 0) ||
              (x.documentThumbFileId != null && x.documentThumbFileId! > 0),
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
        if (ordered.isEmpty) {
          _flushPendingNeighbors(chatId);
          _notifyViewportMediaRescan();
          return;
        }
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

  /// Last successful openMessageContent key (`chatId:messageId`) + time.
  String? _lastOpenMessageContentKey;
  DateTime? _lastOpenMessageContentAt;

  /// Helps TDLib authorize CDN access for channel media (esp. through proxy).
  Future<void> _openMessageContent(int chatId, int messageId) async {
    final c = _client;
    if (c == null || messageId <= 0) return;
    // open/view while Connecting floods FakeTLS before media DCs are up
    // (Shariy: 15s of openMessageContent spam, then Ready + 0B downloads).
    if (!_tdlibReadyForMedia) {
      _mediaLog(
        'openMessageContent defer chat=$chatId msg=$messageId '
        'conn=$_connectionState',
      );
      return;
    }
    final key = '$chatId:$messageId';
    final lastAt = _lastOpenMessageContentAt;
    if (_lastOpenMessageContentKey == key &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 8)) {
      return;
    }
    try {
      await c.sendAwait({
        '@type': 'openMessageContent',
        'chat_id': chatId,
        'message_id': messageId,
      }, timeout: const Duration(seconds: 8));
      _lastOpenMessageContentKey = key;
      _lastOpenMessageContentAt = DateTime.now();
      _mediaLog('openMessageContent ok chat=$chatId msg=$messageId');
      // Official clients also view the message; some channel CDNs stay closed
      // until viewMessages (FC had offset=0 but VPS saw no DC203).
      try {
        await c.sendAwait({
          '@type': 'viewMessages',
          'chat_id': chatId,
          'message_ids': [messageId],
          'source': {'@type': 'messageSourceChatHistory'},
          'force_read': false,
        }, timeout: const Duration(seconds: 5));
        _mediaLog('viewMessages ok chat=$chatId msg=$messageId');
      } catch (e) {
        _mediaLog('viewMessages soft-fail chat=$chatId msg=$messageId err=$e');
      }
    } catch (e) {
      _mediaLog('openMessageContent err chat=$chatId msg=$messageId err=$e');
    }
  }

  Future<void> _openMessageContentForFile(int chatId, int fileId) async {
    final list = _messagesByChat[chatId];
    if (list == null) return;
    for (final m in list) {
      if (m.videoFileId == fileId ||
          m.videoNoteFileId == fileId ||
          m.photoRemoteId == fileId ||
          m.documentFileId == fileId ||
          m.documentThumbFileId == fileId ||
          m.videoThumbFileId == fileId ||
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
    return mediaNeedsViewportFocus(m);
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

  /// Sharp enough for a chat bubble — soft s/m / tiny files alone are not.
  /// Typed `x` with a soft/minithumb path used to skip focus forever
  /// (`focus-skip-empty … photoPath=true`) and leave the bubble muddy.
  bool _photoBubbleSharp(TdlibMessage m) {
    final type = m.photoSizeType;
    // Soft s/m: sharp only when a fallback upgrade is already on disk (≥40KB).
    if (type == 'm' || type == 's' || type == null) {
      for (final id in m.photoFallbackFileIds) {
        if (_hasSharpPhotoCached(id)) return true;
      }
      return false;
    }
    final path = resolvedPhotoPath(m);
    if (path == null || path.isEmpty) return false;
    if (type == 'x' || type == 'y' || type == 'w') {
      return _isSharpPhotoPath(path);
    }
    // Unknown type: accept only a clearly large on-disk file.
    return _isSharpPhotoPath(path);
  }

  /// Public for viewport prefetch — soft local path still needs upgrade.
  bool photoNeedsFocusDownload(TdlibMessage m) {
    if (m.photoRemoteId != null && m.photoRemoteId! > 0) {
      return !_photoBubbleSharp(m);
    }
    // Stub / channel photo before sizes resolve — minithumb only.
    if (m.photoThumbBytes != null && m.photoThumbBytes!.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Video / round / animation: need first-frame thumb (not the full body).
  bool videoPreviewNeedsFocusDownload(TdlibMessage m) {
    if (m.isVideoNote) {
      final vt = m.videoNoteThumbFileId;
      if (vt != null && vt > 0) {
        if (_hasCachedPath(vt)) return false;
        final path = m.videoNoteThumbLocalPath;
        if (path != null && path.isNotEmpty) {
          try {
            if (File(path).existsSync() && File(path).lengthSync() >= 3 * 1024) {
              return false;
            }
          } catch (_) {}
        }
        return true;
      }
      // No thumb id yet — still focus so openMessageContent can resolve it.
      // Do NOT pull the round-video body for preview.
      return m.videoNoteThumbBytes == null || m.videoNoteThumbBytes!.isEmpty;
    }
    if (m.isVideo || m.isAnimation) {
      final vt = m.videoThumbFileId;
      if (vt != null && vt > 0) {
        if (_hasCachedPath(vt)) return false;
        final path = m.videoThumbLocalPath;
        if (path != null && path.isNotEmpty) {
          try {
            if (File(path).existsSync() && File(path).lengthSync() >= 3 * 1024) {
              return false;
            }
          } catch (_) {}
        }
        return true;
      }
      final hasFull = (m.videoLocalPath != null && m.videoLocalPath!.isNotEmpty) ||
          (m.videoFileId != null && _hasCachedPath(m.videoFileId!));
      if (hasFull) return false;
      // Minithumb-only stub — openMessageContent + thumb fetch.
      return true;
    }
    return false;
  }

  /// Any light media the open-chat viewport should exclusive-focus.
  /// Broader than [photoNeedsFocusDownload]: videos with only minithumb
  /// bytes (no thumb file id yet) still need openMessageContent + download.
  bool mediaNeedsViewportFocus(TdlibMessage m) {
    if (photoNeedsFocusDownload(m)) return true;
    if (videoPreviewNeedsFocusDownload(m)) return true;
    if (m.isSticker &&
        m.photoRemoteId != null &&
        m.photoRemoteId! > 0 &&
        !_hasCachedPath(m.photoRemoteId!)) {
      return true;
    }
    if (m.isPdfDocument) {
      final dt = m.documentThumbFileId;
      if (dt != null && dt > 0 && !_hasCachedPath(dt)) return true;
      final doc = m.documentFileId;
      if (doc != null &&
          doc > 0 &&
          !_hasCachedPath(doc) &&
          (dt == null || !_hasCachedPath(dt))) {
        return true;
      }
    }
    return false;
  }

  /// Listeners notified when exclusive focus finishes a download (or skips),
  /// so the conversation can re-scan the real viewport for remaining soft media.
  final List<VoidCallback> _viewportMediaRescanListeners = [];

  void addViewportMediaRescanListener(VoidCallback listener) {
    _viewportMediaRescanListeners.add(listener);
  }

  void removeViewportMediaRescanListener(VoidCallback listener) {
    _viewportMediaRescanListeners.remove(listener);
  }

  void _notifyViewportMediaRescan() {
    if (_viewportMediaRescanListeners.isEmpty) return;
    final copy = List<VoidCallback>.of(_viewportMediaRescanListeners);
    scheduleMicrotask(() {
      for (final cb in copy) {
        try {
          cb();
        } catch (e) {
          debugPrint('[tdlib] viewportMediaRescan listener: $e');
        }
      }
    });
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
    _focusHoldUntil = DateTime.now().add(
      Duration(seconds: _enabledProxyId != null ? 45 : 8),
    );

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
  Future<int> loadOlderMessages(
    int chatId, {
    int pageSize = 50,
    bool silent = false,
  }) async {
    final c = _client;
    if (c == null || !isReady) return 0;
    final existing = _messagesByChat[chatId] ?? const <TdlibMessage>[];
    if (existing.isEmpty) {
      await _loadChatHistory(chatId, silent: silent);
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
        if (!silent) notifyListeners();
        added = (_messagesByChat[chatId]?.length ?? 0) - before;
        if (added > 0 || newly.isNotEmpty) {
          return newly.isNotEmpty ? newly.length : added;
        }
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

  /// Returns true when the transcript actually moved (new message, or content
  /// the UI paints differs). Callers on a timer use it to skip no-op notifies.
  bool _upsertMessage(TdlibMessage msg) {
    final list = _messagesByChat.putIfAbsent(msg.chatId, () => []);
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      final prev = list[idx];
      list[idx] = msg;
      return prev.uiFingerprint != msg.uiFingerprint;
    }
    list.add(msg);
    list.sort((a, b) => a.id.compareTo(b.id));
    return true;
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

  Future<void> closeChat(int chatId, {int? openToken}) async {
    // Stale dispose after the same chat was re-opened: must not clear RAM or
    // tell TDLib to close — that triggers from_cache deletes of the new session.
    if (openToken != null &&
        _openChatId == chatId &&
        _activeOpenToken != null &&
        openToken != _activeOpenToken) {
      _mediaLog(
        'closeChat ignore stale token=$openToken '
        'active=$_activeOpenToken chat=$chatId',
      );
      _slog('tg.chat', 'close_stale_ignored', {
        'chatId': chatId,
        'token': openToken,
        'activeToken': _activeOpenToken,
        'msgs': _messagesByChat[chatId]?.length ?? 0,
      });
      return;
    }
    // Dispose of a previous chat after we already opened another: openChat
    // already sent closeChat for the previous id.
    if (_openChatId != null && _openChatId != chatId) {
      _slog('tg.chat', 'close_skip_other_open', {
        'chatId': chatId,
        'token': openToken,
        'activeChatId': _openChatId,
      });
      return;
    }

    if (_openChatId == chatId) {
      _slog('tg.chat', 'close', {
        'chatId': chatId,
        'token': openToken ?? _activeOpenToken,
        'msgs': _messagesByChat[chatId]?.length ?? 0,
      });
      _openChatId = null;
      _activeOpenToken = null;
      AppSessionDiagnostics.instance.setTgOpenChat(null);
      _openTranscriptPreserve.remove(chatId);
      // Resume background jobs that were waiting; rebuild hub so avatars re-queue.
      _pumpDownloadQueue();
      // Never notify synchronously from a widget dispose path.
      scheduleMicrotask(() {
        notifyListeners();
      });
      unawaited(_warmRecentHubMedia());
    }
    await _sendTdlibCloseChat(chatId);
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
    bool disableNotification = false,
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
      'disable_notification': disableNotification,
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
    final trimmed = text.trim();
    final existing = () {
      final list = _messagesByChat[chatId];
      if (list == null) return null;
      for (final m in list) {
        if (m.id == messageId) return m;
      }
      return null;
    }();
    final useCaption = existing != null &&
        (existing.isPhoto ||
            existing.videoFileId != null ||
            existing.isAnimation);
    if (useCaption) {
      await c.sendAwait({
        '@type': 'editMessageCaption',
        'chat_id': chatId,
        'message_id': messageId,
        'caption': {
          '@type': 'formattedText',
          'text': trimmed,
        },
      });
    } else {
      await c.sendAwait({
        '@type': 'editMessageText',
        'chat_id': chatId,
        'message_id': messageId,
        'input_message_content': {
          '@type': 'inputMessageText',
          'text': {
            '@type': 'formattedText',
            'text': trimmed,
          },
        },
      });
    }
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
      final preserved = _openTranscriptPreserve[chatId];
      if (preserved != null) {
        preserved.removeWhere((m) => messageIds.contains(m.id));
      }
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
      final chatIds = <int>{};
      for (final m in all.values) {
        if (m.tgUserId > 0) _matchedTgUserIds.add(m.tgUserId);
        if (m.tgChatId != 0) {
          _matchedTgUserIds.add(m.tgChatId);
          chatIds.add(m.tgChatId);
        }
      }
      // Re-pull getChat so hub badges see fresh unread_count / last_read.
      unawaited(refreshChatSnapshots(chatIds));
    } catch (e) {
      debugPrint('[tdlib] refreshMatchedTgUserIds failed: $e');
    }
  }

  /// Soft-refresh chat rows (unread / last message) without opening them.
  Future<void> refreshChatSnapshots(Iterable<int> chatIds) async {
    final c = _client;
    if (c == null || !isReady) return;
    var changed = false;
    for (final chatId in chatIds) {
      if (chatId == 0) continue;
      try {
        final prev = _chatRowFingerprint(_chats[chatId]);
        final chat = await c.sendAwait({
          '@type': 'getChat',
          'chat_id': chatId,
        });
        if (chat['@type'] != 'chat') continue;
        _applyChatRow(chatId, Map<String, dynamic>.from(chat));
        if (_chatRowFingerprint(_chats[chatId]) != prev) changed = true;
      } catch (e) {
        debugPrint('[tdlib] refreshChatSnapshots($chatId): $e');
      }
    }
    if (changed) {
      _hubChatsCache = null;
      _notifyUi();
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
    var changed = false;
    for (final scope in scopes) {
      try {
        final res = await c.sendAwait({
          '@type': 'getScopeNotificationSettings',
          'scope': {'@type': scope},
        });
        if (res['@type']?.toString() == 'scopeNotificationSettings') {
          final next = Map<String, dynamic>.from(res);
          final prev = _scopeNotificationSettings[scope];
          _scopeNotificationSettings[scope] = next;
          if (prev == null ||
              prev['mute_for'] != next['mute_for']) {
            changed = true;
          }
        }
      } catch (e) {
        debugPrint('[tdlib] getScopeNotificationSettings($scope): $e');
      }
    }
    if (changed) notifyListeners();
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

  /// `true`/`false` when mute is known; `null` until chat settings (and scope
  /// defaults, when used) are loaded — callers should keep snapshot badge color.
  bool? isChatMutedIfKnown(int chatId) {
    final chat = _chats[chatId];
    final settings = chat?['notification_settings'];
    if (settings is! Map) return null;
    // When the chat uses scope defaults, chat.mute_for is ignored by TDLib
    // (often a stale non-zero leftover). Never fall through to it — that made
    // unmuted chats show gray hub badges.
    if (settings['use_default_mute_for'] == true) {
      final scopeType = _scopeTypeForChat(chatId);
      if (scopeType == null) return null;
      final scope = _scopeNotificationSettings[scopeType];
      if (scope == null) return null;
      return ((scope['mute_for'] as num?)?.toInt() ?? 0) > 0;
    }
    return ((settings['mute_for'] as num?)?.toInt() ?? 0) > 0;
  }

  bool isChatMuted(int chatId) => isChatMutedIfKnown(chatId) ?? false;

  /// Text search in a chat (AppBar / message search sheet).
  Future<List<TdlibMessage>> searchChatTextMessages(
    int chatId,
    String query, {
    int limit = 50,
  }) async {
    final c = _client;
    final q = query.trim();
    if (c == null || !isReady || q.isEmpty) return const [];
    try {
      final res = await c.sendAwait({
        '@type': 'searchChatMessages',
        'chat_id': chatId,
        'query': q,
        'from_message_id': 0,
        'offset': 0,
        'limit': limit.clamp(1, 100),
        'filter': {'@type': 'searchMessagesFilterEmpty'},
      });
      return _parseMessagesList(res);
    } catch (e) {
      debugPrint('[tdlib] searchChatTextMessages($chatId): $e');
      return const [];
    }
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
  ///
  /// R22 (SessionLog 16:37): album:prefetch + stall-retry:tap:photo held 1/1
  /// while later taps saw only `focus_hold_block` / empty queue head.
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

    bool isAutofocusish(String r) =>
        r.startsWith('focus:') ||
        r.startsWith('focus-tail:') ||
        r.startsWith('focus-upgrade:') ||
        r.startsWith('neighbor:') ||
        r.startsWith('auto:video:') ||
        r.startsWith('stall-fallback:') ||
        r.startsWith('stall-retry:') ||
        r.startsWith('stall-lastchance:') ||
        r.startsWith('album:prefetch:') ||
        r.startsWith('demoted-after-focus');

    // Drop queued autofocus / neighbor / album-prefetch / stall jobs.
    final drop = _downloadQueue
        .where((j) => j.fileId != fileId && isAutofocusish(j.reason))
        .toList();
    for (final j in drop) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      final w = _downloadWaiters.remove(j.fileId);
      if (w != null && !w.isCompleted) w.complete(null);
    }

    // Cancel any non-tap holder of the exclusive slot (incl. partial idle).
    // Keep other tap:* only if bytes are flowing (lastBytes>0 and recent).
    final blockers = <int>[];
    for (final id in _downloadInFlight.toList()) {
      if (id == fileId) continue;
      final t = _downloadTrace[id];
      final r = t?.reason ?? '';
      if (r.startsWith('tap:') && r != reason) {
        final idle = t?.lastProgressAt == null
            ? const Duration(days: 1)
            : DateTime.now().difference(t!.lastProgressAt!);
        if ((t?.lastBytes ?? 0) > 0 && idle < const Duration(seconds: 8)) {
          continue; // live peer tap
        }
      }
      blockers.add(id);
    }
    if (blockers.isNotEmpty || drop.isNotEmpty) {
      _mediaLog(
        'preempt-tap file=$fileId cancel=${blockers.join(",")} '
        'dropQ=${drop.map((j) => '${j.fileId}:${j.reason}').join(",")} '
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
      final w = _downloadWaiters.remove(id);
      if (w != null && !w.isCompleted) w.complete(null);
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

    // FakeTLS exclusive slot: bare ensure (profile/header avatar sheets) must
    // not hold 1/1 at 0B (A/B: ensure file=1309 idle 12s while chat open).
    // User taps use reason tap:* / focus paths — those still go on the wire.
    // R22: album:prefetch also stays disk-only — 5 waiters piled behind one
    // 0B focus (SessionLog 16:37 queued=6).
    final isBareEnsure = reason == 'ensure' ||
        reason == 'peer-avatar' ||
        reason == 'avatar' ||
        reason.startsWith('ensure:');
    final isAlbumPrefetch = reason.startsWith('album:prefetch:');
    if (_enabledProxyId != null && (isBareEnsure || isAlbumPrefetch)) {
      if (await _probeLocalFile(fileId)) {
        return _filePathCache[fileId];
      }
      _mediaLog(
        'ensure-skip-proxy file=$fileId reason=$reason '
        '(no wire for ${isAlbumPrefetch ? 'album-prefetch' : 'avatar/ensure'} '
        'under FakeTLS)',
      );
      _slog('tg.media', 'ensure_skip_proxy', {
        'fileId': fileId,
        'reason': reason,
      });
      return null;
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
    // Viewer tap must preempt foreign-chat ensure holding the only slot.
    // R17 / R8: do NOT force origin (offset=1) on tap — official + our
    // locked ladder is CDN-first; stall-recover adds origin after 0B.
    // SessionLog 00:14: tap:video forceBypass burned ~75s Ready+0B on
    // origin, then CDN retry delivered the file (00:17:26).
    if (reason.startsWith('tap:') || reason.startsWith('ensure')) {
      await _yieldSlotsToFocus({fileId});
    }
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

  /// Whether the current user is the group/channel creator.
  Future<bool> amChatCreator(int chatId) async {
    final c = _client;
    final myId = _myUserId;
    if (c == null || !isReady || myId == null || myId <= 0 || chatId == 0) {
      return false;
    }
    try {
      final res = await c.sendAwait({
        '@type': 'getChatMember',
        'chat_id': chatId,
        'member_id': {'@type': 'messageSenderUser', 'user_id': myId},
      });
      if (res['@type'] != 'chatMember') return false;
      final status = res['status'];
      if (status is! Map) return false;
      return status['@type']?.toString() == 'chatMemberStatusCreator';
    } catch (e) {
      debugPrint('[tdlib] amChatCreator($chatId): $e');
      return false;
    }
  }

  Future<List<TdlibChatMember>> chatMembers(
    int chatId, {
    int limit = 100,
  }) async {
    final c = _client;
    if (c == null || !isReady || chatId == 0) return const [];
    final chat = _chats[chatId];
    if (chat == null) return const [];
    final type = chat['type'];
    if (type is! Map) return const [];
    final typeName = type['@type']?.toString() ?? '';
    final out = <TdlibChatMember>[];

    try {
      if (typeName == 'chatTypeBasicGroup') {
        final bgId = _tdlibInt(type['basic_group_id']);
        if (bgId <= 0) return const [];
        final full = await c.sendAwait({
          '@type': 'getBasicGroupFullInfo',
          'basic_group_id': bgId,
        });
        final members = full['members'];
        if (members is! List) return const [];
        for (final raw in members) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          final memberId = m['member_id'];
          var userId = 0;
          if (memberId is Map) {
            userId = _tdlibInt(memberId['user_id']);
          } else {
            userId = _tdlibInt(m['user_id']);
          }
          if (userId <= 0) continue;
          final status = m['status'];
          final statusType =
              status is Map ? status['@type']?.toString() ?? '' : '';
          out.add(_chatMemberFromUserId(
            userId,
            isCreator: statusType == 'chatMemberStatusCreator',
            isAdmin: statusType == 'chatMemberStatusAdministrator',
          ));
        }
      } else if (typeName == 'chatTypeSupergroup') {
        final isChannel = type['is_channel'] == true;
        if (isChannel) return const [];
        var offset = '';
        while (out.length < limit) {
          final res = await c.sendAwait({
            '@type': 'getSupergroupMembers',
            'supergroup_id': _tdlibInt(type['supergroup_id']),
            'filter': {'@type': 'supergroupMembersFilterRecent'},
            'offset': offset.isEmpty ? 0 : int.tryParse(offset) ?? out.length,
            'limit': (limit - out.length).clamp(1, 200),
          });
          if (res['@type'] != 'chatMembers') break;
          final members = res['members'];
          if (members is! List || members.isEmpty) break;
          for (final raw in members) {
            if (raw is! Map) continue;
            final m = Map<String, dynamic>.from(raw);
            final memberId = m['member_id'];
            var userId = 0;
            if (memberId is Map) {
              userId = _tdlibInt(memberId['user_id']);
            } else {
              userId = _tdlibInt(m['user_id']);
            }
            if (userId <= 0) continue;
            final status = m['status'];
            final statusType =
                status is Map ? status['@type']?.toString() ?? '' : '';
            out.add(_chatMemberFromUserId(
              userId,
              isCreator: statusType == 'chatMemberStatusCreator',
              isAdmin: statusType == 'chatMemberStatusAdministrator',
            ));
            if (out.length >= limit) break;
          }
          final total = (res['total_count'] as num?)?.toInt() ?? out.length;
          if (out.length >= total || members.isEmpty) break;
          // getSupergroupMembers uses numeric offset in recent TDLib.
          offset = '${out.length}';
          if (members.length < 10) break;
        }
      }
    } catch (e) {
      debugPrint('[tdlib] chatMembers($chatId): $e');
    }

    out.sort((a, b) {
      if (a.isCreator != b.isCreator) return a.isCreator ? -1 : 1;
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return out;
  }

  TdlibChatMember _chatMemberFromUserId(
    int userId, {
    required bool isCreator,
    required bool isAdmin,
  }) {
    final name = senderDisplayName(userId);
    final user = _users[userId];
    final photo = user?['profile_photo'];
    int? fileId;
    List<int>? mini;
    if (photo is Map) {
      fileId = _tdlibPhotoFileId(photo, 'small');
      final mt = photo['minithumbnail'];
      if (mt is Map) {
        final data = mt['data'];
        if (data is List) {
          mini = [
            for (final e in data)
              if (e is num) e.toInt(),
          ];
          if (mini.isEmpty) mini = null;
        }
      }
    }
    String? path;
    if (fileId != null && fileId > 0) {
      path = _filePathCache[fileId];
      if (path == null || path.isEmpty) {
        _queueFileDownload(
          fileId,
          priority: prioBackground,
          background: true,
          reason: 'member-avatar',
        );
      }
    }
    return TdlibChatMember(
      userId: userId,
      displayName: name.isEmpty ? 'User $userId' : name,
      avatarLocalPath: path,
      avatarMinithumbnailBytes: mini,
      isCreator: isCreator,
      isAdmin: isAdmin,
    );
  }

  /// Kick member; messages are kept (`revoke_messages: false`).
  Future<void> removeChatMember(int chatId, int userId) async {
    final c = _client;
    if (c == null || !isReady || chatId == 0 || userId <= 0) return;
    await c.sendAwait({
      '@type': 'banChatMember',
      'chat_id': chatId,
      'member_id': {'@type': 'messageSenderUser', 'user_id': userId},
      'banned_until_date': 0,
      'revoke_messages': false,
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
  /// getChat already tried and still no photo — stop the rebuild loop.
  final Set<int> _chatPhotoRefreshDone = {};
  final Set<int> _hubAvatarMissingLogged = {};
  /// fileId → stall recoveries already tried (alt size / delayed requeue).
  final Map<int, int> _hubAvatarStallAttempts = {};
  /// Per-chat cooldown for hub avatar downloads after consecutive STALL-0B.
  final Map<int, DateTime> _hubAvatarCoolUntil = {};
  /// file_ids that repeatedly stall at 0 bytes (CDN remote poison); skip until chat.photo refreshes.
  final Set<int> _hubAvatarPoisonFileIds = {};
  /// remoteFile ids tied to poisoned file_ids (survive file_id rotation).
  final Set<String> _hubAvatarPoisonRemotes = {};
  /// Last getChat refresh attempt after stall give-up (per chat).
  final Map<int, DateTime> _hubAvatarPhotoRefreshAt = {};
  /// fileId → do not re-enqueue hub-avatar until this time (after give-up).
  final Map<int, DateTime> _hubAvatarCooldownUntil = {};
  /// After a 0B stall on CDN (offset=0), retry once with origin-only (offset=1).
  final Set<int> _downloadForceBypassCdnOnce = {};
  /// fileIds that already tried offset=1 — don't flip again on every stall.
  final Set<int> _downloadTriedBypassCdn = {};

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
      // FakeTLS: header avatar must not grab the exclusive wire slot before
      // channel media (Shariy: peer-avatar soft-purge left TDLib still pulling).
      if (_enabledProxyId != null) {
        _mediaLog(
          'defer peer-avatar file=$idToFetch chat=$chatId (proxy exclusive)',
        );
        return;
      }
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
      _queueAvatarDownload(idToFetch, chatId: chatId);
    }
  }

  int? _tdlibPhotoFileId(dynamic photo, String key) {
    if (photo is! Map) return null;
    final f = photo[key];
    if (f is! Map) return null;
    final id = _tdlibInt(f['id']);
    return id > 0 ? id : null;
  }

  String _tdlibPhotoRemoteUnique(dynamic photo, String key) {
    if (photo is! Map) return '';
    final f = photo[key];
    if (f is! Map) return '';
    final remote = f['remote'];
    if (remote is! Map) return '';
    return remote['unique_id']?.toString().trim() ?? '';
  }

  void _refreshChatPhotoIfMissing(int chatId) {
    if (chatId == 0) return;
    if (_chatPhotoRefreshQueued.contains(chatId)) return;
    if (_chatPhotoRefreshDone.contains(chatId)) return;
    final existing = _chats[chatId];
    final beforeId =
        existing == null ? null : _resolveChatAvatarFileId(existing);
    if (beforeId != null) {
      _chatPhotoRefreshDone.add(chatId);
      return;
    }
    final c = _client;
    if (c == null) return;
    _chatPhotoRefreshQueued.add(chatId);
    unawaited(() async {
      try {
        final chat = await c.sendAwait({
          '@type': 'getChat',
          'chat_id': chatId,
        });
        if (chat['@type'] != 'chat') return;
        _applyChatRow(chatId, Map<String, dynamic>.from(chat));

        // Private peers: profile_photo often carries small/big when chat.photo
        // only has a minithumbnail stub.
        final type = chat['type'];
        if (type is Map && type['@type'] == 'chatTypePrivate') {
          final uid = _tdlibInt(type['user_id']);
          if (uid > 0) {
            try {
              final user = await c.sendAwait({
                '@type': 'getUser',
                'user_id': uid,
              });
              if (user['@type'] == 'user') {
                _users[uid] = Map<String, dynamic>.from(user);
              }
            } catch (_) {}
          }
        }

        final afterId = _resolveChatAvatarFileId(
          _chats[chatId]!,
          user: _privateUserId(chatId) == null
              ? null
              : _users[_privateUserId(chatId)!],
        );
        final photo = _chats[chatId]!['photo'];
        final keys = photo is Map
            ? photo.keys.map((k) => k.toString()).join(',')
            : 'null';
        _mediaLog(
          'photo-refresh chat=$chatId afterId=$afterId photoKeys=$keys',
        );
        _ensurePeerAvatarDownloading(
          chatId,
          foreground: _openChatId == chatId,
        );
        // Critical: do NOT notify when photo is still missing. Otherwise
        // peerAvatarPath → refresh → notify → rebuild loops forever for
        // groups without a resolvable profile photo (ТП НСИС…) — ~320ms
        // FRAME every ~330ms and fling never starts.
        if (afterId != null && afterId != beforeId) {
          _notifyUi();
        }
      } catch (e) {
        _mediaLog('photo-refresh fail chat=$chatId err=$e');
      } finally {
        _chatPhotoRefreshQueued.remove(chatId);
        _chatPhotoRefreshDone.add(chatId);
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

  /// Ensure Saved Messages private chat exists; returns its chat id.
  Future<int?> ensureSavedMessagesChatId() async {
    final c = _client;
    final myId = _myUserId;
    if (c == null || !isReady || myId == null || myId <= 0) return null;
    final existing = privateChatIdForUser(myId);
    if (existing != null && existing != 0) return existing;
    try {
      final res = await c.sendAwait({
        '@type': 'createPrivateChat',
        'user_id': myId,
        'force': true,
      }, timeout: const Duration(seconds: 15));
      final chatId = (res['id'] as num?)?.toInt() ??
          (res['chat_id'] as num?)?.toInt();
      if (chatId != null && chatId != 0) return chatId;
    } catch (e) {
      debugPrint('[tdlib] ensureSavedMessagesChatId: $e');
    }
    return myId;
  }

  /// Pull a page of recent messages without opening the chat UI.
  Future<List<TdlibMessage>> fetchRecentChatMessages(
    int chatId, {
    int limit = 80,
  }) async {
    final c = _client;
    if (c == null || !isReady || chatId == 0) return const [];
    try {
      final res = await c.sendAwait({
        '@type': 'getChatHistory',
        'chat_id': chatId,
        'from_message_id': 0,
        'offset': 0,
        'limit': limit.clamp(1, 100),
        'only_local': false,
      }, timeout: const Duration(seconds: 25));
      if (res['@type'] != 'messages') return const [];
      final parsed = _parseMessagesList(res);
      var changed = false;
      for (final m in parsed) {
        if (_upsertMessage(m)) changed = true;
      }
      // Saved-Messages bridge polls this chat in the background — it must not
      // rebuild an unrelated open conversation.
      if (changed) _notifyListenersForChat(chatId);
      return parsed;
    } catch (e) {
      debugPrint('[tdlib] fetchRecentChatMessages($chatId): $e');
      return const [];
    }
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
          } else if (_openChatId == null) {
            _queueAvatarDownload(photoId);
          }
          // Open group: skip sender-avatar enqueue — exclusive focus owns slots.
        }
        // Batch many getUser completions (large groups) into one frame.
        _notifyUi();
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
      unawaited(_refreshUser(userId, queueAvatar: false));
    }
    // UI only shows online status for the open private peer. Groups show
    // "группа" — notifying here rebuilt the whole NSIS transcript on every
    // member going online/offline.
    final openId = _openChatId;
    if (openId != null) {
      if (_privateUserId(openId) == userId) {
        _notifyUi();
      }
      return;
    }
    // Hub has no online dots — keep data warm, skip rebuilds.
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
    // Only suppress while the user is already looking at this chat.
    // Matched FC↔TG DMs used to skip TDLib banners ("FC/secretary only"), but
    // secretary is soft-killed and FC does not push TG-only messages — so Киса
    // pushes arrived via FCM, then ackRemoveNotification wiped them (unread=0
    // locally while MTProto was WaitingForNetwork).
    return _openChatId == chatId;
  }

  Future<void> _showOrSkipTdlibNotification({
    required int groupId,
    required int chatId,
    required Map<String, dynamic> notification,
    required bool isSilent,
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;

    // Muted / silent (TDLib is_silent or notification_sound_id=0): never raise
    // a system banner — matches official TG. Do not removeNotification: that
    // would ack the group and can wipe unread while the chat stays muted.
    if (isSilent) {
      await _cancelLocalTdlibNotification(chatId);
      return;
    }

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
    assert(() {
      debugPrint(
        '[unread-dbg] ackRemoveNotification group=$groupId notif=$id '
        'chat=${_notifGroupChatId[groupId]} '
        'unread=${unreadCountFor(_notifGroupChatId[groupId] ?? 0)}',
      );
      return true;
    }());
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
    // Open chat owns download slots — don't even attempt hub/sender avatars.
    if (_openChatId != null) return;
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
      chatId: null,
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
            _applyChatRow(id, Map<String, dynamic>.from(chat));
            _syncChatOrderMembership(id);
            _reindexFolderMembership(id);
            final lastOut =
                (chat['last_read_outbox_message_id'] as num?)?.toInt();
            if (lastOut != null) _lastReadOutboxId[id] = lastOut;
            _resolveChatAvatarFileId(_chats[id]!);
            _notifyListenersForChat(id, hubOnly: true);
          }
        }
        break;
      case 'updateChatPosition':
        final chatId = (update['chat_id'] as num?)?.toInt();
        final position = update['position'];
        if (chatId != null && position is Map) {
          _applyChatPosition(chatId, Map<String, dynamic>.from(position));
          _notifyListenersForChat(chatId, hubOnly: true);
        }
        break;
      case 'updateChatFolders':
        unawaited(_onChatFoldersUpdate(update));
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
            _reindexFolderMembership(chatId);
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
              // Unread for closed chats: rely on unreadCountFor tip heuristic
              // + updateChatReadInbox. Do not mutate unread_count here — a
              // stored bump of 1 used to revive after stale getChat merges.
            }
          }
        } else if (type == 'updateChatReadInbox') {
          assert(() {
            debugPrint(
              '[unread-dbg] readInbox chat=$chatId '
              'unread=${update['unread_count']} '
              'lastReadInbox=${update['last_read_inbox_message_id']}',
            );
            return true;
          }());
          final lastIn = _tdlibInt(update['last_read_inbox_message_id']);
          if (lastIn > 0) {
            _advanceReadInboxFloor(chatId, lastIn);
          }
          final incomingUnread = _tdlibInt(update['unread_count']);
          final tip = chat['last_message'];
          final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
          final readThrough = _effectiveLastReadInbox(chatId);
          if (tipId > 0 && tipId <= readThrough) {
            chat['unread_count'] = 0;
          } else {
            // Keep progressive-read optimistic floor when TDLib lags.
            final optimistic = _tdlibInt(chat['unread_count']);
            if (optimistic > 0 &&
                incomingUnread > 0 &&
                incomingUnread > optimistic) {
              chat['unread_count'] = optimistic;
            } else {
              chat['unread_count'] = incomingUnread;
            }
          }
          if (unreadCountFor(chatId) > 0) {
            unawaited(warmUnreadChatHistory(chatId));
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
          _miniThumbByChatId.remove(chatId);
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
        _notifyListenersForChat(chatId);
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
        // Official guidance (td#620): from_cache means TDLib unloaded RAM,
        // not that messages were deleted. Safe — and required — to ignore
        // when we keep our own open-chat transcript. Applying them was the
        // main "history collapsed to last_message" bug after close/reopen.
        if (update['from_cache'] == true) {
          _slog('tg.history', 'delete_from_cache_ignored', {
            'chatId': chatId,
            'count': ids is List ? ids.length : 0,
            'isOpen': chatId == _openChatId,
            'msgs': chatId == null
                ? 0
                : (_messagesByChat[chatId]?.length ?? 0),
          });
          break;
        }
        if (chatId != null && ids is List) {
          final idSet = ids
              .map((e) => (e as num?)?.toInt())
              .whereType<int>()
              .toSet();
          if (idSet.isEmpty) break;
          final before = _messagesByChat[chatId]?.length ?? 0;
          _messagesByChat[chatId]?.removeWhere((m) => idSet.contains(m.id));
          final preserved = _openTranscriptPreserve[chatId];
          if (preserved != null) {
            preserved.removeWhere((m) => idSet.contains(m.id));
          }
          _slog('tg.history', 'delete_applied', {
            'chatId': chatId,
            'removed': idSet.length,
            'permanent': update['is_permanent'] == true,
            'msgsBefore': before,
            'msgsAfter': _messagesByChat[chatId]?.length ?? 0,
            'isOpen': chatId == _openChatId,
          });
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
          if (_chatActions.remove(chatId) != null) {
            _notifyListenersForChat(chatId);
          }
        } else if (_chatActions[chatId] != label) {
          _chatActions[chatId] = label;
          _notifyListenersForChat(chatId);
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
            if (msg.chatId == _openChatId) {
              _slog('tg.chat', 'new_msg_open', {
                'chatId': msg.chatId,
                'msgId': msg.id,
                'out': msg.isOutgoing,
                'isPhoto': msg.isPhoto,
                'isVideo': msg.isVideo,
                'service': msg.isService,
                'preview': SessionLog.textPreview(msg.text),
                'msgs': _messagesByChat[msg.chatId]?.length ?? 0,
              });
            }
            if (msg.isService) {
              unawaited(refreshVideoChat(msg.chatId));
            }
            if (msg.chatId == _openChatId) {
              _maybeAutoMarkRead(msg.chatId, msg.id);
              focusVisibleMessageMedia(
                chatId: msg.chatId,
                messageId: msg.id,
              );
            } else if (!msg.isOutgoing && !msg.isService) {
              // Tip heuristic in unreadCountFor covers hub badges; do not
              // permanently bump chat['unread_count'] (revives after getChat).
              unawaited(warmUnreadChatHistory(msg.chatId));
            }
            if (!msg.isService && _bridgeNewMessageListeners.isNotEmpty) {
              for (final bridgeHook in List.of(_bridgeNewMessageListeners)) {
                try {
                  bridgeHook(msg);
                } catch (e) {
                  debugPrint('[tdlib] onBridgeNewMessage: $e');
                }
              }
            }
            _notifyListenersForChat(msg.chatId);
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
        if (message is Map) {
          final msg = _parseMessage(Map<String, dynamic>.from(message));
          if (msg != null) {
            // Keep the bubble with failed status (clock → retry icon), do not
            // silently drop it — offline sends used to vanish from the list.
            if (oldId != null && oldId != msg.id) {
              _replaceMessageId(chatId: msg.chatId, oldId: oldId, msg: msg);
            } else {
              _upsertMessage(msg);
            }
            notifyListeners();
          }
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
          AppSessionDiagnostics.instance.setTgState(
            conn: name,
            phase: phase.name,
            proxy: _useMtprotoProxy,
          );
          _slog('tg.conn', 'state', {
            'from': prev,
            'to': name,
            'phase': phase.name,
            'openChatId': _openChatId,
            'msgsOpen': _openChatId == null
                ? null
                : (_messagesByChat[_openChatId!]?.length ?? 0),
          });
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
      var changed = true;
      if (idx >= 0) {
        changed = list[idx].uiFingerprint != msg.uiFingerprint;
        list[idx] = msg;
      } else {
        list.add(msg);
        list.sort((a, b) => a.id.compareTo(b.id));
      }
      // Interaction-info churn re-reads messages that did not change.
      if (changed) _notifyListenersForChat(chatId);
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
        _setAuthPhase(TdlibAuthPhase.waitPhone);
        _hubSurfaceReady = true;
        notifyListeners();
        break;
      case 'authorizationStateWaitCode':
        _setAuthPhase(TdlibAuthPhase.waitCode);
        _hubSurfaceReady = true;
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
        _setAuthPhase(TdlibAuthPhase.waitPassword);
        _hubSurfaceReady = true;
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
        _setAuthPhase(TdlibAuthPhase.ready);
        errorMessage = null;
        _didWipeForEncryption = false;
        // Keep hub skeleton until main list (+ folders) finish loading.
        _hubSurfaceReady = false;
        notifyListeners();
        unawaited(_setTdlibOnline(true));
        _ensureNetworkLinkWatch();
        await refreshChatList();
        await _awaitInitialFolderInfos();
        // Need scopes before hub paints badges — otherwise isChatMuted fell
        // through to stale chat.mute_for and every unread looked gray.
        await _loadScopeNotificationSettings();
        _setHubSurfaceReady(true);
        unawaited(refreshMatchedTgUserIds());
        unawaited(_enableNotificationApiAndRegisterDevice());
        unawaited(_syncTdlibIdentityAfterReady());
        break;
      case 'authorizationStateLoggingOut':
        _setAuthPhase(TdlibAuthPhase.loggingOut);
        _hubSurfaceReady = false;
        notifyListeners();
        break;
      case 'authorizationStateClosing':
      case 'authorizationStateClosed':
        _parametersApplied = false;
        if (_tearingDown) {
          _setAuthPhase(TdlibAuthPhase.starting, why: 'teardown-closed');
          notifyListeners();
          break;
        }
        _mediaLog('auth Closed unexpectedly — recovering client');
        _setAuthPhase(TdlibAuthPhase.starting, why: 'auth-closed');
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
      // R31b: setTdlibParameters first, then enableProxy, then caller goes
      // online/WiFi (ensureStartedBody). Pre-params addProxy timed out on this
      // TDLib build (SessionLog 17:28: getProxies/addProxy TimeoutException)
      // and left proxyId=- while bearer-recover None-bounced mid-boot.
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

  /// Queue ensure/disable so concurrent geo + AppBar + bearer cannot interleave
  /// TDLib proxy RPCs (R18). Inner helpers must call unlocked variants.
  Future<void> _enqueueProxyMutate(Future<void> Function() op) {
    final prev = _proxyMutateTail;
    late final Future<void> curr;
    curr = prev.catchError((_) {}).then((_) => op());
    _proxyMutateTail = curr;
    return curr;
  }

  Future<void> _ensureProxy() => _enqueueProxyMutate(_ensureProxyUnlocked);

  Future<void> _ensureProxyUnlocked() async {
    final c = _client;
    if (c == null) return;

    await _loadDebugMtprotoProxyPref();
    if (kDebugMode && !_debugMtprotoProxyPref) {
      _useMtprotoProxy = false;
      _useMtprotoProxyResolved = false;
      _mediaLog('proxy skipped (user AppBar OFF)');
      await _disableAllProxiesUnlocked(c, why: 'debug-switch-off');
      _enabledProxyId = null;
      return;
    }

    // R18: AppBar ON (or release) → follow geo. Do not force FakeTLS abroad
    // (VPN leave-RU must stay direct; return-to-RU re-enables via geo recheck).
    _useMtprotoProxyResolved ??= await shouldUseTdlibMtprotoProxy();
    _useMtprotoProxy = _useMtprotoProxyResolved!;
    if (!_useMtprotoProxy) {
      _mediaLog('proxy skipped (IP outside RU — direct MTProto)');
      await _disableAllProxiesUnlocked(c, why: 'geo-non-ru');
      _enabledProxyId = null;
      return;
    }

    await _refreshRemoteProxyEndpoints();

    final endpoints = _activeProxyEndpoints;
    if (endpoints.isEmpty) {
      _mediaLog('proxy ensure FAIL (no endpoints configured)');
      return;
    }
    final epoch = _activeProxyEpoch;
    const epochPrefKey = 'tdlib_mtproto_proxy_secret_epoch';
    var forceSecretRotate = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      forceSecretRotate = (prefs.getInt(epochPrefKey) ?? 0) != epoch;
    } catch (_) {}
    if (forceSecretRotate) {
      // New secret generation — wipe rows and start from primary.
      _proxyEndpointIndex = 0;
      _endpointProxyIds.clear();
      await _disableAllProxiesUnlocked(c, why: 'secret-epoch-rotate');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(epochPrefKey, epoch);
        _mediaLog('proxy epoch saved=$epoch');
      } catch (_) {}
    } else {
      // Prefer the hop that last reached Ready on this device/network.
      // (R24 mid-ladder skip stuck us on dead 8443 — SessionLog 14:41–14:44.)
      await _loadPreferredProxyEndpointIndex();
    }
    if (_proxyEndpointIndex < 0 || _proxyEndpointIndex >= endpoints.length) {
      _proxyEndpointIndex = 0;
    }
    final endpoint = endpoints[_proxyEndpointIndex];
    final server = endpoint.server;
    final port = endpoint.port;
    final secret = endpoint.secret;
    try {
      _mediaLog(
        'proxy ensure ${endpoint.label} $server:$port (mtproto FakeTLS) '
        'secret=${secret.length}b ${secret.substring(0, 6)}…${secret.substring(secret.length - 8)} '
        'epoch=$epoch rotate=$forceSecretRotate idx=$_proxyEndpointIndex',
      );

      // Register all endpoints (enable only preferred). Keeps pingProxy able
      // to health-check candidates without add/remove storms on each failover.
      await _syncAllProxyEndpointRows(enableIndex: _proxyEndpointIndex);
      final proxyId = _enabledProxyId;
      if (proxyId != null) {
        // Post-Ready diagnostic only — selection probes use ping while Connecting.
        unawaited(_pingProxyWhenReady(c, proxyId));
      }
    } catch (e) {
      _mediaLog('proxy FAIL err=$e');
      debugPrint('[tdlib] ensureProxy failed: $e');
    }
  }

  Future<void> _disableAllProxies(
    TdlibJsonClient c, {
    required String why,
  }) =>
      _enqueueProxyMutate(() => _disableAllProxiesUnlocked(c, why: why));

  Future<void> _disableAllProxiesUnlocked(
    TdlibJsonClient c, {
    required String why,
  }) async {
    try {
      await c.sendAwait({
        '@type': 'disableProxy',
      }, timeout: const Duration(seconds: 3));
      _mediaLog('proxy disabled why=$why');
    } catch (e) {
      _mediaLog('proxy disable soft-fail why=$why err=$e');
    }
    try {
      final list = await c.sendAwait({
        '@type': 'getProxies',
      }, timeout: const Duration(seconds: 5));
      final proxies = list['proxies'];
      if (proxies is! List) return;
      for (final raw in proxies) {
        if (raw is! Map) continue;
        final p = _flattenProxyEntry(raw);
        final id = (p['id'] as num?)?.toInt();
        if (id == null) continue;
        try {
          await c.sendAwait({
            '@type': 'removeProxy',
            'proxy_id': id,
          }, timeout: const Duration(seconds: 3));
          _mediaLog('proxy removed id=$id why=$why');
        } catch (e) {
          _mediaLog('proxy remove id=$id soft-fail why=$why err=$e');
        }
      }
    } catch (e) {
      _mediaLog('proxy getProxies soft-fail why=$why err=$e');
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
    // Wait for auth + DC settle. Early ping during waitCode/password races
    // false Pong timeouts and our evenIfReady failover then tears Ready down
    // (SessionLog 2026-10-04 20:48–20:49).
    await Future<void>.delayed(const Duration(seconds: 20));
    if (!_tdlibReadyForMedia) {
      _mediaLog('proxy ping skip id=$proxyId (dropped Ready while waiting)');
      return;
    }
    if (phase != TdlibAuthPhase.ready) {
      _mediaLog('proxy ping skip id=$proxyId (auth=$phase)');
      return;
    }
    if (_enabledProxyId != null && _enabledProxyId != proxyId) {
      _mediaLog(
        'proxy ping skip id=$proxyId (enabled moved to $_enabledProxyId)',
      );
      return;
    }
    try {
      final ping = await client.sendAwait(
        {'@type': 'pingProxy', 'proxy_id': proxyId},
        timeout: const Duration(seconds: 12),
      );
      final sec = (ping['seconds'] as num?)?.toDouble();
      if (sec != null && sec >= 0) {
        _lastPongMs = (sec * 1000).round();
        _lastPongAt = DateTime.now();
      }
      _mediaLog('proxy ping ok id=$proxyId seconds=$sec');
      _slog('tg.proxy', 'pong', {
        'proxyId': proxyId,
        'seconds': sec,
        'lastPongMs': _lastPongMs,
      });
      // Media path proven — remember this hop for next boot.
      unawaited(_persistPreferredProxyEndpoint(_proxyEndpointIndex));
      _avatarGiveUpStreak = 0;
    } on TdlibApiException catch (e) {
      // Soft-fail only: do NOT failover here. Blind RR after a single Pong
      // timeout dropped a working Ready session into long Connecting.
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
    int? videoSizeBytes;
    int? videoThumbFileId;
    String? videoThumbPath;
    List<int>? videoThumbBytes;
    var isAnimation = false;
    var isSticker = false;
    String? stickerEmoji;
    var isService = false;
    int? documentFileId;
    String? documentPath;
    String? documentFileName;
    String? documentMimeType;
    int? documentSizeBytes;
    int? documentThumbFileId;
    String? documentThumbPath;
    List<int>? documentThumbBytes;
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
            voiceFileId = _tdlibFileId(voice);
            voicePath = _tdlibLocalPath(voice);
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
            videoNoteFileId = _tdlibFileId(video);
            videoNotePath = _tdlibLocalPath(video);
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
          final durationSec = _tdlibInt(media['duration']);
          if (durationSec > 0) videoDurationMs = durationSec * 1000;
          final w = _tdlibInt(media['width']);
          final h = _tdlibInt(media['height']);
          if (w > 0) videoWidth = w;
          if (h > 0) videoHeight = h;
          final file = _tdlibNestedFile(media);
          if (file != null) {
            videoFileId = _tdlibFileId(file);
            videoPath = _tdlibLocalPath(file);
            final size = _tdlibInt(file['size']);
            final expected = _tdlibInt(file['expected_size']);
            videoSizeBytes =
                size > 0 ? size : (expected > 0 ? expected : null);
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
        if (doc is Map) {
          documentFileName = doc['file_name']?.toString();
          documentMimeType = doc['mime_type']?.toString();
          documentThumbBytes = _minithumbnailBytes(doc['minithumbnail']);
          final thumbParsed = _parseThumbnailFile(doc['thumbnail']);
          documentThumbFileId = thumbParsed.fileId;
          documentThumbPath = thumbParsed.localPath;
          final file = _tdlibNestedFile(doc);
          if (file != null) {
            documentFileId = _tdlibFileId(file);
            final size = _tdlibInt(file['size']);
            final expected = _tdlibInt(file['expected_size']);
            documentSizeBytes = size > 0 ? size : (expected > 0 ? expected : null);
            documentPath = _tdlibLocalPath(file);
          }
        }
        // Keep a stable non-empty label for list/reply previews when there is
        // no caption — the bubble itself uses the file card, not this text.
        if (text.isEmpty) {
          final name = (documentFileName ?? '').trim();
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
        isSticker = true;
        final sticker = content['sticker'];
        if (sticker is Map) {
          stickerEmoji = sticker['emoji']?.toString();
          final w = _tdlibInt(sticker['width']);
          final h = _tdlibInt(sticker['height']);
          final format = sticker['format'];
          final formatType =
              format is Map ? (format['@type']?.toString() ?? '') : '';
          final miniBytes = _minithumbnailBytes(sticker['minithumbnail']);
          final thumbParsed = _parseThumbnailFile(sticker['thumbnail']);
          final file = _tdlibNestedFile(sticker);
          final fileId = _tdlibFileId(file);
          final filePath = file == null ? null : _tdlibLocalPath(file);
          if (formatType == 'stickerFormatWebm') {
            // Animated sticker — muted looping video (same path as GIF).
            isAnimation = true;
            videoFileId = fileId;
            videoPath = filePath;
            videoThumbBytes = miniBytes;
            videoThumbFileId = thumbParsed.fileId;
            videoThumbPath = thumbParsed.localPath;
            if (w > 0) videoWidth = w;
            if (h > 0) videoHeight = h;
          } else if (formatType == 'stickerFormatTgs') {
            // Lottie — show static thumbnail (full TGS not played in bubble).
            photoId = thumbParsed.fileId ?? fileId;
            photoPath = thumbParsed.localPath ?? filePath;
            photoThumbBytes = miniBytes;
            if (w > 0) photoWidth = w;
            if (h > 0) photoHeight = h;
          } else {
            // webp / default — static image sticker.
            photoId = fileId ?? thumbParsed.fileId;
            photoPath = filePath ?? thumbParsed.localPath;
            photoThumbBytes = miniBytes;
            if (w > 0) photoWidth = w;
            if (h > 0) photoHeight = h;
          }
        }
        // Placeholder for list/reply; bubble hides it when media is present.
        final emoji = (stickerEmoji ?? '').trim();
        text = emoji.isNotEmpty ? emoji : 'Стикер';
        textEntities = const [];
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
    if (documentFileId != null &&
        documentPath != null &&
        documentPath.isNotEmpty) {
      _filePathCache[documentFileId] = documentPath;
    }
    if (documentThumbFileId != null &&
        documentThumbPath != null &&
        documentThumbPath.isNotEmpty) {
      _filePathCache[documentThumbFileId] = documentThumbPath;
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
      videoSizeBytes: videoSizeBytes,
      videoThumbFileId: videoThumbFileId,
      videoThumbLocalPath: videoThumbPath ??
          (videoThumbFileId == null
              ? null
              : _filePathCache[videoThumbFileId]),
      videoThumbBytes: videoThumbBytes,
      isAnimation: isAnimation,
      isSticker: isSticker,
      stickerEmoji: stickerEmoji,
      documentFileId: documentFileId,
      documentLocalPath: documentPath ??
          (documentFileId == null ? null : _filePathCache[documentFileId]),
      documentFileName: documentFileName,
      documentMimeType: documentMimeType,
      documentSizeBytes: documentSizeBytes,
      documentThumbFileId: documentThumbFileId,
      documentThumbLocalPath: documentThumbPath ??
          (documentThumbFileId == null
              ? null
              : _filePathCache[documentThumbFileId]),
      documentThumbBytes: documentThumbBytes,
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
      sendingState: () {
        final ss = m['sending_state'];
        if (ss is! Map) return null;
        final t = ss['@type']?.toString() ?? '';
        if (t == 'messageSendingStatePending') return 'pending';
        if (t == 'messageSendingStateFailed') return 'failed';
        return null;
      }(),
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
      // Soft picks are common; logging every ListView rebuild stalls scroll.
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
    final id = _tdlibFileId(file);
    String? path;
    final local = file['local'];
    if (local is Map && local['is_downloading_completed'] == true) {
      path = local['path']?.toString();
    }
    return (fileId: id, localPath: path);
  }

  /// TDLib `file` id — JSON may send int or string.
  static int? _tdlibFileId(dynamic file) {
    if (file is! Map) return null;
    final id = _tdlibInt(file['id']);
    return id > 0 ? id : null;
  }

  /// File object nested under video / animation / document / sticker / …
  static Map? _tdlibNestedFile(dynamic media) {
    if (media is! Map) return null;
    for (final key in [
      'video',
      'animation',
      'document',
      'sticker',
      'photo',
      'voice',
      'file',
    ]) {
      final f = media[key];
      if (f is Map && (f['id'] != null || f['@type']?.toString() == 'file')) {
        return f;
      }
    }
    if (media['@type']?.toString() == 'file' || media['local'] is Map) {
      return media;
    }
    return null;
  }

  static String? _tdlibLocalPath(Map file) {
    final local = file['local'];
    if (local is Map && local['is_downloading_completed'] == true) {
      final path = local['path']?.toString();
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
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
    if (_tearingDown) return;
    final c = _client;
    if (videoChat is! Map) {
      if (_videoChats.remove(chatId) != null) _notifyListenersForChat(chatId);
      return;
    }
    final groupCallId = _tdlibInt(videoChat['group_call_id']);
    if (groupCallId <= 0) {
      if (_videoChats.remove(chatId) != null) _notifyListenersForChat(chatId);
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
        if (_tearingDown) return;
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

    if (_tearingDown) return;
    var username = _videoChats[chatId]?.username ?? '';
    if (username.isEmpty) {
      username = await _chatUsername(chatId);
    }
    if (_tearingDown) return;

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
    _notifyListenersForChat(chatId);
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
    if (changed) _notifyUi();
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

  List<int>? _photoMinithumbnailBytesCached(
    int chatId,
    Map<String, dynamic> chat,
  ) {
    if (_miniThumbByChatId.containsKey(chatId)) {
      return _miniThumbByChatId[chatId];
    }
    final decoded = _photoMinithumbnailBytes(chat);
    _miniThumbByChatId[chatId] = decoded;
    return decoded;
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
      final doc = content['document'];
      var name = '';
      if (doc is Map) name = doc['file_name']?.toString() ?? '';
      if (captionLine != null) return captionLine;
      return name.isNotEmpty ? '📎 $name' : '📎 Файл';
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

}
