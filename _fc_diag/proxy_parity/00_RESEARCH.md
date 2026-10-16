# Proxy parity research — сводка

Дата: 2026-10-05 (обновлено ~22:40 МСК).  
Артефакты: этот каталог + код SessionLog +  
`.cursor/rules/tdlib-faketls-media-invariants.mdc`.

## Статус: сделано vs осталось

### Сделано (LOCKED)

| # | Что | Где |
|---|-----|-----|
| R0–R5 | Research / A/B / SessionLog | `01`…`05` |
| R1–R3 | Auth-gate, DF cut, soft-resume | invariants §1–7 |
| R6–R8 | 0B budgets / CDN-first / Ready+0B | §2/§8 |
| R9 | Long lock grace + soft-restart | §7 |
| R10 | Ready+0B give-up → evenIfReady probe | §3/§8 |
| R11 | Soft-restart preserve longBg+guard | §7; 21:50 |
| R12 | Connecting ping miss → reopen×2 → hop-try | §7; 22:12 |
| R13 | **Resume already Connecting** (bg&lt;2m) → same escalate ladder | §7; SessionLog 22:36 |
| R14 | **FakeTLS quiet** + hop-try resets restartCount for new hop | §7; SessionLog 22:52–55 + mtg handshake EOF |
| R15 | **Collapse soft×2** under long-bg after quiet → soft-restart/probe/hop | §7; SessionLog 23:18 (~2m UX) |
| R16 | **Long-bg soft-restart-first** + post-hop `longbg-socket-reopen` | §7; SessionLog 23:36 (8m lock, no Ready) |
| R17 | **Tap CDN-first** — no `forceBypass` on `ensureFileLocal(tap:*)` | §8; SessionLog 00:14–00:17 |
| R18 | **VPN/geo vs AppBar** — pref=user intent; geo never sticky-OFF; mutate queue | §9; soak_r17 07–09.10 |
| R19 | **Ready+0B video budget 75→35s** (dead CDN ≠ live) | §2/§10; SessionLog 15:32 |
| O1 | VPS mtg read-only | **DONE** `07_VPS_O1.md` |
| O6 | **HTTPS/FakeTLS decouple** — drop stream mux on `164:443` | **DONE** 2026-10-09; sites on `164:443`, mtg on `244:443`+`164:8443` |

### Осталось

| # | Что | Зависимость |
|---|-----|-------------|
| O2 | slotLimit=1 | только A/B |
| O3 | Долгий Connecting без pause | observe |
| O5 | ME-прокси | не без решения |

## Шаг 5 — lock/unlock (R9–R16) + media (R17) + VPN/geo (R18)

| | |
|--|--|
| Grace | `online=false` только если Ready |
| bg ≥2m | `long-background-resume` → **soft-restart-first** (R16) |
| bg &lt;2m но уже Connecting | `connecting-on-resume escalate` → soft-nudge + ladder (R13) |
| Resume ещё Ready | soft-only |
| Ladder | soft→soft→restart → probe → reopen×2 → `longbg-hop-try` |
| After hop-try | reset restartCount + soft-restart cycle on new hop (R14) |
| Quiet | ~35s no repeat `enableProxy` while Connecting (R14) |
| R15 | while quiet — no soft kicks; after quiet — collapse soft×2 |
| R16 post-hop | hop debounce → `longbg-socket-reopen` (None→current), not soft-nudge forever |
| R17 | tap/ensure first download = CDN `offset=0` (stall → origin) |
| R18 | AppBar = user intent; geo never writes pref; ensure/disable queued |
| R19 | video Ready 0B budget 35s (dead CDN → origin sooner) |

## Долгий прогон (soak)

| | |
|--|--|
| **Старт** | **2026-10-09 ~15:40 МСК** — после R19 |
| Пред. | R18 ~15:25; media 15:32 CDN 75s 0B → origin done (`now_r18/CONSENSUS_R19.md`) |
| Тест | open channel + tap video under FakeTLS Ready |
| Маркеры | first `offset=0`; `stall_0b` ~35s (not ~75s); origin then progress/done |

## Реалистичная планка

Достижимо: VPN auto off/on; dead-CDN video → origin ~35s не ~75s.  
Недостижимо: клон tgnet.
