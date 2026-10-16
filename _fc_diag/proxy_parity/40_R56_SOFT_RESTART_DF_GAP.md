# R56 — post soft-restart file sockets are domain-fronting

mtg-wifi (`159.194.244.213:443`) vs SessionLog 2026-10-12 22:02–22:08, client `109.252.61.3`.

- Cold start Ready 22:02:59: main socket RELAY dc=2. First photos at 22:04:50 are RELAY dc=2 and dc=203, 87KB/156KB in ~4s.
- Pause 22:06:02 resets those RELAY sockets.
- Soft-restart Ready 22:06:27 (287ms): dc=2 RELAY again, but every `downloadFile` is domain-fronting (no dc=203) and finishes in ~26s with 0 bytes. Origin retry is another DF socket. Pong times out. Photos stay 0B until ~22:08:36.

Fix: the first post-restart CDN 0B cancels, holds new file sockets for 10s, then retries CDN once (`offset=0`). No origin on that first miss. A download that already got bytes is unchanged.

22:35 check: soft-restart Ready in 599ms. Files 14828 and 14818 completed CDN in ~380ms. File 14808 (19.6KB) was domain-fronting for ~25s; origin retry was another DF socket; `stall-give-up-small`. The gap did not run because `_lastNetMediaDoneAt` was already after the restart. A sibling net done does not make the next socket RELAY, so that check is removed.
