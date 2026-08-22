import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// PUT bytes to a presigned S3 URL (no app JWT headers).
Future<void> putBytesToPresignedUrl({
  required String uploadUrl,
  required Uint8List bytes,
  required Map<String, dynamic> headers,
  void Function(int sent, int total)? onSendProgress,
}) async {
  final client = Dio(
    BaseOptions(
      validateStatus: (status) => status != null && status >= 200 && status < 300,
      sendTimeout: const Duration(minutes: 10),
      receiveTimeout: const Duration(minutes: 10),
    ),
  );
  final hdrs = <String, String>{
    for (final e in headers.entries)
      if (e.value != null) e.key: e.value.toString(),
  };
  await client.put<void>(
    uploadUrl,
    data: bytes,
    options: Options(headers: hdrs),
    onSendProgress: onSendProgress,
  );
}

String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();