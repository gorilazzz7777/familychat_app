/* FCM service worker. Значения подставляются при CI-сборке. */
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'REPLACE_FIREBASE_WEB_API_KEY',
  appId: 'REPLACE_FIREBASE_WEB_APP_ID',
  messagingSenderId: 'REPLACE_FIREBASE_MESSAGING_SENDER_ID',
  projectId: 'REPLACE_FIREBASE_PROJECT_ID',
});

const CALL_TAG_PREFIX = 'familychat-call-';
const CHAT_PREVIEW_CACHE = 'familychat-chat-preview-v1';
const CHAT_PREVIEW_MAX_LINES = 7;
const CHAT_PREVIEW_MAX_CHARS = 900;
const CALL_RING_MS = 3000;
const PENDING_CACHE = 'familychat-pending-native';
const PENDING_URL = '/app/__pending_native_open';
const PENDING_TTL_MS = 90 * 1000;
const activeCallTimers = new Map();

self.addEventListener('install', function (event) {
  event.waitUntil(self.skipWaiting());
});

function callTag(sessionId) {
  return CALL_TAG_PREFIX + String(sessionId || '0');
}

function serializeCallData(data) {
  return {
    type: 'familychat_call',
    session_id: String(data.session_id || ''),
    thread_id: String(data.thread_id || ''),
    caller_user_id: String(data.caller_user_id || ''),
    caller_name: String(data.caller_name || data.body || 'Family Chat'),
    title: String(data.title || 'Входящий звонок'),
    body: String(data.body || data.caller_name || 'Family Chat'),
  };
}

function storePendingCall(data) {
  try {
    sessionStorage.setItem(
      'familychat_pending_call',
      JSON.stringify(serializeCallData(data)),
    );
  } catch (e) {}
}

function buildCallLaunchUrl(data) {
  var d = serializeCallData(data);
  var q = new URLSearchParams();
  q.set('fc_call', '1');
  q.set('session_id', d.session_id);
  q.set('thread_id', d.thread_id);
  q.set('caller_user_id', d.caller_user_id);
  q.set('caller_name', d.caller_name);
  return '/app/?' + q.toString();
}

function callNotificationOptions(data, notification) {
  const title = (notification && notification.title) || data.title || 'Входящий звонок';
  const body =
    (notification && notification.body) ||
    data.body ||
    data.caller_name ||
    'Family Chat';
  return {
    title: title,
    options: {
      body: body,
      icon: '/app/icons/Icon-192.png',
      badge: '/app/icons/Icon-192.png',
      tag: callTag(data.session_id),
      renotify: true,
      requireInteraction: true,
      silent: false,
      vibrate: [400, 200, 400, 200, 400, 200, 400],
      data: serializeCallData(data),
    },
  };
}

async function showCallNotification(data, notification) {
  const built = callNotificationOptions(data, notification);
  await self.registration.showNotification(built.title, built.options);
}

function startCallRing(data, notification) {
  const sessionId = String(data.session_id || '');
  if (!sessionId) {
    return showCallNotification(data, notification);
  }
  if (activeCallTimers.has(sessionId)) {
    return showCallNotification(data, notification);
  }
  showCallNotification(data, notification);
  const timer = setInterval(function () {
    showCallNotification(data, notification);
  }, CALL_RING_MS);
  activeCallTimers.set(sessionId, timer);
}

function stopCallRing(sessionId) {
  const id = String(sessionId || '');
  const timer = activeCallTimers.get(id);
  if (timer) {
    clearInterval(timer);
    activeCallTimers.delete(id);
  }
  return self.registration
    .getNotifications({ tag: callTag(id) })
    .then(function (list) {
      list.forEach(function (notification) {
        notification.close();
      });
    });
}

function savePendingNative(serialized, fromTap) {
  var payload = Object.assign({}, serialized, {
    opened_from_tap: !!fromTap,
    saved_at: Date.now(),
  });
  return caches.open(PENDING_CACHE).then(function (cache) {
    return cache.put(
      PENDING_URL,
      new Response(JSON.stringify(payload), {
        headers: { 'Content-Type': 'application/json' },
      }),
    );
  }).catch(function () {});
}

function takePendingNative() {
  return caches.open(PENDING_CACHE).then(function (cache) {
    return cache.match(PENDING_URL).then(function (res) {
      if (!res) return null;
      return res.json().then(function (data) {
        return cache.delete(PENDING_URL).then(function () {
          var savedAt = Number(data && data.saved_at) || 0;
          if (!savedAt || Date.now() - savedAt > PENDING_TTL_MS) return null;
          return data;
        });
      });
    });
  }).catch(function () {
    return null;
  });
}

function postToWindowClients(serialized) {
  var msg = Object.assign({ source: 'familychat-fcm-sw' }, serialized);
  return clients
    .matchAll({ type: 'window', includeUncontrolled: true })
    .then(function (list) {
      for (var i = 0; i < list.length; i++) {
        try {
          list[i].postMessage(msg);
        } catch (e) {}
      }
      return list;
    });
}

function rememberPushPayload(data, notification) {
  if (data.type === 'familychat_call') {
    var callData = serializeCallData(data);
    return savePendingNative(callData, false).then(function () {
      return postToWindowClients(callData);
    });
  }
  if (!isChatPush(data)) return Promise.resolve();
  var serialized = serializeChatData(data);
  if (notification) {
    if (notification.title) serialized.title = String(notification.title);
    if (notification.body) serialized.body = String(notification.body);
  }
  return savePendingNative(serialized, false).then(function () {
    return postToWindowClients(serialized);
  });
}

function openNativeOrWeb(url, serialized) {
  serialized.opened_from_tap = true;
  var abs;
  try {
    abs = new URL(url, self.registration.scope).href;
  } catch (e) {
    abs = url;
  }
  return savePendingNative(serialized, true)
    .then(function () {
      return postToWindowClients(serialized);
    })
    .then(function (list) {
      if (!list.length) {
        return clients.openWindow(abs);
      }
      var client = list[0];
      var nav =
        typeof client.navigate === 'function'
          ? client.navigate(abs).catch(function () {
              return client;
            })
          : Promise.resolve(client);
      return nav.then(function (opened) {
        var target = opened || client;
        if (target && 'focus' in target) return target.focus();
        return target;
      });
    });
}

function focusClientWithCallData(data) {
  var serialized = serializeCallData(data);
  storePendingCall(serialized);
  return openNativeOrWeb(buildCallLaunchUrl(serialized), serialized);
}

function unwrapPushData(raw) {
  var data = Object.assign({}, raw || {});
  var nested = data.FCM_MSG;
  if (nested && typeof nested === 'object') {
    var inner = nested.data;
    if (inner && typeof inner === 'object') {
      data = Object.assign({}, inner, data);
    }
  }
  return data;
}

function isChatPush(data) {
  var type = String(data.type || '');
  if (type === 'familychat_call' || type === 'familychat_calendar_reminder') {
    return false;
  }
  if (type === 'familychat_chat') return true;
  var threadId = String(data.thread_id || '');
  if (!threadId) return false;
  return String(data.deeplink || '') === 'chat' || type === '';
}

function serializeChatData(data) {
  return {
    type: 'familychat_chat',
    deeplink: 'chat',
    thread_id: String(data.thread_id || ''),
    message_id: String(data.message_id || ''),
    thread_title: String(data.thread_title || ''),
    thread_kind: String(data.thread_kind || ''),
    peer_user_id: String(data.peer_user_id || ''),
    title: String(data.title || ''),
    body: String(data.body || ''),
  };
}

function isGroupThread(data) {
  var kind = String(data.thread_kind || '').toLowerCase();
  if (kind === 'direct' || kind === 'dm' || kind === 'private') return false;
  if (
    kind === 'family' ||
    kind === 'group' ||
    kind === 'channel' ||
    kind === 'family_chat'
  ) {
    return true;
  }
  return !String(data.peer_user_id || '').trim();
}

function splitSenderPrefix(body) {
  var colon = body.indexOf(': ');
  if (colon <= 0 || colon > 40) return null;
  var prefix = body.slice(0, colon).trim();
  if (!prefix || prefix.indexOf('\n') >= 0) return null;
  var rest = body.slice(colon + 2).trim();
  if (!rest) return null;
  return { sender: prefix, text: rest };
}

function previewLineFromPush(data, title, body) {
  var previewBody = String(body || data.body || '').trim();
  if (!previewBody) return null;
  var isGroup = isGroupThread(data);
  var threadTitle = String(data.thread_title || '').trim();
  var pushTitle = String(title || data.title || '').trim();
  var sender = String(data.sender_name || '').trim();
  if (!sender && isGroup) {
    if (pushTitle && pushTitle !== threadTitle) {
      sender = pushTitle;
    } else {
      var split = splitSenderPrefix(previewBody);
      if (split) {
        sender = split.sender;
        previewBody = split.text;
      }
    }
  }
  return {
    message_id: String(data.message_id || ''),
    sender: sender,
    text: previewBody,
    timestamp_ms: Date.now(),
  };
}

function trimPreviewLines(lines) {
  var out = lines.slice();
  if (out.length > CHAT_PREVIEW_MAX_LINES) {
    out = out.slice(out.length - CHAT_PREVIEW_MAX_LINES);
  }
  while (out.length > 0) {
    var total = 0;
    for (var i = 0; i < out.length; i++) {
      total += String(out[i].text || '').length;
      if (out[i].sender) total += String(out[i].sender).length + 2;
      total += 1;
    }
    if (total <= CHAT_PREVIEW_MAX_CHARS) break;
    out = out.slice(1);
  }
  return out;
}

function appendPreviewLine(lines, incoming) {
  var out = lines.slice();
  if (incoming.message_id) {
    for (var i = 0; i < out.length; i++) {
      if (String(out[i].message_id) === String(incoming.message_id)) {
        out[i] = incoming;
        return out;
      }
    }
  }
  out.push(incoming);
  return trimPreviewLines(out);
}

function previewExpandedBody(lines, isGroup) {
  if (!lines.length) return 'Новое сообщение';
  return lines
    .map(function (line) {
      if (isGroup && line.sender) return line.sender + ': ' + line.text;
      return line.text;
    })
    .join('\n');
}

function previewCollapsedBody(lines, isGroup) {
  if (!lines.length) return 'Новое сообщение';
  var last = lines[lines.length - 1];
  if (isGroup && last.sender) return last.sender + ': ' + last.text;
  return last.text;
}

function loadChatPreview(threadId) {
  return caches.open(CHAT_PREVIEW_CACHE).then(function (cache) {
    return cache.match('preview-' + threadId).then(function (res) {
      if (!res) return [];
      return res.json().then(function (parsed) {
        return Array.isArray(parsed) ? parsed : [];
      });
    });
  });
}

function saveChatPreview(threadId, lines) {
  return caches.open(CHAT_PREVIEW_CACHE).then(function (cache) {
    return cache.put(
      'preview-' + threadId,
      new Response(JSON.stringify(lines), {
        headers: { 'Content-Type': 'application/json' },
      }),
    );
  });
}

function clearChatPreview(threadId) {
  return caches.open(CHAT_PREVIEW_CACHE).then(function (cache) {
    return cache.delete('preview-' + threadId);
  });
}

function buildChatLaunchUrl(data) {
  var d = serializeChatData(data);
  var q = new URLSearchParams();
  q.set('fc_chat', '1');
  q.set('thread_id', d.thread_id);
  if (d.message_id) q.set('message_id', d.message_id);
  if (d.thread_title) q.set('thread_title', d.thread_title);
  if (d.thread_kind) q.set('thread_kind', d.thread_kind);
  if (d.peer_user_id) q.set('peer_user_id', d.peer_user_id);
  return '/app/?' + q.toString();
}

function showChatNotification(data, notification) {
  var d = serializeChatData(data);
  var pushTitle =
    (notification && notification.title) || d.title || 'Family Space';
  var pushBody =
    (notification && notification.body) || d.body || 'Новое сообщение';
  if (!d.thread_id) return Promise.resolve();
  var isGroup = isGroupThread(d);
  var threadTitle = String(d.thread_title || '').trim();
  var title = isGroup
    ? threadTitle || pushTitle || 'Family Space'
    : threadTitle || pushTitle || 'Family Space';
  var incoming = previewLineFromPush(d, pushTitle, pushBody);
  return loadChatPreview(d.thread_id)
    .then(function (lines) {
      if (incoming) lines = appendPreviewLine(lines, incoming);
      lines = trimPreviewLines(lines);
      return saveChatPreview(d.thread_id, lines).then(function () {
        return lines;
      });
    })
    .then(function (lines) {
      var body =
        lines.length > 1
          ? previewExpandedBody(lines, isGroup)
          : previewCollapsedBody(lines, isGroup);
      return self.registration.showNotification(title, {
        body: body,
        icon: '/app/icons/Icon-192.png',
        badge: '/app/icons/Icon-192.png',
        tag: 'familychat-chat-' + d.thread_id,
        renotify: true,
        data: d,
      });
    });
}

function focusClientWithChatData(data) {
  var serialized = serializeChatData(data);
  serialized.opened_from_tap = true;
  return openNativeOrWeb(buildChatLaunchUrl(serialized), serialized);
}

const messaging = firebase.messaging();

function rawNotification(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (raw.notification && typeof raw.notification === 'object') return raw.notification;
  return null;
}

messaging.onBackgroundMessage(function (payload) {
  var data = unwrapPushData(Object.assign({}, payload.data || {}));
  if (data.type === 'familychat_call_stop') {
    return stopCallRing(data.session_id);
  }
  if (data.type === 'familychat_call') {
    return Promise.all([
      rememberPushPayload(data, payload.notification),
      startCallRing(data, payload.notification),
    ]);
  }
  if (isChatPush(data)) {
    var shown = payload.notification
      ? Promise.resolve()
      : showChatNotification(data, null);
    return Promise.all([rememberPushPayload(data, payload.notification), shown]);
  }
});

self.addEventListener('push', function (event) {
  var data = {};
  var raw = {};
  try {
    raw = event.data ? event.data.json() : {};
    data = unwrapPushData(Object.assign({}, raw.data || raw));
  } catch (e) {
    return;
  }
  if (data.type === 'familychat_call_stop') return;
  if (data.type === 'familychat_call' || isChatPush(data)) {
    event.waitUntil(rememberPushPayload(data, rawNotification(raw)));
  }
});

self.addEventListener('notificationclick', function (event) {
  var data = unwrapPushData((event.notification && event.notification.data) || {});
  event.notification.close();
  if (data.type === 'familychat_call') {
    stopCallRing(data.session_id);
    event.waitUntil(focusClientWithCallData(data));
    return;
  }
  if (isChatPush(data)) {
    event.waitUntil(
      clearChatPreview(String(data.thread_id || '')).then(function () {
        return focusClientWithChatData(data);
      }),
    );
    return;
  }
  var tag = event.notification && event.notification.tag;
  if (tag && String(tag).indexOf('familychat-chat-') === 0) {
    var id = String(tag).slice('familychat-chat-'.length);
    if (id) {
      event.waitUntil(
        focusClientWithChatData({ type: 'familychat_chat', thread_id: id }),
      );
    }
  }
});

self.addEventListener('message', function (event) {
  var data = event.data || {};
  if (data.type === 'familychat_call_stop') {
    stopCallRing(data.session_id);
    return;
  }
  if (data.type === 'familychat_get_pending_native') {
    event.waitUntil(
      takePendingNative().then(function (payload) {
        var reply = {
          source: 'familychat-fcm-sw',
          pending: true,
          payload: payload,
        };
        if (event.ports && event.ports[0]) {
          event.ports[0].postMessage(reply);
        } else if (event.source) {
          event.source.postMessage(reply);
        }
      }),
    );
  }
});
