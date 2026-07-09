import 'dart:async';
import 'dart:js' as js;

Timer? _timer;
js.JsObject? _context;

Future<void> startWebCallRingtone() async {
  stopWebCallRingtone();
  final ctor = js.context['AudioContext'] ?? js.context['webkitAudioContext'];
  if (ctor == null) return;
  _context = js.JsObject(ctor as js.JsFunction);

  void beep() {
    final ctx = _context;
    if (ctx == null) return;
    final oscillator = ctx.callMethod('createOscillator');
    final gain = ctx.callMethod('createGain');
    oscillator.callMethod('connect', [gain]);
    gain.callMethod('connect', [ctx['destination']]);
    oscillator['frequency']['value'] = 440;
    gain['gain']['value'] = 0.25;
    final now = ctx['currentTime'];
    oscillator.callMethod('start', [now]);
    oscillator.callMethod('stop', [now + 0.45]);
  }

  beep();
  _timer = Timer.periodic(const Duration(milliseconds: 1200), (_) => beep());
}

void stopWebCallRingtone() {
  _timer?.cancel();
  _timer = null;
  final ctx = _context;
  _context = null;
  if (ctx != null) {
    ctx.callMethod('close');
  }
}
