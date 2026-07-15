import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/chat_send_options.dart';
import '../../data/chat_voice_recorder.dart';
import 'chat_compose_circle_button.dart';
import 'chat_send_options_sheet.dart';

class ChatVoiceRecordingChange {
  const ChatVoiceRecordingChange({
    required this.isRecording,
    required this.durationMs,
    this.willCancel = false,
  });

  final bool isRecording;
  final int durationMs;
  final bool willCancel;
}

/// Кнопка ввода: пустое поле — удержание для голосового, иначе отправка текста.
class ChatComposeActionButton extends StatefulWidget {
  const ChatComposeActionButton({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onVoiceComplete,
    this.forceSendButton = false,
    this.onRecordingChanged,
  });

  final TextEditingController controller;
  final void Function(ChatSendOptions options) onSend;
  final Future<void> Function(
    Uint8List bytes,
    int durationMs, {
    String? encoderName,
  }) onVoiceComplete;
  final bool forceSendButton;
  final void Function(ChatVoiceRecordingChange change)? onRecordingChanged;

  @override
  State<ChatComposeActionButton> createState() =>
      _ChatComposeActionButtonState();
}

class _ChatComposeActionButtonState extends State<ChatComposeActionButton> {
  static const double _cancelPx = 64;
  static const int _minSendMs = 400;

  final _recorder = ChatVoiceRecorder();
  bool _hasText = false;
  bool _holdActive = false;
  bool _willCancel = false;
  bool _releasing = false;
  int? _activePointer;
  Offset? _downGlobal;
  double _slideDx = 0;
  Timer? _recordingTimer;
  DateTime? _holdStartedAt;
  Future<void>? _startFuture;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_recorder.ensurePermission());
      });
    }
  }

  @override
  void dispose() {
    _detachPointerRoute();
    widget.controller.removeListener(_onTextChanged);
    _recordingTimer?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText == _hasText) return;
    setState(() => _hasText = hasText);
  }

  bool get _showSend => widget.forceSendButton || _hasText;

  void _notifyRecording({
    required bool isRecording,
    required int durationMs,
    bool willCancel = false,
  }) {
    widget.onRecordingChanged?.call(
      ChatVoiceRecordingChange(
        isRecording: isRecording,
        durationMs: durationMs,
        willCancel: willCancel,
      ),
    );
  }

  void _startHoldTimer() {
    _holdStartedAt = DateTime.now();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final startedAt = _holdStartedAt;
      if (startedAt == null || !mounted) return;
      _notifyRecording(
        isRecording: true,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        willCancel: _willCancel,
      );
    });
  }

  void _stopHoldTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
  }

  int _holdDurationMs() {
    final startedAt = _holdStartedAt;
    if (startedAt == null) return 0;
    return DateTime.now().difference(startedAt).inMilliseconds;
  }

  Future<void> _ensureRecordingStarted() async {
    final granted = await _recorder.ensurePermission();
    if (!granted) {
      throw StateError('permission');
    }
    await _recorder.start();
  }

  void _detachPointerRoute() {
    final pointer = _activePointer;
    if (pointer == null) return;
    try {
      GestureBinding.instance.pointerRouter.removeRoute(
        pointer,
        _onGlobalPointer,
      );
    } catch (_) {}
  }

  void _onGlobalPointer(PointerEvent event) {
    final pointer = _activePointer;
    if (pointer == null || event.pointer != pointer) return;
    if (event is PointerMoveEvent) {
      _onPointerMove(event);
    } else if (event is PointerUpEvent) {
      _detachPointerRoute();
      unawaited(_onPointerUp(event));
    } else if (event is PointerCancelEvent) {
      _detachPointerRoute();
      unawaited(_onPointerCancel(event));
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_showSend || _activePointer != null || _releasing) return;
    _activePointer = event.pointer;
    _downGlobal = event.position;
    _slideDx = 0;
    _willCancel = false;
    setState(() => _holdActive = true);
    _startHoldTimer();
    _notifyRecording(isRecording: true, durationMs: 0);
    _startFuture = _ensureRecordingStarted();
    _startFuture!.catchError((_) {});
    // Ловим move/up глобально: палец может уйти с кнопки при свайпе.
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _onGlobalPointer,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || _downGlobal == null) return;
    final dx = (event.position.dx - _downGlobal!.dx).clamp(-120.0, 0.0);
    final willCancel = dx <= -_cancelPx;
    if (dx == _slideDx && willCancel == _willCancel) return;
    if (willCancel && !_willCancel) {
      HapticFeedback.selectionClick();
    }
    if (!mounted) return;
    setState(() {
      _slideDx = dx;
      _willCancel = willCancel;
    });
    _notifyRecording(
      isRecording: true,
      durationMs: _holdDurationMs(),
      willCancel: willCancel,
    );
  }

  Future<void> _onPointerUp(PointerUpEvent event) async {
    if (_activePointer != null && event.pointer != _activePointer) return;
    final cancel = _willCancel;
    await _releaseHold(send: !cancel);
  }

  Future<void> _onPointerCancel(PointerCancelEvent event) async {
    if (_activePointer != null && event.pointer != _activePointer) return;
    await _releaseHold(send: false);
  }

  Future<void> _releaseHold({required bool send}) async {
    if (_releasing) return;
    if (!_holdActive && _activePointer == null && _startFuture == null) {
      return;
    }
    _releasing = true;
    _detachPointerRoute();

    final holdMs = _holdDurationMs();
    final startFuture = _startFuture;
    _activePointer = null;
    _holdStartedAt = null;
    _downGlobal = null;
    _stopHoldTimer();

    if (mounted) {
      setState(() {
        _holdActive = false;
        _slideDx = 0;
        _willCancel = false;
      });
    } else {
      _holdActive = false;
      _slideDx = 0;
      _willCancel = false;
    }
    _notifyRecording(isRecording: false, durationMs: 0);

    try {
      try {
        await startFuture;
      } catch (error) {
        if (!mounted) return;
        if (error is StateError && error.message == 'permission') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нужен доступ к микрофону')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                kIsWeb
                    ? 'Не удалось начать запись. Разрешите микрофон в браузере'
                    : 'Не удалось начать запись',
              ),
            ),
          );
        }
        await _recorder.cancel();
        return;
      } finally {
        _startFuture = null;
      }

      if (!send || holdMs < _minSendMs) {
        await _recorder.cancel();
        return;
      }

      final result = await _recorder.stop();
      if (result == null || result.bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось записать голосовое')),
        );
        return;
      }

      final durationMs = result.durationMs > 0 ? result.durationMs : holdMs;
      if (durationMs < _minSendMs) {
        await _recorder.cancel();
        return;
      }

      await widget.onVoiceComplete(
        result.bytes,
        durationMs,
        encoderName: result.encoder.name,
      );
    } finally {
      _releasing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (_showSend) {
      return ChatComposeCircleButton(
        tooltip: 'Отправить',
        icon: Icons.send_rounded,
        onTap: () => widget.onSend(ChatSendOptions.normal),
        onLongPress: () async {
          final options = await ChatSendOptionsSheet.show(context);
          if (options == null) return;
          widget.onSend(options);
        },
      );
    }

    final cancelLook = _holdActive && _willCancel;

    // Без Tooltip: его long-press ломает отпускание / отправку голосового.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (e) => unawaited(_onPointerUp(e)),
      onPointerCancel: (e) => unawaited(_onPointerCancel(e)),
      child: Transform.translate(
        offset: Offset(_slideDx, 0),
        child: AnimatedScale(
          scale: _holdActive ? 3.0 : 1.0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          // Центр на месте: низ/право уходят за край экрана и обрезаются.
          alignment: Alignment.center,
          child: ChatComposeCircleButton(
            icon: Icons.mic_rounded,
            iconColor: _holdActive
                ? (cancelLook ? cs.onError : cs.error)
                : cs.primary,
            backgroundColor: _holdActive
                ? (cancelLook
                    ? cs.error
                    : cs.errorContainer.withValues(alpha: 0.85))
                : null,
          ),
        ),
      ),
    );
  }
}
