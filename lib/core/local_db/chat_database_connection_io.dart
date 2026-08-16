import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// Kept for FCM background isolate / explicit native opens.
QueryExecutor openChatDatabaseConnection() {
  return driftDatabase(name: 'familychat_chat');
}
