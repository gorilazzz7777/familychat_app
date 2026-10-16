# O25 — R41: soft-pause quiet 35s (no collapse@4s thrash) (2026-10-11)

**Status: Implemented (R41)** — invariants §7 R41.

## Dig (r40_check)

| Unlock | Client | mtg-wifi |
|--------|--------|----------|
| Long (~48m) | Ready **+4.4s** | soft×1: 2 starts / **1 RELAY** |
| Short (~24s) | Ready **+86s** | soft×1: 6 DF; soft×2/3+skip: DF storm |

Collapse@4s did not help DF soft×1 — it spawned more DF every 5s.
Ready clears `faketls-quiet` immediately, so quiet **35s** does not delay
the good path (long unlock still ≤5s).

## Implemented

Soft-pause quiet + collapse wait = **35s** (boot-class). Stage-5 skip-hop
minWait also full quiet. Soft-restart-first + late-None kept (R40).

## Expect

Good plane: unlock→Ready ≤5s (quiet cleared on Ready).
Hostile DF: one soft×1 up to 35s (no 5s thrash), not +86s.
