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
const CALL_RING_MS = 3000;
const activeCallTimers = new Map();

function callTag(sessionId) {
  return CALL_TAG_PREFIX + String(sessionId || '0');
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
      data: Object.assign({}, data, { type: 'familychat_call' }),
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

function focusClientWithCallData(data) {
  return clients
    .matchAll({ type: 'window', includeUncontrolled: true })
    .then(function (list) {
      for (var i = 0; i < list.length; i++) {
        var client = list[i];
        client.postMessage(
          Object.assign({ source: 'familychat-fcm-sw' }, data),
        );
        if ('focus' in client) {
          return client.focus();
        }
      }
      return clients.openWindow('/app/');
    });
}

const messaging = firebase.messaging();

messaging.onBackgroundMessage(function (payload) {
  var data = Object.assign({}, payload.data || {});
  if (data.type === 'familychat_call') {
    return startCallRing(data, payload.notification);
  }
});

self.addEventListener('notificationclick', function (event) {
  var data = (event.notification && event.notification.data) || {};
  if (data.type !== 'familychat_call') {
    return;
  }
  event.notification.close();
  stopCallRing(data.session_id);
  event.waitUntil(focusClientWithCallData(data));
});

self.addEventListener('message', function (event) {
  var data = event.data || {};
  if (data.type === 'familychat_call_stop') {
    stopCallRing(data.session_id);
  }
});
