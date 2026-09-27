# Telegram TDLib (FamilyChat)

Клиентский TDLib в приложении (Android-first). Сессии только на устройстве.
Secretary (Business Bot) скрыт из UI; серверный bridge не удалён.

## Сборка Android

1. Скачать native libs:

```powershell
.\scripts\fetch_tdlib_android.ps1
```

Кладёт `libtdjson.so` в `android/app/src/main/jniLibs/{abi}/` (в `.gitignore`).

2. `api_id` / `api_hash` уже зашиты по умолчанию в `TdlibConfig`
   (можно переопределить `--dart-define` / `dart_defines/tdlib.json`).

3. Запуск (обычный — ключи уже внутри):

```powershell
flutter run
```

## Прокси

Зашит MTProto: `proxy.remont-tracker.ru:8443` (см. `TdlibConfig`).

## MVP

- Логин: телефон → код → 2FA
- Вкладка «ТГ»: private chats (несвязанные)
- Переписка: текст, фото, реакции
- «Связать» с участником семьи → entry в «Чаты» (сообщения остаются в TDLib)

## iOS

Следующий PR: тот же Dart-слой + prebuilt `tdjson` для iOS.

## Store / ToS

В описании приложения нужно указать, что используется Telegram API (Client API Terms), без слова «Telegram» в title бренда (кроме Unofficial…).
