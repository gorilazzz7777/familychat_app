import 'package:flutter_test/flutter_test.dart';

import 'package:familychat_app/features/chat/data/chat_message_preview.dart';

void main() {
  test('photo without caption becomes Фото', () {
    expect(
      chatMessagePreviewText({
        'id': 1,
        'body': '',
        'attachments': [
          {'kind': 'image', 'filename': 'a.jpg'},
        ],
      }),
      'Фото',
    );
  });

  test('video without caption becomes Видео', () {
    expect(
      chatMessagePreviewText({
        'body': '',
        'attachments': [
          {'kind': 'video', 'filename': 'a.mp4'},
        ],
      }),
      'Видео',
    );
  });

  test('voice metadata becomes Голосовое сообщение', () {
    expect(
      chatMessagePreviewText({
        'body': '',
        'metadata': {
          'voice': {'duration_ms': 1200},
        },
        'attachments': const [],
      }),
      'Голосовое сообщение',
    );
  });

  test('text body wins over attachments', () {
    expect(
      chatMessagePreviewText({
        'body': 'привет',
        'attachments': [
          {'kind': 'image'},
        ],
      }),
      'привет',
    );
  });

  test('prefer richer last_message keeps local attachments', () {
    final richer = chatPreferRicherLastMessage(
      {'id': 10, 'body': '', 'attachments': const []},
      {
        'id': 10,
        'body': '',
        'attachments': [
          {'kind': 'image', 'filename': 'shot.jpg'},
        ],
      },
    );
    expect(chatMessagePreviewText(richer), 'Фото');
  });
}
