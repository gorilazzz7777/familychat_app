import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Свайп влево по сообщению → «Ответить» (как в Telegram).
class ChatSwipeToReply extends StatefulWidget {
  const ChatSwipeToReply({
    super.key,
    required this.child,
    this.onReply,
  });

  final Widget child;
  final VoidCallback? onReply;

  @override
  State<ChatSwipeToReply> createState() => _ChatSwipeToReplyState();
}

class _ChatSwipeToReplyState extends State<ChatSwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _maxDrag = 72;
  static const double _trigger = 48;

  late final AnimationController _controller;
  Animation<double>? _snap;
  double _drag = 0;
  bool _triggeredHaptic = false;
  bool _replyFired = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (widget.onReply == null) return;
    if (_controller.isAnimating) {
      _controller.stop();
      _snap = null;
    }
    final next = (_drag + details.delta.dx).clamp(-_maxDrag, 0.0);
    if (next == _drag) return;
    setState(() => _drag = next);
    final past = _drag <= -_trigger;
    if (past && !_triggeredHaptic) {
      _triggeredHaptic = true;
      HapticFeedback.selectionClick();
    } else if (!past) {
      _triggeredHaptic = false;
    }
  }

  void _onDragEnd(DragEndDetails details) {
    if (widget.onReply == null) return;
    final flingLeft =
        details.primaryVelocity != null && details.primaryVelocity! < -800;
    final shouldReply = _drag <= -_trigger || flingLeft;
    if (shouldReply && !_replyFired) {
      _replyFired = true;
      widget.onReply!();
    }
    _snapBack();
  }

  void _onDragCancel() => _snapBack();

  void _snapBack() {
    final from = _drag;
    if (from == 0) {
      _triggeredHaptic = false;
      _replyFired = false;
      return;
    }
    _snap = Tween<double>(begin: from, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller
      ..removeListener(_onSnapTick)
      ..addListener(_onSnapTick)
      ..forward(from: 0).whenComplete(() {
        if (!mounted) return;
        _controller.removeListener(_onSnapTick);
        setState(() {
          _drag = 0;
          _snap = null;
          _triggeredHaptic = false;
          _replyFired = false;
        });
      });
  }

  void _onSnapTick() {
    final anim = _snap;
    if (anim == null || !mounted) return;
    setState(() => _drag = anim.value);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;

    final theme = Theme.of(context);
    final progress = (-_drag / _trigger).clamp(0.0, 1.0);
    final iconScale = 0.55 + (0.45 * progress);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          if (_drag < -4)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: iconScale,
                  child: Icon(
                    Icons.reply_rounded,
                    color: theme.colorScheme.primary,
                    size: 28,
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_drag, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
