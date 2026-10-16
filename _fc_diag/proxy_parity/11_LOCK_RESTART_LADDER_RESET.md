# O9 — Lock / reopen / brief re-lock: ladder reset, never hop-try (2026-10-09 ~13:44–13:52 UTC)

**Status: Implemented (R23)** — see `.cursor/rules/tdlib-faketls-media-invariants.mdc` §7 item 10.

## Logs (`tg_20261009_13`)

| t (UTC) | Event |
|---------|--------|
| 13:44:16 | `diag/boot` (APK install restart) |
| 13:44:20 | **Ready** `mtproto-up after 354ms` → enable `ip2-443-cf` + quiet ✓ |
| 13:45:21 | pause (lock) while Ready; soft-resume-guard |
| 13:45:27 | Ready→**Connecting** (~6s into lock) — R13 shape |
| 13:45:49 | grace **skip** `online=false` (not Ready) ✓ |
| 13:48:41 | resume bg=**3m19s** → `long-background-resume` → **R16** soft-restart-first ✓ |
| 13:48:43 | soft-restart + enable `ip2-443-cf` + quiet; **stays Connecting** |
| 13:49:23 | quiet clear → **R15** collapse → stage=3 probe |
| 13:49:29 | ping `ip-8443-cf` **timeout**; probe-miss → soft-restart #2 (`restartCount=2`) |
| 13:49:29 | again enable preferred **ip2** + quiet — still Connecting |
| 13:50:02 | brief pause (~33s) while still Connecting |
| 13:50:35 | resume → **`connecting-on-resume escalate`** + **`mtproto-kick-reset`** |
| 13:50:35 | **`_longBackgroundSoftRestartCount = 0`** (wiped at cap) — **pre-R23** |
| 13:50:38 | soft-nudge **enableProxy** same hop + quiet |
| 13:51:16 | R15 → soft-restart again with `restartCount=0` → back to step 1 |
| after 13:45:27 | **`mtproto-up` = 0**; **`longbg-hop-try` = 0**; **`socket-reopen` = 0** |

Plane: `proxyOn=true`, endpoint=`ip2-443-cf`, `mediaReady=false`, stuck Connecting.

## Consensus

1. FakeTLS **не** «мертв навсегда»: cold boot 13:44 Ready за 354ms на том же `ip2-443-cf`.
2. Pause/resume R13–R16 **старт** верный (soft-restart-first, quiet, skip online=false).
3. После soft-restart Ready **не** вернулся (в отличие от O7/R21 кейса 13:15).
4. На cap (`restartCount=2`) должен идти **`longbg-hop-try`** — не дошли: краткий re-lock сбросил счётчик.
5. Баг: `onAppResumed` при `!Ready` всегда zero’ил restartCount; soft-nudge жёг quiet на preferred.
6. R21 не виноват (Ready не было).

## Implemented (R23)

1. **Preserve** `_longBackgroundSoftRestartCount` on short / long resume while still Connecting mid-ladder (`priorRestartCount > 0`). Marker: `longbg-ladder preserve restartCount=N`.
2. Resume recover at **cap** → `_tryNextHopNoPing` (`short-resume hop-try-at-cap` / `longbg-resume hop-try-at-cap`), not soft-nudge / another soft-restart.
3. Short resume under cap but `restartCount > 0` → soft-restart-continue (skip enableProxy+quiet burn).
4. Fresh short R13 (`restartCount==0`) still soft-nudges (22:41 Ready in 266ms).
5. Untouched: R14 quiet, R16 soft-restart-first on fresh ≥2m, R21 Ready-gate, R22 media slot.

## Verify

Lock ≥2m → reopen → soft-restart → still Connecting → soft-restart #2 → **hop-try** to 8443 (or Ready on ip2).  
Brief re-lock mid-ladder → **no** `restartCount=0` wipe; `preserve restartCount=N`; at cap → hop-try; Ready or alternate hop within ~2m.
