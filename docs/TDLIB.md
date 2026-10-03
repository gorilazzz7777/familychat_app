# Telegram TDLib (FamilyChat)

Клиентский TDLib в приложении (Android + iOS). Сессии только на устройстве.

**Secretary (Business Bot) — soft-killed.** Серверный webhook / Business outbound /
matches API no-op (revive только через `FAMILYCHAT_TELEGRAM_SECRETARY_ENABLED=1`).
Мосты TDLib (`TelegramExternalChat` / `TelegramMessageMap` / group+saved /
`TelegramTdlibIdentity`) остаются.

## Сборка Android

1. Скачать native libs:

```powershell
.\scripts\fetch_tdlib_android.ps1
```

Кладёт `libtdjson.so` в `android/app/src/main/jniLibs/{abi}/` (в `.gitignore`).

2. `api_id` / `api_hash` уже зашиты по умолчанию в `TdlibConfig`
   (можно переопределить `--dart-define` / `dart_defines/tdlib.json`).

3. Запуск:

```powershell
flutter run
```

## Сборка iOS

```powershell
.\scripts\fetch_tdlib_ios.ps1
```

Кладёт prebuilt `tdjson` framework / dylib под `ios/` (в `.gitignore`).
FFI загружает библиотеку на `Platform.isIOS`.

## Прокси

MTProto FakeTLS (см. `TdlibConfig.proxyEndpoints`; VPS: nginx stream → mtg):

1. Primary: TCP `cdn.remont-tracker.ru:443`, SNI disguise `www.cloudflare.com`
2. Fallback: тот же FakeTLS на IP VPS `:443` (обход DNS / captive quirks на Wi‑Fi)

При долгом `Connecting` клиент делает failover primary→fallback (и обратно).
`proxySecretEpoch` bump при смене secret — старый proxy row в TDLib сбрасывается.

Включается только если публичный IP в **RU** (для обхода блокировок).
Вне РФ — прямое подключение к Telegram (прокси снимается).
Если гео не определилось — прокси остаётся (безопаснее для RU).

Lifecycle: в фоне kick-таймер останавливается; на resume — debounce recover
(не эскалировать «накопленный» overnight wait).

## MVP

- Логин: телефон → код → 2FA
- Вкладка «ТГ»: private chats (несвязанные)
- Переписка: текст, фото, реакции
- «Связать» с участником семьи → entry в «Чаты» (сообщения остаются в TDLib)
- Dual groups / Saved Messages через TDLib bridges
- TG push: FCM token → TDLib `registerDevice` + `processPushNotification` + локальные баннеры

## Follow-up (вне текущего релиза)

PushKit / CallKit hardening, Notification Service Extension, `aps-environment=production`.

## Store / ToS

В описании приложения нужно указать, что используется Telegram API (Client API Terms), без слова «Telegram» в title бренда (кроме Unofficial…).
