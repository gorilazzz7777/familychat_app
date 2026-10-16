# O16 — 36h diagnosis + boot hold until proxy (2026-10-10…11)

**Status: Implemented (R32)** — invariants §7 R32.

## 36h facts (SessionLog pull)

| Metric | Value |
|--------|------:|
| Process boots | 8 |
| Ready events | 39 (proxy 26 / direct 13) |
| Ready→drop | 39 |
| Stuck Connecting ≥20s | 17 (worst **7h**, **1.7h**, **45m**) |
| First Ready via proxy | **1** |
| First Ready direct then drop | **4** |

### Repeat boot pattern (every cold start)

```
setTdlibParameters ok
→ Connecting/Ready proxyOn=false  (~300ms DIRECT)
→ ensureProxy / enableProxy       (~1–4s later)
→ Ready→Connecting→Ready proxy    (brief FakeTLS)
→ ~15s later Ready→Connecting     (no FC RPC — TDLib drop)
→ stuck minutes…hours
```

Markers: `boot proxy step done conn=connectionStateReady` while first
Ready was already direct; later spontaneous drop with only history warm
in between; overnight kicks frozen in background.

### Secondary failures

- `bearer-recover` None→WiFi **while paused** + pause-suspend None race
  (15:37) → TDLib `TimeoutException` storm.
- Mass `warm-history onlyLocal=false` right after FakeTLS Ready.

## Official vs FC

| | Official tgnet | FC (pre-R32) |
|--|--|--|
| First dial | through configured proxy | **direct**, then enableProxy |
| enableProxy after Ready | never (proxy already on) | every boot |
| Pause | suspendConnections | networkTypeNone (R26) |
| Bearer while paused | soft | None-bounce + enableProxy |
| History warm storm | no | many chats remote @ Ready |

## Fundamental change (not another kick-ladder tweak)

**Hold `networkTypeNone` after `setTdlibParameters` until `enableProxy`
succeeds; then release WiFi/Mobile.** First MTProto dial = FakeTLS only —
same order as official.

Also: bearer-recover soft-only in background; no None-bounce when already
Ready+proxy.

Not “100% forever” (mtg/DPI can still fail) — but removes the structural
bug that guarantees a torn direct session on every boot.

## Markers

`setNetworkType networkTypeNone why=boot-hold-until-proxy`
`boot proxy step done … proxyOn=true id=N`
`bearer-recover soft-only (background)`
`bearer-recover skip-none-bounce (ready+proxy)`

## Verify

Cold start: no Ready `proxyOn=false` before proxy step; first Ready already
`proxyOn=true`; no Ready→Connecting drop within ~15s from enableProxy tear.
