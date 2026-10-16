# O21 — R37: preserve soft-pause ladder across soft-restart (2026-10-11)

**Status: Implemented (R37)** — invariants §7 R37.

## Dig (SessionLog 18:06 + mtg-wifi)

| | Boot 18:01 | Soft-restart 18:06–08 |
|--|------------|------------------------|
| Client | Ready ~2s | Connecting 90s+ soft-nudge |
| mtg phone | **1 RELAY** | **37 starts, 0 RELAY, all DF** |

After R15/R34 soft-restart @15s, tearDown cleared `_resumeFromPauseSuspend`
+ softResume → soft-nudge `skip setNetworkType` forever. No 2nd soft-restart / hop.

## Implemented

1. `_recoverDeadClient(preserveSoftPauseEscalation:)` restores
   `_resumeFromPauseSuspend` + soft-resume guard + restartCount.
2. Soft-pause / pause-suspend soft-restarts increment the same restartCount
   cap as long-bg → soft×≤3 → hop-try.

Markers:
- `preserveSoftPause=true`
- `soft-pause-escalation preserve after soft-restart`
- `soft-restart-preserve-soft-pause`
- subsequent `R15/R34 collapse` / hop (not soft-nudge-only)
