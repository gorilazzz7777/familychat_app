# O17 — Short resume = official resumeNetwork (2026-10-11 ~16:53)

**Status: Implemented (R33)** — invariants §7 R33.

## Logs (post-R32 boot OK)

| t (UTC) | Event |
|---------|--------|
| 16:53:17 | Boot Ready **proxyOn=true** 1.6s (R32 OK) |
| 16:53:38 | pause → R26 `networkTypeNone` |
| 16:53:48 | unsuspend + **enableProxy** (R30) + quiet |
| 16:53:48–55:31 | Connecting ~**1m45s**; soft-nudge no-op |
| 16:55:52 | soft-restart → Ready 20.3s |

## Official

`resumeNetwork`: unpause + reconnect **same** proxy sockets. Does **not**
re-apply proxy settings. TDLib analogue: `online` + `setNetworkType(force)`
only — proxy remains enabled after pause `networkTypeNone`.

## Implemented (R33)

1. Remove unsuspend `enableProxy` (revert R30 mid-handshake reset).
2. Keep quiet 35s after unsuspend.
3. Arm `_resumeFromPauseSuspend` → after quiet, R15-style collapse to
   soft-restart (~40s) if still Connecting (not soft-nudge×2 + 90s).

Markers: `app-resume-recover official-reopen` **without**
`unsuspend enableProxy`; `R15/R33 collapse … pauseSuspend=true`.

## Verify

Lock ≥2s → unlock → Ready in seconds (no enableProxy); if wedge, soft-restart
~40s after quiet, not ~1m45s.
