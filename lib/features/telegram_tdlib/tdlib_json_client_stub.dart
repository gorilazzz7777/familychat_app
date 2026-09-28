import 'dart:async';

import 'tdlib_ffi.dart';

class TdlibApiException implements Exception {
  TdlibApiException({required this.code, required this.message});

  final int code;
  final String message;

  bool get isNeedsTdlibParameters {
    final m = message.toLowerCase();
    return m.contains('initialization parameters') ||
        m.contains('settdlibparameters');
  }

  @override
  String toString() => 'TDLib error $code: $message';
}

/// Web stub — no native TDLib receive loop.
class TdlibJsonClient {
  TdlibJsonClient._();

  static set onNeedsParameters(void Function(TdlibApiException error)? cb) {}

  static Future<TdlibJsonClient> create() async {
    throw UnsupportedError('TDLib is not available on this platform');
  }

  static Future<void> closeOrphanedClients({
    TdlibFfi? existing,
    int? exceptClientId,
  }) async {}

  int get clientId => 0;

  Stream<Map<String, dynamic>> get updates => const Stream.empty();

  void send(Map<String, dynamic> request) {}

  Future<Map<String, dynamic>> sendAwait(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    throw UnsupportedError('TDLib is not available on this platform');
  }

  Map<String, dynamic> execute(Map<String, dynamic> request) => {};

  Future<void> dispose() async {}
}
