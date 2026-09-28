import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _TdCreateClientIdC = Int32 Function();
typedef _TdSendC = Void Function(Int32, Pointer<Utf8>);
typedef _TdReceiveC = Pointer<Utf8> Function(Double);
typedef _TdExecuteC = Pointer<Utf8> Function(Pointer<Utf8>);

/// Low-level FFI to vendored `libtdjson.so` (Android jniLibs).
class TdlibFfi {
  TdlibFfi._(this.library)
      : createClientId = library
            .lookup<NativeFunction<_TdCreateClientIdC>>('td_create_client_id')
            .asFunction(),
        _send = library
            .lookup<NativeFunction<_TdSendC>>('td_send')
            .asFunction(),
        _receive = library
            .lookup<NativeFunction<_TdReceiveC>>('td_receive')
            .asFunction(),
        _execute = library
            .lookup<NativeFunction<_TdExecuteC>>('td_execute')
            .asFunction();

  final DynamicLibrary library;
  final int Function() createClientId;
  final void Function(int, Pointer<Utf8>) _send;
  final Pointer<Utf8> Function(double) _receive;
  final Pointer<Utf8> Function(Pointer<Utf8>) _execute;

  static bool _logConfigured = false;

  static TdlibFfi open() {
    if (!Platform.isAndroid) {
      throw UnsupportedError('TDLib MVP is Android-only for now');
    }
    final ffi = TdlibFfi._(DynamicLibrary.open('libtdjson.so'));
    // Default TDLib logs every td_receive poll (DLTD Begin/End wait) — too noisy.
    // 0=fatal, 1=errors, 2=warnings, 3=info.
    if (!_logConfigured) {
      _logConfigured = true;
      ffi.execute(
        '{"@type":"setLogVerbosityLevel","new_verbosity_level":1}',
      );
    }
    return ffi;
  }

  void send(int clientId, String request) {
    final ptr = request.toNativeUtf8();
    try {
      _send(clientId, ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  String? receive(double timeout) {
    final ptr = _receive(timeout);
    if (ptr.address == 0) return null;
    return ptr.toDartString();
  }

  String execute(String request) {
    final ptr = request.toNativeUtf8();
    try {
      final out = _execute(ptr);
      if (out.address == 0) return '{}';
      return out.toDartString();
    } finally {
      malloc.free(ptr);
    }
  }
}
