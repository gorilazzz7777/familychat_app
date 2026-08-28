import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

import '../config/env.dart';

/// Prefer platform HTTP stacks (Cronet / URLSession) for HTTP/2, connection
/// reuse and TLS session resumption.
void configureNativeHttpAdapter(Dio dio) {
  final host = Uri.tryParse(Env.apiBaseUrl)?.host;
  final quicHints = <(String, int, int)>[
    if (host != null && host.isNotEmpty) (host, 443, 443),
  ];

  dio.httpClientAdapter = NativeAdapter(
    createCronetEngine: () => CronetEngine.build(
      cacheMode: CacheMode.memory,
      cacheMaxSize: 2 * 1024 * 1024,
      enableBrotli: true,
      enableHttp2: true,
      // Negotiates HTTP/3 when the edge supports QUIC; otherwise HTTP/2.
      enableQuic: true,
      quicHints: quicHints,
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
