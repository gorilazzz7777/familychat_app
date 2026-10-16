# O6 — HTTPS / FakeTLS decouple (2026-10-09)

## Problem

`159.194.200.164:443` was nginx **stream ssl_preread** mux:

- site SNI (`familychat-app.ru`, …) → `127.0.0.1:4443`
- empty / unknown SNI → `127.0.0.1:8443` (mtg)

Phone `109.252.61.3` logged many `sni= upstream=8443`. API HTTPS then looked
dead (Client Hello, no Server Hello) while `:80` and Google worked.

## Options considered

| # | Idea | Verdict |
|---|------|---------|
| A | Only fix map (empty→4443 / reject) | Partial; mux stays |
| B | Drop mux; pure HTTPS nginx on 164:443 | Tried — PC OK; **phone TCP-timeout on :443** |
| C | New IP / Cloudflare for API | Later; needs DNS/CF |
| D | **TCP proxy 443→4443 (no mtg) + app `:4443`** | **Chosen** |

App FakeTLS already uses `244.213:443` + `164:8443` only (`TdlibConfig`).

## Implemented (VPS)

1. Disabled `/etc/nginx/stream.d/mtg-sni.conf` → `*.disabled-decouple-*`
   (empty/unknown SNI **never** goes to mtg again).
2. Stream `https-443-to-4443.conf`: `159.194.200.164:443` → `127.0.0.1:4443`
   (byte-transparent; websites only).
3. HTTP SSL for sites stays on `:4443` (not competing with mtg-wifi on
   `244.213:443`).
4. `familychat-app.ru:80` → `301 https://$host:4443$request_uri`
   (phone path that blocks `:443` can still bootstrap via HTTP).
5. App defaults (`lib/core/config/env.dart`) → `https://familychat-app.ru:4443/…`
6. Backup: `/root/nginx_decouple_20261009_125216`

## Topology now

| Port | Role |
|------|------|
| `200.164:443` | **TCP proxy → :4443** (no FakeTLS / no empty→mtg) |
| `200.164:4443` | Website HTTPS (canonical for phone / FC app) |
| `200.164:8443` | mtg FakeTLS |
| `244.213:443` | mtg-wifi FakeTLS (primary FC hop) |

## Phone evidence (post-decouple)

- `164:443` — TCP timeout (ISP path)
- `164:4443` — HTTP 200 ~80ms
- `164:80` — reachable (redirect to `:4443`)

## Rollback

```bash
# restore stream + site files from
/root/nginx_decouple_20261009_125216/
nginx -t && systemctl restart nginx
```
