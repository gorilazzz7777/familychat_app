import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// Cross-platform Drift executor (native file + web Wasm).
QueryExecutor openChatDatabaseConnection() {
  // Resolve against document base (/app/) so nested routes still find assets.
  final sqlite3Wasm = Uri.base.resolve('sqlite3.wasm');
  final driftWorker = Uri.base.resolve('drift_worker.js');
  return driftDatabase(
    name: 'familychat_chat',
    web: DriftWebOptions(
      sqlite3Wasm: sqlite3Wasm,
      driftWorker: driftWorker,
    ),
  );
}
