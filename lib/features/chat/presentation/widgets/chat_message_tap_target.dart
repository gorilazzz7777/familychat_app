import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/platform/browser_info.dart';

/// Тап / long-press для пузыря сообщения.
///
/// [GestureDetector] с **только** [onTap] (без [onLongPress]) — тап срабатывает
/// сразу, не ждёт long-press timeout. Это критично для iOS WebKit (Safari /
/// «На экран Домой»), где связка tap+longPress часто «съедает» короткое нажатие.
///
/// Long-press для мультивыбора — отдельный таймер на [Listener], вне gesture arena,
/// поэтому цитаты / ссылки / картинки по-прежнему могут выиграть свой тап.
class ChatMessageTapTarget extends StatefulWidget {
  const ChatMessageTapTarget({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<ChatMessageTapTarget> createState() => _ChatMessageTapTargetState();
}

class _ChatMessageTapTargetState extends State<ChatMessageTapTarget> {
  static const _moveSlop = 18.0;

  int? _pointer;
  Offset? _downPosition;
  Timer? _longPressTimer;
  bool _longPressFired = false;

  Duration get _longPressDelay {
    if (kIsWeb && isIosBrowser) {
      return const Duration(milliseconds: 380);
    }
    return const Duration(milliseconds: 500);
  }

  void _clearTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _reset() {
    _clearTimer();
    _pointer = null;
    _downPosition = null;
    _longPressFired = false;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.onLongPress == null) return;
    _clearTimer();
    _pointer = event.pointer;
    _downPosition = event.position;
    _longPressFired = false;
    _longPressTimer = Timer(_longPressDelay, () {
      if (!mounted || _pointer != event.pointer) return;
      _longPressFired = true;
      if (kIsWeb && isIosBrowser) {
        HapticFeedback.selectionClick();
      }
      widget.onLongPress?.call();
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _downPosition == null) return;
    if ((event.position - _downPosition!).distance > _moveSlop) {
      _clearTimer();
      _pointer = null;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    _clearTimer();
    _pointer = null;
    _downPosition = null;
    // После срабатывания long-press не даём GestureDetector.onTap открыть меню.
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_pointer != event.pointer) return;
    _reset();
  }

  void _handleTap() {
    if (_longPressFired) return;
    widget.onTap?.call();
  }

  @override
  void dispose() {
    _clearTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null && widget.onLongPress == null) {
      return widget.child;
    }

    Widget child = widget.child;
    if (widget.onTap != null) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: child,
      );
    }

    if (widget.onLongPress != null) {
      child = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: child,
      );
    }

    // iOS WebKit иначе перехватывает жест в selection/callout.
    return SelectionContainer.disabled(child: child);
  }
}
