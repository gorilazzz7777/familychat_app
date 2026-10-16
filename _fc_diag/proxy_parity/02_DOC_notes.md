# DOC — TDLib / CDN / mtg (чтение без деплоя)

## 1. Proxy API (TDLib)

- С 1.3.0: `addProxy` / `enableProxy` / `disableProxy` / `pingProxy` / `proxyTypeMtproto`.
- `addProxy` можно вызывать даже до `setTdlibParameters`; proxy persists.
- Ответ на `addProxy`/`enableProxy` = прокси уже применяется к сетевым запросам (levlam, td#300).
- **Нет явной ошибки** «прокси timeout / bad credentials» (td#3319, levlam 2025):  
  `connectionStateConnectingToProxy` = попытка, не failure.  
  В regular apps смену прокси делает **пользователь вручную**.  
  → FC обязан сам детектить «текст есть / медиа мертва» по своим метрикам (`pingProxy`, bytesΔ, stall).

## 2. `connectionStateReady` ≠ «можно качать» / ≠ «всё живо»

Критическая цитата levlam (td#1176):

> Ignore connection state updates, they are to show a human-readable hint status and are completely irrelevant.  
> You can send most requests only if the authorization state is `authorizationStateReady`.

Следствия для FC:
- Гейтить `downloadFile` / recover / openMessageContent **только** на `connectionStateReady` — **не канон TDLib**.
- Официальный клиент (и правильный TDLib client) шлёт media RPC при `authorizationStateReady`, не дожидаясь «красивого» Ready в UI.
- Наш stall-defer `wait Ready` и kick при Connecting **расходятся** с рекомендацией мейнтейнера.

Уточнение: Ready всё же коррелирует с наличием main MTProto session; но **отсутствие Ready не значит «нельзя звать downloadFile»**, и наличие Ready не значит «все media/CDN DC живы».

## 3. FakeTLS / ConnectionCreator (TDLib source)

- Secret `ee…` → `emulate_tls()` → actor `TlsInit` с domain из secret + proxy secret.
- Обычный obfuscated / `dd` — другой путь (наш mtg v2 принимает только FakeTLS `ee`).
- Domain fronting на стороне **прокси** (не клиента): невалидный FakeTLS handshake → forward на реальный HTTPS host (SNI).

## 4. CDN media path ([core.telegram.org/cdn](https://core.telegram.org/cdn))

- Популярные файлы больших публичных каналов (≥~100k) → CDN DC (`dcOption.cdn`).
- Клиент: `upload.getFile` → возможно `upload.fileCdnRedirect` → отдельный коннект к CDN DC → `upload.getCdnFile` + hash verify с master DC.
- CDN не принимает updates; auth_key CDN может умереть (-404) → пересоздать.
- Ошибки token → fallback на master `upload.getFile`.
- **DC203** в наших mtg логах = типичный CDN id в регионе.

Implication: если mtg не знает IP CDN DC или режет unknown DC → медиа «текст ок, картинки нет».  
`allow-fallback-on-unknown-dc` на mtg смягчает (latency↑).  
Принудительный `downloadFile offset=1` (origin) в FC — обход CDN на стороне клиента; утром у нас работал, днём нет → проблема шире, чем только CDN.

## 5. mtg vs Middle Proxy

| | mtg v2 | ME-прокси (MTProxy / mtproto.zig ME) |
|--|--------|--------------------------------------|
| Режим | direct FakeTLS к DC | multiplex через Telegram middle-end |
| ad_tag / promotion | нет | да |
| non-Premium media | зависит от direct+CDN map | часто **требует** ME |
| DC203 | нужна актуальная карта / fallback | через ME иначе |

Наш стек = **mtg direct**. Нельзя чинить «как zig ME» без смены софта на VPS. Сравнение с official на **том же** mtg всё ещё валидно: official умеет качать через этот же direct FakeTLS.

## 6. downloadFile / offset

- TDLib: `offset` в `downloadFile` — позиция стриминга; `local.download_offset`, prefix size.
- FC: first attempt **CDN `offset=0`**; after Ready+0B stall → one origin (`offset=1` / forceBypass) — R8/R17.
- **R17**: `ensureFileLocal(tap:*)` must not pre-set forceBypass (SessionLog 00:14 burned ~75s origin-0B).
- levlam / stalled downloads (td#2585, уже в комментариях FC): нет «stalled» API — cancel + re-downloadFile.

## 7. Параллельность

- TDLib сам планирует downloads (приоритеты 1..32).
- FC `slotLimit=1` + cancel/suspend — **не** TDLib default; это анти-flood для FakeTLS.
- Official Android не ограничен одним нашим слотом; через тот же mtg может держать несколько DC-lanes.

## Закрытые DOC-пункты плана

| План | Статус |
|------|--------|
| 4 Middle Proxy | закрыт: наш mtg без ME |
| 5 CDN map / fallback | закрыт на уровне доки; LOG — проверить флаги на VPS |
| 6 Proxy API | закрыт |
| 7 Ready meaning | закрыт (+ сюрприз td#1176) |
| 8 Proxy errors | закрыт (нет сигнала) |
| 9 Parallel lanes | частично: default TDLib ≠ slot=1; точные лимиты — LOG |
| 11 CDN path | закрыт |
| 14 slotLimit vs official | закрыт концептуально |
