# R51f — Ready+zombie probe-miss → hop-no-ping + focus-tail ladder

Evidence: `_fc_diag/check_now/tg_21c.jsonl` 2026-10-12 21:22–21:24 (after R51e).

## Facts

1. R51e kept Ready (`proxy sync skip re-enable`) — good.
2. Alt hop `pingProxy` timed out → probe-miss → **no hop** → media stayed on
   dead CDN; requeue `offset=0` again; ~35s until size-fallback finally worked.
3. `focus-tail:*` was not `isFocusish` → `stall-give-up-small` without origin.

## Decision

1. probe-miss + Ready + `evenIfReady` → switch to next FakeTLS hop **without
   ping** (manual-switch analogue; ping unreliable for media plane).
2. Requeue after zombie with `_downloadForceBypassCdnOnce` + recoverAttempted.
3. `focus-tail` / `focus-upgrade` use same CDN→origin 0B path as `focus:`.

Markers: `proxy-failover probe-miss Ready → hop-no-ping`,
`stall-recover-same` on `focus-tail:…`.
