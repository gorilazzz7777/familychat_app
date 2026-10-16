# R65 — mobile→wifi reopen despite stale Ready (2026-10-14 09:22Z)

## Evidence

After R64, mobile→wifi logged:

1. `bearer-recover start why=link:…wifi` + `enableProxy ok`
2. `skip-none-bounce (ready+proxy)` — `_connectionState` still Ready
3. Then Ready→Connecting; ~30s soft-restart thrash; no `mtproto-up`

## Fix

`link:…wifi` / `link:…mobile` flips must not use stale Ready to skip
None→current reopen. Mobile destination still skip-none-bounce.
