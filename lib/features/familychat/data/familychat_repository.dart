import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/config/env.dart';
import '../../../core/debug/upload_image_exif_log.dart';
import '../../../core/network/api_client.dart';

class ThreadMessagesPage {
  const ThreadMessagesPage({
    required this.messages,
    required this.hasMore,
  });

  final List<Map<String, dynamic>> messages;
  final bool hasMore;
}

class FamilyChatRepository {
  FamilyChatRepository(this._client);

  final ApiClient _client;
  Dio get _dio => _client.dio;
  static final Map<String, Uint8List> _attachmentBytesCache =
      <String, Uint8List>{};

  Future<Map<String, dynamic>> status() async {
    final res = await _dio.get<Map<String, dynamic>>('familychat/status/');
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
  }) async {
    final data = <String, dynamic>{};
    if (firstName != null) data['first_name'] = firstName;
    if (lastName != null) data['last_name'] = lastName;
    if (gender != null) data['gender'] = gender;
    if (birthDate != null) data['birth_date'] = birthDate;
    if (birthdayShowYear != null) data['birthday_show_year'] = birthdayShowYear;
    if (suggestFaceTagging != null)
      data['suggest_face_tagging'] = suggestFaceTagging;
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
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/onboarding/profile/',
      data: {
        'first_name': firstName,
        'last_name': lastName,
        'gender': gender,
        'birth_date': birthDate,
        'birthday_show_year': birthdayShowYear,
      },
    );
    return res.data!;
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

  Future<Map<String, dynamic>> acceptInvite(String token) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/invite/$token/accept/',
    );
    return res.data!;
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

  Future<Map<String, dynamic>> familyTree() async {
    final res =
        await _dio.get<Map<String, dynamic>>('familychat/members/tree/');
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
    List<String> deviceAssetIds,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/calendar/albums/$albumPk/photo-sync/',
      data: {'device_asset_ids': deviceAssetIds},
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> activeCalendarPhotoSyncs() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/calendar/photo-sync/active/',
    );
    return (res.data?['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
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
    return ThreadMessagesPage(
      messages: messages,
      hasMore: map['has_more'] == true,
    );
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

  Future<Uint8List> fetchChatAttachmentBytes(
      int threadId, int attachmentId) async {
    final cacheKey = '$threadId:$attachmentId';
    final cached = _attachmentBytesCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;
    final res = await _dio.get<List<int>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/content/',
      options: Options(responseType: ResponseType.bytes),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw StateError('Пустой файл');
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _attachmentBytesCache[cacheKey] = bytes;
    return bytes;
  }

  Future<Map<String, dynamic>> sendThreadMessage(
    int threadId, {
    String? body,
    List<int>? attachmentIds,
    int? replyToMessageId,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/messages/',
      data: {
        if (body != null && body.isNotEmpty) 'body': body,
        if (attachmentIds != null && attachmentIds.isNotEmpty)
          'attachment_ids': attachmentIds,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
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

  Future<Map<String, dynamic>> startThreadCall(int threadId) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/call/start/',
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

  Future<List<Map<String, dynamic>>> callSignals(int callId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/chat/calls/$callId/signal/',
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
  }) async {
    await logUploadImageExifDiagnostics(
      bytes: bytes,
      filename: filename,
      readVia: 'upload_chat_attachment',
    );
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType:
            contentType != null ? DioMediaType.parse(contentType) : null,
      ),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/',
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 3),
        receiveTimeout: const Duration(minutes: 3),
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
    int faceIndex,
    int userId,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/faces/$faceIndex/assign/',
      data: {'user_id': userId},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createChatAttachmentManualFace(
    int threadId,
    int attachmentId, {
    required int userId,
    required Map<String, dynamic> bbox,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/faces/manual/',
      data: {'user_id': userId, 'bbox': bbox},
    );
    return res.data!;
  }

  Future<void> deleteChatAttachment(int threadId, int attachmentId) async {
    await _dio
        .delete('familychat/chat/threads/$threadId/attachments/$attachmentId/');
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
    int faceIndex,
    int userId,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$profileUserId/gallery/photos/$attachmentId/faces/$faceIndex/assign/',
      data: {'user_id': userId},
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> createGalleryPhotoManualFace(
    int profileUserId,
    int attachmentId, {
    required int userId,
    required Map<String, dynamic> bbox,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$profileUserId/gallery/photos/$attachmentId/faces/manual/',
      data: {'user_id': userId, 'bbox': bbox},
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
    List<int> attachmentIds,
  ) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/custom-albums/$albumPk/photos/',
      data: {'attachment_ids': attachmentIds},
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
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/custom-albums/$albumPk/photos/upload/',
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 3),
        receiveTimeout: const Duration(minutes: 3),
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
  }) async {
    final params = <String, dynamic>{'offset': offset, 'limit': limit};
    if (personUserId != null) params['person_user_id'] = personUserId;
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

  Future<Map<String, dynamic>> familyGalleryUpload({
    required Uint8List bytes,
    required String filename,
    String? contentType,
    required String destination,
    int? albumPk,
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
    });
    final res = await _dio.post<Map<String, dynamic>>(
      'familychat/gallery/upload/',
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 3),
        receiveTimeout: const Duration(minutes: 3),
      ),
    );
    return res.data!;
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
