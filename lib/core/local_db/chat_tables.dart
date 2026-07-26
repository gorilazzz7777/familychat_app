import 'package:drift/drift.dart';

/// Full thread JSON (API shape) plus sort/unread indexes.
class ChatThreadRows extends Table {
  IntColumn get id => integer()();
  TextColumn get payloadJson => text()();
  IntColumn get lastActivityMs => integer().withDefault(const Constant(0))();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  IntColumn get lastMessageId => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Full message JSON. messageId > 0 server; <=0 pending/outbox.
class ChatMessageRows extends Table {
  IntColumn get threadId => integer()();
  IntColumn get messageId => integer()();
  TextColumn get payloadJson => text()();
  IntColumn get createdAtMs => integer().withDefault(const Constant(0))();
  BoolColumn get isPending => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {threadId, messageId};
}

class ChatMemberRows extends Table {
  IntColumn get userId => integer()();
  TextColumn get payloadJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {userId};
}

class ChatMetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}