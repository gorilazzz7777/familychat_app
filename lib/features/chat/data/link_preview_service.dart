import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class ChatLinkPreview {
  const ChatLinkPreview({
    required this.url,
    required this.host,
    this.title,
    this.description,
    this.imageUrl,
  });

  final String url;
  final String host;
  final String? title;
  final String? description;
  final String? imageUrl;

  bool get hasCard =>
      (title != null && title!.trim().isNotEmpty) ||
      (imageUrl != null && imageUrl!.trim().isNotEmpty);
}

/// Best-effort Open Graph / HTML preview. Failures are expected (CORS, blocks).
class LinkPreviewService {
  LinkPreviewService._();

  static final LinkPreviewService instance = LinkPreviewService._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 6),
      followRedirects: true,
      maxRedirects: 5,
      responseType: ResponseType.plain,
      headers: {
        'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
        'User-Agent':
            'Mozilla/5.0 (compatible; FamilySpace/1.0; +https://familychat-app.ru)',
      },
      validateStatus: (code) => code != null && code >= 200 && code < 400,
    ),
  );

  final Map<String, ChatLinkPreview?> _cache = {};
  final Map<String, Future<ChatLinkPreview?>> _inFlight = {};

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

  Future<ChatLinkPreview?> load(String rawUrl) {
    final url = rawUrl.trim();
    if (url.isEmpty) return Future<ChatLinkPreview?>.value(null);
    if (_cache.containsKey(url)) {
      return Future<ChatLinkPreview?>.value(_cache[url]);
    }
    final pending = _inFlight[url];
    if (pending != null) return pending;
    final future = _fetch(url);
    _inFlight[url] = future;
    return future.whenComplete(() => _inFlight.remove(url));
  }

  Future<ChatLinkPreview?> _fetch(String url) async {
    final uri = _tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _cache[url] = null;
      return null;
    }
    try {
      final res = await _dio.get<String>(uri.toString());
      final html = res.data;
      if (html == null || html.isEmpty) {
        _cache[url] = null;
        return null;
      }
      final snippet = html.length > 120000 ? html.substring(0, 120000) : html;
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
        _meta(snippet, 'twitter:image'),
      ]);
      final imageUrl = _absolutize(uri, imageRaw);
      final preview = ChatLinkPreview(
        url: url,
        host: displayHost(url),
        title: title,
        description: description,
        imageUrl: imageUrl,
      );
      _cache[url] = preview.hasCard ? preview : null;
      return _cache[url];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[LinkPreview] $url: $e');
      }
      _cache[url] = null;
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
