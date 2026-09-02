import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'chat_push_thread_preview.dart';

/// Telegram-like presentation for chat push notifications.
abstract final class ChatPushNotificationStyle {
  static const selfPerson = Person(name: 'Вы', key: 'familychat_self');

  /// Accent for message-category notifications (read receipts blue family).
  static const notificationColor = Color(0xFF4A9ED8);

  static MessagingStyleInformation? androidMessagingStyle(
    ChatPushThreadPreview preview,
  ) {
    if (preview.lines.isEmpty) return null;

    final contactName = preview.title.trim().isNotEmpty
        ? preview.title.trim()
        : 'Family Space';

    final messages = preview.lines.map((line) {
      final text = line.displayText;
      final when = DateTime.fromMillisecondsSinceEpoch(
        line.timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      );

      if (line.isOutgoing) {
        return Message(text, when, null);
      }

      if (preview.isGroup) {
        final sender =
            line.sender.trim().isNotEmpty ? line.sender.trim() : 'Участник';
        return Message(
          text,
          when,
          Person(name: sender, key: 'member:$sender'),
        );
      }

      return Message(
        text,
        when,
        Person(name: contactName, key: 'peer:$contactName'),
      );
    }).toList(growable: false);

    return MessagingStyleInformation(
      selfPerson,
      conversationTitle: preview.isGroup ? preview.title : null,
      groupConversation: preview.isGroup,
      messages: messages,
    );
  }

  /// Short line under the title (Android subText).
  static String? androidSubText(ChatPushThreadPreview preview) {
    final incoming =
        preview.lines.where((line) => !line.isOutgoing).length;
    if (incoming <= 1) return null;
    return _ruCount(incoming, 'новое сообщение', 'новых сообщения', 'новых сообщений');
  }

  static String collapsedBody(ChatPushThreadPreview preview) {
    if (preview.lines.isEmpty) return 'Новое сообщение';
    final last = preview.lines.last;
    return last.collapsedLine(
      isGroup: preview.isGroup,
      contactTitle: preview.title,
    );
  }

  /// iOS / fallback when MessagingStyle is unavailable.
  static String expandedBody(ChatPushThreadPreview preview) {
    if (preview.lines.isEmpty) return 'Новое сообщение';
    if (preview.lines.length == 1) {
      return collapsedBody(preview);
    }

    final blocks = <String>[];
    String? lastSpeaker;
    for (final line in preview.lines) {
      final speaker = line.speakerLabel(
        isGroup: preview.isGroup,
        contactTitle: preview.title,
      );
      if (speaker != lastSpeaker) {
        if (blocks.isNotEmpty) blocks.add('');
        blocks.add(speaker);
        lastSpeaker = speaker;
      }
      blocks.add(line.displayText);
    }
    return blocks.join('\n');
  }

  static String _ruCount(int n, String one, String few, String many) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 14) return '$n $many';
    if (mod10 == 1) return '$n $one';
    if (mod10 >= 2 && mod10 <= 4) return '$n $few';
    return '$n $many';
  }
}

extension ChatPushPreviewLineStyle on ChatPushPreviewLine {
  bool get isOutgoing => (messageId ?? 0) < 0;

  String get displayText => text.trim().isEmpty ? 'Сообщение' : text.trim();

  String speakerLabel({
    required bool isGroup,
    required String contactTitle,
  }) {
    if (isOutgoing) return 'Вы';
    if (isGroup && sender.trim().isNotEmpty) return sender.trim();
    final title = contactTitle.trim();
    return title.isNotEmpty ? title : 'Family Space';
  }

  String collapsedLine({
    required bool isGroup,
    required String contactTitle,
  }) {
    final body = displayText;
    if (isOutgoing) return 'Вы: $body';
    if (isGroup && sender.trim().isNotEmpty) {
      return '${sender.trim()}: $body';
    }
    return body;
  }
}
