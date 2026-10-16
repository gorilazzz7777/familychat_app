# VPS O1 check — 2026-10-05 ~21:30 MSK

## Setup
- `mtg-wifi` = `simple-run` on `159.194.244.213:443` (preferred hop `ip2-443-cf`)
- `mtg` = `simple-run` on `:8443`
- No toml config → `allow-fallback-on-unknown-dc` flag N/A;
  mtg v2 **simple-run default = fallback ON** (inverse of config-run).

## Dial from VPS
All OK: DC1–5 classic + `91.108.56.*` + `91.105.192.100:443`.

## Phone `109.252.61.3` last 2h (mtg-wifi)
| metric | count |
|--------|------:|
| stream start | 1375 |
| domain-fronting | 2584 |
| relay | 82 |
| dc2 | 93 |
| dc4 | 12 |
| **dc203** | **18** |

No `cannot dial` / unknown-DC rejects in window. DC203 relay had written bytes.

## Decision
**Do not change mtg flags / do not restart.** Uplink+CDN map healthy.
Ready+0B tonight = client media-health ladder (R10), not VPS.
