# A/B protocol — official Telegram vs FamilyChat (same proxy)

Goal: prove whether media works on the **same phone + same FakeTLS proxy** in official TG while FC stalls, and correlate both windows with mtg logs.

## Preconditions

- Same MTProto proxy enabled in both apps (`ip2-443-cf` / current preferred).
- Do **not** change proxy mid-test.
- Note link: **wifi** or **mobile** (stay on one for the whole run if possible).
- Pick one public channel media item (photo ~100–500 KB or short video) that is visible in both apps (e.g. Шарий).
- FC debug build with SessionLog (`tg.proxy` / `plane`, `tg.media` / `download_*`).
- VPS mtg jsonl pull ready (see `pull_mtg_window.ps1`).

## Steps (one cycle ~3–4 min)

1. **T0** — write wall-clock MSK time; start mtg pull window (±2 min pad).
2. **Official 30s** — open the channel, open the media, wait until fully loaded (or 30s timeout). Record: loaded Y/N, approx seconds.
3. **Pause 10s** — leave official in background (optional: force-stop official to free sockets).
4. **FC 30s** — open same channel, tap same media. Watch loading. Record Y/N + SessionLog hour file name.
5. **Official 30s again** — same media (clear cache if needed / another similar file). Record Y/N.
6. **T1** — stop; pull FC `fc_diag/tg_*.jsonl` + mtg window.

## Success criteria

| Pattern | Meaning |
|---------|---------|
| Official Y → FC N → Official Y | FC client/gate problem (proxy OK) |
| Official N → FC N → Official N | proxy/VPS/upstream problem |
| Official Y → FC Y | parity OK for this sample |
| FC N but mtg has relay+bytes for phone IP | TDLib/UI bug (zombie local) |
| FC N and mtg 0 relay for phone IP while Connecting | session/reconnect problem |

## Artifacts to keep

- `_fc_diag/proxy_parity/ab_YYYYMMDD_HHMM.md` — fill template below
- pulled `tg_*.jsonl`
- `mtg_ab_*.log`

## Template

```md
# A/B run

- When (MSK):
- Link: wifi / mobile
- Proxy label:
- Media (channel / approx size):

| Phase | Result | Notes |
|-------|--------|-------|
| Official #1 | Y/N | |
| FC | Y/N | fileId= |
| Official #2 | Y/N | |

mtg phone IP events in window:
FC SessionLog highlights (plane / stall_0b / download_ack):
```
