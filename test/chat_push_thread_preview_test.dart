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
