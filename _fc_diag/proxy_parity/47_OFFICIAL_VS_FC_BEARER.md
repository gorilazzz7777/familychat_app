# Official TG vs FC — wifi↔mobile (2026-10-14)

## A/B fact

Same phone IP `31.173.86.155`, same mtg `:8443`, same FakeTLS secret:

| Client | Window | mtg |
|--------|--------|-----|
| FC R68 hold→proxy→up | 09:55Z | START + DF / hello-timeout / hs-fail, **0 RELAY** |
| Official TG (user paste) | 10:00Z | START + **RELAY dc=2**, 0 DF |

Proxy + Megafon OK. Failure is FC dial path after bearer flip.

## Official Android (DrKLO)

`ApplicationLoader` CONNECTIVITY_ACTION → per account:

```text
ConnectionsManager.checkConnection()
  → native_setIpStrategy(...)
  → native_setNetworkAvailable(online, networkType, slow)
```

Sources: `ApplicationLoader.java`, `ConnectionsManager.java` /
`ConnectionsManager.cpp`.

On wifi↔mobile official does **not**:
- change proxy settings
- `pauseNetwork` / None bounce
- re-`setProxySettings` / enable another hop

Proxy stays whatever the user enabled. Network flip = reopen sockets
to the **same** proxy.

Pause/resume is a separate path (`pauseNetwork` / `resumeNetwork`) —
already documented in `06_OFFICIAL_PAUSE_RESUME.md`.

## TDLib canon

- `setNetworkType` — **must** call on network change; forces all
  connections to reopen (core.telegram.org td_api setNetworkType;
  levlam td#2725, #3144).
- `online=true` when app opened — fast recover (td#3144).
- `enableProxy` — apply once; settings apply immediately (td#1001,
  #3260). Not part of the network-change path.
- `connectionState*` — informational only (td#1001).

## Exact cause class (FC)

FC after wifi→mobile (R67/R68):

1. Prefer mobile hop `:8443` (needed — wifi hop `:443` ClientHello-timeout
   on cellular historically).
2. `networkTypeNone` hold
3. **`enableProxy` to a different proxy_id mid-session**
4. `networkTypeMobile` up

Official cold dial to that same `:8443` = RELAY. FC mid-session hop
mutate = TCP up, FakeTLS hello incomplete → mtg domain-fronting /
`cannot read client hello`.

So the bug is not “8443 blocked on Megafon”. It is **in-session proxy
hop switch + None** instead of official’s **same-proxy
`setNetworkType` reopen** (or a full clean client restart with the new
hop already selected before first dial — boot R32 analogue).

## Fix direction (not implemented here)

Match official bearer path:

- If active hop already correct for radio → **only**
  `setNetworkType(current)` (+ `online=true`). No `enableProxy`, no None.
- If hop must change (443↔8443) → treat like boot: select hop, then
  **soft-restart / recreate** so first dial is clean FakeTLS (R32
  hold→proxy→up on a fresh client), not `enableProxy` on a live Ready
  session.

Do not re-add R66 post-enableProxy None on top of that.
