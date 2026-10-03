/// Web / non-IO stub — TDLib native client is Android/iOS.
class TdlibFfi {
  TdlibFfi._();

  static TdlibFfi open() {
    throw UnsupportedError('TDLib is not available on this platform');
  }

  int createClientId() => 0;

  void send(int clientId, String request) {}

  String? receive(double timeout) => null;

  String execute(String request) => '{}';
}
