# O18 — R34: skip None on Ready short lock + early soft-restart (2026-10-11)

**Status: Implemented (R34)** — invariants §7 R34.

## Dig (`_fc_diag/r33_check`)

| Window | Client | mtg phone `109.252.61.3` |
|--------|--------|---------------------------|
| Boot | Ready ~0.4s | RELAY dc=2/203 |
| Pause None | Ready→WaitingForNetwork | relays finish clean |
| Resume WiFi-only (R33) | Connecting 38s | **21 starts → 0 RELAY** (3 HS_FAIL + 18 DF) |
| Soft-restart | Ready @+90s | DF waves then OPEN |

TDLib `networkTypeNone` ≠ official tgnet `pauseNetwork`. After None,
`setNetworkType(WiFi)` dials FakeTLS that never upgrades to MTProto.

## Implemented

1. **R34a:** pause grace fire while `Ready` + FakeTLS → **skip**
   `networkTypeNone` (freeze-kick only). None remains when already `!Ready`
   (R26 zombie path).
2. **R34b:** if None was applied and short resume still Connecting → quiet
   **12s**, R15 collapse soft-restart @**12s** (was 35+40).

Markers:
- `app-pause-suspend skip None (Ready+FakeTLS)`
- `app-pause-suspend fire networkTypeNone` (only !Ready)
- `faketls-quiet arm 12s why=app-resume-unsuspend`
- `R15/R34 collapse … pauseSuspend=true after=12.0s`

## Verify

1. Lock ≥2s while Ready → unlock: stay Ready (or Ready within seconds);
   log has `skip None`, no Connecting storm.
2. If pause while already Connecting → None still fires; unlock soft-restart
   by ~12s if wedged (not ~2m).
