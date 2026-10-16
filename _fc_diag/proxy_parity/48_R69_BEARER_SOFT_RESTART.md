# R69 — bearer hop change → soft-restart (2026-10-14)

## Evidence

`47_OFFICIAL_VS_FC_BEARER.md`: official TG on cellular + `:8443` =
RELAY; FC R68 mid-session enableProxy = 0 RELAY / DF.

DrKLO: wifi↔mobile → only `setNetworkAvailable` (same proxy).

## Fix

FakeTLS `link:` wifi↔mobile:

1. Prefer hop by port (R67).
2. If hop / enabled proxy_id changed → `_recoverDeadClient(bearer-hop:…)`
   so first dial is clean FakeTLS on the new hop.
3. Else → `setNetworkType(current)` only + quiet if !Ready.
4. Keep R68 resume-race skips.

Markers: `bearer-recover hop-change → soft-restart`,
`bearer-recover same-hop setNetworkType only`,
`recover-dead-client why=bearer-hop:…`.
