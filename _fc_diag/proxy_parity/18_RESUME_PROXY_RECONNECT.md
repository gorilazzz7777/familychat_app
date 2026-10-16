# O14 — Resume after pause None: proxy reconnect (2026-10-09 ~17:08–17:16)

**Status: Implemented (R30)** — invariants §7 R30.

## Logs (post-R29)

| t (UTC) | Event |
|---------|--------|
| 17:08:48 | short resume: unsuspend + quiet 35s + `skip setNetworkType` ✓ |
| 17:09:26 | still Connecting @40s (setNetworkType alone insufficient) |
| 17:09:53 | user PROCESS BOOT (killed before soft-restart@90s) |
| 17:15:18 | long-bg resume: quiet **18s** |
| 17:15:41… | R15 soft-restart every **~20s** ×3 — never Ready |

Contrast: SessionLog 16:56 soft-restart → Ready **20.6s** under quiet 35s.

## Official

`resumeNetwork` reconnects **proxy** sockets once (`ConnectionTypeProxy`),
then waits. Not repeated client recreate every 20s.

## Implemented (R30)

1. After pause-suspend unsuspend: one `enableProxy` (proxy reconnect) + quiet **35s**.
2. `_fakeTlsQuietLongBg` = **35s** (revert R24 18s).
3. R15 soft-restart minWait **≥40s** (no thrash@20s).

Markers: `app-resume-unsuspend enableProxy … (proxy reconnect)`,
`faketls-quiet arm 35s why=app-resume-unsuspend`.
