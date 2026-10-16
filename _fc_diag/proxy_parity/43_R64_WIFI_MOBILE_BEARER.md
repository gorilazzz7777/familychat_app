# R64 — wifi→mobile full bearer-recover (2026-10-14 09:17Z)

## Evidence

Ready on wifi, focus download in flight. Link flipped to mobile:

1. `setNetworkType networkTypeMobile why=link:…` only (no `bearer-recover start`)
2. Ready → Connecting immediately
3. ~50s Connecting → soft-restart thrash; no `mtproto-up`
4. Proxy geo stayed `use=true` — plane dead, not proxy disabled

`mobile→wifi` already forced `_recoverAfterBearerChange` (SessionLog 10:05).
`wifi→mobile` while Ready took the plain `setNetworkType` branch.

## Fix

Any wifi↔mobile flip → `_recoverAfterBearerChange`. Mobile still
`skip-none-bounce` inside recover.
