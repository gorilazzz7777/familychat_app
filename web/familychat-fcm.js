// FCM getToken для Flutter web (обход FlutterFire на iOS PWA). Конфиг — при CI-сборке.
(function () {
  var config = {
    apiKey: 'REPLACE_FIREBASE_WEB_API_KEY',
    appId: 'REPLACE_FIREBASE_WEB_APP_ID',
    messagingSenderId: 'REPLACE_FIREBASE_MESSAGING_SENDER_ID',
    projectId: 'REPLACE_FIREBASE_PROJECT_ID',
  };

  var swUrl = '/familychat/app/firebase-messaging-sw.js';

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
})();
