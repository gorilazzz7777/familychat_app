# R66 — wifi→mobile reopen (2026-10-14 09:27Z)

## Evidence

R64 fired correctly:

1. `bearer-recover start why=link:…mobile` + `enableProxy ok`
2. `skip-none-bounce (mobile)`
3. Ready→Connecting; ~49s soft-restart; no fast `mtproto-up`

## Fix

`link:…mobile` same as R65 `link:…wifi`: None→current reopen.
Keep skip-none-bounce only for non-link mobile recovers.
