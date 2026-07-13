import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/widgets/family_input_styles.dart';
import 'chat_compose_action_button.dart';
import 'chat_compose_circle_button.dart';
import '../../data/chat_send_options.dart';

/// Поле ввода сообщения с кнопками вложения и отправки внутри блока.
class ChatComposeInput extends StatelessWidget {
  const ChatComposeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    required this.onVoiceComplete,
    this.forceSendButton = false,
    this.onRecordingChanged,
    this.hintText = 'Сообщение...',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  final void Function(ChatSendOptions options) onSend;
  final Future<void> Function(Uint8List bytes, int durationMs) onVoiceComplete;
  final bool forceSendButton;
  final void Function(bool isRecording, int durationMs)? onRecordingChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: FamilyInputStyles.composeShellDecoration(theme),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ChatComposeCircleButton(
            tooltip: 'Вложение',
            icon: Icons.attach_file,
            iconColor: theme.colorScheme.onSurface,
            onTap: onAttach,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.multiline,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: hintText,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
                isDense: true,
              ),
            ),
          ),
          ChatComposeActionButton(
            controller: controller,
            onSend: onSend,
            onVoiceComplete: onVoiceComplete,
            forceSendButton: forceSendButton,
            onRecordingChanged: onRecordingChanged,
          ),
        ],
      ),
    );
  }
}
