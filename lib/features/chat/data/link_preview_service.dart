import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class ChatLinkPreview {
  const ChatLinkPreview({
    required this.url,
    required this.host,
    this.canonicalUrl,
    this.title,
    this.description,
    this.imageUrl,
  });

  final String url;
  final String host;
  final String? canonicalUrl;
  final String? title;
  final String? description;
  final String? imageUrl;

  bool get hasCard =>
      (title != null && title!.trim().isNotEmpty) ||
      (imageUrl != null && imageUrl!.trim().isNotEmpty);

  bool get hasImage {
    final value = imageUrl?.trim();
    return value != null && value.isNotEmpty;
  }

  factory ChatLinkPreview.fromJson(Map<String, dynamic> json, String fallbackUrl) {
    final url = json['url']?.toString().trim();
    final hostRaw = json['host']?.toString().trim();
    return ChatLinkPreview(
      url: (url != null && url.isNotEmpty) ? url : fallbackUrl,
      host: (hostRaw != null && hostRaw.isNotEmpty)
          ? hostRaw
          : LinkPreviewService.displayHost(fallbackUrl),
      canonicalUrl: json['canonicalUrl']?.toString(),
      title: _emptyToNull(json['title']?.toString()),
      description: _emptyToNull(json['description']?.toString()),
      imageUrl: _emptyToNull(json['imageUrl']?.toString()),
    );
  }

  static String? _emptyToNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

typedef LinkPreviewBackendFetcher = Future<ChatLinkPreview?> Function(String url);

class _CacheEntry {
  const _CacheEntry(this.preview, this.at);

  final ChatLinkPreview? preview;
  final DateTime at;

  bool get isFresh {
    final ttl = preview == null
        ? const Duration(minutes: 2)
        : const Duration(hours: 6);
    return DateTime.now().difference(at) < ttl;
  }
}

/// Open Graph preview: backend first (redirects / no CORS), then client scrape.
class LinkPreviewService {
  LinkPreviewService._();

  static final LinkPreviewService instance = LinkPreviewService._();

  LinkPreviewBackendFetcher? backendFetcher;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 8),
      followRedirects: true,
      maxRedirects: 8,
      responseType: ResponseType.plain,
      headers: {
        'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.6,en;q=0.4',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
      },
      validateStatus: (code) => code != null && code >= 200 && code < 400,
    ),
  );

  final Map<String, _CacheEntry> _cache = {};
  final Map<String, Future<ChatLinkPreview?>> _inFlight = {};
  int _active = 0;
  static const _maxConcurrent = 3;

  void bindBackend(LinkPreviewBackendFetcher? fetcher) {
    backendFetcher = fetcher;
  }

  static String displayHost(String rawUrl) {
    final uri = _tryParse(rawUrl);
    if (uri == null) return rawUrl;
    var host = uri.host;
    if (host.startsWith('www.')) host = host.substring(4);
    return host.isEmpty ? rawUrl : host;
  }

  static String displayPath(String rawUrl) {
    final uri = _tryParse(rawUrl);
    if (uri == null) return '';
    final path = uri.path;
    if (path.isEmpty || path == '/') {
      return uri.hasQuery ? '?${uri.query}' : '';
    }
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final full = '$path$query';
    if (full.length <= 48) return full;
    return '${full.substring(0, 45)}…';
  }

  static String displayUrl(String rawUrl) {
    final uri = _tryParse(rawUrl);
    if (uri == null) return rawUrl;
    final host = displayHost(rawUrl);
    final path = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
    final text = '$host$path';
    if (text.length <= 64) return text;
    return '${text.substring(0, 61)}…';
  }

  Future<ChatLinkPreview?> load(String rawUrl) {
    final url = rawUrl.trim();
    if (url.isEmpty) return Future<ChatLinkPreview?>.value(null);
    final cached = _cache[url];
    if (cached != null && cached.isFresh) {
      return Future<ChatLinkPreview?>.value(cached.preview);
    }
    final pending = _inFlight[url];
    if (pending != null) return pending;
    final future = _fetch(url);
    _inFlight[url] = future;
    return future.whenComplete(() => _inFlight.remove(url));
  }

  Future<void> _acquire() async {
    while (_active >= _maxConcurrent) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    _active++;
  }

  void _release() {
    if (_active > 0) _active--;
  }

  Future<ChatLinkPreview?> _fetch(String url) async {
    final uri = _tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _cache[url] = _CacheEntry(null, DateTime.now());
      return null;
    }
    await _acquire();
    try {
      final backend = backendFetcher;
      if (backend != null) {
        try {
          final fromServer = await backend(url);
          if (fromServer != null) {
            if (fromServer.hasCard) {
              _cache[url] = _CacheEntry(fromServer, DateTime.now());
              return fromServer;
            }
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[LinkPreview] backend $url: $e');
          }
        }
      }
      return await _fetchClient(uri, url);
    } finally {
      _release();
    }
  }

  Future<ChatLinkPreview?> _fetchClient(Uri uri, String url) async {
    try {
      final res = await _dio.get<String>(uri.toString());
      final html = res.data;
      if (html == null || html.isEmpty) {
        _cache[url] = _CacheEntry(null, DateTime.now());
        return null;
      }
      final pageUri = res.realUri;
      final snippet = html.length > 180000 ? html.substring(0, 180000) : html;
      final title = _firstNonEmpty([
        _meta(snippet, 'og:title'),
        _meta(snippet, 'twitter:title'),
        _tagTitle(snippet),
      ]);
      final description = _firstNonEmpty([
        _meta(snippet, 'og:description'),
        _meta(snippet, 'twitter:description'),
        _meta(snippet, 'description', name: true),
      ]);
      final imageRaw = _firstNonEmpty([
        _meta(snippet, 'og:image'),
        _meta(snippet, 'og:image:url'),
        _meta(snippet, 'og:image:secure_url'),
        _meta(snippet, 'twitter:image'),
        _meta(snippet, 'twitter:image:src'),
        _jsonLdImage(snippet),
      ]);
      final imageUrl = _absolutize(pageUri, imageRaw);
      final preview = ChatLinkPreview(
        url: url,
        host: displayHost(pageUri.toString()),
        canonicalUrl: pageUri.toString(),
        title: title,
        description: description,
        imageUrl: imageUrl,
      );
      final stored = preview.hasCard ? preview : null;
      _cache[url] = _CacheEntry(stored, DateTime.now());
      return stored;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LinkPreview] $url: $e');
      }
      _cache[url] = _CacheEntry(null, DateTime.now());
      return null;
    }
  }

  static Uri? _tryParse(String raw) {
    final value = raw.startsWith('http') ? raw : 'https://$raw';
    return Uri.tryParse(value);
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return _decodeEntities(trimmed);
      }
    }
    return null;
  }

  static String? _absolutize(Uri page, String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    final abs = Uri.tryParse(value);
    if (abs == null) return null;
    if (abs.hasScheme) return abs.toString();
    return page.resolveUri(abs).toString();
  }

  static String? _meta(String html, String property, {bool name = false}) {
    final attr = name ? 'name' : 'property';
    final patterns = [
      RegExp(
        '<meta[^>]+$attr=["\\\']${RegExp.escape(property)}["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\'][^>]*>',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]+content=["\\\']([^"\\\']+)["\\\'][^>]+$attr=["\\\']${RegExp.escape(property)}["\\\'][^>]*>',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String? _tagTitle(String html) {
    final match = RegExp(
      r'<title[^>]*>([^<]+)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    return match?.group(1);
  }

  static String? _jsonLdImage(String html) {
    final patterns = [
      RegExp(r'"image"\s*:\s*"([^"]+)"', caseSensitive: false),
      RegExp(r'"image"\s*:\s*\{\s*"url"\s*:\s*"([^"]+)"', caseSensitive: false),
      RegExp(r'"image"\s*:\s*\[\s*"([^"]+)"', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String _decodeEntities(String raw) {
    return raw
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!);
          if (code == null) return m.group(0)!;
          return String.fromCharCode(code);
        })
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1)!, radix: 16);
          if (code == null) return m.group(0)!;
          return String.fromCharCode(code);
        });
  }
}
