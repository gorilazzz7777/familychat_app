# O13 — Resume after R26 suspend must not R13-escalate (R27)

**Status: Implemented (R27)** — invariants §7.

## Logs (pre-fix) — SessionLog 16:18

| t (UTC) | Event |
|---------|--------|
| 16:18:21 | pause Ready → R26 arm → `networkTypeNone` → WaitingForNetwork |
| 16:18:43 | unlock bg=21.8s — still WaitingForNetwork (expected) |
| 16:18:43 | **bug:** `connecting-on-resume escalate` → `longBg=true` |
| 16:18:45 | R25 `official-reopen` / unsuspend → Connecting |
| 16:18:58 | R15 collapse soft×2 → **soft-restart@15s** (tears FakeTLS) |
| 16:19–16:20 | soft-restart×3 → hop 8443 → soft-restart → Ready ~2m later |

Contrast 16:06 (bg≈10s): unsuspend → Ready in ~100ms (no R15 storm).

## Official vs FC

| | Official tgnet | FC before R27 | FC R27 |
|--|--|--|--|
| Pause | suspendConnections | networkTypeNone | same |
| Resume | resumeNetwork same proxy | unsuspend **+** R13 longBg | unsuspend only |
| Soft-restart on short unlock | no | yes @15s | no |

## Rule

- `_appNetworkSuspended` on resume → **skip R13** (marker
  `connecting-on-resume skip R13 (pause-suspend)`).
- True long-bg (bg ≥2m) still arms ladder after reopen if needed.
- Spontaneous !Ready **without** our suspend keeps R13 (SessionLog 22:36).

## Verify

Lock ≥2s → unlock: `skip R13 (pause-suspend)` + `app-resume-unsuspend`
→ Ready without soft-restart / R15 within first ~30–40s.
