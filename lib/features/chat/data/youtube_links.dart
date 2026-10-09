import '../../../core/config/env.dart';

/// YouTube URL helpers for in-app proxied playback / thumbs.
abstract final class YoutubeLinks {
  static final _idInUrl = RegExp(
    r'(?:youtu\.be/|youtube\.com/(?:watch\?(?:[^#]*&)?v=|embed/|shorts/|live/)|'
    r'youtube-nocookie\.com/embed/)([A-Za-z0-9_-]{6,})',
    caseSensitive: false,
  );

  static bool isYoutubeUrl(String raw) => videoId(raw) != null;

  static String? videoId(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^[A-Za-z0-9_-]{6,20}$').hasMatch(s)) return s;
    return _idInUrl.firstMatch(s)?.group(1);
  }

  /// Thumbnail via familychat yt-relay (phone cannot reach ytimg in RU).
  static String? proxiedThumbUrl(String pageUrl) {
    final id = videoId(pageUrl);
    if (id == null) return null;
    final origin = Uri.parse(Env.apiBaseUrl).origin;
    return '$origin/yt-relay/thumb/$id.jpg';
  }
}
