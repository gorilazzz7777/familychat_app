# O14 — Cold boot: no soft-nudge enableProxy while Connecting (R28)

**Status: Implemented (R28)** — invariants §7.

## Logs (pre-fix) — SessionLog 16:40

| t (UTC) | Event |
|---------|--------|
| 16:40:53 | boot `proxy sync enabled` + `faketls-quiet 35s` while Connecting |
| 16:41:31 | quiet gone → soft-nudge **enableProxy** @40s (aborts TlsInit) |
| 16:42:11 | soft-nudge enableProxy @80s again |
| … | stuck Connecting; media 0B |

Contrast: pause/resume R27 same session → Ready ~12s. VPS mtg dial OK.

## Rule

Soft-nudge while `!Ready`: **only** `online` + `setNetworkType`. Never
`enableProxy` unless `forceEnableProxy` (hop/failover). Covers boot after
quiet expiry — not only soft-resume (R25).

## Verify

Cold start (kill + open): `proxy sync enabled` + quiet; later soft kicks
log `skip enableProxy (Connecting)`; Ready without enableProxy storm.
