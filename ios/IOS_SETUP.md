# Family Chat — настройка iOS

После правок в репозитории на Mac выполните:

```bash
cd familychat_app
flutter pub get
dart run vosk_flutter_service install -t ios
cd ios
pod install
open Runner.xcworkspace
```

Если `pod install` ругается на `share_handler_ios_models` — в `Podfile` уже есть явный путь к `.symlinks/plugins/share_handler_ios/ios/Models`. Сначала выполните `flutter pub get` из корня проекта (чтобы появился `.symlinks`), затем снова `pod install`.

## Firebase / Push (обязательно для уведомлений)

1. В [Firebase Console](https://console.firebase.google.com/) → проект `familychat-53a64` добавьте iOS-приложение с Bundle ID `com.familychat.familychatApp`.
2. Скачайте `GoogleService-Info.plist` и положите в `ios/Runner/`.
3. В Apple Developer: включите Push Notifications для App ID, загрузите APNs key в Firebase → Project settings → Cloud Messaging.
4. В Xcode → Runner → Signing & Capabilities: Push Notifications, Associated Domains, App Groups (`group.com.familychat.familychatApp`).
5. Для TestFlight/App Store в `Runner.entitlements` смените `aps-environment` на `production`.

Либо передайте dart-define при сборке:

- `FIREBASE_IOS_API_KEY`
- `FIREBASE_IOS_APP_ID`
- `FIREBASE_MESSAGING_SENDER_ID`
- `FIREBASE_PROJECT_ID`
- `FIREBASE_STORAGE_BUCKET` (опционально)

## Share Extension («Поделиться» → Family Chat)

Файлы уже в `ios/ShareExtension/`. В Xcode:

1. File → New → Target → Share Extension, имя `ShareExtension`.
2. Замените сгенерированные файлы содержимым из `ios/ShareExtension/`.
3. Добавьте App Group `group.com.familychat.familychatApp` к Runner и ShareExtension.
4. В `ios/Podfile` раскомментируйте блок `target 'ShareExtension'`.
5. `pod install`, пересоберите.

## Universal Links

На сервере должны быть AASA-файлы:

- `https://familychat-app.ru/.well-known/apple-app-site-association`
- `https://remont-tracker.ru/.well-known/apple-app-site-association`

с путями `/familychat/invite/*` (и при необходимости `/familychat/friend-invite/*`).
