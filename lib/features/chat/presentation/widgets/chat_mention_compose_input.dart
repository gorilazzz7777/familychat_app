import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/widgets/family_input_styles.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
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

/// Участник чата для автодополнения @упоминаний.
class ChatMentionParticipant {
  const ChatMentionParticipant({
    required this.userId,
    required this.displayName,
    this.avatarUrl = '',
  });

  final int userId;
  final String displayName;
  final String avatarUrl;
}

/// Поле ввода с автодополнением @имя для групповых чатов.
class ChatMentionComposeInput extends StatefulWidget {
  const ChatMentionComposeInput({
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
    required this.participants,
    this.currentUserId,
    this.hintText = 'Сообщение...',
    this.panelSlotMaxHeight,
    this.panelBarsOverhead = 0,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  final void Function(ChatSendOptions options, List<int> mentionedUserIds) onSend;
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
  final List<ChatMentionParticipant> participants;
  final int? currentUserId;
  final String hintText;
  final double? panelSlotMaxHeight;
  final double panelBarsOverhead;

  @override
  State<ChatMentionComposeInput> createState() => _ChatMentionComposeInputState();
}

class _ChatMentionComposeInputState extends State<ChatMentionComposeInput> {
  final Set<int> _mentionedUserIds = {};
  int? _mentionAtIndex;
  String _mentionQuery = '';
  final _recordingHost = ChatComposeRecordingHost();
  final _circleSession = ChatVideoCircleSession();
  final _composeSectionKey = GlobalKey();
  double _measuredComposeSectionHeight = chatComposeBarEstimate;
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
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant ChatMentionComposeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
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

  List<ChatMentionParticipant> get _suggestions {
    if (_mentionAtIndex == null) return const [];
    final query = _mentionQuery.trim().toLowerCase();
    return widget.participants
        .where((p) => p.userId != widget.currentUserId)
        .where((p) => query.isEmpty || p.displayName.toLowerCase().contains(query))
        .take(8)
        .toList();
  }

  void _onTextChanged() {
    _syncMentionedIds();
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) {
      _clearMentionQuery();
      return;
    }
    final beforeCursor = text.substring(0, cursor);
    final at = beforeCursor.lastIndexOf('@');
    if (at < 0) {
      _clearMentionQuery();
      return;
    }
    final prefix = at == 0 ? '' : beforeCursor[at - 1];
    if (prefix.isNotEmpty && !_isMentionBoundary(prefix)) {
      _clearMentionQuery();
      return;
    }
    final query = beforeCursor.substring(at + 1);
    if (query.contains('\n') || query.contains('@')) {
      _clearMentionQuery();
      return;
    }
    setState(() {
      _mentionAtIndex = at;
      _mentionQuery = query;
    });
  }

  bool _isMentionBoundary(String ch) {
    return ch == ' ' || ch == '\n' || ch == '\t';
  }

  void _clearMentionQuery() {
    if (_mentionAtIndex == null && _mentionQuery.isEmpty) return;
    setState(() {
      _mentionAtIndex = null;
      _mentionQuery = '';
    });
  }

  void _syncMentionedIds() {
    final text = widget.controller.text;
    _mentionedUserIds.removeWhere((id) {
      ChatMentionParticipant? participant;
      for (final p in widget.participants) {
        if (p.userId == id) {
          participant = p;
          break;
        }
      }
      if (participant == null) return true;
      return !text.contains('@${participant.displayName}');
    });
  }

  void _insertMention(ChatMentionParticipant participant) {
    final at = _mentionAtIndex;
    if (at == null) return;
    final text = widget.controller.text;
    final end = widget.controller.selection.baseOffset.clamp(at, text.length);
    final mention = '@${participant.displayName} ';
    final newText = text.replaceRange(at, end, mention);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: at + mention.length),
    );
    _mentionedUserIds.add(participant.userId);
    _clearMentionQuery();
  }

  void _handleSend(ChatSendOptions options) {
    _syncMentionedIds();
    widget.onSend(options, _mentionedUserIds.toList());
    _mentionedUserIds.clear();
    _clearMentionQuery();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions =
        _recording.isRecording ? const <ChatMentionParticipant>[] : _suggestions;
    final showPicker = _pickerOpen && !_recording.isRecording;

    final composeSection = KeyedSubtree(
      key: _composeSectionKey,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (suggestions.isNotEmpty)
            Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surface,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: suggestions.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.4),
                  ),
                  itemBuilder: (context, index) {
                    final p = suggestions[index];
                    return ListTile(
                      dense: true,
                      leading: ChatAvatar(
                        name: p.displayName,
                        avatarUrl:
                            p.avatarUrl.isEmpty ? null : p.avatarUrl,
                        radius: 16,
                      ),
                      title: Text(
                        p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _insertMention(p),
                    );
                  },
                ),
              ),
            ),
          if (suggestions.isNotEmpty) const SizedBox(height: 6),
          Material(
            type: MaterialType.transparency,
            clipBehavior: Clip.none,
            child: DecoratedBox(
              decoration: FamilyInputStyles.composeShellDecoration(theme),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!_recording.isRecording)
                    ChatComposeCircleButton(
                      tooltip: 'Вложение',
                      icon: Icons.attach_file,
                      iconColor: theme.colorScheme.onSurface,
                      onTap: widget.onAttach,
                    ),
                  Expanded(
                    child: _recording.isRecording
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
                  if (!_recording.isRecording)
                    ChatComposeEmojiButton(
                      open: _pickerOpen,
                      onPressed: _togglePicker,
                    ),
                  ChatComposeActionButton(
                    controller: widget.controller,
                    onSend: (options) => _handleSend(options),
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
        ],
      ),
    ),
    );

    final pickerPanel = ChatComposePickerPanel(
      tab: _pickerTab,
      onTabChanged: (tab) => setState(() => _pickerTab = tab),
      emojiController: widget.controller,
      onKlipySelected: (item) {
        _collapsePicker();
        widget.onGifSelected?.call(item);
      },
      onCollapse: _collapsePicker,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final measured = _composeSectionKey.currentContext?.size?.height;
          if (!mounted || measured == null) return;
          if ((measured - _measuredComposeSectionHeight).abs() > 0.5) {
            setState(() => _measuredComposeSectionHeight = measured);
          }
        });

        final pickerHeight = showPicker
            ? chatComposePickerHeight(
                context,
                constraints: constraints,
                panelSlotMaxHeight: widget.panelSlotMaxHeight,
                composeBarHeight: _measuredComposeSectionHeight,
                barsOverhead: widget.panelBarsOverhead,
              )
            : 0.0;

        debugComposePickerLayout(
          tag: 'ChatMentionComposeInput',
          context: context,
          constraints: constraints,
          pickerHeight: pickerHeight,
          showPicker: showPicker,
          composeBarHeight: _measuredComposeSectionHeight,
          panelSlotMaxHeight: widget.panelSlotMaxHeight,
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            composeSection,
            if (showPicker && pickerHeight > 0) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: pickerHeight,
                child: pickerPanel,
              ),
            ],
          ],
        );
      },
    );
  }
}
