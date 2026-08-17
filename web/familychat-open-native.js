/* iOS/Android: web-push открывает PWA — пробуем сразу уйти в натив. */
(function (global) {
  var pendingPayload = null;
  var lastDeep = '';
  var lastOpenAt = 0;
  var openBarEl = null;

  function isAndroid() {
    return /Android/i.test(navigator.userAgent || '');
  }

  function isMobileNative() {
    var ua = navigator.userAgent || '';
    if (/iPhone|iPad|iPod|Android/i.test(ua)) return true;
    return /Macintosh/i.test(ua) && navigator.maxTouchPoints > 1;
  }

  function skipNative() {
    try {
      return new URLSearchParams(location.search).get('fc_web') === '1';
    } catch (e) {
      return false;
    }
  }

  function ensureOpenBar() {
    if (openBarEl || !document.body) return;
    openBarEl = document.createElement('button');
    openBarEl.type = 'button';
    openBarEl.id = 'fc-open-native-bar';
    openBarEl.textContent = 'Открыть Family Space';
    openBarEl.setAttribute('style', [
      'display:none',
      'position:fixed',
      'left:12px',
      'right:12px',
      'top:max(12px, env(safe-area-inset-top))',
      'z-index:2147483647',
      'padding:14px 16px',
      'border:0',
      'border-radius:14px',
      'background:#1a73e8',
      'color:#fff',
      'font:600 16px/1.2 system-ui,-apple-system,sans-serif',
      'box-shadow:0 8px 24px rgba(26,115,232,.35)',
    ].join(';'));
    openBarEl.addEventListener('click', function () {
      if (!lastDeep) return;
      location.href = lastDeep;
    });
    document.body.appendChild(openBarEl);
  }

  function showOpenBar(deep) {
    lastDeep = deep || lastDeep;
    ensureOpenBar();
    if (!openBarEl || !lastDeep) return;
    openBarEl.style.display = 'block';
  }

  function deepLinkFromParams(params) {
    var isCall = params.get('fc_call') === '1';
    var isChat = params.get('fc_chat') === '1';
    if (!isCall && !isChat) return null;
    if (isCall && !(params.get('session_id') && params.get('thread_id'))) return null;
    if (!isCall && !params.get('thread_id')) return null;
    var host = isCall ? 'call' : 'chat';
    var q = params.toString();
    if (isAndroid()) {
      var web = location.origin + '/app/?' + q + '&fc_web=1';
      return (
        'intent://' +
        host +
        '?' +
        q +
        '#Intent;scheme=familychat;package=com.familychat.familychat_app;S.browser_fallback_url=' +
        encodeURIComponent(web) +
        ';end'
      );
    }
    return 'familychat://' + host + '?' + q;
  }

  function deepLinkFromPushData(data) {
    if (!data || typeof data !== 'object') return null;
    var p = new URLSearchParams();
    if (data.type === 'familychat_call') {
      p.set('fc_call', '1');
      p.set('session_id', String(data.session_id || ''));
      p.set('thread_id', String(data.thread_id || ''));
      if (data.caller_user_id) p.set('caller_user_id', String(data.caller_user_id));
      if (data.caller_name) p.set('caller_name', String(data.caller_name));
    } else if (data.thread_id) {
      p.set('fc_chat', '1');
      p.set('thread_id', String(data.thread_id));
      if (data.message_id) p.set('message_id', String(data.message_id));
      if (data.thread_title) p.set('thread_title', String(data.thread_title));
      if (data.thread_kind) p.set('thread_kind', String(data.thread_kind));
      if (data.peer_user_id) p.set('peer_user_id', String(data.peer_user_id));
    } else {
      return null;
    }
    return deepLinkFromParams(p);
  }

  function tryOpenNativeApp(data) {
    if (!isMobileNative()) return false;
    if (skipNative()) return false;
    var deep = data
      ? deepLinkFromPushData(data)
      : deepLinkFromParams(new URLSearchParams(location.search));
    if (!deep) return false;
    var now = Date.now();
    if (deep === lastDeep && now - lastOpenAt < 1500) {
      showOpenBar(deep);
      return false;
    }
    lastDeep = deep;
    lastOpenAt = now;
    showOpenBar(deep);
    if (document.visibilityState !== 'visible') return false;
    try {
      location.href = deep;
      return true;
    } catch (e) {
      return false;
    }
  }

  function onPushPayload(data) {
    if (!data || typeof data !== 'object') return;
    pendingPayload = data;
    tryOpenNativeApp(data);
  }

  function askSwPending() {
    if (!navigator.serviceWorker) return;
    navigator.serviceWorker.getRegistrations().then(function (regs) {
      var fcm = null;
      for (var i = 0; i < regs.length; i++) {
        var worker = regs[i].active || regs[i].waiting || regs[i].installing;
        var url = (worker && worker.scriptURL) || '';
        if (url.indexOf('firebase-messaging-sw.js') !== -1) {
          fcm = regs[i].active || regs[i].waiting;
        }
      }
      if (!fcm) return;
      var ch = new MessageChannel();
      ch.port1.onmessage = function (event) {
        var payload = event.data && event.data.payload;
        if (payload) onPushPayload(payload);
      };
      fcm.postMessage({ type: 'familychat_get_pending_native' }, [ch.port2]);
    }).catch(function () {});
  }

  global.familyChatTryOpenNativeApp = tryOpenNativeApp;

  try {
    localStorage.removeItem('fc_native_debug_log');
  } catch (e) {}

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ensureOpenBar);
  } else {
    ensureOpenBar();
  }
  tryOpenNativeApp(null);
  askSwPending();
  setTimeout(askSwPending, 600);
  setTimeout(askSwPending, 2000);
  if (navigator.serviceWorker && navigator.serviceWorker.ready) {
    navigator.serviceWorker.ready.then(function () {
      askSwPending();
    }).catch(function () {});
  }

  if (navigator.serviceWorker) {
    navigator.serviceWorker.addEventListener('message', function (event) {
      var data = event.data || {};
      if (!data || typeof data !== 'object') return;
      if (data.pending && data.payload) {
        onPushPayload(data.payload);
        return;
      }
      if (data.type === 'familychat_chat' || data.type === 'familychat_call') {
        onPushPayload(data);
      }
    });
  }

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState !== 'visible') return;
    if (pendingPayload) {
      tryOpenNativeApp(pendingPayload);
      return;
    }
    askSwPending();
  });

  window.addEventListener('pageshow', function () {
    if (pendingPayload && document.visibilityState === 'visible') {
      tryOpenNativeApp(pendingPayload);
    }
  });
})(window);
