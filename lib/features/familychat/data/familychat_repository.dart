import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../../../core/config/env.dart';
import '../../../core/debug/upload_image_exif_log.dart';
import '../../../core/media/direct_s3_upload.dart';
import '../../../core/network/api_client.dart';
import '../../../core/notifications/familychat_foreground_bridge.dart';
import '../../../core/settings/app_settings.dart';
import '../../chat/data/link_preview_service.dart';

class ThreadMessagesPage {
  const ThreadMessagesPage({
    required this.messages,
    required this.hasMore,
    this.birthdayScheduled,
    this.voiceTranscriptionEnabled = false,
    this.pinnedMessages = const [],
  });

  final List<Map<String, dynamic>> messages;
  final bool hasMore;
  final Map<String, dynamic>? birthdayScheduled;
  final bool voiceTranscriptionEnabled;
  final List<Map<String, dynamic>> pinnedMessages;
}

class FamilyChatRepository {
  FamilyChatRepository(this._client);

  final ApiClient _client;
  Dio get _dio => _client.dio;
  static final Map<String, Uint8List> _attachmentBytesCache =
      <String, Uint8List>{};
  static final Map<String, Future<Uint8List>> _attachmentBytesInFlight =
      <String, Future<Uint8List>>{};
  static final Map<int, Uint8List> _avatarBytesCache = <int, Uint8List>{};
  static final Map<int, Future<Uint8List>> _avatarBytesInFlight =
      <int, Future<Uint8List>>{};
  static final List<String> _attachmentLru = <String>[];
  static final List<int> _avatarLru = <int>[];
  static const int _maxAttachmentCacheEntries = 64;
  static const int _maxAvatarCacheEntries = 32;

  static void _touchAttachmentLru(String key) {
    _attachmentLru.remove(key);
    _attachmentLru.add(key);
    while (_attachmentLru.length > _maxAttachmentCacheEntries) {
      final evict = _attachmentLru.removeAt(0);
      _attachmentBytesCache.remove(evict);
    }
  }

  static void _putAttachmentCache(String key, Uint8List bytes) {
    _attachmentBytesCache[key] = bytes;
    _touchAttachmentLru(key);
  }

  static void _touchAvatarLru(int userId) {
    _avatarLru.remove(userId);
    _avatarLru.add(userId);
    while (_avatarLru.length > _maxAvatarCacheEntries) {
      final evict = _avatarLru.removeAt(0);
      _avatarBytesCache.remove(evict);
    }
  }

  static void _putAvatarCache(int userId, Uint8List bytes) {
    _avatarBytesCache[userId] = bytes;
    _touchAvatarLru(userId);
  }

  /// Сколько полных файлов вложений качаем одновременно (web/bytes path).
  static const int maxConcurrentAttachmentDownloads = 3;
  static int _attachmentDownloadsActive = 0;
  static final List<void Function()> _attachmentDownloadWaiters = <void Function()>[];

  static Uint8List? peekMemberAvatarBytes(int userId) {
    final cached = _avatarBytesCache[userId];
    if (cached != null && cached.isNotEmpty) {
      _touchAvatarLru(userId);
      return cached;
    }
    return null;
  }

  static Uint8List? peekChatAttachmentBytes(int threadId, int attachmentId) {
    final key = '$threadId:$attachmentId';
    final cached = _attachmentBytesCache[key];
    if (cached != null && cached.isNotEmpty) {
      _touchAttachmentLru(key);
      return cached;
    }
    return null;
  }

  static Future<void> _acquireAttachmentDownloadSlot() async {
    while (_attachmentDownloadsActive >= maxConcurrentAttachmentDownloads) {
      final ready = Completer<void>();
      _attachmentDownloadWaiters.add(() {
        if (!ready.isCompleted) ready.complete();
      });
      await ready.future;
    }
    _attachmentDownloadsActive++;
  }

  static void _releaseAttachmentDownloadSlot() {
    if (_attachmentDownloadsActive > 0) {
      _attachmentDownloadsActive--;
    }
    if (_attachmentDownloadWaiters.isEmpty) return;
    final next = _attachmentDownloadWaiters.removeAt(0);
    next();
  }

  Future<Map<String, dynamic>> status({bool? appForeground}) async {
    final fg = appForeground ?? FamilyChatForegroundBridge.isAppInForeground();
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/status/',
      queryParameters: {'app_foreground': fg ? '1' : '0'},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> uploadProfileAvatarBytes(Uint8List bytes) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: 'avatar.png',
        contentType: DioMediaType.parse('image/png'),
      ),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/me/avatar/',
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(minutes: 2),
      ),
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> deleteProfileAvatar() async {
    final res =
        await _dio.delete<Map<String, dynamic>>('familychat/me/avatar/');
    return res.data!;
  }

  Future<Map<String, dynamic>> onboardingPrefill() async {
    final res =
        await _dio.get<Map<String, dynamic>>('familychat/onboarding/prefill/');
    return res.data!;
  }

  Future<Map<String, dynamic>> updateProfile({
    String? firstName,
    String? lastName,
    String? gender,
    String? birthDate,
    bool? birthdayShowYear,
    bool? suggestFaceTagging,
    String? themeSeedColor,
  }) async {
    final data = <String, dynamic>{};
    if (firstName != null) data['first_name'] = firstName;
    if (lastName != null) data['last_name'] = lastName;
    if (gender != null) data['gender'] = gender;
    if (birthDate != null) data['birth_date'] = birthDate;
    if (birthdayShowYear != null) data['birthday_show_year'] = birthdayShowYear;
    if (suggestFaceTagging != null)
      data['suggest_face_tagging'] = suggestFaceTagging;
    if (themeSeedColor != null) data['theme_seed_color'] = themeSeedColor;
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/me/profile/',
      data: data,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> memberProfile(int userId) async {
    final res =
        await _dio.get<Map<String, dynamic>>('familychat/members/$userId/');
    return res.data!;
  }

  Future<Map<String, dynamic>> memberDmThread(int userId) async {
    final res = await _dio
        .post<Map<String, dynamic>>('familychat/members/$userId/dm-thread/');
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> kinshipOptions() async {
    final res = await _dio.get<List<dynamic>>('familychat/kinship-options/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> saveProfile({
    required String firstName,
    required String lastName,
    required String gender,
    required String birthDate,
    required bool birthdayShowYear,
  }) async {
    return updateProfile(
      firstName: firstName,
      lastName: lastName,
      gender: gender,
      birthDate: birthDate,
      birthdayShowYear: birthdayShowYear,
    );
  }

  Future<Map<String, dynamic>> fetchInviteInfo(String token) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/invite/$token/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> resolveDeferredInvite() async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/deferred-invite/resolve/',
      data: const <String, dynamic>{},
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> createFamily({String? name}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/onboarding/create-family/',
      data: {if (name != null && name.isNotEmpty) 'name': name},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createInvite(String relationshipCode) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/invites/',
      data: {'relationship_code': relationshipCode},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> acceptInvite(
    String token, {
    bool confirmTransfer = false,
  }) async {
    final data = <String, dynamic>{};
    if (confirmTransfer) {
      data['confirm_transfer'] = true;
    }
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/invite/$token/accept/',
      data: data.isEmpty ? null : data,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createFriendInvite() async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/friend-invites/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> fetchFriendInviteInfo(String token) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/friend-invite/$token/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> acceptFriendInvite(String token) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/friend-invite/$token/accept/',
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> listFriends() async {
    final res = await _dio.get<Map<String, dynamic>>('familychat/friends/');
    return (res.data?['contacts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<void> hideFriend(int peerUserId) async {
    await _dio.post('familychat/friends/$peerUserId/hide/');
  }

  Future<Map<String, dynamic>> startOnboardingQuestions(String token) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/onboarding/questions/',
      data: {'invitation_token': token},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> completeOnboarding({
    required int sessionId,
    required List<Map<String, dynamic>> answers,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/onboarding/complete/',
      data: {
        'onboarding_session_id': sessionId,
        'answers': answers,
      },
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> members() async {
    final res = await _dio.get<List<dynamic>>('familychat/members/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> children() async {
    final res = await _dio.get<List<dynamic>>('familychat/children/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> childrenImportable() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/children/importable/',
    );
    final babies = res.data?['babies'];
    if (babies is! List) return [];
    return babies.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> importChildFromDiary({
    int? motherUserId,
    int? fatherUserId,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/children/import/',
      data: {
        if (motherUserId != null) 'mother_user_id': motherUserId,
        if (fatherUserId != null) 'father_user_id': fatherUserId,
      },
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> childDetail(int childId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/children/$childId/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> childGalleryPhotos(
    int childId, {
    int limit = 50,
    int? beforeId,
    String? albumId,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/children/$childId/gallery/photos/',
      queryParameters: {
        'limit': limit,
        if (beforeId != null) 'before_id': beforeId,
        if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
      },
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> childGalleryUpload({
    required int childId,
    required Uint8List bytes,
    required String filename,
    String? contentType,
    String? batchId,
    int? albumPk,
    Map<String, dynamic>? photoExif,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType:
            contentType != null ? DioMediaType.parse(contentType) : null,
      ),
      if (batchId != null && batchId.isNotEmpty) 'batch_id': batchId,
      if (albumPk != null) 'album_pk': albumPk,
      if (photoExif != null && photoExif.isNotEmpty)
        'photo_exif': jsonEncode(photoExif),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/children/$childId/gallery/upload/',
      data: form,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createChildCustomAlbum(
    int childId, {
    required String title,
    String accessMode = 'all',
    List<int> accessUserIds = const [],
    String addMode = 'all',
    List<int> addUserIds = const [],
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/children/$childId/gallery/albums/',
      data: {
        'title': title,
        'access_mode': accessMode,
        'access_user_ids': accessUserIds,
        'add_mode': addMode,
        'add_user_ids': addUserIds,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> updateChildCustomAlbum(
    int childId,
    int albumPk, {
    String? title,
    String? accessMode,
    List<int>? accessUserIds,
    String? addMode,
    List<int>? addUserIds,
  }) async {
    final data = <String, dynamic>{};
    if (title != null) data['title'] = title;
    if (accessMode != null) data['access_mode'] = accessMode;
    if (accessUserIds != null) data['access_user_ids'] = accessUserIds;
    if (addMode != null) data['add_mode'] = addMode;
    if (addUserIds != null) data['add_user_ids'] = addUserIds;
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/children/$childId/gallery/custom-albums/$albumPk/',
      data: data,
    );
    return res.data!;
  }

  Future<void> deleteChildCustomAlbum(int childId, int albumPk) async {
    await _dio.delete(
      'familychat/children/$childId/gallery/custom-albums/$albumPk/',
    );
  }

  Future<int> addPhotosToChildCustomAlbum(
    int childId,
    int albumPk,
    List<int> attachmentIds,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/children/$childId/gallery/custom-albums/$albumPk/photos/',
      data: {'attachment_ids': attachmentIds},
    );
    final added = res.data?['added'];
    if (added is int) return added;
    return int.tryParse('$added') ?? 0;
  }

  Future<void> removePhotoFromChildCustomAlbum({
    required int childId,
    required int albumPk,
    required int attachmentId,
  }) async {
    await _dio.delete(
      'familychat/children/$childId/gallery/custom-albums/$albumPk/photos/$attachmentId/',
    );
  }

  Future<void> deleteChildGalleryPhoto({
    required int childId,
    required int attachmentId,
  }) async {
    await _dio.delete(
      'familychat/children/$childId/gallery/photos/$attachmentId/',
    );
  }

  /// LittleOne Diary baby card (requires diary membership).
  Future<Map<String, dynamic>?> diaryBaby() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('littleone-diary/baby/');
      return res.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403 || e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> diaryMilestones() async {
    try {
      final res =
          await _dio.get<Map<String, dynamic>>('littleone-diary/milestones/');
      final list = res.data?['milestones'];
      if (list is! List) return [];
      return list.cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      if (e.response?.statusCode == 403 || e.response?.statusCode == 404) {
        return [];
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> diaryMilestoneDetail(String code) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'littleone-diary/milestones/$code/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> patchDiaryMilestone(
    String code,
    Map<String, dynamic> data,
  ) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'littleone-diary/milestones/$code/',
      data: data,
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> patchDiaryBaby(Map<String, dynamic> data) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'littleone-diary/baby/',
      data: data,
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> createScrapbookShare() async {
    final res = await _dio.post<Map<String, dynamic>>(
      'littleone-diary/scrapbook/share/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> publicScrapbook(String token) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'littleone-diary/public/scrapbook/$token/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> saveMilestoneMediaLayouts(
    String code,
    Map<String, dynamic> layouts,
  ) async {
    final res = await _dio.put<Map<String, dynamic>>(
      'littleone-diary/milestones/$code/media-layouts/',
      data: {'layouts': layouts},
    );
    return res.data ?? {};
  }

  Future<List<Map<String, dynamic>>> childGalleryAlbums(int childId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/children/$childId/gallery/albums/',
    );
    final albums = res.data?['albums'];
    if (albums is! List) return [];
    return albums.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> familyTree() async {
    final res =
        await _dio.get<Map<String, dynamic>>('familychat/members/tree/');
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> previewFamilyTreeKinshipChanges(
    List<Map<String, dynamic>> changes,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/tree/preview/',
      data: {'changes': changes},
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> saveFamilyTreeKinshipChanges(
    List<Map<String, dynamic>> changes,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/tree/save/',
      data: {'changes': changes},
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> calendar({
    required int year,
    required int month,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/',
      queryParameters: {'year': year, 'month': month},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> calendarAgenda({required int year}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/',
      queryParameters: {'year': year, 'agenda': '1'},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> birthdayDetail({
    required int userId,
    required int year,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/members/$userId/birthday/',
      queryParameters: {'year': year},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> updateBirthdayPreference({
    required int userId,
    required bool skipCongratulations,
    required int year,
  }) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/members/$userId/birthday/',
      queryParameters: {'year': year},
      data: {'skip_congratulations': skipCongratulations},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> fetchCalendarEvent(int eventId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/events/$eventId/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createCalendarEvent(
      Map<String, dynamic> body) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/calendar/events/',
      data: body,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> updateCalendarEvent(
    int eventId,
    Map<String, dynamic> body,
  ) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/calendar/events/$eventId/',
      data: body,
    );
    return res.data!;
  }

  Future<void> deleteCalendarEvent(int eventId) async {
    await _dio.delete('familychat/calendar/events/$eventId/');
  }

  Future<Map<String, dynamic>> fetchCalendarAlbumPhotoSync(int albumPk) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/albums/$albumPk/photo-sync/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> registerCalendarSyncedAssets(
    int albumPk,
    List<String> deviceAssetIds, {
    Map<String, int>? attachmentIdsByDevice,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/calendar/albums/$albumPk/photo-sync/',
      data: {
        'device_asset_ids': deviceAssetIds,
        if (attachmentIdsByDevice != null && attachmentIdsByDevice.isNotEmpty)
          'attachment_ids_by_device': attachmentIdsByDevice,
      },
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> activeCalendarPhotoSyncs() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/photo-sync/active/',
    );
    return (res.data?['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<List<Map<String, dynamic>>> pendingCalendarPhotoReviews() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/photo-sync/pending-review/',
    );
    return (res.data?['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<Map<String, dynamic>> fetchCalendarStagingPhotos(int eventId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/events/$eventId/staging/photos/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> promoteCalendarStagingPhotos(
    int eventId,
    List<int> attachmentIds,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/calendar/events/$eventId/staging/promote/',
      data: {'attachment_ids': attachmentIds},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> rejectCalendarStagingPhotos(
    int eventId,
    List<int> attachmentIds,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/calendar/events/$eventId/staging/reject/',
      data: {'attachment_ids': attachmentIds},
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> chatThreads() async {
    final res =
        await _dio.get<Map<String, dynamic>>('familychat/chat/threads/');
    return (res.data?['threads'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<Map<String, dynamic>> createGroupChat({
    required String title,
    required List<int> memberUserIds,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/groups/',
      data: {'title': title, 'member_user_ids': memberUserIds},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> leaveChatThread(int threadId) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/leave/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> rejoinChatThread(int threadId) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/rejoin/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> addChatThreadMembers(
    int threadId,
    List<int> memberUserIds,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/members/',
      data: {'member_user_ids': memberUserIds},
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> threadParticipants(int threadId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/members/',
    );
    final raw = res.data?['participants'];
    if (raw is! List) return [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<ThreadMessagesPage> threadMessages(
    int threadId, {
    int limit = 20,
    int? beforeId,
  }) async {
    final res = await _dio.get<dynamic>(
      'familychat/chat/threads/$threadId/messages/',
      queryParameters: {
        'limit': limit,
        if (beforeId != null) 'before_id': beforeId,
      },
    );
    final data = res.data;
    if (data is List) {
      final messages = data.cast<Map<String, dynamic>>();
      return ThreadMessagesPage(
          messages: messages, hasMore: messages.length >= limit);
    }
    final map = (data as Map<String, dynamic>?) ?? {};
    final raw = map['messages'];
    final messages = raw is List
        ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : <Map<String, dynamic>>[];
    final scheduledRaw = map['birthday_scheduled'];
    final pinnedRaw = map['pinned_messages'];
    return ThreadMessagesPage(
      messages: messages,
      hasMore: map['has_more'] == true,
      birthdayScheduled: scheduledRaw is Map
          ? Map<String, dynamic>.from(scheduledRaw)
          : null,
      voiceTranscriptionEnabled: map['voice_transcription_enabled'] == true,
      pinnedMessages: pinnedRaw is List
          ? pinnedRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : const [],
    );
  }

  Future<Map<String, dynamic>> birthdayScheduledCongratulation(
    int threadId,
  ) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/birthday-scheduled-congratulation/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> saveBirthdayScheduledCongratulation(
    int threadId, {
    required String body,
    List<int>? attachmentIds,
    int? videoNoteDurationMs,
  }) async {
    final res = await _dio.put<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/birthday-scheduled-congratulation/',
      data: {
        'body': body,
        'attachment_ids': attachmentIds ?? const <int>[],
        'message_metadata': videoNoteDurationMs != null
            ? {
                'video_note': {'duration_ms': videoNoteDurationMs},
              }
            : <String, dynamic>{},
      },
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> deleteBirthdayScheduledCongratulation(
    int threadId,
  ) async {
    final res = await _dio.delete<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/birthday-scheduled-congratulation/',
    );
    return res.data ?? {};
  }

  Future<void> markThreadRead(int threadId,
      {required int lastMessageId}) async {
    await _dio.post(
      'familychat/chat/threads/$threadId/read/',
      data: {'last_message_id': lastMessageId},
    );
  }

  String chatAttachmentContentUrl(int threadId, int attachmentId) {
    final base =
        Env.apiBaseUrl.endsWith('/') ? Env.apiBaseUrl : '${Env.apiBaseUrl}/';
    return '${base}familychat/chat/threads/$threadId/attachments/$attachmentId/content/';
  }

  String memberAvatarContentUrl(int userId) {
    final base =
        Env.apiBaseUrl.endsWith('/') ? Env.apiBaseUrl : '${Env.apiBaseUrl}/';
    return '${base}familychat/members/$userId/avatar/content/';
  }

  Future<Uint8List> fetchMemberAvatarBytes(int userId) async {
    final cached = _avatarBytesCache[userId];
    if (cached != null && cached.isNotEmpty) {
      _touchAvatarLru(userId);
      return cached;
    }

    final inFlight = _avatarBytesInFlight[userId];
    if (inFlight != null) return inFlight;

    final future = _fetchMemberAvatarBytesUncached(userId).then((bytes) {
      _putAvatarCache(userId, bytes);
      return bytes;
    }).whenComplete(() => _avatarBytesInFlight.remove(userId));

    _avatarBytesInFlight[userId] = future;
    return future;
  }

  Future<Uint8List> _fetchMemberAvatarBytesUncached(int userId) async {
    final res = await _dio.get<List<int>>(
      'familychat/members/$userId/avatar/content/',
      options: Options(responseType: ResponseType.bytes),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw StateError('Пустой аватар');
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<Uint8List> fetchChatAttachmentBytes(
      int threadId, int attachmentId) async {
    final cacheKey = '$threadId:$attachmentId';
    final cached = _attachmentBytesCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      _touchAttachmentLru(cacheKey);
      return cached;
    }

    final inFlight = _attachmentBytesInFlight[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _fetchChatAttachmentBytesUncached(threadId, attachmentId)
        .then((bytes) {
      _putAttachmentCache(cacheKey, bytes);
      return bytes;
    }).whenComplete(() => _attachmentBytesInFlight.remove(cacheKey));

    _attachmentBytesInFlight[cacheKey] = future;
    return future;
  }

  Future<Uint8List> _fetchChatAttachmentBytesUncached(
    int threadId,
    int attachmentId,
  ) async {
    await _acquireAttachmentDownloadSlot();
    try {
      final res = await _dio.get<List<int>>(
        'familychat/chat/threads/$threadId/attachments/$attachmentId/content/',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      if (data == null || data.isEmpty) {
        throw StateError('Пустой файл');
      }
      return data is Uint8List ? data : Uint8List.fromList(data);
    } finally {
      _releaseAttachmentDownloadSlot();
    }
  }

  Future<Map<String, dynamic>> sendThreadMessage(
    int threadId, {
    String? body,
    List<int>? attachmentIds,
    int? replyToMessageId,
    List<int>? mentionedUserIds,
    bool notifySilent = false,
    Map<String, dynamic>? location,
    int? voiceDurationMs,
    String? voiceTranscript,
    int? videoNoteDurationMs,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/messages/',
      data: {
        if (body != null && body.isNotEmpty) 'body': body,
        if (attachmentIds != null && attachmentIds.isNotEmpty)
          'attachment_ids': attachmentIds,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (mentionedUserIds != null && mentionedUserIds.isNotEmpty)
          'mentioned_user_ids': mentionedUserIds,
        if (notifySilent) 'notify_silent': true,
        if (location != null) 'location': location,
        if (voiceDurationMs != null) 'voice_duration_ms': voiceDurationMs,
        if (voiceTranscript != null && voiceTranscript.trim().isNotEmpty)
          'voice_transcript': voiceTranscript.trim(),
        if (videoNoteDurationMs != null)
          'video_note_duration_ms': videoNoteDurationMs,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> updateThreadMessage(
    int threadId,
    int messageId, {
    required String body,
  }) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/messages/$messageId/',
      data: {'body': body},
    );
    return res.data ?? {};
  }

  Future<List<Map<String, dynamic>>> threadCallIceServers(int threadId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/call/ice-config/',
    );
    final list = res.data?['ice_servers'];
    if (list is! List) return const [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> startThreadCall(
    int threadId, {
    bool isVideo = false,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/call/start/',
      data: {'is_video': isVideo},
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> callAction(int callId, String action) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/calls/$callId/action/',
      data: {'action': action},
    );
    return res.data ?? {};
  }

  Future<void> sendCallSignal(
    int callId, {
    required String signalType,
    required Map<String, dynamic> payload,
  }) async {
    await _dio.post(
      'familychat/chat/calls/$callId/signal/',
      data: {'signal_type': signalType, 'payload': payload},
    );
  }

  Future<List<Map<String, dynamic>>> callSignals(
    int callId, {
    int afterId = 0,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/calls/$callId/signal/',
      queryParameters: afterId > 0 ? {'after_id': afterId} : null,
    );
    final list = res.data?['signals'];
    if (list is! List) return const [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> forwardMessages({
    required int sourceThreadId,
    required List<int> messageIds,
    required List<int> threadIds,
  }) async {
    await _dio.post(
      'familychat/chat/forward/',
      data: {
        'source_thread_id': sourceThreadId,
        'message_ids': messageIds,
        'thread_ids': threadIds,
      },
    );
  }

  Future<List<int>> deleteMessages(int threadId, List<int> messageIds) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/messages/delete/',
      data: {'message_ids': messageIds},
    );
    final ids = res.data?['deleted_ids'];
    if (ids is! List) return messageIds;
    return ids
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
  }

  Future<List<int>> hideMessagesForMe(int threadId, List<int> messageIds) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/messages/hide/',
      data: {'message_ids': messageIds},
    );
    final ids = res.data?['hidden_ids'];
    if (ids is! List) return messageIds;
    return ids
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
  }

  Future<String> aiComposeMessage(int threadId, {required String task}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/ai-compose/',
      data: {'task': task},
      options: Options(
        receiveTimeout: const Duration(seconds: 100),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    final suggestion = res.data?['suggestion']?.toString().trim() ?? '';
    if (suggestion.isEmpty) {
      throw StateError('empty ai suggestion');
    }
    return suggestion;
  }

  /// Озвучка сообщений (WAV). Только Premium + DM на бэкенде.
  Future<List<int>> speakMessages(int threadId, List<int> messageIds) async {
    final res = await _dio.post<List<int>>(
      'familychat/chat/threads/$threadId/messages/speak/',
      data: {'message_ids': messageIds},
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 180),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw StateError('empty speak audio');
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<List<Map<String, dynamic>>> pinMessage(
    int threadId,
    int messageId,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/pins/',
      data: {'message_id': messageId},
    );
    final raw = res.data?['pinned_messages'];
    if (raw is! List) return const [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> unpinMessage(
    int threadId,
    int messageId,
  ) async {
    final res = await _dio.delete<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/pins/$messageId/',
    );
    final raw = res.data?['pinned_messages'];
    if (raw is! List) return const [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<dynamic>> toggleMessageReaction(
    int threadId,
    int messageId,
    String emoji,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/messages/$messageId/reactions/',
      data: {'emoji': emoji},
    );
    final reactions = res.data?['reactions'];
    if (reactions is List) return reactions;
    return const [];
  }

  Future<Map<String, dynamic>> uploadChatAttachmentBytes(
    int threadId, {
    required Uint8List bytes,
    required String filename,
    String? contentType,
    Map<String, dynamic>? photoExif,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    await logUploadImageExifDiagnostics(
      bytes: bytes,
      filename: filename,
      readVia: 'upload_chat_attachment',
    );
    try {
      return await _uploadChatAttachmentDirect(
        threadId,
        bytes: bytes,
        filename: filename,
        contentType: contentType ?? 'application/octet-stream',
        photoExif: photoExif,
        onSendProgress: onSendProgress,
      );
    } catch (e, st) {
      debugPrint(
        'Direct S3 chat upload failed, legacy fallback: $e\n$st',
      );
      return _uploadChatAttachmentLegacy(
        threadId,
        bytes: bytes,
        filename: filename,
        contentType: contentType,
        photoExif: photoExif,
        onSendProgress: onSendProgress,
      );
    }
  }

  Future<Map<String, dynamic>> _uploadChatAttachmentDirect(
    int threadId, {
    required Uint8List bytes,
    required String filename,
    required String contentType,
    Map<String, dynamic>? photoExif,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final hash = sha256Hex(bytes);
    final prepareBody = <String, dynamic>{
      'filename': filename,
      'content_type': contentType,
      'content_hash': hash,
    };
    if (photoExif != null && photoExif.isNotEmpty) {
      prepareBody['photo_exif'] = jsonEncode(photoExif);
    }
    final prepare = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/prepare/',
      data: prepareBody,
    );
    final data = prepare.data ?? {};
    if (data['status'] == 'ready') {
      final att = data['attachment'];
      if (att is Map<String, dynamic>) return att;
      throw StateError('prepare ready without attachment');
    }
    final uploadUrl = data['upload_url']?.toString() ?? '';
    final storageKey = data['storage_key']?.toString() ?? '';
    if (uploadUrl.isEmpty || storageKey.isEmpty) {
      throw StateError('prepare missing upload_url');
    }
    final headers = data['headers'];
    await putBytesToPresignedUrl(
      uploadUrl: uploadUrl,
      bytes: bytes,
      headers: headers is Map ? Map<String, dynamic>.from(headers) : const {},
      onSendProgress: onSendProgress,
    );
    final completeBody = <String, dynamic>{
      'storage_key': storageKey,
      'content_hash': hash,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': bytes.length,
      'kind': data['kind']?.toString() ?? 'file',
    };
    if (photoExif != null && photoExif.isNotEmpty) {
      completeBody['photo_exif'] = jsonEncode(photoExif);
    }
    final complete = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/complete/',
      data: completeBody,
    );
    return complete.data!;
  }

  Future<Map<String, dynamic>> _uploadChatAttachmentLegacy(
    int threadId, {
    required Uint8List bytes,
    required String filename,
    String? contentType,
    Map<String, dynamic>? photoExif,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final formMap = <String, dynamic>{
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType:
            contentType != null ? DioMediaType.parse(contentType) : null,
      ),
    };
    if (photoExif != null && photoExif.isNotEmpty) {
      formMap['photo_exif'] = jsonEncode(photoExif);
    }
    final form = FormData.fromMap(formMap);
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/',
      data: form,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> threadNotifications(int threadId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/notifications/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> setThreadMute(int threadId, String mute) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/notifications/',
      data: {'mute': mute},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> setThreadQuietHours(
    int threadId, {
    required String start,
    required String end,
    required int utcOffsetMinutes,
  }) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/notifications/',
      data: {
        'quiet_hours': {
          'start': start,
          'end': end,
          'utc_offset_minutes': utcOffsetMinutes,
        },
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> clearThreadQuietHours(int threadId) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/notifications/',
      data: {'quiet_hours': null},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> setThreadCustomTitle(
    int threadId,
    String customTitle,
  ) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/title/',
      data: {'custom_title': customTitle},
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> threadMedia(int threadId) async {
    final res = await _dio
        .get<List<dynamic>>('familychat/chat/threads/$threadId/media/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> memberGalleryAlbums(int userId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/albums/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> memberGalleryPhotos(
    int userId,
    String albumId, {
    int offset = 0,
    int limit = 60,
    String? query,
    int? personUserId,
    bool personUnidentified = false,
  }) async {
    final encodedAlbum = Uri.encodeComponent(albumId);
    final params = <String, dynamic>{'offset': offset, 'limit': limit};
    if (query != null && query.trim().isNotEmpty) params['q'] = query.trim();
    if (personUnidentified) {
      params['person_user_id'] = 'unidentified';
    } else if (personUserId != null) {
      params['person_user_id'] = personUserId;
    }
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/albums/$encodedAlbum/photos/',
      queryParameters: params,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> bulkTagGalleryPhotos(
    int userId,
    String albumId, {
    required List<int> attachmentIds,
    required String tag,
  }) async {
    final encodedAlbum = Uri.encodeComponent(albumId);
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/albums/$encodedAlbum/bulk-tag/',
      data: {
        'attachment_ids': attachmentIds,
        'tag': tag,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> deduplicateGalleryAlbum(
      int userId, String albumId) async {
    final encodedAlbum = Uri.encodeComponent(albumId);
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/albums/$encodedAlbum/deduplicate/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> bulkDeleteGalleryPhotos(
    int userId, {
    required List<int> attachmentIds,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/photos/bulk-delete/',
      data: {'attachment_ids': attachmentIds},
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> threadFiles(int threadId) async {
    final res = await _dio
        .get<List<dynamic>>('familychat/chat/threads/$threadId/files/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> threadLinks(int threadId) async {
    final res = await _dio
        .get<List<dynamic>>('familychat/chat/threads/$threadId/links/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> familyChatMessages() async {
    final res =
        await _dio.get<List<dynamic>>('familychat/chat/family/messages/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> sendFamilyChat(String body) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/family/messages/',
      data: {'body': body},
    );
    return res.data!;
  }

  Future<void> registerFcm({
    required String token,
    required String platform,
  }) async {
    await _dio.post(
      'familychat/fcm-registration/',
      data: {
        'token': token,
        'platform': platform,
      },
    );
  }

  Future<Map<String, dynamic>> attachmentTaggingStatus(
    int threadId,
    int attachmentId,
  ) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/tagging/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> chatAttachmentFaces(
    int threadId,
    int attachmentId,
  ) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/faces/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> assignChatAttachmentFace(
    int threadId,
    int attachmentId,
    int faceIndex, {
    int? userId,
    int? childId,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/faces/$faceIndex/assign/',
      data: {
        if (userId != null) 'user_id': userId,
        if (childId != null) 'child_id': childId,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createChatAttachmentManualFace(
    int threadId,
    int attachmentId, {
    int? userId,
    int? childId,
    required Map<String, dynamic> bbox,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/faces/manual/',
      data: {
        if (userId != null) 'user_id': userId,
        if (childId != null) 'child_id': childId,
        'bbox': bbox,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> deleteChatAttachment(
    int threadId,
    int attachmentId,
  ) async {
    final res = await _dio.delete<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/',
    );
    return res.data ?? const {'ok': true};
  }

  Future<Map<String, dynamic>> galleryPhotoFaces(
    int profileUserId,
    int attachmentId,
  ) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/members/$profileUserId/gallery/photos/$attachmentId/faces/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> assignGalleryPhotoFace(
    int profileUserId,
    int attachmentId,
    int faceIndex, {
    int? userId,
    int? childId,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$profileUserId/gallery/photos/$attachmentId/faces/$faceIndex/assign/',
      data: {
        if (userId != null) 'user_id': userId,
        if (childId != null) 'child_id': childId,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createGalleryPhotoManualFace(
    int profileUserId,
    int attachmentId, {
    int? userId,
    int? childId,
    required Map<String, dynamic> bbox,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$profileUserId/gallery/photos/$attachmentId/faces/manual/',
      data: {
        if (userId != null) 'user_id': userId,
        if (childId != null) 'child_id': childId,
        'bbox': bbox,
      },
    );
    return res.data!;
  }

  Future<void> hideGalleryPhoto(int attachmentId) async {
    await _dio.post('familychat/gallery/photos/$attachmentId/hide/');
  }

  Future<Map<String, dynamic>> createCustomGalleryAlbum(
    int userId, {
    required String title,
    String accessMode = 'all',
    List<int> accessUserIds = const [],
    String addMode = 'owner',
    List<int> addUserIds = const [],
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/custom-albums/',
      data: {
        'title': title,
        'access_mode': accessMode,
        'access_user_ids': accessUserIds,
        'add_mode': addMode,
        'add_user_ids': addUserIds,
      },
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> updateCustomGalleryAlbum(
    int userId,
    int albumPk, {
    String? title,
    String? accessMode,
    List<int>? accessUserIds,
    String? addMode,
    List<int>? addUserIds,
  }) async {
    final data = <String, dynamic>{};
    if (title != null) data['title'] = title;
    if (accessMode != null) data['access_mode'] = accessMode;
    if (accessUserIds != null) data['access_user_ids'] = accessUserIds;
    if (addMode != null) data['add_mode'] = addMode;
    if (addUserIds != null) data['add_user_ids'] = addUserIds;
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/custom-albums/$albumPk/',
      data: data,
    );
    return res.data!;
  }

  Future<void> deleteCustomGalleryAlbum(int userId, int albumPk) async {
    await _dio
        .delete('familychat/members/$userId/gallery/custom-albums/$albumPk/');
  }

  Future<int> addPhotosToCustomAlbum(
    int userId,
    int albumPk,
    List<int> attachmentIds, {
    bool shareToDiary = false,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/custom-albums/$albumPk/photos/',
      data: {
        'attachment_ids': attachmentIds,
        if (shareToDiary) 'share_to_diary': true,
      },
    );
    final added = res.data?['added'];
    if (added is int) return added;
    return int.tryParse('$added') ?? 0;
  }

  Future<Map<String, dynamic>> uploadPhotoToCustomAlbum(
    int userId,
    int albumPk, {
    required Uint8List bytes,
    required String filename,
    String? contentType,
    String? batchId,
    bool shareToDiary = false,
    Map<String, dynamic>? photoExif,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    await logUploadImageExifDiagnostics(
      bytes: bytes,
      filename: filename,
      readVia: 'upload_custom_album',
    );
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType:
            contentType != null ? DioMediaType.parse(contentType) : null,
      ),
      if (batchId != null && batchId.isNotEmpty) 'batch_id': batchId,
      if (shareToDiary) 'share_to_diary': '1',
      if (photoExif != null && photoExif.isNotEmpty)
        'photo_exif': jsonEncode(photoExif),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/custom-albums/$albumPk/photos/upload/',
      data: form,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    return res.data!;
  }

  Future<void> removePhotoFromCustomAlbum(
    int userId,
    int albumPk,
    int attachmentId,
  ) async {
    await _dio.delete(
      'familychat/members/$userId/gallery/custom-albums/$albumPk/photos/$attachmentId/',
    );
  }

  Future<Map<String, dynamic>> memberGalleryPickablePhotos(
    int userId, {
    int offset = 0,
    int limit = 60,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/pickable-photos/',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> familyFeed({
    int offset = 0,
    int limit = 30,
    int? personUserId,
    int? afterId,
  }) async {
    final params = <String, dynamic>{'offset': offset, 'limit': limit};
    if (personUserId != null) params['person_user_id'] = personUserId;
    if (afterId != null) params['after_id'] = afterId;
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/feed/',
      queryParameters: params,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> markFeedRead() async {
    final res = await _dio.post<Map<String, dynamic>>('familychat/feed/read/');
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> familyGalleryAlbums() async {
    final res =
        await _dio.get<Map<String, dynamic>>('familychat/gallery/albums/');
    return res.data!;
  }

  Future<Map<String, dynamic>> familyGalleryPhotos(
    String albumId, {
    int offset = 0,
    int limit = 60,
    String? query,
    int? personUserId,
    bool personUnidentified = false,
  }) async {
    final encodedAlbum = Uri.encodeComponent(albumId);
    final params = <String, dynamic>{'offset': offset, 'limit': limit};
    if (query != null && query.trim().isNotEmpty) params['q'] = query.trim();
    if (personUnidentified) {
      params['person_user_id'] = 'unidentified';
    } else if (personUserId != null) {
      params['person_user_id'] = personUserId;
    }
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/gallery/albums/$encodedAlbum/photos/',
      queryParameters: params,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> diaryShareStatus() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/diary-share/status/',
    );
    return res.data ?? {};
  }

  Future<FamilyChatAppSettings> fetchAppSettings() async {
    final res = await _dio.get<Map<String, dynamic>>('familychat/settings/');
    return FamilyChatAppSettings.fromJson(res.data ?? {});
  }

  Future<ChatLinkPreview?> fetchLinkPreview(String url) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/link-preview/',
      queryParameters: {'url': url},
    );
    final data = res.data;
    if (data == null || data.isEmpty) return null;
    final preview = ChatLinkPreview.fromJson(data, url);
    return preview;
  }

  Future<FamilyChatAppSettings> updateAppSettings(
    FamilyChatAppSettings settings,
  ) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/settings/',
      data: settings.toPatchJson(),
    );
    return FamilyChatAppSettings.fromJson(res.data ?? settings.toCacheJson());
  }

  Future<Map<String, dynamic>> familyGalleryUpload({
    required Uint8List bytes,
    required String filename,
    String? contentType,
    required String destination,
    int? albumPk,
    String? batchId,
    bool shareToDiary = false,
    Map<String, dynamic>? photoExif,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType:
            contentType != null ? DioMediaType.parse(contentType) : null,
      ),
      'destination': destination,
      if (albumPk != null) 'album_pk': albumPk,
      if (batchId != null && batchId.isNotEmpty) 'batch_id': batchId,
      if (shareToDiary) 'share_to_diary': '1',
      if (photoExif != null && photoExif.isNotEmpty)
        'photo_exif': jsonEncode(photoExif),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/gallery/upload/',
      data: form,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> completeFeedPhotoBatch(
    String batchId, {
    String? caption,
    bool shareToDiary = false,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/feed/photo-batch/complete/',
      data: {
        'batch_id': batchId,
        if (caption != null && caption.trim().isNotEmpty) 'caption': caption.trim(),
        if (shareToDiary) 'share_to_diary': true,
      },
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> mediaEngagement(int attachmentId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/media/$attachmentId/engagement/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> toggleMediaLike(int attachmentId) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/media/$attachmentId/engagement/',
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> toggleMediaReaction(
    int attachmentId, {
    required String emoji,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/media/$attachmentId/engagement/',
      data: {'emoji': emoji},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> markFeedEventViewed(int eventId) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/feed/events/$eventId/view/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> submitAppRating(int stars) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/app-rating/',
      data: {
        'stars': stars,
        'source': 'rustore_prompt',
        'app_name': 'familychat',
      },
    );
    return res.data ?? {};
  }

  Future<void> reportRustoreReviewError({
    required String stage,
    required String errorCode,
    String? errorMessage,
    String? reason,
    String? details,
  }) async {
    try {
      await _dio.post(
        'familychat/app-rating/rustore-error/',
        data: {
          'app_name': 'familychat',
          'stage': stage,
          'error_code': errorCode,
          if (errorMessage != null && errorMessage.isNotEmpty)
            'error_message': errorMessage,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
          if (details != null && details.isNotEmpty) 'details': details,
        },
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> locationSharingSettings() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/location/sharing/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> setLocationSharingViewers(
    List<int> viewerUserIds,
  ) async {
    final res = await _dio.put<Map<String, dynamic>>(
      'familychat/location/sharing/',
      data: {'viewer_user_ids': viewerUserIds},
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> setLocationShareWithMember({
    required int userId,
    required bool granted,
  }) async {
    final res = await _dio.put<Map<String, dynamic>>(
      'familychat/location/sharing/members/$userId/',
      data: {'granted': granted},
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> pingLocation({
    required double latitude,
    required double longitude,
    double? accuracyM,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/location/ping/',
      data: {
        'latitude': latitude,
        'longitude': longitude,
        if (accuracyM != null) 'accuracy_m': accuracyM,
      },
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> familyLocationMap() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/location/map/',
    );
    return res.data ?? {};
  }

  Future<Map<String, dynamic>> memberLocation(int userId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/location/members/$userId/',
    );
    return res.data ?? {};
  }

  Future<List<Map<String, dynamic>>> mediaComments(int attachmentId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/media/$attachmentId/comments/',
    );
    return (res.data?['comments'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> addMediaComment(
      int attachmentId, String body) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/media/$attachmentId/comments/',
      data: {'body': body},
    );
    return res.data!;
  }
}
