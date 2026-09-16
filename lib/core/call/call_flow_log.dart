import 'package:flutter/foundation.dart';
import 'package:gorila_chat/gorila_chat.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../network/api_client.dart';

/// One-shot / short-lived call-flow log from push / CallKit paths.
abstract final class CallFlowLog {
  static Future<void> action({
    required int callId,
    required String role,
    required String event, {
    Map<String, dynamic>? data,
    FamilyChatRepository? repository,
  }) async {
    try {
      final repo = repository ?? FamilyChatRepository(ApiClient());
      final reporter = CallFlowReporter(
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
        upload: (id, body) => repo.uploadCallReport(id, body),
      );
      reporter.start(callId: callId, role: role);
      reporter.log(event, data: data);
      await reporter.end();
      reporter.dispose();
    } catch (e, st) {
      debugPrint('CallFlowLog failed: $e\n$st');
    }
  }
}
