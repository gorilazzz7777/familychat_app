import 'package:flutter/material.dart';

import 'chat_compose_send_button.dart';
import '../../data/chat_send_options.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';

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
    required this.participants,
    this.currentUserId,
    this.hintText = 'Сообщение...',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  final void Function(ChatSendOptions options, List<int> mentionedUserIds) onSend;
  final List<ChatMentionParticipant> participants;
  final int? currentUserId;
  final String hintText;

  @override
  State<ChatMentionComposeInput> createState() => _ChatMentionComposeInputState();
}

class _ChatMentionComposeInputState extends State<ChatMentionComposeInput> {
  final Set<int> _mentionedUserIds = {};
  int? _mentionAtIndex;
  String _mentionQuery = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
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
    final fill = theme.colorScheme.surfaceContainerHighest;
    final border = theme.colorScheme.outlineVariant.withValues(alpha: 0.55);
    final suggestions = _suggestions;

    return Column(
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
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
                itemBuilder: (context, index) {
                  final p = suggestions[index];
                  return ListTile(
                    dense: true,
                    leading: ChatAvatar(
                      name: p.displayName,
                      avatarUrl: p.avatarUrl.isEmpty ? null : p.avatarUrl,
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
          color: fill,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Вложение',
                onPressed: widget.onAttach,
                icon: Icon(
                  Icons.attach_file,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _handleSend(ChatSendOptions.normal),
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
              ChatComposeSendButton(
                onSend: (options) => _handleSend(options),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
