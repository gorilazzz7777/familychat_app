# O10 — Lock reopen ~2m vs official instant (2026-10-09 ~14:13–14:26 UTC)

**Status: Implemented (R24)** — see `.cursor/rules/tdlib-faketls-media-invariants.mdc` §7 item 11.

## Logs

| Unlock → Ready | Waste |
|----------------|--------|
| 14:13:35 → 14:15:44 (~2m09s) | soft-restart×2 + probe timeout + hop-try 8443 + preferred restore ip2 → Ready 301ms |
| 14:24:41 → 14:26:50 (~2m09s) | same shape → Ready 402ms |

Official tgnet: `resumeNetwork` same sockets — seconds, not minutes.

## Consensus

1. Ready itself is fast (~0.4s); ladder before it is the UX gap.
2. Connecting `pingProxy` probe always times out — pure delay before soft-restart #2.
3. Hop-try then soft-restart `preferred restore` undid 8443; Ready landed on preferred ip2 after the waste.
4. R23 fixed hang-without-hop; R24 targets **time to Ready**.

## Implemented (R24)

1. Long-bg quiet **18s** (`_fakeTlsQuietLongBg`); boot/non-longbg stays 35s.
2. Soft-restart **cap=3** same hop before hop-try.
3. After #1 fail → soft-restart #2 (**skip probe**). Marker: `R24-skip-probe`.
4. Mid-ladder `ensureProxy`: **no preferred restore**. Marker: `proxy preferred skip mid-ladder`.
5. Untouched: R14 no spam enableProxy, R16 soft-restart-first, R21 Ready-gate, R23 preserve.

## Verify

Lock ≥2m → unlock → Ready ideally ≪60s (often after soft-restart #2/#3).  
No `proxy preferred restore` between hop-try and Ready while mid-ladder.  
Markers: `faketls-quiet arm 18s`, `R24-skip-probe`, `preferred skip mid-ladder`.
