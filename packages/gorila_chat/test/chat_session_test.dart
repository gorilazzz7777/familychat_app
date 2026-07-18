import 'package:flutter_test/flutter_test.dart';
import 'package:gorila_chat/gorila_chat.dart';

void main() {
  test('chatMessageBelongsToThread normalizes string thread ids', () {
    expect(
      chatMessageBelongsToThread({'thread_id': '42'}, 42),
      isTrue,
    );
    expect(
      chatMessageBelongsToThread({'thread_id': 7}, 42),
      isFalse,
    );
  });

  test('ChatConversationSession upserts and requests reload', () {
    final session = ChatConversationSession(threadId: 1);
    final next = session.applyEvent({
      'event': 'chat_message',
      'message': {
        'id': 10,
        'thread_id': 1,
        'body': 'hi',
      },
    });
    expect(next, isNotNull);
    expect(next!.length, 1);

    session.applyEvent({'event': 'chat_refresh'});
    expect(session.wantsReload, isTrue);
  });
}
