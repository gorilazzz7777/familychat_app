# O22 — R38: soft-restart-first on soft-pause resume (2026-10-11)

**Status: Implemented (R38)** — invariants §7 R38.

## Dig

| Path | unlock→Ready | mtg |
|------|--------------|-----|
| R37: WiFi 15s + soft×2 | **~86s** | WiFi window 0 RELAY / DF storm; Ready on soft×2 |
| Boot | ~2s | 1 RELAY |

WiFi-only after soft-pause is never productive and floods FakeTLS fails
before the first soft-restart — likely why soft×1 fails and soft×2 works.

## Implemented

On `_runAppResumeRecover` when `_resumeFromPauseSuspend` + FakeTLS + `!Ready`:
soft-restart immediately (no WiFi reopen / 12s quiet). Preserve soft-pause
ladder (R37).

Marker: `app-resume-recover soft-restart-first`.

## Expect

unlock → soft-restart in <1s; Ready often on first recreate (~seconds) or
soft×2 after quiet 35s (~40s), not ~86s.
