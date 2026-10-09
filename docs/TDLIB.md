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

Prebuilt `libtdjson-static.xcframework` **не в git** (тяжёлый бинарь).
В репо есть `ios/tdjson/tdjson.podspec` + `TdlibKeepSymbols.m`.

**macOS:**

```bash
chmod +x scripts/fetch_tdlib_ios.sh
./scripts/fetch_tdlib_ios.sh
cd ios && pod install && cd ..
```

**Windows (только скачать xcframework, pod — на Mac):**

```powershell
.\scripts\fetch_tdlib_ios.ps1
```

После этого CocoaPods находит `pod 'tdjson', :path => 'tdjson'`.
FFI грузит символы через `DynamicLibrary.process()` (static lib).

## Прокси

MTProto FakeTLS (см. `TdlibConfig.proxyEndpoints`; VPS: `mtg` / `mtg-wifi`):

1. IP-only endpoints + FakeTLS secret SNI `www.cloudflare.com` (hostname в
   `server` ломает SNI — mtg отвергает hello).
2. Порядок по умолчанию: dedicated `244.213:443` (mtg-wifi) → `:8443`
   (прямой `mtg`, без nginx). Primary `200.164:443` в клиенте не используется.
3. **Развязка 2026-10-09:** SNI-mux empty→mtg на `200.164:443` **снят**.
   `200.164:443` = TCP proxy → `:4443` (только сайты). FakeTLS только на
   `244.213:443` (mtg-wifi) и `200.164:8443` (mtg). Канон для FC app /
   сетей с TCP-block `:443`: `https://familychat-app.ru:4443` (`Env`).
   Бэкап: `/root/nginx_decouple_20261009_125216`. См.
   `_fc_diag/proxy_parity/08_HTTPS_FAKETLS_DECOUPLE.md`.

**Выбор hop (официальный TDLib-паттерн):**

- Все endpoint’ы регистрируются в TDLib (`enable=false`), включается один.
- При stuck `Connecting` failover вызывает `pingProxy` по кандидатам и берёт
  hop с минимальным RTT (не слепой round-robin).
- Preferred hop сохраняется только после успешного `pingProxy` (не после
  голого `Ready` — сессия может быть up при мёртвом media/CDN).
- Failover **в Ready** только если `pingProxy` нашёл живой alternate
  (после auth ready + settle). Один Pong timeout / probe-miss **не**
  крутит round-robin — иначе срывает сессию в долгий Connecting.
- **R21:** Ready-gate в `_failoverProxy` после **каждого** `await`
  (`pingProxy`/sync). Late probe-miss `enableProxy` после Ready
  (lock-reopen 16:15) запрещён — marker `skip already-Ready`.
- **R22:** exclusive FakeTLS slot — `preemptForUserTap` дропает
  `album:prefetch`/`stall-*`; album:prefetch disk-only; progress-idle
  Ready+proxy ~15s; thumbs ≤64KB → give-up без lastchance. См.
  `_fc_diag/proxy_parity/10_VIDEO_SLOT_WEDGE.md`.
- **R23:** mid-ladder short resume **не** zero’ит `restartCount`; на cap
  → `longbg-hop-try` (не soft-nudge preferred). См.
  `_fc_diag/proxy_parity/11_LOCK_RESTART_LADDER_RESET.md`.
- **R24:** kick-ladder compress — quiet ~18s, soft-restart×3 skip probe.
- **R25:** resume = official `online` + `setNetworkType` reopen (не
  soft-restart-first / не enableProxy). См.
  `_fc_diag/proxy_parity/13_OFFICIAL_RESUME_R25.md`.
- **R26:** pause = `networkTypeNone` suspend (tgnet pauseNetwork); resume
  unsuspend. См. `_fc_diag/proxy_parity/14_OFFICIAL_PAUSE_SUSPEND.md`.
- **R27:** после R26-suspend short resume **не** R13-escalate (нет
  soft-restart@15s). См.
  `_fc_diag/proxy_parity/15_RESUME_SKIP_R13_AFTER_SUSPEND.md`.
- **R28:** soft-nudge **не** `enableProxy` while Connecting (cold boot
  quiet expiry). См.
  `_fc_diag/proxy_parity/16_BOOT_NO_ENABLEPROXY_WHILE_CONNECTING.md`.
- **R29:** soft-nudge **не** `setNetworkType(force)` while FakeTLS
  Connecting; soft-resume → soft-restart after soft×2. См.
  `_fc_diag/proxy_parity/17_RESUME_LEAVE_HANDSHAKE.md`.
- **R30:** после pause None — один `enableProxy` (proxy reconnect) +
  quiet 35s; long-bg не soft-restart@20s. См.
  `_fc_diag/proxy_parity/18_RESUME_PROXY_RECONNECT.md`.
- **R31b:** boot — params → proxy → online/WiFi; skip bearer mid-boot
  (pre-params addProxy timed out). См.
  `_fc_diag/proxy_parity/19_BOOT_PROXY_BEFORE_DIAL.md`.
- `pingProxy` **не** используется для «лечения» отдельных file stalls
  ([td#2585](https://github.com/tdlib/td/issues/2585)): пока нет Ready —
  только disk-hits; сетевые download ждут канала.

**CDN / `downloadFile.offset`:** по умолчанию `offset=0` (CDN, как в
официальном клиенте). Раньше при включённом FakeTLS всегда был `offset=1`
(CDN off) — на живом прокси официальный TG грузил медиа, а FC залипал в
`acked+0B`. После 0B stall один раз пробуем `offset=1` (origin DC).

`proxySecretEpoch` bump при смене secret — rows в TDLib сбрасываются.

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
