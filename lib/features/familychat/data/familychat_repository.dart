import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/config/env.dart';
import '../../../core/network/api_client.dart';

class FamilyChatRepository {
  FamilyChatRepository(this._client);

  final ApiClient _client;
  Dio get _dio => _client.dio;

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
    final res = await _dio.delete<Map<String, dynamic>>('familychat/me/avatar/');
    return res.data!;
  }

  Future<Map<String, dynamic>> onboardingPrefill() async {
    final res = await _dio.get<Map<String, dynamic>>('familychat/onboarding/prefill/');
    return res.data!;
  }

  Future<Map<String, dynamic>> updateProfile({
    String? firstName,
    String? lastName,
    String? gender,
    String? birthDate,
    bool? birthdayShowYear,
  }) async {
    final data = <String, dynamic>{};
    if (firstName != null) data['first_name'] = firstName;
    if (lastName != null) data['last_name'] = lastName;
    if (gender != null) data['gender'] = gender;
    if (birthDate != null) data['birth_date'] = birthDate;
    if (birthdayShowYear != null) data['birthday_show_year'] = birthdayShowYear;
    final res = await _dio.patch<Map<String, dynamic>>(
      'familychat/me/profile/',
      data: data,
    );
    return res.data!;
  }

  Future<Map<String, dynamic>> memberProfile(int userId) async {
    final res = await _dio.get<Map<String, dynamic>>('familychat/members/$userId/');
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

  Future<List<Map<String, dynamic>>> chatThreads() async {
    final res = await _dio.get<Map<String, dynamic>>('familychat/chat/threads/');
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

  Future<List<Map<String, dynamic>>> threadMessages(int threadId) async {
    final res = await _dio.get<List<dynamic>>('familychat/chat/threads/$threadId/messages/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<void> markThreadRead(int threadId, {required int lastMessageId}) async {
    await _dio.post(
      'familychat/chat/threads/$threadId/read/',
      data: {'last_message_id': lastMessageId},
    );
  }

  String chatAttachmentContentUrl(int threadId, int attachmentId) {
    final base = Env.apiBaseUrl.endsWith('/') ? Env.apiBaseUrl : '${Env.apiBaseUrl}/';
    return '${base}familychat/chat/threads/$threadId/attachments/$attachmentId/content/';
  }

  Future<Uint8List> fetchChatAttachmentBytes(int threadId, int attachmentId) async {
    final res = await _dio.get<List<int>>(
      'familychat/chat/threads/$threadId/attachments/$attachmentId/content/',
      options: Options(responseType: ResponseType.bytes),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw StateError('Пустой файл');
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
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
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: contentType != null ? DioMediaType.parse(contentType) : null,
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
    final res = await _dio.get<List<dynamic>>('familychat/chat/threads/$threadId/media/');
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
  }) async {
    final encodedAlbum = Uri.encodeComponent(albumId);
    final res = await _dio.get<Map<String, dynamic>>(
      'familychat/members/$userId/gallery/albums/$encodedAlbum/photos/',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> threadFiles(int threadId) async {
    final res = await _dio.get<List<dynamic>>('familychat/chat/threads/$threadId/files/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> threadLinks(int threadId) async {
    final res = await _dio.get<List<dynamic>>('familychat/chat/threads/$threadId/links/');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> familyChatMessages() async {
    final res = await _dio.get<List<dynamic>>('familychat/chat/family/messages/');
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
}
