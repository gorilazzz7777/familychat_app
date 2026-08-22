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

  test('ChatConversationSession accepts chat_message with thread_id only on event', () {
    final session = ChatConversationSession(threadId: 1);
    final next = session.applyEvent({
      'event': 'chat_message',
      'thread_id': 1,
      'message': {
        'id': 11,
        'body': 'hi',
      },
    });
    expect(next, isNotNull);
    expect(chatAsInt(next!.first['thread_id']), 1);
    expect(chatAsInt(next.first['id']), 11);
  });

  test('chatNewestServerMessageId skips pending and scheduled tail', () {
    expect(
      chatNewestServerMessageId([
        {'id': 10, 'body': 'ok'},
        {'id': -1, '_pending': true, 'body': 'draft'},
        {'id': -2, '_scheduled': true, '_pending': true, 'body': 'later'},
      ]),
      10,
    );
  });

  test('chatReconcilePendingDuplicates drops stuck sending clone', () {
    final pending = {
      'id': -3,
      '_pending': true,
      'body': '😀😉🤔',
      'created_at': '2026-08-05T06:40:00.000Z',
      'sender_user_id': 7,
      'read_status': 'sending',
      'attachments': const [],
    };
    final sent = {
      'id': 101,
      'body': '😀😉🤔',
      'created_at': '2026-08-05T06:40:01.000Z',
      'sender_user_id': 7,
      'read_status': 'read',
      'attachments': const [],
    };
    final later = {
      'id': 105,
      'body': 'later',
      'created_at': '2026-08-05T07:11:00.000Z',
      'sender_user_id': 7,
      'read_status': 'read',
      'attachments': const [],
    };

    final reconciled = chatReconcilePendingDuplicates(
      [pending, sent, later],
      currentUserId: 7,
    );
    expect(reconciled.length, 2);
    expect(reconciled.every((m) => chatAsInt(m['id'])! > 0), isTrue);
    expect(
      reconciled.map((m) => chatAsInt(m['id'])).toSet(),
      {101, 105},
    );
  });

  test('chatMergeMessageLists keeps unrelated pending', () {
    final pending = {
      'id': -1,
      '_pending': true,
      'body': 'still sending',
      'created_at': '2026-08-05T08:00:00.000Z',
      'sender_user_id': 7,
      'read_status': 'queued',
      'attachments': const [],
    };
    final sent = {
      'id': 50,
      'body': 'other',
      'created_at': '2026-08-05T07:00:00.000Z',
      'sender_user_id': 7,
      'read_status': 'sent',
      'attachments': const [],
    };

    final merged = chatMergeMessageLists(
      [pending],
      [sent],
      currentUserId: 7,
    );
    expect(merged.length, 2);
    expect(merged.any(chatMessageIsPending), isTrue);
  });

  test('chatPendingMatchesServer requires same reply target', () {
    final pending = {
      'id': -2,
      '_pending': true,
      'body': 'same',
      'sender_user_id': 1,
      'reply_to': {'message_id': 9},
      'attachments': const [],
    };
    final server = {
      'id': 20,
      'body': 'same',
      'sender_user_id': 1,
      'reply_to': {'message_id': 8},
      'attachments': const [],
    };
    expect(chatPendingMatchesServer(pending, server), isFalse);
  });

  test('chatReconcile keeps share pending vs older same-shape media', () {
    final older = {
      'id': 88,
      'body': '',
      'created_at': '2026-08-05T06:00:00.000Z',
      'sender_user_id': 7,
      'read_status': 'read',
      'attachments': [
        {'kind': 'image', 'filename': 'old.jpg'},
      ],
    };
    final pending = {
      'id': -9,
      '_pending': true,
      'body': '',
      'created_at': '2026-08-05T08:00:00.000Z',
      'sender_user_id': 7,
      'read_status': 'sending',
      'attachments': [
        {'kind': 'image', 'filename': 'new_share.jpg', '_pending': true},
      ],
    };

    final reconciled = chatReconcilePendingDuplicates(
      [older, pending],
      currentUserId: 7,
    );
    expect(reconciled.length, 2);
    expect(reconciled.any(chatMessageIsPending), isTrue);
    expect(
      reconciled.map((m) => chatAsInt(m['id'])).toSet(),
      {-9, 88},
    );
  });

  test('chatReconcile keeps uploading share vs recent nameless server media', () {
    // Reproduces production flash: older share within seconds, local cache
    // without filenames — must not swallow the new optimistic bubble.
    final older = {
      'id': 91,
      'body': '',
      'created_at': '2026-08-05T08:00:20.000Z',
      'sender_user_id': 7,
      'read_status': 'read',
      'attachments': [
        {'kind': 'image'},
      ],
    };
    final pending = {
      'id': -11,
      '_pending': true,
      'body': '',
      'created_at': '2026-08-05T08:00:40.000Z',
      'sender_user_id': 7,
      'read_status': 'sending',
      'attachments': [
        {'kind': 'image', 'filename': 'IMG_1234.jpg', '_pending': true},
      ],
    };

    final reconciled = chatReconcilePendingDuplicates(
      [older, pending],
      currentUserId: 7,
    );
    expect(reconciled.any(chatMessageIsPending), isTrue);
    expect(
      reconciled.map((m) => chatAsInt(m['id'])).toSet(),
      {-11, 91},
    );
  });

  test('chatReconcile drops uploading share once its server echo arrives', () {
    final pending = {
      'id': -13,
      '_pending': true,
      'body': '',
      'created_at': '2026-08-05T08:00:40.000Z',
      'sender_user_id': 7,
      'read_status': 'sending',
      'attachments': [
        {'kind': 'image', 'filename': 'IMG_1234.jpg', '_pending': true},
      ],
    };
    final delivered = {
      'id': 93,
      'body': '',
      'created_at': '2026-08-05T08:00:41.000Z',
      'sender_user_id': 7,
      'read_status': 'sent',
      'attachments': [
        {'kind': 'image', 'filename': 'compressed.jpg'},
      ],
    };

    final reconciled = chatReconcilePendingDuplicates(
      [pending, delivered],
      currentUserId: 7,
    );
    expect(reconciled.any(chatMessageIsPending), isFalse);
    expect(reconciled.map((m) => chatAsInt(m['id'])).toSet(), {93});
  });

  test('chatPendingToReinject skips share temp removed from sqlite', () {
    final memory = [
      {
        'id': -14,
        '_pending': true,
        'body': '',
        'read_status': 'sending',
        'attachments': [
          {'kind': 'image', 'filename': 'a.jpg', '_pending': true},
        ],
      },
      {
        'id': 94,
        'body': '',
        'attachments': [
          {'kind': 'image', 'filename': 'a.jpg'},
        ],
      },
    ];
    final sqlite = [
      {
        'id': 94,
        'body': '',
        'attachments': [
          {'kind': 'image', 'filename': 'a.jpg'},
        ],
      },
    ];
    final reinject = chatPendingToReinject(
      memoryMessages: memory,
      sqliteRows: sqlite,
    );
    expect(reinject, isEmpty);
  });

  test('chatPendingToReinject keeps share temp still in sqlite', () {
    final pending = {
      'id': -15,
      '_pending': true,
      'body': '',
      'read_status': 'sending',
      'attachments': [
        {'kind': 'image', 'filename': 'b.jpg', '_pending': true},
      ],
    };
    final reinject = chatPendingToReinject(
      memoryMessages: [pending],
      sqliteRows: [pending],
    );
    expect(reinject.length, 1);
    expect(chatAsInt(reinject.first['id']), -15);
  });

  test('chatReconcile does not drop text pending against older same body', () {
    final older = {
      'id': 100,
      'body': 'привет',
      'created_at': '2026-08-05T08:00:00.000Z',
      'sender_user_id': 7,
      'attachments': const [],
    };
    final pending = {
      'id': -16,
      '_pending': true,
      'body': 'привет',
      'created_at': '2026-08-05T08:00:30.000Z',
      'sender_user_id': 7,
      'read_status': 'sending',
      'attachments': const [],
    };
    final reconciled = chatReconcilePendingDuplicates(
      [older, pending],
      currentUserId: 7,
    );
    expect(reconciled.any(chatMessageIsPending), isTrue);
  });

  test('chatPendingMatchesServer rejects server older than pending', () {
    final pending = {
      'id': -12,
      '_pending': true,
      'body': 'hi',
      'created_at': '2026-08-05T08:00:40.000Z',
      'sender_user_id': 7,
      'attachments': const [],
    };
    final older = {
      'id': 92,
      'body': 'hi',
      'created_at': '2026-08-05T08:00:10.000Z',
      'sender_user_id': 7,
      'attachments': const [],
    };
    expect(
      chatPendingMatchesServer(pending, older, currentUserId: 7),
      isFalse,
    );
  });

  test('chatPendingMatchesServer rejects different attachment filenames', () {
    final pending = {
      'id': -4,
      '_pending': true,
      'body': '',
      'created_at': '2026-08-05T08:00:00.000Z',
      'sender_user_id': 7,
      'attachments': [
        {'kind': 'image', 'filename': 'a.jpg'},
      ],
    };
    final server = {
      'id': 44,
      'body': '',
      'created_at': '2026-08-05T08:00:01.000Z',
      'sender_user_id': 7,
      'attachments': [
        {'kind': 'image', 'filename': 'b.jpg'},
      ],
    };
    expect(
      chatPendingMatchesServer(pending, server, currentUserId: 7),
      isFalse,
    );
  });
}
