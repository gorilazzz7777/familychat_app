import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';

class AiAssistantApi {
  AiAssistantApi(this._client);

  final ApiClient _client;
  Dio get _dio => _client.dio;

  Future<List<Map<String, dynamic>>> listSessions() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/familychat/ai-assistant/sessions/',
    );
    final results = res.data?['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> createSession({String title = ''}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/familychat/ai-assistant/sessions/',
      data: {'title': title},
    );
    return Map<String, dynamic>.from(res.data ?? const {});
  }

  Future<Map<String, dynamic>> renameSession(int id, String title) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      '/api/v1/familychat/ai-assistant/sessions/$id/',
      data: {'title': title},
    );
    return Map<String, dynamic>.from(res.data ?? const {});
  }

  Future<void> deleteSession(int id) async {
    await _dio.delete('/api/v1/familychat/ai-assistant/sessions/$id/');
  }

  Future<Map<String, dynamic>> listMessages(int sessionId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/familychat/ai-assistant/sessions/$sessionId/messages/',
    );
    return Map<String, dynamic>.from(res.data ?? const {});
  }

  Future<Map<String, dynamic>> sendMessage({
    required int sessionId,
    required String text,
    List<({String filename, String contentType, Uint8List bytes})> files =
        const [],
  }) async {
    final form = FormData();
    form.fields.add(MapEntry('text', text));
    for (final f in files) {
      form.files.add(
        MapEntry(
          'files',
          MultipartFile.fromBytes(
            f.bytes,
            filename: f.filename,
            contentType: DioMediaType.parse(
              f.contentType.isEmpty
                  ? 'application/octet-stream'
                  : f.contentType,
            ),
          ),
        ),
      );
    }
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/familychat/ai-assistant/sessions/$sessionId/messages/',
      data: form,
    );
    return Map<String, dynamic>.from(res.data ?? const {});
  }
}
