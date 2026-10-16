# R42b — focus: photo Ready+0B uses thumb 12s budget

Evidence: `_fc_diag/lock_media_now/` 2026-10-12 20:25–20:26 (after R51c).

## Facts

1. Unlock → soft-restart-first → Ready+proxyOn in ~1s; send works.
2. `focus:` photo 98.5KB / 185KB (>64KB) used `_stallZeroBytesFocusProxyReady`
   **35s** (R42 only fast-pathed `tap:photo` / ≤64KB).
3. File 14378: 0B for 27s then chat-switch purge — never `stall-recover` /
   R51 zombie soft-restart. File 1261: still 0B at 31s when user reported.
4. Pong timeout while Ready proves CDN/proxy media plane dead; MTProto send OK.

## Decision

Non-video focus/tap under FakeTLS Ready → `_stallZeroBytesThumbProxyReady`
(~12s), same as R42 tap:photo. Video keeps R19 35s. Then R8 origin + R51c
soft-restart can heal within ~24s instead of wedging the exclusive slot.
