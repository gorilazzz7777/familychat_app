# LOG — что добавлено (план §E)

## FC SessionLog

| evt | cat | Когда | Поля |
|-----|-----|-------|------|
| `plane` | `tg.proxy` | каждые 12s при proxy/media activity | `conn, net, proxyOn, lastPongMs, lastPongAgeMs, endpoint, slots, queued, inflight[], mediaReady, fg` |
| `pong` | `tg.proxy` | успешный pingProxy | `proxyId, seconds, lastPongMs` |
| `download_start` | `tg.media` | перед downloadFile | `fileId, reason, offset, size, cdnBypass, chatId, slots, net…` |
| `download_ack` | `tg.media` | после ack | `fileId, offset, cdnBypass` |
| `download_progress` | `tg.media` | шаги progress | `downloaded, size, bytesDelta5s, offset, rateBps, elapsedMs` |
| `stall_0b` / `stall_idle` | `tg.media` | watchdog stall | `fileId, downloaded, size, offset, bytesDelta5s, idleMs, conn, net` |

Все `_slog` теперь всегда пишут `net` + `proxyOn`.

Trace-строки (`net-downloadFile`, `watchdog`, `progress`) дополнены `net=`, `offset=`, `delta5s=`.

Код: `lib/features/telegram_tdlib/telegram_tdlib_service.dart`.

## VPS

- `pull_mtg_window.ps1` — docker logs `--since Nm` → jsonl (только после согласия на SSH).
- `correlate_plane_mtg.py` — джойн plane/stall с mtg DF/relay по минутам.

## A/B

- `04_AB_protocol.md` — ручной протокол official ↔ FC.

## TDLib verbosity

Временно (не включено в код по умолчанию): при проблемном сценарии можно поднять verbosity `connections`/`net` на 5–10 мин через существующий TDLib log hook, если понадобится глубже DOC#9. Не требуется для первого A/B.

## R17 evidence (SessionLog 00:14–00:17)

- Bug: `ensureFileLocal(tap:video)` pre-added `_downloadForceBypassCdnOnce` → first `downloadFile` was origin `offset=1`.
- Result: ~75s Ready+0B on origin; CDN retry then delivered ~5MB video.
- Fix: tap/ensure yield slots only; first wire attempt = CDN `offset=0`; stall-recover still forces one origin after 0B.
- Lock marker: `net-downloadFile … tap:video … offset=0 cdnBypass=false`.
