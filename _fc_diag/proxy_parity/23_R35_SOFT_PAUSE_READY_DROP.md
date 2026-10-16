# O19 — R35: soft-pause Ready drop → early soft-restart (2026-10-11)

**Status: Implemented (R35)** — invariants §7 R35.

## Dig (post-R34 SessionLog 17:36)

| t | Event |
|---|--------|
| 17:36:08 | `skip None (Ready+FakeTLS)` ✓ |
| 17:36:11 | TDLib `Ready → Connecting` (no our None) |
| 17:37:31 | unlock → **R13 escalate** (pauseSuspend=false) |
| 17:38:11+ | soft-restart×N @40s — still Connecting |

R34a alone insufficient when FakeTLS dies spontaneously in background.

## Implemented

1. `skip None` arms `_softPausedReadyProxy`.
2. Resume with that flag + `!Ready` → skip R13, set `_resumeFromPauseSuspend`
   (R34b quiet 12s + collapse soft-restart @12s).
3. Clear flag on Ready / tearDown / real None suspend.

Markers:
- `app-pause-suspend skip None (Ready+FakeTLS)`
- `connecting-on-resume skip R13 (soft-pause Ready drop)`
- `faketls-quiet arm 12s why=app-resume-soft-pause`
- `R15/R34 collapse … pauseSuspend=true after=12.0s`
