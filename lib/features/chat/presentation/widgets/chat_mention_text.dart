import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Рендерит текст сообщения с @упоминаниями и кликабельными ссылками.
class ChatMentionText extends StatelessWidget {
  const ChatMentionText({
    super.key,
    required this.body,
    required this.mentions,
    required this.style,
    required this.mentionStyle,
    this.linkStyle,
  });

  final String body;
  final List<Map<String, dynamic>> mentions;
  final TextStyle style;
  final TextStyle mentionStyle;
  final TextStyle? linkStyle;

  static final _urlPattern = RegExp(
    r'(?:https?:\/\/|www\.)[^\s<>"{}|\\^`\[\]]+',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) return const SizedBox.shrink();

    final resolvedLinkStyle = linkStyle ??
        style.copyWith(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        );

    if (mentions.isEmpty && !_urlPattern.hasMatch(body)) {
      return Text(body, style: style);
    }

    return Text.rich(TextSpan(children: _buildSpans(resolvedLinkStyle)));
  }

  List<InlineSpan> _buildSpans(TextStyle resolvedLinkStyle) {
    final sortedMentions = [...mentions]
      ..sort((a, b) {
        final an = a['display_name']?.toString() ?? '';
        final bn = b['display_name']?.toString() ?? '';
        return bn.length.compareTo(an.length);
      });

    final spans = <InlineSpan>[];
    var index = 0;
    while (index < body.length) {
      final mentionMatch = _matchMention(sortedMentions, index);
      if (mentionMatch != null) {
        spans.add(TextSpan(text: mentionMatch, style: mentionStyle));
        index += mentionMatch.length;
        continue;
      }

      final urlMatch = _urlPattern.matchAsPrefix(body, index);
      if (urlMatch != null) {
        final urlText = urlMatch.group(0)!;
        spans.add(
          TextSpan(
            text: urlText,
            style: resolvedLinkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _openUrl(urlText),
          ),
        );
        index += urlText.length;
        continue;
      }

      final nextAt = body.indexOf('@', index + 1);
      final nextUrl = _nextUrlStart(index + 1);
      final endCandidates = <int>[
        if (nextAt >= 0) nextAt,
        if (nextUrl >= 0) nextUrl,
      ];
      final end = endCandidates.isEmpty
          ? body.length
          : endCandidates.reduce((a, b) => a < b ? a : b);
      spans.add(TextSpan(text: body.substring(index, end), style: style));
      index = end;
    }
    return spans;
  }

  String? _matchMention(List<Map<String, dynamic>> sorted, int index) {
    if (body[index] != '@') return null;
    for (final mention in sorted) {
      final name = mention['display_name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final token = '@$name';
      if (body.startsWith(token, index)) return token;
    }
    return null;
  }

  int _nextUrlStart(int from) {
    final tail = body.substring(from);
    final http = tail.indexOf('http://');
    final https = tail.indexOf('https://');
    final www = tail.indexOf('www.');
    final candidates = [http, https, www].where((v) => v >= 0);
    if (candidates.isEmpty) return -1;
    return from + candidates.reduce((a, b) => a < b ? a : b);
  }

  Future<void> _openUrl(String raw) async {
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'https://$raw');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
