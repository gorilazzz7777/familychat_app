import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/widgets/family_app_bar.dart';
import '../data/services_access.dart';

/// In-app browser for a Services entry. Uses Android WebView proxy override
/// (not a system VPN). Cookies / DOM storage persist in the app WebView store.
class ServicesWebViewScreen extends StatefulWidget {
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
  State<ServicesWebViewScreen> createState() => _ServicesWebViewScreenState();
}

class _ServicesWebViewScreenState extends State<ServicesWebViewScreen> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _proxyReady = false;
  String? _error;
  String _title = '';
  bool _hadSuccessfulLoad = false;

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

  static final InAppWebViewSettings _webSettings = InAppWebViewSettings(
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
    userAgent: 'Mozilla/5.0 (Linux; Android 13; Mobile) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/124.0.0.0 Mobile Safari/537.36',
  );

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _prepareProxy();
  }

  Future<void> _prepareProxy() async {
    if (!Platform.isAndroid) {
      setState(() {
        _error = 'Пока только Android';
        _proxyReady = false;
      });
      return;
    }
    try {
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
      if (!mounted) return;
      setState(() => _proxyReady = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось настроить доступ');
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      ProxyController.instance().clearProxyOverride().catchError((_) {});
    }
    super.dispose();
  }

  bool _isBenignLoadError(WebResourceError error) {
    final type = error.type;
    return type == WebResourceErrorType.UNSUPPORTED_SCHEME ||
        type == WebResourceErrorType.FAILED_SSL_HANDSHAKE ||
        type == WebResourceErrorType.CANCELLED ||
        type == WebResourceErrorType.UNKNOWN;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: _title,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrow_left),
          tooltip: 'К списку сервисов',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(LucideIcons.refresh_cw),
            onPressed: () {
              setState(() => _error = null);
              _controller?.reload();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress),
          Expanded(
            child: !_proxyReady && _error == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      if (_proxyReady)
                        InAppWebView(
                          initialUrlRequest: URLRequest(
                            url: WebUri(widget.url),
                          ),
                          initialSettings: _webSettings,
                          initialUserScripts: UnmodifiableListView([
                            _sameTabScript,
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
                            if (_error != null) setState(() => _error = null);
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
                            setState(() {
                              _error =
                                  'Страница недоступна. Проверьте сеть и попробуйте снова.';
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
                                    onPressed: () {
                                      setState(() => _error = null);
                                      _controller?.reload();
                                    },
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
    );
  }
}
