# Official TG vs FC — pause / proxy reconnect

Дата: 2026-10-05. Повод: FC Ready→Connecting после `app-pause` (~17:04 МСК), потом failover на 8443.

## Official Android (DrKLO / tgnet) — как устроено

Источник: `ConnectionsManager.java` + `jni/tgnet/ConnectionsManager.cpp`, `Connection.cpp`.

1. **Pause** (`setAppPaused(true)` → `native_pauseNetwork`):
   - Счётчик `appResumeCount`; при 0 вызывается pause.
   - Сеть **suspend’ит соединения** (не обязательно «убить прокси»).
   - Если в очереди/inflight есть upload/download — **не засыпает** (`dontSleep`).
   - Иначе через sleep timeout: `suspendConnections`, `networkPaused=true`.

2. **Resume** (`native_resumeNetwork(partial=false)`):
   - Снимает pause, **перезапускает timers**.
   - Если DC в handshake — `createGenericConnection` / media connection `connect()`.
   - **Не** переключает proxy на другой endpoint.
   - **Не** делает `networkTypeNone` bounce.
   - Ping к текущему DC, `processRequestQueue`.

3. **Proxy reconnect** (`Connection::reconnect`):
   - Для `ConnectionTypeProxy`: `suspendConnection(false)` (мягко).
   - Для обычных DC: `forceNextPort` + suspend + `connect()`.
   - Смена прокси — **отдельный** `setProxySettings` по действию пользователя / settings, не авто-failover ladder при stuck Connecting.

4. **Ключевой контраст с FC (наш инцидент 17:04–17:06):**
   | | Official tgnet | FC сейчас |
   |--|--|--|
   | После pause | suspend / sleep | `freeze-kick` + позже Ready→Connecting |
   | Resume | resumeNetwork, тот же proxy | `enableProxy` + kicks + **RR failover** на 8443 |
   | networkTypeNone | нет в pause path | **да** при failover |
   | Автосмена proxy | нет (ручная / settings) | да при `stuck-connecting` |
   | Слот download while Connecting | n/a (свой pool) | 0B `focus` держал 1/1 |

## TDLib (levlam) — что канон для FC

- `online=true` когда приложение на переднем плане → быстрый recover (td#2690, #3144).
- При известной смене сети — `setNetworkType`, **не** обязательно None→WiFi thrash.
- `connectionState*` — hint; не повод для proxy failover.
- Proxy errors: пользователь переключает вручную (td#3319) — как official UI.

## Форумы / багрепорты

| Источник | Суть | Applicable к нам |
|--|--|--|
| [Telegram-iOS #2197](https://github.com/TelegramMessenger/Telegram-iOS/pull/2197) | iOS stuck Connecting после background: `bad_server_salt` не применяется → тишина 90–120с. **Android tgnet специально дропает idle в background**, поэтому на fresh session. | Да: long Connecting после pause — известный класс; Android режет idle, не failover proxy |
| bugs.telegram.org «Connecting after hibernation» (Unigram/TDLib) | После hibernation Connecting, помогает reopen | Да: TDLib-клиенты тоже страдают; reopen = наш user workaround |
| bugs.telegram.org proxy crash / stuck (iOS) | Workarounds: airplane, disable proxy | Слабо; симптомы те же «прокси залип» |
| bugs #69 auto best proxy | Пользователи **просят** автосмену; в official её нет как дефолт при resume | Наш RR-failover — **не** official behavior |
| mtg #441 / zig wedge | NAT/idle → Connecting to proxy; keepalive | Серверная сторона; у нас mtg был жив (DF/relay шли) |

## Вывод для следующего фикса FC

Официальный Android при pause/resume: **suspend → resume того же proxy**, без None-bounce и без смены endpoint.

FC должен:
1. На pause: **не** стартовать failover. При Ready — grace (~20s) перед `online=false`
   **только пока ещё Ready**; если уже Connecting — не ставить `online=false`.
2. На resume: `online=true` + мягкий `setNetworkType(current)` **без** `networkTypeNone`, **без** RR.
   - Ещё Ready → soft-only.
   - Уже Connecting (даже bg &lt;2m) → та же escalate-лестница, что long-bg
     (`connecting-on-resume escalate`, R13; SessionLog 22:36).
   - bg ≥2m → `long-background-resume`.
   Soft-restart preserve + probe-miss → reopen×2 → `longbg-hop-try` (R11/R12).
   After hop-try: reset restartCount + soft-restart on new hop; quiet ~35s
   without repeat `enableProxy` while Connecting (R14 — enableProxy resets
   TDLib proxy sockets mid-FakeTLS; SessionLog 22:52 + mtg handshake EOF).
   Under long-bg: while quiet — no soft kicks; after quiet — collapse soft×2
   straight to soft-restart/probe/hop (R15 — SessionLog 23:18 soft skips
   were pure delay; Ready only after soft-restart, ~2m UX).
   True long-bg (≥2m): soft-restart **first** on resume (R16 — SessionLog
   23:36 enableProxy+quiet never helped). Short R13 keeps soft-nudge.
   After hop-try debounce: one None→current `longbg-socket-reopen` (R16),
   not soft-nudge forever — hibernation reopen analogue; not first recover.
3. Failover proxy на Ready — только по явному better ping (R10).
4. Не держать download slot на 0B пока Connecting.

Не копировать iOS salt-баг; не soft-only forever при resume-Connecting;
не spam `enableProxy` every soft-kick (ломает TlsInit);
не burn soft×2 under long-bg quiet (R15);
не enableProxy-first после true long-bg (R16).
