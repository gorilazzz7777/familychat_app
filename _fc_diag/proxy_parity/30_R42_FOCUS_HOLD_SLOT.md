# O26 — R42: focus-hold / FakeTLS slot (media while Ready) (2026-10-11)

**Status: Implemented (R42).** Does **not** change R40/R41 pause-resume.

## Dig (r41_check SessionLog 20:13 / 20:22)

Ready+proxyOn, but media 0B:
- `focus_hold` kept channel `heldMsgId` after `openChat` → DM
- `purge-non-focus` kept foreign focus file (`focus.contains` before foreign)
- FakeTLS `inflight=2` while `slotLimit=1` (`_downloadActive` desync)
- `tap:photo` 333KB used focus Ready 0B budget 35s

## Implemented

1. Clear focus claim + purge on chat switch (`focus-hold clear why=open-chat:…`).
2. Purge: foreign chat drops before `focus.contains`.
3. Pump gates on `_downloadInFlight.length` too.
4. Stale hold if held msg not in current chat.
5. `tap:photo` Ready+0B budget 12s; skip lastchance like small thumbs.
6. Give-up clears focus claim.

Pause/resume / late-None / soft-restart-first / quiet 35s unchanged.
