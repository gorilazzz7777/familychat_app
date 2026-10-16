# R51e — Ready+same-hop probe must not re-enableProxy

Evidence: `_fc_diag/check_now/` 2026-10-12 21:16:32 (after R51d).

## Facts

1. Unlock → Ready+media `done` (~300ms). Later Pong + CDN/origin 0B.
2. `stall-recover-zombie-hop` → `_failoverProxy(evenIfReady)`.
3. `_probeBestProxyEndpointIndex` → `_syncAllProxyEndpointRows` always
   `disableProxy` + `enableProxy` even for the **current** hop.
4. ~500ms later: Ready→Connecting (before alt-hop ping finished).
5. Alt hop ping timeout → probe-miss; soft-nudge skipped via quiet, but
   plane already torn.

## Consensus

- Soft-restart (R51d) was wrong while Ready+send alive.
- Hop is right **only** when a better ping exists.
- Probe prep must not bounce the live FakeTLS session (same class as R21).

## Fix

1. `_syncAllProxyEndpointRows`: if Ready and `enableId == _enabledProxyId`,
   skip disable/enable (`proxy sync skip re-enable (Ready+same hop)`).
2. `_failoverProxy` probe-miss while Ready: return, no soft-nudge
   (`proxy-failover skip probe-miss Ready`).
