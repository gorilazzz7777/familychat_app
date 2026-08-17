/* iOS/Android: web-push всегда открывает PWA. Сразу пробуем натив + отладка на экране. */
(function (global) {
  var DEBUG_VERSION = 'native-debug-2026-08-17';
  var logs = [];

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

  function displayMode() {
    try {
      if (window.matchMedia('(display-mode: standalone)').matches) return 'standalone';
      if (window.matchMedia('(display-mode: fullscreen)').matches) return 'fullscreen';
      if (window.navigator.standalone) return 'ios-standalone';
    } catch (e) {}
    return 'browser';
  }

  function log(line) {
    var row = new Date().toISOString().slice(11, 23) + ' ' + line;
    logs.push(row);
    if (logs.length > 30) logs.shift();
    try {
      localStorage.setItem('fc_native_debug_log', logs.join('\n'));
    } catch (e) {}
    render();
  }

  function panelEl() {
    return document.getElementById('fc-native-debug');
  }

  function ensurePanel() {
    if (panelEl()) return;
    if (!document.body) {
      document.addEventListener('DOMContentLoaded', ensurePanel);
      return;
    }
    var el = document.createElement('div');
    el.id = 'fc-native-debug';
    el.setAttribute('style', [
      'position:fixed',
      'left:8px',
      'right:8px',
      'bottom:8px',
      'z-index:2147483647',
      'max-height:48vh',
      'overflow:auto',
      'padding:10px 12px',
      'border-radius:12px',
      'background:#1a1a1a',
      'color:#ffe082',
      'font:12px/1.35 ui-monospace,Menlo,monospace',
      'white-space:pre-wrap',
      'word-break:break-all',
      'box-shadow:0 8px 24px rgba(0,0,0,.35)',
    ].join(';'));
    document.body.appendChild(el);
    render();
  }

  function render() {
    var el = panelEl();
    if (!el) return;
    var params = new URLSearchParams(location.search);
    var header = [
      'DEBUG ' + DEBUG_VERSION,
      'url: ' + location.href,
      'mode: ' + displayMode(),
      'mobile: ' + isMobileNative() + ' android: ' + isAndroid(),
      'fc_chat=' + (params.get('fc_chat') || '-') +
        ' fc_call=' + (params.get('fc_call') || '-') +
        ' thread=' + (params.get('thread_id') || '-') +
        ' fc_web=' + (params.get('fc_web') || '-'),
      '---',
    ].join('\n');
    el.textContent = header + '\n' + logs.join('\n');
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
    log('tryOpenNative source=' + (data ? 'push-data' : 'url'));
    if (!isMobileNative()) {
      log('skip: not iOS/Android');
      return false;
    }
    if (skipNative()) {
      log('skip: fc_web=1');
      return false;
    }
    var deep = data
      ? deepLinkFromPushData(data)
      : deepLinkFromParams(new URLSearchParams(location.search));
    if (!deep) {
      log('skip: no fc_chat/fc_call+thread in URL/data');
      return false;
    }
    log('open ' + deep);
    try {
      location.href = deep;
      log('location.href assigned');
      return true;
    } catch (e) {
      log('error: ' + e);
      return false;
    }
  }

  global.familyChatTryOpenNativeApp = tryOpenNativeApp;
  global.familyChatNativeDebugLog = log;

  try {
    var saved = localStorage.getItem('fc_native_debug_log');
    if (saved) logs = saved.split('\n').slice(-20);
  } catch (e) {}

  log('script loaded');
  ensurePanel();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ensurePanel);
  }
  tryOpenNativeApp(null);

  document.addEventListener('visibilitychange', function () {
    log('visibility=' + document.visibilityState);
  });
})(window);
