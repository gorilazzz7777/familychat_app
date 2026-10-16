# O8 — Video / media not loading: exclusive-slot wedge (2026-10-09 ~16:32–16:38)

**Status: Implemented (R22)** — see `.cursor/rules/tdlib-faketls-media-invariants.mdc` §7b.

## Logs (`tg_20261009_13`)

| t (UTC) | What |
|---------|------|
| 13:32:27 | **`tap:video:14760` OK** — 5.58MB / 3.9s → `1007(89).mp4` (Ready + FakeTLS) |
| 13:32:28–13:34:30 | **Video thumb** `14759` (12.5KB): `ack` + **0B** ~90s → CDN→origin→lastchance → give-up |
| 13:36:03 | App restart → Ready |
| 13:36:39 | Thumb `16301` OK ~428ms (same chat) |
| 13:36:52 | `tap:photo:16449` → long **0B**, then crawl to 14.5KB and **idle** |
| 13:37:29+ | `focus` / `album:prefetch`×5 pile behind zombie; `slots=1/1 queued=6` |
| 13:38:24+ | `focus_hold_block` while inflight=`stall-retry:tap:photo:16449` |
| after 13:32 | **No new `tap:video`** in SessionLog |

Plane: `proxyOn=true`, `connectionStateReady`, `mediaReady=true` — proxy plane OK; **media slot wedged**.

## Consensus

1. FakeTLS / Ready **не** причина отказа полного видео в принципе (доказано 13:32).
2. UX «видео не грузится» = **слот 1 занят** зомби CDN (thumb/photo 0B или idle mid-file) + очередь `album:prefetch` + `focus_hold`.
3. User-tap не всегда вычищал очередь: `preemptForUserTap` дропал `focus:`/`neighbor:`, но **не** `album:prefetch:` / `stall-retry:tap:photo`.
4. Progress-idle на mid-file слишком долго держал слот под Ready+proxy (~45s).
5. Мелкие thumbs 0B жгли слот минуты через lastchance.

## Implemented (R22)

1. **`preemptForUserTap`:** drop `album:prefetch` / `stall-*` / focus from queue; cancel any non-live non-tap inflight (incl. partial idle). Photo + video taps call it. Marker: `preempt-tap … dropQ=…album:prefetch…`.
2. **FakeTLS:** `album:prefetch` / bare ensure = **disk only** (no wire) — `ensure_skip_proxy`.
3. **Progress-idle Ready+proxy:** `_stallProgressIdleProxyReady` = **15s** (was 45s).
4. **Small files (≤64KB, not video body):** Ready 0B budget **12s**; **no** lastchance — `stall-give-up-small`.
5. Untouched: R17 first `offset=0`, R19 video Ready 0B 35s for large `tap:video`, R21 already-Ready.

## Verify

- Tap video while soft photo inflight → `preempt` + `net-downloadFile … tap:video` within ~1s.
- No `queued≥5` album-prefetch under FakeTLS.
- Thumb focus: stall_0b → free ≤~40s total, not 90s+.
