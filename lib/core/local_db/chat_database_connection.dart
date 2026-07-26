import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'chat_database_connection_stub.dart'
    if (dart.library.io) 'chat_database_connection_io.dart' as impl;

QueryExecutor openChatDatabaseConnection() {
  if (kIsWeb) {
    throw UnsupportedError('Chat SQLite is native-only');
  }
  return impl.openChatDatabaseConnection();
}