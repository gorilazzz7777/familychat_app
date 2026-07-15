import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/widgets/family_input_styles.dart';
import '../../data/chat_send_options.dart';
import 'chat_compose_action_button.dart';
import 'chat_compose_circle_button.dart';
import 'chat_voice_recording_compose_slot.dart';

/// Поле ввода сообщения с кнопками вложения и отправки внутри блока.
class ChatComposeInput extends StatefulWidget {
  const ChatComposeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    required this.onVoiceComplete,
    this.forceSendButton = false,
    this.hintText = 'Сообщение...',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  final void Function(ChatSendOptions options) onSend;
  final Future<void> Function(
    Uint8List bytes,
    int durationMs, {
    String? encoderName,
  }) onVoiceComplete;
  final bool forceSendButton;
  final String hintText;

  @override
  State<ChatComposeInput> createState() => _ChatComposeInputState();
}

class _ChatComposeInputState extends State<ChatComposeInput> {
  ChatVoiceRecordingChange _recording = const ChatVoiceRecordingChange(
    isRecording: false,
    durationMs: 0,
  );

  void _onRecordingChanged(ChatVoiceRecordingChange change) {
    if (!mounted) return;
    setState(() => _recording = change);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _recording.isRecording;

    return DecoratedBox(
      decoration: FamilyInputStyles.composeShellDecoration(theme),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!recording)
            ChatComposeCircleButton(
              tooltip: 'Вложение',
              icon: Icons.attach_file,
              iconColor: theme.colorScheme.onSurface,
              onTap: widget.onAttach,
            ),
          Expanded(
            child: recording
                ? ChatVoiceRecordingComposeSlot(
                    durationMs: _recording.durationMs,
                    willCancel: _recording.willCancel,
                  )
                : TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    keyboardType: TextInputType.multiline,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
                      isDense: true,
                    ),
                  ),
          ),
          ChatComposeActionButton(
            controller: widget.controller,
            onSend: widget.onSend,
            onVoiceComplete: widget.onVoiceComplete,
            forceSendButton: widget.forceSendButton,
            onRecordingChanged: _onRecordingChanged,
          ),
        ],
      ),
    );
  }
}
