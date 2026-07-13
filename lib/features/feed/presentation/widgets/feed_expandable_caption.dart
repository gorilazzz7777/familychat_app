import 'package:flutter/material.dart';

/// Описание поста: до 2 строк, затем «Показать еще» / «Свернуть».
class FeedExpandableCaption extends StatefulWidget {
  const FeedExpandableCaption({
    super.key,
    required this.text,
    this.collapsedMaxLines = 2,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 0),
  });

  final String text;
  final int collapsedMaxLines;
  final EdgeInsetsGeometry padding;

  @override
  State<FeedExpandableCaption> createState() => _FeedExpandableCaptionState();
}

class _FeedExpandableCaptionState extends State<FeedExpandableCaption> {
  bool _expanded = false;

  bool _textOverflows({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required int maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  TextStyle _linkStyle(ThemeData theme) {
    return theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ) ??
        TextStyle(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyMedium;
    final linkStyle = _linkStyle(theme);

    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final overflows = _textOverflows(
            text: widget.text,
            style: bodyStyle ?? const TextStyle(),
            maxWidth: constraints.maxWidth,
            maxLines: widget.collapsedMaxLines,
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: overflows ? _toggle : null,
                behavior: HitTestBehavior.opaque,
                child: Text(
                  widget.text,
                  style: bodyStyle,
                  maxLines: _expanded ? null : widget.collapsedMaxLines,
                  overflow: _expanded ? TextOverflow.visible : TextOverflow.clip,
                ),
              ),
              if (overflows && !_expanded) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: _toggle,
                  child: Text('Показать еще', style: linkStyle),
                ),
              ],
              if (overflows && _expanded) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: _toggle,
                  child: Text('Свернуть', style: linkStyle),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
