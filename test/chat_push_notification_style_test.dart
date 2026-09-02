import 'package:familychat_app/core/notifications/chat_push_notification_style.dart';
import 'package:familychat_app/core/notifications/chat_push_thread_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatPushNotificationStyle', () {
    test('collapsed body prefixes outgoing messages', () {
      final preview = ChatPushThreadPreview(
        title: 'Шурик',
        collapsedBody: '',
        expandedBody: '',
        isGroup: false,
        lines: const [
          ChatPushPreviewLine(
            messageId: -1,
            sender: '',
            text: 'привет',
          ),
        ],
      );
      expect(
        ChatPushNotificationStyle.collapsedBody(preview),
        'Вы: привет',
      );
    });

    test('expanded body groups by speaker like Telegram', () {
      final preview = ChatPushThreadPreview(
        title: 'Шурик',
        collapsedBody: '',
        expandedBody: '',
        isGroup: false,
        lines: const [
          ChatPushPreviewLine(
            messageId: 1,
            sender: '',
            text: '990',
          ),
          ChatPushPreviewLine(
            messageId: -2,
            sender: '',
            text: '770',
          ),
        ],
      );
      expect(
        ChatPushNotificationStyle.expandedBody(preview),
        'Шурик\n990\n\nВы\n770',
      );
    });

    test('android subText shows unread count', () {
      final preview = ChatPushThreadPreview(
        title: 'Семья',
        collapsedBody: '',
        expandedBody: '',
        isGroup: true,
        lines: const [
          ChatPushPreviewLine(messageId: 1, sender: 'Папа', text: 'a'),
          ChatPushPreviewLine(messageId: 2, sender: 'Мама', text: 'b'),
          ChatPushPreviewLine(messageId: 3, sender: 'Папа', text: 'c'),
        ],
      );
      expect(
        ChatPushNotificationStyle.androidSubText(preview),
        '3 новых сообщения',
      );
    });
  });
}
