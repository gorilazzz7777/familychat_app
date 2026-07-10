import 'dart:async';
import 'dart:html' as html;

Future<void> ensureFcmServiceWorkerRegistered() async {
  final swContainer = html.window.navigator.serviceWorker;
  if (swContainer == null) return;

  const swUrl = '/app/firebase-messaging-sw.js';

  html.ServiceWorkerRegistration? registration;
  try {
    registration = await swContainer.register(swUrl);
  } catch (_) {
    try {
      registration = await swContainer.register('firebase-messaging-sw.js');
    } catch (_) {
      return;
    }
  }

  await _waitForActivation(registration);
  try {
    await swContainer.ready.timeout(const Duration(seconds: 10));
  } catch (_) {}
}

Future<void> _waitForActivation(html.ServiceWorkerRegistration reg) async {
  if (reg.active != null) return;

  final installing = reg.installing ?? reg.waiting;
  if (installing == null) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return;
  }

  final completer = Completer<void>();
  void onStateChange(html.Event _) {
    if (installing.state == 'activated') {
      installing.removeEventListener('statechange', onStateChange);
      if (!completer.isCompleted) completer.complete();
    }
  }

  installing.addEventListener('statechange', onStateChange);
  await completer.future.timeout(
    const Duration(seconds: 8),
    onTimeout: () {},
  );
}
