# R53 — soft-restart settle after Ready blip (2026-10-12)

Evidence: `_fc_diag/now_drop/tg_20261012_19.jsonl` 19:40–19:41 UTC.

## Facts

1. Unlock soft-restart → Ready in **417ms** (plane can land fast).
2. Soft-resume / quiet flags **cleared on Ready**.
3. **+5s** while foreground: Ready→Connecting (no pause, no late-None).
4. Kick ladder waited **35s** → soft-nudge noop → soft-restart.
5. UX: «только что всё было нормально, и опять отвалилось».

## Consensus

Keep R40 late-None (bg) and R52 soft-handshake pause skip.

Add settle after soft-restart Ready:

| Event | Action |
|-------|--------|
| Ready within 90s of soft-restart | arm settle **15s** |
| fg Ready→Connecting during settle | soft-restart early (cap **2**) |
| Ready stable for full settle | clear settle count |
| Cap exhausted | leave normal kick ladder |

Markers: `soft-restart-settle arm`, `soft-restart-settle Ready-drop → soft-restart`,
`soft-restart-settle clear (stable Ready)`,
`recover-dead-client why=ready-drop-in-settle:N`.
