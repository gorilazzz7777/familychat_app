/* FCM service worker. Значения подставляются при CI-сборке. */
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'REPLACE_FIREBASE_WEB_API_KEY',
  appId: 'REPLACE_FIREBASE_WEB_APP_ID',
  messagingSenderId: 'REPLACE_FIREBASE_MESSAGING_SENDER_ID',
  projectId: 'REPLACE_FIREBASE_PROJECT_ID',
});

firebase.messaging();
