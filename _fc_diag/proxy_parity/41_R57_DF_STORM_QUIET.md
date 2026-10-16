# R57 — Ready+proxy 0B photos are a domain-fronting storm

SessionLog + mtg-wifi, client `109.252.61.3`, 2026-10-13.

Same shape at 08:58, 12:00, 13:06 and 19:08:

- UI is Ready, proxy on. A photo completes on CDN in under 2s (19:08:12 RELAY dc=203, 26KB in 1.4s; 12:00:23 80KB in 1.6s).
- The next file stays at 0 bytes. mtg shows `proxy.domain-fronting` starting every ~3s, each socket ~26s, plus `cannot read client hello` timeouts. No dc=203 on those sockets.
- The client then force-origin (`offset=1`). That is another DF socket, so the storm continues and the small file hits `stall-give-up-small`.
- Pong times out while the 0B download holds the only FakeTLS slot. The alt-hop probe also times out, so R51g correctly refuses to hop. The plane was not dead: the previous file had just completed.

R56's 10s quiet ran at 19:10 and the retry was still DF, because those sockets live ~26s and a new `downloadFile` starts more of them.

Fix: non-video Ready+FakeTLS 0B cancels on the next watchdog tick (~4s), holds new file sockets 22s, retries CDN once, and does not origin. A second 0B gives up. A later `done source=net` clears the streak. Video keeps the 35s budget.

Check 19:33–19:35 (this build): before pause, dc=203 RELAY wrote 4135 bytes. After soft-restart the first photo was DF; the 22s CDN retry was still DF. TDLib kept opening those sockets after cancel, and focus re-queued the same id every 5s. Give-up now sticks inside `_queueFileDownload`. After two quiets with no net `done`, further 0B files are not put on the wire.
