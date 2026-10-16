# R54 — hold FakeTLS wire until Ready after soft-restart (2026-10-12)

Evidence: `_fc_diag/media_now/tg_20261012_19.jsonl` 19:45–19:51 UTC.

## Facts

1. UI / TDLib show Ready or proxyOn while `pingProxy` → Pong timeout and
   downloads stay 0B (zombie plane).
2. R51 correctly soft-restarts on Ready+0B+Pong-fail.
3. Immediately after soft-restart, focus still calls `net-downloadFile` on
   `WaitingForNetwork` / `Connecting` → stall CDN→origin → `give-up-small`
   **before** `mtproto-up` (often 10–40s later).
4. Auth gate (`_canStartNetworkDownload`) does not cover this — phase is
   already ready (td#1176). Need a **temporary wire hold**, not Ready-gate
   for normal operation.

## Consensus

| Rule | Action |
|------|--------|
| FakeTLS + !Ready (boot **or** soft-restart) | `_fakeTlsMediaWireHold` → disk only |
| Pump / start while hold | `pump-hold-until-ready` / `start-hold-until-ready` |
| Ready / Updating | hold lifts; flush pending; pump |
| Stall while FakeTLS !Ready | `stall_drop_zombie` + requeue (no origin) |
| R51 zombie soft-restart | also `preserveSoftPauseEscalation` (R53) |

**R54b (19:56 cold boot):** hold must not depend on soft-restart flag —
boot Connecting still had `net-downloadFile` until kick@40s.

Markers: `media-wire-hold arm/clear`, `pump-hold-until-ready`,
`start-hold-until-ready`.
