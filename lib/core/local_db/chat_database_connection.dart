import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// Cross-platform Drift executor (native file + web Wasm).
QueryExecutor openChatDatabaseConnection() {
  return driftDatabase(
    name: 'familychat_chat',
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );
}
