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

  test('hub slim preview without attachments becomes Медиа', () {
    expect(
      chatMessagePreviewText({
        'id': 5,
        'body': '',
        'has_attachments': true,
        'attachment_count': 1,
      }),
      'Медиа',
    );
  });

  test('stub image url without kind becomes Фото', () {
    expect(
      chatMessagePreviewText({
        'body': '',
        'attachments': [
          {'server_url': 'https://cdn.example.com/photo.jpg'},
        ],
      }),
      'Фото',
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

  test('hub keeps queued pending tip over server', () {
    expect(
      chatShouldKeepLocalHubLast(
        localLast: {
          'id': -100,
          'body': 'ок',
          '_pending': true,
          'created_at': '2026-09-10T01:50:00.000Z',
        },
        serverLastId: 2178,
        localMessageExists: true,
        pendingRemoval: false,
        pendingStillQueued: true,
      ),
      isTrue,
    );
  });

  test('hub drops ghost pending tip not in outbox', () {
    expect(
      chatShouldKeepLocalHubLast(
        localLast: {
          'id': -100,
          'body': 'ок',
          '_pending': true,
          'created_at': '2026-09-10T01:50:00.000Z',
        },
        serverLastId: 2178,
        localMessageExists: true,
        pendingRemoval: false,
        pendingStillQueued: false,
      ),
      isFalse,
    );
  });

  test('hub drops missing local tip even if id is newer', () {
    expect(
      chatShouldKeepLocalHubLast(
        localLast: {
          'id': 9999,
          'body': 'ок',
          'created_at': '2026-09-10T01:50:00.000Z',
        },
        serverLastId: 2178,
        localMessageExists: false,
        pendingRemoval: false,
        pendingStillQueued: false,
        now: DateTime.parse('2026-09-10T01:51:00.000Z'),
      ),
      isFalse,
    );
  });

  test('hub drops stale confirmed local tip ahead of server', () {
    expect(
      chatShouldKeepLocalHubLast(
        localLast: {
          'id': 9999,
          'body': 'ок',
          'created_at': '2026-09-10T01:50:00.000Z',
        },
        serverLastId: 2178,
        localMessageExists: true,
        pendingRemoval: false,
        pendingStillQueued: false,
        now: DateTime.parse('2026-09-10T12:00:00.000Z'),
      ),
      isFalse,
    );
  });

  test('hub keeps fresh realtime tip ahead of server', () {
    expect(
      chatShouldKeepLocalHubLast(
        localLast: {
          'id': 9999,
          'body': 'привет',
          'created_at': '2026-09-10T11:58:00.000Z',
        },
        serverLastId: 2178,
        localMessageExists: true,
        pendingRemoval: false,
        pendingStillQueued: false,
        now: DateTime.parse('2026-09-10T12:00:00.000Z'),
      ),
      isTrue,
    );
  });
}
