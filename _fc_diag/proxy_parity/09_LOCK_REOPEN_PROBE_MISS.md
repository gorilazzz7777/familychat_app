# O7 — Lock → reopen: Ready poisoned by late probe-miss (2026-10-09)

## Logs (SessionLog `tg_20261009_13`, phone)

| t (UTC) | Event |
|---------|--------|
| 13:11:09 | pause while **Ready**; soft-pause-grace 20s; kicks frozen |
| 13:11:14 | OS/TDLib: Ready→**Connecting** (~5s into lock) — R13 shape |
| 13:11:29 | grace **skip** `online=false` (not Ready) ✓ |
| 13:11:14–13:14:47 | stuck Connecting in background (~3m38s), kicks frozen ✓ |
| 13:14:48 | resume → `long-background-resume` → **R16** soft-restart-first ✓ |
| 13:14:50 | soft-restart + `proxy-enable` + **R14** quiet 35s ✓ |
| 13:15:25 | quiet ends |
| 13:15:30.35 | **R15** collapse soft×2 → stage=3 (`longbg-probe`) |
| 13:15:30.61 | **Ready** (`mtproto-up after 40.3s`) ✓ FakeTLS succeeded |
| 13:15:36.37 | async `pingProxy` alternate: timeout / probe-miss |
| 13:15:36.38 | `soft-nudge enableProxy … why=proxy-failover-miss:…` |
| 13:15:36.68 | **Ready→Connecting** — session torn |
| 13:15:49+ | plane: Connecting, `mediaReady=false`, `proxyOn=true` |

UI: «прокси включён» (`proxyOn`), плоскость мёртвая (не Ready).

## Consensus

1. Pause/resume ladder **R13–R16 + quiet** отработала: soft-restart → quiet → Ready.
2. Регресс **не** в R14 quiet и не в `online=false`.
3. Баг: `_failoverProxy` проверяет Ready **только на входе**. После `await pingProxy` (~6s) уже Ready, но ветка probe-miss всё равно делает `enableProxy` → срыв Tls/сессии (тот же класс, что R14).
4. R10: failover в Ready только на **лучший ping**; probe-miss **не** должен soft-nudge’ить, если уже Ready.
5. R15 collapse→probe в момент, когда handshake уже дозрел, усиливает гонку (kick и Ready почти одновременно).

## Implemented (R21 — case extension, not R8–R20 rewrite)

1. `_failoverAbortIfReady` — re-check Ready after every await in
   `_failoverProxy` (entry / after-probe / probe-miss / before-hop / after-sync).
2. probe-miss soft-nudge / hop switch only while still not Ready
   (unless `evenIfReady`).
3. Marker: `proxy-failover skip already-Ready why=after-probe:…`
4. Untouched: pause grace, R16 soft-restart-first, boot quiet (R14).

## Verify

Lock ≥2m → reopen → soft-restart-first → quiet → Ready; may see
`skip already-Ready why=after-probe:…`; **no** Ready→Connecting from
`proxy-failover-miss` enableProxy; plane `mediaReady=true`.
