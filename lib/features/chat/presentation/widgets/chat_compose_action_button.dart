import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/chat_send_options.dart';
import '../../data/chat_voice_recorder.dart';
import '../record_video_circle_screen.dart';
import 'chat_compose_circle_button.dart';
import 'chat_send_options_sheet.dart';
import 'chat_video_circle_session.dart';
import 'chat_voice_recording_compose_slot.dart';

class ChatVoiceRecordingChange {
  const ChatVoiceRecordingChange({
    required this.isRecording,
    required this.durationMs,
    this.willCancel = false,
    this.locked = false,
    this.kind = ChatComposeRecordKind.voice,
  });

  final bool isRecording;
  final int durationMs;
  final bool willCancel;
  final bool locked;
  final ChatComposeRecordKind kind;
}

/// Связка «ОТМЕНА» / отправка из строки ввода с кнопкой записи.
class ChatComposeRecordingHost {
  VoidCallback? cancelLocked;
  VoidCallback? sendLocked;
}

/// Кнопка ввода: тап — голос/кружок; удержание — запись; свайп — замок.
class ChatComposeActionButton extends StatefulWidget {
  const ChatComposeActionButton({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onVoiceComplete,
    this.onVideoCircleComplete,
    this.forceSendButton = false,
    this.voiceTranscriptionEnabled = false,
    this.showAiAssist = false,
    this.onRecordingChanged,
    this.circleSession,
    this.recordingHost,
  });

  final TextEditingController controller;
  final void Function(ChatSendOptions options) onSend;
  final Future<void> Function(
    Uint8List bytes,
    int durationMs, {
    String? encoderName,
  }) onVoiceComplete;
  final Future<void> Function(VideoCircleRecording recording)?
      onVideoCircleComplete;
  final bool forceSendButton;
  final bool voiceTranscriptionEnabled;
  final bool showAiAssist;
  final void Function(ChatVoiceRecordingChange change)? onRecordingChanged;
  /// Общая сессия камеры (чтобы композ мог рисовать превью).
  final ChatVideoCircleSession? circleSession;
  final ChatComposeRecordingHost? recordingHost;

  @override
  State<ChatComposeActionButton> createState() =>
      _ChatComposeActionButtonState();
}

class _ChatComposeActionButtonState extends State<ChatComposeActionButton> {
  static const double _cancelPx = 64;
  static const double _lockPx = 52;
  static const int _minSendMs = 400;
  static const int _tapToggleMs = 220;

  final _recorder = ChatVoiceRecorder();
  late final ChatVideoCircleSession _ownedCircleSession;
  ChatVideoCircleSession get _circle =>
      widget.circleSession ?? _ownedCircleSession;

  bool _hasText = false;
  bool _circleMode = false;
  bool _holdActive = false;
  bool _locked = false;
  bool _willCancel = false;
  bool _releasing = false;
  bool _recordingStarted = false;
  int? _activePointer;
  Offset? _downGlobal;
  double _slideDx = 0;
  Timer? _recordingTimer;
  Timer? _armTimer;
  DateTime? _holdStartedAt;
  Future<void>? _startFuture;

  @override
  void initState() {
    super.initState();
    _ownedCircleSession = ChatVideoCircleSession();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    widget.recordingHost?.cancelLocked = () => unawaited(_onLockedCancel());
    widget.recordingHost?.sendLocked = () => unawaited(_onLockedSend());
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_recorder.ensurePermission());
      });
    }
  }

  @override
  void didUpdateWidget(covariant ChatComposeActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recordingHost != widget.recordingHost) {
      oldWidget.recordingHost?.cancelLocked = null;
      oldWidget.recordingHost?.sendLocked = null;
      widget.recordingHost?.cancelLocked = () => unawaited(_onLockedCancel());
      widget.recordingHost?.sendLocked = () => unawaited(_onLockedSend());
    }
  }

  @override
  void dispose() {
    widget.recordingHost?.cancelLocked = null;
    widget.recordingHost?.sendLocked = null;
    _detachPointerRoute();
    _armTimer?.cancel();
    widget.controller.removeListener(_onTextChanged);
    _recordingTimer?.cancel();
    unawaited(_recorder.dispose());
    if (widget.circleSession == null) {
      _ownedCircleSession.dispose();
    }
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText == _hasText) return;
    setState(() => _hasText = hasText);
  }

  bool get _showSend => widget.forceSendButton || _hasText;

  ChatComposeRecordKind get _kind =>
      _circleMode ? ChatComposeRecordKind.circle : ChatComposeRecordKind.voice;

  void _notifyRecording({
    required bool isRecording,
    required int durationMs,
    bool willCancel = false,
    bool? locked,
  }) {
    widget.onRecordingChanged?.call(
      ChatVoiceRecordingChange(
        isRecording: isRecording,
        durationMs: durationMs,
        willCancel: willCancel,
        locked: locked ?? _locked,
        kind: _kind,
      ),
    );
  }

  void _startHoldTimer() {
    _holdStartedAt = DateTime.now();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final startedAt = _holdStartedAt;
      if (startedAt == null || !mounted) return;
      var ms = DateTime.now().difference(startedAt).inMilliseconds;
      if (_circleMode) {
        // Сессия кружка — источник правды (сброс при смене камеры).
        ms = _circle.elapsedMs;
        if (ms >= ChatVideoCircleSession.maxMs && !_releasing) {
          unawaited(_finishLockedOrHold(send: true));
          return;
        }
      }
      _notifyRecording(
        isRecording: true,
        durationMs: ms,
        willCancel: _willCancel,
      );
      if (mounted) setState(() {});
    });
  }

  void _stopHoldTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
  }

  int _holdDurationMs() {
    if (_circleMode) return _circle.elapsedMs;
    final startedAt = _holdStartedAt;
    if (startedAt == null) return 0;
    return DateTime.now().difference(startedAt).inMilliseconds;
  }

  Future<void> _ensureRecordingStarted() async {
    if (_circleMode) {
      if (kIsWeb || widget.onVideoCircleComplete == null) {
        throw StateError('circle_unsupported');
      }
      await _circle.start();
      return;
    }
    final granted = await _recorder.ensurePermission();
    if (!granted) throw StateError('permission');
    await _recorder.start(forTranscription: widget.voiceTranscriptionEnabled);
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
    if (_locked) return;
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

  void _toggleMode() {
    if (_circleMode == false &&
        (kIsWeb || widget.onVideoCircleComplete == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Кружки пока только в приложении')),
      );
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _circleMode = !_circleMode);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_showSend || _activePointer != null || _releasing) return;
    if (_locked) return;

    _activePointer = event.pointer;
    _downGlobal = event.position;
    _slideDx = 0;
    _willCancel = false;
    _recordingStarted = false;
    _armTimer?.cancel();

    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _onGlobalPointer,
    );

    _armTimer = Timer(const Duration(milliseconds: _tapToggleMs), () {
      if (!mounted || _activePointer != event.pointer || _locked) return;
      _beginHoldRecording();
    });
  }

  void _beginHoldRecording() {
    if (_recordingStarted || _releasing) return;
    _recordingStarted = true;
    setState(() => _holdActive = true);
    _startHoldTimer();
    _notifyRecording(isRecording: true, durationMs: 0);
    HapticFeedback.mediumImpact();
    _startFuture = _ensureRecordingStarted();
    _startFuture!.catchError((_) {});
  }

  void _lockRecording() {
    if (_locked || !_recordingStarted) return;
    HapticFeedback.mediumImpact();
    _detachPointerRoute();
    _activePointer = null;
    _downGlobal = null;
    setState(() {
      _locked = true;
      _willCancel = false;
      _slideDx = 0;
      _holdActive = true;
    });
    _notifyRecording(
      isRecording: true,
      durationMs: _holdDurationMs(),
      locked: true,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || _downGlobal == null || _locked) {
      return;
    }
    if (!_recordingStarted) {
      final dist = (event.position - _downGlobal!).distance;
      if (dist > 12) {
        _armTimer?.cancel();
        _armTimer = null;
        _beginHoldRecording();
      }
    }
    if (!_recordingStarted) return;

    final delta = event.position - _downGlobal!;
    final dx = delta.dx.clamp(-120.0, 0.0);
    final willCancel = dx <= -_cancelPx;
    final dist = delta.distance;
    final lockCandidate = !willCancel && dist >= _lockPx;

    if (lockCandidate) {
      _lockRecording();
      return;
    }

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
    _armTimer?.cancel();
    _armTimer = null;

    if (_locked) {
      _detachPointerRoute();
      _activePointer = null;
      return;
    }

    if (!_recordingStarted) {
      _detachPointerRoute();
      _activePointer = null;
      _downGlobal = null;
      _toggleMode();
      return;
    }

    final cancel = _willCancel;
    await _releaseHold(send: !cancel);
  }

  Future<void> _onPointerCancel(PointerCancelEvent event) async {
    if (_activePointer != null && event.pointer != _activePointer) return;
    _armTimer?.cancel();
    _armTimer = null;
    if (_locked) {
      _detachPointerRoute();
      _activePointer = null;
      return;
    }
    if (!_recordingStarted) {
      _detachPointerRoute();
      _activePointer = null;
      return;
    }
    await _releaseHold(send: false);
  }

  Future<void> _finishLockedOrHold({required bool send}) async {
    if (_locked) {
      await _releaseHold(send: send);
      return;
    }
    await _releaseHold(send: send);
  }

  Future<void> _onLockedCancel() async {
    if (!_locked || _releasing) return;
    await _releaseHold(send: false);
  }

  Future<void> _onLockedSend() async {
    if (!_locked || _releasing) return;
    await _releaseHold(send: true);
  }

  Future<void> _releaseHold({required bool send}) async {
    if (_releasing) return;
    if (!_holdActive &&
        !_locked &&
        _activePointer == null &&
        _startFuture == null &&
        !_recordingStarted) {
      return;
    }
    _releasing = true;
    _detachPointerRoute();
    _armTimer?.cancel();
    _armTimer = null;

    final holdMs = _holdDurationMs();
    final startFuture = _startFuture;
    final wasCircle = _circleMode;
    _activePointer = null;
    _holdStartedAt = null;
    _downGlobal = null;
    _stopHoldTimer();

    if (mounted) {
      setState(() {
        _holdActive = false;
        _locked = false;
        _slideDx = 0;
        _willCancel = false;
        _recordingStarted = false;
      });
    } else {
      _holdActive = false;
      _locked = false;
      _slideDx = 0;
      _willCancel = false;
      _recordingStarted = false;
    }
    _notifyRecording(isRecording: false, durationMs: 0, locked: false);

    try {
      try {
        await startFuture;
      } catch (error) {
        if (!mounted) return;
        if (wasCircle) {
          await _circle.cancel();
        } else {
          await _recorder.cancel();
        }
        if (error is StateError && error.message == 'permission') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                wasCircle
                    ? 'Нужен доступ к камере и микрофону'
                    : 'Нужен доступ к микрофону',
              ),
            ),
          );
        } else if (error is StateError &&
            error.message == 'circle_unsupported') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Кружки пока только в приложении')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                wasCircle
                    ? 'Не удалось начать запись кружка'
                    : (kIsWeb
                        ? 'Не удалось начать запись. Разрешите микрофон в браузере'
                        : 'Не удалось начать запись'),
              ),
            ),
          );
        }
        return;
      } finally {
        _startFuture = null;
      }

      if (!send || holdMs < _minSendMs) {
        if (wasCircle) {
          await _circle.cancel();
        } else {
          await _recorder.cancel();
        }
        return;
      }

      if (wasCircle) {
        final result = await _circle.stop();
        if (result == null || result.bytes.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось записать кружок')),
          );
          return;
        }
        final durationMs =
            result.durationMs > 0 ? result.durationMs : holdMs;
        if (durationMs < _minSendMs) {
          await _circle.cancel();
          return;
        }
        final cb = widget.onVideoCircleComplete;
        if (cb != null) await cb(result);
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

    if (_showSend && !_holdActive && !_locked) {
      return ChatComposeCircleButton(
        tooltip: 'Отправить',
        icon: Icons.send_rounded,
        onTap: () => widget.onSend(ChatSendOptions.normal),
        onLongPress: () async {
          final options = await ChatSendOptionsSheet.show(
            context,
            showAiAssist: widget.showAiAssist,
          );
          if (options == null) return;
          widget.onSend(options);
        },
      );
    }

    if (_locked) {
      return ChatComposeCircleButton(
        tooltip: 'Отправить',
        icon: Icons.send_rounded,
        iconColor: cs.onPrimary,
        backgroundColor: cs.primary,
        onTap: () => unawaited(_onLockedSend()),
      );
    }

    final cancelLook = _holdActive && _willCancel;
    final icon = _circleMode ? Icons.photo_camera_rounded : Icons.mic_rounded;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (e) => unawaited(_onPointerUp(e)),
      onPointerCancel: (e) => unawaited(_onPointerCancel(e)),
      child: Transform.translate(
        offset: Offset(_slideDx, 0),
        child: AnimatedScale(
          scale: _holdActive && !_locked ? 3.0 : 1.0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          child: ChatComposeCircleButton(
            icon: icon,
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
