// FCM getToken для Flutter web (обход FlutterFire на iOS PWA). Конфиг — при CI-сборке.
(function () {
  var config = {
    apiKey: 'REPLACE_FIREBASE_WEB_API_KEY',
    appId: 'REPLACE_FIREBASE_WEB_APP_ID',
    messagingSenderId: 'REPLACE_FIREBASE_MESSAGING_SENDER_ID',
    projectId: 'REPLACE_FIREBASE_PROJECT_ID',
  };

  var swUrl = '/app/firebase-messaging-sw.js';
  var foregroundWired = false;

  async function getMessagingServiceWorkerRegistration() {
    var registrations = await navigator.serviceWorker.getRegistrations();
    for (var i = 0; i < registrations.length; i++) {
      var reg = registrations[i];
      var scriptUrl = (reg.active && reg.active.scriptURL) ||
        (reg.installing && reg.installing.scriptURL) ||
        (reg.waiting && reg.waiting.scriptURL) ||
        '';
      if (scriptUrl.indexOf('firebase-messaging-sw.js') !== -1) {
        return reg;
      }
    }
    return navigator.serviceWorker.register(swUrl);
  }

  function postToApp(data) {
    window.postMessage(
      Object.assign({ source: 'familychat-fcm' }, data),
      window.location.origin,
    );
  }

  window.familyChatGetFcmToken = async function (vapidKey) {
    if (typeof firebase === 'undefined') {
      throw new Error('firebase JS SDK not loaded');
    }
    if (!firebase.apps.length) {
      firebase.initializeApp(config);
    }

    var registration = await getMessagingServiceWorkerRegistration();
    await navigator.serviceWorker.ready;

    return firebase.messaging().getToken({
      vapidKey: vapidKey,
      serviceWorkerRegistration: registration,
    });
  };

  window.familyChatInitFcmForeground = function () {
    if (foregroundWired) return;
    if (typeof firebase === 'undefined') return;
    if (!firebase.apps.length) {
      firebase.initializeApp(config);
    }
    foregroundWired = true;
    firebase.messaging().onMessage(function (payload) {
      var data = Object.assign({}, payload.data || {});
      if (payload.notification) {
        if (!data.title && payload.notification.title) {
          data.title = payload.notification.title;
        }
        if (!data.body && payload.notification.body) {
          data.body = payload.notification.body;
        }
      }
      if (data.type === 'familychat_call' || data.type === 'familychat_chat') {
        postToApp(data);
      }
    });
  };
})();
