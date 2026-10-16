# R67 — wifi→mobile use :8443 (2026-10-14 09:31Z)

## Evidence

R66 reopen ran (`bearer-recover:…:down/up`) but stayed on `ip2-443-cf`.

mtg-wifi: cellular `31.173.86.15` → many `cannot read client hello i/o timeout`.
Wi‑Fi `178.177.48.241` same minute → RELAY. Phone internet OK; FakeTLS to
mtg-wifi:443 from carrier is not.

`TdlibConfig`: `:8443` = mobile mtg; `:443` mtg-wifi = home Wi‑Fi.

## Fix

On link wifi↔mobile (and soft-restart `ensure` on that radio): pick hop by
port (`8443` mobile / `443` wifi) before enableProxy. No preferred pref write.
