# R52 — pause mid soft-handshake must not fire None (2026-10-12)

Evidence: `_fc_diag/last2h/` ~15:30–17:14 MSK.

## Facts

1. ~95/104 min of the window spent in `WaitingForNetwork` after
   `app-pause-suspend late-None` / pause-suspend None while locked.
2. Unlock soft-restart usually lands Ready in &lt;1–5s (R40 path OK).
3. Smoking gun thrash (12:49 UTC):
   - unlock → soft-restart-first + quiet 35s
   - **re-lock while Connecting** @12:49:22 → `fire networkTypeNone`
   - unlock → soft-restart again
   - **re-lock while Connecting** @12:49:57 → None again → **62m WFN**
4. Media 0B while short Ready windows + Pong timeout = zombie plane (R51).

## Consensus

Keep R34 skip-None (Ready) and R40 late-None (stop DF on long lock).

Change only the mid-handshake pause path:

| Situation | Action |
|-----------|--------|
| Ready+FakeTLS short lock | skip None (R34) |
| Ready→Connecting in bg | late-None after **2s defer**; cancel if Ready returns (R52) |
| Pause while soft-restart / faketls-quiet | **skip None**; arm late-None when quiet ends still bg+!Ready (R52) |
| Pause while zombie Connecting (no quiet) | fire None (R26) |

Markers: `skip None (soft-handshake)`, `late-None defer`,
`late-None cancel (Ready recovered)`, `soft-handshake late-None arm/cancel`.
