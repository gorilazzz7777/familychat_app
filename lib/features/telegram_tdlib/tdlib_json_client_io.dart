import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tdlib_ffi.dart';

class TdlibApiException implements Exception {
  TdlibApiException({required this.code, required this.message});

  final int code;
  final String message;

  bool get isNeedsTdlibParameters {
    final m = message.toLowerCase();
    return m.contains('initialization parameters') ||
        m.contains('settdlibparameters');
  }

  @override
  String toString() => 'TDLib error $code: $message';
}

/// Process-wide receive loop. [td_receive] must never run on two threads.
class _TdlibReceiveHub {
  _TdlibReceiveHub._();

  static const _portName = 'familychat.tdlib.receive.control';

  static Isolate? _isolate;
  static ReceivePort? _fromIsolate;
  static SendPort? _controlPort;
  static final _updates = StreamController<Map<String, dynamic>>.broadcast();
  static Future<void>? _starting;

  /// Called when any live client sees "call setTdlibParameters first".
  static void Function(TdlibApiException error)? onNeedsParameters;

  static Stream<Map<String, dynamic>> get updates => _updates.stream;

  static Future<void> ensureStarted() {
    if (_isolate != null && _controlPort != null) {
      return Future<void>.value();
    }
    return _starting ??= _start();
  }

  static Future<void> _stopPreviousReceiveIsolate() async {
    final old = IsolateNameServer.lookupPortByName(_portName);
    if (old == null) return;
    try {
      IsolateNameServer.removePortNameMapping(_portName);
    } catch (_) {}
    try {
      old.send('stop');
    } catch (_) {}
    // td_receive timeout is 1s — wait for the loop to exit.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  static Future<void> _start() async {
    await _stopPreviousReceiveIsolate();
    _fromIsolate?.close();
    _fromIsolate = ReceivePort();
    final ready = Completer<SendPort>();
    _fromIsolate!.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message == 'stopped') return;
      if (message is! String) return;
      Map<String, dynamic>? obj;
      try {
        obj = jsonDecode(message) as Map<String, dynamic>?;
      } catch (_) {
        return;
      }
      if (obj == null || _updates.isClosed) return;
      _updates.add(obj);
    });
    _isolate = await Isolate.spawn(
      _receiveIsolateMain,
      _fromIsolate!.sendPort,
    );
    _controlPort = await ready.future.timeout(const Duration(seconds: 5));
    _starting = null;
  }

  static void _receiveIsolateMain(SendPort sendPort) {
    final ffi = TdlibFfi.open();
    final control = ReceivePort();
    try {
      IsolateNameServer.removePortNameMapping(_portName);
    } catch (_) {}
    IsolateNameServer.registerPortWithName(control.sendPort, _portName);
    sendPort.send(control.sendPort);
    var running = true;
    control.listen((msg) {
      if (msg == 'stop') running = false;
    });
    while (running) {
      // 1s idle timeout; stop signal is checked between receives.
      final raw = ffi.receive(1.0);
      if (raw == null || raw.isEmpty) continue;
      sendPort.send(raw);
    }
    try {
      IsolateNameServer.removePortNameMapping(_portName);
    } catch (_) {}
    sendPort.send('stopped');
    control.close();
  }
}

/// JSON TDLib client. Shares one process-wide [td_receive] loop.
class TdlibJsonClient {
  TdlibJsonClient._(this._ffi, this._clientId);

  static const _clientIdFile = 'tdlib_active_client_id.txt';

  final TdlibFfi _ffi;
  final int _clientId;
  StreamSubscription<Map<String, dynamic>>? _hubSub;
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  int _extraSeq = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  bool _disposed = false;

  /// App hook: native client returned "call setTdlibParameters first".
  static set onNeedsParameters(void Function(TdlibApiException error)? cb) {
    _TdlibReceiveHub.onNeedsParameters = cb;
  }

  /// Single-flight create — concurrent ensureStarted callers share one client.
  static Future<TdlibJsonClient>? _createInFlight;

  int get clientId => _clientId;

  Stream<Map<String, dynamic>> get updates => _updates.stream;

  static Future<TdlibJsonClient> create() {
    final existing = _createInFlight;
    if (existing != null) return existing;
    late final Future<TdlibJsonClient> created;
    created = _createImpl().whenComplete(() {
      if (identical(_createInFlight, created)) {
        _createInFlight = null;
      }
    });
    _createInFlight = created;
    return created;
  }

  static Future<TdlibJsonClient> _createImpl() async {
    await _TdlibReceiveHub.ensureStarted();
    final ffi = TdlibFfi.open();
    // Hot restart leaves native clients alive — close the last one only.
    await closeOrphanedClients(existing: ffi);
    final clientId = ffi.createClientId();
    await _persistClientId(clientId);
    final client = TdlibJsonClient._(ffi, clientId);
    client._hubSub = _TdlibReceiveHub.updates.listen(client._onHubUpdate);
    debugPrint('[tdlib] client created id=$clientId');
    return client;
  }

  /// Close native clients left over after hot restart / crash.
  ///
  /// Only the persisted last id (and at most one previous) — never a wide
  /// range that can race-close a freshly created live client.
  static Future<void> closeOrphanedClients({
    TdlibFfi? existing,
    int? exceptClientId,
  }) async {
    await _TdlibReceiveHub.ensureStarted();
    final ffi = existing ?? TdlibFfi.open();
    final lastId = await _readPersistedClientId();
    final ids = <int>{};
    if (lastId != null && lastId > 0) {
      ids.add(lastId);
      if (lastId > 1) ids.add(lastId - 1);
    }
    if (exceptClientId != null) {
      ids.remove(exceptClientId);
    }
    if (ids.isEmpty) return;
    await Future.wait(ids.map((id) => _closeClientId(ffi, id)));
  }

  static Future<void> _closeClientId(TdlibFfi ffi, int clientId) async {
    final closed = Completer<void>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = _TdlibReceiveHub.updates.listen((obj) {
      final cid = (obj['@client_id'] as num?)?.toInt();
      if (cid != null && cid != clientId) return;
      if (obj['@type']?.toString() != 'updateAuthorizationState') return;
      final state = obj['authorization_state'];
      final type = state is Map ? state['@type']?.toString() : null;
      if (type == 'authorizationStateClosed' && !closed.isCompleted) {
        closed.complete();
      }
    });
    try {
      ffi.send(clientId, jsonEncode({'@type': 'close'}));
      await closed.future.timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // Already closed / never existed — fine.
    } finally {
      await sub.cancel();
    }
  }

  static Future<File> _clientIdStore() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, _clientIdFile));
  }

  static Future<void> _persistClientId(int id) async {
    try {
      final f = await _clientIdStore();
      await f.writeAsString('$id');
    } catch (e) {
      debugPrint('[tdlib] persist client id failed: $e');
    }
  }

  static Future<int?> _readPersistedClientId() async {
    try {
      final f = await _clientIdStore();
      if (!await f.exists()) return null;
      return int.tryParse((await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearPersistedClientId() async {
    try {
      final f = await _clientIdStore();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _onHubUpdate(Map<String, dynamic> obj) {
    if (_disposed) return;
    final clientId = (obj['@client_id'] as num?)?.toInt();
    // Drop updates without client id or for another client — never deliver
    // cross-client errors into our pending map.
    if (clientId == null || clientId != _clientId) return;

    final extra = obj['@extra']?.toString();
    if (extra != null && _pending.containsKey(extra)) {
      final completer = _pending.remove(extra);
      if (obj['@type']?.toString() == 'error') {
        final err = TdlibApiException(
          code: (obj['code'] as num?)?.toInt() ?? 0,
          message: obj['message']?.toString() ?? 'TDLib error',
        );
        if (err.isNeedsTdlibParameters) {
          _TdlibReceiveHub.onNeedsParameters?.call(err);
        }
        completer?.completeError(err);
      } else {
        completer?.complete(obj);
      }
    }
    if (!_updates.isClosed) {
      _updates.add(obj);
    }
  }

  void send(Map<String, dynamic> request) {
    if (_disposed) return;
    _ffi.send(_clientId, jsonEncode(request));
  }

  Future<Map<String, dynamic>> sendAwait(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_disposed) {
      return Future.error(StateError('TDLib client disposed'));
    }
    final extra = 'fc_${_clientId}_${++_extraSeq}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[extra] = completer;
    send({...request, '@extra': extra});
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(extra);
      throw TimeoutException('TDLib request timed out: ${request['@type']}');
    });
  }

  Map<String, dynamic> execute(Map<String, dynamic> request) {
    final raw = _ffi.execute(jsonEncode(request));
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('TDLib client disposed'));
      }
    }
    _pending.clear();
    await _hubSub?.cancel();
    _hubSub = null;

    final closed = Completer<void>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = _TdlibReceiveHub.updates.listen((obj) {
      final cid = (obj['@client_id'] as num?)?.toInt();
      if (cid != null && cid != _clientId) return;
      if (obj['@type']?.toString() != 'updateAuthorizationState') return;
      final state = obj['authorization_state'];
      final type = state is Map ? state['@type']?.toString() : null;
      if (type == 'authorizationStateClosed' && !closed.isCompleted) {
        closed.complete();
      }
    });
    try {
      _ffi.send(_clientId, jsonEncode({'@type': 'close'}));
      await closed.future.timeout(const Duration(seconds: 3));
    } catch (_) {
    } finally {
      await sub.cancel();
    }
    await _clearPersistedClientId();
    await _updates.close();
  }
}
