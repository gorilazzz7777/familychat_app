import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

/// When Cronet starts timing out on a device/network, fall back to dart:io for
/// the rest of the process (boot + subsequent API calls).
bool _forceDartIoHttp = false;

bool get isForcedDartIoHttp => _forceDartIoHttp;

/// Prefer platform HTTP stacks (Cronet / URLSession) for HTTP/2, connection
/// reuse and TLS session resumption — unless [forceDartIoHttpAdapters] ran.
void configureNativeHttpAdapter(Dio dio) {
  if (_forceDartIoHttp) {
    dio.httpClientAdapter = IOHttpClientAdapter();
    return;
  }

  dio.httpClientAdapter = NativeAdapter(
    createCronetEngine: () => CronetEngine.build(
      cacheMode: CacheMode.memory,
      cacheMaxSize: 2 * 1024 * 1024,
      enableBrotli: true,
      enableHttp2: true,
      // nginx on our VPS is HTTP/2 only (no QUIC listener).
      enableQuic: false,
    ),
    createCupertinoConfiguration: () {
      final config = URLSessionConfiguration.defaultSessionConfiguration()
        ..timeoutIntervalForRequest = const Duration(seconds: 90)
        ..httpMaximumConnectionsPerHost = 8;
      return config;
    },
    createFallbackAdapter: (error, stackTrace) => IOHttpClientAdapter(),
  );
}

/// Switch listed [Dio] clients to dart:io and keep them there.
void forceDartIoHttpAdapters(Iterable<Dio> dios) {
  _forceDartIoHttp = true;
  for (final dio in dios) {
    dio.httpClientAdapter = IOHttpClientAdapter();
  }
  if (kDebugMode) {
    debugPrint('[HttpAdapter] forced dart:io for ${dios.length} client(s)');
  }
}

bool isLikelyCronetTransportFailure(Object? error) {
  if (error is! DioException) return false;
  if (error.response != null) return false;
  final blob = '${error.type} ${error.message ?? ''} ${error.error ?? ''}';
  return blob.contains('Cronet') ||
      blob.contains('ERR_TIMED_OUT') ||
      blob.contains('ERR_CONNECTION') ||
      blob.contains('ERR_NAME_NOT_RESOLVED') ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.connectionError;
}
