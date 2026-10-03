import 'package:flutter/foundation.dart';

/// One MTProto FakeTLS endpoint (host may differ; SNI lives inside [secret]).
class TdlibProxyEndpoint {
  const TdlibProxyEndpoint({
    required this.server,
    required this.port,
    required this.secret,
    required this.label,
  });

  final String server;
  final int port;
  final String secret;
  final String label;
}

/// TDLib client config for FamilyChat.
///
/// Defaults are the Family Space app credentials from my.telegram.org.
/// Override at build time with `--dart-define=TELEGRAM_API_ID=…` /
/// `TELEGRAM_API_HASH=…` if needed.
class TdlibConfig {
  TdlibConfig._();

  static const apiId = int.fromEnvironment(
    'TELEGRAM_API_ID',
    defaultValue: 26200510,
  );
  static const apiHash = String.fromEnvironment(
    'TELEGRAM_API_HASH',
    defaultValue: 'a7585fb85b603c1a80902fd76f374051',
  );

  /// FakeTLS secret with SNI `www.cloudflare.com` (Megafon mobile needs this;
  /// `cdn.remont-tracker.ru` SNI stalled on cellular DPI).
  static const _fakeTlsCfSecret =
      'eefd10303a88e2c4ab0e0d385432d568ac7777772e636c6f7564666c6172652e636f6d';

  /// Ordered MTProto endpoints. Index 0 = preferred; later entries are
  /// automatic failover when Wi‑Fi stays wedged on Connecting.
  ///
  /// IP only: with a hostname as [TdlibProxyEndpoint.server], TDLib puts that
  /// hostname into TLS SNI, while FakeTLS secret requires SNI
  /// `www.cloudflare.com`. mtg then rejects the hello
  /// (`cannot find www.cloudflare.com in [cdn.remont-tracker.ru]`).
  /// SessionLog 2026-10-03 23:28: stuck Connecting on `cdn-443-cf` failover
  /// until rotated back to IP → Ready in ~11s. Hostname must NOT be a failover
  /// target with this secret — stage-2 kick cycles enableProxy on the IP instead.
  ///
  /// Keep [proxySecretEpoch] in sync when secrets or preferred server change
  /// so TDLib drops stale proxy rows.
  static const proxyEndpoints = <TdlibProxyEndpoint>[
    TdlibProxyEndpoint(
      server: '159.194.200.164',
      port: 443,
      secret: _fakeTlsCfSecret,
      label: 'ip-443-cf',
    ),
  ];

  /// Bump whenever any [proxyEndpoints] secret or preferred server changes.
  static const proxySecretEpoch = 5;

  /// Primary endpoint helpers (call sites / docs).
  static String get proxyServer => proxyEndpoints.first.server;
  static int get proxyPort => proxyEndpoints.first.port;
  static String get proxySecret => proxyEndpoints.first.secret;

  /// Android + iOS (static tdjson on iOS via DynamicLibrary.process).
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool get hasApiCredentials => apiId > 0 && apiHash.isNotEmpty;

  static bool get isEnabled => isSupportedPlatform && hasApiCredentials;
}
