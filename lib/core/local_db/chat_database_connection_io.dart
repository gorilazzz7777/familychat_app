import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:sqlite3/common.dart';

void _configureChatSqlite(CommonDatabase database) {
  database.execute('PRAGMA busy_timeout = 8000;');
  database.execute('PRAGMA journal_mode = WAL;');
  database.execute('PRAGMA synchronous = NORMAL;');
}

/// Kept for FCM background isolate / explicit native opens.
QueryExecutor openChatDatabaseConnection() {
  return driftDatabase(
    name: 'familychat_chat',
    native: DriftNativeOptions(
      shareAcrossIsolates: true,
      setup: _configureChatSqlite,
    ),
  );
}
