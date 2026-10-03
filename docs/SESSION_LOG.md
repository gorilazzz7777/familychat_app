# Session diagnostics (debug)

Debug builds write a JSONL event store for AI post-hoc analysis. **Release builds are a no-op** (`kDebugMode` only).

## Location

`<app_documents>/fc_diag/tg_YYYYMMDD_HH.jsonl`

Retention: **48 hours** (hourly files pruned automatically).

## Adb pull (debuggable debug APK)

```bash
# List
adb shell run-as com.familychat.familychat_app ls app_flutter/fc_diag

# Pull one hour file
adb exec-out run-as com.familychat.familychat_app \
  cat app_flutter/fc_diag/tg_YYYYMMDD_HH.jsonl > tg_diag.jsonl
```

Fallback if `run-as` path differs (`app_flutter` vs files):

```bash
adb shell run-as com.familychat.familychat_app find . -name 'tg_*.jsonl'
```

Or copy to sdcard then pull:

```bash
adb shell "run-as com.familychat.familychat_app sh -c 'cp -r app_flutter/fc_diag /sdcard/Download/fc_diag'"
adb pull /sdcard/Download/fc_diag ./fc_diag
```

Boot logcat also prints: `[session-log] dir=...`

## Categories (high signal)

### App-wide (`AppSessionDiagnostics`)

| cat | meaning |
|-----|---------|
| `app` | diag start, 60s heartbeat snapshot |
| `app.life` | lifecycle paused / resumed / hidden |
| `app.net` | bearer link (`wifi`/`mobile`/`offline`), UI online flag |
| `app.shell` | bottom-nav tab changes |
| `app.nav` | Navigator push/pop/replace |
| `app.boot` | bootstrap / splash phases (from `ChatBootTrace`) |
| `app.auth` | TG (and future FC) auth phase transitions |
| `app.push` | FCM received / opened-from-tap |
| `app.error` | Flutter + platform uncaught errors |

Ambient fields on many of these: `life`, `net`, `uiOnline`, `shell`, `route`, `fcThread`, `tgChat`, `tgConn`, `tgPhase`, `tgProxy`.

### Family Chat

| cat | meaning |
|-----|---------|
| `fc.chat` | FC conversation open / close |
| `fc.ws` | WebSocket connected / disconnected (throttled) |
| `fc.sync` | `ChatOfflineSync` online / offline |

### Telegram (existing)

| cat | meaning |
|-----|---------|
| `tg.chat` | open/close/claim/new message while open |
| `tg.history` | history load, delete, preserve/restore |
| `tg.media` | focus, downloads (`trace` from tdlib-media) |
| `tg.conn` | MTProto connection + recover |
| `tg.auth` | TDLib auth phase |
| `tg.ui` | viewport focus pick, jank focus |
| `tg.jank` | throttled UI jank traces (no SCROLL spam) |
| `diag` | SessionLog boot |

Each line: `{"ts","cat","evt",...}` — UTC ISO timestamps.

## Analysis tips

1. Filter by `cat` prefix (`app.`, `fc.`, `tg.`) for a timeline of the whole session.
2. Heartbeat (`app` / `snapshot`) every 60s shows ambient state even when idle.
3. Correlate `app.life` → `tg.conn` / `fc.ws` after resume to spot recover stalls.
4. `app.error` + nearby `tg.chat` / `fc.chat` opens often pinpoints UI freezes.
