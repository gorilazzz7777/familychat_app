import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// Inline Telegram block quote (`textEntityTypeBlockQuote` /
/// `textEntityTypeExpandableBlockQuote`).
///
/// Expandable quotes start collapsed (~3 lines + bottom fade + chevron),
/// matching official Telegram Android.
class ChatMessageBlockQuote extends StatefulWidget {
  const ChatMessageBlockQuote({
    super.key,
    required this.child,
    required this.accentColor,
    this.fillColor,
    this.expandable = false,
    this.collapsedMaxLines = 3,
  });

  final Widget child;
  final Color accentColor;
  final Color? fillColor;
  final bool expandable;
  final int collapsedMaxLines;

  @override
  State<ChatMessageBlockQuote> createState() => _ChatMessageBlockQuoteState();
}

class _ChatMessageBlockQuoteState extends State<ChatMessageBlockQuote> {
  late bool _expanded = !widget.expandable;

  @override
  void didUpdateWidget(covariant ChatMessageBlockQuote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandable && !widget.expandable) {
      _expanded = true;
    } else if (!oldWidget.expandable && widget.expandable) {
      _expanded = false;
    }
  }

  void _toggle() {
    if (!widget.expandable) return;
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    // Official Mash quote fill ≈ #F5EFFB, bar ≈ #AA7CE1.
    final fill = widget.fillColor ?? const Color(0xFFF5EFFB);
    final accent = widget.accentColor;
    final showChevron = widget.expandable;
    final collapsed = widget.expandable && !_expanded;

    final text = DefaultTextStyle.merge(
      style: TextStyle(
        fontStyle: FontStyle.italic,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      child: widget.child,
    );

    final body = collapsed
        ? _CollapsedQuoteBody(
            maxLines: widget.collapsedMaxLines,
            child: text,
          )
        : text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: showChevron ? _toggle : null,
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                ColoredBox(
                  color: fill,
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(width: 3, color: accent),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              8,
                              8,
                              showChevron ? 22 : 10,
                              showChevron ? 18 : 8,
                            ),
                            child: body,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    LucideIcons.quote,
                    size: 14,
                    color: accent.withValues(alpha: 0.85),
                  ),
                ),
                if (showChevron)
                  Positioned(
                    right: 2,
                    bottom: 0,
                    child: Icon(
                      expandedIcon,
                      size: 18,
                      color: accent.withValues(alpha: 0.9),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData get expandedIcon =>
      _expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down;
}

/// Collapsed quote text with a bottom fade (TG parity).
class _CollapsedQuoteBody extends StatelessWidget {
  const _CollapsedQuoteBody({
    required this.child,
    required this.maxLines,
  });

  final Widget child;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final fontSize = style.fontSize ?? 16;
    final height = style.height ?? 1.35;
    final maxH = fontSize * height * maxLines;

    return SizedBox(
      height: maxH,
      width: double.infinity,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0.0, 0.55, 1.0],
          ).createShader(rect);
        },
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxHeight: double.infinity,
            child: child,
          ),
        ),
      ),
    );
  }
}
