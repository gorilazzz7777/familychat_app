import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/widgets/family_input_styles.dart';
import '../../data/chat_gif_item.dart';
import '../../data/chat_send_options.dart';
import '../record_video_circle_screen.dart';
import 'chat_circle_recording_overlay.dart';
import 'chat_compose_action_button.dart';
import 'chat_compose_circle_button.dart';
import 'chat_compose_picker_panel.dart';
import 'chat_emoji_picker_sheet.dart';
import 'chat_video_circle_session.dart';
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
    this.onVideoCircleComplete,
    this.onGifSelected,
    this.forceSendButton = false,
    this.voiceTranscriptionEnabled = false,
    this.showAiAssist = false,
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
  final Future<void> Function(VideoCircleRecording recording)?
      onVideoCircleComplete;
  final void Function(ChatGifItem item)? onGifSelected;
  final bool forceSendButton;
  final bool voiceTranscriptionEnabled;
  final bool showAiAssist;
  final String hintText;

  @override
  State<ChatComposeInput> createState() => _ChatComposeInputState();
}

class _ChatComposeInputState extends State<ChatComposeInput> {
  final _recordingHost = ChatComposeRecordingHost();
  final _circleSession = ChatVideoCircleSession();
  ChatVoiceRecordingChange _recording = const ChatVoiceRecordingChange(
    isRecording: false,
    durationMs: 0,
  );
  bool _pickerOpen = false;
  ChatComposePickerTab _pickerTab = ChatComposePickerTab.emoji;
  OverlayEntry? _circleOverlay;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant ChatComposeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    _removeCircleOverlay();
    _circleSession.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus && _pickerOpen) {
      setState(() => _pickerOpen = false);
    }
  }

  void _onRecordingChanged(ChatVoiceRecordingChange change) {
    if (!mounted) return;
    setState(() {
      _recording = change;
      if (change.isRecording) _pickerOpen = false;
    });
    _syncCircleOverlay();
  }

  void _removeCircleOverlay() {
    _circleOverlay?.remove();
    _circleOverlay = null;
  }

  void _syncCircleOverlay() {
    final need = _recording.isRecording &&
        _recording.kind == ChatComposeRecordKind.circle;
    if (!need) {
      _removeCircleOverlay();
      return;
    }
    if (_circleOverlay == null) {
      _circleOverlay = OverlayEntry(
        builder: (ctx) {
          // Пока палец удерживает запись — жесты проходят к кнопке под оверлеем.
          return IgnorePointer(
            ignoring: !_recording.locked,
            child: ChatCircleRecordingOverlay(
              session: _circleSession,
              durationMs: _recording.durationMs,
              locked: _recording.locked,
              onCancel: () => _recordingHost.cancelLocked?.call(),
              onSend: () => _recordingHost.sendLocked?.call(),
            ),
          );
        },
      );
      Overlay.of(context, rootOverlay: true).insert(_circleOverlay!);
    } else {
      _circleOverlay!.markNeedsBuild();
    }
  }

  void _togglePicker() {
    if (_pickerOpen) {
      setState(() => _pickerOpen = false);
      widget.focusNode.requestFocus();
      return;
    }
    widget.focusNode.unfocus();
    setState(() {
      _pickerOpen = true;
      _pickerTab = ChatComposePickerTab.emoji;
    });
  }

  void _collapsePicker() {
    setState(() => _pickerOpen = false);
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _recording.isRecording;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, _pickerOpen ? 0 : 8),
          child: Material(
            type: MaterialType.transparency,
            clipBehavior: Clip.none,
            child: DecoratedBox(
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
                            locked: _recording.locked,
                            kind: _recording.kind,
                            onCancel: () =>
                                _recordingHost.cancelLocked?.call(),
                          )
                        : TextField(
                            controller: widget.controller,
                            focusNode: widget.focusNode,
                            keyboardType: TextInputType.multiline,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.newline,
                            readOnly: _pickerOpen,
                            showCursor: true,
                            onTap: () {
                              if (_pickerOpen) {
                                setState(() => _pickerOpen = false);
                              }
                            },
                            decoration: InputDecoration(
                              hintText: widget.hintText,
                              filled: true,
                              fillColor: Colors.white,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.fromLTRB(0, 10, 0, 10),
                              isDense: true,
                            ),
                          ),
                  ),
                  if (!recording)
                    ChatComposeEmojiButton(
                      open: _pickerOpen,
                      onPressed: _togglePicker,
                    ),
                  ChatComposeActionButton(
                    controller: widget.controller,
                    onSend: widget.onSend,
                    onVoiceComplete: widget.onVoiceComplete,
                    onVideoCircleComplete: widget.onVideoCircleComplete,
                    forceSendButton: widget.forceSendButton,
                    voiceTranscriptionEnabled:
                        widget.voiceTranscriptionEnabled,
                    showAiAssist: widget.showAiAssist,
                    onRecordingChanged: _onRecordingChanged,
                    circleSession: _circleSession,
                    recordingHost: _recordingHost,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_pickerOpen && !recording)
          ChatComposePickerPanel(
            tab: _pickerTab,
            onTabChanged: (tab) => setState(() => _pickerTab = tab),
            emojiController: widget.controller,
            onGifSelected: (item) {
              _collapsePicker();
              widget.onGifSelected?.call(item);
            },
            onCollapse: _collapsePicker,
          ),
      ],
    );
  }
}
