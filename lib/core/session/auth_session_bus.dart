import 'dart:async';

class AuthSessionBus {
  AuthSessionBus._();
  static final AuthSessionBus instance = AuthSessionBus._();

  final _accessRefreshed = StreamController<String>.broadcast();
  final _sessionInvalidated = StreamController<void>.broadcast();

  Stream<String> get onAccessRefreshed => _accessRefreshed.stream;
  Stream<void> get onSessionInvalidated => _sessionInvalidated.stream;

  void emitAccessRefreshed(String access) {
    if (!_accessRefreshed.isClosed) {
      _accessRefreshed.add(access);
    }
  }

  void emitSessionInvalidated() {
    if (!_sessionInvalidated.isClosed) {
      _sessionInvalidated.add(null);
    }
  }
}
