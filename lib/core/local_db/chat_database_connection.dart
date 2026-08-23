import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:sqlite3/common.dart';

void _configureChatSqlite(CommonDatabase database) {
  database.execute('PRAGMA busy_timeout = 8000;');
  database.execute('PRAGMA journal_mode = WAL;');
  database.execute('PRAGMA synchronous = NORMAL;');
}

/// Cross-platform Drift executor (native file + web Wasm).
QueryExecutor openChatDatabaseConnection() {
  // Resolve against document base (/app/) so nested routes still find assets.
  final sqlite3Wasm = Uri.base.resolve('sqlite3.wasm');
  final driftWorker = Uri.base.resolve('drift_worker.js');
  return driftDatabase(
    name: 'familychat_chat',
    native: DriftNativeOptions(
      shareAcrossIsolates: true,
      setup: _configureChatSqlite,
    ),
    web: DriftWebOptions(
      sqlite3Wasm: sqlite3Wasm,
      driftWorker: driftWorker,
    ),
  );
}
