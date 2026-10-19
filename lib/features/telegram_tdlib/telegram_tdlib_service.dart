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
import '../chat/data/hub_first_paint_snapshot.dart';
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
import 'tg_history_store.dart';
import 'tdlib_smartspeech.dart';
import 'tdlib_video_note_prep.dart';
import 'tdlib_video_stream_proxy.dart'
    if (dart.library.html) 'tdlib_video_stream_proxy_stub.dart';

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

/// User FakeTLS policy (hub «Прокси»). Geo must never write this (R18).
enum TdlibMtprotoProxyMode {
  /// Follow geo: non-RU / VPN → direct; RU → FakeTLS.
  auto,
  /// Always FakeTLS, including under VPN.
  alwaysOn,
  /// Always direct MTProto.
  alwaysOff,
}

extension TdlibMtprotoProxyModeStorage on TdlibMtprotoProxyMode {
  String get storageValue => switch (this) {
        TdlibMtprotoProxyMode.auto => 'auto',
        TdlibMtprotoProxyMode.alwaysOn => 'on',
        TdlibMtprotoProxyMode.alwaysOff => 'off',
      };

  static TdlibMtprotoProxyMode fromStorage(String? raw) {
    switch (raw) {
      case 'on':
        return TdlibMtprotoProxyMode.alwaysOn;
      case 'off':
        return TdlibMtprotoProxyMode.alwaysOff;
      case 'auto':
      default:
        return TdlibMtprotoProxyMode.auto;
    }
  }
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
  /// Active stream `downloadFile` limit (0 = whole file). Used to skip spam
  /// re-issue on the same range (SessionLog 08:43 file=18099).
  int streamLimit = -1;
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

/// One row from hub global Telegram search (`searchPublicChats` / `@username`).
class TdlibGlobalSearchHit {
  const TdlibGlobalSearchHit({
    required this.chatId,
    required this.title,
    this.userId = 0,
    this.username = '',
    this.isGroup = false,
    this.isChannel = false,
    this.photoFileId,
    this.photoLocalPath,
    this.photoMinithumbnailBytes,
  });

  final int chatId;
  final int userId;
  final String title;
  final String username;
  final bool isGroup;
  final bool isChannel;
  final int? photoFileId;
  final String? photoLocalPath;
  final List<int>? photoMinithumbnailBytes;

  String get subtitle {
    final u = username.trim();
    if (u.isNotEmpty) return '@$u';
    if (isChannel) return 'канал';
    if (isGroup) return 'группа';
    return 'Telegram';
  }
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

  String get memberCountLabel =>
      TelegramTdlibService.formatMemberCountLabel(memberCount, isChannel: isChannel) ??
      kindLabel;

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
  /// chatId → member/subscriber count from full info (AppBar subtitle).
  final Map<int, int> _memberCountByChatId = {};
  final Set<int> _memberCountFetchQueued = {};
  final List<int> _chatOrder = [];
  /// Chats on Telegram's Archive list (`chatListArchive`).
  final List<int> _archiveChatOrder = [];
  /// From [updateUnreadChatCount] for `chatListArchive`.
  int _archiveUnreadChatCount = 0;
  int _archiveTotalCount = 0;
  /// Folder tabs from [updateChatFolders] (id → basic info).
  final Map<int, TdlibChatFolderInfo> _chatFolderInfos = {};
  /// Full [chatFolder] payloads from [getChatFolder].
  final Map<int, Map<String, dynamic>> _chatFolderDetails = {};
  /// chat_folder_id → chat ids known to belong to that folder.
  final Map<int, Set<int>> _folderChatIds = {};
  int _chatFoldersEpoch = 0;
  /// Live TG rows may replace the hub snapshot once the first `loadChats`
  /// page lands (TG-style incremental). Full folders/mute finish later.
  bool _hubSurfaceReady = false;
  /// Folders + mute scopes finished — snapshot gap-fill can drop.
  bool _hubHydrateComplete = false;
  /// TG user ids (and private chat ids) matched to an FC peer — excluded from
  /// [notifiedUnreadTotal] so Chat-tab badges do not double-count FC DMs.
  final Set<int> _matchedTgUserIds = {};
  /// Local floor for inbox read progress. TDLib `getChat` / last-message
  /// updates can briefly regress `last_read_inbox_message_id` after
  /// `viewMessages`, which made the tip-heuristic revive hub badges.
  final Map<int, int> _readInboxFloor = {};
  /// After a successful local [markMessagesRead], briefly prefer RAM unread
  /// while TDLib's `unread_count` catches up. Never pin a low RAM value
  /// forever (that undercounted Mash/Осташко vs official TG).
  final Map<int, DateTime> _markReadLocalAt = {};
  /// Debounced getChat after tip moves on a closed chat (readInbox can lag).
  final Map<int, Timer> _unreadRefreshTimers = {};
  /// Hub badge floor for FakeTLS+channel desync: local TDLib unread can sit
  /// below official TG after viewMessages applied locally but readHistory
  /// never reached the server. Display max(tdlib, floor); floor is raised by
  /// repair file / new messages and lowered only on authoritative readInbox.
  final Map<int, int> _hubUnreadFloor = {};
  bool _hubUnreadFloorLoaded = false;
  /// Last tip id we optimistically +1'd unread for (newMessage / lastMessage).
  /// Prevents double-count when FakeTLS delivers both for the same post.
  final Map<int, int> _hubUnreadBumpTipId = {};
  /// Scope defaults for [isChatMuted] when `use_default_mute_for` is set.
  final Map<String, Map<String, dynamic>> _scopeNotificationSettings = {};

  int? _openChatId;
  /// UI near the tip (reverse list ~0). When false, tip arrivals must not
  /// auto viewMessages — user is reading history and needs unread FAB/line.
  bool _openChatNearTip = true;
  /// Multi-unread open: block force viewMessages (tap/stream) until the user
  /// scrolls / releases the unread gate — otherwise tap:video at the wrong
  /// separator advances last_read through the pack (Осташко 96→82).
  bool _blockUnreadForceView = false;
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
  /// Boot / mtproto-up must not race hub first paint with getChatHistory×N
  /// (SessionLog 09:12: warm-history @ +0.2s after Ready → thrash).
  DateTime? _hubWarmNotBefore;
  Timer? _hubWarmDeferTimer;
  bool _hubWarmPassScheduled = false;
  Future<void> _historyWarmChain = Future<void>.value();
  /// History warm after hub list is live — keep off the unread critical path.
  /// Keep history warm off the cold-start critical path (first ~10s hitch).
  static const _hubWarmBootGrace = Duration(seconds: 12);
  /// After openChat claim: coalesce UI notifies so first paint isn't a
  /// NOTIFY×N rebuild storm (SessionLog 08:59: FRAME build 400ms+).
  /// Шарий 20:25: 2s quiet ended mid ready-catchup → NOTIFY×13 + 11s freeze.
  DateTime? _openChatUiQuietUntil;
  Timer? _openChatQuietFlushTimer;
  int? _openChatQuietMsgCountAtArm;
  /// True from [claimOpenChat] until [openChat] returns — quiet can expire
  /// mid-await (getChat/history ~4s) and then flush rebuilt Valya tip.
  bool _openChatOpening = false;
  static const _openChatUiQuiet = Duration(seconds: 4);
  /// After quiet ends, keep a longer coalesce so media/history tails do not
  /// flush every 48ms (SessionLog 20:25:44–46).
  DateTime? _openChatPostQuietUntil;
  static const _openChatPostQuiet = Duration(seconds: 3);
  /// After Ready: brief coalesce while TDLib dumps the first chat burst.
  /// Keep short — long quiet delayed live unread (was 6s; TG ~36ms debounce).
  DateTime? _hubBootUiQuietUntil;
  Timer? _hubBootFlushTimer;
  static const _hubBootUiQuiet = Duration(milliseconds: 500);
  /// Drain TDLib updates with event-loop yields during boot quiet so a
  /// burst of updateNewChat cannot ANR the isolate (SessionLog 09:22).
  final List<Map<String, dynamic>> _bootUpdateQueue = [];
  bool _bootUpdateDraining = false;
  int _bootUpdateHandled = 0;
  /// Quiet-end / drain-end flush must pierce the boot coalesce in notifyListeners.
  bool _flushingBootUi = false;
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
  /// Soft `m` / tiny ids that already gave up under FakeTLS Ready+0B — do not
  /// re-wire them on every viewport tick (album cell 2: 14613×N).
  final Set<int> _mediaGiveUpFileIds = {};
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
  /// R57 (SessionLog 13 Oct 08:58 / 12:00 / 13:06 / 19:08 + mtg-wifi): a
  /// non-video Ready+FakeTLS download that is still 0B is a domain-fronting
  /// socket (lives ~26s, 0 bytes) and TDLib opens another every ~3s while
  /// it stays in flight. Origin is another DF socket. Cancel on the next
  /// watchdog tick instead of the 12s thumb budget.
  static const _stallZeroBytesDfProxyReady = Duration(seconds: 4);
  /// Non-stream photo/document under Ready+FakeTLS: 0B stall budget (idle,
  /// not wall-clock). Between hub 4s and old 40s generic Ready path.
  static const _stallZeroBytesPhotoProxyReady = Duration(seconds: 8);
  static const _stallSmallFileBytes = 64 * 1024;
  static const _stallProgressIdle = Duration(seconds: 45);
  static const _stallProgressIdleProxy = Duration(seconds: 20);
  /// R22: mid-file idle under Ready+FakeTLS held the slot 45s at 14.5KB —
  /// align with Connecting-proxy idle (~15–20s). Video body keeps this.
  static const _stallProgressIdleProxyReady = Duration(seconds: 15);
  /// Photo / non-stream full file: mid-file idle (bytes then stuck).
  static const _stallProgressIdlePhotoProxyReady = Duration(seconds: 12);
  /// Progressive `stream:video:` range: no progress on current offset.
  static const _stallZeroBytesStreamRange = Duration(seconds: 8);
  static const _stallProgressIdleStreamRange = Duration(seconds: 8);
  /// Auto-download / background warm window (same as FamilyChat media policy).
  static const mediaAutoAge = ChatMediaDisplayPolicy.deferredFullMediaAge;
  /// Hub warm disabled in exclusive-focus mode.
  static const warmHubChatLimit = 0;
  static const warmHubMediaPerChat = 0;
  /// Open-chat: focused media first; then neighbors (after focus claims slot).
  /// Direct MTProto: ±4. FakeTLS: ±1 only — enough to hide the next-bubble
  /// loader on media channels without the old radius-4 DF storm (slotLimit=1).
  static const viewportMediaRadius = 4;
  static const viewportMediaRadiusProxy = 1;
  /// Ordered exclusive focus queue (first = actively downloading).
  List<int> _focusDownloadOrder = const [];
  int? _focusMessageId;
  /// Hold exclusive focus while a download is in flight so scroll jitter
  /// cannot cancel→restart 0B downloads forever.
  DateTime? _focusHoldUntil;
  /// Throttle focus_miss getMessage / slog (layout ticks ~1.4s forever).
  final Map<int, DateTime> _focusMissAt = {};

  /// Drop exclusive-focus claim (hold + order). Does **not** touch proxy /
  /// pause-resume (R40/R41). Used on chat switch and stall give-up so a
  /// zombie focus cannot wedge FakeTLS 1/1 (r41_check: held channel msg
  /// while openChat=DM; tap:photo 0B behind focus_hold_block).
  void _clearFocusMediaClaim({required String why}) {
    final had = _focusHoldUntil != null ||
        _focusMessageId != null ||
        _focusDownloadOrder.isNotEmpty;
    _focusHoldUntil = null;
    _focusMessageId = null;
    _focusDownloadOrder = const [];
    _pendingNeighborMessageIds = const [];
    if (had) {
      _mediaLog('focus-hold clear why=$why');
    }
  }

  /// True while exclusive focus still has wire/queue work (not merely a
  /// stale order of already-cached file ids).
  bool _focusMediaBusy() {
    if (_focusDownloadOrder.any(
      (id) =>
          !_hasCachedPath(id) &&
          (_downloadInFlight.contains(id) || _downloadQueued.contains(id)),
    )) {
      return true;
    }
    bool isFocusReason(String r) =>
        r.startsWith('focus:') ||
        r.startsWith('focus-upgrade:') ||
        r.startsWith('focus-tail:');
    if (_downloadInFlight.isNotEmpty) {
      for (final id in _downloadInFlight) {
        final reason = _downloadTrace[id]?.reason ?? '';
        if (isFocusReason(reason)) return true;
      }
    }
    return _downloadQueue.any((j) => isFocusReason(j.reason));
  }

  /// Album siblings around [idx] (or a single-message list when not an album).
  List<TdlibMessage> _albumMembersAround(List<TdlibMessage> list, int idx) {
    if (idx < 0 || idx >= list.length) return const [];
    final focus = list[idx];
    final members = <TdlibMessage>[focus];
    final albumId = focus.mediaAlbumId;
    if (albumId == null) return members;
    for (var i = idx - 1; i >= 0; i--) {
      if (list[i].mediaAlbumId != albumId) break;
      members.insert(0, list[i]);
    }
    for (var i = idx + 1; i < list.length; i++) {
      if (list[i].mediaAlbumId != albumId) break;
      members.add(list[i]);
    }
    return members;
  }

  bool _sameMediaAlbum(int chatId, int messageIdA, int messageIdB) {
    if (messageIdA == messageIdB) return true;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return false;
    TdlibMessage? a;
    TdlibMessage? b;
    for (final m in list) {
      if (m.id == messageIdA) a = m;
      if (m.id == messageIdB) b = m;
      if (a != null && b != null) break;
    }
    final albumA = a?.mediaAlbumId;
    final albumB = b?.mediaAlbumId;
    return albumA != null && albumA == albumB;
  }

  /// True when [m] still needs preview wire work (uncached file or soft alias
  /// on a typed `x`/`y`/`w` primary that is not sharp yet).
  bool _memberHasUncachedPreviewWork(TdlibMessage m) {
    if (!mediaNeedsViewportFocus(m)) return false;
    final primary = m.photoRemoteId;
    if (primary != null &&
        primary > 0 &&
        !_hasUsablePhotoCached(primary, minBytes: 3 * 1024) &&
        !_mediaGiveUpFileIds.contains(primary) &&
        (m.photoSizeType == 'x' ||
            m.photoSizeType == 'y' ||
            m.photoSizeType == 'w')) {
      return true;
    }
    for (final id in previewFileIdsFor(m)) {
      if (_mediaGiveUpFileIds.contains(id)) continue;
      if (!_hasCachedPath(id)) return true;
    }
    if (m.isPhoto ||
        (m.photoThumbBytes != null && m.photoThumbBytes!.isNotEmpty)) {
      if ((m.photoRemoteId == null || m.photoRemoteId! <= 0) &&
          m.photoFallbackFileIds.isEmpty) {
        return true;
      }
    }
    if (m.isVideo || m.isAnimation || m.isVideoNote) {
      final vt = m.isVideoNote ? m.videoNoteThumbFileId : m.videoThumbFileId;
      if (vt == null || vt <= 0) return true;
    }
    return false;
  }
  /// 0..1 while downloading; removed on complete/cancel.
  final Map<int, double> _fileDownloadProgress = {};
  final Map<int, _TdlibDownloadTrace> _downloadTrace = {};
  /// Official-style progressive video: loopback HTTP + TDLib range downloads.
  TdlibVideoStreamProxy? _videoStreamProxy;
  final Set<int> _streamingVideoIds = {};
  final Map<int, String> _streamUrlByFileId = {};
  /// Survive soft-restart / ExoPlayer race: revive proxy session from this.
  final Map<int, TdlibVideoStreamSession> _streamSessionMeta = {};
  final Map<int, String> _partialFilePath = {};
  final Map<int, List<Completer<void>>> _streamRangeWaiters = {};
  /// Serialize range `downloadFile` per file (TDLib: one active download/file).
  final Map<int, Future<void>> _streamRangeGates = {};
  /// Moov-at-end Range failed under FakeTLS — keep prefix/full fill and do not
  /// let ExoPlayer end-Range cancel a live offset=0 download again.
  final Set<int> _streamFullFallbackIds = {};
  /// SaluteSpeech (@smartspeech_sber_bot) — voice → text via forward.
  int? _smartSpeechBotChatId;
  Completer<String>? _smartSpeechReplyCompleter;
  Future<void>? _smartSpeechJob;
  /// Ignore bot messages at/before this id (pre-forward history).
  int _smartSpeechAfterMsgId = 0;
  bool _smartSpeechBotChatOpened = false;
  final Map<String, String> _voiceTranscripts = {};
  final Set<String> _voiceTranscriptPending = {};
  bool _voiceTranscriptsLoaded = false;
  /// TDLib `photoSize.progressive_sizes` — JPEG prefix thresholds (bytes).
  final Map<int, List<int>> _photoProgressiveSizes = {};
  /// Last progressive prefix byte count painted for [fileId].
  final Map<int, int> _photoProgressivePaintedBytes = {};
  /// Snapshot path of a progressive JPEG prefix (not the final file).
  final Map<int, String> _progressivePaintPath = {};
  /// Bubble primary (`x`) → larger fullscreen size (`y`/`w`) when present.
  final Map<int, int> _photoFullscreenUpgrade = {};
  final Set<int> _progressivePaintInFlight = {};
  /// remote.unique_id → our tracked file id (TDLib may emit updateFile under a new id).
  final Map<String, int> _remoteUniqueToFileId = {};
  /// Survives soft-restart: remote.unique_id → on-disk path (file_ids remap).
  final Map<String, String> _durablePathByRemote = {};
  /// Stale pre-restart file_id → live id after [file-id-remap] (tap may still
  /// carry the old attachment id until the bubble rebuilds).
  final Map<int, int> _staleFileIdRemap = {};
  Timer? _downloadWatchdog;
  /// SessionLog `tg.proxy` / `plane` heartbeat (proxy-parity research).
  Timer? _proxyPlaneTimer;
  /// Last successful [pingProxy] RTT in ms; null if never / last failed.
  int? _lastPongMs;
  DateTime? _lastPongAt;
  /// Last failed health [pingProxy] on the enabled hop (Pong timeout etc.).
  /// SessionLog 11:34–11:35: Ready+0B with fresh Pong fail = zombie FakeTLS
  /// plane — cancel+requeue tore Ready→Connecting; soft-restart heals (R51).
  DateTime? _lastProxyPingFailAt;
  DateTime? _lastStallZombieSoftRestartAt;
  /// Last net media complete — live bytes beat Pong-fail as plane health (R51b).
  DateTime? _lastNetMediaDoneAt;
  static const _recentNetMediaOk = Duration(seconds: 60);
  /// Survive soft-restart tearDown so focus/tap requeues after Ready (R51).
  final List<_TdlibDownloadJob> _pendingMediaAfterSoftRestart = [];
  static const _proxyPingFailFresh = Duration(seconds: 90);
  static const _stallZombieSoftRestartCooldown = Duration(seconds: 45);
  /// R54/R54b (SessionLog 19:45–19:57): FakeTLS + !Ready → no wire downloads
  /// (boot Connecting, soft-restart, quiet). Focus used to burn CDN→origin
  /// and give-up before mtproto-up. Disk hits still OK. Not an auth Ready-gate
  /// (td#1176) — only FakeTLS handshake hold.
  bool get _fakeTlsMediaWireHold =>
      _useMtprotoProxy &&
      (!_tdlibReadyForMedia ||
          (_softRestartFileGapUntil != null &&
              DateTime.now().isBefore(_softRestartFileGapUntil!)));

  /// R57: hold new file sockets so domain-fronting connections (~26s, 0B)
  /// can die before the next downloadFile. At most two holds until a net
  /// done resets the counter.
  void _armDfStormHold(int fileId, String why) {
    final until = _softRestartFileGapUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    if (_dfStormHolds >= 2) return;
    _dfStormHolds++;
    _softRestartFileGapUntil =
        DateTime.now().add(const Duration(seconds: 22));
    _softRestartFileGapTimer?.cancel();
    _softRestartFileGapTimer = Timer(const Duration(seconds: 22), () {
      _softRestartFileGapTimer = null;
      _softRestartFileGapUntil = null;
      _mediaLog('media-wire-hold clear (df-storm)');
      if (_tearingDown || _client == null) return;
      _pumpDownloadQueue();
    });
    _mediaLog(
      'media-wire-hold arm 22s why=$why file=$fileId holds=$_dfStormHolds',
    );
  }

  /// R71 (SessionLog 20:21 + mtg-wifi): after soft-restart, rapid next
  /// `downloadFile` often opens `proxy.domain-fronting` while siblings just
  /// RELAY'd (dc=203). Short cool between net completes — not a plane kick.
  static const _postRestartMediaWindow = Duration(seconds: 25);
  static const _postRestartMediaCool = Duration(seconds: 3);

  bool get _inPostRestartMediaWindow {
    if (!_useMtprotoProxy) return false;
    final at = _lastSoftRestartAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _postRestartMediaWindow;
  }

  /// True when album tails should wait for one post-restart RELAY `done`
  /// before joining the exclusive FakeTLS queue.
  bool get _deferFocusTailsAfterRestart {
    if (!_inPostRestartMediaWindow) return false;
    final restart = _lastSoftRestartAt!;
    final done = _lastNetMediaDoneAt;
    return done == null || !done.isAfter(restart);
  }

  void _armPostRestartMediaCool({required String why}) {
    if (!_inPostRestartMediaWindow) return;
    final coolUntil = DateTime.now().add(_postRestartMediaCool);
    final until = _softRestartFileGapUntil;
    // Never shorten an active DF 22s quiet.
    if (until != null && until.isAfter(coolUntil)) return;
    _softRestartFileGapUntil = coolUntil;
    _softRestartFileGapTimer?.cancel();
    _softRestartFileGapTimer = Timer(_postRestartMediaCool, () {
      _softRestartFileGapTimer = null;
      _softRestartFileGapUntil = null;
      _mediaLog('media-wire-hold clear (post-restart-cool)');
      if (_tearingDown || _client == null) return;
      _pumpDownloadQueue();
    });
    _mediaLog(
      'media-wire-hold arm ${_postRestartMediaCool.inSeconds}s '
      'why=post-restart-cool:$why',
    );
  }

  /// R71: user tap must pierce Ready+DF / post-restart cool holds so
  /// `tap:photo` is not stuck behind `disk-miss-requeue` for 22s
  /// (SessionLog 20:22:27). Keep R54 !Ready wire hold.
  void _releaseDfWireHoldForUserTap(String why) {
    if (!_tdlibReadyForMedia) return;
    final until = _softRestartFileGapUntil;
    if (until == null || !DateTime.now().isBefore(until)) return;
    _softRestartFileGapTimer?.cancel();
    _softRestartFileGapTimer = null;
    _softRestartFileGapUntil = null;
    _mediaLog('media-wire-hold clear (user-tap) why=$why');
  }
  /// Batches high-frequency media UI notifies (progress / completes mid-fling).
  Timer? _uiNotifyTimer;
  bool _uiNotifyPending = false;
  bool _uiScrollBusy = false;
  DateTime? _uiScrollBusyUntil;
  /// Compose/IME focus — no TTL (unlike scroll 720ms). Valya SessionLog 21:35.
  bool _uiImeBusy = false;
  /// Cached [hubChats] until the next [notifyListeners] — build() used to
  /// re-walk/sort/decode minithumbs dozens of times per frame.
  List<TdlibChatPreview>? _hubChatsCache;
  List<TdlibChatPreview>? _hubArchiveChatsCache;
  /// Debounced hub first-paint persist for lastMessage / readInbox (muted OK).
  final Set<int> _hubSnapshotPersistPending = {};
  Timer? _hubSnapshotPersistTimer;
  /// Serialize hub-snapshot batch writes (avoid overlapping read/write storms).
  Future<void> _hubSnapshotFlushJob = Future<void>.value();
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
  /// Live wire: FakeTLS on/off after mode + geo resolution.
  bool _useMtprotoProxy = true;
  bool? _useMtprotoProxyResolved;
  /// Hub «Прокси» mode — **user intent only**, persisted; default [auto].
  /// R18: geo must NOT write this (VPN leave-RU used to sticky-OFF the old
  /// debug switch and then skip all future geo rechecks).
  static const _kMtprotoProxyModePref = 'tdlib_mtproto_proxy_mode';
  /// Legacy debug AppBar bool (migrated → mode).
  static const _kDebugMtprotoProxyPref = 'tdlib_debug_mtproto_proxy';
  /// One-shot: clear sticky AppBar OFF written by pre-R18 geo-off.
  static const _kDebugMtprotoProxyR18Migrated =
      'tdlib_debug_mtproto_proxy_r18';
  TdlibMtprotoProxyMode _mtprotoProxyMode = TdlibMtprotoProxyMode.auto;
  bool _mtprotoProxyModeLoaded = false;
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
  /// R52: defer late-None so Ready↔Connecting blips do not freeze the plane.
  Timer? _lateNoneDeferTimer;
  static const _lateNoneDefer = Duration(seconds: 2);
  /// R72: deferred + soft-handshake timers must not both await None.
  bool _lateNoneApplyInFlight = false;
  /// R52: after skip-None mid soft-handshake, apply late-None when quiet ends
  /// (still bg + !Ready) — keep R40 DF freeze without aborting the dial.
  Timer? _softHandshakePauseNoneTimer;
  /// R72: soft-restart-first cooldown (rapid lock while previous tearDown).
  static const _softRestartFirstCooldown = Duration(seconds: 8);
  /// R53 (SessionLog 19:40): soft-restart → Ready@0.4s → Ready→Connecting@+5s
  /// in foreground; soft-resume flags already cleared on Ready so kick waited
  /// 35s. Settle window: early soft-restart on Ready-drop (cap 2).
  DateTime? _lastSoftRestartAt;
  /// R56: after soft-restart, a 0B CDN try is domain-fronting (mtg, no dc=203).
  /// Silence before the next downloadFile. Cold start's first file is RELAY.
  DateTime? _softRestartFileGapUntil;
  Timer? _softRestartFileGapTimer;
  /// R57: file ids that already got the post-DF CDN retry. A second 0B
  /// gives up without origin (origin restarts the domain-fronting storm).
  final Set<int> _dfStormCdnRetried = {};
  int _dfStormHolds = 0;
  DateTime? _softRestartSettleUntil;
  Timer? _softRestartSettleOkTimer;
  int _softRestartSettleCount = 0;
  static const _softRestartSettle = Duration(seconds: 15);
  static const _softRestartSettleCap = 2;
  static const _softRestartSettleArmWindow = Duration(seconds: 90);
  /// True after pause applied networkTypeNone until resume unsuspends.
  bool _appNetworkSuspended = false;
  /// R61: background Connecting with the kick timer frozen. One
  /// setNetworkType of the current bearer after 90s — the mobile→wifi
  /// reassert that ended the 74m stall (13 Oct 10:37–11:51). Not the
  /// foreground kick ladder.
  Timer? _bgStuckReassertTimer;
  int _bgStuckReassertCount = 0;
  static const _bgStuckReassertCap = 3;
  static const _bgStuckReassertWait = Duration(seconds: 90);
  /// R33/R34: short resume after our pause-suspend None — official
  /// resumeNetwork only; if still Connecting after short quiet, collapse to
  /// soft-restart early (not enableProxy + soft-nudge forever).
  /// Dig `_fc_diag/r33_check`: WiFi-only after None → 0/21 mtg RELAY.
  bool _resumeFromPauseSuspend = false;
  /// R41 (r40_check mtg): soft-pause soft-restart quiet/collapse.
  /// Ready clears quiet immediately — good plane still lands ≤5s (long unlock
  /// +4.4s / RELAY). Collapse@4s on DF soft×1 → soft× every 5s = DF thrash
  /// (+86s short unlock; SHORT_SOFT1 6 DF / 0 RELAY). One FakeTLS attempt
  /// needs the same quiet as boot (35s) when the plane is hostile.
  static const _pauseSuspendResumeQuiet = Duration(seconds: 35);
  static const _pauseSuspendCollapseWait = Duration(seconds: 35);
  /// R35: pause skipped None while Ready+FakeTLS (R34a). If TDLib then
  /// drops Ready→Connecting in background, resume must not R13@40s —
  /// reuse R34b early soft-restart (SessionLog 17:36 skip None → +3s drop).
  bool _softPausedReadyProxy = false;
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
  /// Boot / short-path soft-restart for stuck Connecting used to reset the
  /// kick ladder (`restartCount=0` every soft×) and forever restore a dead
  /// preferred hop (SessionLog 10:13–10:16: MegaFon WiFi blacks
  /// `244.213:443` while `:8443` works). Cap soft× then failover.
  int _stuckConnectingSoftRestartCount = 0;
  static const _stuckConnectingSoftRestartCap = 2;
  /// iOS only (19 Oct iPhone SessionLog): sticky hop stayed Connecting across
  /// soft×N. Cap 0 = hard-hop on first stuck-Connecting kick + softRestartAfter
  /// (R69); SessionLog 15:01 soft×1 on :8443 never Ready, hard-hop→:443 @237ms.
  /// Android keeps [_stuckConnectingSoftRestartCap] — do not tighten there.
  static const _iosStuckConnectingSoftRestartCap = 0;

  /// Sticky preferred port ≠ R67 default for this radio (wifi→443, mobile→8443).
  bool get _iosStuckWrongPortPreferred {
    if (kIsWeb || !Platform.isIOS || !_useMtprotoProxy) return false;
    final wantPort = _wantProxyPortForKind(_preferredProxyRadioKind);
    final eps = _activeProxyEndpoints;
    if (wantPort == null || eps.isEmpty) return false;
    final curPort = eps[_proxyEndpointIndex.clamp(0, eps.length - 1)].port;
    return curPort != wantPort;
  }
  /// Soft-pause stage-5 already hard-hopped once this thrash cycle.
  /// Cleared on Ready. SessionLog 16 Oct 10:00–10:24: skip-hop +
  /// socket-reopen forever on sticky `:443` (hard-hop count=0) while
  /// official TG RELAY on both ports — second stage-5 must hop, third
  /// falls back to socket-reopen.
  bool _softPauseHardHopTried = false;
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
  /// Legacy single preferred hop (`server:port`). Migrated into per-radio
  /// v2 keys — a mobile `:8443` Ready must not sticky-restore on home Wi‑Fi
  /// soft-restart (SessionLog 16 Oct 12:49: pause → soft-restart×N on
  /// `ip-8443-cf` while `net=wifi`).
  static const _preferredProxyKey = 'tdlib_mtproto_preferred_endpoint_v1';
  static const _preferredProxyKeyWifi =
      'tdlib_mtproto_preferred_endpoint_v2_wifi';
  static const _preferredProxyKeyMobile =
      'tdlib_mtproto_preferred_endpoint_v2_mobile';

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

  /// Chats on Telegram's Archive list (shown inside «Архив чатов»).
  List<TdlibChatPreview> get hubArchiveChats =>
      _hubArchiveChatsCache ??= _buildHubArchiveChats();

  bool get hasArchivedChats =>
      _archiveChatOrder.isNotEmpty || _archiveTotalCount > 0;

  /// Unread chats in Archive (for the hub Archive row badge).
  int get archiveUnreadChatCount => _archiveUnreadChatCount;

  int get archiveChatCount =>
      _archiveChatOrder.isNotEmpty ? _archiveChatOrder.length : _archiveTotalCount;

  bool isChatArchived(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return false;
    return _isInArchiveChatList(chat);
  }

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
        // SaluteSpeech bot: hidden from hub; open only via search.
        if (_smartSpeechBotChatId == id ||
            _isSmartSpeechBotUser(userId, user)) {
          continue;
        }
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
          if (isSavedMessagesChat(id)) {
            lastReadStatus = 'read';
          } else if (mid > 0 && lastOutbox > 0 && mid <= lastOutbox) {
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

  List<TdlibChatPreview> _buildHubArchiveChats() {
    final out = <TdlibChatPreview>[];
    for (final id in _archiveChatOrder) {
      final chat = _chats[id];
      if (chat == null) continue;
      if (!_isInArchiveChatList(chat)) continue;
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
        if (_myUserId != null && userId == _myUserId) continue;
        user = _users[userId];
        if (_smartSpeechBotChatId == id ||
            _isSmartSpeechBotUser(userId, user)) {
          continue;
        }
      } else if (typeName == 'chatTypeBasicGroup') {
        isGroup = true;
      } else if (typeName == 'chatTypeSupergroup') {
        isChannel = type['is_channel'] == true;
        isGroup = !isChannel;
        final sgId = (type['supergroup_id'] as num?)?.toInt();
        if (sgId != null) {
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
          if (isSavedMessagesChat(id)) {
            lastReadStatus = 'read';
          } else if (mid > 0 && lastOutbox > 0 && mid <= lastOutbox) {
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

  /// Hub may show live TG rows once this is true (first loadChats page or
  /// auth will not load chats).
  bool get hubSurfaceReady => _hubSurfaceReady;

  /// TDLib already has ordered chats in RAM (incremental paint).
  bool get hubHasLiveChats => _chatOrder.isNotEmpty;

  /// Folders + mute scopes applied — snapshot gap-fill no longer needed.
  bool get hubHydrateComplete => _hubHydrateComplete;

  void _setHubSurfaceReady(bool value) {
    if (_hubSurfaceReady == value) return;
    _hubSurfaceReady = value;
    notifyListeners();
  }

  void _setHubHydrateComplete(bool value) {
    if (_hubHydrateComplete == value) return;
    _hubHydrateComplete = value;
    if (value) {
      _notifyUi(immediate: true, force: true);
    }
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

  void _scheduleHubSnapshotRowPersist(int chatId) {
    if (kIsWeb || chatId == 0) return;
    if (isSavedMessagesChat(chatId)) return;
    _hubSnapshotPersistPending.add(chatId);
    // SQLite writes mid boot quiet stack with updateNewChat → ANR.
    // Still queue the id; flush when quiet ends / push asks.
    if (_inHubBootUiQuiet) return;
    _armHubSnapshotPersistTimer();
  }

  void _armHubSnapshotPersistTimer({Duration delay = const Duration(milliseconds: 350)}) {
    _hubSnapshotPersistTimer?.cancel();
    _hubSnapshotPersistTimer = Timer(delay, () {
      _hubSnapshotPersistTimer = null;
      _flushHubSnapshotPersistPending();
    });
  }

  /// Push / quiet-end: write queued hub rows so cold start stays fresh.
  void _flushHubSnapshotPersistSoon({required String why}) {
    if (_hubSnapshotPersistPending.isEmpty) {
      // Also persist top of live order after a push (tip may have moved).
      for (final id in _chatOrder.take(12)) {
        if (id != 0) _hubSnapshotPersistPending.add(id);
      }
    }
    if (_hubSnapshotPersistPending.isEmpty) return;
    _mediaLog(
      'hub-snapshot flush soon n=${_hubSnapshotPersistPending.length} why=$why',
    );
    _armHubSnapshotPersistTimer(delay: const Duration(milliseconds: 120));
  }

  void _flushHubSnapshotPersistPending() {
    if (_hubSnapshotPersistPending.isEmpty) return;
    if (_inHubBootUiQuiet) {
      _armHubSnapshotPersistTimer(delay: const Duration(milliseconds: 400));
      return;
    }
    // Opening a chat: do not compete with tip paint / focus media for SQLite.
    final openQuiet = _openChatUiQuietUntil;
    if (openQuiet != null && DateTime.now().isBefore(openQuiet)) {
      _armHubSnapshotPersistTimer(delay: const Duration(milliseconds: 500));
      return;
    }
    final ids = _hubSnapshotPersistPending.toList(growable: false);
    _hubSnapshotPersistPending.clear();
    _hubSnapshotFlushJob = _hubSnapshotFlushJob.then((_) async {
      await _persistHubSnapshotRowsBatch(ids);
    }).catchError((Object e) {
      debugPrint('[tdlib] hub snapshot batch persist failed: $e');
    });
  }

  /// One read/write for the whole pending set (not upsertFullRow×N).
  Future<void> _persistHubSnapshotRowsBatch(List<int> chatIds) async {
    if (kIsWeb || chatIds.isEmpty) return;
    final rows = <Map<String, dynamic>>[];
    for (final chatId in chatIds) {
      final row = hubSnapshotRowForChat(chatId);
      if (row != null) rows.add(row);
    }
    if (rows.isEmpty) return;
    final sw = Stopwatch()..start();
    try {
      await HubFirstPaintSnapshot.upsertFullRows(rows);
      _mediaLog(
        'hub-snapshot batch ok n=${rows.length} dt=${sw.elapsedMilliseconds}ms',
      );
    } catch (e) {
      debugPrint('[tdlib] hub snapshot batch persist failed: $e');
    }
  }

  /// Hub-snapshot synthetic for a TG chat (Main or Archive — same client DB).
  Map<String, dynamic>? hubSnapshotRowForChat(int chatId) {
    if (chatId <= 0 || isSavedMessagesChat(chatId)) return null;
    final preview = chatPreviewById(chatId);
    if (preview == null) return null;
    final created = preview.lastMessageDate > 0
        ? DateTime.fromMillisecondsSinceEpoch(preview.lastMessageDate * 1000)
            .toIso8601String()
        : null;
    return <String, dynamic>{
      'id': -chatId.abs(),
      'kind': 'tdlib_chat',
      'title': preview.title,
      'tdlib_chat_id': chatId,
      'tdlib_archived': isChatArchived(chatId),
      if (!preview.isGroup && !preview.isChannel && preview.userId > 0)
        'tdlib_user_id': preview.userId,
      'tdlib_photo_path': preview.photoLocalPath,
      'tdlib_photo_bytes': preview.photoMinithumbnailBytes,
      'tdlib_photo_file_id': preview.photoFileId,
      'notifications_enabled': !isChatMuted(chatId),
      'unread_count': preview.unreadCount,
      'last_message': {
        'body': preview.lastMessageText,
        if (created != null) 'created_at': created,
        if (preview.lastMessageReadStatus != null)
          'read_status': preview.lastMessageReadStatus,
        if (preview.lastMessageOutgoing) 'is_mine': true,
      },
    };
  }

  /// Persist Archive folder chrome + archived chats into hub SQLite snapshot.
  Future<void> persistArchiveHubSnapshot() async {
    if (kIsWeb || !isReady) return;
    final rows = <Map<String, dynamic>>[];
    for (final c in hubArchiveChats) {
      final row = hubSnapshotRowForChat(c.chatId);
      if (row != null) rows.add(row);
    }
    if (hasArchivedChats || rows.isNotEmpty) {
      String subtitle;
      if (rows.isNotEmpty) {
        final tip = rows.first;
        final title = tip['title']?.toString() ?? '';
        final lm = tip['last_message'];
        final body = lm is Map ? lm['body']?.toString().trim() ?? '' : '';
        subtitle = body.isNotEmpty && title.isNotEmpty
            ? '$title: $body'
            : (title.isNotEmpty ? title : 'Архив');
      } else {
        final n = archiveChatCount;
        subtitle = n > 0 ? '$n чатов' : 'Архив';
      }
      rows.add({
        'id': -900001,
        'kind': 'tdlib_archive',
        'title': 'Архив чатов',
        'notifications_enabled': true,
        'unread_count': archiveUnreadChatCount,
        'last_message': {'body': subtitle},
      });
    }
    if (rows.isEmpty) return;
    try {
      await HubFirstPaintSnapshot.upsertFullRows(rows);
    } catch (e) {
      debugPrint('[tdlib] archive hub snapshot persist failed: $e');
    }
  }

  /// Full hub-row write for cold-start snapshot (works with hub unmounted).
  Future<void> _persistHubSnapshotRow(int chatId) async {
    await _persistHubSnapshotRowsBatch([chatId]);
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
        if (isSavedMessagesChat(chatId)) {
          lastReadStatus = 'read';
        } else if (mid > 0 && lastOutbox > 0 && mid <= lastOutbox) {
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
  ///
  /// R48: FakeTLS no longer hard-skips hub avatars. Hub *is* the active
  /// screen — visible faces own the single slot (slotLimit=1, 0B≈4s). Open
  /// chat still purges hub-avatar via [_purgeNonFocusDownloads] /
  /// [_suspendBackgroundDownloads].
  void prefetchVisibleHubAvatars(
    Iterable<int> chatIds, {
    int limit = 16,
  }) {
    if (_openChatId != null) {
      _mediaLog('hub-avatar skip: openChat=$_openChatId');
      return;
    }
    // R48: no new hub wire while backgrounded (pause clears unfinished).
    if (!_appInForeground) {
      _mediaLog('hub-avatar skip: background');
      return;
    }
    // Boot-prime already painted faces — don't fight first frames for slot.
    if (_inHubBootUiQuiet) {
      return;
    }
    if (isUiScrollBusy) {
      return;
    }
    if (!_tdlibReadyForMedia) {
      _mediaLog('hub-avatar skip: conn=$_connectionState');
      return;
    }
    // SessionLog 21:11: hub-avatar queued behind zombie tap:photo (openChat
    // null) for ~50s — muddy faces never started. Hub owns the wire now.
    _purgeConversationWireForHub();

    // FakeTLS: keep the pending queue short so scroll does not pile 16×0B
    // waiters behind one poison remote (serial slot).
    final effectiveLimit = _enabledProxyId != null ? 8 : limit;

    // Cap how many hub-avatar jobs sit waiting — otherwise scroll floods the
    // queue while the in-flight CDN downloads sit at 0B.
    final hubQueued = _downloadQueue
        .where((j) => j.reason == 'hub-avatar')
        .length;
    final hubInflight = _downloadInFlight.where((id) {
      final r = _downloadTrace[id]?.reason ?? '';
      return r == 'hub-avatar';
    }).length;
    final hubBudget = effectiveLimit - hubQueued - hubInflight;
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

      // Active hub screen: not background — pause/openChat must yield the
      // FakeTLS slot immediately (bg-only suspend left poison 0B on wire).
      _queueFileDownload(
        photoId,
        priority: prioHubAvatar,
        background: false,
        chatId: chatId,
        reason: 'hub-avatar',
      );
      n++;
    }
    _mediaLog(
      'hub-avatar prefetch queued=$n cached=$alreadyCached '
      'missingId=$missingId visible=${chatIds.length} '
      'budget=$hubBudget proxy=${_enabledProxyId != null} '
      '${_downloadQueueStats()}',
    );
    if (n > 0) _pumpDownloadQueue();
  }

  /// True if chat has a non-zero order on Telegram's main list (not archive/folder-only).
  bool _isInMainChatList(Map chat) {
    return _isInChatList(chat, 'chatListMain');
  }

  /// True if chat has a non-zero order on Telegram's Archive list.
  bool _isInArchiveChatList(Map chat) {
    return _isInChatList(chat, 'chatListArchive');
  }

  bool _isInChatList(Map chat, String listTypeName) {
    final positions = chat['positions'];
    if (positions is! List || positions.isEmpty) return false;
    for (final p in positions) {
      if (p is! Map) continue;
      final list = p['list'];
      final listType = list is Map ? list['@type']?.toString() ?? '' : '';
      if (listType != listTypeName) continue;
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
      _archiveChatOrder.remove(chatId);
      return;
    }
    final inMain = _isInMainChatList(chat);
    if (inMain) {
      if (!_chatOrder.contains(chatId)) _chatOrder.add(chatId);
    } else {
      _chatOrder.remove(chatId);
    }
    final inArchive = _isInArchiveChatList(chat);
    if (inArchive) {
      if (!_archiveChatOrder.contains(chatId)) _archiveChatOrder.add(chatId);
    } else {
      _archiveChatOrder.remove(chatId);
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
        // Valya/DM open: always notifying here rebuilt the whole transcript
        // (FRAME build 200–320ms) even when canSend was already true.
        if (_canSendMessages[chatId] != true) {
          _canSendMessages[chatId] = true;
          _notifyUi();
        } else {
          _canSendMessages[chatId] = true;
        }
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
      _notifyUi();
    } else {
      _canSendMessages[chatId] = next;
    }
  }

  String? cachedFilePath(int fileId) {
    if (fileId <= 0) return null;
    final path = _filePathCache[fileId];
    if (path != null && path.isNotEmpty) return path;
    // R47b: UI may still hold a pre-soft-restart id after remap.
    final mapped = _staleFileIdRemap[fileId];
    if (mapped != null && mapped > 0) {
      final p = _filePathCache[mapped];
      if (p != null && p.isNotEmpty) return p;
    }
    return null;
  }

  /// Local path for a message photo, including stall-fallback `m` sizes.
  String? resolvedPhotoPath(TdlibMessage m) {
    final primary = m.photoRemoteId;
    // Sharp primary wins when present.
    if (primary != null) {
      final p = cachedFilePath(primary);
      if (p != null && _isSharpPhotoPath(p)) return p;
    }
    // Soft fallback paints while sharp `x`/`y`/`w` is still downloading.
    for (final id in m.photoFallbackFileIds) {
      final p = cachedFilePath(id);
      if (p != null && p.isNotEmpty) return p;
    }
    // Official progressive JPEG: paint a prefix while the full size downloads.
    if (primary != null) {
      final prog = _progressivePaintPath[primary];
      if (prog != null && prog.isNotEmpty) return prog;
    }
    if (m.photoLocalPath != null && m.photoLocalPath!.isNotEmpty) {
      return m.photoLocalPath;
    }
    if (primary != null) {
      final p = cachedFilePath(primary);
      if (p != null) return p;
      final prog = _progressivePaintPath[primary];
      if (prog != null && prog.isNotEmpty) return prog;
    }
    return null;
  }

  /// True when a progressive JPEG prefix is already on screen for [fileId].
  bool hasProgressivePhotoPaint(int fileId) {
    final p = _progressivePaintPath[fileId];
    return p != null && p.isNotEmpty;
  }

  /// Larger `y`/`w` file for fullscreen when bubble primary is a smaller size.
  int? photoFullscreenUpgradeId(int fileId) {
    if (fileId <= 0) return null;
    final up = _photoFullscreenUpgrade[fileId];
    if (up == null || up <= 0 || up == fileId) return null;
    return up;
  }

  /// Drop a stale cache entry so the next request re-queues the download.
  void invalidateCachedFile(int fileId) {
    if (fileId <= 0) return;
    _filePathCache.remove(fileId);
  }

  /// Debug-only: wipe local media for [chatId] (RAM + TDLib deleteFile +
  /// message path stamps) so bubbles re-download. Returns cleared file count.
  Future<int> debugClearChatMediaCache(int chatId) async {
    if (!kDebugMode) return 0;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return 0;

    final fileIds = <int>{};
    final stampedPaths = <String>{};
    void addId(int? id) {
      if (id != null && id > 0) fileIds.add(id);
    }

    void addPath(String? path) {
      if (path != null && path.isNotEmpty) stampedPaths.add(path);
    }

    for (final m in list) {
      addId(m.photoRemoteId);
      for (final id in m.photoFallbackFileIds) {
        addId(id);
      }
      addId(m.voiceFileId);
      addId(m.videoNoteFileId);
      addId(m.videoNoteThumbFileId);
      addId(m.videoFileId);
      addId(m.videoThumbFileId);
      addId(m.documentFileId);
      addId(m.documentThumbFileId);
      addPath(m.photoLocalPath);
      addPath(m.voiceLocalPath);
      addPath(m.videoNoteLocalPath);
      addPath(m.videoNoteThumbLocalPath);
      addPath(m.videoLocalPath);
      addPath(m.videoThumbLocalPath);
      addPath(m.documentLocalPath);
      addPath(m.documentThumbLocalPath);
    }
    if (fileIds.isEmpty && stampedPaths.isEmpty) return 0;

    // Drop unfinished work for these ids so deleteFile is not racing.
    for (final j in _downloadQueue.toList()) {
      if (!fileIds.contains(j.fileId)) continue;
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      final w = _downloadWaiters.remove(j.fileId);
      if (w != null && !w.isCompleted) w.complete(null);
    }
    for (final id in fileIds.toList()) {
      if (_downloadInFlight.contains(id)) {
        await _cancelTdlibDownload(id);
        _releaseDownloadSlot(id, failed: true);
      }
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
      final w = _downloadWaiters.remove(id);
      if (w != null && !w.isCompleted) w.complete(null);
      _mediaGiveUpFileIds.remove(id);
    }

    final pathsToEvict = <String>{...stampedPaths};
    for (final id in fileIds) {
      final cached = _filePathCache.remove(id);
      if (cached != null && cached.isNotEmpty) pathsToEvict.add(cached);
    }
    _durablePathByRemote
        .removeWhere((_, path) => pathsToEvict.contains(path));
    _remoteUniqueToFileId.removeWhere((_, id) => fileIds.contains(id));

    final c = _client;
    if (c != null) {
      for (final id in fileIds) {
        try {
          await c.sendAwait({
            '@type': 'deleteFile',
            'file_id': id,
          }, timeout: const Duration(seconds: 5));
        } catch (e) {
          debugPrint('[tdlib] debug deleteFile($id): $e');
        }
      }
    }
    for (final path in pathsToEvict) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    // Strip stamped local paths so UI cannot paint from memory stamps.
    final next = <TdlibMessage>[];
    for (final m in list) {
      next.add(
        TdlibMessage(
          id: m.id,
          chatId: m.chatId,
          senderUserId: m.senderUserId,
          isOutgoing: m.isOutgoing,
          date: m.date,
          text: m.text,
          textEntities: m.textEntities,
          photoLocalPath: null,
          photoRemoteId: m.photoRemoteId,
          photoSizeType: m.photoSizeType,
          photoWidth: m.photoWidth,
          photoHeight: m.photoHeight,
          photoFallbackFileIds: m.photoFallbackFileIds,
          photoThumbBytes: m.photoThumbBytes,
          voiceFileId: m.voiceFileId,
          voiceLocalPath: null,
          voiceDurationMs: m.voiceDurationMs,
          videoNoteFileId: m.videoNoteFileId,
          videoNoteLocalPath: null,
          videoNoteDurationMs: m.videoNoteDurationMs,
          videoNoteThumbFileId: m.videoNoteThumbFileId,
          videoNoteThumbLocalPath: null,
          videoNoteThumbBytes: m.videoNoteThumbBytes,
          videoFileId: m.videoFileId,
          videoLocalPath: null,
          videoDurationMs: m.videoDurationMs,
          videoWidth: m.videoWidth,
          videoHeight: m.videoHeight,
          videoSizeBytes: m.videoSizeBytes,
          videoThumbFileId: m.videoThumbFileId,
          videoThumbLocalPath: null,
          videoThumbBytes: m.videoThumbBytes,
          isAnimation: m.isAnimation,
          isSticker: m.isSticker,
          stickerEmoji: m.stickerEmoji,
          documentFileId: m.documentFileId,
          documentLocalPath: null,
          documentFileName: m.documentFileName,
          documentMimeType: m.documentMimeType,
          documentSizeBytes: m.documentSizeBytes,
          documentThumbFileId: m.documentThumbFileId,
          documentThumbLocalPath: null,
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
        ),
      );
    }
    _messagesByChat[chatId] = next;
    final preserved = _openTranscriptPreserve[chatId];
    if (preserved != null) {
      _openTranscriptPreserve[chatId] = List<TdlibMessage>.from(next);
    }

    _clearFocusMediaClaim(why: 'debug-clear-chat-cache');
    _mediaReadyEpoch++;
    _mediaLog(
      'debug-clear-chat-cache chat=$chatId files=${fileIds.length} '
      'paths=${pathsToEvict.length} epoch=$_mediaReadyEpoch',
    );
    _slog('tg.media', 'debug_clear_chat_cache', {
      'chatId': chatId,
      'files': fileIds.length,
      'paths': pathsToEvict.length,
    });
    notifyListeners();
    // Kick tip media so the open chat immediately re-wires without scroll.
    focusNewestPendingMedia(chatId);
    return fileIds.length;
  }

  /// Download progress 0..1, or null if idle / unknown.
  double? fileDownloadProgress(int fileId) => _fileDownloadProgress[fileId];

  /// Bytes received so far for an in-flight / traced download (0 if unknown).
  int fileDownloadedBytes(int fileId) => _downloadTrace[fileId]?.lastBytes ?? 0;

  /// Expected total size for a traced download (0 if unknown).
  int fileExpectedSize(int fileId) =>
      _downloadTrace[fileId]?.expectedSize ?? 0;

  /// Active progressive-play loopback URL for [fileId], if any.
  String? videoStreamUrl(int fileId) => _streamUrlByFileId[fileId];

  bool isFileDownloading(int fileId) =>
      _downloadInFlight.contains(fileId) ||
      _downloadQueued.contains(fileId) ||
      _fileDownloadProgress.containsKey(fileId) ||
      _streamingVideoIds.contains(fileId);

  /// File ids that paint a chat-bubble preview for [m] (photo sizes, thumbs).
  List<int> previewFileIdsFor(TdlibMessage m) {
    final out = <int>[];
    void add(int? id) {
      if (id == null || id <= 0 || out.contains(id)) return;
      out.add(id);
    }

    add(m.photoRemoteId);
    for (final id in m.photoFallbackFileIds) {
      add(id);
    }
    add(m.videoThumbFileId);
    add(m.videoNoteThumbFileId);
    add(m.videoFileId);
    add(m.documentThumbFileId);
    add(m.documentFileId);
    return out;
  }

  /// True while preview media for [m] is queued / in flight (bubble loader).
  bool isMessagePreviewLoading(TdlibMessage m) {
    final ids = previewFileIdsFor(m);
    for (final id in ids) {
      if (isFileDownloading(id)) return true;
      final waiter = _downloadWaiters[id];
      if (waiter != null && !waiter.isCompleted) return true;
    }
    if (_focusMessageId == m.id && _focusMediaBusy()) return true;
    return false;
  }

  /// Best-effort 0..1 progress across [m]'s preview file ids.
  double? messagePreviewProgress(TdlibMessage m) {
    double? best;
    for (final id in previewFileIdsFor(m)) {
      final p = _fileDownloadProgress[id];
      if (p == null) continue;
      if (best == null || p > best) best = p;
    }
    return best;
  }

  /// Conversation list sets this while the user is dragging/flinging so media
  /// progress/completes don't rebuild the whole ListView mid-ballistic.
  void setUiScrollBusy(bool busy) {
    if (busy) {
      // SessionLog 20:54: hub-avatar getFile/probe mid-scroll → Skipped 1950.
      // Drop wire only on the rising edge (every ScrollUpdate extends the TTL).
      final newlyBusy = !_uiScrollBusy;
      _uiScrollBusy = true;
      // Extend window on every scroll tick (drag + fling). Longer than the
      // ballistic settle so reaction/media notifies don't hitch the fling end.
      _uiScrollBusyUntil =
          DateTime.now().add(const Duration(milliseconds: 900));
      LinkPreviewService.instance.deferNetworkFetches = true;
      if (newlyBusy && _openChatId == null) {
        _suspendHubAvatarWireForScroll();
      }
      return;
    }
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    if (!_uiImeBusy && LinkPreviewService.instance.linkPreviewGateOpen) {
      LinkPreviewService.instance.deferNetworkFetches = false;
    }
    // Flush after settle — 100ms still raced fling-end (Valya: FRAME 90–130ms
    // right after scroll-busy cleared). Skip if IME still holds defer.
    _uiNotifyTimer?.cancel();
    if (_uiNotifyPending && !_uiImeBusy) {
      _uiNotifyTimer = Timer(const Duration(milliseconds: 280), () {
        _uiNotifyTimer = null;
        if (_deferMediaUiNotify) return;
        _flushPendingUiNotify();
      });
    }
  }

  /// Compose/IME focus — hold UI notifies until explicit clear (no 720ms TTL).
  /// SessionLog 21:35: scroll-busy expired mid-keyboard → NOTIFY×40 while typing.
  void setUiImeBusy(bool busy) {
    if (busy) {
      _uiImeBusy = true;
      LinkPreviewService.instance.deferNetworkFetches = true;
      return;
    }
    if (!_uiImeBusy) return;
    _uiImeBusy = false;
    if (!_uiScrollBusy && LinkPreviewService.instance.linkPreviewGateOpen) {
      LinkPreviewService.instance.deferNetworkFetches = false;
    }
    _uiNotifyTimer?.cancel();
    if (_uiNotifyPending && !_deferMediaUiNotify) {
      _uiNotifyTimer = Timer(const Duration(milliseconds: 280), () {
        _uiNotifyTimer = null;
        if (_deferMediaUiNotify) return;
        _flushPendingUiNotify();
      });
    }
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

  bool get _inOpenChatUiQuiet {
    if (_openChatOpening) return true;
    final until = _openChatUiQuietUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// UI may skip SQLite watch setState while open quiet holds rebuilds.
  bool get isOpenChatUiQuiet => _inOpenChatUiQuiet;

  @override
  void notifyListeners() {
    if (_tearingDown) return;
    _hubChatsCache = null;
    _hubArchiveChatsCache = null;
    // Hub boot quiet / boot-update drain: coalesce. Direct notifyListeners from
    // updateNewChat / updateChat* during _drainBootUpdateQueue bypassed
    // _notifyUi quiet and caused NOTIFY×1500 + FRAME build 140–250ms
    // (SessionLog 11:57 / 12:09). Snapshot stays on screen until one flush.
    if (!_flushingBootUi &&
        _openChatId == null &&
        (_inHubBootUiQuiet || _bootUpdateDraining)) {
      _uiNotifyPending = true;
      return;
    }
    // Open-chat quiet: same hole — _loadChatHistory / ready-catchup called
    // notifyListeners() directly and bypassed _notifyUi (Шарий 20:25).
    if (!_flushingBootUi && _openChatId != null && _inOpenChatUiQuiet) {
      _uiNotifyPending = true;
      return;
    }
    // Mid-scroll: same hole — updateUser / updateSupergroup call notifyListeners
    // directly (not _notifyUi), so scroll-busy never deferred them.
    // SessionLog 12:48–12:49: NOTIFY×180 from _onUpdate:updateUser while
    // flinging a 200-msg channel → FRAME build 95–365ms sticky scroll.
    if (!_flushingBootUi && _deferMediaUiNotify) {
      _uiNotifyPending = true;
      return;
    }
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
    if (_uiImeBusy) return true;
    if (!_uiScrollBusy) return false;
    final until = _uiScrollBusyUntil;
    if (until != null && DateTime.now().isBefore(until)) return true;
    // Auto-expire if the conversation forgot to clear after fling.
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    return false;
  }

  /// Hub / FC background sync must pause while the user scrolls or types.
  bool get isUiInteractionBusy => _deferMediaUiNotify;

  /// Coalesce high-frequency media notifies. [immediate] bypasses throttle
  /// unless the open conversation is scrolling/flinging — mid-ballistic
  /// rebuilds (reactions, path stamps) were FRAME build=160–270ms and felt
  /// like sticky scroll. Use [force] only for auth / open-chat must-paint.
  ///
  /// While MTProto is Connecting (or just after soft-restart) use a longer
  /// coalesce — SessionLog showed ~200 NOTIFY/min from `_onUpdate` storms.
  void _notifyUi({
    bool immediate = false,
    bool media = false,
    bool force = false,
  }) {
    if (_deferMediaUiNotify && !force) {
      // Defer even "immediate" reaction/media paints — SessionLog 14:52
      // showed _applyInteractionInfoReactions bypassing scroll-busy.
      _uiNotifyPending = true;
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = Timer(const Duration(milliseconds: 180), () {
        _uiNotifyTimer = null;
        if (_deferMediaUiNotify) {
          _notifyUi(media: media);
          return;
        }
        _flushPendingUiNotify();
      });
      return;
    }
    final now = DateTime.now();
    final inHubBootQuiet = _openChatId == null &&
        (_inHubBootUiQuiet || _bootUpdateDraining);
    // Hub boot: hold all rebuilds (incl. immediate) until quiet/drain ends.
    // force=true still paints (auth / quiet-end flush).
    if (inHubBootQuiet && !force) {
      _uiNotifyPending = true;
      return;
    }
    // Open-chat quiet / in-flight openChat: hold rebuilds — including immediate
    // (refreshChatList force-immediate rebuilt Valya tip FRAME ~266ms).
    // Only force=true paints during quiet (auth / must-paint).
    if (_inOpenChatUiQuiet && !force) {
      _uiNotifyPending = true;
      return;
    }
    if (immediate) {
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = null;
      _uiNotifyPending = false;
      notifyListeners();
      return;
    }
    // Hub boot already handled above; keep snapshot path for non-immediate.
    final Duration coalesce;
    if (!_tdlibReadyForMedia) {
      coalesce = const Duration(milliseconds: 200);
    } else if (_openChatPostQuietUntil != null &&
        DateTime.now().isBefore(_openChatPostQuietUntil!)) {
      coalesce = const Duration(milliseconds: 220);
    } else {
      coalesce = const Duration(milliseconds: 48);
    }
    _uiNotifyPending = true;
    _uiNotifyTimer ??= Timer(coalesce, () {
      _uiNotifyTimer = null;
      _flushPendingUiNotify();
    });
  }

  void _armOpenChatUiQuiet({String why = 'claim'}) {
    _openChatUiQuietUntil = DateTime.now().add(_openChatUiQuiet);
    _openChatPostQuietUntil = null;
    // Cancel in-flight coalesce so it cannot flush mid-quiet via
    // `_flushingBootUi` pierce (was the quiet↔storm loop).
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    final id = _openChatId;
    _openChatQuietMsgCountAtArm =
        id == null ? null : (_messagesByChat[id]?.length ?? 0);
    _openChatQuietFlushTimer?.cancel();
    _openChatQuietFlushTimer = Timer(_openChatUiQuiet, () {
      _openChatQuietFlushTimer = null;
      _openChatUiQuietUntil = null;
      _openChatPostQuietUntil =
          DateTime.now().add(_openChatPostQuiet);
      if (!_uiNotifyPending) return;
      // Tip already on screen at arm and count unchanged — drop no-op rebuild
      // (Valya: quiet-end FRAME ~200ms with identical 50 rows).
      final openId = _openChatId;
      final atArm = _openChatQuietMsgCountAtArm;
      final nowCount =
          openId == null ? 0 : (_messagesByChat[openId]?.length ?? 0);
      if (atArm != null && atArm >= 16 && nowCount == atArm) {
        _uiNotifyPending = false;
        _mediaLog('open-chat-ui-quiet end drop-noop why=$why');
        return;
      }
      _mediaLog('open-chat-ui-quiet end flush why=$why');
      _flushPendingUiNotify();
    });
    _mediaLog(
      'open-chat-ui-quiet arm ${_fmtDur(_openChatUiQuiet)} why=$why',
    );
  }

  void _armHubBootUiQuiet({
    required String why,
    Duration? duration,
  }) {
    // Don't keep extending — first arm wins so quiet actually ends.
    if (_inHubBootUiQuiet) return;
    final quiet = duration ?? _hubBootUiQuiet;
    _hubBootUiQuietUntil = DateTime.now().add(quiet);
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    _hubBootFlushTimer?.cancel();
    _hubBootFlushTimer = Timer(quiet, () {
      _hubBootFlushTimer = null;
      _hubBootUiQuietUntil = null;
      _mediaLog('hub-boot-ui-quiet end flush');
      // Snapshot rows queued during quiet (push / updateChat*) — write now.
      _flushHubSnapshotPersistSoon(why: 'hub-boot-ui-quiet-end');
      // If boot drain is still chewing the queue, leave pending — drain-end
      // flushes once. Painting mid-drain just restarts the NOTIFY storm.
      if (_bootUpdateDraining) {
        _uiNotifyPending = true;
        return;
      }
      if (_uiNotifyPending) {
        _flushPendingUiNotify(pierceHubBootQuiet: true);
      } else {
        _flushingBootUi = true;
        try {
          _notifyUi(immediate: true, force: true);
        } finally {
          _flushingBootUi = false;
        }
      }
    });
    _mediaLog(
      'hub-boot-ui-quiet ${_fmtDur(quiet)} why=$why',
    );
  }

  bool get _inHubBootUiQuiet =>
      _hubBootUiQuietUntil != null &&
      DateTime.now().isBefore(_hubBootUiQuietUntil!);

  void _onUpdateMaybeQueued(Map<String, dynamic> update) {
    if (_inHubBootUiQuiet) {
      _bootUpdateQueue.add(update);
      unawaited(_drainBootUpdateQueue());
      return;
    }
    // Flush any leftovers once quiet ends.
    if (_bootUpdateQueue.isNotEmpty) {
      _bootUpdateQueue.add(update);
      unawaited(_drainBootUpdateQueue());
      return;
    }
    _onUpdate(update);
  }

  Future<void> _drainBootUpdateQueue() async {
    if (_bootUpdateDraining) return;
    _bootUpdateDraining = true;
    try {
      while (_bootUpdateQueue.isNotEmpty) {
        final u = _bootUpdateQueue.removeAt(0);
        _onUpdate(u);
        _bootUpdateHandled++;
        // Yield every few updates so frames / timers can run.
        if (_bootUpdateHandled % 6 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      _bootUpdateDraining = false;
      if (_bootUpdateQueue.isNotEmpty) {
        unawaited(_drainBootUpdateQueue());
      } else if (_uiNotifyPending && !_inHubBootUiQuiet && _openChatId == null) {
        // Quiet already ended while drain was still running — one hub flush.
        _flushPendingUiNotify();
      }
    }
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

  void _flushPendingUiNotify({bool pierceHubBootQuiet = false}) {
    if (!_uiNotifyPending) return;
    // Coalesce timers used `_flushingBootUi=true`, which pierced open-quiet
    // and scroll-busy — quiet was a no-op and NOTIFY storms returned
    // (Шарий 20:44 NOTIFY×40 during ready-catchup quiet; hub Skipped 760+).
    if (_inOpenChatUiQuiet || _deferMediaUiNotify) {
      _uiNotifyTimer?.cancel();
      _uiNotifyTimer = Timer(const Duration(milliseconds: 220), () {
        _uiNotifyTimer = null;
        _flushPendingUiNotify();
      });
      return;
    }
    if (!pierceHubBootQuiet &&
        _openChatId == null &&
        (_inHubBootUiQuiet || _bootUpdateDraining)) {
      return;
    }
    _uiNotifyPending = false;
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    _flushingBootUi = true;
    try {
      notifyListeners();
    } finally {
      _flushingBootUi = false;
    }
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

  /// True for hub / peer avatars that must yield the FakeTLS slot to chat media.
  /// [group-member] avatars (group info sheet) are intentionally excluded.
  bool _isPurgableAvatarReason(String reason) {
    if (reason == 'group-member' ||
        reason.startsWith('stall-retry:group-member') ||
        reason.startsWith('stall-lastchance:group-member')) {
      return false;
    }
    return reason == 'peer-avatar' ||
        reason == 'avatar' ||
        reason == 'hub-avatar' ||
        reason.startsWith('stall-retry:peer-avatar') ||
        reason.startsWith('stall-retry:avatar') ||
        reason.startsWith('stall-retry:hub-avatar') ||
        reason.contains('peer-avatar') ||
        reason.contains('hub-avatar') ||
        reason == 'member-avatar' || // legacy name; treat as purgable
        (reason.contains('avatar') && !reason.contains('group-member'));
  }

  /// Hub is the active screen — drop leftover chat media (tap/focus/ensure)
  /// that still holds FakeTLS slotLimit=1 after closeChat.
  void _purgeConversationWireForHub() {
    if (_openChatId != null) return;
    bool keepHub(String reason) =>
        reason == 'hub-avatar' ||
        reason.startsWith('stall-retry:hub-avatar') ||
        reason.contains(':hub-avatar');
    final dropQueued = _downloadQueue
        .where((j) => !keepHub(j.reason))
        .toList(growable: false);
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }
    var cancelled = 0;
    for (final id in _downloadInFlight.toList()) {
      final reason = _downloadTrace[id]?.reason ?? '';
      if (keepHub(reason)) continue;
      _downloadInFlight.remove(id);
      _downloadBackgroundIds.remove(id);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
      unawaited(_cancelTdlibDownload(id));
      cancelled++;
    }
    if (dropQueued.isNotEmpty || cancelled > 0) {
      _mediaLog(
        'hub-wire purge dropQ=${dropQueued.length} '
        'cancelInflight=$cancelled ${_downloadQueueStats()}',
      );
    }
  }

  /// Hub scroll rising-edge: cancel hub-avatar wire so getFile/downloadFile
  /// cannot stall the UI isolate mid-fling (SessionLog 20:54 Skipped 1950).
  void _suspendHubAvatarWireForScroll() {
    final dropQueued = _downloadQueue
        .where((j) => j.reason == 'hub-avatar')
        .toList(growable: false);
    for (final j in dropQueued) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
    }
    var cancelled = 0;
    for (final id in _downloadInFlight.toList()) {
      final reason = _downloadTrace[id]?.reason ?? '';
      if (reason != 'hub-avatar') continue;
      _downloadInFlight.remove(id);
      _downloadBackgroundIds.remove(id);
      _downloadActive = (_downloadActive - 1).clamp(0, 100);
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
      unawaited(_cancelTdlibDownload(id));
      cancelled++;
    }
    if (dropQueued.isNotEmpty || cancelled > 0) {
      _mediaLog(
        'hub-avatar scroll-suspend dropQ=${dropQueued.length} '
        'cancelInflight=$cancelled ${_downloadQueueStats()}',
      );
    }
  }

  /// Drop queued avatars. With FakeTLS, soft-release leaves TDLib still
  /// pulling the avatar on the wire and starves the focus media slot — cancel.
  Future<void> _purgeAvatarDownloads() async {
    final dropQueued = _downloadQueue
        .where((j) => _isPurgableAvatarReason(j.reason))
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
      if (!_isPurgableAvatarReason(reason)) continue;
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
    if (cancelled > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  void _queueAvatarDownload(int fileId, {int? chatId}) {
    if (fileId <= 0) return;
    // Don't compete with exclusive focus downloads inside an open chat.
    if (_openChatId != null) return;
    // R48: hub is the active screen — allow FakeTLS wire (slot=1, short 0B).
    // Open chat still purges these before channel media starts.
    if (_filePathCache.containsKey(fileId)) return;
    if (_downloadInFlight.contains(fileId) || _downloadQueued.contains(fileId)) {
      return;
    }
    _queueFileDownload(
      fileId,
      priority: prioHubAvatar,
      background: false,
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
      final isStreamRange = t.reason.startsWith('stream:video:');
      final isFocus = t.reason.startsWith('focus') ||
          t.reason.contains(':focus') ||
          t.reason.startsWith('stall-fallback:') ||
          t.reason.startsWith('stall-retry:') ||
          t.reason.startsWith('stall-lastchance:') ||
          t.reason.startsWith('tap:');
      // Full-file video only — progressive ranges use stream budgets below.
      final isVideo = !isStreamRange &&
          (t.reason.contains('video:') ||
              t.reason.startsWith('auto:video:') ||
              t.reason.startsWith('tap:video:'));
      // R70: voice must not share the thumb DF 4s / give-up-small path.
      final isVoice = t.reason.contains('voice:');
      final isHubAvatar = t.reason == 'hub-avatar';
      final isBareEnsure = t.reason == 'ensure' ||
          t.reason == 'peer-avatar' ||
          t.reason == 'avatar' ||
          t.reason.startsWith('ensure:');
      final proxyOn = _useMtprotoProxy && _enabledProxyId != null;
      final mediaReady = _tdlibReadyForMedia;
      final isSmallFile = t.expectedSize > 0 &&
          t.expectedSize <= _stallSmallFileBytes &&
          !isVideo &&
          !isVoice &&
          !isStreamRange;
      // R42 / R42b: tap:photo Ready+0B used focus 35s budget (wedged 1/1).
      // R57: non-video FakeTLS Ready 0B is domain-fronting (~26s). Cancel at
      // 4s (video keeps R19 35s) so TDLib stops opening a new DF socket
      // every ~3s. Larger photos share the short 0B photo budget (8s).
      final isFocusPhoto = !isVideo && !isStreamRange && isFocus;
      final isPhotoLike =
          !isVideo && !isVoice && !isStreamRange && !isHubAvatar && !isBareEnsure;
      final zeroLimit = isStreamRange
          ? _stallZeroBytesStreamRange
          : (isHubAvatar || isBareEnsure)
              ? _stallZeroBytesHubAvatar
              : (proxyOn && mediaReady && (isSmallFile || isFocusPhoto))
                  ? _stallZeroBytesDfProxyReady
                  : (proxyOn && mediaReady && isPhotoLike)
                      ? _stallZeroBytesPhotoProxyReady
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
                              : (isFocus
                                  ? _stallZeroBytesFocus
                                  : _stallZeroBytes));
      final progressLimit = isStreamRange
          ? _stallProgressIdleStreamRange
          : proxyOn
              ? (mediaReady
                  ? (isPhotoLike || isHubAvatar
                      ? _stallProgressIdlePhotoProxyReady
                      : _stallProgressIdleProxyReady)
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
        // R48: hub-avatar under Ready must use [_recoverStalledDownload]
        // (alt size / delayed retry) — drop-zombie left blurry tiles forever.
        // R54: FakeTLS !Ready — free slot + requeue only (no origin ladder).
        // Stream ranges: cancel current offset + pulse waiters (not photo ladder).
        if (isStreamRange) {
          unawaited(_recoverStalledStreamRange(id));
          continue;
        }
        final proxyConnecting = proxyOn && !mediaReady;
        if (!_canStartNetworkDownload || isBareEnsure || proxyConnecting) {
          unawaited(
            _dropInFlightWhileNotReady(
              id,
              requeue: !isBareEnsure &&
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

  /// Progressive range idle: cancel this offset only and wake [ensureRange]
  /// waiters so the proxy loop can re-issue (not photo CDN→origin ladder).
  Future<void> _recoverStalledStreamRange(int fileId) async {
    if (!_downloadInFlight.contains(fileId) &&
        !_streamingVideoIds.contains(fileId)) {
      return;
    }
    final t = _downloadTrace[fileId];
    final offset = t?.offset ?? 0;
    final got = t?.lastBytes ?? 0;
    final expected = t?.expectedSize ?? fileExpectedSize(fileId);
    final already = t?.recoverAttempted == true;
    final moovTail = _isStreamMoovAtEndOffset(offset, expected);
    _mediaLog(
      'stall-stream-range file=$fileId offset=$offset '
      'got=${_fmtBytes(got)} retry=${!already}'
      '${moovTail ? ' moov-tail' : ''}',
    );
    _slog('tg.media', 'stall_stream_range', {
      'fileId': fileId,
      'offset': offset,
      'downloaded': got,
      'retry': !already,
      'moovTail': moovTail,
    });
    if (t != null) {
      t.recoverAttempted = true;
      t.downloadAcked = false;
      // Reset idle clock so watchdog does not cancel in a tight loop.
      t.lastProgressAt = DateTime.now();
      t.lastStartAt = DateTime.now();
    }
    await _cancelTdlibDownload(fileId);
    // Keep inflight ownership for the stream session; ensureRange re-downloads.
    _pulseStreamRangeWaiters(fileId);
    if (already) {
      // Second idle — never leave a half-filled video wedged (SessionLog
      // 14:18 file=14838 stuck 17.9/46.7 after moov-at-end + stream-end).
      // Always resume full offset=0 fill; defer further end-Range probes.
      _mediaLog(
        'stall-stream-range resume-full file=$fileId '
        'offset=$offset got=${_fmtBytes(got)}'
        '${moovTail ? ' moov-tail' : ''}',
      );
      _streamFullFallbackIds.add(fileId);
      if (t != null) {
        t.recoverAttempted = false;
        t.offset = 0;
        t.streamLimit = 0;
      }
      unawaited(_continueVideoFullDownload(fileId, why: 'stall-stream-range'));
      _pulseStreamRangeWaiters(fileId);
    }
  }

  /// True when [offset] is in the trailing window ExoPlayer uses for moov-at-end.
  bool _isStreamMoovAtEndOffset(int offset, int expectedSize) {
    if (offset <= 0 || expectedSize <= 0) return false;
    // Within last 2MB, or past 90% — classic moov-at-end probe.
    if (offset >= expectedSize - 2 * 1024 * 1024) return true;
    return offset * 10 >= expectedSize * 9;
  }

  /// Re-arm offset=0 after a moov-at-end Range so FakeTLS slot=1 keeps filling.
  Future<void> _kickStreamPrefixDownload(
    int fileId, {
    bool fullFile = false,
  }) async {
    if (fileId <= 0) return;
    final t = _downloadTrace[fileId];
    final got = t?.lastBytes ?? 0;
    // Already have more than a warm window — only full fill makes sense
    // (SessionLog 14:18 spam warm=1MB while stuck at 17.9MB).
    final forceFull = fullFile ||
        got >= 2 * 1024 * 1024 ||
        _streamFullFallbackIds.contains(fileId);
    if (!_streamingVideoIds.contains(fileId)) {
      // Stream UI closed — keep filling so the gallery can open the file.
      unawaited(
        _continueVideoFullDownload(fileId, why: 'prefix-kick-no-stream'),
      );
      return;
    }
    final expected = fileExpectedSize(fileId);
    final warm = forceFull || expected <= 0
        ? 0
        : (expected < 1024 * 1024 ? expected : 1024 * 1024);
    _mediaLog(
      'stream-prefix-kick file=$fileId '
      '${forceFull ? 'full' : 'warm=${_fmtBytes(warm)}'} '
      'got=${_fmtBytes(got)} '
      'fallback=${_streamFullFallbackIds.contains(fileId)}',
    );
    await _startStreamRangeDownload(
      fileId: fileId,
      offset: 0,
      limit: warm,
      force: true,
    );
  }

  /// After stream dies / moov-at-end fails: finish the file with offset=0 limit=0.
  Future<void> _continueVideoFullDownload(
    int fileId, {
    required String why,
  }) async {
    if (fileId <= 0 || _tearingDown) return;
    final expected = fileExpectedSize(fileId);
    final t = _downloadTrace[fileId];
    final got = t?.lastBytes ?? 0;
    if (expected > 0 && got >= expected) return;
    if (await _probeLocalFile(fileId)) return;
    _streamFullFallbackIds.add(fileId);
    final chatId = t?.chatId ?? _openChatId;
    _mediaLog(
      'stream-full-continue file=$fileId why=$why '
      'got=${_fmtBytes(got)}/${_fmtBytes(expected)}',
    );
    // Prefer the stream download path (keeps priority) while session alive;
    // otherwise re-queue as tap:video so the hub/gallery can finish.
    if (_streamingVideoIds.contains(fileId)) {
      await _startStreamRangeDownload(
        fileId: fileId,
        offset: 0,
        limit: 0,
        force: true,
      );
      return;
    }
    _queueFileDownload(
      fileId,
      priority: 32,
      background: false,
      chatId: chatId,
      reason: 'stream-full:$why',
    );
    _pumpDownloadQueue();
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
    // Progressive ranges use [_recoverStalledStreamRange] from the watchdog.
    if (_streamingVideoIds.contains(fileId) ||
        reasonEarly.startsWith('stream:video:')) {
      unawaited(_recoverStalledStreamRange(fileId));
      return;
    }
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
        // Requeue no-ops when a temp path is cached; siblings must still run.
        _pumpDownloadQueue();
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
    // focus-tail / focus-upgrade must share CDN→origin (R51f SessionLog
    // 21:22: focus-tail gave up at 12s with no origin; album cells stuck).
    final isFocusish = reason.startsWith('focus') ||
        reason.contains(':focus') ||
        reason.startsWith('tap:') ||
        reason.startsWith('auto:video:') ||
        reason.startsWith('stall-retry:') ||
        reason.startsWith('stall-fallback:') ||
        reason.startsWith('stall-lastchance:');

    // FakeTLS 0B: first recover = cancel + same fileId (td#3017).
    // Use chatId from trace — do not require _openChatId (SessionLog 20:27
    // openChat=null skipped same-file and jumped to size-fallback).
    final chatForRequeue = chatId ?? _openChatId;
    if (proxyOn &&
        !hadProgress &&
        isFocusish &&
        !reason.startsWith('stall-fallback:') &&
        !reason.startsWith('stall-lastchance:') &&
        chatForRequeue != null) {
      // R51 / R51b / R51c / R51d (SessionLog 20:28–20:30): Pong alone is NOT
      // zombie proof — first CDN 0B must try origin (R8). After CDN+origin
      // both 0B + fresh Pong while Ready: do NOT soft-restart (R51d — tore
      // working MTProto Ready/send → «прокси отлетел», then soft× kick for
      // 40s×N). Heal with evenIfReady hop (R10); keep Ready when possible.
      final pongFailAt = _lastProxyPingFailAt;
      final pongFailAge = pongFailAt == null
          ? null
          : DateTime.now().difference(pongFailAt);
      final recentMediaOk = _lastNetMediaDoneAt != null &&
          DateTime.now().difference(_lastNetMediaDoneAt!) <= _recentNetMediaOk;
      final originTried = recoverAttempted ||
          _downloadTriedBypassCdn.contains(fileId);
      // iOS (19 Oct SessionLog): Ready + Pong soft-fail then every photo
      // STALL-0B → R57 quiet → hold-cap give-up. R57 never tries origin, so
      // the Android R51 zombie gate (originTried) never opens. Hop on fresh
      // Pong-fail without origin for non-video only. Android unchanged.
      final iosPongFailSkipOrigin = !kIsWeb &&
          Platform.isIOS &&
          !reason.contains('video:');
      final zombiePlane = _tdlibReadyForMedia &&
          pongFailAge != null &&
          pongFailAge <= _proxyPingFailFresh &&
          (originTried || iosPongFailSkipOrigin);
      final zombieCooldownOk = _lastStallZombieSoftRestartAt == null ||
          DateTime.now().difference(_lastStallZombieSoftRestartAt!) >=
              _stallZombieSoftRestartCooldown;
      if (zombiePlane && zombieCooldownOk) {
        final priority = t?.priority ?? prioFocused;
        final retryReason = reason.startsWith('stall-retry:')
            ? reason
            : 'stall-retry:$reason';
        _mediaLog(
          'stall-recover-zombie-hop file=$fileId reason=$reason '
          'pongFailAge=${_fmtDur(pongFailAge!)} originTried=$originTried '
          'iosSkipOrigin=$iosPongFailSkipOrigin '
          'conn=$_connectionState → '
          '${iosPongFailSkipOrigin ? 'soft-restart same hop' : 'evenIfReady hop'}',
        );
        _slog('tg.media', 'stall_zombie_hop', {
          'fileId': fileId,
          'reason': reason,
          'pongFailAgeMs': pongFailAge.inMilliseconds,
          'originTried': originTried,
          'iosSkipOrigin': iosPongFailSkipOrigin,
        });
        _downloadInFlight.remove(fileId);
        _downloadBackgroundIds.remove(fileId);
        _downloadActive = (_downloadActive - 1).clamp(0, 100);
        _downloadTrace.remove(fileId);
        _fileDownloadProgress.remove(fileId);
        // Avoid cancelDownloadFile here — can Ready→Connecting (11:35);
        // soft-restart is worse while Ready+send still work (20:28).
        _lastProxyPingFailAt = null;
        _lastStallZombieSoftRestartAt = DateTime.now();
        _dfStormHolds = 0;
        _dfStormCdnRetried.clear();
        _softRestartFileGapTimer?.cancel();
        _softRestartFileGapTimer = null;
        _softRestartFileGapUntil = null;
        notifyListeners();
        unawaited(() async {
          if (iosPongFailSkipOrigin) {
            // Soft-restart same hop only — do NOT hard-hop+persist. Hard-hop
            // 443→8443 while Ready poisoned v2_wifi preferred; next cold boot
            // stuck Connecting ~40s+ on :8443 (user: «раньше было быстрее»).
            // tearDown remaps file_ids — do not requeue the stale id here.
            await _recoverDeadClient(
              'stall-0b-zombie-pong-ios:$fileId',
            );
            return;
          }
          await _failoverProxy(
            why: 'stall-0b-zombie-pong:$fileId',
            evenIfReady: true,
          );
          if (_tearingDown || _client == null) return;
          if (_downloadInFlight.contains(fileId) ||
              _downloadQueued.contains(fileId)) {
            return;
          }
          // After hop (or probe-miss hop-no-ping): prefer origin once —
          // re-burning CDN 0B left media wedged (SessionLog 21:23–21:24).
          if (_enabledProxyId != null) {
            _downloadForceBypassCdnOnce.add(fileId);
          }
          _queueFileDownload(
            fileId,
            priority: priority,
            background: false,
            chatId: chatForRequeue,
            reason: retryReason,
          );
          _downloadTrace[fileId]?.recoverAttempted = true;
        }());
        return;
      }
      if (pongFailAge != null &&
          pongFailAge <= _proxyPingFailFresh &&
          _tdlibReadyForMedia &&
          !originTried) {
        _mediaLog(
          'stall-recover-zombie-defer file=$fileId '
          'pongFailAge=${_fmtDur(pongFailAge)} '
          'recentMediaOk=$recentMediaOk → try origin first (R51b)',
        );
      }
      if (!recoverAttempted) {
        final nonVideo = !reason.contains('video:');
        // R57 (mtg-wifi 13 Oct): sibling net done does not make the next
        // socket RELAY. 0B CDN is domain-fronting; origin is another DF
        // socket and TDLib keeps opening one every ~3s. Quiet 22s (socket
        // lifetime ~26s), then one CDN retry. A second 0B gives up.
        if (nonVideo &&
            _tdlibReadyForMedia &&
            _dfStormCdnRetried.contains(fileId)) {
          _mediaLog(
            'stall-df-exhausted file=$fileId reason=$reason '
            '(CDN retry still 0B, no origin)',
          );
          _downloadInFlight.remove(fileId);
          _downloadBackgroundIds.remove(fileId);
          _downloadActive = (_downloadActive - 1).clamp(0, 100);
          _downloadTrace.remove(fileId);
          _fileDownloadProgress.remove(fileId);
          await _cancelTdlibDownload(fileId);
          _mediaGiveUpFileIds.add(fileId);
          _armDfStormHold(fileId, 'df-exhausted');
          // R71: always drop exclusive focus — focus-tail used to leave
          // hold+order busy → focus_hold_block / tap stuck during quiet.
          _clearFocusMediaClaim(why: 'stall-df-exhausted:$fileId');
          final wDf = _downloadWaiters.remove(fileId);
          if (wDf != null && !wDf.isCompleted) {
            wDf.complete(_filePathCache[fileId]);
          }
          _pumpDownloadQueue();
          notifyListeners();
          return;
        }
        if (nonVideo && _tdlibReadyForMedia && _dfStormHolds >= 2) {
          // Two quiets already failed to bring dc=203 back. Another
          // downloadFile only feeds the domain-fronting storm.
          _mediaLog(
            'stall-df-exhausted file=$fileId reason=$reason '
            '(hold cap, no new socket)',
          );
          _downloadInFlight.remove(fileId);
          _downloadBackgroundIds.remove(fileId);
          _downloadActive = (_downloadActive - 1).clamp(0, 100);
          _downloadTrace.remove(fileId);
          _fileDownloadProgress.remove(fileId);
          await _cancelTdlibDownload(fileId);
          _mediaGiveUpFileIds.add(fileId);
          _clearFocusMediaClaim(why: 'stall-df-exhausted-cap:$fileId');
          final wCap = _downloadWaiters.remove(fileId);
          if (wCap != null && !wCap.isCompleted) {
            wCap.complete(_filePathCache[fileId]);
          }
          _pumpDownloadQueue();
          notifyListeners();
          return;
        }
        if (nonVideo && _tdlibReadyForMedia) {
          _dfStormCdnRetried.add(fileId);
          _mediaLog(
            'stall-recover-gap file=$fileId reason=$reason '
            '(DF 0B → quiet 22s, retry CDN, no origin)',
          );
          _downloadInFlight.remove(fileId);
          _downloadBackgroundIds.remove(fileId);
          _downloadActive = (_downloadActive - 1).clamp(0, 100);
          _downloadTrace.remove(fileId);
          _fileDownloadProgress.remove(fileId);
          await _cancelTdlibDownload(fileId);
          _armDfStormHold(fileId, 'df-storm');
          _queueFileDownload(
            fileId,
            priority: prioFocused,
            background: false,
            chatId: chatForRequeue,
            reason: reason.startsWith('stall-retry:')
                ? reason
                : 'stall-retry:$reason',
          );
          notifyListeners();
          return;
        }
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
        // First attempt is CDN (offset=0); after 0B force origin. Always
        // re-arm force even if tried set (zombie requeue cleared force-once
        // and left CDN-only loops — SessionLog 21:24:13 offset=0 again).
        if (_enabledProxyId != null) {
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
      // tap:photo:/tap:video:/auto:video: suffix is FILE id — never a
      // message id (SessionLog: openMessageContent msg=16518 → not found).
      // Also covers stall-retry:tap:video:N / stall-fallback:tap:video:N.
      final fileIdInReason = RegExp(
        r'(?:(?:^|:)tap:(?:photo|video):|^auto:video:)(\d+)',
      ).firstMatch(clean);
      if (fileIdInReason != null) {
        final fid = int.tryParse(fileIdInReason.group(1)!);
        if (fid != null && fid > 0) {
          final byFile = _findMessageForFileId(fid);
          if (byFile != null) return byFile.id;
        }
        return _focusMessageId;
      }
      final m = RegExp(
        r'(?:focus(?:-tail)?:|stall-fallback:|stall-retry:|stall-lastchance:|neighbor:)(\d+)',
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
    _mediaLog(
      'stall-recover-done file=$fileId ${_downloadQueueStats()}',
    );

    // Neighbor / demoted 0B stalls — drop, never promote to focus priority.
    final isNeighborish = reason.startsWith('neighbor:') ||
        reason.startsWith('demoted-after-focus') ||
        reason.contains('neighbor:');
    if (isNeighborish) {
      _mediaLog('stall-drop-neighbor file=$fileId reason=$reason');
      // R49: only complete waiters on terminal drop — not before lastchance.
      final w = _downloadWaiters.remove(fileId);
      if (w != null && !w.isCompleted) w.complete(_filePathCache[fileId]);
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

    // R22/R42: small thumbs + tap:photo — skip lastchance (another ~35s 0B).
    // One CDN + one origin is enough; free the exclusive FakeTLS slot.
    // r41_check: tap:photo 333KB Ready+0B burned 30s+ before stall@35s.
    // R70: voice is NOT a thumb — ≤64KB .oga hit stall-give-up-small and
    // poisoned `_mediaGiveUpFileIds` so the bubble never retried after Ready.
    final isVoice = reason.contains('voice:');
    final smallThumb = _enabledProxyId != null &&
        !reason.contains('video:') &&
        !isVoice &&
        (((t?.expectedSize ?? 0) > 0 &&
                t!.expectedSize <= _stallSmallFileBytes) ||
            reason.contains('tap:photo:'));

    // Last chance: focus/tap/auto-video — never neighbors / small thumbs.
    if (!smallThumb &&
        chatId != null &&
        focusMsgId != null &&
        focusMsgId > 0 &&
        !reason.startsWith('stall-lastchance:') &&
        (reason.contains('focus:') ||
            reason.startsWith('tap:') ||
            reason.startsWith('auto:video:') ||
            reason.startsWith('stall-retry:')) &&
        prevFallbackAttempt < 3) {
      await _openMessageContent(chatId, focusMsgId, force: true);
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
      _mediaGiveUpFileIds.add(fileId);
      // R46: focus-tail / focus-upgrade give-up must NOT wipe the whole album
      // claim (`focus-tail:` contains `focus:` — old check cleared order and
      // left sibling sharp stuck behind soft 0B retries).
      if (reason.startsWith('focus-tail:') ||
          reason.startsWith('focus-upgrade:')) {
        _focusDownloadOrder =
            _focusDownloadOrder.where((id) => id != fileId).toList();
        _mediaLog(
          'stall-give-up-small keep-album-queue drop=$fileId '
          'remain=$_focusDownloadOrder',
        );
        final wTail = _downloadWaiters.remove(fileId);
        if (wTail != null && !wTail.isCompleted) {
          wTail.complete(_filePathCache[fileId]);
        }
        _pumpDownloadQueue();
        notifyListeners();
        return;
      }
      // Free exclusive-focus claim so the next viewport/tap can use the slot
      // (r41_check: give-up left focus_hold → DM media blocked).
      if (reason.contains('focus:') || reason.contains('tap:')) {
        _clearFocusMediaClaim(why: 'stall-give-up-small:$fileId');
      }
      final wSmall = _downloadWaiters.remove(fileId);
      if (wSmall != null && !wSmall.isCompleted) {
        wSmall.complete(_filePathCache[fileId]);
      }
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
      // Do not soft-restart / pause-resume here — media path must not tear
      // FakeTLS reconnect (R40/R41).
      if (proxyOn && _tdlibReadyForMedia) {
        unawaited(_failoverProxy(why: 'media-0B-ready:$fileId', evenIfReady: true));
      }
      if (reason.contains('focus:') || reason.contains('tap:')) {
        _clearFocusMediaClaim(why: 'stall-give-up:$fileId');
      }
      final wGive = _downloadWaiters.remove(fileId);
      if (wGive != null && !wGive.isCompleted) {
        wGive.complete(_filePathCache[fileId]);
      }
      _pumpDownloadQueue();
      if (_isProtectedUserMediaReason(reason)) {
        _notifyViewportMediaRescan();
      }
      notifyListeners();
      return;
    }

    final shouldRetry = t != null &&
        !recoverAttempted &&
        _openChatId != null &&
        (reason.contains('focus:') ||
            reason.startsWith('tap:') ||
            reason.startsWith('auto:video:'));
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
      // Terminal — no further requeue.
      final wEnd = _downloadWaiters.remove(fileId);
      if (wEnd != null && !wEnd.isCompleted) {
        wEnd.complete(_filePathCache[fileId]);
      }
      _pumpDownloadQueue();
      if (_isProtectedUserMediaReason(reason)) {
        _notifyViewportMediaRescan();
      }
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
          background: false,
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
        if (!_appInForeground) return;
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
          background: false,
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
    _flushPendingMediaAfterSoftRestart();
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

  /// Drop stall/DF give-ups after MTProto returns so open-chat media can retry.
  void _clearMediaGiveUpsAfterPlaneUp() {
    if (_mediaGiveUpFileIds.isEmpty) return;
    final n = _mediaGiveUpFileIds.length;
    _mediaGiveUpFileIds.clear();
    _dfStormCdnRetried.clear();
    _mediaLog('media-give-up clear n=$n why=mtproto-up');
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
    // R57: a second 0B already gave up. Focus rebuilds must not open another
    // domain-fronting socket for the same id (SessionLog 19:35 loop).
    if (_mediaGiveUpFileIds.contains(fileId)) return;
    final cached = _filePathCache[fileId];
    if (cached != null && cached.isNotEmpty) {
      if (_isPaintReadyMediaPath(cached)) {
        // Silent: UI rebuilds hit this often.
        return;
      }
      _filePathCache.remove(fileId);
    }

    // R48: no new wire jobs while backgrounded (pause owns the queue).
    if (!_appInForeground) {
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
      // R40 (r39_check mtg): R34a skip None while Ready, then TDLib drops
      // Ready→Connecting in bg and keeps dialing FakeTLS (LOCK 3 DF + QUIET
      // 12 DF / 0 RELAY). Freeze with None so unlock soft-restart ≈ boot.
      // R52: defer ~2s — blips that return Ready must not late-None.
      if (!_appInForeground &&
          _softPausedReadyProxy &&
          _useMtprotoProxy &&
          !_appNetworkSuspended &&
          !_tearingDown &&
          _client != null &&
          name != 'connectionStateWaitingForNetwork') {
        _armDeferredLatePauseNone();
      } else if (!_appInForeground &&
          name != 'connectionStateWaitingForNetwork') {
        // R61: Ready already cleared the soft-pause flag, so this drop
        // is not late-None. Kick is frozen for the whole pause.
        _scheduleBgStuckReassert();
      }
      // R53: Ready just after soft-restart is unstable — drop in fg must not
      // wait full kick 35s (SessionLog 19:40:31 Ready → 19:40:36 Connecting).
      if (name != 'connectionStateWaitingForNetwork') {
        _maybeSoftRestartAfterSettleReadyDrop();
      }
    } else if (name == 'connectionStateReady' ||
        name == 'connectionStateUpdating') {
      _cancelDeferredLatePauseNone(why: 'ready:$name');
      _cancelSoftHandshakePauseNone(why: 'ready:$name');
      // R54b: wire hold lifts with Ready (getter); marker for SessionLog.
      if (_useMtprotoProxy) {
        _mediaLog('media-wire-hold clear (conn=$name)');
      }
      if (_fakeTlsQuietUntil != null) {
        _fakeTlsQuietUntil = null;
        _mediaLog('faketls-quiet clear (conn=$name)');
      }
      if (_softResumeGuardUntil != null ||
          _longBackgroundResume ||
          _longBackgroundSoftRestartCount > 0 ||
          _stuckConnectingSoftRestartCount > 0 ||
          _resumeFromPauseSuspend ||
          _softPausedReadyProxy) {
        _softResumeGuardUntil = null;
        _longBackgroundResume = false;
        _longBackgroundSoftRestartCount = 0;
        _stuckConnectingSoftRestartCount = 0;
        _softPauseHardHopTried = false;
        _resumeWasTrueLongBackground = false;
        _resumeFromPauseSuspend = false;
        _softPausedReadyProxy = false;
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
      _cancelBgStuckReassert('ready');
      _armSoftRestartSettleIfNeeded(why: name);
      if (wasWaiting) {
        // R70: WFN / Connecting / DF give-ups must not stick after the plane
        // is live again (failed voice while !Ready never retried). Safe on
        // wifi — wasWaiting is rare when the hop stays Ready.
        _clearMediaGiveUpsAfterPlaneUp();
        _mediaReadyEpoch++;
        // R72: shared waiters + one deferred openMessageContent.
        _completeWaitMediaConn(true);
        _flushPendingOpenMessageContent();
        // Hub watches mediaReadyEpoch to re-run avatar prefetch after Connecting.
        // Do NOT warm history/tip on the Ready edge — hub is still painting.
        _armHubWarmBootGrace(why: 'mtproto-up');
        _armHubBootUiQuiet(why: 'mtproto-up');
        scheduleHubWarmAfterBoot(why: 'mtproto-up');
        // Official TG: hub unread comes from local DB + updateChat*; do not
        // storm getChat×N after Ready (SessionLog 20:45 Skipped 760/1641).
        _notifyUi();
      }
    } else {
      _connectingSince = null;
      _connectingTimeoutTimer?.cancel();
      _connectingTimeoutTimer = null;
      _cancelBgStuckReassert('not-connecting');
      _connectionStatusRevealTimer?.cancel();
      _connectionStatusRevealTimer = null;
    }
  }

  void _armSoftRestartSettleIfNeeded({required String why}) {
    if (!_useMtprotoProxy) return;
    final last = _lastSoftRestartAt;
    if (last == null) return;
    if (DateTime.now().difference(last) > _softRestartSettleArmWindow) {
      return;
    }
    _softRestartSettleUntil = DateTime.now().add(_softRestartSettle);
    _softRestartSettleOkTimer?.cancel();
    _softRestartSettleOkTimer = Timer(_softRestartSettle, () {
      _softRestartSettleOkTimer = null;
      if (!_tdlibReadyForMedia) return;
      _softRestartSettleUntil = null;
      _softRestartSettleCount = 0;
      _mediaLog('soft-restart-settle clear (stable Ready)');
    });
    _mediaLog(
      'soft-restart-settle arm ${_softRestartSettle.inSeconds}s '
      'why=$why count=$_softRestartSettleCount '
      'until=${_softRestartSettleUntil!.toUtc().toIso8601String()}',
    );
  }

  void _maybeSoftRestartAfterSettleReadyDrop() {
    if (!_appInForeground || !_useMtprotoProxy) return;
    if (_tearingDown || _recoveringClient || _client == null) return;
    final until = _softRestartSettleUntil;
    if (until == null || DateTime.now().isAfter(until)) return;
    if (_softRestartSettleCount >= _softRestartSettleCap) {
      _mediaLog(
        'soft-restart-settle cap=$_softRestartSettleCap '
        '→ leave kick ladder conn=$_connectionState',
      );
      _softRestartSettleUntil = null;
      _softRestartSettleOkTimer?.cancel();
      _softRestartSettleOkTimer = null;
      return;
    }
    _softRestartSettleCount++;
    _softRestartSettleUntil = null;
    _softRestartSettleOkTimer?.cancel();
    _softRestartSettleOkTimer = null;
    _mediaLog(
      'soft-restart-settle Ready-drop → soft-restart '
      '#$_softRestartSettleCount conn=$_connectionState',
    );
    _slog('tg.conn', 'settle_ready_drop', {
      'count': _softRestartSettleCount,
      'conn': _connectionState,
    });
    unawaited(
      _recoverDeadClient(
        'ready-drop-in-settle:$_softRestartSettleCount',
        preserveSoftPauseEscalation: true,
      ),
    );
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

  /// R61 (13 Oct 10:37–11:51): pause freezes the kick ladder, and a later
  /// Ready in the background clears the soft-pause flag. The next
  /// Ready→Connecting then sits until a link event. mobile→wifi
  /// `setNetworkType` ended that stall in 269ms. Same action, once the
  /// Connecting has outlasted the 84s self-heal seen the same hour.
  /// Not enableProxy, not soft-restart, not networkTypeNone.
  void _cancelBgStuckReassert(String why) {
    final had = _bgStuckReassertTimer != null || _bgStuckReassertCount != 0;
    _bgStuckReassertTimer?.cancel();
    _bgStuckReassertTimer = null;
    _bgStuckReassertCount = 0;
    if (had) _mediaLog('bg-stuck-reassert clear why=$why');
  }

  void _scheduleBgStuckReassert() {
    if (_appInForeground || _tearingDown) return;
    if (_bgStuckReassertTimer != null) return;
    if (_bgStuckReassertCount >= _bgStuckReassertCap) return;
    if (_tdlibReadyForMedia || _appNetworkSuspended || _softPausedReadyProxy) {
      return;
    }
    if (_connectionState == 'connectionStateWaitingForNetwork') return;
    if (_networkKind != ChatNetworkLinkKind.wifi &&
        _networkKind != ChatNetworkLinkKind.mobile) {
      return;
    }
    _bgStuckReassertTimer = Timer(_bgStuckReassertWait, () {
      _bgStuckReassertTimer = null;
      unawaited(_runBgStuckReassert());
    });
  }

  Future<void> _runBgStuckReassert() async {
    if (_appInForeground || _tearingDown || _client == null) return;
    if (_tdlibReadyForMedia || _appNetworkSuspended || _softPausedReadyProxy) {
      return;
    }
    if (_networkKind != ChatNetworkLinkKind.wifi &&
        _networkKind != ChatNetworkLinkKind.mobile) {
      return;
    }
    if (_connectionState != 'connectionStateConnecting' &&
        _connectionState != 'connectionStateConnectingToProxy') {
      return;
    }
    if (_inFakeTlsQuiet || _recoveringClient) {
      _scheduleBgStuckReassert();
      return;
    }
    _bgStuckReassertCount++;
    _mediaLog(
      'bg-stuck-reassert #$_bgStuckReassertCount '
      'conn=$_connectionState net=$_networkKind',
    );
    await _setTdlibOnline(true);
    if (_appInForeground || _tearingDown || _client == null) return;
    if (_tdlibReadyForMedia) return;
    await _applyNetworkTypeFromDevice(why: 'bg-stuck-reassert', force: true);
    if (!_tdlibReadyForMedia && _useMtprotoProxy && !_tearingDown) {
      _armFakeTlsQuiet(why: 'bg-stuck-reassert');
    }
    if (_bgStuckReassertCount < _bgStuckReassertCap) {
      _scheduleBgStuckReassert();
    }
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
    final mobileEarly = _networkKind == ChatNetworkLinkKind.mobile;
    // R70: cellular FakeTLS hello is slower than wifi — do not kick while
    // ConnectingToProxy still dialing (wifi keeps the prior 40s budget).
    final connectingToProxyBudget =
        Duration(seconds: mobileEarly ? 55 : 40);
    if (_connectionState == 'connectionStateConnectingToProxy' &&
        waited < connectingToProxyBudget) {
      return;
    }
    final mobile = mobileEarly;
    final bearerAt = _lastBearerChangeAt;
    final recentBearer = bearerAt != null &&
        DateTime.now().difference(bearerAt) < const Duration(minutes: 3);
    final softResume = _softResumeGuardUntil != null &&
        DateTime.now().isBefore(_softResumeGuardUntil!);
    final longBg = _longBackgroundResume;

    // R14/R15: while quiet, do not burn soft kicks (boot enableProxy also
    // arms quiet — SessionLog 16:01: soft-nudge enableProxy @35s aborted
    // FakeTLS; mtg `cannot read client hello` / i/o timeout).
    // iOS exception: sticky wrong-port preferred (wifi+:8443) never Ready —
    // quiet only delayed hard-hop ~35s (SessionLog 19 Oct «долго прокси»).
    if (_inFakeTlsQuiet && !_tdlibReadyForMedia) {
      if (!_iosStuckWrongPortPreferred) return;
    }

    int nextStage;
    Duration minWait;
    Duration minGap;

    // R15/R33/R34: after quiet clears, collapse soft×2 → soft-restart / hop —
    // not another soft-nudge. Includes short resume after pause-suspend
    // (SessionLog 16:53: unsuspend+enableProxy stuck ~1m45s; r33_check:
    // WiFi-only after None never yields mtg RELAY — soft-restart @12s).
    // R24: skip stage-3 probe while Connecting (ping always times out).
    final r15Collapse = softResume &&
        _connectionKickCount < 2 &&
        (longBg || _resumeFromPauseSuspend);
    // Long-bg without pause-suspend: minWait ≥ quiet 35s (Ready@20.6s).
    // Soft-pause / late-None: same 35s quiet/collapse (R41 — @4s thrashed).
    final pauseSuspendEarly = r15Collapse && _resumeFromPauseSuspend;
    if (r15Collapse && _longBackgroundSoftRestartCount == 0) {
      nextStage = 4;
      minWait = pauseSuspendEarly
          ? _pauseSuspendCollapseWait
          : Duration(seconds: mobile ? 45 : 40);
      minGap = const Duration(seconds: 12);
    } else if (r15Collapse &&
        _longBackgroundSoftRestartCount < _longBgSoftRestartCap) {
      // Soft-restart again (not probe — ping times out while Connecting).
      nextStage = 4;
      minWait = pauseSuspendEarly
          ? _pauseSuspendCollapseWait
          : Duration(seconds: mobile ? 45 : 40);
      minGap = const Duration(seconds: 12);
    } else if (r15Collapse) {
      nextStage = 5;
      // R41: soft-pause skip-hop only after a full quiet window (not @14s
      // while soft×1 FakeTLS still allowed to finish).
      minWait = pauseSuspendEarly
          ? _pauseSuspendCollapseWait
          : Duration(seconds: mobile ? 48 : 42);
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
      // iOS only: first kick was 35–40s on sticky wrong-port preferred
      // (wifi+:8443 / SessionLog 19 Oct) while the other hop Ready@~0.2s.
      // Shorter wait + port-mismatch → hard-hop on kick #1 (cap 0).
      if (!kIsWeb && Platform.isIOS && _useMtprotoProxy && !longBg) {
        minWait = _iosStuckWrongPortPreferred
            ? const Duration(seconds: 10)
            : Duration(seconds: mobile ? 18 : 12);
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
      final tag = pauseSuspendEarly ? 'R15/R34' : 'R15/R33';
      _mediaLog(
        'mtproto-kick $tag collapse soft×2 → stage=$nextStage '
        'restartCount=$_longBackgroundSoftRestartCount '
        'pauseSuspend=$_resumeFromPauseSuspend '
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
          // R28/R29: soft-nudge while Connecting skips setNetworkType and
          // enableProxy — a pure no-op. SessionLog 11:35 (WiFi→LTE, stall
          // cancel tore Ready→Connecting): kick #1/#2 logged skip then sat
          // ~90s until spontaneous Ready; soft-restart was stage 4 @~200s.
          // After minWait (~40s) already elapsed, escalate to soft-restart
          // same hop instead of burning empty soft-nudge stages.
          if (!_tdlibReadyForMedia) {
            _mediaLog(
              'mtproto-kick #$stage soft-nudge noop → soft-restart '
              '(Connecting+FakeTLS) waited=${_fmtDur(waited)}',
            );
            if (_longBackgroundResume || _resumeFromPauseSuspend) {
              _longBackgroundSoftRestartCount =
                  (_longBackgroundSoftRestartCount + 1)
                      .clamp(1, _longBgSoftRestartCap);
            } else {
              // Short-path: soft-restart used to wipe kick ladder + restore
              // dead preferred forever (MegaFon WiFi vs mtg-wifi :443).
              final hopCap = (!kIsWeb && Platform.isIOS)
                  ? _iosStuckConnectingSoftRestartCap
                  : _stuckConnectingSoftRestartCap;
              _stuckConnectingSoftRestartCount =
                  (_stuckConnectingSoftRestartCount + 1)
                      .clamp(1, hopCap + 1);
              if (_stuckConnectingSoftRestartCount > hopCap &&
                  _activeProxyEndpoints.length > 1) {
                // Hard hop — pingProxy while Connecting times out on every
                // endpoint (R24), so _failoverProxy stays on dead preferred.
                // iOS: softRestartAfter — mid-session enableProxy alone left
                // Connecting (R69); Android path unchanged (no softRestart).
                await _hardHopDeadPreferred(
                  why: 'soft×$_stuckConnectingSoftRestartCount'
                      ':stuck-connecting-faketls-noop',
                  softRestartAfter: !kIsWeb && Platform.isIOS,
                );
                return;
              }
            }
            await _recoverDeadClient(
              'stuck-connecting-faketls-noop:${_fmtDur(waited)}',
              preserveLongBgEscalation: _longBackgroundResume,
              preserveSoftPauseEscalation: _resumeFromPauseSuspend,
            );
            return;
          }
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
          'pauseSuspend=$_resumeFromPauseSuspend '
          'restartCount=$_longBackgroundSoftRestartCount',
        );
        // R37: soft-pause / pause-suspend soft-restart must keep the early
        // ladder (soft×N → hop) — tearDown used to wipe flags → soft-nudge
        // forever while mtg shows DF-only (SessionLog 18:06–18:08).
        if (_longBackgroundResume || _resumeFromPauseSuspend) {
          _longBackgroundSoftRestartCount =
              (_longBackgroundSoftRestartCount + 1)
                  .clamp(1, _longBgSoftRestartCap);
        }
        await _recoverDeadClient(
          _longBackgroundResume
              ? 'stuck-connecting-longbg:${_fmtDur(waited)}'
              : 'stuck-connecting:${_fmtDur(waited)}',
          preserveLongBgEscalation: _longBackgroundResume,
          preserveSoftPauseEscalation: _resumeFromPauseSuspend,
        );
        return;
      case 5:
        // Soft-pause: one preferred soft-restart first (R39 — sometimes
        // preferred recovers in ~300ms). If still Connecting, hard-hop with
        // persist + soft-restart (SessionLog 16 Oct 10:00–10:24: skip-hop +
        // socket-reopen left hard-hop=0 on sticky :443 while official TG
        // RELAY on both ports). After that hop also fails → socket-reopen.
        if (_resumeFromPauseSuspend && _useMtprotoProxy) {
          final lastSkip = _lastLongBgHopTryAt;
          final withinSkipWindow = lastSkip != null &&
              DateTime.now().difference(lastSkip) <
                  const Duration(minutes: 5);
          if (!withinSkipWindow) {
            _lastLongBgHopTryAt = DateTime.now();
            _longBackgroundSoftRestartCount = 1;
            _connectionKickCount = 0;
            _mediaLog(
              'mtproto-kick soft-pause-skip-hop soft-restart-preferred '
              'after=${_fmtDur(waited)}',
            );
            await _recoverDeadClient(
              'soft-pause-skip-hop',
              preserveSoftPauseEscalation: true,
              preserveLongBgEscalation: _longBackgroundResume,
            );
            return;
          }
          if (!_softPauseHardHopTried && _activeProxyEndpoints.length > 1) {
            _softPauseHardHopTried = true;
            await _hardHopDeadPreferred(
              why: 'soft-pause-skip-hop-exhausted:${_fmtDur(waited)}',
              softRestartAfter: true,
            );
            return;
          }
          _mediaLog(
            'mtproto-kick soft-pause-skip-hop exhausted → socket-reopen '
            'after=${_fmtDur(waited)} hardHopTried=$_softPauseHardHopTried',
          );
          await _longBgSocketReopenLastResort(
            why: 'soft-pause-skip-hop-exhausted',
          );
          return;
        }
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
    _cancelBgStuckReassert('foreground');
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
      // R36: R34a skip-None then Ready→Connecting in bg, unlock after ≥2m —
      // still early soft-restart (SessionLog 17:54 long-bg missed R35).
      if (_softPausedReadyProxy && !_tdlibReadyForMedia) {
        _resumeFromPauseSuspend = true;
        _softPausedReadyProxy = false;
        _mediaLog(
          'long-background-resume soft-pause Ready drop '
          '→ R34 early soft-restart',
        );
      } else if (_tdlibReadyForMedia) {
        _softPausedReadyProxy = false;
      }
    } else if (pauseSuspended) {
      // R27/R33: !Ready expected after networkTypeNone — unsuspend only
      // (official resumeNetwork). Arm collapse-to-soft-restart if quiet
      // expires still Connecting — not enableProxy mid-handshake.
      _longBackgroundSoftRestartCount = 0;
      _resumeWasTrueLongBackground = false;
      _resumeFromPauseSuspend = true;
      _softPausedReadyProxy = false;
      _mediaLog(
        'connecting-on-resume skip R13 (pause-suspend) '
        'bg=${_fmtDur(bgFor)} conn=$_connectionState → official-reopen only',
      );
    } else if (_softPausedReadyProxy && !_tdlibReadyForMedia) {
      // R35 (SessionLog 17:36): R34a skipped None while Ready; TDLib then
      // dropped Ready→Connecting ~3s into lock. Treat like pause-suspend
      // early path — not R13 longBg@40s (soft-restart×N, ~2m UX).
      _longBackgroundSoftRestartCount = 0;
      _resumeWasTrueLongBackground = false;
      _resumeFromPauseSuspend = true;
      _softPausedReadyProxy = false;
      _mediaLog(
        'connecting-on-resume skip R13 (soft-pause Ready drop) '
        'bg=${_fmtDur(bgFor)} conn=$_connectionState → R34 early soft-restart',
      );
    } else if (!_tdlibReadyForMedia) {
      // SessionLog 22:36: lock ~52s — TDLib already Connecting (+5s into
      // background) but bg < 2m so R9–R12 never armed; soft-nudge only.
      // Consensus: reopen ladder when resume finds not-Ready (R13).
      // R23: if already mid-ladder, keep restartCount (do not zero).
      // R27/R35: only when we did NOT soft-pause / suspend (true zombie).
      // R68 (SessionLog 09:45): wifi→mobile fires a bogus resume with
      // bg=0ms mid bearer-recover; arming longBg there → soft-restart@50s
      // while FakeTLS quiet already owned the dial (0 RELAY / DF storm).
      final recentBearer = _lastBearerRecoverAt != null &&
          DateTime.now().difference(_lastBearerRecoverAt!) <
              const Duration(seconds: 12);
      if (recentBearer) {
        _longBackgroundSoftRestartCount = 0;
        _resumeWasTrueLongBackground = false;
        _mediaLog(
          'connecting-on-resume skip R13 (bearer-flip) '
          'bg=${_fmtDur(bgFor)} conn=$_connectionState',
        );
      } else {
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
      }
    } else {
      _longBackgroundSoftRestartCount = 0;
      _resumeWasTrueLongBackground = false;
      _softPausedReadyProxy = false;
    }
    _armSoftResumeGuard(why: 'app-resume');
    // Cancel pending suspend; if already suspended, resume recover unsuspends.
    if (_pauseOfflineGraceTimer != null) {
      _pauseOfflineGraceTimer!.cancel();
      _pauseOfflineGraceTimer = null;
      _mediaLog('app-pause-suspend cancel (resume before None)');
    }
    _cancelDeferredLatePauseNone(why: 'app-resume');
    _cancelSoftHandshakePauseNone(why: 'app-resume');
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
    // R68: bearer-recover already did hold→proxy→up + quiet. A same-tick
    // resume must not official-reopen / soft-restart on top of that dial.
    final bearerOwnsDial = _lastBearerRecoverAt != null &&
        DateTime.now().difference(_lastBearerRecoverAt!) <
            const Duration(seconds: 12);
    if (needUnsuspend && bearerOwnsDial) {
      _mediaLog(
        'app-resume skip recover (bearer-recover owns dial) '
        'conn=$_connectionState',
      );
      if (!_tdlibReadyForMedia) {
        _ensureConnectingWaitLogTimer();
      }
    } else if (needUnsuspend) {
      // Fresh kick clock (do not inherit hours of background "waited").
      if (!_tdlibReadyForMedia) {
        _resetMtprotoKickClock(why: 'app-resume-not-ready');
        _ensureConnectingWaitLogTimer();
      }
      // R25/R26: online + setNetworkType after pause None (resumeNetwork).
      _scheduleAppResumeRecover();
    } else if (prevKind != kind) {
      await _applyNetworkTypeFromDevice(why: 'app-resume', force: true);
    } else if (_tdlibReadyForMedia &&
        _useMtprotoProxy &&
        _enabledProxyId != null) {
      // R36 (SessionLog 17:54): force setNetworkType while already
      // Ready+FakeTLS tore Ready→Connecting (~180ms). online=true above
      // is enough (levlam td#3144); leave FakeTLS sockets alone.
      _mediaLog(
        'app-resume-ready skip setNetworkType (Ready+FakeTLS) '
        'proxyId=$_enabledProxyId',
      );
    } else {
      // Ready, never suspended, direct MTProto — soft-nudge network type.
      await _applyNetworkTypeFromDevice(why: 'app-resume-ready', force: true);
    }
  }

  void _scheduleAppResumeRecover() {
    _appResumeRecoverTimer?.cancel();
    // R40: soft-pause FakeTLS — soft-restart-first immediately (≤5s target).
    final immediate = _resumeFromPauseSuspend &&
        _useMtprotoProxy &&
        !_tdlibReadyForMedia;
    _appResumeRecoverTimer = Timer(
      immediate ? Duration.zero : const Duration(seconds: 2),
      () {
        _appResumeRecoverTimer = null;
        unawaited(_runAppResumeRecover());
      },
    );
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
    // R68: timer may have been armed before bearer-recover claimed the dial.
    if (_lastBearerRecoverAt != null &&
        DateTime.now().difference(_lastBearerRecoverAt!) <
            const Duration(seconds: 12)) {
      _mediaLog(
        'app-resume-recover skip (bearer-recover) '
        'conn=$_connectionState quiet=$_inFakeTlsQuiet',
      );
      await _setTdlibOnline(true);
      return;
    }
    final last = _lastAppResumeRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 12)) {
      _mediaLog('app-resume-recover skip debounce');
      return;
    }
    _lastAppResumeRecoverAt = DateTime.now();
    final wasSuspended = _appNetworkSuspended;
    // R40 (r39_check + mtg): quiet-only left zombie dialing (QUIET 12 DF /
    // 0 RELAY) → soft×3 / +46s. Late-None on bg Ready-drop freezes wire;
    // unlock soft-restart-first ≈ boot (Ready ~1–2s). WiFi-only after None
    // still 0 RELAY (R33) — never official-reopen for this path.
    if (_resumeFromPauseSuspend &&
        _useMtprotoProxy &&
        !_tdlibReadyForMedia) {
      // 13 Oct 10:33 MSK: unlock while the previous soft-restart was still
      // inside its 35s quiet tore that handshake and started another.
      // Leave the in-flight dial alone; the quiet expiry ladder still runs.
      if (_inFakeTlsQuiet) {
        _mediaLog(
          'app-resume-recover skip soft-restart (quiet) '
          'until=${_fakeTlsQuietUntil!.toUtc().toIso8601String()} '
          'conn=$_connectionState',
        );
        await _setTdlibOnline(true);
        return;
      }
      // R72: official resumeNetwork once — do not tearDown again while the
      // previous soft-restart is still building FakeTLS / cool-down.
      if (_recoveringClient) {
        _mediaLog(
          'app-resume-recover skip soft-restart (recovering) '
          'conn=$_connectionState',
        );
        await _setTdlibOnline(true);
        return;
      }
      final lastSr = _lastSoftRestartAt;
      if (lastSr != null &&
          DateTime.now().difference(lastSr) < _softRestartFirstCooldown &&
          !_tdlibReadyForMedia) {
        _mediaLog(
          'app-resume-recover skip soft-restart (cooldown) '
          'age=${_fmtDur(DateTime.now().difference(lastSr))} '
          'conn=$_connectionState',
        );
        await _setTdlibOnline(true);
        return;
      }
      await _setTdlibOnline(true);
      _appNetworkSuspended = false;
      // Recent Pong soft-fail on the sticky hop → hard-hop before soft-restart
      // (SessionLog 16 Oct 12:49: Pong timeout then soft×N on same dead
      // preferred). Per-radio preferred still applies inside ensure.
      final pongFailAt = _lastProxyPingFailAt;
      final pongFailRecent = pongFailAt != null &&
          DateTime.now().difference(pongFailAt) < const Duration(minutes: 5);
      if (pongFailRecent &&
          !_softPauseHardHopTried &&
          _activeProxyEndpoints.length > 1) {
        _softPauseHardHopTried = true;
        _longBackgroundSoftRestartCount = 1;
        _mediaLog(
          'app-resume-recover soft-restart-first → hard-hop '
          '(recent Pong fail) suspended=$wasSuspended '
          'conn=$_connectionState net=$_networkKind',
        );
        await _hardHopDeadPreferred(
          why: 'soft-pause-resume-pong-fail',
          softRestartAfter: true,
        );
        return;
      }
      _mediaLog(
        'app-resume-recover soft-restart-first '
        'suspended=$wasSuspended '
        'longBg=$_resumeWasTrueLongBackground '
        'restartCount=$_longBackgroundSoftRestartCount '
        'conn=$_connectionState net=$_networkKind',
      );
      _longBackgroundSoftRestartCount =
          (_longBackgroundSoftRestartCount + 1)
              .clamp(1, _longBgSoftRestartCap);
      await _recoverDeadClient(
        'soft-pause-resume',
        preserveSoftPauseEscalation: true,
        preserveLongBgEscalation: _longBackgroundResume,
      );
      return;
    }
    // R25/R26/R33/R34 — official resumeNetwork (DrKLO + levlam td#3144):
    //   online=true + setNetworkType(force) after pause None.
    // Proxy stays enabled in TDLib — do NOT enableProxy again (SessionLog
    // 16:53: unsuspend+enableProxy aborted FakeTLS → stuck ~1m45s).
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
    // Leave FakeTLS alone after the one resumeNetwork analogue.
    if (!_tdlibReadyForMedia && _useMtprotoProxy) {
      _armFakeTlsQuiet(
        why: wasSuspended ? 'app-resume-unsuspend' : 'app-resume-official',
        duration: wasSuspended ? _pauseSuspendResumeQuiet : _fakeTlsQuiet,
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
    if (!_tdlibReadyForMedia &&
        _connectionState != 'connectionStateWaitingForNetwork') {
      _scheduleBgStuckReassert();
    }
    // R48: unfinished queue must not resume after unlock and steal the
    // active-screen slot. Disk cache stays; only drop pending / inflight.
    // Await so HOME mid-prefetch cannot race new enqueue after empty clear.
    await _clearUnfinishedDownloadsOnPause();
    if (_client == null || _tearingDown) return;
    // R26: always arm suspend — even if already Connecting. Old path skipped
    // when !Ready → zombie FakeTLS until spontaneous Ready (SessionLog 15:35).
    _armPauseNetworkSuspend();
  }

  /// Drop queued + cancel inflight media when the app leaves the foreground.
  /// Keeps [_filePathCache] / durable paths so painted avatars stay sharp.
  Future<void> _clearUnfinishedDownloadsOnPause() async {
    final dropQ = _downloadQueue.length;
    final dropIn = _downloadInFlight.length;

    for (final j in _downloadQueue.toList()) {
      _downloadQueue.remove(j);
      _downloadQueued.remove(j.fileId);
      _downloadTrace.remove(j.fileId);
      _fileDownloadProgress.remove(j.fileId);
      final w = _downloadWaiters.remove(j.fileId);
      if (w != null && !w.isCompleted) w.complete(_filePathCache[j.fileId]);
    }
    _downloadQueue.clear();
    _downloadQueued.clear();

    for (final id in _downloadInFlight.toList()) {
      await _cancelTdlibDownload(id);
      _releaseDownloadSlot(id, failed: true);
      _downloadTrace.remove(id);
      _fileDownloadProgress.remove(id);
      final w = _downloadWaiters.remove(id);
      if (w != null && !w.isCompleted) w.complete(_filePathCache[id]);
    }
    _focusHoldUntil = null;
    _focusDownloadOrder = const [];
    _pendingNeighborMessageIds = const [];
    // Hub pane caches last prefetch ids against [mediaReadyEpoch] — bump so
    // resume re-queues visible avatars instead of thinking they were sent.
    _mediaReadyEpoch++;
    _mediaLog(
      'app-pause clear-unfinished dropQ=$dropQ cancelInflight=$dropIn '
      'epoch=$_mediaReadyEpoch ${_downloadQueueStats()}',
    );
    if (dropQ > 0 || dropIn > 0) {
      notifyListeners();
    }
  }

  /// Official tgnet `pauseNetwork` analogue for TDLib (R26/R34):
  /// after short grace — `networkTypeNone` only when already !Ready (zombie
  /// FakeTLS). Ready+FakeTLS skips None (R34 — short lock keeps Ready).
  /// Resume unsuspends via setNetworkType(current) when None was applied.
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
    // R55 (SessionLog 21:42:38): a second pause after late-None saw
    // WaitingForNetwork, cleared `_softPausedReadyProxy`, and fired None
    // again. Unlock then took official-reopen WiFi (0 RELAY) instead of
    // R40 soft-restart-first — UI stuck «ожидание подключения».
    if (_appNetworkSuspended || _softPausedReadyProxy) {
      _mediaLog(
        'app-pause-suspend skip repeat '
        'suspended=$_appNetworkSuspended softPause=$_softPausedReadyProxy '
        'conn=$_connectionState',
      );
      return;
    }
    // R72: already WaitingForNetwork (late-None / offline) — official
    // pauseNetwork is a no-op when paused. Keep soft-pause so unlock still
    // takes soft-restart-first (R40), do not write None again.
    if (_connectionState == 'connectionStateWaitingForNetwork') {
      _softPausedReadyProxy = true;
      _appNetworkSuspended = true;
      _mediaLog(
        'app-pause-suspend skip already-WFN '
        'conn=$_connectionState',
      );
      return;
    }
    // R34 (r33_check + mtg-wifi): TDLib networkTypeNone ≠ tgnet pauseNetwork.
    // After None, unsuspend WiFi-only never upgrades FakeTLS→RELAY (0/21).
    // Short lock while still Ready — leave sockets alone (freeze-kick only).
    // Keep None when already !Ready (R26 zombie FakeTLS).
    if (_tdlibReadyForMedia && _useMtprotoProxy) {
      _softPausedReadyProxy = true;
      _mediaLog(
        'app-pause-suspend skip None (Ready+FakeTLS) '
        'conn=$_connectionState fg=$_appInForeground',
      );
      return;
    }
    // R52 (SessionLog 12:49:22 / 12:49:57): pause mid soft-restart quiet
    // fired None → aborted FakeTLS dial → 62m WaitingForNetwork until unlock.
    // Soft-handshake protect: leave dialing alone; late-None when quiet ends
    // still bg+!Ready (keeps R40 DF freeze for long locks).
    if (_useMtprotoProxy && (_recoveringClient || _inFakeTlsQuiet)) {
      _softPausedReadyProxy = true;
      _mediaLog(
        'app-pause-suspend skip None (soft-handshake) '
        'conn=$_connectionState recovering=$_recoveringClient '
        'quiet=$_inFakeTlsQuiet',
      );
      _armLateNoneAfterSoftHandshakeQuiet();
      return;
    }
    _softPausedReadyProxy = false;
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

  void _armDeferredLatePauseNone() {
    if (_lateNoneDeferTimer != null) return;
    _mediaLog(
      'app-pause-suspend late-None defer ${_lateNoneDefer.inSeconds}s '
      'conn=$_connectionState',
    );
    _lateNoneDeferTimer = Timer(_lateNoneDefer, () {
      _lateNoneDeferTimer = null;
      if (_appInForeground || _tearingDown || _client == null) return;
      if (!_softPausedReadyProxy || _appNetworkSuspended) return;
      if (_tdlibReadyForMedia) {
        _mediaLog(
          'app-pause-suspend late-None cancel (Ready recovered) '
          'conn=$_connectionState',
        );
        return;
      }
      unawaited(_applyLatePauseNoneAfterReadyDrop());
    });
  }

  void _cancelDeferredLatePauseNone({required String why}) {
    if (_lateNoneDeferTimer == null) return;
    _lateNoneDeferTimer!.cancel();
    _lateNoneDeferTimer = null;
    _mediaLog('app-pause-suspend late-None defer cancel why=$why');
  }

  void _armLateNoneAfterSoftHandshakeQuiet() {
    _softHandshakePauseNoneTimer?.cancel();
    final quietLeft = _fakeTlsQuietUntil == null
        ? Duration.zero
        : _fakeTlsQuietUntil!.difference(DateTime.now());
    final delay = quietLeft > const Duration(milliseconds: 200)
        ? quietLeft
        : const Duration(milliseconds: 200);
    _mediaLog(
      'app-pause-suspend soft-handshake late-None arm '
      '${_fmtDur(delay)} conn=$_connectionState',
    );
    _softHandshakePauseNoneTimer = Timer(delay, () {
      _softHandshakePauseNoneTimer = null;
      if (_appInForeground || _tearingDown || _client == null) return;
      if (_appNetworkSuspended || _tdlibReadyForMedia) return;
      if (!_softPausedReadyProxy) return;
      unawaited(_applyLatePauseNoneAfterReadyDrop());
    });
  }

  void _cancelSoftHandshakePauseNone({required String why}) {
    if (_softHandshakePauseNoneTimer == null) return;
    _softHandshakePauseNoneTimer!.cancel();
    _softHandshakePauseNoneTimer = null;
    _mediaLog('app-pause-suspend soft-handshake late-None cancel why=$why');
  }

  /// R40: R34a left Ready alone; if TDLib later drops to Connecting in
  /// background, apply None so FakeTLS stops DF-dialing until unlock
  /// soft-restart (r39_check: LOCK+QUIET 0 RELAY while zombie lived).
  Future<void> _applyLatePauseNoneAfterReadyDrop() async {
    if (_appInForeground || _tearingDown || _client == null) return;
    if (!_softPausedReadyProxy || _appNetworkSuspended) return;
    if (_tdlibReadyForMedia) return;
    if (!_useMtprotoProxy) return;
    // R72: already WFN — plane frozen; mark suspended for R40 unlock only.
    if (_connectionState == 'connectionStateWaitingForNetwork') {
      _appNetworkSuspended = true;
      _cancelDeferredLatePauseNone(why: 'already-WFN');
      _cancelSoftHandshakePauseNone(why: 'already-WFN');
      _mediaLog(
        'app-pause-suspend late-None skip already-WFN '
        'conn=$_connectionState',
      );
      return;
    }
    // R72: deferred + soft-handshake timers raced before either set
    // `_appNetworkSuspended` (SessionLog pairs Δt~1ms).
    if (_lateNoneApplyInFlight) {
      _mediaLog(
        'app-pause-suspend late-None skip in-flight '
        'conn=$_connectionState',
      );
      return;
    }
    // R52: still inside soft-restart quiet — do not abort the dial; re-arm.
    if (_recoveringClient || _inFakeTlsQuiet) {
      _mediaLog(
        'app-pause-suspend late-None defer (soft-handshake still active) '
        'conn=$_connectionState',
      );
      _armLateNoneAfterSoftHandshakeQuiet();
      return;
    }
    if (_networkKind == ChatNetworkLinkKind.wifi ||
        _networkKind == ChatNetworkLinkKind.mobile) {
      _lastNonOfflineKind = _networkKind;
    }
    _lateNoneApplyInFlight = true;
    _cancelDeferredLatePauseNone(why: 'late-None-apply');
    _cancelSoftHandshakePauseNone(why: 'late-None-apply');
    try {
      _mediaLog(
        'app-pause-suspend late-None (Ready-drop in bg) '
        'conn=$_connectionState',
      );
      _cancelBgStuckReassert('late-None');
      await _setNetworkType(
        'networkTypeNone',
        why: 'app-pause-late-None',
        force: true,
      );
      if (_appInForeground || _tearingDown) return;
      _appNetworkSuspended = true;
    } finally {
      _lateNoneApplyInFlight = false;
    }
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
      _cancelBgStuckReassert('link-offline');
      await _applyNetworkTypeFromDevice(why: 'link:$kind', force: true);
      notifyListeners();
      return;
    }
    // Bearer just reasserted the type. Give that dial its own 90s budget
    // if it does not reach Ready (R61).
    _bgStuckReassertCount = 0;
    if (_bgStuckReassertTimer == null) _scheduleBgStuckReassert();
    // wifi↔mobile: always full recover. Plain setNetworkType while still
    // Ready leaves a long Connecting hang (SessionLog 10:05 mobile→wifi;
    // 14 Oct 09:17 wifi→mobile — Ready→Connecting, ~50s, soft-restart
    // thrash, no mtproto-up). Mobile path still skip-none-bounce inside
    // recover (SessionLog 2026-10-02 08:41).
    final wifiMobileFlip =
        (kind == ChatNetworkLinkKind.wifi ||
            kind == ChatNetworkLinkKind.mobile) &&
        (prev == ChatNetworkLinkKind.wifi ||
            prev == ChatNetworkLinkKind.mobile) &&
        prev != kind;
    if (wifiMobileFlip || !_tdlibReadyForMedia) {
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
    await _loadMtprotoProxyMode();
    // R18: alwaysOff = forced direct — skip geo. auto = follow geo
    // (VPN leave-RU drops FakeTLS; return-to-RU re-enables). alwaysOn =
    // force FakeTLS. Never write geo into [_mtprotoProxyMode].
    if (_mtprotoProxyMode == TdlibMtprotoProxyMode.alwaysOff) {
      _mediaLog('proxy geo recheck skip (user alwaysOff) why=$why');
      return;
    }
    final last = _lastProxyGeoRecheckAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastProxyGeoRecheckAt = DateTime.now();
    final geoWant = await shouldUseTdlibMtprotoProxy();
    final want = _mtprotoProxyMode == TdlibMtprotoProxyMode.alwaysOn
        ? true
        : geoWant;
    final was = _useMtprotoProxy;
    if (want == was && _useMtprotoProxyResolved == want) {
      _mediaLog('proxy geo recheck $why unchanged use=$want');
      return;
    }
    _mediaLog(
      'proxy geo recheck $why → use=$want (was $was) '
      'mode=${_mtprotoProxyMode.storageValue}',
    );
    _useMtprotoProxyResolved = want;
    _useMtprotoProxy = want;
    AppSessionDiagnostics.instance.setTgState(proxy: want);
    _slog('tg.conn', 'proxy_geo', {
      'why': why,
      'use': want,
      'was': was,
      'mode': _mtprotoProxyMode.storageValue,
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
    // R32 (SessionLog 15:37): mobile→wifi while paused raced pause-suspend
    // None + bearer None→WiFi + enableProxy → TDLib timeouts / stuck Connecting.
    // Background: only soft setNetworkType (no enableProxy / None bounce).
    if (!_appInForeground || _appNetworkSuspended) {
      _mediaLog('bearer-recover soft-only (background) why=$why');
      await _applyNetworkTypeFromDevice(why: 'bearer-bg:$why', force: true);
      return;
    }
    final last = _lastBearerRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 8)) {
      _mediaLog('bearer-recover skip debounce why=$why');
      return;
    }
    _lastBearerRecoverAt = DateTime.now();
    // R68: kill any pending resume recover — radio flips often co-fire a
    // lifecycle resume (bg=0) that official-reopened on top of our dial.
    _appResumeRecoverTimer?.cancel();
    _appResumeRecoverTimer = null;
    final mobile = _networkKind == ChatNetworkLinkKind.mobile;
    final linkBearerFlip = why.startsWith('link:ChatNetworkLinkKind.wifi') ||
        why.startsWith('link:ChatNetworkLinkKind.mobile');
    _mediaLog(
      'bearer-recover start why=$why conn=$_connectionState '
      'proxyId=${_enabledProxyId ?? "?"} net=$_networkKind',
    );
    await _setTdlibOnline(true);
    if (_tearingDown || _client == null) return;

    // R69 (14 Oct official A/B + DrKLO): wifi↔mobile official only calls
    // setNetworkAvailable / setNetworkType — same proxy, reopen sockets.
    // Mid-session enableProxy hop switch (R67/R68 hold→proxy→up) left mtg
    // with DF / hello-timeout / 0 RELAY while official TG on the same
    // :8443 + cellular IP got RELAY dc=2. Match official:
    //   same hop → setNetworkType only;
    //   hop must change (443↔8443) → soft-restart so first dial is clean
    //   FakeTLS on the new hop (boot R32), never enableProxy mid-session.
    if (linkBearerFlip && _useMtprotoProxy) {
      final beforeIdx = _proxyEndpointIndex;
      final beforeId = _enabledProxyId;
      _preferEndpointForCurrentBearer(why: why);
      final afterIdx = _proxyEndpointIndex;
      final wantId = _endpointProxyIds[afterIdx];
      final hopChanged = beforeIdx != afterIdx ||
          _enabledProxyId == null ||
          (wantId != null && beforeId != wantId);
      if (hopChanged) {
        _mediaLog(
          'bearer-recover hop-change → soft-restart '
          'idx=$beforeIdx→$afterIdx id=${beforeId ?? "?"}→${wantId ?? "?"} '
          'net=$_networkKind why=$why',
        );
        await _recoverDeadClient('bearer-hop:$why');
        return;
      }
      _mediaLog(
        'bearer-recover same-hop setNetworkType only '
        'proxyId=${_enabledProxyId ?? "?"} net=$_networkKind why=$why',
      );
      await _applyNetworkTypeFromDevice(
        why: 'bearer-recover:$why:same-hop',
        force: true,
      );
      if (!_tdlibReadyForMedia) {
        _armFakeTlsQuiet(why: 'bearer-recover:$why:same-hop');
      }
      return;
    }

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
    // resume bounce → WaitingForNetwork → another 40s+ Connecting).
    // App-resume while Connecting: online+setNetworkType only.
    // Mid-handshake mobile (non-link) still skip-none-bounce (SessionLog
    // 2026-10-02 08:41). Non-proxy wifi↔mobile / wifi !Ready: reopen.
    if (mobile ||
        why.startsWith('app-resume') ||
        (_useMtprotoProxy && _tdlibReadyForMedia)) {
      _mediaLog(
        'bearer-recover skip-none-bounce '
        '(${mobile ? 'mobile' : (_tdlibReadyForMedia ? 'ready+proxy' : 'app-resume')}) '
        'why=$why',
      );
      return;
    }
    await _reopenNetworkConnections(why: 'bearer-recover:$why');
  }

  /// FakeTLS hop for the current radio. Compile-time order: mtg-wifi `:443`
  /// first (home Wi‑Fi), direct mtg `:8443` second (mobile; `:443` often
  /// ClientHello-timeout on cellular DPI — R67). Does not write preferred
  /// prefs (per-radio v2 preferred stays for soft-restart — R73).
  void _preferEndpointForCurrentBearer({required String why}) {
    final endpoints = _activeProxyEndpoints;
    if (endpoints.length <= 1) return;
    final wantPort = _wantProxyPortForKind(_preferredProxyRadioKind);
    if (wantPort == null) return;
    final idx = endpoints.indexWhere((e) => e.port == wantPort);
    if (idx < 0) return;
    final cur = _proxyEndpointIndex.clamp(0, endpoints.length - 1);
    if (cur == idx) return;
    _mediaLog(
      'bearer-endpoint ${endpoints[cur].label} → ${endpoints[idx].label} '
      'net=$_networkKind why=$why',
    );
    _proxyEndpointIndex = idx;
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
    var kind = force ? await ChatNetworkLink.current() : _networkKind;
    // 13 Oct 10:36 MSK: the link stream had already said wifi/mobile, then
    // checkConnectivity() flickered offline and this force-read wrote
    // networkTypeNone. TDLib stayed WaitingForNetwork until a later read
    // agreed with the stream.
    if (force &&
        (kind == ChatNetworkLinkKind.offline ||
            kind == ChatNetworkLinkKind.unknown) &&
        (_networkKind == ChatNetworkLinkKind.wifi ||
            _networkKind == ChatNetworkLinkKind.mobile)) {
      _mediaLog(
        'network-type keep $_networkKind (current=$kind) why=$why',
      );
      kind = _networkKind;
    }
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

  /// Radio used for preferred FakeTLS hop prefs (wifi vs mobile).
  ChatNetworkLinkKind get _preferredProxyRadioKind {
    if (_networkKind == ChatNetworkLinkKind.wifi ||
        _networkKind == ChatNetworkLinkKind.mobile) {
      return _networkKind;
    }
    final last = _lastNonOfflineKind;
    if (last == ChatNetworkLinkKind.wifi ||
        last == ChatNetworkLinkKind.mobile) {
      return last;
    }
    return ChatNetworkLinkKind.unknown;
  }

  String? _preferredProxyPrefKeyForKind(ChatNetworkLinkKind kind) {
    return switch (kind) {
      ChatNetworkLinkKind.wifi => _preferredProxyKeyWifi,
      ChatNetworkLinkKind.mobile => _preferredProxyKeyMobile,
      _ => null,
    };
  }

  int? _wantProxyPortForKind(ChatNetworkLinkKind kind) {
    return switch (kind) {
      ChatNetworkLinkKind.mobile => 8443,
      ChatNetworkLinkKind.wifi => 443,
      _ => null,
    };
  }

  Future<void> _loadPreferredProxyEndpointIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final endpoints = _activeProxyEndpoints;
      if (endpoints.isEmpty) return;
      final kind = _preferredProxyRadioKind;
      final v2Key = _preferredProxyPrefKeyForKind(kind);
      if (v2Key != null) {
        final keyed = prefs.getString(v2Key);
        if (keyed != null && keyed.isNotEmpty) {
          final idx =
              endpoints.indexWhere((e) => '${e.server}:${e.port}' == keyed);
          if (idx >= 0) {
            _proxyEndpointIndex = idx;
            _mediaLog(
              'proxy preferred restore idx=$idx key=$keyed '
              'net=$kind (v2)',
            );
            return;
          }
        }
      }
      // Legacy v1: stash under the radio that matches its port, then only
      // restore when it matches this radio's default — otherwise R67 port
      // (home Wi‑Fi must not inherit sticky mobile `:8443`).
      final legacy = prefs.getString(_preferredProxyKey);
      if (legacy != null && legacy.isNotEmpty) {
        final legIdx =
            endpoints.indexWhere((e) => '${e.server}:${e.port}' == legacy);
        if (legIdx >= 0) {
          final legPort = endpoints[legIdx].port;
          final legKind = legPort == 8443
              ? ChatNetworkLinkKind.mobile
              : (legPort == 443 ? ChatNetworkLinkKind.wifi : null);
          if (legKind != null) {
            final migrateKey = _preferredProxyPrefKeyForKind(legKind);
            if (migrateKey != null &&
                (prefs.getString(migrateKey) ?? '').isEmpty) {
              await prefs.setString(migrateKey, legacy);
              _mediaLog(
                'proxy preferred migrate v1→v2 net=$legKind key=$legacy',
              );
            }
          }
          final want = _wantProxyPortForKind(kind);
          if (want != null && legPort == want) {
            _proxyEndpointIndex = legIdx;
            _mediaLog(
              'proxy preferred restore idx=$legIdx key=$legacy '
              'net=$kind (legacy)',
            );
            return;
          }
        }
      }
      if (kind == ChatNetworkLinkKind.wifi ||
          kind == ChatNetworkLinkKind.mobile) {
        _preferEndpointForCurrentBearer(why: 'preferred-miss:$kind');
      }
    } catch (_) {}
  }

  Future<void> _persistPreferredProxyEndpoint(int index) async {
    final endpoints = _activeProxyEndpoints;
    if (index < 0 || index >= endpoints.length) return;
    final e = endpoints[index];
    final key = '${e.server}:${e.port}';
    try {
      final prefs = await SharedPreferences.getInstance();
      final kind = _preferredProxyRadioKind;
      final v2Key = _preferredProxyPrefKeyForKind(kind);
      if (v2Key != null) {
        await prefs.setString(v2Key, key);
      }
      // Keep legacy for older builds / diagnostics.
      await prefs.setString(_preferredProxyKey, key);
      _mediaLog(
        'proxy preferred save idx=$index key=$key label=${e.label} '
        'net=$kind',
      );
    } catch (_) {}
  }

  Future<void> _clearPreferredProxyEndpoint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final kind = _preferredProxyRadioKind;
      final v2Key = _preferredProxyPrefKeyForKind(kind);
      if (v2Key != null) {
        await prefs.remove(v2Key);
      }
      await prefs.remove(_preferredProxyKey);
      _mediaLog('proxy preferred cleared net=$kind');
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
    final enableId = _endpointProxyIds[idx];
    if (enableId == null) {
      _enabledProxyId = null;
      _mediaLog('proxy sync FAIL no id for enableIndex=$idx');
      return;
    }
    // R51e (SessionLog 21:16:32): probe/failover sync while Ready re-ran
    // disableProxy+enableProxy on the *same* hop → Ready→Connecting ~500ms
    // (zombie-hop tore send-alive MTProto). Skip re-enable when already on
    // that id and Ready; still add missing rows above (enable=false).
    if (_tdlibReadyForMedia &&
        _enabledProxyId != null &&
        _enabledProxyId == enableId) {
      _proxyEndpointIndex = idx;
      _mediaLog(
        'proxy sync skip re-enable (Ready+same hop) idx=$idx '
        'label=${endpoints[idx].label} id=$enableId',
      );
      return;
    }
    try {
      await c.sendAwait({
        '@type': 'disableProxy',
      }, timeout: const Duration(seconds: 3));
    } catch (_) {}
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
      // R41: soft-pause uses same quiet budget as soft-restart (35s).
      _armFakeTlsQuiet(
        why: 'proxy-enable:${endpoints[idx].label}',
        duration: _resumeFromPauseSuspend ? _pauseSuspendResumeQuiet : null,
      );
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
      // R21 / R51e / R51g: never soft-nudge or hop-no-ping after Ready on
      // probe-miss. R51f hop-no-ping (SessionLog 21:39) enableProxy tore
      // Ready→Connecting while siblings had just downloaded; blur stayed.
      // Size-fallback on the live hop is the media heal (21:24 soft→upgrade).
      if (_tdlibReadyForMedia) {
        _mediaLog(
          'proxy-failover skip probe-miss Ready keep=${from.label} '
          'why=$why evenIfReady=$evenIfReady (no hop, no soft-nudge)',
        );
        return;
      }
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
  /// Leave a dead sticky preferred FakeTLS hop. Persist so soft-restart
  /// restore does not undo the switch (SessionLog 16 Oct: every soft×
  /// restored `244.213:443` and never hard-hopped under soft-pause).
  Future<void> _hardHopDeadPreferred({
    required String why,
    bool softRestartAfter = false,
  }) async {
    if (!_useMtprotoProxy || _client == null || _tearingDown) return;
    if (_tdlibReadyForMedia) {
      _mediaLog('hard-hop skip (already Ready) why=$why');
      return;
    }
    final endpoints = _activeProxyEndpoints;
    if (endpoints.length <= 1) {
      _mediaLog('hard-hop single-hop skip why=$why');
      return;
    }
    final cur = _proxyEndpointIndex.clamp(0, endpoints.length - 1);
    final next = (cur + 1) % endpoints.length;
    _mediaLog(
      'hard-hop why=$why ${endpoints[cur].label} → ${endpoints[next].label} '
      '(dead preferred; skip ping; persist'
      '${softRestartAfter ? '+soft-restart' : ''})',
    );
    _proxyEndpointIndex = next;
    await _persistPreferredProxyEndpoint(next);
    _stuckConnectingSoftRestartCount = 0;
    _longBackgroundSoftRestartCount = 0;
    _connectionKickCount = 0;
    _lastConnectionKickAt = null;
    _connectingSince = DateTime.now();
    _lastLongBgHopTryAt = DateTime.now();
    if (softRestartAfter) {
      // Clean first dial on the new hop (boot R32 / bearer R69 analogue).
      await _recoverDeadClient(
        'hard-hop:$why',
        preserveSoftPauseEscalation: _resumeFromPauseSuspend,
        preserveLongBgEscalation: _longBackgroundResume,
      );
      return;
    }
    await _ensureProxy();
    if (!_tdlibReadyForMedia) {
      _armFakeTlsQuiet(why: 'hard-hop:$why');
    }
  }

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
    // Persist — otherwise soft-restart preferred-restore undoes the hop.
    await _persistPreferredProxyEndpoint(nextIdx);
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
    // R48: do not start new network downloads while backgrounded.
    // Disk probes are still OK (paint from cache after unlock).
    if (!_appInForeground) {
      _pumpLocalDiskHitsWhileConnecting();
      return;
    }
    // Local disk hits must never wait on connection state.
    // Network downloads: gate on auth ready (td#1176), NOT connectionStateReady.
    // R54b: FakeTLS + !Ready → hold *wire* (boot/Connecting too, not auth-gate).
    final wireHold = _fakeTlsMediaWireHold;
    if (!_canStartNetworkDownload || wireHold) {
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
          '${wireHold ? 'pump-hold-until-ready' : 'pump-wait-auth'} '
          'queued=${_downloadQueue.length} '
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

    // R42: gate on inflight set too — `_downloadActive` can desync after
    // yield/preempt and allow FakeTLS 2× inflight (r41_check 14603+14604).
    while (_downloadActive < _downloadSlotLimit &&
        _downloadInFlight.length < _downloadSlotLimit &&
        _downloadQueue.isNotEmpty) {
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
      final cachedPath = _filePathCache[job.fileId];
      if (cachedPath != null &&
          cachedPath.isNotEmpty &&
          !_isPaintReadyMediaPath(cachedPath)) {
        _filePathCache.remove(job.fileId);
      }
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
  ///
  /// R70 (r69_post SessionLog): voice notes land as `.oga` / `.ogg`. The old
  /// image/video-only list left `complete-defer … .oga` forever → stall-retry
  /// → give-up while the file was already on disk (mobile FakeTLS worst).
  bool _isVideoMediaPath(String path) {
    final lower = p.basename(path).toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.m4v');
  }

  /// Drop inline streams that belong to another chat. The bubble may still
  /// be mounted under the previous route; leaving the session up makes the
  /// next chat play that file (or a jpeg later cached under the same id).
  void _endForeignVideoStreams(int keepChatId) {
    final foreign = <int>[];
    for (final id in _streamingVideoIds) {
      final meta = _streamSessionMeta[id];
      if (meta != null && meta.chatId == keepChatId) continue;
      foreign.add(id);
    }
    if (foreign.isEmpty) return;
    for (final id in foreign) {
      _mediaLog('stream-end foreign file=$id keepChat=$keepChatId');
      endVideoStream(id);
      unawaited(_cancelTdlibDownload(id));
      if (_downloadInFlight.contains(id)) {
        _releaseDownloadSlot(id, failed: true);
      }
    }
  }

  /// Path the video player may read. Image paths cached under the same
  /// file id (thumb complete) are not a video body. Temp TDLib paths with
  /// no extension stay usable while the mp4 is still being renamed.
  String? _videoStreamPath(int fileId) {
    bool usable(String? path) {
      if (path == null || path.isEmpty) return false;
      final lower = p.basename(path).toLowerCase();
      if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp')) {
        return false;
      }
      return true;
    }

    final partial = _partialFilePath[fileId];
    if (usable(partial)) return partial;
    final cached = cachedFilePath(fileId);
    if (usable(cached)) return cached;
    return null;
  }

  bool _isPaintReadyMediaPath(String path) {
    if (path.isEmpty) return false;
    final name = p.basename(path);
    if (!name.contains('.')) return false;
    final lower = name.toLowerCase();
    const ok = [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.mp4',
      '.mov',
      '.webm',
      // Voice / audio (TDLib voiceNote → .oga).
      '.oga',
      '.ogg',
      '.opus',
      '.mp3',
      '.m4a',
      '.aac',
    ];
    return ok.any(lower.endsWith);
  }

  /// Soft-upgrade bar (~≥40KB). Sync I/O only on focus/tap paths.
  bool _isSharpPhotoPath(String path) {
    return _hasUsablePhotoFile(path, minBytes: 40 * 1024);
  }

  bool _hasUsablePhotoFile(String path, {required int minBytes}) {
    if (!_isPaintReadyMediaPath(path)) return false;
    try {
      return File(path).lengthSync() >= minBytes;
    } catch (_) {
      return false;
    }
  }

  bool _hasUsablePhotoCached(int fileId, {required int minBytes}) {
    final path = _filePathCache[fileId];
    if (path == null || path.isEmpty) return false;
    return _hasUsablePhotoFile(path, minBytes: minBytes);
  }

  bool _hasSharpPhotoCached(int fileId) =>
      _hasUsablePhotoCached(fileId, minBytes: 40 * 1024);

  /// File id to download for a sharp bubble.
  ///
  /// R45: for typed `x`/`y`/`w` prefer [photoRemoteId] — fallbacks are soft
  /// `m`/`s`. Old order (fallback first) painted ~20KB forever and aliased it
  /// onto primary so the real `x` never downloaded (Ostashko 21.9KB `_109.jpg`).
  int? _photoUpgradeFileId(TdlibMessage m) {
    if (_photoBubbleSharp(m)) return null;
    final primary = m.photoRemoteId;
    final type = m.photoSizeType;
    if ((type == 'x' || type == 'y' || type == 'w') &&
        primary != null &&
        primary > 0 &&
        !_hasSharpPhotoCached(primary)) {
      return primary;
    }
    for (final id in m.photoFallbackFileIds) {
      if (id > 0 && !_hasSharpPhotoCached(id)) return id;
    }
    if (primary != null && primary > 0 && !_hasSharpPhotoCached(primary)) {
      return primary;
    }
    return null;
  }

  bool _isTdlibFileMissingError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('file not found') ||
        (s.contains('404') && s.contains('not found'));
  }

  bool _messageRefsFileId(TdlibMessage m, int fileId) {
    if (fileId <= 0) return false;
    if (m.photoRemoteId == fileId) return true;
    if (m.photoFallbackFileIds.contains(fileId)) return true;
    if (m.videoFileId == fileId || m.videoThumbFileId == fileId) return true;
    if (m.videoNoteFileId == fileId || m.videoNoteThumbFileId == fileId) {
      return true;
    }
    if (m.voiceFileId == fileId) return true;
    if (m.documentFileId == fileId || m.documentThumbFileId == fileId) {
      return true;
    }
    return false;
  }

  TdlibMessage? _findMessageForFileId(int fileId) {
    if (fileId <= 0) return null;
    final open = _openChatId;
    final lists = <List<TdlibMessage>>[
      if (open != null) _messagesByChat[open] ?? const <TdlibMessage>[],
      for (final e in _messagesByChat.entries)
        if (e.key != open) e.value,
    ];
    for (final list in lists) {
      for (final m in list) {
        if (_messageRefsFileId(m, fileId)) return m;
      }
    }
    return null;
  }

  int? _counterpartFileId(
    TdlibMessage before,
    TdlibMessage after,
    int staleId,
  ) {
    if (before.videoFileId == staleId) return after.videoFileId;
    if (before.videoThumbFileId == staleId) return after.videoThumbFileId;
    if (before.photoRemoteId == staleId) return after.photoRemoteId;
    final fi = before.photoFallbackFileIds.indexOf(staleId);
    if (fi >= 0 && fi < after.photoFallbackFileIds.length) {
      return after.photoFallbackFileIds[fi];
    }
    if (before.videoNoteFileId == staleId) return after.videoNoteFileId;
    if (before.videoNoteThumbFileId == staleId) {
      return after.videoNoteThumbFileId;
    }
    if (before.voiceFileId == staleId) return after.voiceFileId;
    if (before.documentFileId == staleId) return after.documentFileId;
    if (before.documentThumbFileId == staleId) {
      return after.documentThumbFileId;
    }
    // Role unknown — prefer any new media id on the refreshed message.
    // R70: voice before photo — unknown-role used to pick photo/webp and
    // stamp a sticker path onto a voice bubble (tap:voice:30 → …_109.webp).
    if (after.voiceFileId != null && after.voiceFileId != staleId) {
      return after.voiceFileId;
    }
    if (after.videoFileId != null && after.videoFileId != staleId) {
      return after.videoFileId;
    }
    if (after.videoNoteFileId != null && after.videoNoteFileId != staleId) {
      return after.videoNoteFileId;
    }
    if (after.photoRemoteId != null && after.photoRemoteId != staleId) {
      return after.photoRemoteId;
    }
    if (after.documentFileId != null && after.documentFileId != staleId) {
      return after.documentFileId;
    }
    return null;
  }

  /// Soft-restart keeps RAM transcripts for paint, but TDLib remaps file_ids.
  /// Re-fetch the owning message and return the live file id for [staleId].
  Future<int?> _remapStaleFileId(
    int staleId, {
    required String reason,
  }) async {
    if (staleId <= 0 || _client == null) return null;
    final cachedRemap = _staleFileIdRemap[staleId];
    if (cachedRemap != null && cachedRemap > 0 && cachedRemap != staleId) {
      final owner = _findMessageForFileId(cachedRemap);
      final open = _openChatId;
      if (owner != null && open != null && owner.chatId != open) {
        _mediaLog(
          'file-id-remap skip foreign stale=$staleId fresh=$cachedRemap '
          'owner=${owner.chatId} open=$open',
        );
        _staleFileIdRemap.remove(staleId);
      } else {
        _seedRemappedPath(staleId, cachedRemap);
        return cachedRemap;
      }
    }
    // Message may already have been upserted to the fresh id — scan preserve
    // + open chat for stamped paths / prior remap owner.
    var before = _findMessageForFileId(staleId);
    if (before == null) {
      final open = _openChatId;
      final preserved = open == null ? null : _openTranscriptPreserve[open];
      if (preserved != null) {
        for (final m in preserved) {
          if (_messageRefsFileId(m, staleId)) {
            before = m;
            break;
          }
        }
      }
    }
    // After soft-restart history upsert, the live message may already carry
    // the *new* file_id — scan by stale id misses. Fall back to focus /
    // open-chat owner so getMessage can still yield a fresh id
    // (SessionLog 21:20: remap miss → stream:video File not found ×20s).
    if (before == null) {
      final open = _openChatId;
      final focusId = _focusMessageId;
      if (open != null && focusId != null) {
        final list = _messagesByChat[open];
        if (list != null) {
          for (final m in list) {
            if (m.id == focusId) {
              before = m;
              break;
            }
          }
        }
        if (before == null) {
          final preserved = _openTranscriptPreserve[open];
          if (preserved != null) {
            for (final m in preserved) {
              if (m.id == focusId) {
                before = m;
                break;
              }
            }
          }
        }
      }
    }
    if (before == null) {
      _mediaLog(
        'file-id-remap miss file=$staleId reason=$reason (no message)',
      );
      return null;
    }
    if (!isReady) {
      // Still bind disk path under the stale id so the bubble can paint.
      _seedCacheFromMessageLocalPaths(before);
      return null;
    }
    try {
      final raw = await _client!.sendAwait({
        '@type': 'getMessage',
        'chat_id': before.chatId,
        'message_id': before.id,
      }, timeout: const Duration(seconds: 12));
      if (raw['@type'] != 'message') return null;
      final map = Map<String, dynamic>.from(raw);
      map.putIfAbsent('chat_id', () => before!.chatId);
      final after = _parseMessage(map);
      if (after == null) return null;
      // Keep stamped local path across id remap when TDLib omits it briefly.
      final withPath = (after.photoLocalPath == null ||
              after.photoLocalPath!.isEmpty) &&
          before.photoLocalPath != null &&
          before.photoLocalPath!.isNotEmpty
          ? _copyMessage(after, photoLocalPath: before.photoLocalPath)
          : after;
      _upsertMessage(withPath);
      _touchOpenTranscriptPreserve(before.chatId);
      final fresh = _counterpartFileId(before, withPath, staleId) ??
          _freshMediaIdForReason(withPath, reason, staleId);
      _mediaLog(
        'file-id-remap file=$staleId → ${fresh ?? 'null'} '
        'msg=${before.id} chat=${before.chatId} reason=$reason',
      );
      _slog('tg.media', 'file_id_remap', {
        'staleId': staleId,
        'freshId': fresh,
        'messageId': before.id,
        'chatId': before.chatId,
        'reason': reason,
      });
      if (fresh != null && fresh != staleId) {
        _staleFileIdRemap[staleId] = fresh;
        _seedRemappedPath(
          staleId,
          fresh,
          fallback: before.photoLocalPath ?? before.videoLocalPath,
        );
        _seedCacheFromMessageLocalPaths(withPath);
        _notifyUi();
        return fresh;
      }
      // Same numeric id after getMessage — still missing; nothing to remap.
      return null;
    } catch (e) {
      _mediaLog('file-id-remap fail file=$staleId err=$e');
      return null;
    }
  }

  /// When [staleId] is no longer stamped on the message (already upgraded),
  /// pick the live media id matching [reason].
  int? _freshMediaIdForReason(
    TdlibMessage m,
    String reason,
    int staleId,
  ) {
    final r = reason.toLowerCase();
    int? pick(int? id) =>
        (id != null && id > 0 && id != staleId) ? id : null;
    if (r.contains('stream:video') ||
        r.contains('tap:video') ||
        r.contains('auto:video') ||
        (r.contains('video') && !r.contains('thumb') && !r.contains('note'))) {
      return pick(m.videoFileId);
    }
    if (r.contains('video') && r.contains('thumb')) {
      return pick(m.videoThumbFileId) ?? pick(m.videoFileId);
    }
    if (r.contains('photo') || r.contains('focus')) {
      final primary = pick(m.photoRemoteId);
      if (primary != null) return primary;
      for (final id in m.photoFallbackFileIds) {
        final p = pick(id);
        if (p != null) return p;
      }
      return null;
    }
    if (r.contains('voice')) return pick(m.voiceFileId);
    return pick(m.videoFileId) ??
        pick(m.photoRemoteId) ??
        pick(m.voiceFileId) ??
        pick(m.documentFileId);
  }

  void _seedRemappedPath(
    int staleId,
    int freshId, {
    String? fallback,
  }) {
    if (freshId <= 0) return;
    final fromStale = _filePathCache[staleId];
    final path = (fromStale != null && fromStale.isNotEmpty)
        ? fromStale
        : (fallback != null && fallback.isNotEmpty ? fallback : null);
    if (path == null || !_isPaintReadyMediaPath(path)) return;
    try {
      if (!File(path).existsSync()) return;
    } catch (_) {
      return;
    }
    _filePathCache[freshId] = path;
    _filePathCache[staleId] = path;
    _mediaLog(
      'remap-seed-disk stale=$staleId fresh=$freshId '
      'path=${p.basename(path)}',
    );
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
      var remoteUid = '';
      if (remote is Map) {
        remoteUid = remote['id']?.toString() ?? '';
        if (remoteUid.isEmpty) {
          remoteUid = remote['unique_id']?.toString() ?? '';
        }
        if (remoteUid.isNotEmpty) {
          if (t != null) t.remoteUniqueId = remoteUid;
          _remoteUniqueToFileId[remoteUid] = fileId;
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
        // SessionLog 21:58: completed path `mtproto <id>` has no extension.
        // Caching it made _queueFileDownload return silently, so the
        // FakeTLS queue (7 focus-tail files) never pumped after the slot
        // was freed.
        if (!_isPaintReadyMediaPath(path)) {
          _mediaLog(
            'probe-hit-unready file=$fileId '
            'path=${p.basename(path)} (temp — do not cache)',
          );
          return false;
        }
        _filePathCache[fileId] = path;
        if (remoteUid.isNotEmpty) {
          _durablePathByRemote[remoteUid] = path;
        }
        _mediaLog(
          'probe-hit file=$fileId size=${size > 0 ? _fmtBytes(size) : '?'} '
          'path=${p.basename(path)}',
        );
        return true;
      }
      // TDLib not marked complete yet, but we already have the bytes from a
      // previous session (soft-restart cleared file_id → path).
      if (remoteUid.isNotEmpty) {
        final durable = _durablePathByRemote[remoteUid];
        if (durable != null &&
            durable.isNotEmpty &&
            _isPaintReadyMediaPath(durable)) {
          try {
            if (File(durable).existsSync()) {
              _filePathCache[fileId] = durable;
              _mediaLog(
                'probe-hit-durable file=$fileId '
                'path=${p.basename(durable)} remote=$remoteUid',
              );
              return true;
            }
          } catch (_) {}
        }
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
    final wireHold = _fakeTlsMediaWireHold;
    if (!_canStartNetworkDownload || wireHold) {
      _mediaLog(
        '${wireHold ? 'start-hold-until-ready' : 'start-defer'} '
        'file=$fileId reason=${t?.reason ?? reason} '
        'conn=$_connectionState phase=$phase net=$_networkKind',
      );
      // Return slot to queue until auth ready / online / post-restart Ready.
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
    final reasonNow = t?.reason ?? reason;
    final isHubAvatar = reasonNow == 'hub-avatar';
    // Hub fling won the race after pump-start — free the slot, no getFile.
    if (isHubAvatar && isUiScrollBusy) {
      _mediaLog('start-abort hub-avatar scroll-busy file=$fileId');
      _releaseDownloadSlot(fileId, failed: true);
      return;
    }
    // Disk cache hit (cold start / RAM empty) — don't re-fetch from network.
    // Hub-avatar: skip getFile probe (SessionLog 20:54: probe hung ~12s →
    // Skipped 1950 while scrolling). Cache map only; miss → downloadFile.
    if (isHubAvatar) {
      if (_hasCachedPath(fileId)) {
        final path = _filePathCache[fileId]!;
        if (t != null) t.fromDiskCache = true;
        _mediaLog('disk-hit file=$fileId reason=hub-avatar (cache-only)');
        _completeFileDownload(fileId, path);
        return;
      }
    } else if (await _probeLocalFile(fileId)) {
      final path = _filePathCache[fileId]!;
      if (t != null) t.fromDiskCache = true;
      _mediaLog(
        'disk-hit file=$fileId reason=$reasonNow '
        'waited=${_fmtDur(DateTime.now().difference(t?.enqueuedAt ?? DateTime.now()))}',
      );
      _completeFileDownload(fileId, path);
      return;
    }
    try {
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
      // Re-assert open/view before downloadFile so CDN auth is fresh.
      // Channels always; private chats for video/tap/auto (video notes need
      // it — SessionLog 01:43 auto:video Ready+0B with no open).
      // R49: force on tap/stall video — 8s debounce after focus left body 0B.
      final chatForOpen = t?.chatId ?? _openChatId;
      final needsOpen = chatForOpen != null &&
          (chatForOpen < 0 ||
              reasonNow.contains('video:') ||
              reasonNow.startsWith('tap:') ||
              reasonNow.startsWith('auto:video:') ||
              reasonNow.startsWith('stall-retry:') ||
              reasonNow.startsWith('stall-lastchance:'));
      if (needsOpen) {
        final forceOpen = reasonNow.contains('video:') ||
            reasonNow.startsWith('tap:') ||
            reasonNow.startsWith('auto:video:') ||
            reasonNow.startsWith('stall-retry:') ||
            reasonNow.startsWith('stall-lastchance:');
        await _openMessageContentForFile(
          chatForOpen,
          fileId,
          force: forceOpen,
        );
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
      // R47: preserved transcript file_ids die across soft-restart.
      if (_isTdlibFileMissingError(e)) {
        final fresh = await _remapStaleFileId(fileId, reason: reasonNow);
        if (fresh != null && fresh != fileId) {
          final waiter = _downloadWaiters.remove(fileId);
          if (waiter != null) {
            _downloadWaiters[fresh] = waiter;
          }
          _releaseDownloadSlot(fileId, failed: true);
          final disk = cachedFilePath(fresh) ?? cachedFilePath(fileId);
          if (disk != null && disk.isNotEmpty) {
            _mediaLog(
              'remap-disk-hit stale=$fileId fresh=$fresh '
              'path=${p.basename(disk)}',
            );
            _completeFileDownload(fresh, disk);
            return;
          }
          _queueFileDownload(
            fresh,
            priority: priority,
            background: false,
            chatId: t?.chatId ?? _openChatId,
            reason: reasonNow.contains('$fileId')
                ? reasonNow.replaceFirst('$fileId', '$fresh')
                : reasonNow,
          );
          return;
        }
      }
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
    _streamFullFallbackIds.remove(fileId);
    _partialFilePath[fileId] = path;
    _pulseStreamRangeWaiters(fileId);
    _clearProgressivePhotoPaint(fileId);
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
    final fromDisk = t?.fromDiskCache == true;
    _mediaLog(
      'done file=$fileId reason=${t?.reason ?? ''} '
      '${fromDisk ? 'source=disk' : 'source=net'} '
      'size=${size > 0 ? _fmtBytes(size) : (bytes > 0 ? _fmtBytes(bytes) : '?')} '
      'dl=${elapsed == null ? '?' : _fmtDur(elapsed)} '
      'queued=${queued == null ? '?' : _fmtDur(queued)} '
      '${rate > 0 ? 'rate=${_fmtBytes(rate.round())}/s ' : ''}'
      'path=${p.basename(path)} ${_downloadQueueStats()}',
    );
    // R51b: live CDN/origin bytes prove the FakeTLS plane — ignore stale Pong.
    if (!fromDisk) {
      _lastNetMediaDoneAt = now;
      _lastProxyPingFailAt = null;
      // Live bytes mean the next 0B is a new bad socket, not the same storm.
      _dfStormCdnRetried.clear();
      _dfStormHolds = 0;
      // R71: after soft-restart, space the next FakeTLS file socket (~3s).
      // mtg 20:21: RELAY dc=203 then immediate next stream → DF.
      _armPostRestartMediaCool(why: 'net-done:$fileId');
    }
    _filePathCache[fileId] = path;
    _fileDownloadProgress.remove(fileId);
    _hubAvatarStallAttempts.remove(fileId);
    _hubAvatarCooldownUntil.remove(fileId);
    _hubAvatarCoolUntil.remove(fileId);
    _hubAvatarPoisonFileIds.remove(fileId);
    final doneRemote = t?.remoteUniqueId.trim() ?? '';
    if (doneRemote.isNotEmpty) {
      _hubAvatarPoisonRemotes.remove(doneRemote);
      // R47b: survive soft-restart file_id remap.
      _durablePathByRemote[doneRemote] = path;
      _remoteUniqueToFileId[doneRemote] = fileId;
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
    // R43: also clear `_focusDownloadOrder` — leaving it non-empty made the
    // same-focus early-return re-arm FakeTLS hold for +45s on every
    // viewport tick (Shariy 20:30: disk-hit 14504 → HOLD×40 on siblings).
    if (_focusDownloadOrder.contains(fileId)) {
      final stillPending = _focusDownloadOrder.any(
        (id) =>
            id != fileId &&
            !_hasCachedPath(id) &&
            (_downloadInFlight.contains(id) || _downloadQueued.contains(id)),
      );
      if (!stillPending) {
        // Keep `_focusMessageId` so same bubble does not re-openMessageContent.
        _focusHoldUntil = null;
        _focusDownloadOrder = const [];
        _mediaLog('focus-hold clear why=focus-complete:$fileId');
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
    } else if (_isProtectedUserMediaReason(reason)) {
      // Tap/video finished — run focus that was deferred under tap-hold.
      _notifyViewportMediaRescan();
    }

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
        final pathIsSharp = _isSharpPhotoPath(path);
        // R45: never alias soft `m` onto typed `x`/`y`/`w` primary — that made
        // resolvedPhotoPath look "done" at ~20KB and blocked the real size.
        if (primary != null &&
            primary > 0 &&
            primary != fileId &&
            !softDone &&
            pathIsSharp) {
          _filePathCache[primary] = path;
          _mediaLog(
            'focus-alias primary=$primary ← file=$fileId msg=${msg.id}',
          );
        } else if (primary != null &&
            primary > 0 &&
            primary != fileId &&
            !softDone &&
            !pathIsSharp) {
          _mediaLog(
            'focus-alias skip soft→primary primary=$primary '
            'file=$fileId msg=${msg.id}',
          );
          // Drop a previous soft alias so sharp download can proceed.
          if (_hasCachedPath(primary) && !_hasSharpPhotoCached(primary)) {
            _filePathCache.remove(primary);
          }
        } else if (primary != null &&
            primary > 0 &&
            primary == fileId) {
          _filePathCache[primary] = path;
        }
        final patched = _messageWithDownloadedFile(msg, fileId, path);
        if (patched != null) {
          _upsertMessage(patched);
        }
        // Soft size paints quickly — then queue x/y upgrades (one at a time).
        final isSoftFallback = msg.photoFallbackFileIds.contains(fileId) &&
            (primary == null || fileId != primary);
        if ((softDone || isSoftFallback) &&
            (msg.photoRemoteId == fileId ||
                msg.photoFallbackFileIds.contains(fileId))) {
          int? upgradeId;
          if (primary != null &&
              primary > 0 &&
              primary != fileId &&
              !_hasSharpPhotoCached(primary)) {
            upgradeId = primary;
          } else {
            for (final id in msg.photoFallbackFileIds) {
              if (id != fileId && !_hasSharpPhotoCached(id)) {
                upgradeId = id;
                break;
              }
            }
          }
          if (upgradeId != null) {
            if (_hasCachedPath(upgradeId) && !_hasSharpPhotoCached(upgradeId)) {
              _filePathCache.remove(upgradeId);
            }
            _mediaLog(
              'focus-upgrade-soft msg=${msg.id} from=$fileId → [$upgradeId]',
            );
            _queueFileDownload(
              upgradeId,
              priority: prioFocused,
              background: false,
              chatId: chatId,
              reason: 'focus-upgrade:${msg.id}',
            );
            if (!_focusDownloadOrder.contains(upgradeId)) {
              _focusDownloadOrder = [..._focusDownloadOrder, upgradeId];
            }
            _focusHoldUntil = DateTime.now().add(
              Duration(seconds: _enabledProxyId != null ? 45 : 8),
            );
          } else if (softDone &&
              (msg.photoSizeType == 'm' ||
                  msg.photoSizeType == 's' ||
                  msg.photoSizeType == null)) {
            // Soft-only sizes list — refresh after open so TDLib exposes x/y.
            unawaited(
              _enqueueNeighborMediaAsync(chatId: chatId, messageId: msg.id),
            );
          }
        } else if (!softDone &&
            primary != null &&
            fileId == primary &&
            pathIsSharp) {
          // Real sharp primary landed — drop leftover soft size jobs.
          final dropIds = <int>{
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
      // A thumb updateFile must not become the video body. SessionLog
      // 22:03/22:10: stream file completed as `…_97.jpg` / `…_109.jpg`
      // and the bubble played that still as the message video.
      if (!_isVideoMediaPath(path)) {
        _mediaLog(
          'video-path reject file=$fileId msg=${m.id} '
          'path=${p.basename(path)}',
        );
        if (_filePathCache[fileId] == path) _filePathCache.remove(fileId);
        return null;
      }
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
    List<TdlibReaction>? reactions,
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
      reactions: reactions ?? m.reactions,
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
    final partialPath = local['path']?.toString();
    if (partialPath != null && partialPath.isNotEmpty) {
      _partialFilePath[fileId] = partialPath;
    }
    if (_streamingVideoIds.contains(fileId) ||
        (_downloadTrace[fileId]?.reason ?? '').startsWith('stream:video:')) {
      _pulseStreamRangeWaiters(fileId);
    }
    if (!completed) {
      _maybePaintProgressivePhoto(fileId, local);
    }
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
      // Idle budgets need real byte growth — updateFile spam with the same
      // downloaded_size used to reset lastProgressAt and hide STALL-IDLE.
      if (downloaded > prev) {
        t.lastProgressAt = now;
      }
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

  /// Open TG conversation id, if any — FC sync pauses deferred prefetch on this.
  int? get openChatId => _openChatId;
  bool get isConnected => isReady;

  /// Own Telegram user id after getMe (null until ready).
  int? get myUserId => _myUserId;

  /// Live FakeTLS wire state (after mode + geo).
  bool get mtprotoProxyEnabled => _useMtprotoProxy;

  /// Hub «Прокси» user policy (not the live geo result).
  TdlibMtprotoProxyMode get mtprotoProxyMode => _mtprotoProxyMode;

  /// Persist hub «Прокси» mode and apply immediately.
  Future<void> setMtprotoProxyMode(TdlibMtprotoProxyMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMtprotoProxyModePref, mode.storageValue);
    _mtprotoProxyMode = mode;
    _mtprotoProxyModeLoaded = true;
    _useMtprotoProxyResolved = null;
    if (mode == TdlibMtprotoProxyMode.alwaysOff) {
      _useMtprotoProxy = false;
    } else if (mode == TdlibMtprotoProxyMode.alwaysOn) {
      _useMtprotoProxy = true;
    }
    notifyListeners();

    final c = _client;
    if (c == null) return;
    switch (mode) {
      case TdlibMtprotoProxyMode.alwaysOff:
        _mediaLog('proxy mode → alwaysOff');
        await _disableAllProxies(c, why: 'user-mode-off');
        _enabledProxyId = null;
      case TdlibMtprotoProxyMode.alwaysOn:
        _mediaLog('proxy mode → alwaysOn');
        await _ensureProxy();
      case TdlibMtprotoProxyMode.auto:
        _mediaLog('proxy mode → auto (follow geo)');
        await _ensureProxy();
    }
    notifyListeners();
  }

  Future<void> _loadMtprotoProxyMode() async {
    if (_mtprotoProxyModeLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kDebugMtprotoProxyR18Migrated) != true) {
        // Pre-R18 geo wrote AppBar OFF and blocked all later rechecks.
        await prefs.setBool(_kDebugMtprotoProxyPref, true);
        await prefs.setBool(_kDebugMtprotoProxyR18Migrated, true);
        _mediaLog('proxy R18 migrate: reset sticky AppBar OFF → allow');
      }
      final stored = prefs.getString(_kMtprotoProxyModePref);
      if (stored != null) {
        _mtprotoProxyMode =
            TdlibMtprotoProxyModeStorage.fromStorage(stored);
      } else {
        // Legacy debug bool: false → alwaysOff, else auto.
        final legacy = prefs.getBool(_kDebugMtprotoProxyPref);
        _mtprotoProxyMode = legacy == false
            ? TdlibMtprotoProxyMode.alwaysOff
            : TdlibMtprotoProxyMode.auto;
        await prefs.setString(
          _kMtprotoProxyModePref,
          _mtprotoProxyMode.storageValue,
        );
      }
    } catch (_) {
      _mtprotoProxyMode = TdlibMtprotoProxyMode.auto;
    }
    _mtprotoProxyModeLoaded = true;
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
    final incUnread = _tdlibInt(next['unread_count']);
    var floor = _readInboxFloor[chatId] ?? 0;
    // If TDLib still reports unread, never keep a floor ahead of its
    // last_read — that zeroed badges while getChat.unread_count was live.
    if (incUnread > 0 && floor > incRead) {
      floor = incRead;
      _readInboxFloor[chatId] = incRead;
    }
    var bestRead = incRead;
    if (incUnread <= 0) {
      // Fully caught up per TDLib: floor may be slightly ahead of a lagging
      // last_read field after viewMessages.
      if (prevRead > bestRead) bestRead = prevRead;
      if (floor > bestRead) bestRead = floor;
    }
    if (bestRead > 0) {
      next['last_read_inbox_message_id'] = bestRead;
      if (bestRead > (_readInboxFloor[chatId] ?? 0)) {
        _readInboxFloor[chatId] = bestRead;
      }
    }
    final last = next['last_message'] ?? prev?['last_message'];
    if (last is Map) {
      final tipId = _tdlibInt(last['id']);
      if (tipId > 0 && tipId <= bestRead && incUnread <= 0) {
        next['unread_count'] = 0;
      }
    }
    _chats[chatId] = next;
    // Fresh getChat / chat update is authoritative for hub floor. Tip-bump
    // must not stick max(floor, tdlib) above official TG (SessionLog 20:20:
    // Осташко 10 vs TG 8 after optimistic +1 raised persisted floor).
    _setHubUnreadFloor(chatId, _tdlibInt(next['unread_count']));
  }

  /// Authoritative-enough unread for hub badges.
  ///
  /// Always prefer TDLib `unread_count` when > 0. Tip-only RAM / partial
  /// history must never pull the badge down (Mash/Осташко: RAM=1–2 while
  /// TDLib/official had 12/4 — 2026-10-17).
  ///
  /// Only within ~2s after a local [markMessagesRead] may RAM pull down an
  /// open chat (TDLib unread_count can lag high mid progressive read).
  ///
  /// When TDLib reports 0 but the tip is still past the read floor, treat as
  /// at least 1 (matched DM tip heuristic).
  ///
  /// Once the tip is at/below the read floor, always report 0.
  int unreadCountFor(int chatId) {
    final chat = _chats[chatId];
    if (chat == null) return 0;
    final last = chat['last_message'];
    final lastId = last is Map ? _tdlibInt(last['id']) : 0;
    final lastRead = _effectiveLastReadInbox(chatId);
    if (lastId > 0 && lastId <= lastRead) return 0;

    final reported = _tdlibInt(chat['unread_count']);
    var ramCounted = -1;
    final list = _messagesByChat[chatId];
    if (list != null && list.isNotEmpty) {
      final hasTip = lastId <= 0 || list.any((m) => m.id == lastId);
      if (hasTip) {
        var counted = 0;
        for (final m in list) {
          if (m.isOutgoing) continue;
          if (m.id > lastRead) counted++;
        }
        ramCounted = counted;
      }
    }

    if (reported > 0) {
      if (chatId == _openChatId) {
        // Open chat: progressive mark-read owns the badge — never pin a
        // sticky hub floor above the live count (that froze Осташко at 4
        // while scrolling).
        if (ramCounted >= 0 &&
            ramCounted < reported &&
            _markReadIsFresh(chatId)) {
          return ramCounted;
        }
        if (ramCounted > reported) return ramCounted;
        return reported;
      }
      final floored = _hubUnreadDisplay(chatId, reported);
      if (ramCounted > floored) return ramCounted;
      return floored;
    }

    final floorOnly = _hubUnreadFloor[chatId] ?? 0;
    if (floorOnly > 0) return floorOnly;
    if (ramCounted > 0) return ramCounted;
    if (last is! Map) return 0;
    if (last['is_outgoing'] == true) return 0;
    if (lastId <= 0) return 0;
    if (lastId > lastRead) return 1;
    return 0;
  }

  int _hubUnreadDisplay(int chatId, int reported) {
    final floor = _hubUnreadFloor[chatId] ?? 0;
    if (floor <= reported) {
      if (floor > 0 && floor < reported) {
        _hubUnreadFloor[chatId] = reported;
        _schedulePersistHubUnreadFloor();
      }
      return reported;
    }
    return floor;
  }

  Timer? _hubUnreadFloorPersistTimer;

  void _setHubUnreadFloor(int chatId, int value) {
    if (chatId == 0) return;
    if (value <= 0) {
      if (_hubUnreadFloor.remove(chatId) != null) {
        _schedulePersistHubUnreadFloor();
      }
      return;
    }
    final prev = _hubUnreadFloor[chatId] ?? 0;
    if (value == prev) return;
    _hubUnreadFloor[chatId] = value;
    _schedulePersistHubUnreadFloor();
  }

  /// Coalesce disk writes — `_applyChatRow` can touch floor for every getChat
  /// / loadChats row; sync JSON flush mid-scroll was hitching the hub.
  void _schedulePersistHubUnreadFloor() {
    _hubUnreadFloorPersistTimer?.cancel();
    _hubUnreadFloorPersistTimer = Timer(const Duration(milliseconds: 800), () {
      _hubUnreadFloorPersistTimer = null;
      unawaited(_persistHubUnreadFloor());
    });
  }

  Future<File> _hubUnreadFloorFile() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/familychat_local_cache/hub');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/unread_floor_v1.json');
  }

  Future<void> _loadHubUnreadFloor() async {
    if (_hubUnreadFloorLoaded) return;
    _hubUnreadFloorLoaded = true;
    try {
      final f = await _hubUnreadFloorFile();
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return;
      for (final e in raw.entries) {
        final id = int.tryParse('${e.key}') ?? 0;
        final n = (e.value is num) ? (e.value as num).toInt() : int.tryParse('${e.value}') ?? 0;
        if (id != 0 && n > 0) _hubUnreadFloor[id] = n;
      }
      if (_hubUnreadFloor.isNotEmpty) {
        debugPrint(
          '[unread-dbg] loaded hub unread floor $_hubUnreadFloor',
        );
      }
    } catch (e) {
      debugPrint('[tdlib] load hub unread floor failed: $e');
    }
  }

  Future<void> _persistHubUnreadFloor() async {
    try {
      final f = await _hubUnreadFloorFile();
      if (_hubUnreadFloor.isEmpty) {
        if (await f.exists()) await f.delete();
        return;
      }
      final map = <String, int>{
        for (final e in _hubUnreadFloor.entries) '${e.key}': e.value,
      };
      await f.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('[tdlib] persist hub unread floor failed: $e');
    }
  }

  bool _markReadIsFresh(int chatId) {
    final at = _markReadLocalAt[chatId];
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 2);
  }

  void _scheduleUnreadRefresh(int chatId, {String why = 'tip'}) {
    if (chatId == 0 || chatId == _openChatId) return;
    _unreadRefreshTimers[chatId]?.cancel();
    _unreadRefreshTimers[chatId] = Timer(const Duration(milliseconds: 400), () {
      _unreadRefreshTimers.remove(chatId);
      unawaited(refreshChatSnapshots([chatId]));
    });
  }

  /// First (oldest) unread message id, or null if none / not loaded yet.
  ///
  /// When [unread_count] says N but `last_read` is already near the tip
  /// (FakeTLS / bad progressive mark), "first id > last_read" is the tip —
  /// separator + jump land on the newest post (SessionLog 20:47: listIndex=0
  /// with unread=3). Fall back to the Nth inbound from tip **only** when the
  /// read floor is already in RAM.
  ///
  /// Incomplete history (oldest loaded still newer than last_read) must
  /// return null — tip-count placed Осташко's «Непрочитанные» mid-pack and
  /// mark-read wiped ~14 messages (SessionLog 20:07 unread 96→82).
  int? firstUnreadMessageId(int chatId) {
    final unread = unreadCountFor(chatId);
    if (unread <= 0) return null;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return null;

    final lastRead = lastReadInboxMessageId(chatId);
    final above = <TdlibMessage>[];
    for (final m in list) {
      if (m.isOutgoing) continue;
      if (m.id > lastRead) above.add(m);
    }
    if (above.length >= unread) {
      return above.first.id;
    }

    // Still paging toward last_read — do not invent an anchor from the tip.
    if (lastRead > 0 && list.first.id > lastRead) {
      return null;
    }

    final inbound = <TdlibMessage>[
      for (final m in list)
        if (!m.isOutgoing) m,
    ];
    if (inbound.isEmpty) return null;
    final fromTip = unread.clamp(1, inbound.length);
    return inbound[inbound.length - fromTip].id;
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
      _setHubUnreadFloor(chatId, 0);
      return;
    }
    // Open chat progressive mark-read: update live unread + hub floor from
    // RAM past [messageId]. Closed chats: leave unread_count to readInbox /
    // getChat so tip-only RAM cannot pin hub at 1.
    if (chatId != _openChatId) return;
    _applyOpenChatUnreadAfterMark(chatId, messageId);
  }

  /// Remaining inbound messages after [messageId] — drives FAB + hub after
  /// a successful viewMessages while the chat is open.
  void _applyOpenChatUnreadAfterMark(int chatId, int messageId) {
    final chat = _chats[chatId];
    if (chat == null) return;
    final tip = chat['last_message'];
    final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
    if (tipId > 0 && tipId <= messageId) {
      chat['unread_count'] = 0;
      _setHubUnreadFloor(chatId, 0);
      return;
    }
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    final hasTip = tipId <= 0 || list.any((m) => m.id == tipId);
    if (!hasTip) return;
    var remaining = 0;
    for (final m in list) {
      if (m.isOutgoing) continue;
      if (m.id > messageId) remaining++;
    }
    chat['unread_count'] = remaining;
    _setHubUnreadFloor(chatId, remaining);
  }

  Future<void> markMessagesRead(
    int chatId,
    List<int> messageIds, {
    bool force = false,
  }) async {
    final c = _client;
    if (c == null || !isReady || messageIds.isEmpty) return;
    var maxId = 0;
    for (final id in messageIds) {
      if (id > maxId) maxId = id;
    }
    debugPrint(
      '[unread-dbg] markMessagesRead chat=$chatId ids=$messageIds '
      'unread=${unreadCountFor(chatId)} force=$force',
    );
    try {
      await c.sendAwait({
        '@type': 'viewMessages',
        'chat_id': chatId,
        'message_ids': messageIds,
        'force_read': true,
      });
    } catch (e) {
      // Do not advance local floor — that made FC badges drop while official
      // Telegram still showed unread (viewMessages never reached the server).
      _mediaLog('markMessagesRead FAIL chat=$chatId ids=$messageIds err=$e');
      debugPrint('[tdlib] markMessagesRead failed: $e');
      return;
    }
    if (maxId > 0) {
      _markReadLocalAt[chatId] = DateTime.now();
      _advanceReadInboxFloor(chatId, maxId);
      _hubChatsCache = null;
      _notifyListenersForChat(chatId);
      _scheduleHubSnapshotRowPersist(chatId);
    }
  }

  /// Mark the current tip as read (explicit catch-up only — do not call from
  /// FC mark-read; that wiped TG unread without opening the TG chat).
  Future<void> markChatTipRead(int chatId) async {
    if (chatId == 0 || !isReady) return;
    final chat = _chats[chatId];
    if (chat == null) return;
    final last = chat['last_message'];
    if (last is! Map) return;
    final tipId = _tdlibInt(last['id']);
    if (tipId <= 0) return;
    if (tipId <= _effectiveLastReadInbox(chatId)) return;
    await markMessagesRead(chatId, [tipId], force: true);
  }

  /// Conversation UI: tip visible vs scrolled into history.
  void setOpenChatNearTip(bool nearTip) {
    if (_openChatNearTip == nearTip) return;
    _openChatNearTip = nearTip;
  }

  /// See [_blockUnreadForceView]. Cleared on chat close / gate release.
  void setBlockUnreadForceView(bool block) {
    if (_blockUnreadForceView == block) return;
    _blockUnreadForceView = block;
    if (block) {
      _mediaLog('unread-force-view block openChat=$_openChatId');
    } else {
      _mediaLog('unread-force-view allow openChat=$_openChatId');
    }
  }

  /// Auto-mark incoming tip only when the inbox is already caught up **and**
  /// the open chat is parked on the tip. Otherwise opening / history-scroll
  /// would wipe the unread divider, or tip arrivals while scrolled up would
  /// never arm the FAB unread badge.
  void _maybeAutoMarkRead(int chatId, int messageId) {
    if (chatId != _openChatId || messageId <= 0) return;
    if (!_openChatNearTip) return;
    if (unreadCountFor(chatId) > 0) return;
    debugPrint('[unread-dbg] autoMarkRead chat=$chatId msg=$messageId');
    // Same as markMessagesRead: floor only after viewMessages succeeds.
    unawaited(() async {
      final c = _client;
      if (c == null || !isReady) return;
      try {
        await c.sendAwait({
          '@type': 'viewMessages',
          'chat_id': chatId,
          'message_ids': [messageId],
          'force_read': true,
        });
      } catch (e) {
        _mediaLog(
          'autoMarkRead FAIL chat=$chatId msg=$messageId err=$e',
        );
        return;
      }
      if (chatId != _openChatId) return;
      _markReadLocalAt[chatId] = DateTime.now();
      _advanceReadInboxFloor(chatId, messageId);
      _scheduleHubSnapshotRowPersist(chatId);
      _hubChatsCache = null;
      _notifyListenersForChat(chatId);
    }());
  }

  String outgoingReadStatus(TdlibMessage m) {
    if (!m.isOutgoing) return '';
    // Local / not-yet-acked: clock (or failed), never a premature ✓.
    if (m.sendingState == 'failed') return 'failed';
    if (m.sendingState == 'pending' ||
        (m.sendingState == null && m.id < 0)) {
      return 'sending';
    }
    // Saved Messages = chat with self: once delivered, always «прочитано»
    // (TDLib last_read_outbox often lags / stays behind for this chat).
    if (isSavedMessagesChat(m.chatId)) return 'read';
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

  /// Hub search: public chats + exact `@username` while the user types.
  ///
  /// Returns at most 20 hits, deduped by [TdlibGlobalSearchHit.chatId].
  /// Empty when not Ready or the query is too short.
  Future<List<TdlibGlobalSearchHit>> searchTelegramGlobal(String query) async {
    final c = _client;
    if (c == null || !isReady) return const [];
    final raw = query.trim();
    if (raw.isEmpty) return const [];
    final hasAt = raw.startsWith('@');
    final token = raw.replaceFirst(RegExp(r'^@+'), '').trim();
    if (hasAt) {
      if (token.isEmpty) return const [];
    } else if (token.length < 2) {
      return const [];
    }

    final byId = <int, TdlibGlobalSearchHit>{};

    Future<void> addChatId(int chatId) async {
      if (chatId == 0 || byId.containsKey(chatId)) return;
      var chat = _chats[chatId];
      if (chat == null) {
        try {
          final res = await c.sendAwait({
            '@type': 'getChat',
            'chat_id': chatId,
          });
          if (res['@type'] != 'chat') return;
          chat = Map<String, dynamic>.from(res);
          _applyChatRow(chatId, chat);
        } catch (_) {
          return;
        }
      }
      final hit = _globalHitFromChat(chatId, chat);
      if (hit != null) byId[chatId] = hit;
    }

    // Exact public username (with @, or a single username-shaped token).
    final looksLikeUsername = hasAt ||
        RegExp(r'^[A-Za-z][\w\d_]{3,31}$').hasMatch(token);
    if (looksLikeUsername && token.isNotEmpty) {
      try {
        final chat = await c.sendAwait({
          '@type': 'searchPublicChat',
          'username': token,
        });
        if (chat['@type'] == 'chat') {
          final chatId = _tdlibInt(chat['id']);
          if (chatId != 0) {
            _applyChatRow(chatId, Map<String, dynamic>.from(chat));
            await addChatId(chatId);
          }
        }
      } catch (e) {
        debugPrint('[tdlib] searchPublicChat($token): $e');
      }
    }

    try {
      final res = await c.sendAwait({
        '@type': 'searchPublicChats',
        'query': hasAt ? token : raw,
      });
      final ids = res['chat_ids'];
      if (ids is List) {
        var n = 0;
        for (final rawId in ids) {
          if (n >= 20) break;
          final chatId = _tdlibInt(rawId);
          if (chatId == 0) continue;
          await addChatId(chatId);
          n++;
        }
      }
    } catch (e) {
      debugPrint('[tdlib] searchPublicChats($raw): $e');
    }

    return byId.values.take(20).toList(growable: false);
  }

  TdlibGlobalSearchHit? _globalHitFromChat(
    int chatId,
    Map<String, dynamic> chat,
  ) {
    final type = chat['type'];
    if (type is! Map) return null;
    final typeName = type['@type']?.toString() ?? '';
    var userId = 0;
    var isGroup = false;
    var isChannel = false;
    Map<String, dynamic>? user;
    if (typeName == 'chatTypePrivate' || typeName == 'chatTypeSecret') {
      userId = _tdlibInt(type['user_id']);
      user = userId > 0 ? _users[userId] : null;
      if (user == null && userId > 0) {
        unawaited(_refreshUser(userId, queueAvatar: false));
      }
    } else if (typeName == 'chatTypeBasicGroup') {
      isGroup = true;
    } else if (typeName == 'chatTypeSupergroup') {
      isChannel = type['is_channel'] == true;
      isGroup = !isChannel;
      final sgId = _tdlibInt(type['supergroup_id']);
      if (sgId > 0) _ensureSupergroupCached(sgId);
    } else {
      return null;
    }

    final photoId = _resolveChatAvatarFileId(
      chat,
      user: (isGroup || isChannel) ? null : user,
    );
    String? photoPath;
    if (photoId != null && photoId > 0) {
      photoPath = _filePathCache[photoId];
    }
    final mini = _photoMinithumbnailBytesCached(chatId, chat);

    return TdlibGlobalSearchHit(
      chatId: chatId,
      userId: userId,
      title: _chatTitle(chat, user),
      username: _usernameForCachedChat(chatId, chat, user: user),
      isGroup: isGroup,
      isChannel: isChannel,
      photoFileId: photoId,
      photoLocalPath: photoPath,
      photoMinithumbnailBytes: mini,
    );
  }

  String _usernameForCachedChat(
    int chatId,
    Map<String, dynamic> chat, {
    Map<String, dynamic>? user,
  }) {
    final type = chat['type'];
    if (type is Map) {
      final typeName = type['@type']?.toString() ?? '';
      if (typeName == 'chatTypePrivate' || typeName == 'chatTypeSecret') {
        final u = user ?? _users[_tdlibInt(type['user_id'])];
        if (u != null) return _tdlibUsernameFromUser(u);
      }
      if (typeName == 'chatTypeSupergroup') {
        final sgId = _tdlibInt(type['supergroup_id']);
        final sg = _supergroups[sgId];
        if (sg != null) {
          final usernames = sg['usernames'];
          if (usernames is Map) {
            var username = usernames['editable_username']?.toString() ?? '';
            if (username.isEmpty) {
              final active = usernames['active_usernames'];
              if (active is List && active.isNotEmpty) {
                username = active.first.toString();
              }
            }
            if (username.isNotEmpty) return username;
          }
          final legacy = sg['username']?.toString() ?? '';
          if (legacy.isNotEmpty) return legacy;
        }
      }
    }
    return '';
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
    await _loadMtprotoProxyMode();
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
      // Already authorized but hub never finished first list pass
      // (e.g. previous Ready handler was interrupted).
      if (phase == TdlibAuthPhase.ready && !_hubSurfaceReady) {
        unawaited(_hydrateHubAfterReady());
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
      _sub = _client!.updates.listen(_onUpdateMaybeQueued);
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
    bool preserveSoftPauseEscalation = false,
  }) async {
    if (_tearingDown || _recoveringClient) return;
    final last = _lastDeadClientRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastDeadClientRecoverAt = DateTime.now();
    _lastSoftRestartAt = _lastDeadClientRecoverAt;
    _dfStormCdnRetried.clear();
    _dfStormHolds = 0;
    _softRestartFileGapUntil = null;
    _softRestartFileGapTimer?.cancel();
    _softRestartFileGapTimer = null;
    // R54b: FakeTLS soft-restart → !Ready → wire hold via getter.
    if (_useMtprotoProxy) {
      _mediaLog('media-wire-hold arm why=$why');
    }
    _recoveringClient = true;
    // Soft-restart must not wipe long-bg escalation (SessionLog 21:50:
    // soft-restart → longBg=false → slow soft ladder on same dead hop).
    // R37: same for soft-pause / pause-suspend early ladder.
    final keepLongBg = preserveLongBgEscalation || _longBackgroundResume;
    final keepSoftPause =
        preserveSoftPauseEscalation || _resumeFromPauseSuspend;
    final keepRestartCount = (keepLongBg || keepSoftPause)
        ? _longBackgroundSoftRestartCount.clamp(0, _longBgSoftRestartCap)
        : 0;
    _mediaLog(
      'recover-dead-client why=$why phase=$phase conn=$_connectionState '
      'preserveLongBg=$keepLongBg preserveSoftPause=$keepSoftPause '
      'restartCount=$keepRestartCount',
    );
    _slog('tg.conn', 'recover_begin', {
      'why': why,
      'phase': phase.toString(),
      'openChatId': _openChatId,
      'preservedMsgs': _openChatId == null
          ? 0
          : (_messagesByChat[_openChatId!]?.length ?? 0),
      'preserveLongBg': keepLongBg,
      'preserveSoftPause': keepSoftPause,
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
      if (keepSoftPause) {
        _resumeFromPauseSuspend = true;
        _longBackgroundSoftRestartCount = keepRestartCount;
        if (!keepLongBg) {
          _armSoftResumeGuard(why: 'soft-restart-preserve-soft-pause');
        }
        _mediaLog(
          'soft-pause-escalation preserve after soft-restart '
          'restartCount=$_longBackgroundSoftRestartCount',
        );
      }
      phase = TdlibAuthPhase.starting;
      notifyListeners();
      await ensureStarted();
      // Fresh client already applied proxy via ensureStarted — quiet so
      // immediate soft-kick enableProxy does not abort FakeTLS (R14).
      // R41: soft-pause quiet 35s (Ready clears early → ≤5s still OK;
      // collapse@4s thrashed DF — r40_check short unlock +86s).
      if (!_tdlibReadyForMedia) {
        _armFakeTlsQuiet(
          why: 'soft-restart:$why',
          duration: keepSoftPause ? _pauseSuspendResumeQuiet : null,
        );
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
    _markReadLocalAt.clear();
    for (final t in _unreadRefreshTimers.values) {
      t.cancel();
    }
    _unreadRefreshTimers.clear();
    _users.clear();
    _supergroups.clear();
    _supergroupFetchQueued.clear();
    _memberCountByChatId.clear();
    _memberCountFetchQueued.clear();
    _chatOrder.clear();
    _archiveChatOrder.clear();
    _archiveUnreadChatCount = 0;
    _archiveTotalCount = 0;
    _hubArchiveChatsCache = null;
    _chatFolderInfos.clear();
    _chatFolderDetails.clear();
    _folderChatIds.clear();
    _chatFoldersEpoch = 0;
    _hubSurfaceReady = false;
    _hubHydrateComplete = false;
    _hubUnreadBumpTipId.clear();
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
    // Keep [_durablePathByRemote] + [_staleFileIdRemap] across soft-restart
    // (R47b) — only wipe with the database.
    if (wipeDatabase) {
      _durablePathByRemote.clear();
      _staleFileIdRemap.clear();
    }
    _filePathCache.clear();
    _downloadQueued.clear();
    _downloadInFlight.clear();
    _downloadBackgroundIds.clear();
    _downloadQueue.clear();
    _downloadActive = 0;
    _fileDownloadProgress.clear();
    _downloadTrace.clear();
    _remoteUniqueToFileId.clear();
    // R47: stale ids from prior client must not stay poisoned across restart.
    _mediaGiveUpFileIds.clear();
    _hubWarmDeferTimer?.cancel();
    _hubWarmDeferTimer = null;
    _hubWarmPassScheduled = false;
    _hubWarmNotBefore = null;
    _historyWarmChain = Future<void>.value();
    _historyWarmInFlight.clear();
    _openChatQuietFlushTimer?.cancel();
    _openChatQuietFlushTimer = null;
    _openChatUiQuietUntil = null;
    _openChatOpening = false;
    _openChatQuietMsgCountAtArm = null;
    _hubBootFlushTimer?.cancel();
    _hubBootFlushTimer = null;
    _hubBootUiQuietUntil = null;
    _bootUpdateQueue.clear();
    _bootUpdateDraining = false;
    _bootUpdateHandled = 0;
    _flushingBootUi = false;
    _completeWaitMediaConn(false);
    _pendingOpenMessageContent = null;
    _lastOpenMessageContentDeferKey = null;
    _lastOpenMessageContentDeferLogAt = null;
    _lateNoneApplyInFlight = false;
    _downloadWatchdog?.cancel();
    _downloadWatchdog = null;
    _proxyPlaneTimer?.cancel();
    _proxyPlaneTimer = null;
    _lastPongMs = null;
    _lastPongAt = null;
    // Keep [_lastProxyPingFailAt] / [_pendingMediaAfterSoftRestart] across
    // soft-restart (R51). Full wipe clears pending below.
    _uiNotifyTimer?.cancel();
    _uiNotifyTimer = null;
    _uiNotifyPending = false;
    _uiScrollBusy = false;
    _uiScrollBusyUntil = null;
    _uiImeBusy = false;
    _hubUnreadFloorPersistTimer?.cancel();
    _hubUnreadFloorPersistTimer = null;
    _hubChatsCache = null;
    _miniThumbByChatId.clear();
    _connectingTimeoutTimer?.cancel();
    _connectingTimeoutTimer = null;
    _bgStuckReassertTimer?.cancel();
    _bgStuckReassertTimer = null;
    _bgStuckReassertCount = 0;
    _connectionStatusRevealTimer?.cancel();
    _connectionStatusRevealTimer = null;
    _appResumeRecoverTimer?.cancel();
    _appResumeRecoverTimer = null;
    _pauseOfflineGraceTimer?.cancel();
    _pauseOfflineGraceTimer = null;
    _lateNoneDeferTimer?.cancel();
    _lateNoneDeferTimer = null;
    _softHandshakePauseNoneTimer?.cancel();
    _softHandshakePauseNoneTimer = null;
    _softRestartSettleOkTimer?.cancel();
    _softRestartSettleOkTimer = null;
    _softRestartSettleUntil = null;
    _softRestartFileGapTimer?.cancel();
    _softRestartFileGapTimer = null;
    _softRestartFileGapUntil = null;
    _dfStormCdnRetried.clear();
    _dfStormHolds = 0;
    // Keep [_lastSoftRestartAt] / [_softRestartSettleCount] across soft-restart
    // so the next Ready re-arms settle (R53).
    _appNetworkSuspended = false;
    _resumeFromPauseSuspend = false;
    _softPausedReadyProxy = false;
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
    _partialFilePath.clear();
    _streamRangeGates.clear();
    _streamFullFallbackIds.clear();
    _smartSpeechBotChatId = null;
    _smartSpeechJob = null;
    _smartSpeechAfterMsgId = 0;
    _smartSpeechBotChatOpened = false;
    final speechWaiter = _smartSpeechReplyCompleter;
    _smartSpeechReplyCompleter = null;
    if (speechWaiter != null && !speechWaiter.isCompleted) {
      speechWaiter.completeError(StateError('tdlib tearDown'));
    }
    _voiceTranscriptPending.clear();
    // Keep [_voiceTranscripts] across soft-restart (disk-backed).
    _photoProgressivePaintedBytes.clear();
    _progressivePaintPath.clear();
    _progressivePaintInFlight.clear();
    // Soft-restart must NOT kill the loopback video proxy — ExoPlayer keeps
    // the old http://127.0.0.1:port/v/<id> URL and would 404 if we dispose.
    // Full wipe drops streams; soft-restart keeps proxy + session meta so
    // Range requests can revive after the new TDLib client is Ready.
    if (wipeDatabase) {
      for (final id in _streamingVideoIds.toList()) {
        endVideoStream(id);
      }
      _streamingVideoIds.clear();
      _streamUrlByFileId.clear();
      _streamSessionMeta.clear();
      final streamProxy = _videoStreamProxy;
      _videoStreamProxy = null;
      unawaited(streamProxy?.dispose() ?? Future<void>.value());
      _proxyEndpointIndex = 0;
    }
    await _networkLinkSub?.cancel();
    _networkLinkSub = null;
    // R51: keep waiters for files we will requeue after Ready so tap:video
    // does not complete(null) mid soft-restart.
    final pendingIds =
        _pendingMediaAfterSoftRestart.map((j) => j.fileId).toSet();
    final keepWaiters = <int, Completer<String?>>{};
    for (final e in _downloadWaiters.entries) {
      if (pendingIds.contains(e.key) && !e.value.isCompleted) {
        keepWaiters[e.key] = e.value;
      } else if (!e.value.isCompleted) {
        e.value.complete(null);
      }
    }
    _downloadWaiters
      ..clear()
      ..addAll(keepWaiters);
    if (wipeDatabase) {
      _pendingMediaAfterSoftRestart.clear();
      _lastProxyPingFailAt = null;
      _lastStallZombieSoftRestartAt = null;
      for (final w in _downloadWaiters.values) {
        if (!w.isCompleted) w.complete(null);
      }
      _downloadWaiters.clear();
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
  ///
  /// Official path: push → TDLib updates its DB → [updateChat*] handlers
  /// mirror into [HubFirstPaintSnapshot]. No parallel unread SQLite writer.
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
      // Flush pending hub-row writes so the next cold start paints fresh
      // unread/tip without waiting for online hydrate.
      _flushHubSnapshotPersistSoon(why: 'processPushNotification');
    } on TdlibApiException catch (e) {
      // 406 = unsupported / need full sync — quiet list catch-up only.
      debugPrint('[tdlib] processPushNotification: $e');
      if (e.code == 406 && isReady) {
        unawaited(
          refreshChatList(
            maxPages: 2,
            pageLimit: 40,
            armBootQuiet: true,
            scheduleWarm: false,
            promoteSurfacePerPage: false,
          ),
        );
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

  /// Background hub hydrate after Ready — must not block auth / first paint.
  ///
  /// TG-style: paint from [HubFirstPaintSnapshot] already on screen; one quiet
  /// `loadChats` pass promotes live rows; no second list storm / getChat×N.
  Future<void> _hydrateHubAfterReady() async {
    try {
      await _loadHubUnreadFloor();
      _hubHydrateComplete = false;
      // Longer quiet than the default 500ms — one coalesce for the whole
      // first loadChats pass so snapshot→live does not badge-flicker.
      _armHubBootUiQuiet(
        why: 'hub-hydrate',
        duration: const Duration(milliseconds: 1800),
      );
      await refreshChatList(
        maxPages: 3,
        pageLimit: 40,
        armBootQuiet: false, // already armed above
        scheduleWarm: false,
        promoteSurfacePerPage: true,
      );
      // Archive list in parallel — without it, archived chats vanish from Main
      // and never appear in «Архив чатов» (and FC snapshot can resurface them).
      unawaited(refreshArchiveChatList(maxPages: 4, pageLimit: 40));
      // Empty account / failed pages — still open the gate.
      if (!_hubSurfaceReady) _setHubSurfaceReady(true);
      // Mute color + folders: parallel, not a badge gate (TG paints count first).
      unawaited(_finishHubHydrateExtras());
      // FCM / identity after UI is calm.
      unawaited(Future<void>.delayed(const Duration(seconds: 3), () async {
        await refreshMatchedTgUserIds();
        await _enableNotificationApiAndRegisterDevice();
        await _syncTdlibIdentityAfterReady();
      }));
      // Deeper list only if the first pass left a thin order (new account /
      // cold TDLib). Otherwise updates keep the list current — no +25s storm.
      unawaited(Future<void>.delayed(const Duration(seconds: 40), () {
        if (!isReady || _openChatId != null) return;
        if (_chatOrder.length >= 60) return;
        unawaited(
          refreshChatList(
            maxPages: 4,
            pageLimit: 40,
            armBootQuiet: true,
            scheduleWarm: false,
            promoteSurfacePerPage: false,
          ),
        );
      }));
      _mediaLog('hub-hydrate after-ready done surface=$_hubSurfaceReady');
    } catch (e) {
      _mediaLog('hub-hydrate after-ready fail err=$e');
      _setHubSurfaceReady(true);
      _setHubHydrateComplete(true);
    }
  }

  Future<void> _finishHubHydrateExtras() async {
    try {
      await _awaitInitialFolderInfos();
      await _loadScopeNotificationSettings();
    } catch (e) {
      _mediaLog('hub-hydrate extras fail err=$e');
    } finally {
      _setHubHydrateComplete(true);
      _mediaLog('hub-hydrate folders+mute done');
    }
  }

  Future<void> refreshChatList({
    int maxPages = 12,
    int pageLimit = 50,
    bool armBootQuiet = true,
    bool scheduleWarm = true,
    bool promoteSurfacePerPage = false,
  }) async {
    final c = _client;
    if (c == null || !isReady) return;
    // Cap pages + yield so boot doesn't ANR on a long loadChats storm.
    if (armBootQuiet) {
      _armHubBootUiQuiet(why: 'refreshChatList');
    }
    var timeoutStreak = 0;
    for (var i = 0; i < maxPages; i++) {
      try {
        await c.sendAwait(
          {
            '@type': 'loadChats',
            'chat_list': {'@type': 'chatListMain'},
            'limit': pageLimit.clamp(1, 100),
          },
          timeout: const Duration(seconds: 20),
        );
        timeoutStreak = 0;
        if (promoteSurfacePerPage &&
            !_hubSurfaceReady &&
            _chatOrder.isNotEmpty) {
          // First live page may pierce boot quiet; never pierce scroll-busy
          // (force:true mid-fling → sticky hub scroll, SessionLog 20:28).
          _setHubSurfaceReady(true);
          // One promote notify — further pages stay quiet until the loop ends
          // (mid-page notify×N was the hub badge/order flicker).
          _notifyUi();
        }
        // Let the event loop paint between pages.
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
    // Never force-immediate on hub — pierce scroll-busy / quiet restarted the
    // loadChats rebuild storm. Coalesce only; quiet-end flush paints once.
    _notifyUi();
    if (scheduleWarm) {
      scheduleHubWarmAfterBoot(why: 'refreshChatList');
    }
  }

  /// Load Telegram Archive chat list (`chatListArchive`).
  Future<void> refreshArchiveChatList({
    int maxPages = 6,
    int pageLimit = 50,
  }) async {
    final c = _client;
    if (c == null || !isReady) return;
    var timeoutStreak = 0;
    for (var i = 0; i < maxPages; i++) {
      try {
        await c.sendAwait(
          {
            '@type': 'loadChats',
            'chat_list': {'@type': 'chatListArchive'},
            'limit': pageLimit.clamp(1, 100),
          },
          timeout: const Duration(seconds: 20),
        );
        timeoutStreak = 0;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      } on TdlibApiException catch (e) {
        if (e.code == 404) break; // no more chats
        debugPrint('[tdlib] loadChats archive failed: $e');
        break;
      } on TimeoutException catch (e) {
        timeoutStreak++;
        debugPrint('[tdlib] loadChats archive timeout ($timeoutStreak): $e');
        if (timeoutStreak >= 3) break;
        await Future<void>.delayed(
          Duration(milliseconds: 400 * timeoutStreak),
        );
      } catch (e) {
        debugPrint('[tdlib] loadChats archive failed: $e');
        break;
      }
    }
    _notifyUi();
    unawaited(persistArchiveHubSnapshot());
  }

  /// Move chats to Telegram Archive (removed from Main automatically).
  Future<void> archiveChats(Iterable<int> chatIds) async {
    final c = _client;
    if (c == null || !isReady) return;
    var ok = 0;
    for (final id in chatIds) {
      if (id <= 0) continue;
      if (isSavedMessagesChat(id)) continue;
      try {
        await c.sendAwait(
          {
            '@type': 'addChatToList',
            'chat_id': id,
            'chat_list': {'@type': 'chatListArchive'},
          },
          timeout: const Duration(seconds: 15),
        );
        ok++;
      } catch (e) {
        debugPrint('[tdlib] archiveChat $id failed: $e');
      }
    }
    if (ok > 0) {
      _mediaLog('archive chats ok=$ok');
      _notifyUi();
      unawaited(_persistArchiveMembership(chatIds, archived: true));
    }
  }

  /// Restore chats from Archive to the Main list.
  Future<void> unarchiveChats(Iterable<int> chatIds) async {
    final c = _client;
    if (c == null || !isReady) return;
    var ok = 0;
    for (final id in chatIds) {
      if (id <= 0) continue;
      try {
        await c.sendAwait(
          {
            '@type': 'addChatToList',
            'chat_id': id,
            'chat_list': {'@type': 'chatListMain'},
          },
          timeout: const Duration(seconds: 15),
        );
        ok++;
      } catch (e) {
        debugPrint('[tdlib] unarchiveChat $id failed: $e');
      }
    }
    if (ok > 0) {
      _mediaLog('unarchive chats ok=$ok');
      _notifyUi();
      unawaited(_persistArchiveMembership(chatIds, archived: false));
    }
  }

  /// Force Archive/Main membership into hub SQLite even if positions lag.
  Future<void> _persistArchiveMembership(
    Iterable<int> chatIds, {
    required bool archived,
  }) async {
    final rows = <Map<String, dynamic>>[];
    for (final id in chatIds) {
      final row = hubSnapshotRowForChat(id);
      if (row == null) continue;
      row['tdlib_archived'] = archived;
      rows.add(row);
    }
    if (rows.isNotEmpty) {
      try {
        await HubFirstPaintSnapshot.upsertFullRows(rows);
      } catch (e) {
        debugPrint('[tdlib] archive membership persist failed: $e');
      }
    }
    await persistArchiveHubSnapshot();
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
    _openChatOpening = true;
    try {
      return await _openChatBody(chatId, token);
    } finally {
      _finishOpenChatOpening(chatId);
    }
  }

  void _finishOpenChatOpening(int chatId) {
    if (!_openChatOpening) return;
    _openChatOpening = false;
    if (!_uiNotifyPending) return;
    final atArm = _openChatQuietMsgCountAtArm;
    final nowCount = _messagesByChat[chatId]?.length ?? 0;
    if (atArm != null && atArm >= 16 && nowCount == atArm) {
      _uiNotifyPending = false;
      return;
    }
    // One coalesce after open returns — tip already revealed via setState.
    _notifyUi();
  }

  Future<int> _openChatBody(int chatId, int token) async {
    // Durable window from last visit — before tip-only seed / remote history.
    await seedTranscriptFromCache(chatId);
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
    var c = _client;
    // Cold open while boot still WFN — wait for Ready instead of aborting
    // (Шарий 20:37: open_abort not_ready left TDLib openChat never sent).
    if (c != null && !isReady) {
      _mediaLog('openChat=$chatId wait-ready (boot still $_connectionState)');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!isReady &&
          DateTime.now().isBefore(deadline) &&
          _isActiveOpen(chatId, token)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      c = _client;
    }
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
    // R48: hub-avatar is foreground on the hub — suspend-bg alone misses it.
    await _suspendBackgroundDownloads();
    await _purgeAvatarDownloads();
    _purgeNonFocusDownloads(keepChatId: chatId);
    if (_enabledProxyId != null) {
      // Settle only if wire was busy — fixed 800ms on every open made hub→chat
      // feel frozen after cold start (Шарий 20:41 open gap ~3s + tip-seed).
      final wireBusy = _downloadInFlight.isNotEmpty ||
          _downloadQueue.isNotEmpty;
      await Future<void>.delayed(
        Duration(milliseconds: wireBusy ? 800 : 120),
      );
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

    // AppBar: channel/group member count (subscribers) instead of bare «канал».
    _ensureMemberCountCached(chatId);

    if (!_isActiveOpen(chatId, token)) return token;

    // Seed last_message immediately so UI isn't blank while history loads.
    // Upsert only — never replace an already-loaded transcript with tip-only.
    final last = _chats[chatId]?['last_message'];
    if (last is Map) {
      final lastMap = Map<String, dynamic>.from(last);
      lastMap.putIfAbsent('chat_id', () => chatId);
      final seeded = _parseMessage(lastMap);
      if (seeded != null) {
        final before = _messagesByChat[chatId]?.length ?? 0;
        final hadId = before > 0 &&
            (_messagesByChat[chatId]?.any((m) => m.id == seeded.id) ?? false);
        _upsertMessage(seeded);
        // Tip already in RAM from seed/hub — don't force another full rebuild.
        if (!hadId) _notifyUi();
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
      // Don't block open / first paint on getUser — quiet coalesces the notify.
      unawaited(_refreshUser(peerUid, queueAvatar: false));
    }
    if (!_isActiveOpen(chatId, token)) return token;

    // SQLite-first: UI paints tip from TgMessageRows; tip fill is background.
    // Do not await seed-50 / openCap history into RAM for ListView.
    if (!_tdlibReadyForMedia) {
      _mediaLog(
        'openChat=$chatId local history first — still $_connectionState '
        '(remote fill on Ready)',
      );
      _ensureConnectingWaitLogTimer();
    }
    final have = _messagesByChat[chatId]?.length ?? 0;
    final unread = unreadCountFor(chatId);
    final warm = isUnreadHistoryWarm(chatId) && have >= 16;
    // Official tip ≈20; unread packs still need deeper pages via ensureOlder.
    final openCap = unread >= 2
        ? (unread + 20).clamp(TgHistoryStore.tipPaintCap, 72)
        : TgHistoryStore.tipPaintCap;
    _touchOpenTranscriptPreserve(chatId);
    unawaited(
      TgHistoryStore.instance.ensureTip(
        chatId,
        chatType: _tgChatTypeLabel(chatId),
        title: peerTitle(chatId),
        loadTip: () => loadTipHistoryForDb(
          chatId,
          maxCount: TgHistoryStore.tipPaintCap,
        ),
      ),
    );
    if (warm) {
      _mediaLog(
        'openChat=$chatId skip-block-history warm=true '
        'msgs=$have unread=$unread cap=$openCap tg-db=1',
      );
      if (_tdlibReadyForMedia) {
        unawaited(() async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!_isActiveOpen(chatId, token)) return;
          await syncChatTail(chatId);
        }());
      }
    } else {
      // Thin open: local tip only (silent) — paint comes from DB watch.
      unawaited(
        _loadChatHistory(
          chatId,
          preferLocal: true,
          silent: true,
          maxCountCap: openCap,
          maxAttemptsCap: 3,
        ),
      );
      if (!_isActiveOpen(chatId, token)) return token;
      if (_tdlibReadyForMedia) {
        unawaited(() async {
          await _loadChatHistory(
            chatId,
            preferLocal: false,
            silent: true,
            maxCountCap: openCap,
            maxAttemptsCap: isChannelChat(chatId) ? 4 : 6,
          );
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
          await _loadChatHistory(
            chatId,
            preferLocal: false,
            silent: true,
            maxCountCap: openCap,
            maxAttemptsCap: 4,
          );
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
    // Fresh open — assume tip until conversation scroll reports otherwise.
    _openChatNearTip = true;
    final token = ++_openChatTokenSeq;
    _openChatId = chatId;
    _activeOpenToken = token;
    _openChatOpening = true;
    _armOpenChatUiQuiet();
    AppSessionDiagnostics.instance.setTgOpenChat(chatId);
    // TDLib: prefer a single opened chat (channel updates + unload rules).
    if (prevId != null && prevId != chatId) {
      _openTranscriptPreserve.remove(prevId);
      // R42: old chat focus hold + focus: inflight kept the FakeTLS slot
      // after openChat flipped (r41_check purge kept focus file via
      // focusDownloadOrder before foreign check).
      _clearFocusMediaClaim(why: 'open-chat:$prevId→$chatId');
      _purgeNonFocusDownloads(keepChatId: chatId);
      // Inline player from the previous chat kept its HTTP session
      // (Осташко 22:10: Mash stream 16214 still in flight, completed as a
      // jpeg, and held slot=1). End it before this chat's media starts.
      _endForeignVideoStreams(chatId);
      _pumpDownloadQueue();
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
    var seededPaths = 0;
    for (final entry in _openTranscriptPreserve.entries) {
      final chatId = entry.key;
      final preserved = entry.value;
      if (preserved.isEmpty) continue;
      final existing = _messagesByChat[chatId];
      if (existing == null || existing.isEmpty) {
        _messagesByChat[chatId] = List<TdlibMessage>.of(preserved);
        for (final m in preserved) {
          seededPaths += _seedCacheFromMessageLocalPaths(m);
        }
        _slog('tg.history', 'restore', {
          'chatId': chatId,
          'count': preserved.length,
          'mode': 'replace_empty',
          'seededPaths': seededPaths,
        });
        continue;
      }
      if (existing.length >= preserved.length) {
        // Still re-seed paths onto whatever ids the live list carries.
        for (final m in existing) {
          seededPaths += _seedCacheFromMessageLocalPaths(m);
        }
        for (final m in preserved) {
          seededPaths += _seedCacheFromMessageLocalPaths(m);
        }
        continue;
      }
      final byId = <int, TdlibMessage>{
        for (final m in existing) m.id: m,
      };
      for (final m in preserved) {
        byId.putIfAbsent(m.id, () => m);
      }
      _messagesByChat[chatId] = byId.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      for (final m in _messagesByChat[chatId]!) {
        seededPaths += _seedCacheFromMessageLocalPaths(m);
      }
      _slog('tg.history', 'restore', {
        'chatId': chatId,
        'before': existing.length,
        'after': _messagesByChat[chatId]?.length ?? 0,
        'mode': 'merge',
        'seededPaths': seededPaths,
      });
    }
    if (seededPaths > 0) {
      _mediaLog(
        'restore-seed-cache paths=$seededPaths '
        '(R47b soft-restart disk paint)',
      );
    }
  }

  /// Re-bind RAM [_filePathCache] from stamped local paths after soft-restart
  /// (tearDown clears id→path; files on disk remain).
  int _seedCacheFromMessageLocalPaths(TdlibMessage m) {
    var n = 0;
    void seed(int? id, String? path) {
      if (id == null || id <= 0) return;
      if (path == null || path.isEmpty) return;
      if (!_isPaintReadyMediaPath(path)) return;
      if (_hasCachedPath(id)) return;
      try {
        if (!File(path).existsSync()) return;
      } catch (_) {
        return;
      }
      _filePathCache[id] = path;
      n++;
    }

    seed(m.photoRemoteId, m.photoLocalPath);
    if (m.photoLocalPath != null && m.photoLocalPath!.isNotEmpty) {
      for (final id in m.photoFallbackFileIds) {
        seed(id, m.photoLocalPath);
      }
    }
    seed(m.videoFileId, m.videoLocalPath);
    seed(m.videoThumbFileId, m.videoThumbLocalPath);
    seed(m.videoNoteFileId, m.videoNoteLocalPath);
    seed(m.videoNoteThumbFileId, m.videoNoteThumbLocalPath);
    seed(m.voiceFileId, m.voiceLocalPath);
    seed(m.documentFileId, m.documentLocalPath);
    seed(m.documentThumbFileId, m.documentThumbLocalPath);
    return n;
  }

  void _touchOpenTranscriptPreserve(int chatId) {
    if (_openChatId != chatId) return;
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    final prev = _openTranscriptPreserve[chatId];
    if (prev != null && prev.length > list.length) return;
    _openTranscriptPreserve[chatId] = List<TdlibMessage>.of(list);
  }

  /// Restore last-visit transcript window from SQLite (survives process death).
  ///
  /// TDLib `only_local` after cold start often has tip-only until remote pages
  /// land — without this, open paints 1 message then drips the rest.
  ///
  /// Fast path: [readTail] only. Full meta→rows migrate is background — awaiting
  /// it on open pinned the UI ~3s (Шарий 20:41 FRAME total≈3078ms, db=200).
  Future<int> seedTranscriptFromCache(int chatId) async {
    final existing = _messagesByChat[chatId]?.length ?? 0;
    if (existing >= TgHistoryStore.ensureTipMin) {
      unawaited(
        TgHistoryStore.instance.migrateFromTranscriptCacheIfNeeded(chatId),
      );
      return existing;
    }
    // Tip paint first — do not await migrate (can upsert hundreds of rows).
    final tip = await TgHistoryStore.instance.readTail(
      chatId,
      limit: TgHistoryStore.tipPaintCap,
    );
    await Future<void>.delayed(Duration.zero);
    if (tip.isEmpty) {
      // Cold meta cache may still have a tip while SQLite rows are empty.
      unawaited(() async {
        await TgHistoryStore.instance.migrateFromTranscriptCacheIfNeeded(
          chatId,
        );
        if (_openChatId != chatId) return;
        if ((_messagesByChat[chatId]?.length ?? 0) >=
            TgHistoryStore.ensureTipMin) {
          return;
        }
        await seedTranscriptFromCache(chatId);
      }());
      return existing;
    }
    final byId = <int, TdlibMessage>{
      for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[])
        m.id: m,
    };
    for (final m in tip) {
      byId.putIfAbsent(m.id, () => m);
      _seedFilePathCacheFromMessage(m);
    }
    final sorted = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    _messagesByChat[chatId] = sorted;
    _touchOpenTranscriptPreserve(chatId);
    unawaited(
      TgHistoryStore.instance.migrateFromTranscriptCacheIfNeeded(chatId),
    );
    if (sorted.length > existing) {
      _mediaLog(
        '[tg-db] tip-seed chat=$chatId was=$existing now=${sorted.length} '
        'db=-1',
      );
      _slog('tg.history', 'tg_db_tip_seed', {
        'chatId': chatId,
        'was': existing,
        'now': sorted.length,
        'db': -1,
      });
    }
    return sorted.length;
  }

  void _seedFilePathCacheFromMessage(TdlibMessage m) {
    void seed(int? id, String? path) {
      if (id == null || id <= 0) return;
      final p = path?.trim() ?? '';
      if (p.isEmpty) return;
      _filePathCache[id] = p;
    }

    seed(m.photoRemoteId, m.photoLocalPath);
    for (final id in m.photoFallbackFileIds) {
      seed(id, m.photoLocalPath);
    }
    seed(m.voiceFileId, m.voiceLocalPath);
    seed(m.videoNoteFileId, m.videoNoteLocalPath);
    seed(m.videoNoteThumbFileId, m.videoNoteThumbLocalPath);
    seed(m.videoFileId, m.videoLocalPath);
    seed(m.videoThumbFileId, m.videoThumbLocalPath);
    seed(m.documentFileId, m.documentLocalPath);
    seed(m.documentThumbFileId, m.documentThumbLocalPath);
  }

  Future<void> _persistTranscriptCache(int chatId) async {
    // TG rows are written on every upsert; stop meta transcript-cache writes.
    final list = _messagesByChat[chatId];
    if (list == null || list.isEmpty) return;
    unawaited(
      TgHistoryStore.instance.upsertMessages(
        chatId,
        list,
        chatType: _tgChatTypeLabel(chatId),
        title: peerTitle(chatId),
      ),
    );
  }

  String _tgChatTypeLabel(int chatId) => TgHistoryStore.chatTypeLabel(
        isChannel: isChannelChat(chatId),
        isPrivate: isPrivateChat(chatId),
        isGroup: isGroupChat(chatId),
      );

  /// Flush open chat transcript to disk (app pause / leave).
  Future<void> persistTranscriptCache(int chatId) =>
      _persistTranscriptCache(chatId);

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

  /// Shared Ready wait (R72) — many openChat/ping callers join one poll.
  Completer<bool>? _waitMediaConnCompleter;
  DateTime? _waitMediaConnStartedAt;
  Timer? _waitMediaConnPoll;
  static const _waitMediaConnSharedCap = Duration(seconds: 90);

  /// Wait until TDLib can carry media/history bytes (Ready/Updating).
  Future<bool> _waitForMediaConnection({
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (_tdlibReadyForMedia) return true;
    var shared = _waitMediaConnCompleter;
    if (shared == null) {
      shared = Completer<bool>();
      _waitMediaConnCompleter = shared;
      _waitMediaConnStartedAt = DateTime.now();
      _mediaLog(
        'wait-media-conn start conn=$_connectionState '
        'timeout=${timeout.inSeconds}s shared=true',
      );
      _waitMediaConnPoll?.cancel();
      _waitMediaConnPoll = Timer.periodic(const Duration(milliseconds: 200), (
        t,
      ) {
        if (_tdlibReadyForMedia) {
          t.cancel();
          _completeWaitMediaConn(true);
          return;
        }
        final started = _waitMediaConnStartedAt;
        if (started != null &&
            DateTime.now().difference(started) >= _waitMediaConnSharedCap) {
          t.cancel();
          _mediaLog('wait-media-conn TIMEOUT conn=$_connectionState shared');
          _completeWaitMediaConn(false);
        }
      });
    } else {
      _mediaLog(
        'wait-media-conn join conn=$_connectionState '
        'timeout=${timeout.inSeconds}s',
      );
    }
    try {
      return await shared.future.timeout(
        timeout,
        onTimeout: () {
          _mediaLog(
            'wait-media-conn TIMEOUT (waiter) conn=$_connectionState '
            'timeout=${timeout.inSeconds}s',
          );
          return _tdlibReadyForMedia;
        },
      );
    } catch (_) {
      return _tdlibReadyForMedia;
    }
  }

  void _completeWaitMediaConn(bool ok) {
    _waitMediaConnPoll?.cancel();
    _waitMediaConnPoll = null;
    final c = _waitMediaConnCompleter;
    _waitMediaConnCompleter = null;
    final started = _waitMediaConnStartedAt;
    _waitMediaConnStartedAt = null;
    if (c == null) return;
    if (ok && started != null) {
      _mediaLog(
        'wait-media-conn ok after '
        '${_fmtDur(DateTime.now().difference(started))} '
        'conn=$_connectionState',
      );
    }
    if (!c.isCompleted) c.complete(ok);
  }

  /// Remove queued/inflight downloads that aren't exclusive-focus media.
  ///
  /// Foreign-chat `ensure` / stale tap jobs must die on open — otherwise they
  /// hold the FakeTLS slot for ~45s at 0B while the viewer shows minithumb
  /// (SessionLog: ensure chat=71606080 blocked Shariy tap:photo=16472).
  void _purgeNonFocusDownloads({int? keepChatId}) {
    final focus = _focusDownloadOrder.toSet();
    bool keepJob({required int? chatId, required String reason, required int fileId}) {
      // Foreign chat always drops — even if still listed in focus order
      // (r41_check: focus.contains kept channel file after openChat=DM).
      final foreign =
          keepChatId != null && chatId != null && chatId != keepChatId;
      if (foreign) return false;
      if (focus.contains(fileId)) return true;
      // R70: auto `voice:` / `tap:voice:` must survive purge while this chat
      // is open (chatId may be null during list rebuild — still keep).
      if (reason.contains('voice:')) return true;
      return reason.startsWith('focus:') ||
          reason.startsWith('focus-tail:') ||
          reason.startsWith('demoted-after-focus:') ||
          reason.startsWith('tap:') ||
          reason.startsWith('ensure') ||
          reason.startsWith('sheet-media') ||
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
    /// Hub warm must not pull a full channel window (boot lag: 201 local
    /// msgs for unread=1 while the UI is still painting).
    int? maxCountCap,
    int? maxAttemptsCap,
  }) async {
    final c = _client;
    if (c == null) return;

    final isChannel = isChannelChat(chatId);
    // preferLocal=true → only_local (fast). Otherwise remote when Ready.
    final onlyLocal = preferLocal ?? !_tdlibReadyForMedia;
    // Channels need many round-trips while TDLib pulls remote history.
    var maxAttempts = onlyLocal
        ? (isChannel ? 12 : 6)
        : (isChannel ? 40 : 20);
    if (maxAttemptsCap != null) {
      maxAttempts = maxAttempts.clamp(1, maxAttemptsCap);
    }
    final emptyLimit = onlyLocal
        ? (isChannel ? 4 : 2)
        : (isChannel ? 12 : 4);
    // Cap so a busy channel from the last 5 days can't run forever.
    var maxCount = isChannel ? 200 : 120;
    if (maxCountCap != null) {
      maxCount = maxCount.clamp(1, maxCountCap);
    }
    // Proxy path often stalls remote channel pages — keep per-call timeout
    // modest and retry instead of one 45s hang with seed=1 on screen.
    final callTimeout = Duration(
      seconds: onlyLocal ? 8 : (isChannel ? 18 : 20),
    );

    final byId = <int, TdlibMessage>{
      for (final m in _messagesByChat[chatId] ?? const []) m.id: m,
    };

    // Seed from chat.last_message so UI isn't empty while history loads.
    // Never clobber an already-painted row's local media paths (open blink).
    final last = _chats[chatId]?['last_message'];
    if (last is Map) {
      final lastMap = Map<String, dynamic>.from(last);
      lastMap.putIfAbsent('chat_id', () => chatId);
      final seeded = _parseMessage(lastMap);
      if (seeded != null) {
        final prev = byId[seeded.id];
        byId[seeded.id] = prev == null
            ? seeded
            : _mergePreservingLocalMedia(prev, seeded);
      }
    }
    if (byId.isNotEmpty) {
      _writeChatMessages(chatId, byId);
      // Coalesce — direct notifyListeners bypassed open quiet (Шарий hang).
      if (!silent) _notifyUi();
    }

    var fromMessageId = 0;
    var emptyStreak = 0;
    var stagnantStreak = 0;

    // R47: never overwrite history-page / freshly parsed rows with preserved
    // RAM copies — those keep pre-soft-restart file_ids → getFile 404 /
    // "File not found" on tap (SessionLog 00:39–00:40). Live updates that
    // only exist in RAM (arrived during await) still fill gaps.
    void mergeLiveIntoById() {
      for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[]) {
        byId.putIfAbsent(m.id, () => m);
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
          // Respect maxCountCap — channel warm used to request 100 and land
          // 50+ msgs in one page even when capped at 40.
          'limit': (maxCount - byId.length).clamp(
            1,
            isChannel ? 100 : 50,
          ),
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
        final prev = byId[msg.id];
        byId[msg.id] =
            prev == null ? msg : _mergePreservingLocalMedia(prev, msg);
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
    if (count > 1) {
      unawaited(_persistTranscriptCache(chatId));
    }
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

  void _armHubWarmBootGrace({required String why}) {
    final until = DateTime.now().add(_hubWarmBootGrace);
    if (_hubWarmNotBefore == null || until.isAfter(_hubWarmNotBefore!)) {
      _hubWarmNotBefore = until;
      _mediaLog(
        'hub-warm grace ${_fmtDur(_hubWarmBootGrace)} why=$why',
      );
    }
  }

  /// Coalesce boot / loadChats / unread updates into one deferred warm pass
  /// after hub first paint has settled.
  void scheduleHubWarmAfterBoot({String why = ''}) {
    if (!isReady) return;
    _hubWarmNotBefore ??= DateTime.now().add(_hubWarmBootGrace);
    final wait = _hubWarmNotBefore!.difference(DateTime.now());
    if (wait <= Duration.zero) {
      _runDeferredHubWarm(why: why);
      return;
    }
    if (_hubWarmPassScheduled) return;
    _hubWarmPassScheduled = true;
    _hubWarmDeferTimer?.cancel();
    _hubWarmDeferTimer = Timer(wait, () {
      _hubWarmDeferTimer = null;
      _hubWarmPassScheduled = false;
      _runDeferredHubWarm(why: 'deferred:$why');
    });
    _mediaLog('hub-warm defer ${_fmtDur(wait)} why=$why');
  }

  void _runDeferredHubWarm({String why = ''}) {
    if (!isReady) return;
    if (_openChatId != null) return;
    if (!_appInForeground) return;
    // SessionLog 20:42: hub-warm run → Skipped 418 (~3.5s). Candidate scan
    // called unreadCountFor (RAM transcript walk) for every hub row; with
    // SQLite tip paint, prefetch is unused — keep the timer as a no-op.
    if (warmHubChatLimit <= 0) {
      _mediaLog('hub-warm skip why=disabled:$why');
      return;
    }
    // Idle-gate: never fight hub list scroll / IME (SessionLog 20:17 Skipped 75).
    if (_deferMediaUiNotify) {
      _mediaLog('hub-warm defer idle-wait why=$why');
      _hubWarmPassScheduled = true;
      _hubWarmDeferTimer?.cancel();
      _hubWarmDeferTimer = Timer(const Duration(seconds: 2), () {
        _hubWarmDeferTimer = null;
        _hubWarmPassScheduled = false;
        _runDeferredHubWarm(why: 'idle-retry:$why');
      });
      return;
    }
    _mediaLog('hub-warm run why=$why');
    warmUnreadChatsFromHub(maxChats: warmHubChatLimit);
  }

  /// Prefetch local tip into SQLite for one unread DM/group on the hub.
  /// No remote pages / older walk — open paints from DB + ensureTip.
  Future<void> warmUnreadChatHistory(int chatId) async {
    if (chatId == 0 || !isReady) return;
    if (_openChatId == chatId) return;
    if (unreadCountFor(chatId) <= 0) return;
    // Channels: never hub-warm. getChatHistory pages are huge and fight first
    // paint / FakeTLS slot (SessionLog 09:12 channel 52 msgs @ boot).
    if (isChannelChat(chatId)) {
      _mediaLog('warm-history skip channel chat=$chatId');
      return;
    }
    if (_deferMediaUiNotify) {
      _mediaLog('warm-history defer ui-busy chat=$chatId');
      scheduleHubWarmAfterBoot(why: 'warm-idle:$chatId');
      return;
    }
    if (_historyWarmInFlight.contains(chatId)) return;
    final have = _messagesByChat[chatId]?.length ?? 0;
    final dbHave = await TgHistoryStore.instance.count(chatId);
    if ((isUnreadHistoryWarm(chatId) && have >= TgHistoryStore.tipPaintCap) ||
        dbHave >= TgHistoryStore.ensureTipMin) {
      _mediaLog(
        'warm-history skip chat=$chatId have=$have db=$dbHave',
      );
      return;
    }

    _historyWarmInFlight.add(chatId);
    _mediaLog(
      'warm-history start chat=$chatId unread=${unreadCountFor(chatId)} '
      'tip-only=1',
    );
    try {
      await _loadChatHistory(
        chatId,
        preferLocal: true,
        silent: true,
        maxCountCap: TgHistoryStore.tipPaintCap,
        maxAttemptsCap: 2,
      );
      // Batch SQLite write once (not per-row mid-page).
      final list = _messagesByChat[chatId];
      if (list != null && list.isNotEmpty) {
        unawaited(
          TgHistoryStore.instance.upsertMessages(
            chatId,
            list.length <= TgHistoryStore.tipPaintCap
                ? list
                : list.sublist(list.length - TgHistoryStore.tipPaintCap),
            chatType: _tgChatTypeLabel(chatId),
            title: peerTitle(chatId),
          ),
        );
      }
      _mediaLog(
        'warm-history done chat=$chatId '
        'msgs=${_messagesByChat[chatId]?.length ?? 0} '
        'warm=${isUnreadHistoryWarm(chatId)} tip-only=1',
      );
    } finally {
      _historyWarmInFlight.remove(chatId);
    }
  }

  void _enqueueHistoryWarm(int chatId) {
    _historyWarmChain = _historyWarmChain.catchError((_) {}).then((_) async {
      // Yield a frame between chats so hub list stays responsive.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (_deferMediaUiNotify) {
        scheduleHubWarmAfterBoot(why: 'chain-idle');
        return;
      }
      await warmUnreadChatHistory(chatId);
    });
  }

  /// Warm hub chats that already have unreads (after list load / new msgs).
  /// Local tip only — remote/open path fills the rest via ensureTip/ensureOlder.
  void warmUnreadChatsFromHub({int maxChats = 1}) {
    if (!isReady) return;
    if (maxChats <= 0) return;
    if (_hubWarmNotBefore != null &&
        DateTime.now().isBefore(_hubWarmNotBefore!)) {
      scheduleHubWarmAfterBoot(why: 'warmUnreadChatsFromHub');
      return;
    }
    if (_deferMediaUiNotify) {
      scheduleHubWarmAfterBoot(why: 'warmUnreadChatsFromHub-busy');
      return;
    }
    // DMs/groups only; serial — parallel getChatHistory fought hub paint.
    final pool = _unreadWarmCandidates(maxChats: maxChats);
    for (final c in pool) {
      _enqueueHistoryWarm(c.id);
    }
  }

  /// Cheap hub-warm pool: TDLib `unread_count` only — never [unreadCountFor]
  /// (that walks RAM transcripts for every row; SessionLog 20:42 Skipped 418).
  List<({int id, int unread})> _unreadWarmCandidates({required int maxChats}) {
    if (maxChats <= 0) return const [];
    final candidates = <({int id, int unread})>[];
    for (final id in _chatOrder) {
      if (_openChatId == id) continue;
      if (isChannelChat(id)) continue;
      final chat = _chats[id];
      if (chat == null) continue;
      final unread = _tdlibInt(chat['unread_count']);
      if (unread <= 0) continue;
      candidates.add((id: id, unread: unread));
      // Enough deep-unread picks — no need to scan the whole hub order.
      if (candidates.length >= maxChats * 4) break;
    }
    candidates.sort((a, b) {
      final aDeep = a.unread >= 2 ? 0 : 1;
      final bDeep = b.unread >= 2 ? 0 : 1;
      if (aDeep != bDeep) return aDeep.compareTo(bDeep);
      return b.unread.compareTo(a.unread);
    });
    if (candidates.length <= maxChats) return candidates;
    return candidates.sublist(0, maxChats);
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
  ///
  /// [lightPoll] — periodic UI timer: tip + unread only, one attempt, no
  /// history-page fanout (Шарий 4s poll → BUILD×N forever).
  Future<void> syncChatTail(
    int chatId, {
    int limit = 40,
    bool lightPoll = false,
  }) async {
    final c = _client;
    if (c == null || !isReady) return;
    try {
      final maxAttempts = lightPoll ? 1 : 8;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
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
            // Light poll: tip row only — skip soft field churn on older ids.
            if (seeded != null &&
                _upsertMessage(seeded, persistDb: !lightPoll)) {
              changed = true;
            }
          }
        }

        final tipMissing = expectedLastId != null &&
            expectedLastId > 0 &&
            !(_messagesByChat[chatId]?.any((m) => m.id == expectedLastId) ??
                false);

        // Light poll: tip row (+ getMessage if tip missing). No history page.
        if (!lightPoll) {
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
                if (msg != null && _upsertMessage(msg)) {
                  changed = true;
                }
              }
            }
          }
        }

        // Explicitly fetch the tip message if history page still lags.
        if (tipMissing) {
          try {
            final one = await c.sendAwait({
              '@type': 'getMessage',
              'chat_id': chatId,
              'message_id': expectedLastId,
            });
            if (one['@type'] == 'message') {
              final msg = _parseMessage(one);
              if (msg != null &&
                  _upsertMessage(msg, persistDb: !lightPoll)) {
                changed = true;
              }
            }
          } catch (_) {}
        }

        // Media for open chat is owned by history tip + viewport — not every
        // syncChatTail (that re-boosted inFlight downloads into a 0B stall).
        // Only a real change notifies, and through the coalescing gate.
        if (changed) _notifyUi();

        final haveTip = expectedLastId == null ||
            expectedLastId <= 0 ||
            (_messagesByChat[chatId]?.any((m) => m.id == expectedLastId) ??
                false);
        if (haveTip || lightPoll) break;

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
      // Keep first paint stable — ready-catchup used to load 200 channel msgs
      // with mid-load notifyListeners and freeze the open UI (Шарий 20:25).
      _armOpenChatUiQuiet(why: 'ready-catchup');
      final have = _messagesByChat[openId]?.length ?? 0;
      final tipCap = TgHistoryStore.tipPaintCap;
      // Soft-restart / Connecting→Ready: refill tip silently; grow on scroll.
      await _loadChatHistory(
        openId,
        preferLocal: true,
        silent: true,
        maxCountCap: have >= tipCap ? have.clamp(tipCap, 72) : tipCap,
        maxAttemptsCap: 4,
      );
      if (_tdlibReadyForMedia) {
        await _loadChatHistory(
          openId,
          preferLocal: false,
          silent: true,
          maxCountCap: tipCap,
          maxAttemptsCap: 3,
        );
      }
      await syncChatTail(openId);
      _touchOpenTranscriptPreserve(openId);
      // One coalesced paint after catchup (quiet may still hold).
      _notifyUi();
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
        '${_messagesByChat[openId]?.length ?? 0} silent=true',
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
    // FakeTLS: keep a tiny ±1 band (not full ±4). Full radius flooded mtg
    // with domain-fronting (A/B 16:38); ±1 still serial behind focus (slot=1).
    final effectiveRadius =
        _enabledProxyId != null ? viewportMediaRadiusProxy : radius;
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

  /// User-driven media (tap / its stall ladder) must keep the FakeTLS slot.
  /// Ostashko SessionLog 10:41: focus thumb `yield soft=15860` canceled
  /// `stall-lastchance` of tap:video — photos OK, video body forever 0B.
  bool _isProtectedUserMediaReason(String reason) {
    if (reason.startsWith('tap:')) return true;
    if (reason.startsWith('stream:video:')) return true;
    if (reason.startsWith('stall-retry:tap:')) return true;
    if (reason.startsWith('stall-fallback:tap:')) return true;
    if (reason.startsWith('stall-lastchance:')) return true;
    if (reason.startsWith('auto:video:')) return true;
    if (reason.startsWith('stall-retry:auto:video:')) return true;
    return false;
  }

  bool _userTapMediaHoldsWire() {
    for (final id in _downloadInFlight) {
      final r = _downloadTrace[id]?.reason ?? '';
      if (_isProtectedUserMediaReason(r)) return true;
    }
    for (final j in _downloadQueue) {
      if (_isProtectedUserMediaReason(j.reason)) return true;
    }
    return false;
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
      // Never cancel tap:video / lastchance / auto:video for a focus thumb.
      if (_isProtectedUserMediaReason(reason)) continue;
      final zeroBytes = (t?.lastBytes ?? 0) <= 0;
      // Under proxy: cancel 0B focus so the tapped file can start.
      if (_enabledProxyId != null &&
          zeroBytes &&
          (reason.startsWith('focus:') ||
              reason.startsWith('focus-tail:') ||
              reason.startsWith('focus-upgrade:') ||
              reason.startsWith('stall-fallback:') ||
              reason.startsWith('stall-retry:focus') ||
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
    // FakeTLS allows only the ±1 band from prefetchOpenChatViewport
    // (pending list already capped). Do not hard-skip here.
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
      // Stale hold from a previous chat — never block the new open chat.
      final heldInThisChat =
          _messagesByChat[chatId]?.any((m) => m.id == held) ?? false;
      if (!heldInThisChat) {
        _clearFocusMediaClaim(why: 'focus-hold-stale-chat:$held');
      } else if (!_focusMediaBusy()) {
        // R43: held bubble already local / idle — do not block scroll siblings.
        _focusHoldUntil = null;
        _mediaLog('focus-hold clear why=focus-hold-idle:$held');
      } else if (_sameMediaAlbum(chatId, held, messageId)) {
        // R44: viewport landed on another cell of the same album — tails are
        // already in the exclusive queue; do not thrash openMessageContent.
        return;
      } else {
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
    }

    var idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) {
      // SQLite UI / viewport can name a msg not yet in RAM after soft-restart.
      // One getMessage upsert — do not spam focus_miss every layout tick
      // (SessionLog 21:00–21:20: focus_miss×80 while WFN).
      final lastMissAt = _focusMissAt[messageId];
      final now = DateTime.now();
      if (lastMissAt != null &&
          now.difference(lastMissAt) < const Duration(seconds: 4)) {
        return;
      }
      _focusMissAt[messageId] = now;
      // RAM already has the window — snap to nearest light media instead of
      // getMessage storms (focus_miss every ~1.4s on a live 200-msg chat).
      var best = -1;
      var bestDelta = 1 << 62;
      for (var i = 0; i < list.length; i++) {
        if (!_messageHasLightMedia(list[i])) continue;
        final d = (list[i].id - messageId).abs();
        if (d < bestDelta) {
          bestDelta = d;
          best = i;
        }
      }
      if (best >= 0) {
        idx = best;
        messageId = list[best].id;
      } else {
        _slog('tg.media', 'focus_miss', {
          'chatId': chatId,
          'msgId': messageId,
          'force': force,
        });
        if (isReady && _client != null) {
          unawaited(() async {
            try {
              final raw = await _client!.sendAwait({
                '@type': 'getMessage',
                'chat_id': chatId,
                'message_id': messageId,
              }, timeout: const Duration(seconds: 8));
              if (raw['@type'] != 'message') return;
              final map = Map<String, dynamic>.from(raw);
              map.putIfAbsent('chat_id', () => chatId);
              final msg = _parseMessage(map);
              if (msg == null) return;
              _upsertMessage(msg);
              if (_openChatId == chatId) {
                focusVisibleMessageMedia(
                  chatId: chatId,
                  messageId: messageId,
                  force: force,
                );
              }
            } catch (_) {}
          }());
        }
        return;
      }
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

    // Same focus / same album already claimed — do NOT re-open while busy.
    // Idle rescan was spamming open+view every ~1s and starving FakeTLS media
    // (Shariy SessionLog 22:11: open/view 30× while downloadFile sat at 0B).
    // R43: only refresh the exclusive hold while focus work is still busy —
    // re-arming +45s after disk/net complete blocked every sibling preview.
    // R44: when idle but album siblings still need preview, fall through and
    // re-enqueue (focus-cap used to drop tails; same-focus then stuck forever).
    final sameAlbumAsFocus = _focusMessageId != null &&
        _sameMediaAlbum(chatId, _focusMessageId!, messageId);
    if (_focusMessageId == messageId || sameAlbumAsFocus) {
      if (_focusMediaBusy()) {
        _focusHoldUntil = DateTime.now().add(
          Duration(seconds: _enabledProxyId != null ? 45 : 8),
        );
        return;
      }
      final albumMembers = _albumMembersAround(list, idx);
      // Only re-enqueue when some album cell still has no local preview file.
      // Soft-but-not-sharp (cached m <40KB) must not loop forever here.
      if (!albumMembers.any(_memberHasUncachedPreviewWork)) {
        return;
      }
      // Fall through — re-queue remaining album siblings.
    }

    final focus = list[idx];
    final members = _albumMembersAround(list, idx);

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
      if (_mediaGiveUpFileIds.contains(id)) return;
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
      // R45/R46: typed x/y/w → wire primary only. Soft `m` on disk still paints
      // via resolvedPhotoPath; wiring soft under FakeTLS often 0B×12s and
      // blocks the album sibling sharp (Yandex album 14613 give-up).
      final primary = m.photoRemoteId;
      final typedSharp = m.photoSizeType == 'x' ||
          m.photoSizeType == 'y' ||
          m.photoSizeType == 'w';
      if (typedSharp && primary != null && primary > 0) {
        if (_hasUsablePhotoCached(primary, minBytes: 3 * 1024)) {
          final path = _filePathCache[primary]!;
          final patched = _messageWithDownloadedFile(m, primary, path);
          if (patched != null) {
            _upsertMessage(patched);
            notifyListeners();
          }
          return;
        }
        if (_mediaGiveUpFileIds.contains(primary)) return;
        if (_hasCachedPath(primary) &&
            !_hasUsablePhotoCached(primary, minBytes: 3 * 1024)) {
          _filePathCache.remove(primary);
        }
        addId(primary);
        return;
      }
      final up = _photoUpgradeFileId(m);
      if (up == null) return;
      if (_mediaGiveUpFileIds.contains(up)) return;
      if (_hasSharpPhotoCached(up)) {
        final path = _filePathCache[up]!;
        final patched = _messageWithDownloadedFile(m, up, path);
        if (patched != null) {
          _upsertMessage(patched);
          notifyListeners();
        }
        return;
      }
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

    // R71: under FakeTLS post soft-restart, queue head only until one net
    // `done` proves RELAY — tails opened ~300ms later were DF (mtg 20:21:48).
    // After that done (+ cool), idle same-album re-enqueue picks up tails.
    if (ordered.length > 1 && _deferFocusTailsAfterRestart) {
      _mediaLog(
        'focus-album-queue defer-tails (post-restart) '
        'msg=$messageId keep=${ordered.first} '
        'deferred=${ordered.sublist(1)}',
      );
      ordered.removeRange(1, ordered.length);
    }

    // R44: keep full album / multi-file focus order. FakeTLS slotLimit=1
    // already serializes the wire — the old focus-cap→1 dropped siblings and
    // left gallery cells on minithumb forever (same-focus never re-queued).
    if (ordered.length > 1) {
      _mediaLog(
        'focus-album-queue msg=$messageId files=${ordered.length} '
        'head=${ordered.first} tail=${ordered.sublist(1)}',
      );
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
  /// Already-read viewMessages throttle (idle focus re-fired every ~8–15s).
  String? _lastViewMessagesKey;
  DateTime? _lastViewMessagesAt;
  /// R72: while !Ready, keep one pending open (official does not spam media
  /// RPCs while network paused). Flush on Ready.
  ({int chatId, int messageId, bool force})? _pendingOpenMessageContent;
  String? _lastOpenMessageContentDeferKey;
  DateTime? _lastOpenMessageContentDeferLogAt;

  /// Helps TDLib authorize CDN access for channel media (esp. through proxy).
  ///
  /// [force] — tap:video must re-open even if focus already opened the same
  /// message within 8s (R49: debounce skipped open → Ready+0B video body).
  Future<void> _openMessageContent(
    int chatId,
    int messageId, {
    bool force = false,
  }) async {
    final c = _client;
    if (c == null || messageId <= 0) return;
    // open/view while Connecting floods FakeTLS before media DCs are up
    // (Shariy: 15s of openMessageContent spam, then Ready + 0B downloads).
    // R72: coalesce — one pending + rare log; flush when Ready lands.
    if (!_tdlibReadyForMedia) {
      final prev = _pendingOpenMessageContent;
      _pendingOpenMessageContent = (
        chatId: chatId,
        messageId: messageId,
        force: force || (prev?.force ?? false),
      );
      final key = '$chatId:$messageId';
      final now = DateTime.now();
      final lastLog = _lastOpenMessageContentDeferLogAt;
      if (_lastOpenMessageContentDeferKey != key ||
          lastLog == null ||
          now.difference(lastLog) >= const Duration(seconds: 5)) {
        _lastOpenMessageContentDeferKey = key;
        _lastOpenMessageContentDeferLogAt = now;
        _mediaLog(
          'openMessageContent defer chat=$chatId msg=$messageId '
          'conn=$_connectionState',
        );
      }
      return;
    }
    final key = '$chatId:$messageId';
    final lastAt = _lastOpenMessageContentAt;
    if (!force &&
        _lastOpenMessageContentKey == key &&
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
      // until viewMessages. But with the chat open, viewMessages(id) marks
      // everything ≤ id as read — focus/prefetch on tip wiped the unread gap
      // while the user was still at the frontier.
      // Already-read: view for CDN auth. Unread: only on force (user tap);
      // progressive viewport mark-read covers the rest.
      // Multi-unread open gate: ignore force until the user releases it.
      final allowForceView = force && !_blockUnreadForceView;
      final lastRead = _effectiveLastReadInbox(chatId);
      final liveUnread = unreadCountFor(chatId);
      // Any live unread: never tip-view for CDN while the pack is open.
      // Cold boot + tip focus used to pass messageId<=lastRead (stale floor)
      // and wipe unread_count (Осташко 08:26 viewMessages ok tip).
      if (!allowForceView && (messageId > lastRead || liveUnread > 0)) {
        _mediaLog(
          'viewMessages skip unread chat=$chatId msg=$messageId '
          'lastRead=$lastRead liveUnread=$liveUnread'
          '${force && _blockUnreadForceView ? ' (unread-gate)' : ''}',
        );
      } else {
        // Already-read CDN auth once per message — idle focus/rescan used to
        // re-view every ~8–15s (Шарий SessionLog 19:28–19:34).
        final now = DateTime.now();
        final lastVmAt = _lastViewMessagesAt;
        if (!allowForceView &&
            _lastViewMessagesKey == key &&
            lastVmAt != null &&
            now.difference(lastVmAt) < const Duration(seconds: 60)) {
          return;
        }
        try {
          await c.sendAwait({
            '@type': 'viewMessages',
            'chat_id': chatId,
            'message_ids': [messageId],
            'source': {'@type': 'messageSourceChatHistory'},
            'force_read': false,
          }, timeout: const Duration(seconds: 5));
          _lastViewMessagesKey = key;
          _lastViewMessagesAt = now;
          _mediaLog('viewMessages ok chat=$chatId msg=$messageId');
        } catch (e) {
          _mediaLog(
            'viewMessages soft-fail chat=$chatId msg=$messageId err=$e',
          );
        }
      }
    } catch (e) {
      _mediaLog('openMessageContent err chat=$chatId msg=$messageId err=$e');
    }
  }

  /// R72: run the one deferred open after WFN/Connecting → Ready.
  void _flushPendingOpenMessageContent() {
    final p = _pendingOpenMessageContent;
    if (p == null) return;
    _pendingOpenMessageContent = null;
    if (!_tdlibReadyForMedia || _client == null) return;
    _mediaLog(
      'openMessageContent flush-pending chat=${p.chatId} msg=${p.messageId} '
      'force=${p.force}',
    );
    unawaited(
      _openMessageContent(p.chatId, p.messageId, force: p.force),
    );
  }

  Future<void> _openMessageContentForFile(
    int chatId,
    int fileId, {
    bool force = false,
  }) async {
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
        await _openMessageContent(chatId, m.id, force: force);
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
    // R46: declared `x`/`y`/`w` primary on disk is the bubble target — sizes
    // are often 20–35KB (`_120.jpg`), below the old 40KB soft-upgrade bar
    // (album cell 2: 35.5KB done but spinner forever).
    if (type == 'x' || type == 'y' || type == 'w') {
      final primary = m.photoRemoteId;
      if (primary != null &&
          primary > 0 &&
          _hasUsablePhotoCached(primary, minBytes: 3 * 1024)) {
        return true;
      }
      // R47b: soft-restart cleared RAM file_id cache; stamped local path on
      // the preserved message is still the on-disk file — do not spin/re-wire.
      // Progressive JPEG prefixes also stamp photoLocalPath — those must NOT
      // count as sharp or focus stops the real download mid-file.
      final local = m.photoLocalPath;
      if (local != null &&
          local.isNotEmpty &&
          _isPaintReadyMediaPath(local) &&
          (primary == null || _progressivePaintPath[primary] != local)) {
        return true;
      }
      return false;
    }
    final path = resolvedPhotoPath(m);
    if (path == null || path.isEmpty) return false;
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

    // Remember focus for openMessageContent / lastchance msg id, but do not
    // enqueue thumbs or yield while tap:video holds the exclusive slot.
    if (_userTapMediaHoldsWire()) {
      _mediaLog(
        'focus-defer tap-hold msg=$messageId files=$ordered '
        '${_downloadQueueStats()}',
      );
      notifyListeners();
      return;
    }

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
    // when slots free mid-await. Never drop tap / lastchance ladder.
    final dropped = _downloadQueue
        .where(
          (j) =>
              !want.contains(j.fileId) &&
              j.reason != 'ensure' &&
              !_isProtectedUserMediaReason(j.reason),
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
    final existing = _messagesByChat[chatId] ?? const <TdlibMessage>[];
    if (existing.isEmpty) {
      await _loadChatHistory(chatId, silent: silent);
      return _messagesByChat[chatId]?.length ?? 0;
    }
    return loadOlderMessagesForDb(
      chatId,
      beforeMessageId: existing.first.id,
      pageSize: pageSize,
      silent: silent,
    );
  }

  /// Tip fill for [TgHistoryStore.ensureTip] — silent, capped (~20).
  Future<void> loadTipHistoryForDb(int chatId, {int maxCount = 20}) async {
    final cap = maxCount.clamp(8, 48);
    await _loadChatHistory(
      chatId,
      preferLocal: true,
      silent: true,
      maxCountCap: cap,
      maxAttemptsCap: 3,
    );
    if (_tdlibReadyForMedia) {
      await _loadChatHistory(
        chatId,
        preferLocal: false,
        silent: true,
        maxCountCap: cap,
        maxAttemptsCap: 2,
      );
    }
  }

  /// Older page for DB writer (from [beforeMessageId], not RAM tip).
  Future<int> loadOlderMessagesForDb(
    int chatId, {
    required int beforeMessageId,
    int pageSize = 40,
    bool silent = true,
  }) async {
    final c = _client;
    if (c == null || !isReady || beforeMessageId <= 0) return 0;
    final isChannel = isChannelChat(chatId);
    final onlyLocal = !_tdlibReadyForMedia;
    final beforeIds = {
      for (final m in _messagesByChat[chatId] ?? const <TdlibMessage>[]) m.id,
    };
    final retries = onlyLocal ? 2 : (isChannel ? 8 : 1);
    var added = 0;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final res = await c.sendAwait({
          '@type': 'getChatHistory',
          'chat_id': chatId,
          'from_message_id': beforeMessageId,
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
        final page = <TdlibMessage>[];
        for (final raw in list) {
          if (raw is! Map) continue;
          final map = raw is Map<String, dynamic>
              ? raw
              : Map<String, dynamic>.from(raw);
          map.putIfAbsent('chat_id', () => chatId);
          final msg = _parseMessage(map);
          if (msg == null) continue;
          _upsertMessage(msg, persistDb: false);
          page.add(msg);
          if (!beforeIds.contains(msg.id)) newly.add(msg);
        }
        _persistDbMessagesBatch(chatId, page);
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
        debugPrint('[tdlib] loadOlderMessagesForDb failed: $e');
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
  /// Keep painted disk paths when a fresher TDLib row omits them.
  ///
  /// `openChat` / `getChatHistory` often re-seed `chat.last_message` without
  /// local file paths — a blind replace made photo bubbles flash empty then
  /// repaint (Киса DM open blink).
  TdlibMessage _mergePreservingLocalMedia(
    TdlibMessage before,
    TdlibMessage after,
  ) {
    String? keep(String? prev, String? next) {
      if (next != null && next.isNotEmpty) return next;
      if (prev != null && prev.isNotEmpty) return prev;
      return next;
    }

    final photoPath = keep(before.photoLocalPath, after.photoLocalPath);
    final voicePath = keep(before.voiceLocalPath, after.voiceLocalPath);
    final videoPath = keep(before.videoLocalPath, after.videoLocalPath);
    final videoThumbPath =
        keep(before.videoThumbLocalPath, after.videoThumbLocalPath);
    final videoNotePath =
        keep(before.videoNoteLocalPath, after.videoNoteLocalPath);
    final videoNoteThumbPath =
        keep(before.videoNoteThumbLocalPath, after.videoNoteThumbLocalPath);
    final documentPath =
        keep(before.documentLocalPath, after.documentLocalPath);
    final documentThumbPath =
        keep(before.documentThumbLocalPath, after.documentThumbLocalPath);

    final same = identical(photoPath, after.photoLocalPath) &&
        identical(voicePath, after.voiceLocalPath) &&
        identical(videoPath, after.videoLocalPath) &&
        identical(videoThumbPath, after.videoThumbLocalPath) &&
        identical(videoNotePath, after.videoNoteLocalPath) &&
        identical(videoNoteThumbPath, after.videoNoteThumbLocalPath) &&
        identical(documentPath, after.documentLocalPath) &&
        identical(documentThumbPath, after.documentThumbLocalPath);
    if (same) return after;

    return _copyMessage(
      after,
      photoLocalPath: photoPath,
      voiceLocalPath: voicePath,
      videoLocalPath: videoPath,
      videoThumbLocalPath: videoThumbPath,
      videoNoteLocalPath: videoNotePath,
      videoNoteThumbLocalPath: videoNoteThumbPath,
      documentLocalPath: documentPath,
      documentThumbLocalPath: documentThumbPath,
    );
  }

  bool _upsertMessage(TdlibMessage msg, {bool persistDb = true}) {
    final list = _messagesByChat.putIfAbsent(msg.chatId, () => []);
    final idx = list.indexWhere((m) => m.id == msg.id);
    TdlibMessage stored;
    var changed = true;
    if (idx >= 0) {
      final prev = list[idx];
      final merged = _mergePreservingLocalMedia(prev, msg);
      list[idx] = merged;
      stored = merged;
      changed = prev.uiFingerprint != merged.uiFingerprint;
    } else {
      list.add(msg);
      list.sort((a, b) => a.id.compareTo(b.id));
      stored = msg;
    }
    if (persistDb) {
      unawaited(
        TgHistoryStore.instance.upsertMessage(
          stored,
          chatType: _tgChatTypeLabel(stored.chatId),
          title: peerTitle(stored.chatId),
        ),
      );
    }
    return changed;
  }

  void _persistDbMessagesBatch(int chatId, List<TdlibMessage> messages) {
    if (messages.isEmpty) return;
    unawaited(
      TgHistoryStore.instance.upsertMessages(
        chatId,
        messages,
        chatType: _tgChatTypeLabel(chatId),
        title: peerTitle(chatId),
      ),
    );
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
    if (oldId != msg.id) {
      unawaited(TgHistoryStore.instance.deleteMessages(chatId, [oldId]));
    }
    unawaited(
      TgHistoryStore.instance.upsertMessage(
        msg,
        chatType: _tgChatTypeLabel(chatId),
        title: peerTitle(chatId),
      ),
    );
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
        'unread': unreadCountFor(chatId),
      });
      // Persist before clearing open ownership so cold start paints a window.
      unawaited(_persistTranscriptCache(chatId));
      _openChatId = null;
      _activeOpenToken = null;
      _openChatNearTip = true;
      _blockUnreadForceView = false;
      _openChatUiQuietUntil = null;
      _openChatPostQuietUntil = null;
      _openChatQuietFlushTimer?.cancel();
      _openChatQuietFlushTimer = null;
      AppSessionDiagnostics.instance.setTgOpenChat(null);
      _openTranscriptPreserve.remove(chatId);
      // Drop open-session optimistic unread; re-pull TDLib row for hub badge.
      unawaited(refreshChatSnapshots([chatId]));
      // Free FakeTLS slot — leftover tap:photo must not block hub-avatar
      // (SessionLog 21:11: hub faces waited ~50s behind zombie tap:photo).
      _purgeConversationWireForHub();
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
    List<int>? bytes,
  }) async {
    final c = _client;
    if (c == null) return;
    final staged = await stageLocalFileForTdlib(
      localPath: localPath,
      bytes: bytes,
      filename: p.basename(localPath),
    );
    _mediaLog(
      'sendPhoto chat=$chatId path=${p.basename(staged)} '
      'src=${p.basename(localPath)}',
    );
    try {
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
            'path': staged,
          },
          if (caption.isNotEmpty)
            'caption': {
              '@type': 'formattedText',
              'text': caption,
            },
        },
      });
    } on TdlibApiException catch (e) {
      _mediaLog('sendPhoto FAIL chat=$chatId code=${e.code} ${e.message}');
      _slog('tg.send', 'photo_fail', {
        'chatId': chatId,
        'code': e.code,
        'message': e.message,
      });
      rethrow;
    }
  }

  Future<void> sendVideo(
    int chatId,
    String localPath, {
    String caption = '',
    int? replyToMessageId,
    List<int>? bytes,
  }) async {
    final c = _client;
    if (c == null) return;
    final staged = await stageLocalFileForTdlib(
      localPath: localPath,
      bytes: bytes,
      filename: p.basename(localPath),
    );
    _mediaLog(
      'sendVideo chat=$chatId path=${p.basename(staged)} '
      'src=${p.basename(localPath)}',
    );
    try {
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
            'path': staged,
          },
          if (caption.isNotEmpty)
            'caption': {
              '@type': 'formattedText',
              'text': caption,
            },
        },
      });
    } on TdlibApiException catch (e) {
      _mediaLog('sendVideo FAIL chat=$chatId code=${e.code} ${e.message}');
      _slog('tg.send', 'video_fail', {
        'chatId': chatId,
        'code': e.code,
        'message': e.message,
      });
      rethrow;
    }
  }

  Future<void> sendDocument(
    int chatId,
    String localPath, {
    String caption = '',
    int? replyToMessageId,
    List<int>? bytes,
  }) async {
    final c = _client;
    if (c == null) return;
    final staged = await stageLocalFileForTdlib(
      localPath: localPath,
      bytes: bytes,
      filename: p.basename(localPath).isNotEmpty
          ? p.basename(localPath)
          : 'file.bin',
    );
    _mediaLog(
      'sendDocument chat=$chatId path=${p.basename(staged)} '
      'src=${p.basename(localPath)}',
    );
    try {
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
            'path': staged,
          },
          if (caption.isNotEmpty)
            'caption': {
              '@type': 'formattedText',
              'text': caption,
            },
        },
      });
    } on TdlibApiException catch (e) {
      _mediaLog(
        'sendDocument FAIL chat=$chatId code=${e.code} ${e.message}',
      );
      _slog('tg.send', 'document_fail', {
        'chatId': chatId,
        'code': e.code,
        'message': e.message,
      });
      rethrow;
    }
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
    // Camera mp4 is typically 720×480 — TDLib requires square ≤640.
    final prepared = await TdlibVideoNotePrep.prepareSquare(localPath);
    _mediaLog(
      'sendVideoNote chat=$chatId path=${p.basename(prepared.path)} '
      'length=${prepared.length} duration=${durationSec}s '
      'src=${p.basename(localPath)}',
    );
    try {
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
            'path': prepared.path,
          },
          'duration': durationSec,
          'length': prepared.length,
        },
      });
    } on TdlibApiException catch (e) {
      _mediaLog(
        'sendVideoNote FAIL chat=$chatId code=${e.code} ${e.message}',
      );
      _slog('tg.send', 'video_note_fail', {
        'chatId': chatId,
        'code': e.code,
        'message': e.message,
      });
      rethrow;
    }
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
    _mediaLog(
      'sendVoiceNote chat=$chatId path=${p.basename(localPath)} '
      'duration=${durationSec}s',
    );
    try {
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
          // Empty waveform — TDLib/server fills for small notes.
          'waveform': '',
        },
      });
    } on TdlibApiException catch (e) {
      _mediaLog(
        'sendVoiceNote FAIL chat=$chatId code=${e.code} ${e.message}',
      );
      _slog('tg.send', 'voice_note_fail', {
        'chatId': chatId,
        'code': e.code,
        'message': e.message,
      });
      rethrow;
    }
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

  /// Stage a path/bytes into an app-owned `tdlib_upload_*` file.
  ///
  /// Same class of fix as voice (always materialize) / video-note prep:
  /// Android SAF / MediaStore / file_picker paths often `exists` for Dart but
  /// TDLib native `fopen` → 400.
  Future<String> stageLocalFileForTdlib({
    String? localPath,
    List<int>? bytes,
    required String filename,
  }) async {
    if (bytes != null && bytes.isNotEmpty) {
      return materializeTempFile(bytes: bytes, filename: filename);
    }
    final srcPath = localPath?.trim() ?? '';
    if (srcPath.isEmpty) {
      throw StateError('No local file for TDLib upload');
    }
    final src = File(srcPath);
    if (!await src.exists()) {
      throw StateError('Local file missing for TDLib upload');
    }
    final base = p.basename(srcPath);
    if (base.startsWith('tdlib_upload_')) {
      return srcPath;
    }
    final dir = await getTemporaryDirectory();
    final safe = filename.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final name = safe.isEmpty ? 'file.bin' : safe;
    final dest = File(
      p.join(
        dir.path,
        'tdlib_upload_${DateTime.now().microsecondsSinceEpoch}_$name',
      ),
    );
    await src.copy(dest.path);
    return dest.path;
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
    unawaited(TgHistoryStore.instance.deleteMessages(chatId, messageIds));
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

  // --- SaluteSpeech voice → text (@smartspeech_sber_bot) ---

  Future<bool> hasSmartSpeechConsent() => TdlibSmartSpeech.hasConsent();

  Future<void> setSmartSpeechConsent(bool value) =>
      TdlibSmartSpeech.setConsent(value);

  String? voiceTranscriptText(int chatId, int messageId) {
    if (!_voiceTranscriptsLoaded) {
      unawaited(_ensureVoiceTranscriptsLoaded().then((_) {
        if (_voiceTranscripts.isNotEmpty) notifyListeners();
      }));
    }
    final key = TdlibSmartSpeech.transcriptKey(chatId, messageId);
    final t = _voiceTranscripts[key];
    if (t == null || t.isEmpty) return null;
    // Never paint status/system blurbs (poisoned cache from early ack).
    if (TdlibSmartSpeech.isStatusAck(t) ||
        TdlibSmartSpeech.isBotSystemBlurb(t)) {
      _voiceTranscripts.remove(key);
      unawaited(_persistVoiceTranscripts());
      return null;
    }
    return t;
  }

  bool isVoiceTranscriptPending(int chatId, int messageId) =>
      _voiceTranscriptPending.contains(
        TdlibSmartSpeech.transcriptKey(chatId, messageId),
      );

  bool isSmartSpeechBotChat(int chatId) {
    if (chatId <= 0) return false;
    if (_smartSpeechBotChatId == chatId) return true;
    final chat = _chats[chatId];
    if (chat == null) return false;
    final type = chat['type'];
    if (type is! Map || type['@type']?.toString() != 'chatTypePrivate') {
      return false;
    }
    final userId = _tdlibInt(type['user_id']);
    return _isSmartSpeechBotUser(userId, _users[userId]);
  }

  bool _isSmartSpeechBotUser(int userId, Map<String, dynamic>? user) {
    if (userId <= 0) return false;
    if (user == null) return false;
    final u = _tdlibUsernameFromUser(user).toLowerCase();
    return u == TdlibSmartSpeech.botUsername;
  }

  Future<void> _ensureVoiceTranscriptsLoaded() async {
    if (_voiceTranscriptsLoaded) return;
    _voiceTranscriptsLoaded = true;
    final loaded = await TdlibSmartSpeech.loadTranscripts();
    _voiceTranscripts
      ..clear()
      ..addAll(loaded);
    // Drop any in-RAM status leftovers from before filter.
    final before = _voiceTranscripts.length;
    _voiceTranscripts.removeWhere(
      (_, v) =>
          TdlibSmartSpeech.isStatusAck(v) ||
          TdlibSmartSpeech.isBotSystemBlurb(v),
    );
    if (_voiceTranscripts.length != before) {
      unawaited(_persistVoiceTranscripts());
    }
  }

  Future<void> _persistVoiceTranscripts() async {
    await TdlibSmartSpeech.saveTranscripts(
      Map<String, String>.from(_voiceTranscripts),
    );
  }

  /// Forward [messageId] voice to SaluteSpeech and return the bot's text.
  ///
  /// Throws [TdlibSmartSpeechNeedConsent] when the user has not accepted yet.
  Future<String?> requestVoiceTranscript({
    required int chatId,
    required int messageId,
  }) async {
    if (chatId <= 0 || messageId <= 0 || !isReady) return null;
    await _ensureVoiceTranscriptsLoaded();
    final key = TdlibSmartSpeech.transcriptKey(chatId, messageId);
    final existing = _voiceTranscripts[key];
    if (existing != null && existing.isNotEmpty) {
      // Purge accidental status/system cache (SessionLog 09:13 chars=23).
      if (!TdlibSmartSpeech.isStatusAck(existing) &&
          !TdlibSmartSpeech.isBotSystemBlurb(existing)) {
        return existing;
      }
      _voiceTranscripts.remove(key);
      unawaited(_persistVoiceTranscripts());
    }
    if (!await hasSmartSpeechConsent()) {
      throw TdlibSmartSpeechNeedConsent();
    }

    // Serialize — one bot dialog wait at a time.
    while (_smartSpeechJob != null) {
      try {
        await _smartSpeechJob;
      } catch (_) {}
    }
    final gate = Completer<void>();
    _smartSpeechJob = gate.future;
    _voiceTranscriptPending.add(key);
    notifyListeners();
    try {
      final botChatId = await _ensureSmartSpeechBotChat();
      if (botChatId == null || botChatId <= 0) {
        _mediaLog('smartspeech ensure-bot fail');
        return null;
      }
      // Baseline so we ignore pre-forward bot history / ack-only lines.
      final prior = await fetchRecentChatMessages(botChatId, limit: 8);
      var afterId = 0;
      for (final m in prior) {
        if (m.id > afterId) afterId = m.id;
      }
      _smartSpeechAfterMsgId = afterId;
      final replyFuture = _armSmartSpeechReplyWaiter();
      await _smartSpeechOpenBotChat(botChatId);
      _mediaLog(
        'smartspeech forward chat=$chatId msg=$messageId → bot=$botChatId '
        'afterMsg=$afterId',
      );
      await forwardMessages(
        fromChatId: chatId,
        messageIds: [messageId],
        toChatId: botChatId,
      );
      // SessionLog 09:23: ack via updateNewMessage, real text only via push —
      // poll getChatHistory until a non-status body appears.
      unawaited(_pollSmartSpeechReply(botChatId, afterMsgId: afterId));
      final raw = await replyFuture.timeout(const Duration(seconds: 90));
      final cleaned = TdlibSmartSpeech.cleanReplyText(raw);
      if (cleaned.isEmpty) {
        _mediaLog('smartspeech empty-reply chat=$chatId msg=$messageId');
        return null;
      }
      _voiceTranscripts[key] = cleaned;
      unawaited(_persistVoiceTranscripts());
      _mediaLog(
        'smartspeech ok chat=$chatId msg=$messageId '
        'chars=${cleaned.length}',
      );
      return cleaned;
    } on TimeoutException {
      _mediaLog('smartspeech timeout chat=$chatId msg=$messageId');
      return null;
    } catch (e) {
      if (e is TdlibSmartSpeechNeedConsent) rethrow;
      _mediaLog('smartspeech fail chat=$chatId msg=$messageId err=$e');
      return null;
    } finally {
      _voiceTranscriptPending.remove(key);
      unawaited(_smartSpeechCloseBotChat());
      _smartSpeechAfterMsgId = 0;
      if (!gate.isCompleted) gate.complete();
      if (identical(_smartSpeechJob, gate.future)) {
        _smartSpeechJob = null;
      }
      notifyListeners();
    }
  }

  Future<String> _armSmartSpeechReplyWaiter() {
    final prev = _smartSpeechReplyCompleter;
    if (prev != null && !prev.isCompleted) {
      prev.completeError(StateError('smartspeech waiter replaced'));
    }
    final next = Completer<String>();
    _smartSpeechReplyCompleter = next;
    return next.future;
  }

  bool _isSmartSpeechTranscriptCandidate(TdlibMessage msg) {
    if (msg.isOutgoing || msg.isService) return false;
    if (msg.isVoiceNote ||
        msg.isVideoNote ||
        msg.isPhoto ||
        msg.isVideo ||
        msg.isSticker ||
        msg.isAnimation) {
      return false;
    }
    // Document/file placeholders from [_parseMessage] are not transcripts.
    if (msg.documentFileId != null) {
      final t = msg.text.trim();
      if (t.startsWith('Файл') || t.startsWith('🎵')) return false;
    }
    final cleaned = TdlibSmartSpeech.cleanReplyText(msg.text);
    return cleaned.isNotEmpty;
  }

  void _completeSmartSpeechWaiter(String text, {required String why}) {
    final waiter = _smartSpeechReplyCompleter;
    if (waiter == null || waiter.isCompleted) return;
    final cleaned = TdlibSmartSpeech.cleanReplyText(text);
    if (cleaned.isEmpty) return;
    _mediaLog(
      'smartspeech reply why=$why chars=${cleaned.length} '
      'preview=${cleaned.length > 48 ? cleaned.substring(0, 48) : cleaned}',
    );
    waiter.complete(cleaned);
    _smartSpeechReplyCompleter = null;
  }

  void _onSmartSpeechBotMessage(TdlibMessage msg) {
    if (!isSmartSpeechBotChat(msg.chatId)) return;
    final waiter = _smartSpeechReplyCompleter;
    if (waiter == null || waiter.isCompleted) return;
    if (msg.isOutgoing || msg.isService) return;
    if (_smartSpeechAfterMsgId > 0 && msg.id <= _smartSpeechAfterMsgId) {
      return;
    }
    final text = msg.text.trim();
    _mediaLog(
      'smartspeech bot-in id=${msg.id} chars=${text.length} '
      'preview=${text.length > 48 ? text.substring(0, 48) : text}',
    );
    if (TdlibSmartSpeech.isStatusAck(text)) {
      _mediaLog(
        'smartspeech skip-status bot=${msg.chatId} '
        'chars=${text.length} preview=${text.length > 40 ? text.substring(0, 40) : text}',
      );
      return;
    }
    if (!_isSmartSpeechTranscriptCandidate(msg)) {
      _mediaLog('smartspeech skip-kind bot=${msg.chatId} id=${msg.id}');
      return;
    }
    _completeSmartSpeechWaiter(text, why: 'update');
  }

  Future<void> _pollSmartSpeechReply(
    int botChatId, {
    required int afterMsgId,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 88));
    var ticks = 0;
    while (DateTime.now().isBefore(deadline)) {
      final waiter = _smartSpeechReplyCompleter;
      if (waiter == null || waiter.isCompleted) return;
      await Future<void>.delayed(
        Duration(milliseconds: ticks == 0 ? 800 : 1600),
      );
      ticks++;
      if (_smartSpeechReplyCompleter == null ||
          _smartSpeechReplyCompleter!.isCompleted) {
        return;
      }
      final history = await fetchRecentChatMessages(botChatId, limit: 12);
      // Newest first — TDLib returns newest→oldest usually; sort by id desc.
      final sorted = List<TdlibMessage>.from(history)
        ..sort((a, b) => b.id.compareTo(a.id));
      for (final m in sorted) {
        if (m.id <= afterMsgId) continue;
        _onSmartSpeechBotMessage(m);
        if (_smartSpeechReplyCompleter == null ||
            _smartSpeechReplyCompleter!.isCompleted) {
          _mediaLog('smartspeech poll-hit ticks=$ticks id=${m.id}');
          return;
        }
      }
      if (ticks == 1 || ticks % 5 == 0) {
        _mediaLog(
          'smartspeech poll ticks=$ticks afterMsg=$afterMsgId '
          'have=${history.length}',
        );
      }
    }
  }

  Future<void> _smartSpeechOpenBotChat(int botChatId) async {
    final c = _client;
    if (c == null || botChatId <= 0) return;
    // Do not touch UI [_openChatId] — only tell TDLib the chat is open so
    // updateNewMessage / history fill more reliably while we wait.
    if (_openChatId == botChatId) return;
    try {
      await c.sendAwait({
        '@type': 'openChat',
        'chat_id': botChatId,
      }, timeout: const Duration(seconds: 8));
      _smartSpeechBotChatOpened = true;
      _mediaLog('smartspeech openChat bot=$botChatId');
    } catch (e) {
      _mediaLog('smartspeech openChat soft-fail err=$e');
    }
  }

  Future<void> _smartSpeechCloseBotChat() async {
    if (!_smartSpeechBotChatOpened) return;
    _smartSpeechBotChatOpened = false;
    final botChatId = _smartSpeechBotChatId;
    final c = _client;
    if (c == null || botChatId == null || botChatId <= 0) return;
    if (_openChatId == botChatId) return;
    try {
      await c.sendAwait({
        '@type': 'closeChat',
        'chat_id': botChatId,
      }, timeout: const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<int?> _ensureSmartSpeechBotChat() async {
    if (_smartSpeechBotChatId != null && _smartSpeechBotChatId! > 0) {
      return _smartSpeechBotChatId;
    }
    // Already in chat list?
    for (final entry in _chats.entries) {
      final chat = entry.value;
      final type = chat['type'];
      if (type is! Map || type['@type']?.toString() != 'chatTypePrivate') {
        continue;
      }
      final uid = _tdlibInt(type['user_id']);
      if (_isSmartSpeechBotUser(uid, _users[uid])) {
        _smartSpeechBotChatId = entry.key;
        break;
      }
    }
    if (_smartSpeechBotChatId == null) {
      final c = _client;
      if (c == null || !isReady) return null;
      try {
        final chat = await c.sendAwait({
          '@type': 'searchPublicChat',
          'username': TdlibSmartSpeech.botUsername,
        }, timeout: const Duration(seconds: 20));
        if (chat['@type']?.toString() == 'chat') {
          final chatId = _tdlibInt(chat['id']);
          if (chatId > 0) {
            _applyChatRow(chatId, Map<String, dynamic>.from(chat));
            _smartSpeechBotChatId = chatId;
          }
        }
      } catch (e) {
        _mediaLog('smartspeech searchPublicChat fail err=$e');
      }
    }
    final botChatId = _smartSpeechBotChatId;
    if (botChatId == null || botChatId <= 0) return null;

    // Create private chat if needed (adds to main list — we hide in hub).
    final type = _chats[botChatId]?['type'];
    final userId = type is Map ? _tdlibInt(type['user_id']) : 0;
    if (userId > 0) {
      final ensured = await ensurePrivateChatId(userId);
      if (ensured != null && ensured > 0) {
        _smartSpeechBotChatId = ensured;
      }
    }
    final id = _smartSpeechBotChatId!;
    // Prior /start? Any history means the user already talked to the bot.
    final history = await fetchRecentChatMessages(id, limit: 8);
    final hasPrior = history.isNotEmpty;
    if (!hasPrior) {
      _mediaLog('smartspeech /start bot=$id');
      final welcome = _armSmartSpeechReplyWaiter();
      try {
        await sendText(id, '/start');
        await welcome.timeout(const Duration(seconds: 25));
      } catch (e) {
        _mediaLog('smartspeech /start wait soft-fail err=$e');
      }
    } else {
      _mediaLog('smartspeech skip-/start bot=$id have=${history.length}');
    }
    // Keep out of the way: mute + drop unread; hub filter hides the row.
    unawaited(setChatMuted(id, muted: true));
    unawaited(_markSmartSpeechRead(id));
    _hubChatsCache = null;
    return id;
  }

  Future<void> _markSmartSpeechRead(int chatId) async {
    final c = _client;
    if (c == null) return;
    try {
      final tip = _chats[chatId]?['last_message'];
      final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
      if (tipId <= 0) return;
      await c.sendAwait({
        '@type': 'viewMessages',
        'chat_id': chatId,
        'message_ids': [tipId],
        'force_read': true,
      }, timeout: const Duration(seconds: 8));
    } catch (_) {}
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

  Future<void> setChatMuted(
    int chatId, {
    required bool muted,
    int? muteForSeconds,
  }) async {
    final c = _client;
    if (c == null) return;
    final muteFor = !muted
        ? 0
        : (muteForSeconds ?? (366 * 24 * 3600)).clamp(0, 366 * 24 * 3600);
    await c.sendAwait({
      '@type': 'setChatNotificationSettings',
      'chat_id': chatId,
      'notification_settings': {
        '@type': 'chatNotificationSettings',
        'use_default_mute_for': false,
        'mute_for': muteFor,
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

  /// Optimistic tip paint when a closed chat tip advances past last_read.
  ///
  /// Only fills a **zero** badge (FakeTLS tip without readInbox). Never +1
  /// when TDLib already reports unread — catch-up lastMessage hops would
  /// inflate past official TG and stick via [_hubUnreadFloor].
  /// Dedupes newMessage∩lastMessage for the same tip id.
  void _bumpClosedChatUnreadForTip(
    int chatId,
    int tipId, {
    required String why,
  }) {
    if (chatId == 0 || tipId <= 0 || chatId == _openChatId) return;
    final row = _chats[chatId];
    if (row == null) return;
    final already = _hubUnreadBumpTipId[chatId] ?? 0;
    if (tipId <= already) {
      _scheduleUnreadRefresh(chatId, why: why);
      return;
    }
    _hubUnreadBumpTipId[chatId] = tipId;
    final cur = _tdlibInt(row['unread_count']);
    // Do not raise [_hubUnreadFloor] here — getChat/readInbox own the floor.
    if (cur <= 0) {
      row['unread_count'] = 1;
      _hubChatsCache = null;
    }
    _scheduleUnreadRefresh(chatId, why: why);
  }

  /// After MTProto Ready: soft-refresh a few hub badges (FakeTLS tip/badge
  /// desync). Kept small + late — getChat×40×2 on Ready was a cold-start hitch.
  /// Soft-refresh chat rows (unread / last message) without opening them.
  /// Prefer push / updateChat* — do not call this in a boot storm.
  Future<void> refreshChatSnapshots(Iterable<int> chatIds) async {
    final c = _client;
    if (c == null || !isReady) return;
    var changed = false;
    for (final chatId in chatIds) {
      if (chatId == 0) continue;
      if (_openChatId != null) return;
      if (_deferMediaUiNotify) break;
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
      // Yield so hub ListView can paint between RPCs.
      await Future<void>.delayed(const Duration(milliseconds: 40));
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
      // Warm soft/chat-quality thumbs. Must be foreground — pump skips all
      // background jobs while a chat is open (profile sheet is opened from
      // chat → background sheet-media never started → gray placeholders).
      for (final m in parsed) {
        unawaited(ensureSheetMediaPreview(m));
      }
      return parsed;
    } catch (e) {
      debugPrint('[tdlib] searchChatMedia($chatId): $e');
      return const [];
    }
  }

  /// Soft `m` / video thumb for profile+chat info gallery grids.
  int? sheetMediaPreviewFileId(TdlibMessage m) {
    if (m.isPhoto || m.photoRemoteId != null) {
      // Chat bubbles paint soft `m` first — same quality for the grid.
      if (m.photoFallbackFileIds.isNotEmpty) {
        return m.photoFallbackFileIds.first;
      }
      return m.photoRemoteId;
    }
    return m.videoThumbFileId ?? m.videoNoteThumbFileId;
  }

  /// Queue a chat-quality preview for a sheet gallery tile (wire allowed).
  Future<String?> ensureSheetMediaPreview(TdlibMessage m) async {
    final cached = resolvedPhotoPath(m);
    if (cached != null && cached.isNotEmpty) return cached;
    if (m.videoThumbLocalPath != null && m.videoThumbLocalPath!.isNotEmpty) {
      return m.videoThumbLocalPath;
    }
    final id = sheetMediaPreviewFileId(m);
    if (id == null || id <= 0) return null;
    final ram = cachedFilePath(id);
    if (ram != null && ram.isNotEmpty) return ram;
    return ensureFileLocal(
      id,
      priority: prioHubAvatar,
      reason: 'sheet-media:${m.chatId}:${m.id}',
      waitFor: const Duration(seconds: 45),
    );
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
          // Profile «Ссылки»: hide t.me / telegram.me — redundant next to
          // chat identity / in-app navigation.
          if (TelegramLinkUtils.isTelegramHostUrl(url)) continue;
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

  /// TDLib stores active emoji reactions **without** U+FE0F (td#1928;
  /// SessionLog: `The reaction isn't available` for `❤️` vs `❤`).
  static String normalizeReactionEmoji(String emoji) =>
      emoji.replaceAll('\uFE0F', '').trim();

  Future<void> toggleReaction({
    required int chatId,
    required int messageId,
    required String emoji,
    required bool add,
  }) async {
    final c = _client;
    if (c == null) return;
    var normalized = normalizeReactionEmoji(emoji);
    if (normalized.isEmpty) return;
    // Prefer the exact glyph TDLib lists as available (FE0F / chat-restricted
    // variants). Fall back to our normalized form when the list is empty.
    final resolved = add
        ? (await _matchAvailableReactionEmoji(chatId, messageId, normalized) ??
            normalized)
        : normalized;
    // Paint immediately — updateMessageInteractionInfo / getMessage often
    // lag or skip forcing a rebuild until reopen.
    _applyOptimisticReaction(
      chatId: chatId,
      messageId: messageId,
      emoji: resolved,
      add: add,
    );
    try {
      await _sendReactionToggle(
        c,
        chatId: chatId,
        messageId: messageId,
        emoji: resolved,
        add: add,
      );
      _mediaLog(
        'reaction ${add ? 'add' : 'remove'} ok '
        'chat=$chatId msg=$messageId emoji=$resolved',
      );
    } catch (e) {
      _mediaLog(
        'reaction ${add ? 'add' : 'remove'} fail '
        'chat=$chatId msg=$messageId emoji=$resolved err=$e',
      );
      // Roll back optimistic paint, then maybe retry add with matched glyph.
      _applyOptimisticReaction(
        chatId: chatId,
        messageId: messageId,
        emoji: resolved,
        add: !add,
      );
      if (!add) rethrow;
      final matched = await _matchAvailableReactionEmoji(
        chatId,
        messageId,
        normalized,
      );
      if (matched == null) rethrow;
      if (matched == resolved) rethrow;
      _applyOptimisticReaction(
        chatId: chatId,
        messageId: messageId,
        emoji: matched,
        add: true,
      );
      try {
        await _sendReactionToggle(
          c,
          chatId: chatId,
          messageId: messageId,
          emoji: matched,
          add: true,
        );
        _mediaLog(
          'reaction add ok (matched available) '
          'chat=$chatId msg=$messageId emoji=$matched',
        );
      } catch (e2) {
        _applyOptimisticReaction(
          chatId: chatId,
          messageId: messageId,
          emoji: matched,
          add: false,
        );
        rethrow;
      }
    }
  }

  /// Instant bubble update for add/remove (before TDLib push catches up).
  void _applyOptimisticReaction({
    required int chatId,
    required int messageId,
    required String emoji,
    required bool add,
  }) {
    final list = _messagesByChat[chatId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final m = list[idx];
    final want = normalizeReactionEmoji(emoji);
    final next = <TdlibReaction>[];
    var found = false;
    for (final r in m.reactions) {
      final e = normalizeReactionEmoji(r.emoji);
      if (e != want) {
        next.add(r);
        continue;
      }
      found = true;
      if (add) {
        next.add(
          TdlibReaction(
            emoji: r.emoji,
            count: r.chosen ? r.count : r.count + 1,
            chosen: true,
          ),
        );
      } else if (r.count > 1) {
        next.add(
          TdlibReaction(
            emoji: r.emoji,
            count: r.count - 1,
            chosen: false,
          ),
        );
      }
      // count==1 → drop the chip
    }
    if (add && !found) {
      next.add(TdlibReaction(emoji: want, count: 1, chosen: true));
    }
    list[idx] = _copyMessage(m, reactions: next);
    // Immediate — reaction chips must not wait open-quiet coalesce.
    _notifyUi(immediate: true);
  }

  List<TdlibReaction> _reactionsFromInteractionInfo(dynamic interaction) {
    final out = <TdlibReaction>[];
    if (interaction is! Map) return out;
    final ri = interaction['reactions'];
    final list = ri is Map ? ri['reactions'] : null;
    if (list is! List) return out;
    for (final r in list) {
      if (r is! Map) continue;
      final type = r['type'];
      var emoji = '';
      if (type is Map && type['@type'] == 'reactionTypeEmoji') {
        emoji = type['emoji']?.toString() ?? '';
      }
      if (emoji.isEmpty) continue;
      out.add(
        TdlibReaction(
          emoji: emoji,
          count: (r['total_count'] as num?)?.toInt() ?? 0,
          chosen: r['is_chosen'] == true,
        ),
      );
    }
    return out;
  }

  /// Apply reactions from [updateMessageInteractionInfo] without waiting on
  /// getMessage (keeps local media paths; paints chip immediately).
  void _applyInteractionInfoReactions(
    int chatId,
    int messageId,
    dynamic interactionInfo,
  ) {
    final list = _messagesByChat[chatId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final m = list[idx];
    final next = _reactionsFromInteractionInfo(interactionInfo);
    final prevFp = Object.hashAll(
      m.reactions.map((r) => Object.hash(r.emoji, r.count, r.chosen)),
    );
    final nextFp = Object.hashAll(
      next.map((r) => Object.hash(r.emoji, r.count, r.chosen)),
    );
    if (prevFp == nextFp) return;
    list[idx] = _copyMessage(m, reactions: next);
    // Coalesce — never hitch an open-chat fling for a channel reaction bump.
    _notifyUi();
  }

  Future<void> _sendReactionToggle(
    TdlibJsonClient c, {
    required int chatId,
    required int messageId,
    required String emoji,
    required bool add,
  }) async {
    // TDLib JSON field is `reaction_type` (not `reaction`) — wrong key →
    // empty type → 400 "The reaction isn't available for the message".
    final reactionType = {
      '@type': 'reactionTypeEmoji',
      'emoji': emoji,
    };
    if (add) {
      await c.sendAwait({
        '@type': 'addMessageReaction',
        'chat_id': chatId,
        'message_id': messageId,
        'reaction_type': reactionType,
        'is_big': false,
        'update_recent_reactions': true,
      });
    } else {
      await c.sendAwait({
        '@type': 'removeMessageReaction',
        'chat_id': chatId,
        'message_id': messageId,
        'reaction_type': reactionType,
      });
    }
  }

  /// Pick an available emoji that matches [want] after FE0F-normalize.
  /// Returns the **exact** string from TDLib's list (may still omit FE0F).
  Future<String?> _matchAvailableReactionEmoji(
    int chatId,
    int messageId,
    String want,
  ) async {
    final c = _client;
    if (c == null) return null;
    try {
      final res = await c.sendAwait({
        '@type': 'getMessageAvailableReactions',
        'chat_id': chatId,
        'message_id': messageId,
        'row_size': 8,
      }, timeout: const Duration(seconds: 8));
      if (res['@type'] != 'availableReactions') return null;
      final wantN = normalizeReactionEmoji(want);
      String? fromList(dynamic raw) {
        if (raw is! List) return null;
        for (final item in raw) {
          if (item is! Map) continue;
          final type = item['type'] ?? item;
          if (type is! Map) continue;
          if (type['@type']?.toString() != 'reactionTypeEmoji') continue;
          final rawEmoji = type['emoji']?.toString() ?? '';
          final e = normalizeReactionEmoji(rawEmoji);
          if (e.isEmpty) continue;
          if (e == wantN) return normalizeReactionEmoji(rawEmoji);
        }
        return null;
      }

      return fromList(res['top_reactions']) ??
          fromList(res['recent_reactions']) ??
          fromList(res['popular_reactions']);
    } catch (e) {
      _mediaLog(
        'reaction available-list fail chat=$chatId msg=$messageId err=$e',
      );
      return null;
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
    // R71: pierce Ready DF / post-restart cool so tap is not disk-miss for 22s.
    _releaseDfWireHoldForUserTap('preempt-tap:$reason');
    // R70: user tap retries a previously poisoned id (voice give-up while
    // !Ready / complete-defer loop). Clear only this file — not the set.
    if (_mediaGiveUpFileIds.remove(fileId)) {
      _dfStormCdnRetried.remove(fileId);
      _mediaLog('media-give-up clear file=$fileId why=preempt-tap:$reason');
    }

    // Channel videos often need openMessageContent or CDN never unlocks.
    // R49: force — focus debounce must not skip open/view on the tap itself.
    if (reason.contains('video:') ||
        reason.contains('tap:photo:') ||
        reason.contains('voice:')) {
      await _openMessageContentForFile(
        chatId,
        fileId,
        force: reason.contains('video:') || reason.contains('voice:'),
      );
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

  /// Live video file for a tap. Cached transcripts keep pre-restart file ids;
  /// those ids can now be a different file (Осташко 15230 → IMG_4536.MP4).
  Future<int?> freshVideoFileId({
    required int chatId,
    required int messageId,
    required int staleFileId,
  }) async {
    final c = _client;
    if (c == null || chatId == 0 || messageId <= 0 || staleFileId <= 0) {
      return null;
    }
    try {
      final raw = await c.sendAwait({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      }, timeout: const Duration(seconds: 8));
      if (raw['@type'] != 'message') return null;
      final map = Map<String, dynamic>.from(raw);
      map.putIfAbsent('chat_id', () => chatId);
      final after = _parseMessage(map);
      final fresh = after?.videoFileId ?? after?.videoNoteFileId;
      if (after == null || fresh == null || fresh <= 0) return null;
      _upsertMessage(after);
      if (fresh == staleFileId) return null;
      _mediaLog(
        'tap-video rebind file=$staleFileId → $fresh '
        'msg=$messageId chat=$chatId',
      );
      return fresh;
    } catch (e) {
      _mediaLog('tap-video rebind fail file=$staleFileId err=$e');
      return null;
    }
  }

  /// Progressive video like official TG: loopback URL + TDLib Range downloads.
  ///
  /// Returns null when the file is already complete on disk (caller plays file)
  /// or streaming is unavailable (web / no size). Otherwise a `http://127.0.0.1`
  /// URL for [VideoPlayerController.networkUrl].
  Future<String?> beginVideoStream({
    required int fileId,
    int? chatId,
    int? expectedSize,
    String mimeType = 'video/mp4',
  }) async {
    if (fileId <= 0 || kIsWeb) return null;
    if (await _probeLocalFile(fileId)) {
      final ready = cachedFilePath(fileId);
      if (ready != null && _isVideoMediaPath(ready)) return null;
      if (ready != null) {
        _mediaLog(
          'stream-begin drop-image file=$fileId path=${p.basename(ready)}',
        );
        _filePathCache.remove(fileId);
      }
    }
    var size = expectedSize ?? 0;
    if (size <= 0) size = fileExpectedSize(fileId);
    if (size <= 0) {
      final file = await _getFileMap(fileId);
      if (file != null) {
        size = _tdlibInt(file['expected_size']);
        if (size <= 0) size = _tdlibInt(file['size']);
        final local = file['local'];
        if (local is Map) {
          final path = local['path']?.toString();
          if (path != null && path.isNotEmpty) {
            _partialFilePath[fileId] = path;
          }
          if (local['is_downloading_completed'] == true &&
              path != null &&
              path.isNotEmpty) {
            _completeFileDownload(fileId, path);
            return null;
          }
        }
      }
    }
    if (size <= 0) {
      _mediaLog('stream-begin skip file=$fileId (unknown size)');
      return null;
    }
    // Bubble may still carry a pre-restart size (Осташко tap 15230:
    // declared 335KB, live file 2.02MB IMG_4536.MP4). Content-Length
    // must be the live file or ExoPlayer plays a truncated body.
    var liveSize = fileExpectedSize(fileId);
    if (liveSize <= size) {
      final probed = await _getFileMap(fileId);
      if (probed != null) {
        final expected = _tdlibInt(probed['expected_size']);
        final sz = _tdlibInt(probed['size']);
        if (expected > liveSize) liveSize = expected;
        if (sz > liveSize) liveSize = sz;
      }
    }
    if (liveSize > size) {
      _mediaLog(
        'stream-size raise file=$fileId '
        'declared=${_fmtBytes(size)} live=${_fmtBytes(liveSize)}',
      );
      size = liveSize;
    }
    if (chatId != null && chatId != 0) {
      await _openMessageContentForFile(chatId, fileId, force: true);
    }
    _streamingVideoIds.add(fileId);
    final session = TdlibVideoStreamSession(
      fileId: fileId,
      expectedSize: size,
      mimeType: mimeType,
      chatId: chatId,
    );
    _streamSessionMeta[fileId] = session;
    _videoStreamProxy ??= TdlibVideoStreamProxy(
      ensureRange: ({
        required int fileId,
        required int offset,
        required int length,
      }) =>
          ensureVideoStreamRange(
            fileId: fileId,
            offset: offset,
            length: length,
          ),
      reviveSession: _reviveVideoStreamSession,
    );
    final url = await _videoStreamProxy!.register(session);
    _streamUrlByFileId[fileId] = url;
    _mediaLog(
      'stream-begin file=$fileId size=${_fmtBytes(size)} url=$url '
      'chat=$chatId',
    );
    // Kick the first megabyte so ExoPlayer's opening Range is warm.
    // Moov-at-end is driven by the player; we fetch that Range once (no
    // downloadFile spam) and on failure switch to full-fallback prefix fill
    // instead of leaving the slot wedged on a dead end-offset.
    final warm = size < 1024 * 1024 ? size : 1024 * 1024;
    unawaited(
      ensureVideoStreamRange(fileId: fileId, offset: 0, length: warm),
    );
    notifyListeners();
    return url;
  }

  void endVideoStream(int fileId) {
    if (fileId <= 0) return;
    final t = _downloadTrace[fileId];
    final got = t?.lastBytes ?? 0;
    final expected = t?.expectedSize ?? fileExpectedSize(fileId);
    final incomplete = expected <= 0 || got < expected;
    _streamingVideoIds.remove(fileId);
    _streamUrlByFileId.remove(fileId);
    _streamSessionMeta.remove(fileId);
    // Keep [_streamFullFallbackIds] until the file completes — blocks another
    // moov-at-end Range from cancelling the full fill mid-download.
    _videoStreamProxy?.unregister(fileId);
    final waiters = _streamRangeWaiters.remove(fileId);
    if (waiters != null) {
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
    _mediaLog(
      'stream-end file=$fileId got=${_fmtBytes(got)}'
      '${incomplete ? ' → full-continue' : ''}',
    );
    if (incomplete) {
      unawaited(_continueVideoFullDownload(fileId, why: 'stream-end'));
    } else {
      _streamFullFallbackIds.remove(fileId);
    }
    notifyListeners();
  }

  Future<TdlibVideoStreamSession?> _reviveVideoStreamSession(int fileId) async {
    final meta = _streamSessionMeta[fileId];
    if (meta == null) {
      _mediaLog('stream-revive miss file=$fileId (no meta)');
      return null;
    }
    _streamingVideoIds.add(fileId);
    _mediaLog(
      'stream-revive file=$fileId size=${_fmtBytes(meta.expectedSize)}',
    );
    return meta;
  }

  /// Ensure [length] contiguous bytes from [offset] are on disk (TDLib ranges).
  Future<TdlibVideoRangeReady?> ensureVideoStreamRange({
    required int fileId,
    required int offset,
    required int length,
  }) async {
    if (fileId <= 0 || length <= 0 || offset < 0) return null;
    final prev = _streamRangeGates[fileId] ?? Future<void>.value();
    final gate = Completer<void>();
    _streamRangeGates[fileId] = gate.future;
    try {
      await prev;
      return await _ensureVideoStreamRangeUnlocked(
        fileId: fileId,
        offset: offset,
        length: length,
      );
    } finally {
      gate.complete();
    }
  }

  Future<TdlibVideoRangeReady?> _ensureVideoStreamRangeUnlocked({
    required int fileId,
    required int offset,
    required int length,
  }) async {
    final c = _client;
    if (c == null || _tearingDown) return null;
    // Overall cap; per-range idle is [_stallProgressIdleStreamRange] (~8s).
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    // Lookahead so the next player Range often hits cache (official buffers).
    final expected = fileExpectedSize(fileId);
    final moovTail = _isStreamMoovAtEndOffset(offset, expected);
    final fullFallback = _streamFullFallbackIds.contains(fileId);
    var downloadLimit = length;
    if (moovTail) {
      // Exact player window (+ small pad) — do not inflate to 512KB past EOF
      // and do not steal a huge FakeTLS window for a 50KB moov probe.
      downloadLimit = length;
      if (expected > 0) {
        final maxTail = expected - offset;
        if (maxTail > 0 && downloadLimit < maxTail) {
          final room = maxTail - downloadLimit;
          downloadLimit += room < 64 * 1024 ? room : 64 * 1024;
        }
      }
    } else if (downloadLimit < 512 * 1024) {
      downloadLimit = 512 * 1024;
    }
    if (expected > 0 && offset + downloadLimit > expected) {
      downloadLimit = expected - offset;
    }
    if (downloadLimit < length) downloadLimit = length;

    // After moov-at-end give-up: keep filling from 0; do not cancel that
    // download with another end-Range (SessionLog 08:43 18/30 hang).
    if (moovTail && fullFallback) {
      final avail = await _getFileDownloadedPrefixSize(fileId, offset);
      final path = _videoStreamPath(fileId);
      if (avail >= length && path != null && path.isNotEmpty) {
        return TdlibVideoRangeReady(path: path, available: avail);
      }
      unawaited(_kickStreamPrefixDownload(fileId, fullFile: true));
      _mediaLog(
        'stream-range moov-defer file=$fileId offset=$offset '
        'need=$length (full-fallback)',
      );
      return null;
    }

    var lastAvail = -1;
    var lastAvailAt = DateTime.now();
    var idleCancels = 0;

    while (!_tearingDown && DateTime.now().isBefore(deadline)) {
      if (!_streamingVideoIds.contains(fileId) &&
          !_downloadInFlight.contains(fileId)) {
        // Session ended mid-wait.
      }
      final avail = await _getFileDownloadedPrefixSize(fileId, offset);
      final path = _videoStreamPath(fileId);
      if (avail >= length && path != null && path.isNotEmpty) {
        if (moovTail) {
          // Moov landed — return slot to prefix for progressive play.
          _streamFullFallbackIds.remove(fileId);
          unawaited(_kickStreamPrefixDownload(fileId));
        }
        return TdlibVideoRangeReady(path: path, available: avail);
      }
      if (avail > lastAvail) {
        lastAvail = avail;
        lastAvailAt = DateTime.now();
        idleCancels = 0;
      } else if (DateTime.now().difference(lastAvailAt) >=
          _stallProgressIdleStreamRange) {
        // No growth on this range — cancel TDLib offset, allow one retry.
        // Moov-at-end under FakeTLS almost never lands (SessionLog 14:18:
        // end-Range got=0 while prefix filled to 18MB). First idle → full
        // fill immediately; a second end-Range only cancels the live prefix.
        _mediaLog(
          'stream-range idle-cancel file=$fileId offset=$offset '
          'need=$length got=$avail n=$idleCancels'
          '${moovTail ? ' moov-tail' : ''}',
        );
        final t = _downloadTrace[fileId];
        if (t != null) t.downloadAcked = false;
        await _cancelTdlibDownload(fileId);
        idleCancels++;
        lastAvailAt = DateTime.now();
        if (moovTail) {
          _streamFullFallbackIds.add(fileId);
          unawaited(_continueVideoFullDownload(fileId, why: 'moov-idle'));
          break;
        }
        if (idleCancels >= 2) break;
        if (!_canStartNetworkDownload && !_tdlibReadyForMedia) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        await _startStreamRangeDownload(
          fileId: fileId,
          offset: offset,
          limit: downloadLimit <= 0 ? 0 : downloadLimit,
          force: true,
        );
        continue;
      }
      if (!_canStartNetworkDownload && !_tdlibReadyForMedia) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      await _startStreamRangeDownload(
        fileId: fileId,
        offset: offset,
        limit: downloadLimit <= 0 ? 0 : downloadLimit,
      );
      final waiter = Completer<void>();
      (_streamRangeWaiters[fileId] ??= <Completer<void>>[]).add(waiter);
      try {
        await waiter.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Re-check prefix / idle budget above.
      } finally {
        _streamRangeWaiters[fileId]?.remove(waiter);
      }
    }
    final avail = await _getFileDownloadedPrefixSize(fileId, offset);
    final path = _videoStreamPath(fileId);
    if (avail >= length && path != null && path.isNotEmpty) {
      if (moovTail) {
        _streamFullFallbackIds.remove(fileId);
        unawaited(_kickStreamPrefixDownload(fileId));
      }
      return TdlibVideoRangeReady(path: path, available: avail);
    }
    if (moovTail) {
      // End-Range never arrived — switch to full fill so UI does not sit at
      // a frozen mid-file percent forever.
      _streamFullFallbackIds.add(fileId);
      unawaited(_kickStreamPrefixDownload(fileId, fullFile: true));
      _mediaLog(
        'stream-range moov-fail → full-fallback file=$fileId '
        'offset=$offset need=$length got=$avail',
      );
    } else {
      _mediaLog(
        'stream-range FAIL file=$fileId offset=$offset need=$length '
        'got=$avail path=${path == null ? "null" : p.basename(path)}',
      );
    }
    return null;
  }

  Future<void> _startStreamRangeDownload({
    required int fileId,
    required int offset,
    required int limit,
    bool force = false,
  }) async {
    final c = _client;
    if (c == null || _tearingDown) return;
    // Full-fallback: ignore end-Range so we do not cancel a live prefix fill.
    if (!force &&
        offset > 0 &&
        _streamFullFallbackIds.contains(fileId)) {
      _mediaLog(
        'stream-downloadFile skip moov-defer file=$fileId offset=$offset',
      );
      return;
    }
    final existing = _downloadTrace[fileId];
    // R4: never spam downloadFile on an active same-offset transfer —
    // SessionLog 08:43 re-issued end-Range every ~20ms → moov never landed.
    if (!force &&
        existing != null &&
        existing.offset == offset &&
        existing.streamLimit == limit &&
        existing.downloadAcked &&
        _downloadInFlight.contains(fileId)) {
      return;
    }
    if (!_downloadInFlight.contains(fileId)) {
      _downloadInFlight.add(fileId);
      _downloadActive = (_downloadActive + 1).clamp(0, 100);
    }
    final t = _downloadTrace.putIfAbsent(
      fileId,
      () => _TdlibDownloadTrace(
        fileId: fileId,
        reason: 'stream:video:$fileId',
        priority: 32,
        background: false,
        chatId: _openChatId,
      ),
    );
    t.reason = 'stream:video:$fileId';
    // New Range → fresh idle/retry budget (watchdog recoverAttempted is per offset).
    if (t.offset != offset || t.streamLimit != limit) {
      t.recoverAttempted = false;
      t.lastProgressAt = null;
    }
    t.offset = offset;
    t.streamLimit = limit;
    t.startedAt ??= DateTime.now();
    t.lastStartAt = DateTime.now();
    t.downloadAcked = false;
    if (t.expectedSize <= 0) {
      final s = fileExpectedSize(fileId);
      if (s > 0) t.expectedSize = s;
    }
    _mediaLog(
      'stream-downloadFile file=$fileId offset=$offset limit=$limit '
      'prio=32 net=${_networkKind.name}'
      '${force ? ' force=true' : ''}',
    );
    try {
      await c.sendAwait(
        {
          '@type': 'downloadFile',
          'file_id': fileId,
          'priority': 32,
          'offset': offset,
          'limit': limit,
          'synchronous': false,
        },
        timeout: const Duration(seconds: 20),
      );
      t.downloadAcked = true;
    } catch (e) {
      _mediaLog('stream-downloadFile FAIL file=$fileId err=$e');
      // R47: stream path used to leave FakeTLS slot=1 on dead file_id for
      // ~20s (SessionLog 21:20 File not found ×N → stall give-up).
      if (_isTdlibFileMissingError(e)) {
        final fresh = await _remapStaleFileId(
          fileId,
          reason: 'stream:video:$fileId',
        );
        _releaseDownloadSlot(fileId, failed: true);
        if (fresh != null && fresh != fileId) {
          await _startStreamRangeDownload(
            fileId: fresh,
            offset: offset,
            limit: limit,
            force: true,
          );
        }
        return;
      }
    }
  }

  Future<int> _getFileDownloadedPrefixSize(int fileId, int offset) async {
    final c = _client;
    if (c == null) return 0;
    try {
      final r = await c.sendAwait(
        {
          '@type': 'getFileDownloadedPrefixSize',
          'file_id': fileId,
          'offset': offset,
        },
        timeout: const Duration(seconds: 5),
      );
      return _tdlibInt(r['size']);
    } catch (_) {
      return 0;
    }
  }

  Future<Map?> _getFileMap(int fileId) async {
    final c = _client;
    if (c == null || fileId <= 0) return null;
    try {
      final r = await c.sendAwait(
        {'@type': 'getFile', 'file_id': fileId},
        timeout: const Duration(seconds: 8),
      );
      if (r['@type'] != 'file') return null;
      return r;
    } catch (_) {
      return null;
    }
  }

  void _pulseStreamRangeWaiters(int fileId) {
    final list = _streamRangeWaiters[fileId];
    if (list == null || list.isEmpty) return;
    for (final w in List<Completer<void>>.from(list)) {
      if (!w.isCompleted) w.complete();
    }
    list.clear();
  }

  /// Wait until file is local (via async download + [updateFile]), or null.
  Future<String?> ensureFileLocal(
    int fileId, {
    int priority = prioFocused,
    Duration waitFor = const Duration(seconds: 120),
    String reason = 'ensure',
  }) async {
    if (fileId <= 0) return null;
    final cached = cachedFilePath(fileId);
    if (cached != null && cached.isNotEmpty) {
      _mediaLog('ensure-hit-ram file=$fileId reason=$reason');
      return cached;
    }
    // R47b: attachment id may still be pre-remap; follow table / disk seed.
    final remapped = _staleFileIdRemap[fileId];
    if (remapped != null && remapped > 0 && remapped != fileId) {
      _seedRemappedPath(fileId, remapped);
      final viaRemap = cachedFilePath(remapped) ?? cachedFilePath(fileId);
      if (viaRemap != null && viaRemap.isNotEmpty) {
        _mediaLog(
          'ensure-hit-remap file=$fileId → $remapped '
          'path=${p.basename(viaRemap)} reason=$reason',
        );
        return viaRemap;
      }
      return ensureFileLocal(
        remapped,
        priority: priority,
        waitFor: waitFor,
        reason: reason.contains('$fileId')
            ? reason.replaceFirst('$fileId', '$remapped')
            : reason,
      );
    }

    // FakeTLS exclusive slot: bare ensure (profile/header avatar sheets) must
    // not hold 1/1 at 0B (A/B: ensure file=1309 idle 12s while chat open).
    // User taps use reason tap:* / focus paths — those still go on the wire.
    // R22: album:prefetch also stays disk-only — 5 waiters piled behind one
    // 0B focus (SessionLog 16:37 queued=6).
    // sheet-media:* is intentional foreground (info Gallery tab) — allow wire.
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
    // Prefer chat id embedded in sheet-media:* so purge keeps the right chat.
    final sheetChat = () {
      if (!reason.startsWith('sheet-media:')) return null;
      final parts = reason.split(':');
      if (parts.length < 2) return null;
      return int.tryParse(parts[1]);
    }();
    _queueFileDownload(
      fileId,
      priority: priority,
      background: false,
      chatId: sheetChat ?? _openChatId,
      reason: reason,
    );
    try {
      // R47: downloadFile "File not found" remaps waiter onto the fresh id
      // inside [_startAsyncDownload]; this completer still completes.
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
      // Completer may have been moved to a remapped file id (R47).
      if (identical(_downloadWaiters[fileId], completer)) {
        _downloadWaiters.remove(fileId);
      }
      for (final e in _downloadWaiters.entries.toList()) {
        if (identical(e.value, completer)) {
          _downloadWaiters.remove(e.key);
        }
      }
      if (!completer.isCompleted) {
        completer.complete(_filePathCache[fileId]);
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
            if (memberCount > 0) {
              _memberCountByChatId[chatId] = memberCount;
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
            if (memberCount > 0) {
              _memberCountByChatId[chatId] = memberCount;
            }
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

  /// Clear messages locally (and optionally for peers). Keeps the chat in the list.
  Future<void> clearChatHistory(
    int chatId, {
    bool revoke = false,
  }) async {
    final c = _client;
    if (c == null || chatId == 0) return;
    await c.sendAwait({
      '@type': 'deleteChatHistory',
      'chat_id': chatId,
      'remove_from_chat_list': false,
      'revoke': revoke,
    });
    _messagesByChat.remove(chatId);
    _openTranscriptPreserve.remove(chatId);
    _pinnedMessageId.remove(chatId);
    _hubChatsCache = null;
    notifyListeners();
  }

  /// Delete a private/secret chat (history + remove from chat list).
  Future<void> deleteChat(
    int chatId, {
    bool revoke = false,
  }) async {
    final c = _client;
    if (c == null || chatId == 0) return;
    await c.sendAwait({
      '@type': 'deleteChatHistory',
      'chat_id': chatId,
      'remove_from_chat_list': true,
      'revoke': revoke,
    });
    _messagesByChat.remove(chatId);
    _openTranscriptPreserve.remove(chatId);
    _pinnedMessageId.remove(chatId);
    _chats.remove(chatId);
    _chatOrder.remove(chatId);
    _hubChatsCache = null;
    notifyListeners();
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
    final specs = <({int userId, bool isCreator, bool isAdmin})>[];

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
          specs.add((
            userId: userId,
            isCreator: statusType == 'chatMemberStatusCreator',
            isAdmin: statusType == 'chatMemberStatusAdministrator',
          ));
        }
      } else if (typeName == 'chatTypeSupergroup') {
        final isChannel = type['is_channel'] == true;
        if (isChannel) return const [];
        var offset = '';
        while (specs.length < limit) {
          final res = await c.sendAwait({
            '@type': 'getSupergroupMembers',
            'supergroup_id': _tdlibInt(type['supergroup_id']),
            'filter': {'@type': 'supergroupMembersFilterRecent'},
            'offset': offset.isEmpty ? 0 : int.tryParse(offset) ?? specs.length,
            'limit': (limit - specs.length).clamp(1, 200),
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
            specs.add((
              userId: userId,
              isCreator: statusType == 'chatMemberStatusCreator',
              isAdmin: statusType == 'chatMemberStatusAdministrator',
            ));
            if (specs.length >= limit) break;
          }
          final total = (res['total_count'] as num?)?.toInt() ?? specs.length;
          if (specs.length >= total || members.isEmpty) break;
          // getSupergroupMembers uses numeric offset in recent TDLib.
          offset = '${specs.length}';
          if (members.length < 10) break;
        }
      }
    } catch (e) {
      debugPrint('[tdlib] chatMembers($chatId): $e');
    }

    // Hydrate users (names / profile_photo) before painting the list.
    const chunk = 8;
    for (var i = 0; i < specs.length; i += chunk) {
      final slice = specs.skip(i).take(chunk);
      await Future.wait([
        for (final s in slice)
          _refreshUser(s.userId, queueAvatar: false),
      ]);
    }

    final out = <TdlibChatMember>[
      for (final s in specs)
        _chatMemberFromUserId(
          s.userId,
          isCreator: s.isCreator,
          isAdmin: s.isAdmin,
        ),
    ];
    out.sort((a, b) {
      if (a.isCreator != b.isCreator) return a.isCreator ? -1 : 1;
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });

    // Progressive disk/wire fill — sheet listens via [userAvatarLocalPath].
    unawaited(_prefetchGroupMemberAvatars([
      for (final m in out) m.userId,
    ]));
    return out;
  }

  /// Local path for a TG user's small profile photo (if already on disk).
  String? userAvatarLocalPath(int userId) {
    if (userId <= 0) return null;
    final fileId = _resolveUserAvatarFileId(_users[userId]);
    if (fileId == null || fileId <= 0) return null;
    return cachedFilePath(fileId);
  }

  Future<void> _prefetchGroupMemberAvatars(List<int> userIds) async {
    for (final userId in userIds) {
      if (_tearingDown || _client == null) return;
      final fileId = _resolveUserAvatarFileId(_users[userId]);
      if (fileId == null || fileId <= 0) continue;
      if (cachedFilePath(fileId) != null) continue;
      try {
        await ensureFileLocal(
          fileId,
          priority: prioBackground,
          waitFor: const Duration(seconds: 20),
          reason: 'group-member',
        );
      } catch (_) {}
      if (cachedFilePath(fileId) != null) {
        _notifyUi();
      }
    }
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
      path = cachedFilePath(fileId);
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

  /// Russian plural label, e.g. `14 556 подписчиков`. Null if [count] ≤ 0.
  static String? formatMemberCountLabel(
    int count, {
    required bool isChannel,
  }) {
    if (count <= 0) return null;
    final mod10 = count % 10;
    final mod100 = count % 100;
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
    final formatted = count
        .toString()
        .replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]} ',
        );
    return '$formatted $word';
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
      final n = _memberCountForChat(chatId);
      return formatMemberCountLabel(n, isChannel: true) ?? 'канал';
    }
    if (typeName == 'chatTypeBasicGroup' ||
        typeName == 'chatTypeSupergroup') {
      final n = _memberCountForChat(chatId);
      return formatMemberCountLabel(n, isChannel: false) ?? 'группа';
    }
    if (typeName != 'chatTypePrivate') return '';
    final uid = (type['user_id'] as num?)?.toInt();
    if (uid == null) return '';
    return _formatUserStatus(_users[uid]?['status']);
  }

  int _memberCountForChat(int chatId) {
    final cached = _memberCountByChatId[chatId] ?? 0;
    if (cached > 0) return cached;
    final chat = _chats[chatId];
    final type = chat?['type'];
    if (type is Map && type['@type']?.toString() == 'chatTypeSupergroup') {
      final sgId = _tdlibInt(type['supergroup_id']);
      final fromSg = _tdlibInt(_supergroups[sgId]?['member_count']);
      if (fromSg > 0) {
        _memberCountByChatId[chatId] = fromSg;
        return fromSg;
      }
    }
    // Full info has the real count — fetch once for AppBar.
    _ensureMemberCountCached(chatId);
    return 0;
  }

  void _ensureMemberCountCached(int chatId) {
    if (chatId == 0 ||
        (_memberCountByChatId[chatId] ?? 0) > 0 ||
        _memberCountFetchQueued.contains(chatId)) {
      return;
    }
    final c = _client;
    final chat = _chats[chatId];
    final type = chat?['type'];
    if (c == null || type is! Map) return;
    final typeName = type['@type']?.toString() ?? '';
    _memberCountFetchQueued.add(chatId);
    unawaited(() async {
      try {
        if (typeName == 'chatTypeSupergroup') {
          final sgId = _tdlibInt(type['supergroup_id']);
          if (sgId <= 0) return;
          var n = _tdlibInt(_supergroups[sgId]?['member_count']);
          if (n <= 0) {
            try {
              final sg = await c.sendAwait({
                '@type': 'getSupergroup',
                'supergroup_id': sgId,
              });
              if (sg['@type'] == 'supergroup') {
                _supergroups[sgId] = Map<String, dynamic>.from(sg);
                n = _tdlibInt(sg['member_count']);
              }
            } catch (_) {}
          }
          if (n <= 0) {
            final full = await c.sendAwait({
              '@type': 'getSupergroupFullInfo',
              'supergroup_id': sgId,
            });
            if (full['@type'] == 'supergroupFullInfo') {
              n = _tdlibInt(full['member_count']);
            }
          }
          if (n > 0) {
            _memberCountByChatId[chatId] = n;
            _notifyUi();
          }
        } else if (typeName == 'chatTypeBasicGroup') {
          final bgId = _tdlibInt(type['basic_group_id']);
          if (bgId <= 0) return;
          final full = await c.sendAwait({
            '@type': 'getBasicGroupFullInfo',
            'basic_group_id': bgId,
          });
          if (full['@type'] == 'basicGroupFullInfo') {
            final members = full['members'];
            final n = members is List ? members.length : 0;
            if (n > 0) {
              _memberCountByChatId[chatId] = n;
              _notifyUi();
            }
          }
        }
      } catch (e) {
        debugPrint('[tdlib] memberCount chat=$chatId: $e');
      } finally {
        _memberCountFetchQueued.remove(chatId);
      }
    }());
  }

  int? _privateUserId(int chatId) {
    final type = _chats[chatId]?['type'];
    if (type is! Map) return null;
    if (type['@type']?.toString() != 'chatTypePrivate') return null;
    return (type['user_id'] as num?)?.toInt();
  }

  /// Peer user id for a private chat (including Saved Messages = self).
  int? privatePeerUserId(int chatId) => _privateUserId(chatId);

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

  /// Find or create the private chat with [userId] (TDLib `createPrivateChat`).
  Future<int?> ensurePrivateChatId(int userId) async {
    if (userId <= 0) return null;
    final existing = privateChatIdForUser(userId);
    if (existing != null && existing != 0) return existing;
    final c = _client;
    if (c == null || !isReady) return null;
    try {
      final res = await c.sendAwait({
        '@type': 'createPrivateChat',
        'user_id': userId,
        'force': true,
      }, timeout: const Duration(seconds: 15));
      final chatId = _tdlibInt(res['id']);
      if (chatId > 0) {
        if (res['@type']?.toString() == 'chat') {
          _applyChatRow(chatId, Map<String, dynamic>.from(res));
        }
        return chatId;
      }
    } catch (e) {
      debugPrint('[tdlib] ensurePrivateChatId($userId): $e');
    }
    return privateChatIdForUser(userId);
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
        final had = _users.containsKey(userId);
        final prevStatus = had ? _users[userId]!['status'] : null;
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
        // Open-chat quiet + already-known peer: skip rebuild (Valya open was
        // FRAME 217ms from getUser coalesce with identical transcript).
        final inOpenQuiet = _openChatUiQuietUntil != null &&
            DateTime.now().isBefore(_openChatUiQuietUntil!);
        final openPeer = _openChatId != null &&
            _privateUserId(_openChatId!) == userId;
        if (inOpenQuiet && had && openPeer) {
          final nextStatus = _users[userId]?['status'];
          if (prevStatus?.toString() == nextStatus?.toString()) return;
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
    // Bootstrap snapshot on TDLib start / reconnect — NOT live traffic.
    // Raising banners here re-fired the same unread as a "new" push on every
    // app open (and resurrected old unread as zombie pushes). Sync maps +
    // ack TDLib's queue only; live shows come from updateNotificationGroup.
    final groups = update['groups'];
    if (groups is! List) return;
    var groupsN = 0;
    var notifsN = 0;
    var acked = 0;
    for (final g in groups) {
      if (g is! Map) continue;
      final groupId = (g['id'] as num?)?.toInt();
      final chatId = (g['chat_id'] as num?)?.toInt();
      final notifications = g['notifications'];
      if (groupId == null || chatId == null) continue;
      groupsN++;
      _notifGroupChatId[groupId] = chatId;
      if (notifications is! List || notifications.isEmpty) {
        await _cancelLocalTdlibNotification(chatId);
        continue;
      }
      for (final raw in notifications) {
        if (raw is! Map) continue;
        notifsN++;
        final notification = Map<String, dynamic>.from(raw);
        await _ackRemoveNotification(groupId, notification);
        acked++;
      }
      await _cancelLocalTdlibNotification(chatId);
    }
    _slog('tg.push', 'active_bootstrap', {
      'groups': groupsN,
      'notifs': notifsN,
      'acked': acked,
      'raised': 0,
    });
    _mediaLog(
      'notif active-bootstrap groups=$groupsN notifs=$notifsN '
      'acked=$acked raised=0',
    );
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
          source: 'group_added',
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
      source: 'notif_update',
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

  int? _tdlibNotificationMessageId(Map<String, dynamic> notification) {
    final type = notification['type'];
    if (type is! Map) return null;
    final typeName = type['@type']?.toString() ?? '';
    if (typeName == 'notificationTypeNewMessage') {
      final message = type['message'];
      if (message is Map) {
        final id = _tdlibInt(message['id']);
        return id == 0 ? null : id;
      }
    }
    if (typeName == 'notificationTypeNewPushMessage') {
      final id = _tdlibInt(type['message_id']);
      return id == 0 ? null : id;
    }
    return null;
  }

  Future<void> _showOrSkipTdlibNotification({
    required int groupId,
    required int chatId,
    required Map<String, dynamic> notification,
    required bool isSilent,
    String source = 'live',
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;

    final notifId = (notification['id'] as num?)?.toInt();
    final messageId = _tdlibNotificationMessageId(notification);
    final notifDate = (notification['date'] as num?)?.toInt() ?? 0;

    // Muted / silent (TDLib is_silent or notification_sound_id=0): never raise
    // a system banner — matches official TG. Do not removeNotification: that
    // would ack the group and can wipe unread while the chat stays muted.
    if (isSilent) {
      await _cancelLocalTdlibNotification(chatId);
      _slog('tg.push', 'skip_silent', {
        'chatId': chatId,
        'groupId': groupId,
        'notifId': notifId,
        'messageId': messageId,
        'source': source,
      });
      return;
    }

    if (await _shouldSkipTdlibLocalPush(chatId)) {
      await _ackRemoveNotification(groupId, notification);
      await _cancelLocalTdlibNotification(chatId);
      _slog('tg.push', 'skip_open_chat', {
        'chatId': chatId,
        'groupId': groupId,
        'notifId': notifId,
        'messageId': messageId,
        'source': source,
      });
      return;
    }

    // Stale TDLib notification (old unread kept in the group): do not raise —
    // this is the "zombie push" class. Ack so it does not return next boot.
    if (notifDate > 0) {
      final ageSec =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - notifDate;
      if (ageSec > 180) {
        await _ackRemoveNotification(groupId, notification);
        _slog('tg.push', 'skip_stale', {
          'chatId': chatId,
          'groupId': groupId,
          'notifId': notifId,
          'messageId': messageId,
          'ageSec': ageSec,
          'source': source,
        });
        return;
      }
    }

    final parsed = _parseTdlibNotificationContent(chatId, notification);
    if (parsed == null) return;

    final data = <String, dynamic>{
      'type': kTdlibPushType,
      'chat_id': '$chatId',
      'notification_group_id': '$groupId',
      if (notifId != null) 'notification_id': '$notifId',
      if (messageId != null) 'message_id': '$messageId',
      'title': parsed.title,
      'body': parsed.body,
      'thread_title': parsed.title,
    };

    await FamilyChatNotifications.showForegroundPush(
      title: parsed.title,
      body: parsed.body,
      data: data,
    );
    // Ack after raise so reconnect does not re-deliver the same group as a
    // fresh banner (duplicate-on-open). Unread on the chat is unchanged.
    await _ackRemoveNotification(groupId, notification);
    _slog('tg.push', 'raised', {
      'chatId': chatId,
      'groupId': groupId,
      'notifId': notifId,
      'messageId': messageId,
      'source': source,
      'preview': SessionLog.textPreview(parsed.body),
    });
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
            // Folder reindex + avatar resolve are heavy; skip mid boot quiet
            // (boot-prime already has faces; folders catch up after quiet).
            if (!_inHubBootUiQuiet) {
              _reindexFolderMembership(id);
              _resolveChatAvatarFileId(_chats[id]!);
            }
            final lastOut =
                (chat['last_read_outbox_message_id'] as num?)?.toInt();
            if (lastOut != null) _lastReadOutboxId[id] = lastOut;
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
      case 'updateUnreadChatCount':
        final list = update['chat_list'];
        final listType =
            list is Map ? list['@type']?.toString() ?? '' : '';
        if (listType == 'chatListArchive') {
          _archiveUnreadChatCount =
              (update['unread_count'] as num?)?.toInt() ?? 0;
          _archiveTotalCount =
              (update['total_count'] as num?)?.toInt() ?? 0;
          _notifyUi();
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
          final prevTip = chat['last_message'];
          final prevTipId = prevTip is Map ? _tdlibInt(prevTip['id']) : 0;
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
            } else if (_isInArchiveChatList(chat)) {
              _archiveChatOrder.remove(chatId);
              _archiveChatOrder.insert(0, chatId);
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
              // Unread for closed chats: updateChatReadInbox is authoritative.
              // FakeTLS often delivers tip/lastMessage while dropping readInbox
              // + newMessage — tip advances (20:05) but badge freezes (19 vs 22).
              if (!msg.isOutgoing &&
                  !msg.isService &&
                  msg.chatId != _openChatId) {
                final lastRead = _effectiveLastReadInbox(chatId);
                if (msg.id > lastRead && msg.id != prevTipId) {
                  _bumpClosedChatUnreadForTip(chatId, msg.id, why: 'lastMessage');
                }
              }
            }
          }
        } else if (type == 'updateChatReadInbox') {
          debugPrint(
            '[unread-dbg] readInbox chat=$chatId '
            'unread=${update['unread_count']} '
            'lastReadInbox=${update['last_read_inbox_message_id']}',
          );
          final lastIn = _tdlibInt(update['last_read_inbox_message_id']);
          if (lastIn > 0) {
            _advanceReadInboxFloor(chatId, lastIn);
          }
          final incomingUnread = _tdlibInt(update['unread_count']);
          final tip = chat['last_message'];
          final tipId = tip is Map ? _tdlibInt(tip['id']) : 0;
          final readThrough = _effectiveLastReadInbox(chatId);
          if (tipId > 0 && tipId <= readThrough && incomingUnread <= 0) {
            chat['unread_count'] = 0;
          } else if (chatId == _openChatId &&
              _markReadIsFresh(chatId) &&
              incomingUnread > 0) {
            // Only briefly keep a lower optimistic right after local mark-read.
            final optimistic = _tdlibInt(chat['unread_count']);
            if (optimistic > 0 && incomingUnread > optimistic) {
              chat['unread_count'] = optimistic;
            } else {
              chat['unread_count'] = incomingUnread;
            }
          } else {
            chat['unread_count'] = incomingUnread;
          }
          // Always follow TDLib readInbox for the hub floor — including drops
          // after our own progressive mark-read (sticky floor used to freeze
          // channel badges while scrolling).
          _setHubUnreadFloor(chatId, incomingUnread);
          // Authoritative unread — allow future tip bumps from this tip onward.
          final tipNow = chat['last_message'];
          final tipNowId = tipNow is Map ? _tdlibInt(tipNow['id']) : 0;
          if (tipNowId > 0) {
            _hubUnreadBumpTipId[chatId] = tipNowId;
          }
          if (unreadCountFor(chatId) > 0) {
            // Boot grace: don't start getChatHistory mid first-paint.
            if (_hubWarmNotBefore != null &&
                DateTime.now().isBefore(_hubWarmNotBefore!)) {
              scheduleHubWarmAfterBoot(why: 'updateChatReadInbox');
            } else if (!isChannelChat(chatId)) {
              _enqueueHistoryWarm(chatId);
            }
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
        if (type == 'updateChatLastMessage' ||
            type == 'updateChatReadInbox') {
          _scheduleHubSnapshotRowPersist(chatId);
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
          unawaited(
            TgHistoryStore.instance.deleteMessages(chatId, idSet.toList()),
          );
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
            // Coalesce / scroll-defer — raw notifyListeners hitch flings.
            _notifyUi();
          }
        }
        break;
      case 'updateSupergroup':
        final sg = update['supergroup'];
        if (sg is Map) {
          final id = (sg['id'] as num?)?.toInt();
          if (id != null) {
            _supergroups[id] = Map<String, dynamic>.from(sg);
            final mc = _tdlibInt(sg['member_count']);
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
            } else if (mc > 0) {
              for (final entry in _chats.entries) {
                final t = entry.value['type'];
                if (t is Map &&
                    t['@type']?.toString() == 'chatTypeSupergroup' &&
                    (t['supergroup_id'] as num?)?.toInt() == id) {
                  _memberCountByChatId[entry.key] = mc;
                }
              }
            }
            _notifyUi();
          }
        }
        break;
      case 'updateSupergroupFullInfo':
        final sgId = _tdlibInt(update['supergroup_id']);
        final full = update['supergroup_full_info'];
        if (sgId > 0 && full is Map) {
          final mc = _tdlibInt(full['member_count']);
          if (mc > 0) {
            for (final entry in _chats.entries) {
              final t = entry.value['type'];
              if (t is Map &&
                  t['@type']?.toString() == 'chatTypeSupergroup' &&
                  (t['supergroup_id'] as num?)?.toInt() == sgId) {
                _memberCountByChatId[entry.key] = mc;
              }
            }
            _notifyUi();
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
            _onSmartSpeechBotMessage(msg);
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
            // Hidden SaluteSpeech bot: no hub unread / history warm.
            final smartSpeechBot = isSmartSpeechBotChat(msg.chatId);
            if (smartSpeechBot && !msg.isOutgoing) {
              unawaited(_markSmartSpeechRead(msg.chatId));
            }
            if (msg.chatId == _openChatId) {
              _maybeAutoMarkRead(msg.chatId, msg.id);
              focusVisibleMessageMedia(
                chatId: msg.chatId,
                messageId: msg.id,
              );
            } else if (!msg.isOutgoing && !msg.isService && !smartSpeechBot) {
              // Tentative +1 if tip advanced past last_read; updateChatReadInbox
              // overwrites with the authoritative count when it arrives.
              // Without this, FakeTLS can deliver last_message/newMessage while
              // dropping readInbox — hub tip stays fresh but badge freezes.
              final closed = msg.chatId != _openChatId;
              if (closed) {
                final lastRead = _effectiveLastReadInbox(msg.chatId);
                if (msg.id > lastRead) {
                  _bumpClosedChatUnreadForTip(
                    msg.chatId,
                    msg.id,
                    why: 'newMessage',
                  );
                }
              }
              if (_hubWarmNotBefore != null &&
                  DateTime.now().isBefore(_hubWarmNotBefore!)) {
                scheduleHubWarmAfterBoot(why: 'newMessage');
              } else if (!isChannelChat(msg.chatId)) {
                _enqueueHistoryWarm(msg.chatId);
              }
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
        final chatId = (update['chat_id'] as num?)?.toInt();
        final messageId = (update['message_id'] as num?)?.toInt();
        if (chatId == null || messageId == null) return;
        unawaited(_reloadMessage(chatId, messageId));
        break;
      case 'updateMessageInteractionInfo':
        final chatId = (update['chat_id'] as num?)?.toInt();
        final messageId = (update['message_id'] as num?)?.toInt();
        if (chatId == null || messageId == null) return;
        // Payload already has fresh reactions — apply in-place (don't wait
        // for getMessage; reopen-only paint was the user-visible bug).
        _applyInteractionInfoReactions(
          chatId,
          messageId,
          update['interaction_info'],
        );
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
      // SaluteSpeech may edit ack → transcript (updateMessageContent).
      _onSmartSpeechBotMessage(msg);
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
        // Keep snapshot until the first loadChats page promotes the surface
        // (empty chatOrder after soft-restart would otherwise flash FC-only).
        _hubHydrateComplete = false;
        if (_hubSurfaceReady && _chatOrder.isEmpty) {
          _hubSurfaceReady = false;
          notifyListeners();
        }
        unawaited(_setTdlibOnline(true));
        _ensureNetworkLinkWatch();
        _armHubBootUiQuiet(why: 'auth-ready');
        // loadChats immediately (no +1.8s) — TG getDialogs right after Ready.
        unawaited(_hydrateHubAfterReady());
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
      // R32 (36h SessionLog 10–11 Oct): after setTdlibParameters TDLib dials
      // **direct** → Ready@~300ms, then enableProxy (~1–4s later) tears that
      // session → FakeTLS Ready briefly → collapse. Official never dials
      // without proxy. Hold networkTypeNone until proxy is enabled; caller
      // then releases WiFi/Mobile (first dial = FakeTLS only).
      await sendParams();
      _mediaLog('boot setTdlibParameters ok');
      await _setNetworkType(
        'networkTypeNone',
        why: 'boot-hold-until-proxy',
        force: true,
      );
      await _ensureProxy();
      _mediaLog(
        'boot proxy step done conn=$_connectionState '
        'proxyOn=$_useMtprotoProxy id=${_enabledProxyId ?? "-"}',
      );
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

    await _loadMtprotoProxyMode();
    if (_mtprotoProxyMode == TdlibMtprotoProxyMode.alwaysOff) {
      _useMtprotoProxy = false;
      _useMtprotoProxyResolved = false;
      _mediaLog('proxy skipped (user alwaysOff)');
      await _disableAllProxiesUnlocked(c, why: 'user-mode-off');
      _enabledProxyId = null;
      return;
    }

    if (_mtprotoProxyMode == TdlibMtprotoProxyMode.alwaysOn) {
      // User force-on: skip geo (VPN / non-RU still FakeTLS).
      _useMtprotoProxyResolved = true;
      _useMtprotoProxy = true;
    } else {
      // R18 auto: follow geo. Do not force FakeTLS abroad
      // (VPN leave-RU must stay direct; return-to-RU re-enables via geo recheck).
      _useMtprotoProxyResolved ??= await shouldUseTdlibMtprotoProxy();
      _useMtprotoProxy = _useMtprotoProxyResolved!;
      if (!_useMtprotoProxy) {
        _mediaLog('proxy skipped (IP outside RU — direct MTProto)');
        await _disableAllProxiesUnlocked(c, why: 'geo-non-ru');
        _enabledProxyId = null;
        return;
      }
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
      // Prefer the hop that last reached Ready on this radio (wifi vs mobile
      // prefs). R24 mid-ladder skip stuck us on dead 8443 — SessionLog
      // 14:41–14:44. Load remaps to R67 default when this radio has no
      // preferred (legacy mobile `:8443` must not sticky-restore on Wi‑Fi).
      // MegaFon Wi‑Fi that needs `:8443` keeps it via v2_wifi after Pong.
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
        _lastProxyPingFailAt = null;
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
      // R51: remember fail so Ready+0B stall can soft-restart zombie plane.
      _noteProxyPingFail(e);
      _mediaLog('proxy ping soft-fail id=$proxyId err=$e');
    } catch (e) {
      _noteProxyPingFail(e);
      _mediaLog('proxy ping soft-fail id=$proxyId err=$e');
    }
  }

  void _noteProxyPingFail(Object err) {
    final s = err.toString();
    // TearDown / dispose races are not plane-health signals.
    if (s.contains('disposed') ||
        s.contains('closed') ||
        s.contains('client is null')) {
      return;
    }
    _lastProxyPingFailAt = DateTime.now();
  }

  void _flushPendingMediaAfterSoftRestart() {
    if (_pendingMediaAfterSoftRestart.isEmpty) return;
    if (!_tdlibReadyForMedia || !_canStartNetworkDownload) return;
    final jobs = List<_TdlibDownloadJob>.of(_pendingMediaAfterSoftRestart);
    _pendingMediaAfterSoftRestart.clear();
    _mediaLog(
      'flush-pending-after-soft-restart n=${jobs.length} '
      'files=${jobs.map((j) => j.fileId).join(',')}',
    );
    for (final j in jobs) {
      _queueFileDownload(
        j.fileId,
        priority: j.priority,
        background: j.background,
        chatId: j.chatId ?? _openChatId,
        reason: j.reason.isEmpty ? 'stall-retry:zombie-plane' : j.reason,
      );
    }
    _pumpDownloadQueue();
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
        final serviceText = _serviceContentText(
          content,
          senderUserId: senderUserId,
        );
        if (serviceText != null) {
          isService = true;
          text = serviceText;
        } else {
          text = _friendlyContentLabel(ctype);
        }
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
      var pre = false;
      String? language;
      String? url;
      String? urlKind;
      var blockquote = false;
      var expandableBlockquote = false;
      if (t == 'textEntityTypeBold') {
        bold = true;
      } else if (t == 'textEntityTypeItalic') {
        italic = true;
      } else if (t == 'textEntityTypeUnderline') {
        underline = true;
      } else if (t == 'textEntityTypeStrikethrough') {
        strikethrough = true;
      } else if (t == 'textEntityTypeCode') {
        code = true;
      } else if (t == 'textEntityTypePre') {
        pre = true;
      } else if (t == 'textEntityTypePreCode') {
        pre = true;
        final lang = type['language']?.toString();
        if (lang != null && lang.isNotEmpty) language = lang;
      } else if (t == 'textEntityTypeBlockQuote') {
        blockquote = true;
      } else if (t == 'textEntityTypeExpandableBlockQuote') {
        expandableBlockquote = true;
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
        if (pre) 'pre': true,
        if (language != null && language.isNotEmpty) 'language': language,
        if (blockquote) 'blockquote': true,
        if (expandableBlockquote) 'expandable_blockquote': true,
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
      final progressive = _readProgressiveSizes(raw);
      if (progressive.isNotEmpty) {
        _photoProgressiveSizes[id] = progressive;
      }
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
      _rememberFullscreenUpgrade(
        primaryId: chosen.fileId,
        primaryType: chosen.type,
        byType: byType,
      );
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

  List<int> _readProgressiveSizes(Map raw) {
    final ps = raw['progressive_sizes'];
    if (ps is! List || ps.isEmpty) return const [];
    final out = <int>[];
    for (final v in ps) {
      final n = (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
      if (n > 0) out.add(n);
    }
    if (out.isEmpty) return const [];
    out.sort();
    return out;
  }

  /// Bubble keeps `x`; fullscreen may pull `y` then `w` (official screen pick).
  void _rememberFullscreenUpgrade({
    required int primaryId,
    required String primaryType,
    required Map<String, int> byType,
  }) {
    if (primaryId <= 0) return;
    int? upgrade;
    if (primaryType == 'w') {
      upgrade = null;
    } else if (primaryType == 'y') {
      upgrade = byType['w'];
    } else {
      // x / m / s / unknown — prefer y (~1280 phone), else w.
      upgrade = byType['y'] ?? byType['w'];
    }
    if (upgrade != null && upgrade != primaryId) {
      _photoFullscreenUpgrade[primaryId] = upgrade;
    } else {
      _photoFullscreenUpgrade.remove(primaryId);
    }
  }

  /// Official TG: as the full JPEG downloads from offset=0, paint progressive
  /// prefixes so the bubble "resolves" instead of staying on minithumb.
  void _maybePaintProgressivePhoto(int fileId, Map local) {
    final prefixes = _photoProgressiveSizes[fileId];
    if (prefixes == null || prefixes.isEmpty) return;
    if (_hasUsablePhotoCached(fileId, minBytes: 3 * 1024)) return;
    final offset = _tdlibInt(local['download_offset']);
    if (offset != 0) return;
    final path = local['path']?.toString();
    if (path == null || path.isEmpty) return;
    final avail = _tdlibInt(local['downloaded_prefix_size']);
    final downloaded = _tdlibInt(local['downloaded_size']);
    final have = avail > 0 ? avail : downloaded;
    if (have <= 0) return;
    // Skip tiny prefixes — minithumb already covers them; need a real scan.
    const minPaint = 8 * 1024;
    var hit = 0;
    for (final p in prefixes) {
      if (p >= minPaint && have >= p) hit = p;
    }
    if (hit <= 0 && have >= minPaint) {
      // No declared thresholds crossed but we have enough bytes — paint once.
      hit = have < 64 * 1024 ? have : 64 * 1024;
    }
    if (hit <= 0) return;
    final painted = _photoProgressivePaintedBytes[fileId] ?? 0;
    if (hit <= painted) return;
    if (_progressivePaintInFlight.contains(fileId)) return;
    _progressivePaintInFlight.add(fileId);
    unawaited(_paintProgressivePhotoPrefix(fileId, path, hit));
  }

  Future<void> _paintProgressivePhotoPrefix(
    int fileId,
    String srcPath,
    int bytes,
  ) async {
    try {
      final src = File(srcPath);
      if (!src.existsSync()) return;
      final len = src.lengthSync();
      if (len < bytes) return;
      final raf = await src.open();
      late final List<int> data;
      try {
        await raf.setPosition(0);
        data = await raf.read(bytes);
      } finally {
        await raf.close();
      }
      if (data.length < 4) return;
      // JPEG SOI
      if (data[0] != 0xFF || data[1] != 0xD8) return;
      final dir = await getTemporaryDirectory();
      final outPath = p.join(dir.path, 'tdlib_prog_${fileId}_$bytes.jpg');
      final out = File(outPath);
      await out.writeAsBytes(data, flush: true);
      _progressivePaintPath[fileId] = outPath;
      _photoProgressivePaintedBytes[fileId] = bytes;
      // Stamp messages so bubbles rebuild without waiting for full complete.
      final msg = _findMessageForFileId(fileId);
      if (msg != null) {
        final patched = _copyMessage(msg, photoLocalPath: outPath);
        _upsertMessage(patched);
      }
      _mediaLog(
        'photo-progressive paint file=$fileId bytes=${_fmtBytes(bytes)} '
        'path=${p.basename(outPath)}',
      );
      _notifyUi();
    } catch (e) {
      _mediaLog('photo-progressive FAIL file=$fileId err=$e');
    } finally {
      _progressivePaintInFlight.remove(fileId);
    }
  }

  void _clearProgressivePhotoPaint(int fileId) {
    _progressivePaintPath.remove(fileId);
    _photoProgressivePaintedBytes.remove(fileId);
    _progressivePaintInFlight.remove(fileId);
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
      case 'messageChatAddMembers':
        return 'Добавлен участник';
      case 'messageChatJoinByLink':
      case 'messageChatJoinByRequest':
        return 'Новый участник';
      case 'messageChatDeleteMember':
        return 'Участник вышел';
      case 'messageChatChangeTitle':
        return 'Название изменено';
      case 'messageChatChangePhoto':
        return 'Фото группы изменено';
      case 'messageChatDeletePhoto':
        return 'Фото группы удалено';
      case 'messagePinMessage':
        return 'Сообщение закреплено';
      case 'messageBasicGroupChatCreate':
      case 'messageSupergroupChatCreate':
        return 'Группа создана';
      case 'messageUnsupported':
        return 'Неподдерживаемое сообщение';
      default:
        return 'Вложение';
    }
  }

  /// Localized service/system content (add/join/leave/pin/…), Telegram-style.
  /// Returns null when [content] is not a handled service type.
  String? _serviceContentText(
    Map content, {
    int senderUserId = 0,
  }) {
    final type = content['@type']?.toString() ?? '';
    if (senderUserId > 0) _ensureUserCached(senderUserId);
    final actor = senderUserId > 0
        ? _memberDisplayName(senderUserId)
        : 'Участник';

    switch (type) {
      case 'messageChatAddMembers': {
        final ids = <int>[];
        final raw = content['member_user_ids'];
        if (raw is List) {
          for (final id in raw) {
            final uid = _tdlibInt(id);
            if (uid > 0) ids.add(uid);
          }
        }
        for (final uid in ids) {
          _ensureUserCached(uid);
        }
        if (ids.isEmpty) return '$actor добавил(а) участника';
        if (ids.length == 1 && ids.first == senderUserId) {
          return '$actor присоединился(ась) к группе';
        }
        final names = ids
            .where((uid) => uid != senderUserId || ids.length == 1)
            .map(_memberDisplayName)
            .toList();
        final joined = names.isEmpty
            ? ids.map(_memberDisplayName).toList()
            : names;
        return '$actor добавил(а) ${_joinMemberNames(joined)}';
      }
      case 'messageChatJoinByLink':
      case 'messageChatJoinByRequest':
        return '$actor присоединился(ась) к группе';
      case 'messageChatDeleteMember': {
        final uid = _tdlibInt(content['user_id']);
        if (uid > 0) _ensureUserCached(uid);
        if (uid <= 0 || uid == senderUserId) {
          return '$actor вышел(а) из группы';
        }
        return '$actor исключил(а) ${_memberDisplayName(uid)}';
      }
      case 'messageChatChangeTitle': {
        final title = content['title']?.toString().trim() ?? '';
        return title.isEmpty
            ? '$actor изменил(а) название группы'
            : '$actor изменил(а) название группы на «$title»';
      }
      case 'messageChatChangePhoto':
        return '$actor изменил(а) фото группы';
      case 'messageChatDeletePhoto':
        return '$actor удалил(а) фото группы';
      case 'messagePinMessage':
        return '$actor закрепил(а) сообщение';
      case 'messageBasicGroupChatCreate':
      case 'messageSupergroupChatCreate':
        return '$actor создал(а) группу';
      case 'messageScreenshotTaken':
        return '$actor сделал(а) снимок экрана';
      case 'messageChatSetMessageAutoDeleteTime': {
        final sec = _tdlibInt(content['message_auto_delete_time']);
        if (sec <= 0) {
          return '$actor отключил(а) автоудаление';
        }
        return '$actor включил(а) автоудаление';
      }
      default:
        return null;
    }
  }

  String _memberDisplayName(int userId) {
    final user = _users[userId];
    if (user == null) return 'Участник';
    final first = user['first_name']?.toString() ?? '';
    final last = user['last_name']?.toString() ?? '';
    final name = ('$first $last').trim();
    return name.isEmpty ? 'Участник' : name;
  }

  String _joinMemberNames(List<String> names) {
    if (names.isEmpty) return 'участника';
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} и ${names[1]}';
    final head = names.sublist(0, names.length - 1).join(', ');
    return '$head и ${names.last}';
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
    var senderUserId = 0;
    final sender = last['sender_id'];
    if (sender is Map && sender['@type'] == 'messageSenderUser') {
      senderUserId = _tdlibInt(sender['user_id']);
    }
    final serviceText = _serviceContentText(
      content,
      senderUserId: senderUserId,
    );
    if (serviceText != null) return serviceText;
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
