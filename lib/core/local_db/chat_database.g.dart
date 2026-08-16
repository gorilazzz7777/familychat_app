// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_database.dart';

// ignore_for_file: type=lint
class $ChatThreadRowsTable extends ChatThreadRows
    with TableInfo<$ChatThreadRowsTable, ChatThreadRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatThreadRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _lastActivityMsMeta =
      const VerificationMeta('lastActivityMs');
  @override
  late final GeneratedColumn<int> lastActivityMs = GeneratedColumn<int>(
      'last_activity_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _unreadCountMeta =
      const VerificationMeta('unreadCount');
  @override
  late final GeneratedColumn<int> unreadCount = GeneratedColumn<int>(
      'unread_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastMessageIdMeta =
      const VerificationMeta('lastMessageId');
  @override
  late final GeneratedColumn<int> lastMessageId = GeneratedColumn<int>(
      'last_message_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, payloadJson, lastActivityMs, unreadCount, lastMessageId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_thread_rows';
  @override
  VerificationContext validateIntegrity(Insertable<ChatThreadRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('last_activity_ms')) {
      context.handle(
          _lastActivityMsMeta,
          lastActivityMs.isAcceptableOrUnknown(
              data['last_activity_ms']!, _lastActivityMsMeta));
    }
    if (data.containsKey('unread_count')) {
      context.handle(
          _unreadCountMeta,
          unreadCount.isAcceptableOrUnknown(
              data['unread_count']!, _unreadCountMeta));
    }
    if (data.containsKey('last_message_id')) {
      context.handle(
          _lastMessageIdMeta,
          lastMessageId.isAcceptableOrUnknown(
              data['last_message_id']!, _lastMessageIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChatThreadRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatThreadRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
      lastActivityMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_activity_ms'])!,
      unreadCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}unread_count'])!,
      lastMessageId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_message_id']),
    );
  }

  @override
  $ChatThreadRowsTable createAlias(String alias) {
    return $ChatThreadRowsTable(attachedDatabase, alias);
  }
}

class ChatThreadRow extends DataClass implements Insertable<ChatThreadRow> {
  final int id;
  final String payloadJson;
  final int lastActivityMs;
  final int unreadCount;
  final int? lastMessageId;
  const ChatThreadRow(
      {required this.id,
      required this.payloadJson,
      required this.lastActivityMs,
      required this.unreadCount,
      this.lastMessageId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['payload_json'] = Variable<String>(payloadJson);
    map['last_activity_ms'] = Variable<int>(lastActivityMs);
    map['unread_count'] = Variable<int>(unreadCount);
    if (!nullToAbsent || lastMessageId != null) {
      map['last_message_id'] = Variable<int>(lastMessageId);
    }
    return map;
  }

  ChatThreadRowsCompanion toCompanion(bool nullToAbsent) {
    return ChatThreadRowsCompanion(
      id: Value(id),
      payloadJson: Value(payloadJson),
      lastActivityMs: Value(lastActivityMs),
      unreadCount: Value(unreadCount),
      lastMessageId: lastMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageId),
    );
  }

  factory ChatThreadRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatThreadRow(
      id: serializer.fromJson<int>(json['id']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      lastActivityMs: serializer.fromJson<int>(json['lastActivityMs']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      lastMessageId: serializer.fromJson<int?>(json['lastMessageId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'lastActivityMs': serializer.toJson<int>(lastActivityMs),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'lastMessageId': serializer.toJson<int?>(lastMessageId),
    };
  }

  ChatThreadRow copyWith(
          {int? id,
          String? payloadJson,
          int? lastActivityMs,
          int? unreadCount,
          Value<int?> lastMessageId = const Value.absent()}) =>
      ChatThreadRow(
        id: id ?? this.id,
        payloadJson: payloadJson ?? this.payloadJson,
        lastActivityMs: lastActivityMs ?? this.lastActivityMs,
        unreadCount: unreadCount ?? this.unreadCount,
        lastMessageId:
            lastMessageId.present ? lastMessageId.value : this.lastMessageId,
      );
  ChatThreadRow copyWithCompanion(ChatThreadRowsCompanion data) {
    return ChatThreadRow(
      id: data.id.present ? data.id.value : this.id,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      lastActivityMs: data.lastActivityMs.present
          ? data.lastActivityMs.value
          : this.lastActivityMs,
      unreadCount:
          data.unreadCount.present ? data.unreadCount.value : this.unreadCount,
      lastMessageId: data.lastMessageId.present
          ? data.lastMessageId.value
          : this.lastMessageId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatThreadRow(')
          ..write('id: $id, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('lastActivityMs: $lastActivityMs, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('lastMessageId: $lastMessageId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, payloadJson, lastActivityMs, unreadCount, lastMessageId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatThreadRow &&
          other.id == this.id &&
          other.payloadJson == this.payloadJson &&
          other.lastActivityMs == this.lastActivityMs &&
          other.unreadCount == this.unreadCount &&
          other.lastMessageId == this.lastMessageId);
}

class ChatThreadRowsCompanion extends UpdateCompanion<ChatThreadRow> {
  final Value<int> id;
  final Value<String> payloadJson;
  final Value<int> lastActivityMs;
  final Value<int> unreadCount;
  final Value<int?> lastMessageId;
  const ChatThreadRowsCompanion({
    this.id = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.lastActivityMs = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.lastMessageId = const Value.absent(),
  });
  ChatThreadRowsCompanion.insert({
    this.id = const Value.absent(),
    required String payloadJson,
    this.lastActivityMs = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.lastMessageId = const Value.absent(),
  }) : payloadJson = Value(payloadJson);
  static Insertable<ChatThreadRow> custom({
    Expression<int>? id,
    Expression<String>? payloadJson,
    Expression<int>? lastActivityMs,
    Expression<int>? unreadCount,
    Expression<int>? lastMessageId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (lastActivityMs != null) 'last_activity_ms': lastActivityMs,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (lastMessageId != null) 'last_message_id': lastMessageId,
    });
  }

  ChatThreadRowsCompanion copyWith(
      {Value<int>? id,
      Value<String>? payloadJson,
      Value<int>? lastActivityMs,
      Value<int>? unreadCount,
      Value<int?>? lastMessageId}) {
    return ChatThreadRowsCompanion(
      id: id ?? this.id,
      payloadJson: payloadJson ?? this.payloadJson,
      lastActivityMs: lastActivityMs ?? this.lastActivityMs,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessageId: lastMessageId ?? this.lastMessageId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (lastActivityMs.present) {
      map['last_activity_ms'] = Variable<int>(lastActivityMs.value);
    }
    if (unreadCount.present) {
      map['unread_count'] = Variable<int>(unreadCount.value);
    }
    if (lastMessageId.present) {
      map['last_message_id'] = Variable<int>(lastMessageId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatThreadRowsCompanion(')
          ..write('id: $id, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('lastActivityMs: $lastActivityMs, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('lastMessageId: $lastMessageId')
          ..write(')'))
        .toString();
  }
}

class $ChatMessageRowsTable extends ChatMessageRows
    with TableInfo<$ChatMessageRowsTable, ChatMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMessageRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _threadIdMeta =
      const VerificationMeta('threadId');
  @override
  late final GeneratedColumn<int> threadId = GeneratedColumn<int>(
      'thread_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _messageIdMeta =
      const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
      'message_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMsMeta =
      const VerificationMeta('createdAtMs');
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
      'created_at_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _isPendingMeta =
      const VerificationMeta('isPending');
  @override
  late final GeneratedColumn<bool> isPending = GeneratedColumn<bool>(
      'is_pending', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_pending" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns =>
      [threadId, messageId, payloadJson, createdAtMs, isPending];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_message_rows';
  @override
  VerificationContext validateIntegrity(Insertable<ChatMessageRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('thread_id')) {
      context.handle(_threadIdMeta,
          threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta));
    } else if (isInserting) {
      context.missing(_threadIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta,
          messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('created_at_ms')) {
      context.handle(
          _createdAtMsMeta,
          createdAtMs.isAcceptableOrUnknown(
              data['created_at_ms']!, _createdAtMsMeta));
    }
    if (data.containsKey('is_pending')) {
      context.handle(_isPendingMeta,
          isPending.isAcceptableOrUnknown(data['is_pending']!, _isPendingMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {threadId, messageId};
  @override
  ChatMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMessageRow(
      threadId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}thread_id'])!,
      messageId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}message_id'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
      createdAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at_ms'])!,
      isPending: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_pending'])!,
    );
  }

  @override
  $ChatMessageRowsTable createAlias(String alias) {
    return $ChatMessageRowsTable(attachedDatabase, alias);
  }
}

class ChatMessageRow extends DataClass implements Insertable<ChatMessageRow> {
  final int threadId;
  final int messageId;
  final String payloadJson;
  final int createdAtMs;
  final bool isPending;
  const ChatMessageRow(
      {required this.threadId,
      required this.messageId,
      required this.payloadJson,
      required this.createdAtMs,
      required this.isPending});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['thread_id'] = Variable<int>(threadId);
    map['message_id'] = Variable<int>(messageId);
    map['payload_json'] = Variable<String>(payloadJson);
    map['created_at_ms'] = Variable<int>(createdAtMs);
    map['is_pending'] = Variable<bool>(isPending);
    return map;
  }

  ChatMessageRowsCompanion toCompanion(bool nullToAbsent) {
    return ChatMessageRowsCompanion(
      threadId: Value(threadId),
      messageId: Value(messageId),
      payloadJson: Value(payloadJson),
      createdAtMs: Value(createdAtMs),
      isPending: Value(isPending),
    );
  }

  factory ChatMessageRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMessageRow(
      threadId: serializer.fromJson<int>(json['threadId']),
      messageId: serializer.fromJson<int>(json['messageId']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      isPending: serializer.fromJson<bool>(json['isPending']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'threadId': serializer.toJson<int>(threadId),
      'messageId': serializer.toJson<int>(messageId),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'isPending': serializer.toJson<bool>(isPending),
    };
  }

  ChatMessageRow copyWith(
          {int? threadId,
          int? messageId,
          String? payloadJson,
          int? createdAtMs,
          bool? isPending}) =>
      ChatMessageRow(
        threadId: threadId ?? this.threadId,
        messageId: messageId ?? this.messageId,
        payloadJson: payloadJson ?? this.payloadJson,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        isPending: isPending ?? this.isPending,
      );
  ChatMessageRow copyWithCompanion(ChatMessageRowsCompanion data) {
    return ChatMessageRow(
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      createdAtMs:
          data.createdAtMs.present ? data.createdAtMs.value : this.createdAtMs,
      isPending: data.isPending.present ? data.isPending.value : this.isPending,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessageRow(')
          ..write('threadId: $threadId, ')
          ..write('messageId: $messageId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('isPending: $isPending')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(threadId, messageId, payloadJson, createdAtMs, isPending);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMessageRow &&
          other.threadId == this.threadId &&
          other.messageId == this.messageId &&
          other.payloadJson == this.payloadJson &&
          other.createdAtMs == this.createdAtMs &&
          other.isPending == this.isPending);
}

class ChatMessageRowsCompanion extends UpdateCompanion<ChatMessageRow> {
  final Value<int> threadId;
  final Value<int> messageId;
  final Value<String> payloadJson;
  final Value<int> createdAtMs;
  final Value<bool> isPending;
  final Value<int> rowid;
  const ChatMessageRowsCompanion({
    this.threadId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.isPending = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatMessageRowsCompanion.insert({
    required int threadId,
    required int messageId,
    required String payloadJson,
    this.createdAtMs = const Value.absent(),
    this.isPending = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : threadId = Value(threadId),
        messageId = Value(messageId),
        payloadJson = Value(payloadJson);
  static Insertable<ChatMessageRow> custom({
    Expression<int>? threadId,
    Expression<int>? messageId,
    Expression<String>? payloadJson,
    Expression<int>? createdAtMs,
    Expression<bool>? isPending,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (threadId != null) 'thread_id': threadId,
      if (messageId != null) 'message_id': messageId,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAtMs != null) 'created_at_ms': createdAtMs,
      if (isPending != null) 'is_pending': isPending,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatMessageRowsCompanion copyWith(
      {Value<int>? threadId,
      Value<int>? messageId,
      Value<String>? payloadJson,
      Value<int>? createdAtMs,
      Value<bool>? isPending,
      Value<int>? rowid}) {
    return ChatMessageRowsCompanion(
      threadId: threadId ?? this.threadId,
      messageId: messageId ?? this.messageId,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      isPending: isPending ?? this.isPending,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (threadId.present) {
      map['thread_id'] = Variable<int>(threadId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAtMs.present) {
      map['created_at_ms'] = Variable<int>(createdAtMs.value);
    }
    if (isPending.present) {
      map['is_pending'] = Variable<bool>(isPending.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessageRowsCompanion(')
          ..write('threadId: $threadId, ')
          ..write('messageId: $messageId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('isPending: $isPending, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatMemberRowsTable extends ChatMemberRows
    with TableInfo<$ChatMemberRowsTable, ChatMemberRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMemberRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
      'user_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [userId, payloadJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_member_rows';
  @override
  VerificationContext validateIntegrity(Insertable<ChatMemberRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  ChatMemberRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMemberRow(
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}user_id'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
    );
  }

  @override
  $ChatMemberRowsTable createAlias(String alias) {
    return $ChatMemberRowsTable(attachedDatabase, alias);
  }
}

class ChatMemberRow extends DataClass implements Insertable<ChatMemberRow> {
  final int userId;
  final String payloadJson;
  const ChatMemberRow({required this.userId, required this.payloadJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['payload_json'] = Variable<String>(payloadJson);
    return map;
  }

  ChatMemberRowsCompanion toCompanion(bool nullToAbsent) {
    return ChatMemberRowsCompanion(
      userId: Value(userId),
      payloadJson: Value(payloadJson),
    );
  }

  factory ChatMemberRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMemberRow(
      userId: serializer.fromJson<int>(json['userId']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'payloadJson': serializer.toJson<String>(payloadJson),
    };
  }

  ChatMemberRow copyWith({int? userId, String? payloadJson}) => ChatMemberRow(
        userId: userId ?? this.userId,
        payloadJson: payloadJson ?? this.payloadJson,
      );
  ChatMemberRow copyWithCompanion(ChatMemberRowsCompanion data) {
    return ChatMemberRow(
      userId: data.userId.present ? data.userId.value : this.userId,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMemberRow(')
          ..write('userId: $userId, ')
          ..write('payloadJson: $payloadJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(userId, payloadJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMemberRow &&
          other.userId == this.userId &&
          other.payloadJson == this.payloadJson);
}

class ChatMemberRowsCompanion extends UpdateCompanion<ChatMemberRow> {
  final Value<int> userId;
  final Value<String> payloadJson;
  const ChatMemberRowsCompanion({
    this.userId = const Value.absent(),
    this.payloadJson = const Value.absent(),
  });
  ChatMemberRowsCompanion.insert({
    this.userId = const Value.absent(),
    required String payloadJson,
  }) : payloadJson = Value(payloadJson);
  static Insertable<ChatMemberRow> custom({
    Expression<int>? userId,
    Expression<String>? payloadJson,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (payloadJson != null) 'payload_json': payloadJson,
    });
  }

  ChatMemberRowsCompanion copyWith(
      {Value<int>? userId, Value<String>? payloadJson}) {
    return ChatMemberRowsCompanion(
      userId: userId ?? this.userId,
      payloadJson: payloadJson ?? this.payloadJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMemberRowsCompanion(')
          ..write('userId: $userId, ')
          ..write('payloadJson: $payloadJson')
          ..write(')'))
        .toString();
  }
}

class $ChatMetaRowsTable extends ChatMetaRows
    with TableInfo<$ChatMetaRowsTable, ChatMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMetaRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_meta_rows';
  @override
  VerificationContext validateIntegrity(Insertable<ChatMetaRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  ChatMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMetaRow(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $ChatMetaRowsTable createAlias(String alias) {
    return $ChatMetaRowsTable(attachedDatabase, alias);
  }
}

class ChatMetaRow extends DataClass implements Insertable<ChatMetaRow> {
  final String key;
  final String value;
  const ChatMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  ChatMetaRowsCompanion toCompanion(bool nullToAbsent) {
    return ChatMetaRowsCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory ChatMetaRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  ChatMetaRow copyWith({String? key, String? value}) => ChatMetaRow(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  ChatMetaRow copyWithCompanion(ChatMetaRowsCompanion data) {
    return ChatMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class ChatMetaRowsCompanion extends UpdateCompanion<ChatMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const ChatMetaRowsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatMetaRowsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<ChatMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatMetaRowsCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return ChatMetaRowsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMetaRowsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatOutboxRowsTable extends ChatOutboxRows
    with TableInfo<$ChatOutboxRowsTable, ChatOutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatOutboxRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMsMeta =
      const VerificationMeta('createdAtMs');
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
      'created_at_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [id, payloadJson, createdAtMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_outbox_rows';
  @override
  VerificationContext validateIntegrity(Insertable<ChatOutboxRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('created_at_ms')) {
      context.handle(
          _createdAtMsMeta,
          createdAtMs.isAcceptableOrUnknown(
              data['created_at_ms']!, _createdAtMsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChatOutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatOutboxRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
      createdAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at_ms'])!,
    );
  }

  @override
  $ChatOutboxRowsTable createAlias(String alias) {
    return $ChatOutboxRowsTable(attachedDatabase, alias);
  }
}

class ChatOutboxRow extends DataClass implements Insertable<ChatOutboxRow> {
  final String id;
  final String payloadJson;
  final int createdAtMs;
  const ChatOutboxRow(
      {required this.id, required this.payloadJson, required this.createdAtMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['payload_json'] = Variable<String>(payloadJson);
    map['created_at_ms'] = Variable<int>(createdAtMs);
    return map;
  }

  ChatOutboxRowsCompanion toCompanion(bool nullToAbsent) {
    return ChatOutboxRowsCompanion(
      id: Value(id),
      payloadJson: Value(payloadJson),
      createdAtMs: Value(createdAtMs),
    );
  }

  factory ChatOutboxRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatOutboxRow(
      id: serializer.fromJson<String>(json['id']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
    };
  }

  ChatOutboxRow copyWith({String? id, String? payloadJson, int? createdAtMs}) =>
      ChatOutboxRow(
        id: id ?? this.id,
        payloadJson: payloadJson ?? this.payloadJson,
        createdAtMs: createdAtMs ?? this.createdAtMs,
      );
  ChatOutboxRow copyWithCompanion(ChatOutboxRowsCompanion data) {
    return ChatOutboxRow(
      id: data.id.present ? data.id.value : this.id,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      createdAtMs:
          data.createdAtMs.present ? data.createdAtMs.value : this.createdAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatOutboxRow(')
          ..write('id: $id, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAtMs: $createdAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, payloadJson, createdAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatOutboxRow &&
          other.id == this.id &&
          other.payloadJson == this.payloadJson &&
          other.createdAtMs == this.createdAtMs);
}

class ChatOutboxRowsCompanion extends UpdateCompanion<ChatOutboxRow> {
  final Value<String> id;
  final Value<String> payloadJson;
  final Value<int> createdAtMs;
  final Value<int> rowid;
  const ChatOutboxRowsCompanion({
    this.id = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatOutboxRowsCompanion.insert({
    required String id,
    required String payloadJson,
    this.createdAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        payloadJson = Value(payloadJson);
  static Insertable<ChatOutboxRow> custom({
    Expression<String>? id,
    Expression<String>? payloadJson,
    Expression<int>? createdAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAtMs != null) 'created_at_ms': createdAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatOutboxRowsCompanion copyWith(
      {Value<String>? id,
      Value<String>? payloadJson,
      Value<int>? createdAtMs,
      Value<int>? rowid}) {
    return ChatOutboxRowsCompanion(
      id: id ?? this.id,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAtMs.present) {
      map['created_at_ms'] = Variable<int>(createdAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatOutboxRowsCompanion(')
          ..write('id: $id, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatOutboxBlobRowsTable extends ChatOutboxBlobRows
    with TableInfo<$ChatOutboxBlobRowsTable, ChatOutboxBlobRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatOutboxBlobRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _storageKeyMeta =
      const VerificationMeta('storageKey');
  @override
  late final GeneratedColumn<String> storageKey = GeneratedColumn<String>(
      'storage_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
      'bytes', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [storageKey, bytes];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_outbox_blob_rows';
  @override
  VerificationContext validateIntegrity(Insertable<ChatOutboxBlobRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('storage_key')) {
      context.handle(
          _storageKeyMeta,
          storageKey.isAcceptableOrUnknown(
              data['storage_key']!, _storageKeyMeta));
    } else if (isInserting) {
      context.missing(_storageKeyMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
          _bytesMeta, bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta));
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {storageKey};
  @override
  ChatOutboxBlobRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatOutboxBlobRow(
      storageKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}storage_key'])!,
      bytes: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}bytes'])!,
    );
  }

  @override
  $ChatOutboxBlobRowsTable createAlias(String alias) {
    return $ChatOutboxBlobRowsTable(attachedDatabase, alias);
  }
}

class ChatOutboxBlobRow extends DataClass
    implements Insertable<ChatOutboxBlobRow> {
  final String storageKey;
  final Uint8List bytes;
  const ChatOutboxBlobRow({required this.storageKey, required this.bytes});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['storage_key'] = Variable<String>(storageKey);
    map['bytes'] = Variable<Uint8List>(bytes);
    return map;
  }

  ChatOutboxBlobRowsCompanion toCompanion(bool nullToAbsent) {
    return ChatOutboxBlobRowsCompanion(
      storageKey: Value(storageKey),
      bytes: Value(bytes),
    );
  }

  factory ChatOutboxBlobRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatOutboxBlobRow(
      storageKey: serializer.fromJson<String>(json['storageKey']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'storageKey': serializer.toJson<String>(storageKey),
      'bytes': serializer.toJson<Uint8List>(bytes),
    };
  }

  ChatOutboxBlobRow copyWith({String? storageKey, Uint8List? bytes}) =>
      ChatOutboxBlobRow(
        storageKey: storageKey ?? this.storageKey,
        bytes: bytes ?? this.bytes,
      );
  ChatOutboxBlobRow copyWithCompanion(ChatOutboxBlobRowsCompanion data) {
    return ChatOutboxBlobRow(
      storageKey:
          data.storageKey.present ? data.storageKey.value : this.storageKey,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatOutboxBlobRow(')
          ..write('storageKey: $storageKey, ')
          ..write('bytes: $bytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(storageKey, $driftBlobEquality.hash(bytes));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatOutboxBlobRow &&
          other.storageKey == this.storageKey &&
          $driftBlobEquality.equals(other.bytes, this.bytes));
}

class ChatOutboxBlobRowsCompanion extends UpdateCompanion<ChatOutboxBlobRow> {
  final Value<String> storageKey;
  final Value<Uint8List> bytes;
  final Value<int> rowid;
  const ChatOutboxBlobRowsCompanion({
    this.storageKey = const Value.absent(),
    this.bytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatOutboxBlobRowsCompanion.insert({
    required String storageKey,
    required Uint8List bytes,
    this.rowid = const Value.absent(),
  })  : storageKey = Value(storageKey),
        bytes = Value(bytes);
  static Insertable<ChatOutboxBlobRow> custom({
    Expression<String>? storageKey,
    Expression<Uint8List>? bytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (storageKey != null) 'storage_key': storageKey,
      if (bytes != null) 'bytes': bytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatOutboxBlobRowsCompanion copyWith(
      {Value<String>? storageKey, Value<Uint8List>? bytes, Value<int>? rowid}) {
    return ChatOutboxBlobRowsCompanion(
      storageKey: storageKey ?? this.storageKey,
      bytes: bytes ?? this.bytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (storageKey.present) {
      map['storage_key'] = Variable<String>(storageKey.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatOutboxBlobRowsCompanion(')
          ..write('storageKey: $storageKey, ')
          ..write('bytes: $bytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MediaLocalIndexRowsTable extends MediaLocalIndexRows
    with TableInfo<$MediaLocalIndexRowsTable, MediaLocalIndexRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaLocalIndexRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, payloadJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_local_index_rows';
  @override
  VerificationContext validateIntegrity(Insertable<MediaLocalIndexRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MediaLocalIndexRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaLocalIndexRow(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
    );
  }

  @override
  $MediaLocalIndexRowsTable createAlias(String alias) {
    return $MediaLocalIndexRowsTable(attachedDatabase, alias);
  }
}

class MediaLocalIndexRow extends DataClass
    implements Insertable<MediaLocalIndexRow> {
  final String key;
  final String payloadJson;
  const MediaLocalIndexRow({required this.key, required this.payloadJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['payload_json'] = Variable<String>(payloadJson);
    return map;
  }

  MediaLocalIndexRowsCompanion toCompanion(bool nullToAbsent) {
    return MediaLocalIndexRowsCompanion(
      key: Value(key),
      payloadJson: Value(payloadJson),
    );
  }

  factory MediaLocalIndexRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaLocalIndexRow(
      key: serializer.fromJson<String>(json['key']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'payloadJson': serializer.toJson<String>(payloadJson),
    };
  }

  MediaLocalIndexRow copyWith({String? key, String? payloadJson}) =>
      MediaLocalIndexRow(
        key: key ?? this.key,
        payloadJson: payloadJson ?? this.payloadJson,
      );
  MediaLocalIndexRow copyWithCompanion(MediaLocalIndexRowsCompanion data) {
    return MediaLocalIndexRow(
      key: data.key.present ? data.key.value : this.key,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaLocalIndexRow(')
          ..write('key: $key, ')
          ..write('payloadJson: $payloadJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, payloadJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaLocalIndexRow &&
          other.key == this.key &&
          other.payloadJson == this.payloadJson);
}

class MediaLocalIndexRowsCompanion extends UpdateCompanion<MediaLocalIndexRow> {
  final Value<String> key;
  final Value<String> payloadJson;
  final Value<int> rowid;
  const MediaLocalIndexRowsCompanion({
    this.key = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaLocalIndexRowsCompanion.insert({
    required String key,
    required String payloadJson,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        payloadJson = Value(payloadJson);
  static Insertable<MediaLocalIndexRow> custom({
    Expression<String>? key,
    Expression<String>? payloadJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaLocalIndexRowsCompanion copyWith(
      {Value<String>? key, Value<String>? payloadJson, Value<int>? rowid}) {
    return MediaLocalIndexRowsCompanion(
      key: key ?? this.key,
      payloadJson: payloadJson ?? this.payloadJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaLocalIndexRowsCompanion(')
          ..write('key: $key, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ChatDatabase extends GeneratedDatabase {
  _$ChatDatabase(QueryExecutor e) : super(e);
  $ChatDatabaseManager get managers => $ChatDatabaseManager(this);
  late final $ChatThreadRowsTable chatThreadRows = $ChatThreadRowsTable(this);
  late final $ChatMessageRowsTable chatMessageRows =
      $ChatMessageRowsTable(this);
  late final $ChatMemberRowsTable chatMemberRows = $ChatMemberRowsTable(this);
  late final $ChatMetaRowsTable chatMetaRows = $ChatMetaRowsTable(this);
  late final $ChatOutboxRowsTable chatOutboxRows = $ChatOutboxRowsTable(this);
  late final $ChatOutboxBlobRowsTable chatOutboxBlobRows =
      $ChatOutboxBlobRowsTable(this);
  late final $MediaLocalIndexRowsTable mediaLocalIndexRows =
      $MediaLocalIndexRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        chatThreadRows,
        chatMessageRows,
        chatMemberRows,
        chatMetaRows,
        chatOutboxRows,
        chatOutboxBlobRows,
        mediaLocalIndexRows
      ];
}

typedef $$ChatThreadRowsTableCreateCompanionBuilder = ChatThreadRowsCompanion
    Function({
  Value<int> id,
  required String payloadJson,
  Value<int> lastActivityMs,
  Value<int> unreadCount,
  Value<int?> lastMessageId,
});
typedef $$ChatThreadRowsTableUpdateCompanionBuilder = ChatThreadRowsCompanion
    Function({
  Value<int> id,
  Value<String> payloadJson,
  Value<int> lastActivityMs,
  Value<int> unreadCount,
  Value<int?> lastMessageId,
});

class $$ChatThreadRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChatThreadRowsTable> {
  $$ChatThreadRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastActivityMs => $composableBuilder(
      column: $table.lastActivityMs,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastMessageId => $composableBuilder(
      column: $table.lastMessageId, builder: (column) => ColumnFilters(column));
}

class $$ChatThreadRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChatThreadRowsTable> {
  $$ChatThreadRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastActivityMs => $composableBuilder(
      column: $table.lastActivityMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastMessageId => $composableBuilder(
      column: $table.lastMessageId,
      builder: (column) => ColumnOrderings(column));
}

class $$ChatThreadRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChatThreadRowsTable> {
  $$ChatThreadRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<int> get lastActivityMs => $composableBuilder(
      column: $table.lastActivityMs, builder: (column) => column);

  GeneratedColumn<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => column);

  GeneratedColumn<int> get lastMessageId => $composableBuilder(
      column: $table.lastMessageId, builder: (column) => column);
}

class $$ChatThreadRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $ChatThreadRowsTable,
    ChatThreadRow,
    $$ChatThreadRowsTableFilterComposer,
    $$ChatThreadRowsTableOrderingComposer,
    $$ChatThreadRowsTableAnnotationComposer,
    $$ChatThreadRowsTableCreateCompanionBuilder,
    $$ChatThreadRowsTableUpdateCompanionBuilder,
    (
      ChatThreadRow,
      BaseReferences<_$ChatDatabase, $ChatThreadRowsTable, ChatThreadRow>
    ),
    ChatThreadRow,
    PrefetchHooks Function()> {
  $$ChatThreadRowsTableTableManager(
      _$ChatDatabase db, $ChatThreadRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatThreadRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatThreadRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatThreadRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int> lastActivityMs = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<int?> lastMessageId = const Value.absent(),
          }) =>
              ChatThreadRowsCompanion(
            id: id,
            payloadJson: payloadJson,
            lastActivityMs: lastActivityMs,
            unreadCount: unreadCount,
            lastMessageId: lastMessageId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String payloadJson,
            Value<int> lastActivityMs = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<int?> lastMessageId = const Value.absent(),
          }) =>
              ChatThreadRowsCompanion.insert(
            id: id,
            payloadJson: payloadJson,
            lastActivityMs: lastActivityMs,
            unreadCount: unreadCount,
            lastMessageId: lastMessageId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatThreadRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $ChatThreadRowsTable,
    ChatThreadRow,
    $$ChatThreadRowsTableFilterComposer,
    $$ChatThreadRowsTableOrderingComposer,
    $$ChatThreadRowsTableAnnotationComposer,
    $$ChatThreadRowsTableCreateCompanionBuilder,
    $$ChatThreadRowsTableUpdateCompanionBuilder,
    (
      ChatThreadRow,
      BaseReferences<_$ChatDatabase, $ChatThreadRowsTable, ChatThreadRow>
    ),
    ChatThreadRow,
    PrefetchHooks Function()>;
typedef $$ChatMessageRowsTableCreateCompanionBuilder = ChatMessageRowsCompanion
    Function({
  required int threadId,
  required int messageId,
  required String payloadJson,
  Value<int> createdAtMs,
  Value<bool> isPending,
  Value<int> rowid,
});
typedef $$ChatMessageRowsTableUpdateCompanionBuilder = ChatMessageRowsCompanion
    Function({
  Value<int> threadId,
  Value<int> messageId,
  Value<String> payloadJson,
  Value<int> createdAtMs,
  Value<bool> isPending,
  Value<int> rowid,
});

class $$ChatMessageRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChatMessageRowsTable> {
  $$ChatMessageRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get threadId => $composableBuilder(
      column: $table.threadId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get messageId => $composableBuilder(
      column: $table.messageId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isPending => $composableBuilder(
      column: $table.isPending, builder: (column) => ColumnFilters(column));
}

class $$ChatMessageRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChatMessageRowsTable> {
  $$ChatMessageRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get threadId => $composableBuilder(
      column: $table.threadId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get messageId => $composableBuilder(
      column: $table.messageId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isPending => $composableBuilder(
      column: $table.isPending, builder: (column) => ColumnOrderings(column));
}

class $$ChatMessageRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChatMessageRowsTable> {
  $$ChatMessageRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<int> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => column);

  GeneratedColumn<bool> get isPending =>
      $composableBuilder(column: $table.isPending, builder: (column) => column);
}

class $$ChatMessageRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $ChatMessageRowsTable,
    ChatMessageRow,
    $$ChatMessageRowsTableFilterComposer,
    $$ChatMessageRowsTableOrderingComposer,
    $$ChatMessageRowsTableAnnotationComposer,
    $$ChatMessageRowsTableCreateCompanionBuilder,
    $$ChatMessageRowsTableUpdateCompanionBuilder,
    (
      ChatMessageRow,
      BaseReferences<_$ChatDatabase, $ChatMessageRowsTable, ChatMessageRow>
    ),
    ChatMessageRow,
    PrefetchHooks Function()> {
  $$ChatMessageRowsTableTableManager(
      _$ChatDatabase db, $ChatMessageRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMessageRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMessageRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMessageRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> threadId = const Value.absent(),
            Value<int> messageId = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int> createdAtMs = const Value.absent(),
            Value<bool> isPending = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatMessageRowsCompanion(
            threadId: threadId,
            messageId: messageId,
            payloadJson: payloadJson,
            createdAtMs: createdAtMs,
            isPending: isPending,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int threadId,
            required int messageId,
            required String payloadJson,
            Value<int> createdAtMs = const Value.absent(),
            Value<bool> isPending = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatMessageRowsCompanion.insert(
            threadId: threadId,
            messageId: messageId,
            payloadJson: payloadJson,
            createdAtMs: createdAtMs,
            isPending: isPending,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatMessageRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $ChatMessageRowsTable,
    ChatMessageRow,
    $$ChatMessageRowsTableFilterComposer,
    $$ChatMessageRowsTableOrderingComposer,
    $$ChatMessageRowsTableAnnotationComposer,
    $$ChatMessageRowsTableCreateCompanionBuilder,
    $$ChatMessageRowsTableUpdateCompanionBuilder,
    (
      ChatMessageRow,
      BaseReferences<_$ChatDatabase, $ChatMessageRowsTable, ChatMessageRow>
    ),
    ChatMessageRow,
    PrefetchHooks Function()>;
typedef $$ChatMemberRowsTableCreateCompanionBuilder = ChatMemberRowsCompanion
    Function({
  Value<int> userId,
  required String payloadJson,
});
typedef $$ChatMemberRowsTableUpdateCompanionBuilder = ChatMemberRowsCompanion
    Function({
  Value<int> userId,
  Value<String> payloadJson,
});

class $$ChatMemberRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChatMemberRowsTable> {
  $$ChatMemberRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));
}

class $$ChatMemberRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChatMemberRowsTable> {
  $$ChatMemberRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));
}

class $$ChatMemberRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChatMemberRowsTable> {
  $$ChatMemberRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);
}

class $$ChatMemberRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $ChatMemberRowsTable,
    ChatMemberRow,
    $$ChatMemberRowsTableFilterComposer,
    $$ChatMemberRowsTableOrderingComposer,
    $$ChatMemberRowsTableAnnotationComposer,
    $$ChatMemberRowsTableCreateCompanionBuilder,
    $$ChatMemberRowsTableUpdateCompanionBuilder,
    (
      ChatMemberRow,
      BaseReferences<_$ChatDatabase, $ChatMemberRowsTable, ChatMemberRow>
    ),
    ChatMemberRow,
    PrefetchHooks Function()> {
  $$ChatMemberRowsTableTableManager(
      _$ChatDatabase db, $ChatMemberRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMemberRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMemberRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMemberRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> userId = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
          }) =>
              ChatMemberRowsCompanion(
            userId: userId,
            payloadJson: payloadJson,
          ),
          createCompanionCallback: ({
            Value<int> userId = const Value.absent(),
            required String payloadJson,
          }) =>
              ChatMemberRowsCompanion.insert(
            userId: userId,
            payloadJson: payloadJson,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatMemberRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $ChatMemberRowsTable,
    ChatMemberRow,
    $$ChatMemberRowsTableFilterComposer,
    $$ChatMemberRowsTableOrderingComposer,
    $$ChatMemberRowsTableAnnotationComposer,
    $$ChatMemberRowsTableCreateCompanionBuilder,
    $$ChatMemberRowsTableUpdateCompanionBuilder,
    (
      ChatMemberRow,
      BaseReferences<_$ChatDatabase, $ChatMemberRowsTable, ChatMemberRow>
    ),
    ChatMemberRow,
    PrefetchHooks Function()>;
typedef $$ChatMetaRowsTableCreateCompanionBuilder = ChatMetaRowsCompanion
    Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$ChatMetaRowsTableUpdateCompanionBuilder = ChatMetaRowsCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$ChatMetaRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChatMetaRowsTable> {
  $$ChatMetaRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$ChatMetaRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChatMetaRowsTable> {
  $$ChatMetaRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$ChatMetaRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChatMetaRowsTable> {
  $$ChatMetaRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$ChatMetaRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $ChatMetaRowsTable,
    ChatMetaRow,
    $$ChatMetaRowsTableFilterComposer,
    $$ChatMetaRowsTableOrderingComposer,
    $$ChatMetaRowsTableAnnotationComposer,
    $$ChatMetaRowsTableCreateCompanionBuilder,
    $$ChatMetaRowsTableUpdateCompanionBuilder,
    (
      ChatMetaRow,
      BaseReferences<_$ChatDatabase, $ChatMetaRowsTable, ChatMetaRow>
    ),
    ChatMetaRow,
    PrefetchHooks Function()> {
  $$ChatMetaRowsTableTableManager(_$ChatDatabase db, $ChatMetaRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMetaRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMetaRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMetaRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatMetaRowsCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatMetaRowsCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatMetaRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $ChatMetaRowsTable,
    ChatMetaRow,
    $$ChatMetaRowsTableFilterComposer,
    $$ChatMetaRowsTableOrderingComposer,
    $$ChatMetaRowsTableAnnotationComposer,
    $$ChatMetaRowsTableCreateCompanionBuilder,
    $$ChatMetaRowsTableUpdateCompanionBuilder,
    (
      ChatMetaRow,
      BaseReferences<_$ChatDatabase, $ChatMetaRowsTable, ChatMetaRow>
    ),
    ChatMetaRow,
    PrefetchHooks Function()>;
typedef $$ChatOutboxRowsTableCreateCompanionBuilder = ChatOutboxRowsCompanion
    Function({
  required String id,
  required String payloadJson,
  Value<int> createdAtMs,
  Value<int> rowid,
});
typedef $$ChatOutboxRowsTableUpdateCompanionBuilder = ChatOutboxRowsCompanion
    Function({
  Value<String> id,
  Value<String> payloadJson,
  Value<int> createdAtMs,
  Value<int> rowid,
});

class $$ChatOutboxRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChatOutboxRowsTable> {
  $$ChatOutboxRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnFilters(column));
}

class $$ChatOutboxRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChatOutboxRowsTable> {
  $$ChatOutboxRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnOrderings(column));
}

class $$ChatOutboxRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChatOutboxRowsTable> {
  $$ChatOutboxRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => column);
}

class $$ChatOutboxRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $ChatOutboxRowsTable,
    ChatOutboxRow,
    $$ChatOutboxRowsTableFilterComposer,
    $$ChatOutboxRowsTableOrderingComposer,
    $$ChatOutboxRowsTableAnnotationComposer,
    $$ChatOutboxRowsTableCreateCompanionBuilder,
    $$ChatOutboxRowsTableUpdateCompanionBuilder,
    (
      ChatOutboxRow,
      BaseReferences<_$ChatDatabase, $ChatOutboxRowsTable, ChatOutboxRow>
    ),
    ChatOutboxRow,
    PrefetchHooks Function()> {
  $$ChatOutboxRowsTableTableManager(
      _$ChatDatabase db, $ChatOutboxRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatOutboxRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatOutboxRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatOutboxRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int> createdAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatOutboxRowsCompanion(
            id: id,
            payloadJson: payloadJson,
            createdAtMs: createdAtMs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String payloadJson,
            Value<int> createdAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatOutboxRowsCompanion.insert(
            id: id,
            payloadJson: payloadJson,
            createdAtMs: createdAtMs,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatOutboxRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $ChatOutboxRowsTable,
    ChatOutboxRow,
    $$ChatOutboxRowsTableFilterComposer,
    $$ChatOutboxRowsTableOrderingComposer,
    $$ChatOutboxRowsTableAnnotationComposer,
    $$ChatOutboxRowsTableCreateCompanionBuilder,
    $$ChatOutboxRowsTableUpdateCompanionBuilder,
    (
      ChatOutboxRow,
      BaseReferences<_$ChatDatabase, $ChatOutboxRowsTable, ChatOutboxRow>
    ),
    ChatOutboxRow,
    PrefetchHooks Function()>;
typedef $$ChatOutboxBlobRowsTableCreateCompanionBuilder
    = ChatOutboxBlobRowsCompanion Function({
  required String storageKey,
  required Uint8List bytes,
  Value<int> rowid,
});
typedef $$ChatOutboxBlobRowsTableUpdateCompanionBuilder
    = ChatOutboxBlobRowsCompanion Function({
  Value<String> storageKey,
  Value<Uint8List> bytes,
  Value<int> rowid,
});

class $$ChatOutboxBlobRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChatOutboxBlobRowsTable> {
  $$ChatOutboxBlobRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get storageKey => $composableBuilder(
      column: $table.storageKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
      column: $table.bytes, builder: (column) => ColumnFilters(column));
}

class $$ChatOutboxBlobRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChatOutboxBlobRowsTable> {
  $$ChatOutboxBlobRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get storageKey => $composableBuilder(
      column: $table.storageKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
      column: $table.bytes, builder: (column) => ColumnOrderings(column));
}

class $$ChatOutboxBlobRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChatOutboxBlobRowsTable> {
  $$ChatOutboxBlobRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get storageKey => $composableBuilder(
      column: $table.storageKey, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);
}

class $$ChatOutboxBlobRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $ChatOutboxBlobRowsTable,
    ChatOutboxBlobRow,
    $$ChatOutboxBlobRowsTableFilterComposer,
    $$ChatOutboxBlobRowsTableOrderingComposer,
    $$ChatOutboxBlobRowsTableAnnotationComposer,
    $$ChatOutboxBlobRowsTableCreateCompanionBuilder,
    $$ChatOutboxBlobRowsTableUpdateCompanionBuilder,
    (
      ChatOutboxBlobRow,
      BaseReferences<_$ChatDatabase, $ChatOutboxBlobRowsTable,
          ChatOutboxBlobRow>
    ),
    ChatOutboxBlobRow,
    PrefetchHooks Function()> {
  $$ChatOutboxBlobRowsTableTableManager(
      _$ChatDatabase db, $ChatOutboxBlobRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatOutboxBlobRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatOutboxBlobRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatOutboxBlobRowsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> storageKey = const Value.absent(),
            Value<Uint8List> bytes = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatOutboxBlobRowsCompanion(
            storageKey: storageKey,
            bytes: bytes,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String storageKey,
            required Uint8List bytes,
            Value<int> rowid = const Value.absent(),
          }) =>
              ChatOutboxBlobRowsCompanion.insert(
            storageKey: storageKey,
            bytes: bytes,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatOutboxBlobRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $ChatOutboxBlobRowsTable,
    ChatOutboxBlobRow,
    $$ChatOutboxBlobRowsTableFilterComposer,
    $$ChatOutboxBlobRowsTableOrderingComposer,
    $$ChatOutboxBlobRowsTableAnnotationComposer,
    $$ChatOutboxBlobRowsTableCreateCompanionBuilder,
    $$ChatOutboxBlobRowsTableUpdateCompanionBuilder,
    (
      ChatOutboxBlobRow,
      BaseReferences<_$ChatDatabase, $ChatOutboxBlobRowsTable,
          ChatOutboxBlobRow>
    ),
    ChatOutboxBlobRow,
    PrefetchHooks Function()>;
typedef $$MediaLocalIndexRowsTableCreateCompanionBuilder
    = MediaLocalIndexRowsCompanion Function({
  required String key,
  required String payloadJson,
  Value<int> rowid,
});
typedef $$MediaLocalIndexRowsTableUpdateCompanionBuilder
    = MediaLocalIndexRowsCompanion Function({
  Value<String> key,
  Value<String> payloadJson,
  Value<int> rowid,
});

class $$MediaLocalIndexRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $MediaLocalIndexRowsTable> {
  $$MediaLocalIndexRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));
}

class $$MediaLocalIndexRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $MediaLocalIndexRowsTable> {
  $$MediaLocalIndexRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));
}

class $$MediaLocalIndexRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $MediaLocalIndexRowsTable> {
  $$MediaLocalIndexRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);
}

class $$MediaLocalIndexRowsTableTableManager extends RootTableManager<
    _$ChatDatabase,
    $MediaLocalIndexRowsTable,
    MediaLocalIndexRow,
    $$MediaLocalIndexRowsTableFilterComposer,
    $$MediaLocalIndexRowsTableOrderingComposer,
    $$MediaLocalIndexRowsTableAnnotationComposer,
    $$MediaLocalIndexRowsTableCreateCompanionBuilder,
    $$MediaLocalIndexRowsTableUpdateCompanionBuilder,
    (
      MediaLocalIndexRow,
      BaseReferences<_$ChatDatabase, $MediaLocalIndexRowsTable,
          MediaLocalIndexRow>
    ),
    MediaLocalIndexRow,
    PrefetchHooks Function()> {
  $$MediaLocalIndexRowsTableTableManager(
      _$ChatDatabase db, $MediaLocalIndexRowsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaLocalIndexRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaLocalIndexRowsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaLocalIndexRowsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MediaLocalIndexRowsCompanion(
            key: key,
            payloadJson: payloadJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String payloadJson,
            Value<int> rowid = const Value.absent(),
          }) =>
              MediaLocalIndexRowsCompanion.insert(
            key: key,
            payloadJson: payloadJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MediaLocalIndexRowsTableProcessedTableManager = ProcessedTableManager<
    _$ChatDatabase,
    $MediaLocalIndexRowsTable,
    MediaLocalIndexRow,
    $$MediaLocalIndexRowsTableFilterComposer,
    $$MediaLocalIndexRowsTableOrderingComposer,
    $$MediaLocalIndexRowsTableAnnotationComposer,
    $$MediaLocalIndexRowsTableCreateCompanionBuilder,
    $$MediaLocalIndexRowsTableUpdateCompanionBuilder,
    (
      MediaLocalIndexRow,
      BaseReferences<_$ChatDatabase, $MediaLocalIndexRowsTable,
          MediaLocalIndexRow>
    ),
    MediaLocalIndexRow,
    PrefetchHooks Function()>;

class $ChatDatabaseManager {
  final _$ChatDatabase _db;
  $ChatDatabaseManager(this._db);
  $$ChatThreadRowsTableTableManager get chatThreadRows =>
      $$ChatThreadRowsTableTableManager(_db, _db.chatThreadRows);
  $$ChatMessageRowsTableTableManager get chatMessageRows =>
      $$ChatMessageRowsTableTableManager(_db, _db.chatMessageRows);
  $$ChatMemberRowsTableTableManager get chatMemberRows =>
      $$ChatMemberRowsTableTableManager(_db, _db.chatMemberRows);
  $$ChatMetaRowsTableTableManager get chatMetaRows =>
      $$ChatMetaRowsTableTableManager(_db, _db.chatMetaRows);
  $$ChatOutboxRowsTableTableManager get chatOutboxRows =>
      $$ChatOutboxRowsTableTableManager(_db, _db.chatOutboxRows);
  $$ChatOutboxBlobRowsTableTableManager get chatOutboxBlobRows =>
      $$ChatOutboxBlobRowsTableTableManager(_db, _db.chatOutboxBlobRows);
  $$MediaLocalIndexRowsTableTableManager get mediaLocalIndexRows =>
      $$MediaLocalIndexRowsTableTableManager(_db, _db.mediaLocalIndexRows);
}
