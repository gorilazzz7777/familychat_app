import 'dart:typed_data';

import 'package:dio/dio.dart';

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
        'registration_token': token,
        'platform': platform,
      },
    );
  }
}
