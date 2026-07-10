class OAuthCallbackResult {
  const OAuthCallbackResult({
    required this.provider,
    this.sessionCode,
    this.error,
    this.errorCode,
    this.status,
  });

  final String provider;
  final String? sessionCode;
  final String? error;
  final String? errorCode;
  final String? status;

  bool get isOk => status == null || status == 'ok';
}

String? extractInviteToken(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  for (var i = 0; i < segments.length - 1; i++) {
    if (segments[i] == 'invite') {
      final token = segments[i + 1].trim();
      if (token.isNotEmpty) return token;
    }
  }
  if (uri.scheme == 'familychat' && uri.host == 'invite') {
    final token = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    if (token != null && token.isNotEmpty) return token;
  }
  return null;
}

OAuthCallbackResult? parseOAuthCallback(Uri uri) {
  if (uri.scheme == 'familychat' && uri.host == 'auth') {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final provider = segments.first;
    if (!const {'yandex', 'vk', 'google'}.contains(provider)) return null;

    final status = uri.queryParameters['status'];
    if (status != null && status != 'ok') {
      return OAuthCallbackResult(
        provider: provider,
        status: status,
        error: uri.queryParameters['error_description'] ?? status,
        errorCode: uri.queryParameters['error_code'],
      );
    }

    final code = uri.queryParameters['session_code'];
    if (code == null || code.isEmpty) return null;

    return OAuthCallbackResult(
      provider: provider,
      status: 'ok',
      sessionCode: code.replaceAll(RegExp(r'\\+$'), ''),
    );
  }

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final authIdx = segments.indexOf('auth');
  if (authIdx < 0 || authIdx + 1 >= segments.length) return null;

  final provider = segments[authIdx + 1];
  if (!const {'yandex', 'vk', 'google'}.contains(provider)) return null;

  final status = uri.queryParameters['status'];
  if (status != null && status != 'ok') {
    return OAuthCallbackResult(
      provider: provider,
      status: status,
      error: uri.queryParameters['error_description'] ?? status,
      errorCode: uri.queryParameters['error_code'],
    );
  }

  final code = uri.queryParameters['session_code'];
  if (code == null || code.isEmpty) return null;

  return OAuthCallbackResult(
    provider: provider,
    status: 'ok',
    sessionCode: code.replaceAll(RegExp(r'\\+$'), ''),
  );
}

Map<String, dynamic>? parseIncomingCallPushFromUri(Uri uri) {
  if (uri.queryParameters['fc_call'] != '1') return null;
  final sessionId = uri.queryParameters['session_id']?.trim();
  final threadId = uri.queryParameters['thread_id']?.trim();
  if (sessionId == null ||
      sessionId.isEmpty ||
      threadId == null ||
      threadId.isEmpty) {
    return null;
  }
  return {
    'type': 'familychat_call',
    'session_id': sessionId,
    'thread_id': threadId,
    'caller_user_id': uri.queryParameters['caller_user_id'] ?? '0',
    'caller_name': uri.queryParameters['caller_name'] ?? 'Family Chat',
  };
}
