import 'package:familychat_app/core/notifications/chat_push_thread_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatPushThreadPreview', () {
    test('appends lines and trims to max messages', () {
      var lines = <ChatPushPreviewLine>[];
      for (var i = 1; i <= 10; i++) {
        lines = ChatPushThreadPreview.trimLines(
          [
            ...lines,
            ChatPushPreviewLine(
              messageId: i,
              sender: 'Alice',
              text: 'msg $i',
            ),
          ],
        );
      }
      expect(lines.length, ChatPushThreadPreview.maxMessages);
      expect(lines.first.messageId, 4);
      expect(lines.last.messageId, 10);
    });

    test('filters to unread incoming only', () {
      final lines = [
        for (var i = 1; i <= 7; i++)
          ChatPushPreviewLine(
            messageId: i,
            sender: 'Alice',
            text: 'msg $i',
          ),
      ];
      final unreadOnly = ChatPushThreadPreview.filterToUnreadLines(lines, 1);
      expect(unreadOnly.length, 1);
      expect(unreadOnly.single.messageId, 7);
      expect(unreadOnly.single.text, 'msg 7');
    });

    test('keeps recent outgoing lines from inline reply', () {
      final lines = [
        ChatPushPreviewLine(messageId: 1, sender: 'Alice', text: 'old read'),
        ChatPushPreviewLine(messageId: 2, sender: 'Alice', text: 'unread'),
        ChatPushPreviewLine(
          messageId: -100,
          sender: '',
          text: 'my reply',
        ),
      ];
      final filtered = ChatPushThreadPreview.filterToUnreadLines(lines, 1);
      expect(filtered.length, 2);
      expect(filtered.first.text, 'unread');
      expect(filtered.last.text, 'my reply');
    });

    test('parses sender prefix from group body', () {
      final line = ChatPushThreadPreview.lineFromPushData(
        data: const {
          'thread_id': '1',
          'message_id': '7',
          'thread_kind': 'family',
          'thread_title': 'Семья',
          'title': 'Семья',
          'body': 'Папа: Купи хлеб',
        },
      );
      expect(line?.sender, 'Папа');
      expect(line?.text, 'Купи хлеб');
    });
  });
}
