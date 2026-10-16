# O11 — Official-like fast resume (2026-10-09)

**Status: Implemented (R25)** — invariants §7 R25.

## Why R24 failed

| Unlock 14:41 | Result |
|--------------|--------|
| soft-restart×3 + hop-try + preferred-skip on 8443 | **no Ready** (stuck) |
| Pre-R24: hop-try then preferred restore → Ready ~0.4s | worked but ~2m ladder |

Compressing the soft-restart ladder is not “instant like official TG”.

## Official sources

1. **DrKLO tgnet** `ConnectionsManager::resumeNetwork`: unpause, reconnect
   same DC/proxy sockets (`createGenericConnection()->connect()`). No proxy
   switch, no client recreate.
2. **TDLib levlam** [td#3144](https://github.com/tdlib/td/issues/3144):
   `online=true` when app opened → “recover almost immediate”;
   `setNetworkType` forces reopen when network known.
3. **TDLib setNetworkType docs**: calling forces all connections to reopen
   even if type unchanged.

## Implemented (R25)

Resume recover (`_runAppResumeRecover`) when not Ready:

1. `setOption online=true`
2. `setNetworkType(current, force: true)`
3. **No** soft-restart, **no** enableProxy, **no** hop-try

Also: soft kicks under soft-resume while Connecting skip `enableProxy`.
Preferred-skip mid-ladder **reverted**. Soft-restart/hop remain kick-ladder
escalation only.

Markers: `app-resume-recover official-reopen`,
`soft-nudge skip enableProxy (soft-resume Connecting)`.

## Verify

Lock ≥2m → unlock → log `official-reopen` then `mtproto-up` in **seconds**
(not soft-restart-first / not ~2m). UI leaves «подключение…» quickly.
