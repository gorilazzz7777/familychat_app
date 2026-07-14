import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/chat_send_options.dart';
import '../../data/chat_voice_recorder.dart';
import 'chat_compose_circle_button.dart';
import 'chat_send_options_sheet.dart';

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
  final void Function(bool isRecording, int durationMs)? onRecordingChanged;

  @override
  State<ChatComposeActionButton> createState() => _ChatComposeActionButtonState();
}

class _ChatComposeActionButtonState extends State<ChatComposeActionButton> {
  final _recorder = ChatVoiceRecorder();
  bool _hasText = false;
  bool _holdActive = false;
  int? _activePointer;
  Timer? _recordingTimer;
  DateTime? _holdStartedAt;
  Future<void>? _startFuture;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    // На web разрешение микрофона нужно запрашивать по жесту (удержание).
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_recorder.ensurePermission());
      });
    }
  }

  @override
  void dispose() {
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

  void _notifyRecording(bool recording, int durationMs) {
    widget.onRecordingChanged?.call(recording, durationMs);
  }

  void _startHoldTimer() {
    _holdStartedAt = DateTime.now();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final startedAt = _holdStartedAt;
      if (startedAt == null || !mounted) return;
      _notifyRecording(true, DateTime.now().difference(startedAt).inMilliseconds);
    });
  }

  void _stopHoldTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
  }

  int? _holdDurationMs() {
    final startedAt = _holdStartedAt;
    if (startedAt == null) return null;
    return DateTime.now().difference(startedAt).inMilliseconds;
  }

  Future<void> _ensureRecordingStarted() async {
    final granted = await _recorder.ensurePermission();
    if (!granted) {
      throw StateError('permission');
    }
    await _recorder.start();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_showSend || _activePointer != null) return;
    _activePointer = event.pointer;
    setState(() => _holdActive = true);
    _startHoldTimer();
    _notifyRecording(true, 0);
    _startFuture = _ensureRecordingStarted();
    _startFuture!.catchError((_) {});
  }

  Future<void> _onPointerUp(PointerUpEvent event) async {
    if (_activePointer != event.pointer) return;
    await _releaseHold(send: true);
  }

  Future<void> _onPointerCancel(PointerCancelEvent event) async {
    if (_activePointer != event.pointer) return;
    await _releaseHold(send: false);
  }

  Future<void> _releaseHold({required bool send}) async {
    final holdMs = _holdDurationMs() ?? 0;
    _activePointer = null;
    _holdStartedAt = null;
    _stopHoldTimer();

    if (_holdActive) {
      setState(() => _holdActive = false);
    }
    _notifyRecording(false, 0);

    try {
      await _startFuture;
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

    if (!send) {
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
    if (durationMs < 400) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Удерживайте кнопку чуть дольше для записи')),
      );
      return;
    }

    await widget.onVoiceComplete(
      result.bytes,
      durationMs,
      encoderName: result.encoder.name,
    );
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

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: ChatComposeCircleButton(
        tooltip: 'Удерживайте для голосового',
        icon: _holdActive ? Icons.mic_rounded : Icons.mic_none_rounded,
        iconColor: _holdActive ? cs.error : cs.primary,
        backgroundColor: _holdActive
            ? cs.errorContainer.withValues(alpha: 0.72)
            : null,
      ),
    );
  }
}
