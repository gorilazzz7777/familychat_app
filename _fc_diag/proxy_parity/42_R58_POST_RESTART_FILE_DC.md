# R58 — checked and rejected: 30s before the first file socket

mtg-wifi vs SessionLog 2026-10-13.

19:32–19:34 suggested the first post-restart `downloadFile` (same second as Ready) sends no ClientHello and poisons later retries. Cold start's first file 28s after Ready was RELAY dc=203.

Check 20:33 (this hold on device): soft-restart Ready 20:33:10, `media-wire-hold arm 30s why=post-restart-file-dc`, first `net-downloadFile` at 20:33:40. Still 0B at +5s, `stall-recover-gap`. mtg shows a DF socket 20:33:40–20:34:06 beside a short dc=203 relay 20:33:38–20:33:48 that did not deliver the file.

Do not keep the 30s hold. It delays every unlock and does not bring the photo.
