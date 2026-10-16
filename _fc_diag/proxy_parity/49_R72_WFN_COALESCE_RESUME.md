# R72 — WFN coalesce + resume no-thrash (2026-10-16)

## Evidence (SessionLog last 27h + mtg)

- `openMessageContent defer` ×320 while `WaitingForNetwork` (peaks 20–40/min) —
  focus/viewport re-called every tick; no TDLib RPC, but log storm + wasted
  work, and deferred opens never flushed as a single Ready pass.
- `wait-media-conn start` ×29 overlapping waiters (25s each) on same WFN.
- `late-None` often logged in pairs (Δt ~1ms) — deferred timer + soft-handshake
  timer both passed the `!_appNetworkSuspended` check before either awaited
  `setNetworkType(None)`.
- Pause while already WFN still armed grace / noise; unlock soft-restart-first
  ×21 was correct (R40), but rapid unlock while `_recoveringClient` / cool-down
  after soft-restart could start another tearDown (soft-restart ×33–38 in noisy
  hours).

## Official / TDLib

- DrKLO tgnet: `pauseNetwork` when already paused = no-op; `resumeNetwork` once
  reconnects same proxy (`06_OFFICIAL_PAUSE_RESUME.md`).
- While network paused / offline, clients do not spam media open/view RPCs;
  queue resumes after `resumeNetwork` / Ready.
- levlam: `connectionState*` is a hint; still avoid flooding while WFN.

## Fix (client only)

1. **OMC:** one pending `(chatId,msg,force)` while `!Ready`; defer log ≤1/5s
   per key; flush once on Ready (`openMessageContent flush-pending`).
2. **wait-media-conn:** shared Completer — one start log, all waiters join;
   complete on Ready (`wait-media-conn shared` / `ok` / waiter TIMEOUT).
3. **late-None:** sync `_lateNoneApplyInFlight`; skip if already WFN (mark
   suspended for R40 unlock). Marker: `late-None skip already-WFN` /
   `late-None in-flight`.
4. **pause:** if already WFN → skip None, keep soft-pause + suspended.
   Marker: `app-pause-suspend skip already-WFN`.
5. **resume soft-restart-first:** skip if `_recoveringClient` or soft-restart
   age &lt;8s and still `!Ready` (leave in-flight dial). Marker:
   `app-resume-recover skip soft-restart (recovering|cooldown)`.

No mtg / hop / geo changes.
