/* iOS/Android: web-push всегда открывает PWA. Сразу пробуем натив. */
(function (global) {
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
    if (!isMobileNative() || skipNative()) return false;
    var deep = data
      ? deepLinkFromPushData(data)
      : deepLinkFromParams(new URLSearchParams(location.search));
    if (!deep) return false;
    try {
      location.href = deep;
      return true;
    } catch (e) {
      return false;
    }
  }

  global.familyChatTryOpenNativeApp = tryOpenNativeApp;
  tryOpenNativeApp(null);
})(window);
