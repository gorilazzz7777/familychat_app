import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/chat_network_link.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../data/services_access.dart';
import '../data/services_ios_webview_proxy.dart';
import '../data/services_proxy_registrar.dart';

/// In-app browser for a Services entry.
///
/// Proxy (not a system VPN):
/// - Android: WebView [ProxyController] / PROXY_OVERRIDE
/// - iOS 17+: [WKWebsiteDataStore.proxyConfigurations] via native channel
///
/// Cookies / DOM storage persist in the app WebView store.
class ServicesWebViewScreen extends ConsumerStatefulWidget {
  const ServicesWebViewScreen({
    super.key,
    required this.title,
    required this.url,
    required this.proxy,
  });

  final String title;
  final String url;
  final ServicesProxyConfig proxy;

  @override
  ConsumerState<ServicesWebViewScreen> createState() =>
      _ServicesWebViewScreenState();
}

class _ServicesWebViewScreenState
    extends ConsumerState<ServicesWebViewScreen> {
  final _registrar = ServicesProxyRegistrar();
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _proxyReady = false;
  String? _error;
  String _title = '';
  bool _hadSuccessfulLoad = false;
  bool _retrying = false;

  StreamSubscription<ChatNetworkLinkKind>? _netSub;
  ChatNetworkLinkKind? _lastNetKind;
  Timer? _netReregisterDebounce;

  /// Force window.open / target=_blank into the same WebView (Google OAuth).
  static final UserScript _sameTabScript = UserScript(
    source: '''
      (function() {
        try {
          window.open = function(url) {
            if (url) { window.location.href = url; }
            return window;
          };
        } catch (e) {}
      })();
    ''',
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// TikTok mobile web leaves brand nav-loading (cyan/magenta SVG) and/or
  /// DivLoadingContainer up after like/follow while <video> already plays
  /// (botType=others / mssdk challenge never finishes). Hide stuck overlays.
  static final UserScript _tiktokStuckLoaderScript = UserScript(
    source: '''
      (function() {
        if (window.__fcTtLoaderWatch) return;
        window.__fcTtLoaderWatch = true;
        var host = (location.hostname || '').toLowerCase();
        if (host !== 'tiktok.com' && !host.endsWith('.tiktok.com')) return;
        function hideEl(el) {
          if (!el) return;
          el.style.setProperty('display', 'none', 'important');
          el.style.setProperty('visibility', 'hidden', 'important');
          el.style.setProperty('opacity', '0', 'important');
          el.style.setProperty('pointer-events', 'none', 'important');
          el.setAttribute('data-fc-hidden-loader', '1');
        }
        function sweep() {
          try {
            var video = document.querySelector('video');
            // Even without a ready video, a stuck full-screen nav-loading
            // after user interaction blocks the whole UI — clear it if it
            // has been present with a playing/ready video OR for >2.5s.
            var ready = video && video.readyState >= 3;
            hideEl(document.getElementById('navigation-loading'));
            hideEl(document.getElementById('nav-loading'));
            if (!ready) return;
            var nodes = document.querySelectorAll('[class*="LoadingContainer"]');
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              var r = el.getBoundingClientRect();
              if (r.width < 80 || r.height < 80) continue;
              hideEl(el);
            }
          } catch (e) {}
        }
        setInterval(sweep, 700);
        setTimeout(sweep, 1200);
        setTimeout(sweep, 2500);
      })();
    ''',
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// Built in [_prepareProxy] with a browser-like UA (real Chrome major,
  /// without Android WebView `wv` / `Version/4.0` markers).
  InAppWebViewSettings? _webSettings;

  /// TikTok webmssdk rejects embedded-WebView fingerprints (`; wv)`,
  /// `Version/4.0`) and also rejects a stale spoofed Chrome major (we used
  /// to hardcode 124 while the device WebView is 154+) — both end in the
  /// eternal cyan/magenta spinner on like/follow.
  static String _browserLikeUserAgent(String defaultUa) {
    var ua = defaultUa.trim();
    ua = ua.replaceAll(RegExp(r';\s*;\s*wv\)'), ')');
    ua = ua.replaceAll('; wv', '');
    ua = ua.replaceAll(RegExp(r'\sVersion/4\.0\s'), ' ');
    ua = ua.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return ua;
  }

  static bool _isTikTokUrl(String url) {
    try {
      final host = Uri.parse(url).host.toLowerCase();
      return host == 'tiktok.com' || host.endsWith('.tiktok.com');
    } catch (_) {
      return false;
    }
  }

  /// Mobile TikTok web hard-caps For You after ~1 swipe and redirects to the
  /// native-app install funnel (onelink / snssdk). Phone Chrome shows that
  /// store page; we cancel those hops so the feed looks "stuck". Desktop
  /// Chrome (laptop) serves the unrestricted web feed — spoof that UA.
  static String _desktopChromeUserAgent(String defaultUa) {
    final m = RegExp(r'Chrome/(\d+)').firstMatch(defaultUa);
    final major = m?.group(1) ?? '154';
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36';
  }

  /// Extra TikTok desktop-mode hints + block in-page app-install redirects
  /// that would otherwise leave the SPA mid-transition after we CANCEL them.
  static final UserScript _tiktokDesktopAssistScript = UserScript(
    source: '''
      (function() {
        if (window.__fcTtDesktopAssist) return;
        window.__fcTtDesktopAssist = true;
        var host = (location.hostname || '').toLowerCase();
        if (host !== 'tiktok.com' && !host.endsWith('.tiktok.com')) return;
        try {
          Object.defineProperty(navigator, 'platform', {
            get: function() { return 'Win32'; },
            configurable: true,
          });
          Object.defineProperty(navigator, 'maxTouchPoints', {
            get: function() { return 1; },
            configurable: true,
          });
        } catch (e) {}
        function isAppHop(u) {
          try {
            var s = String(u || '');
            return /onelink\\.me|app\\.link|snssdk|tiktokv\\.com\\/.*download|play\\.google\\.com|apps\\.apple\\.com|intent:/i.test(s);
          } catch (e) { return false; }
        }
        try {
          var desc = Object.getOwnPropertyDescriptor(Location.prototype, 'href');
          if (desc && desc.set) {
            Object.defineProperty(Location.prototype, 'href', {
              get: desc.get,
              set: function(v) { if (isAppHop(v)) return; return desc.set.call(this, v); },
              configurable: true,
            });
          }
          var assign = Location.prototype.assign;
          Location.prototype.assign = function(u) {
            if (isAppHop(u)) return; return assign.call(this, u);
          };
          var replace = Location.prototype.replace;
          Location.prototype.replace = function(u) {
            if (isAppHop(u)) return; return replace.call(this, u);
          };
        } catch (e) {}
      })();
    ''',
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  InAppWebViewSettings _buildWebSettings(
    String userAgent, {
    required bool desktopSite,
  }) {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      thirdPartyCookiesEnabled: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      useHybridComposition: true,
      useShouldOverrideUrlLoading: true,
      // Still advertise multi-window so sites call window.open; we fold into same tab.
      supportMultipleWindows: true,
      javaScriptCanOpenWindowsAutomatically: true,
      userAgent: userAgent,
      // Desktop layout for TikTok (matches laptop Chrome feed).
      useWideViewPort: desktopSite,
      loadWithOverviewMode: desktopSite,
    );
  }

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _prepareProxy();
    _netSub = ChatNetworkLink.watch().listen(_onNetKind);
  }

  @override
  void dispose() {
    _netReregisterDebounce?.cancel();
    unawaited(_netSub?.cancel() ?? Future<void>.value());
    if (Platform.isAndroid) {
      ProxyController.instance().clearProxyOverride().catchError((_) {});
    } else if (Platform.isIOS) {
      unawaited(ServicesIosWebViewProxy.clearProxy());
    }
    super.dispose();
  }

  void _onNetKind(ChatNetworkLinkKind kind) {
    final prev = _lastNetKind;
    _lastNetKind = kind;
    if (kind == ChatNetworkLinkKind.offline) return;
    if (kind != ChatNetworkLinkKind.wifi &&
        kind != ChatNetworkLinkKind.mobile) {
      return;
    }
    if (prev == null || prev == ChatNetworkLinkKind.unknown) return;
    if (prev == kind) return;
    _netReregisterDebounce?.cancel();
    _netReregisterDebounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(_reregister(why: 'webview-net:$prev→$kind'));
    });
  }

  Future<bool> _reregister({required String why}) async {
    try {
      final data =
          await ref.read(familychatRepositoryProvider).fetchServicesAccess();
      await _registrar.register(data.register, why: why);
      return true;
    } catch (e) {
      debugPrint('[services_webview] reregister fail why=$why $e');
      return false;
    }
  }

  Future<void> _prepareProxy() async {
    try {
      if (Platform.isAndroid) {
        final supported = await WebViewFeature.isFeatureSupported(
          WebViewFeature.PROXY_OVERRIDE,
        );
        if (!supported) {
          setState(() {
            _error = 'Прокси WebView недоступен на этом устройстве';
          });
          return;
        }
        await ProxyController.instance().setProxyOverride(
          settings: ProxySettings(
            proxyRules: [ProxyRule(url: widget.proxy.proxyUrl)],
            bypassRules: const ['<-loopback>'],
          ),
        );
      } else if (Platform.isIOS) {
        final supported = await ServicesIosWebViewProxy.isSupported();
        if (!supported) {
          setState(() {
            _error =
                'Для сервисов через прокси нужен iOS 17 или новее.';
            _proxyReady = false;
          });
          return;
        }
        // Fresh allowlist before WKWebView first dial (same as Android open).
        // Bound: a hung register used to leave the WebView on eternal spinner.
        final registered = await _reregister(why: 'ios-prepare-proxy')
            .timeout(const Duration(seconds: 18), onTimeout: () => false);
        if (!registered) {
          debugPrint('[services_webview] ios-prepare-proxy register miss');
        }
        await ServicesIosWebViewProxy.setProxy(widget.proxy)
            .timeout(const Duration(seconds: 8));
      } else {
        setState(() {
          _error = 'Сервисы через прокси на этой платформе недоступны';
          _proxyReady = false;
        });
        return;
      }

      final defaultUa = await InAppWebViewController.getDefaultUserAgent();
      final tiktok = _isTikTokUrl(widget.url);
      final browserUa = tiktok
          ? _desktopChromeUserAgent(defaultUa)
          : _browserLikeUserAgent(defaultUa);
      debugPrint(
        '[services_webview] ua default=$defaultUa → '
        '${tiktok ? 'desktop' : 'browser'}=$browserUa '
        'proxy=${widget.proxy.proxyUrl} platform='
        '${Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other')}',
      );
      if (!mounted) return;
      setState(() {
        _webSettings = _buildWebSettings(
          browserUa,
          desktopSite: tiktok,
        );
        _proxyReady = true;
      });
    } catch (e) {
      debugPrint('[services_webview] prepareProxy fail $e');
      if (!mounted) return;
      setState(() => _error = 'Не удалось настроить доступ');
    }
  }

  bool _isBenignLoadError(WebResourceError error) {
    final type = error.type;
    return type == WebResourceErrorType.UNSUPPORTED_SCHEME ||
        type == WebResourceErrorType.FAILED_SSL_HANDSHAKE ||
        type == WebResourceErrorType.CANCELLED ||
        type == WebResourceErrorType.UNKNOWN;
  }

  bool _looksLikeProxyOrNetworkError(WebResourceError error) {
    final desc = error.description.toLowerCase();
    final typeName = error.type.toString().toLowerCase();
    if (typeName.contains('host_lookup') ||
        typeName.contains('timeout') ||
        typeName.contains('connect') ||
        typeName.contains('io')) {
      return true;
    }
    return desc.contains('err_proxy') ||
        desc.contains('err_tunnel') ||
        desc.contains('err_connection') ||
        desc.contains('err_name_not_resolved') ||
        desc.contains('err_timed_out') ||
        desc.contains('err_internet_disconnected') ||
        desc.contains('proxy') ||
        desc.contains('tunnel');
  }

  NavigationActionPolicy _navigationPolicy(WebUri? uri) {
    if (uri == null) return NavigationActionPolicy.ALLOW;
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final appHop = host.contains('onelink.me') ||
        host.contains('app.link') ||
        host.startsWith('snssdk') ||
        (host.contains('tiktokv.com') && uri.path.contains('download'));
    if (appHop) {
      debugPrint('[services_webview] blocked app-hop url=$uri');
      return NavigationActionPolicy.CANCEL;
    }
    if (scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'about' ||
        scheme == 'data' ||
        scheme == 'blob') {
      return NavigationActionPolicy.ALLOW;
    }
    debugPrint('[services_webview] blocked scheme=$scheme url=$uri');
    return NavigationActionPolicy.CANCEL;
  }

  Future<bool> _handleCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    final url = action.request.url;
    debugPrint('[services_webview] createWindow url=$url');
    if (url != null &&
        (url.scheme == 'http' ||
            url.scheme == 'https' ||
            url.scheme == 'about')) {
      // Same-tab navigation — avoids black empty popup dialogs.
      await controller.loadUrl(urlRequest: URLRequest(url: url));
    }
    return false;
  }

  /// Prefer in-WebView history (YouTube / TikTok / …). Returns true if handled.
  Future<bool> _goBackInWebView() async {
    final c = _controller;
    if (c == null) return false;
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        return true;
      }
    } catch (e) {
      debugPrint('[services_webview] goBack failed: $e');
    }
    return false;
  }

  Future<void> _onAppBarBack() async {
    if (await _goBackInWebView()) return;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _exitToServices() {
    Navigator.of(context).pop();
  }

  Future<void> _onSystemPop(bool didPop) async {
    if (didPop) return;
    if (await _goBackInWebView()) return;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _retryAfterProxyRefresh() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _error = null;
      _hadSuccessfulLoad = false;
    });
    final ok = await _reregister(why: 'webview-retry');
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _retrying = false;
        _error =
            'Не удалось обновить доступ к прокси. Проверьте сеть (Wi‑Fi / мобильная) и попробуйте снова.';
      });
      return;
    }
    // Re-apply iOS CONNECT proxy after allowlist refresh (IP may have changed).
    if (Platform.isIOS && _proxyReady) {
      try {
        await ServicesIosWebViewProxy.setProxy(widget.proxy);
      } catch (e) {
        debugPrint('[services_webview] ios re-setProxy fail $e');
      }
    }
    if (!mounted) return;
    setState(() => _retrying = false);
    final c = _controller;
    if (c != null) {
      await c.reload();
    } else if (_proxyReady) {
      // WebView not created yet — nothing to reload; proxy ready path will load.
    } else {
      await _prepareProxy();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        unawaited(_onSystemPop(didPop));
      },
      child: Scaffold(
        appBar: FamilyAppBar.build(
          title: _title,
          leading: IconButton(
            icon: const Icon(LucideIcons.arrow_left),
            tooltip: 'Назад',
            onPressed: () => unawaited(_onAppBarBack()),
          ),
          actions: [
            IconButton(
              tooltip: 'Обновить',
              icon: const Icon(LucideIcons.refresh_cw),
              onPressed: _retrying
                  ? null
                  : () => unawaited(_retryAfterProxyRefresh()),
            ),
            IconButton(
              tooltip: 'Выход',
              icon: const Icon(LucideIcons.log_out),
              onPressed: _exitToServices,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_progress > 0 && _progress < 1)
              LinearProgressIndicator(value: _progress),
            Expanded(
              child: (!_proxyReady && _error == null) || _retrying
                  ? const Center(child: CircularProgressIndicator())
                  : Stack(
                      children: [
                        if (_proxyReady && _webSettings != null)
                          InAppWebView(
                            initialUrlRequest: URLRequest(
                              url: WebUri(widget.url),
                            ),
                            initialSettings: _webSettings,
                            initialUserScripts: UnmodifiableListView([
                              _sameTabScript,
                              if (_isTikTokUrl(widget.url)) ...[
                                _tiktokDesktopAssistScript,
                                _tiktokStuckLoaderScript,
                              ],
                            ]),
                            shouldOverrideUrlLoading: (controller, nav) async {
                              return _navigationPolicy(nav.request.url);
                            },
                            onCreateWindow: _handleCreateWindow,
                            onWebViewCreated: (controller) {
                              _controller = controller;
                            },
                            onLoadStop: (_, url) {
                              if (!mounted) return;
                              _hadSuccessfulLoad = true;
                              if (_error != null) {
                                setState(() => _error = null);
                              }
                              debugPrint('[services_webview] loadStop $url');
                            },
                            onProgressChanged: (_, progress) {
                              if (!mounted) return;
                              setState(() => _progress = progress / 100.0);
                            },
                            onTitleChanged: (_, title) {
                              if (!mounted) return;
                              final t = title?.trim();
                              if (t == null || t.isEmpty) return;
                              if (t.toLowerCase().contains('не удалось') ||
                                  t.toLowerCase().contains('can\'t') ||
                                  t.toLowerCase().contains('webpage not')) {
                                return;
                              }
                              setState(() => _title = t);
                            },
                            onReceivedError: (_, request, error) {
                              debugPrint(
                                '[services_webview] error main=${request.isForMainFrame} '
                                'type=${error.type} desc=${error.description} '
                                'url=${request.url}',
                              );
                              if (request.isForMainFrame != true || !mounted) {
                                return;
                              }
                              if (_isBenignLoadError(error) ||
                                  _hadSuccessfulLoad) {
                                return;
                              }
                              final proxyish =
                                  _looksLikeProxyOrNetworkError(error);
                              setState(() {
                                _error = proxyish
                                    ? 'Нет доступа через прокси (часто после смены Wi‑Fi / мобильной сети). Нажмите «Повторить» — обновим доступ.'
                                    : 'Страница недоступна. Проверьте сеть и попробуйте снова.';
                              });
                            },
                          ),
                        if (_error != null)
                          ColoredBox(
                            color: Theme.of(context).colorScheme.surface,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _error!,
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 12),
                                    FilledButton(
                                      onPressed: _retrying
                                          ? null
                                          : () => unawaited(
                                                _retryAfterProxyRefresh(),
                                              ),
                                      child: const Text('Повторить'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
