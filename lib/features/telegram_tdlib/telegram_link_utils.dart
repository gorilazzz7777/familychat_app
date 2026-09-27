/// Helpers for Telegram deep links (`t.me`, `telegram.me`, `tg://`).
abstract final class TelegramLinkUtils {
  static final _hostPattern = RegExp(
    r'^(?:www\.)?(?:t\.me|telegram\.me|telegram\.dog)$',
    caseSensitive: false,
  );

  /// True for public/private Telegram message / chat / username links.
  static bool looksLikeTelegramLink(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return false;
    if (value.startsWith('tg://')) return true;
    final uri = Uri.tryParse(_ensureScheme(value));
    if (uri == null) return false;
    if (!_hostPattern.hasMatch(uri.host)) return false;
    final path = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (path.isEmpty) return false;
    // Skip joinchat / addstickers / proxy / socks / share — open externally.
    final first = path.first.toLowerCase();
    if (first == 'joinchat' ||
        first == 'addstickers' ||
        first == 'addtheme' ||
        first == 'proxy' ||
        first == 'socks' ||
        first == 'share' ||
        first == 'iv' ||
        first == 'setlanguage') {
      return false;
    }
    return true;
  }

  /// Normalize to an https URL TDLib `getMessageLinkInfo` accepts when possible.
  static String normalize(String raw) {
    var value = raw.trim();
    if (value.startsWith('@') && value.length > 1) {
      return 'https://t.me/${value.substring(1)}';
    }
    if (value.startsWith('tg://')) {
      final uri = Uri.tryParse(value);
      if (uri != null) {
        final domain = uri.queryParameters['domain'] ??
            uri.queryParameters['phone'];
        final post = uri.queryParameters['post'];
        if (domain != null && domain.isNotEmpty) {
          if (post != null && post.isNotEmpty) {
            return 'https://t.me/$domain/$post';
          }
          return 'https://t.me/$domain';
        }
        // tg://privatepost?channel=…&post=…
        final channel = uri.queryParameters['channel'];
        final channelPost = uri.queryParameters['post'];
        if (channel != null &&
            channel.isNotEmpty &&
            channelPost != null &&
            channelPost.isNotEmpty) {
          return 'https://t.me/c/$channel/$channelPost';
        }
      }
      return value;
    }
    value = _ensureScheme(value);
    return value;
  }

  static String? usernameFromLink(String raw) {
    final uri = Uri.tryParse(normalize(raw));
    if (uri == null) return null;
    if (!_hostPattern.hasMatch(uri.host)) return null;
    final path = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (path.isEmpty) return null;
    final first = path.first;
    if (first.toLowerCase() == 'c' || first.toLowerCase() == 's') {
      return null;
    }
    if (RegExp(r'^\d+$').hasMatch(first)) return null;
    return first.replaceFirst(RegExp(r'^@'), '');
  }

  static String _ensureScheme(String value) {
    final v = value.trim();
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    return 'https://$v';
  }
}
