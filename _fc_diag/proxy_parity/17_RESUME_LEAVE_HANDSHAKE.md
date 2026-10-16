# O13 — Official resume: leave FakeTLS alone (2026-10-09 ~16:49)

**Status: Implemented (R29)** — invariants §7 R29.

## Logs (pre-fix, post-R28)

| t (UTC) | Event |
|---------|--------|
| 16:48:10 | PROCESS BOOT — Ready **213ms** (R28 OK) |
| 16:48:47 | pause → R26 `networkTypeNone` |
| 16:49:54 | resume → R27 skip R13 → `official-reopen` → Connecting |
| 16:50:29… | R28 `skip enableProxy` ✓ but **`setNetworkType` every ~40s** |
| ~5m | softResume pinned soft-nudge **#2 forever** |
| 16:56:14 | soft-restart → Ready **20.6s** |

## Official tgnet

`resumeNetwork`: unpause + reconnect **once**, same proxy. No repeated
socket reopen, no proxy RR, no soft-nudge forever.

TDLib analogue: one `online` + `setNetworkType(force)` (R25/R26), then
**leave the handshake alone** until Ready or true last-resort soft-restart.

## Implemented (R29)

1. After `official-reopen` / `unsuspend` while !Ready: arm `faketls-quiet`.
2. Soft-nudge while FakeTLS Connecting: **skip `setNetworkType(force)`**
   (and enableProxy — R28). Only `online=true`.
3. Soft-resume after soft×2 → soft-restart same hop (not stage=2 forever);
   still no RR/failover under soft-resume.

Markers: `soft-nudge skip setNetworkType (Connecting)`,
`faketls-quiet arm … why=app-resume-unsuspend`.

## Verify

Lock ≥2s → unlock → `unsuspend` + quiet → `mtproto-up` in **seconds**
(no `setNetworkType` soft-nudge storm). If wedge: soft-restart ~90s, not ~5m.
