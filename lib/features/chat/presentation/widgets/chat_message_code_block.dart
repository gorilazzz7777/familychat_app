import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// Telegram-style `textEntityTypePre` / `textEntityTypePreCode` block.
///
/// Matches official Mash: grey rounded panel, optional language header,
/// monospace + light syntax colors, full code (no vertical clip), copy button.
class ChatMessageCodeBlock extends StatelessWidget {
  const ChatMessageCodeBlock({
    super.key,
    required this.code,
    this.language,
    this.isMine = false,
  });

  final String code;
  final String? language;
  final bool isMine;

  static const _bgIn = Color(0xFFF1F3F5);
  static const _bgOut = Color(0x33FFFFFF);
  static const _headerIn = Color(0xFF707579);
  static const _headerOut = Color(0xCCFFFFFF);
  static const _copyIn = Color(0xFF4DBBFF);
  static const _copyOut = Color(0xFF8FD3FF);

  /// Mash syntax colors (sampled from official TG Android).
  static const _tag = Color(0xFF7F79F3);
  static const _attr = Color(0xFFF28C39);
  static const _string = Color(0xFF37C123);
  static const _comment = Color(0xFF707579);
  static const _number = Color(0xFF2980B9);
  static const _keyword = Color(0xFF7F79F3);

  @override
  Widget build(BuildContext context) {
    final lang = (language ?? '').trim();
    final langLabel = lang.isEmpty ? null : lang.toUpperCase();
    final bg = isMine ? _bgOut : _bgIn;
    final headerColor = isMine ? _headerOut : _headerIn;
    final copyColor = isMine ? _copyOut : _copyIn;
    final baseColor =
        isMine ? Colors.white.withValues(alpha: 0.95) : const Color(0xFF000000);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.35,
      color: baseColor,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (langLabel != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(
                    langLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: headerColor,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  langLabel != null ? 6 : 10,
                  12,
                  8,
                ),
                child: Text.rich(
                  TextSpan(
                    style: mono,
                    children: _highlightSpans(code, lang, mono),
                  ),
                ),
              ),
              InkWell(
                onTap: () => _copy(context),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.copy, size: 15, color: copyColor),
                      const SizedBox(width: 6),
                      Text(
                        'КОПИРОВАТЬ КОД',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: copyColor,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Код скопирован'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  static List<InlineSpan> _highlightSpans(
    String source,
    String language,
    TextStyle base,
  ) {
    final lang = language.toLowerCase().trim();
    if (lang == 'xml' ||
        lang == 'html' ||
        (lang.isEmpty && _looksLikeXml(source))) {
      return _highlightXml(source, base);
    }
    if (lang == 'json' || (lang.isEmpty && _looksLikeJson(source))) {
      return _highlightJson(source, base);
    }
    return [TextSpan(text: source, style: base)];
  }

  static bool _looksLikeJson(String s) {
    final t = s.trimLeft();
    return t.startsWith('{') || t.startsWith('[');
  }

  static bool _looksLikeXml(String s) {
    final t = s.trimLeft();
    return t.startsWith('<?xml') || (t.startsWith('<') && t.contains('>'));
  }

  static List<InlineSpan> _highlightXml(String source, TextStyle base) {
    final spans = <InlineSpan>[];
    var i = 0;
    final n = source.length;

    void add(String text, Color? color) {
      if (text.isEmpty) return;
      spans.add(
        TextSpan(
          text: text,
          style: color == null ? base : base.copyWith(color: color),
        ),
      );
    }

    while (i < n) {
      if (source.startsWith('<!--', i)) {
        final end = source.indexOf('-->', i + 4);
        final e = end < 0 ? n : end + 3;
        add(source.substring(i, e), _comment);
        i = e;
        continue;
      }
      if (source.startsWith('<?', i)) {
        final end = source.indexOf('?>', i + 2);
        final e = end < 0 ? n : end + 2;
        add(source.substring(i, e), _comment);
        i = e;
        continue;
      }
      if (source[i] == '<') {
        add('<', _tag);
        i++;
        if (i < n && source[i] == '/') {
          add('/', _tag);
          i++;
        }
        final nameStart = i;
        while (i < n &&
            source[i] != '>' &&
            source[i] != '/' &&
            !_isXmlSpace(source[i])) {
          i++;
        }
        if (i > nameStart) add(source.substring(nameStart, i), _tag);

        while (i < n && source[i] != '>') {
          if (source[i] == '/' && i + 1 < n && source[i + 1] == '>') {
            add('/>', _tag);
            i += 2;
            break;
          }
          if (_isXmlSpace(source[i])) {
            final wsStart = i;
            while (i < n && _isXmlSpace(source[i])) {
              i++;
            }
            add(source.substring(wsStart, i), null);
            continue;
          }
          final aStart = i;
          while (i < n &&
              source[i] != '=' &&
              source[i] != '>' &&
              source[i] != '/' &&
              !_isXmlSpace(source[i])) {
            i++;
          }
          if (i > aStart) add(source.substring(aStart, i), _attr);
          if (i < n && source[i] == '=') {
            add('=', _tag);
            i++;
            while (i < n && _isXmlSpace(source[i])) {
              add(source[i], null);
              i++;
            }
            if (i < n && (source[i] == '"' || source[i] == "'")) {
              final q = source[i];
              final vStart = i;
              i++;
              while (i < n && source[i] != q) {
                if (source[i] == '\\' && i + 1 < n) {
                  i += 2;
                } else {
                  i++;
                }
              }
              if (i < n) i++;
              add(source.substring(vStart, i), _string);
            }
          }
        }
        if (i < n && source[i] == '>') {
          add('>', _tag);
          i++;
        }
        continue;
      }

      final tStart = i;
      while (i < n && source[i] != '<') {
        i++;
      }
      add(source.substring(tStart, i), null);
    }

    return spans.isEmpty ? [TextSpan(text: source, style: base)] : spans;
  }

  static bool _isXmlSpace(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';

  static List<InlineSpan> _highlightJson(String source, TextStyle base) {
    final spans = <InlineSpan>[];
    final re = RegExp(
      r'("(?:\\.|[^"\\])*")(\s*:)?'
      r'|(\btrue\b|\bfalse\b|\bnull\b)'
      r'|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)'
      r'|([\[\]{},:])'
      r'|(\s+)'
      r'|(.)',
      multiLine: true,
    );
    for (final m in re.allMatches(source)) {
      final str = m.group(1);
      final colonAfterKey = m.group(2);
      final kw = m.group(3);
      final num = m.group(4);
      final punct = m.group(5);
      final ws = m.group(6);
      final other = m.group(7);
      if (str != null) {
        final isKey = colonAfterKey != null;
        spans.add(
          TextSpan(
            text: str,
            style: base.copyWith(color: isKey ? _attr : _string),
          ),
        );
        if (colonAfterKey != null) {
          spans.add(
            TextSpan(text: colonAfterKey, style: base.copyWith(color: _tag)),
          );
        }
        continue;
      }
      if (kw != null) {
        spans.add(TextSpan(text: kw, style: base.copyWith(color: _keyword)));
        continue;
      }
      if (num != null) {
        spans.add(TextSpan(text: num, style: base.copyWith(color: _number)));
        continue;
      }
      if (punct != null) {
        spans.add(TextSpan(text: punct, style: base.copyWith(color: _tag)));
        continue;
      }
      if (ws != null) {
        spans.add(TextSpan(text: ws, style: base));
        continue;
      }
      if (other != null) {
        spans.add(TextSpan(text: other, style: base));
      }
    }
    return spans.isEmpty ? [TextSpan(text: source, style: base)] : spans;
  }
}
