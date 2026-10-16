# O15 — Boot: proxy before first dial (2026-10-09 ~17:21)

**Status: Implemented (R31b)** — invariants §7 R31/R31b.

## Logs

| t (UTC) | Event |
|---------|--------|
| 17:21:39 | Ready direct → enableProxy → Ready→Connecting +9s |
| 17:28:48 | R31 boot: pre-params `getProxies`/`addProxy` **Timeout** (~30s) |
| 17:29:21 | `proxy-before-params done id=-` then bearer-recover **None→WiFi** |
| UI | «ожидание сети…», Proxy ON, media blur |

## Official intent

Proxy before first dial — **not** Ready-direct then enableProxy.

## Implemented (R31b)

Pre-params addProxy does **not** work reliably on our TDLib build.

1. `setTdlibParameters` → `_ensureProxy` → **then** `online` + WiFi.
2. Skip bearer-recover / link-change while boot params in flight.

Markers: `boot proxy step done`, `bearer-recover skip (boot/params)`,
`link-change skip (boot/params)`.

## Verify

Cold start → no pre-params timeouts; no bearer None mid-boot; Ready with
proxy without long «ожидание».
