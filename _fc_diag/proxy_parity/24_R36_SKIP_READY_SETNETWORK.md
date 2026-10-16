# O20 — R36: skip force setNetworkType when Ready+FakeTLS (2026-10-11)

**Status: Implemented (R36)** — invariants §7 R36.

## Dig (post-R35 SessionLog 17:54)

| t | Event |
|---|--------|
| 17:51:33 | `skip None (Ready+FakeTLS)` |
| 17:51:36 | TDLib Ready→Connecting in bg |
| 17:54:06 | unlock bg=2m35s; briefly Ready again |
| 17:54:07 | `setNetworkType WiFi why=app-resume-ready` |
| 17:54:07.48 | **Ready→Connecting** (~180ms) |
| 17:54:47+ | longBg soft-restart×2 — no Ready |

R35 missed (long-bg first). Self-inflicted drop via force setNetworkType.

## Implemented

1. Resume while Ready+FakeTLS+proxy → **no** force `setNetworkType`.
2. Soft-pause under long-bg (≥2m) + !Ready → arm R34 early soft-restart.
3. `_resumeFromPauseSuspend` collapse @12s even when longBg flag set.

Markers:
- `app-resume-ready skip setNetworkType (Ready+FakeTLS)`
- `long-background-resume soft-pause Ready drop`
