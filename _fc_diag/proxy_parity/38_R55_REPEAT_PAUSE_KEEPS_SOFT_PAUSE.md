# R55 — repeat pause must keep soft-pause

SessionLog 2026-10-12 21:42–21:45 (`_fc_diag/media_loop/tg_now.jsonl`).

1. Lock while Ready+FakeTLS → `skip None` (`_softPausedReadyProxy=true`).
2. Ready→Connecting ~6s → late-None → WaitingForNetwork (`_appNetworkSuspended=true`). Flag stays true. This is R40: unlock must `soft-restart-first`.
3. A second `onAppPaused` at 21:42:36 (keyguard flicker, still background) re-armed pause-suspend. At 21:42:38 the client was already !Ready and not in quiet, so the R26 branch **cleared** `_softPausedReadyProxy` and fired `networkTypeNone` again.
4. Unlock at 21:44:41 (bg 2m22s) logged `long-background-resume → official-reopen` and **not** `soft-pause Ready drop`. `setNetworkType(WiFi)` after None does not bring RELAY. Kick waited 40s, then soft-restart. UI stayed «ожидание подключения к прокси».

Fix: if already suspended or `_softPausedReadyProxy` is set, `_applyPauseNetworkSuspend` returns (`app-pause-suspend skip repeat`) and does not clear the flag. Fresh zombie pause (flag false, not suspended) still fires None (R26/R27).
