# R51 / R51b–d — Ready+0B + Pong = media-plane heal (not soft-restart)

Evidence:
- 11:34 LTE — cancel tore Ready (original R51 soft-restart)
- 20:02 — soft-restart on first CDN 0B after live siblings (R51b)
- 20:16 — `recentMediaOk` blocked heal → give-up (R51c)
- 20:28–20:30 — soft-restart while Ready+send OK → «прокси отлетел»,
  Connecting 40s × soft-kick loop (R51d)

## Decision

1. First CDN 0B → origin (R8); marker `stall-recover-zombie-defer`.
2. After CDN+origin 0B + fresh Pong while **Ready**: **evenIfReady hop**
   (R10) — **not** soft-restart, **not** cancel. Markers:
   `stall-recover-zombie-hop`, `stall_zombie_hop`.
3. Soft-restart remains for true dead client / stuck-Connecting ladders
   (pause-resume, R15), not for Ready+send-alive media stalls.
4. **R51e:** probe sync must not re-enable same hop while Ready; probe-miss
   while Ready → no soft-nudge. See `36_R51e_PROBE_NO_REENABLE_READY.md`.
