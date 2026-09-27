import 'package:flutter/foundation.dart';

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

  /// Hardcoded RU MTProto proxy (FamilyChat infra).
  ///
  /// FakeTLS disguise host is `proxy.remont-tracker.ru` (same as [proxyServer]).
  /// Keep this in sync with the mtg container secret on the VPS — a domain
  /// mismatch yields `cannot find X in [Y]`; a key mismatch yields
  /// `incorrect client random`. Both fall through to domain-fronting and
  /// stall media at 0B while API can still look Ready.
  static const proxyServer = 'proxy.remont-tracker.ru';
  static const proxyPort = 8443;
  static const proxySecret =
      'eee1a6c02fc78d6c1b1d8ab8c45d7235db70726f78792e72656d6f6e742d747261636b65722e7275';

  /// Android-first MVP; iOS follows in a later PR with the same Dart API.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static bool get hasApiCredentials => apiId > 0 && apiHash.isNotEmpty;

  static bool get isEnabled => isSupportedPlatform && hasApiCredentials;
}
