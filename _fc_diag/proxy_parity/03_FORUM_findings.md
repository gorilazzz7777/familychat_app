# FORUM — applicable findings (mtg + TDLib + MTProxy)

Отобраны только выводы, применимые к нашему стеку (TDLib + mtg FakeTLS) или явно помеченные как «другой софт».

| # | Finding | Источник | Applicable? |
|---|---------|----------|-------------|
| F1 | **Ignore connectionState** — human-readable hint; запросы при `authorizationStateReady` | tdlib/td#1176 levlam | **Да — прямо ломает нашу Ready-gate политику** |
| F2 | Нет API «прокси упал»; смену прокси в regular apps делает пользователь | tdlib/td#3319 levlam | Да — нужен свой health (bytes/ping) |
| F3 | Нет «stalled» downloads: `is_downloading_active` true пока не скачается; при плохой сети cancel + async re-`downloadFile` | tdlib/td#2585, #3017 levlam | Да — уже частично в FC; не пинать pingProxy как cure |
| F4 | Один concurrent download request на file_id; priority влияет на ещё не посланные parts | tdlib/td#3017 | Да — spam re-downloadFile на тот же id бесполезен |
| F5 | mtg = **direct only**, без MiddleProxy; «text ok / media no» на том же IP, где ME-прокси (telemt) работает — другой uplink path | 9seconds/mtg#406 | Да — не ждать ME-фикса от mtg; сравнивать FC vs official на **том же** mtg |
| F6 | DC203 = CDN; `cannot dial to 203` / no addresses → media дырявое; workaround `allow-fallback-on-unknown-dc=true`, осторожно с `auto-update` | mtg#208, discussions #381, PR#344 | **Да — проверить конфиг нашего mtg на VPS** |
| F7 | Upstream Telegram DC IP timeout (в т.ч. DC203) — вина reachability с VPS, не FakeTLS handshake | mtg discussion #381 | Да — `mtg doctor` / dial tests на VPS |
| F8 | Non-Premium media часто требует MiddleProxy + корректный egress NAT (`middle_proxy_nat_ip`) | sleep3r/mtproto.zig#249,#366 | **Нет для mtg** (нет ME); полезно если когда-нибудь сменим прокси-софт |
| F9 | Сообщения «FakeTLS flawed / dd better for RU 2026» в alexbers/mtprotoproxy — anecdotal, другой daemon | alexbers#312 | Слабо; наш official на том же ee уже ок → не корневая причина FC |
| F10 | Невозможно заранее знать, что прокси «будет работать» — только пробовать | tdlib/td#537 levlam | Да — A/B + ping + media probe |

## Топ действий из форумов (не код политики FC)

1. Пересмотреть Ready-gating (F1) — **DOC+FORUM closed**.
2. На VPS: `allow-fallback-on-unknown-dc`, `mtg doctor` DC1–5+203 (F6/F7) —
   **DONE 2026-10-05** (`07_VPS_O1.md`): simple-run already fallback ON;
   dial OK; phone had dc203 relay. No flag change.
3. Не путать симптомы ME-прокси с mtg (F5/F8).
4. Health-метрики клиента обязательны (F2/F10) → R10 evenIfReady probe after give-up.
