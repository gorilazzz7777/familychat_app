# HAVE — факты из наших логов (SessionLog + mtg)

Источник окна: `_fc_diag/last10h/` (pull ~2026-10-05), устройство RZCYA09MGVP, endpoint `ip2-443-cf` `159.194.244.213:443` FakeTLS epoch=9.

| # | Факт | Источник |
|---|------|----------|
| A1 | Секрет/порт/FakeTLS валидны: официальный ТГ на том же телефоне+прокси работает; FC тоже поднимал Ready | SessionLog `mtproto-up` 07:55 MSK; user report official OK |
| A2 | Domain fronting и relay — разные вещи. Полезны только `proxy.relay` + written bytes | `mtg_win.log`: DF vs relay counters |
| A3 | «Хорошее» окно FC медиа (07:55–08:05 MSK / 04:55–05:05 UTC): Wi‑Fi `109.252.61.3`, **DF=0 в первые минуты затем DF**, relay DC2/4, **~136 KB** written, **без DC203** | `analyze_mtg_vs_fc.py` + SessionLog `done source=net` ×48 |
| A4 | Stall фото 20568 (11:23–12:10 MSK): клиент `downloadFile` + STALL-0B ×143, `connectionStateConnecting`; с Wi‑Fi IP на mtg **0 events**; телефон уже на **mobile** | SessionLog + mtg correlate |
| A5 | В то же stall-окно чужие клиенты на mtg живы (`178.177…`, `31.173.85.36`, …) → **прокси глобально не мёртв** | `correlate_stall.py` |
| A6 | Megafon `31.173.*` через тот же mtg открывает **DC203** (CDN) + multi-DC → медиа-путь CDN на нашем прокси **возможен** | mtg relay `dc=203` |
| A7 | Heartbeat snapshots: ~88% `Connecting` + proxy ON (wifi/mobile) | `REPORT.md` |
| A8 | Первый ping после Ready: **Pong timeout** | SessionLog 07:55 |
| A9 | Media health done/(done+stall0) ≈ **25%** за окно; почти все успешные `done` утром | `proxy_quality_summary.json` |
| A10 | FC media: **slotLimit=1**; first download **CDN offset=0**; after Ready+0B → one origin (`forceBypass`/offset=1). Tap must not pre-force origin (R17) | код + SessionLog 00:14 |
| A11 | Ready→Connecting mid-download рвёт единственный слот; watchdog держит зомби `tap:photo:20568` | SessionLog 11:23→12:09 |
| A12 | wifi↔mobile + pause/resume → `app-resume-not-ready` / freeze-kick | SessionLog |
| A13 | Рестарт mtg иногда кратковременно улучшал relay (наблюдение прошлых сессий) | prior diag / agent notes |
| A14 | FC sqlite `familychat_chat.sqlite` — не TDLib session log; TG-диагностика только из `fc_diag/tg_*.jsonl` | `REPORT.md` |

## Вывод HAVE

Разрыв «official ок / FC плох» на **том же** FakeTLS объясняется в основном **клиентским поведением FC+TDLib** (Connecting, зомби-download, slot=1, thrash), а не мёртвым прокси. CDN DC203 на mtg реален (mobile egress), но FC в плохие минуты часто не имеет соответствующего relay с своего IP.
