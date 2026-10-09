import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../telegram_tdlib/telegram_link_navigation.dart';
import '../youtube_proxy_navigation.dart';

/// Styled range from Telegram TDLib `textEntity` (UTF-16 offsets).
class ChatTextEntity {
  const ChatTextEntity({
    required this.offset,
    required this.length,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.code = false,
    this.url,
  });

  final int offset;
  final int length;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool code;
  final String? url;

  factory ChatTextEntity.fromMap(Map<String, dynamic> m, {String body = ''}) {
    final offset = (m['offset'] as num?)?.toInt() ?? 0;
    final length = (m['length'] as num?)?.toInt() ?? 0;
    var url = m['url']?.toString();
    final kind = m['url_kind']?.toString();
    if ((url == null || url.isEmpty) &&
        kind != null &&
        offset >= 0 &&
        length > 0 &&
        offset + length <= body.length) {
      final slice = body.substring(offset, offset + length);
      switch (kind) {
        case 'url':
          url = slice;
        case 'email':
          url = 'mailto:$slice';
        case 'phone':
          url = 'tel:${slice.replaceAll(RegExp(r'[\s\-()]'), '')}';
        case 'mention':
          final user = slice.startsWith('@') ? slice.substring(1) : slice;
          url = 'https://t.me/$user';
      }
    }
    return ChatTextEntity(
      offset: offset,
      length: length,
      bold: m['bold'] == true,
      italic: m['italic'] == true,
      underline: m['underline'] == true,
      strikethrough: m['strikethrough'] == true,
      code: m['code'] == true,
      url: url,
    );
  }

  static List<ChatTextEntity> listFromMaps(
    String body,
    List<Map<String, dynamic>> raw,
  ) {
    if (raw.isEmpty) return const [];
    return [
      for (final m in raw) ChatTextEntity.fromMap(m, body: body),
    ];
  }

  Map<String, dynamic> toMap() => {
        'offset': offset,
        'length': length,
        if (bold) 'bold': true,
        if (italic) 'italic': true,
        if (underline) 'underline': true,
        if (strikethrough) 'strikethrough': true,
        if (code) 'code': true,
        if (url != null && url!.isNotEmpty) 'url': url,
      };
}

/// Рендерит текст сообщения с @упоминаниями, TDLib-сущностями и кликабельными ссылками.
class ChatMentionText extends StatelessWidget {
  const ChatMentionText({
    super.key,
    required this.body,
    required this.mentions,
    required this.style,
    required this.mentionStyle,
    this.linkStyle,
    this.entities = const [],
    this.maxLines,
    this.overflow,
    this.onOpenUrl,
  });

  final String body;
  final List<Map<String, dynamic>> mentions;
  final TextStyle style;
  final TextStyle mentionStyle;
  final TextStyle? linkStyle;
  final List<ChatTextEntity> entities;
  final int? maxLines;
  final TextOverflow? overflow;
  /// Return true if the URL was handled (skip external launch).
  final Future<bool> Function(String url)? onOpenUrl;

  static final _urlPattern = RegExp(
    r'(?:https?:\/\/|www\.)[^\s<>"{}|\\^`\[\]]+',
    caseSensitive: false,
  );

  static const _trailingPunctuation = r''')]}>,.;:!?»"'«''';

  static String? firstUrl(String body) {
    final match = _urlPattern.firstMatch(body);
    if (match == null) return null;
    return stripTrailingPunctuation(match.group(0)!);
  }

  static String stripTrailingPunctuation(String raw) {
    var value = raw.trim();
    while (value.isNotEmpty &&
        _trailingPunctuation.contains(value[value.length - 1])) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) return const SizedBox.shrink();

    final resolvedLinkStyle = (linkStyle ??
            style.copyWith(color: Theme.of(context).colorScheme.primary))
        .copyWith(decoration: TextDecoration.none);

    if (entities.isNotEmpty) {
      return Text.rich(
        TextSpan(children: _buildEntitySpans(context, resolvedLinkStyle)),
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    if (mentions.isEmpty && !_urlPattern.hasMatch(body)) {
      return Text(
        body,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    return Text.rich(
      TextSpan(children: _buildSpans(context, resolvedLinkStyle)),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  List<InlineSpan> _buildEntitySpans(
    BuildContext context,
    TextStyle resolvedLinkStyle,
  ) {
    final n = body.length;
    if (n == 0) return const [];

    final bold = List<bool>.filled(n, false);
    final italic = List<bool>.filled(n, false);
    final underline = List<bool>.filled(n, false);
    final strike = List<bool>.filled(n, false);
    final code = List<bool>.filled(n, false);
    final urls = List<String?>.filled(n, null);

    for (final e in entities) {
      if (e.length <= 0) continue;
      final start = e.offset.clamp(0, n);
      final end = (e.offset + e.length).clamp(0, n);
      if (start >= end) continue;
      for (var i = start; i < end; i++) {
        if (e.bold) bold[i] = true;
        if (e.italic) italic[i] = true;
        if (e.underline) underline[i] = true;
        if (e.strikethrough) strike[i] = true;
        if (e.code) code[i] = true;
        final u = e.url?.trim();
        if (u != null && u.isNotEmpty) urls[i] = u;
      }
    }

    bool sameAt(int a, int b) =>
        bold[a] == bold[b] &&
        italic[a] == italic[b] &&
        underline[a] == underline[b] &&
        strike[a] == strike[b] &&
        code[a] == code[b] &&
        urls[a] == urls[b];

    final spans = <InlineSpan>[];
    var i = 0;
    while (i < n) {
      var j = i + 1;
      while (j < n && sameAt(i, j)) {
        j++;
      }
      final chunk = body.substring(i, j);
      final url = urls[i];
      var runStyle = style;
      if (bold[i]) {
        runStyle = runStyle.copyWith(fontWeight: FontWeight.w700);
      }
      if (italic[i]) {
        runStyle = runStyle.copyWith(fontStyle: FontStyle.italic);
      }
      if (underline[i] || strike[i]) {
        runStyle = runStyle.copyWith(
          decoration: TextDecoration.combine([
            if (underline[i]) TextDecoration.underline,
            if (strike[i]) TextDecoration.lineThrough,
          ]),
        );
      }
      if (code[i]) {
        runStyle = runStyle.copyWith(
          fontFamily: 'monospace',
          backgroundColor: const Color(0x22000000),
        );
      }
      if (url != null && url.isNotEmpty) {
        runStyle = resolvedLinkStyle.merge(
          TextStyle(
            fontWeight: bold[i] ? FontWeight.w700 : resolvedLinkStyle.fontWeight,
            fontStyle: italic[i] ? FontStyle.italic : resolvedLinkStyle.fontStyle,
          ),
        );
        spans.add(
          TextSpan(
            text: chunk,
            style: runStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _openUrl(context, url),
          ),
        );
      } else {
        spans.add(TextSpan(text: chunk, style: runStyle));
      }
      i = j;
    }
    return spans;
  }

  List<InlineSpan> _buildSpans(
    BuildContext context,
    TextStyle resolvedLinkStyle,
  ) {
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
        final urlText = stripTrailingPunctuation(urlMatch.group(0)!);
        if (urlText.isEmpty) {
          index += 1;
          continue;
        }
        spans.add(
          TextSpan(
            text: urlText,
            style: resolvedLinkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _openUrl(context, urlText),
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

  Future<void> _openUrl(BuildContext context, String raw) async {
    var value = raw.trim();
    if (value.startsWith('@') && value.length > 1) {
      value = 'https://t.me/${value.substring(1)}';
    } else if (value.startsWith('tg://')) {
      // keep
    } else if (!value.startsWith('http://') && !value.startsWith('https://')) {
      if (value.contains('@') && !value.contains(' ')) {
        value = 'mailto:$value';
      } else if (RegExp(r'^\+?[\d\s\-()]+$').hasMatch(value)) {
        value = 'tel:${value.replaceAll(RegExp(r'[\s\-()]'), '')}';
      } else {
        value = 'https://$value';
      }
    }
    if (onOpenUrl != null) {
      try {
        if (await onOpenUrl!(value)) return;
      } catch (_) {}
    }
    try {
      if (await YoutubeProxyNavigation.tryOpen(context, value)) return;
    } catch (_) {}
    try {
      if (await TelegramLinkNavigation.tryOpen(value)) return;
    } catch (_) {}
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
