import 'dart:async';
import 'dart:js' as js;
import 'package:js/js.dart' show allowInterop;

Future<String?> getWebFcmToken(String vapidKey) async {
  final fn = js.context['familyChatGetFcmToken'];
  if (fn == null) {
    throw StateError(
      'familyChatGetFcmToken не найден — проверьте familychat-fcm.js в сборке',
    );
  }

  final completer = Completer<String?>();
  final promise = fn.callMethod('call', [js.context, vapidKey]);
  promise.callMethod('then', [
    allowInterop((result) {
      if (result == null) {
        completer.complete(null);
        return;
      }
      final value = result.toString().trim();
      completer.complete(value.isEmpty ? null : value);
    }),
  ]);
  promise.callMethod('catch', [
    allowInterop((error) {
      completer.completeError(error ?? 'getToken failed');
    }),
  ]);

  return completer.future;
}
