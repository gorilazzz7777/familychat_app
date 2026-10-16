# Temp TDLib path wedged the FakeTLS download queue

SessionLog 2026-10-12 21:58, Mash album after a long Home resume (Ready in 635ms, a 4.7KB webp downloaded).

`focus-tail` file 14901 reached 526/526. `getFile` said completed, path `mtproto 5350556019816704464` (no extension). `_probeLocalFile` cached that path. `_completeFileDownload` refused it (`complete-defer`, not paint-ready). Stall recover freed the slot and called `_queueFileDownload`, which returned immediately because the cache was non-empty and did not pump. Seven later `focus-tail` jobs stayed queued with `inflight=0`.

Fix: do not cache a completed path that is not paint-ready (`probe-hit-unready`). Drop such a cache entry in enqueue and pump. Always pump after a progress-stall requeue so siblings are not stuck behind a silent no-op.
