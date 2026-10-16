# O12 — Official pause suspend (2026-10-09 ~15:35–15:46)

**Status: Implemented (R26)** — invariants §7.

## Logs (pre-fix)

| t (UTC) | Event |
|---------|--------|
| 15:35:35 | pause Ready → +5s Connecting; grace **skip** online=false |
| 15:35–15:42 | zombie Connecting ~7m; Ready spontaneously while paused |
| 15:42:31 | unlock already Ready (UI flash) → re-lock → drop again |
| 15:44:15 | R25 `official-reopen` — no Ready; ladder soft-restart…

## Official vs FC

| | Official tgnet | FC R26 |
|--|--|--|
| Pause | `pauseNetwork` → suspendConnections | `setNetworkType(None)` after 2s grace |
| Resume | `resumeNetwork` same proxy | `online` + `setNetworkType(WiFi/Mobile)` |

## Implemented

1. Pause always arms suspend (even if Connecting) — marker `app-pause-suspend`.
2. Grace 2s (quick switches cancel).
3. Resume unsuspend via R25 reopen (`app-resume-unsuspend` / `official-reopen`).
4. No `online=false` skip-zombie path; no soft-restart on resume recover.

## Verify

Lock ≥2m → log `app-pause-suspend fire networkTypeNone`; unlock →
`official-reopen`/`unsuspend` → `mtproto-up` in seconds; no Ready flash
from mid-lock zombie recovery.
