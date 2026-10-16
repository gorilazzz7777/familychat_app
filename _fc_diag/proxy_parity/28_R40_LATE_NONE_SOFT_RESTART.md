# O24 — R40: late-None + soft-restart-first ≤5s (2026-10-11)

**Status: Implemented (R40)** — invariants §7 R40. Target unlock→Ready ≤5s.

## Dig (r39_check + mtg-wifi)

| Phase | Client | mtg phone |
|-------|--------|-----------|
| Boot | Ready ~1.2s | 7 starts / **5 RELAY** |
| LOCK (skip None) | Connecting | 3 DF / 0 RELAY |
| QUIET-only 15s | Connecting | **12 DF / 0 RELAY** |
| Soft×1–2 | Connecting | 5 DF each |
| Soft×3 | Ready +46s (311ms) | 3 starts |

Quiet-only did **not** freeze the wire — zombie foreground DF storm.
Soft×3 proves soft-restart can land in &lt;1s when the plane is clean.

## Implemented

1. After R34a skip None: on Ready→Connecting in background →
   `networkTypeNone` (**late-None**) — stop DF until unlock.
2. Unlock soft-pause / late-None FakeTLS `!Ready` → **soft-restart-first**
   (not quiet-only, not WiFi reopen).
3. Soft-pause quiet / collapse budget **4s** (was 12s).

Markers: `late-None (Ready-drop in bg)`, `soft-restart-first`, quiet `4s`.

## Expect

lock drop → late-None (0 DF in lock); unlock → soft-restart → Ready ≤5s
(typically ~1–2s like boot).
