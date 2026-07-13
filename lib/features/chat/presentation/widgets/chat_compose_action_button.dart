import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/chat_send_options.dart';
import '../../data/chat_voice_recorder.dart';
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
  final Future<void> Function(Uint8List bytes, int durationMs) onVoiceComplete;
  final bool forceSendButton;
  final void Function(bool isRecording, int durationMs)? onRecordingChanged;

  @override
  State<ChatComposeActionButton> createState() => _ChatComposeActionButtonState();
}

class _ChatComposeActionButtonState extends State<ChatComposeActionButton> {
  final _recorder = ChatVoiceRecorder();
  bool _hasText = false;
  bool _recording = false;
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
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

  Future<void> _startRecording() async {
    if (_showSend || _recording) return;
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Голосовые сообщения пока недоступны в веб-версии')),
      );
      return;
    }
    final granted = await _recorder.ensurePermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нужен доступ к микрофону')),
      );
      return;
    }
    try {
      await _recorder.start();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось начать запись')),
      );
      return;
    }
    if (!mounted) return;
    _recordingStartedAt = DateTime.now();
    setState(() {
      _recording = true;
    });
    _notifyRecording(true, 0);
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final startedAt = _recordingStartedAt;
      if (startedAt == null || !mounted) return;
      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      _notifyRecording(true, ms);
    });
  }

  Future<void> _finishRecording({required bool send}) async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStartedAt = null;
    if (!_recording) return;

    setState(() => _recording = false);
    _notifyRecording(false, 0);

    if (!send) {
      await _recorder.cancel();
      return;
    }

    final result = await _recorder.stop();
    if (result == null) return;
    await widget.onVoiceComplete(result.bytes, result.durationMs);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    if (_showSend) {
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => widget.onSend(ChatSendOptions.normal),
          onLongPress: () async {
            final options = await ChatSendOptionsSheet.show(context);
            if (options == null) return;
            widget.onSend(options);
          },
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.send_rounded, color: color),
          ),
        ),
      );
    }

    return Listener(
      onPointerDown: (_) => unawaited(_startRecording()),
      onPointerUp: (_) => unawaited(_finishRecording(send: true)),
      onPointerCancel: (_) => unawaited(_finishRecording(send: false)),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            _recording ? Icons.mic_rounded : Icons.mic_none_rounded,
            color: _recording ? theme.colorScheme.error : color,
          ),
        ),
      ),
    );
  }
}
