# O23 — R39: soft-pause quiet-only (2026-10-11)

**Status: Implemented (R39)** — invariants §7 R39.

## Dig (r38_check SessionLog 19:02–19:06Z + mtg)

| Phase | Client | mtg-wifi phone | mtg:8443 |
|-------|--------|----------------|----------|
| Boot | Ready ~2s | 5 starts / **4 RELAY** | — |
| Soft×1–3 (R38 soft-restart@0) | Connecting | **0 RELAY**, DF×13–14/window | — |
| Hop 8443 | Connecting 40s | — | 16 starts / **0 RELAY** |
| Soft×4 preferred | Ready **+161s** (~282ms) | 2 starts | — |

R38 skipped WiFi DF but soft-restart@0 + quiet 35s → collapse `after=40s`
and a DF storm; hop made it worse; preferred soft-restart recovered.

## Implemented

1. Soft-pause Ready-drop recover: `soft-pause-quiet-only` (online + quiet
   **12s**) — no WiFi force, no soft-restart@0.
2. Pause-suspend None: one `setNetworkType` + quiet **12s**.
3. Soft-pause soft-restart / proxy-enable quiet **12s** (R15/R34 can fire).
4. Soft-pause stage-5: **skip hop** → preferred soft-restart; second time
   → socket-reopen.

Markers: `soft-pause-quiet-only`, `soft-pause-skip-hop soft-restart-preferred`.

## Expect

unlock → quiet 12s (0 DF) → soft×1 → Ready often &lt;30–40s; no hop DF window.
