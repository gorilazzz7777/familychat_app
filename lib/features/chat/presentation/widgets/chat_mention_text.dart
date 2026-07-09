import 'package:flutter/material.dart';

/// Рендерит текст сообщения с подсветкой @упоминаний.
class ChatMentionText extends StatelessWidget {
  const ChatMentionText({
    super.key,
    required this.body,
    required this.mentions,
    required this.style,
    required this.mentionStyle,
  });

  final String body;
  final List<Map<String, dynamic>> mentions;
  final TextStyle style;
  final TextStyle mentionStyle;

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) return const SizedBox.shrink();
    if (mentions.isEmpty) {
      return Text(body, style: style);
    }

    final sorted = [...mentions]
      ..sort((a, b) {
        final an = a['display_name']?.toString() ?? '';
        final bn = b['display_name']?.toString() ?? '';
        return bn.length.compareTo(an.length);
      });

    final spans = <InlineSpan>[];
    var index = 0;
    while (index < body.length) {
      if (body[index] == '@') {
        String? matched;
        for (final mention in sorted) {
          final name = mention['display_name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final token = '@$name';
          if (body.startsWith(token, index)) {
            matched = token;
            break;
          }
        }
        if (matched != null) {
          spans.add(TextSpan(text: matched, style: mentionStyle));
          index += matched.length;
          continue;
        }
      }

      final nextAt = body.indexOf('@', index + 1);
      final end = nextAt == -1 ? body.length : nextAt;
      spans.add(TextSpan(text: body.substring(index, end), style: style));
      index = end;
    }

    return Text.rich(TextSpan(children: spans));
  }
}
