# -*- coding: utf-8 -*-
"""Correlate FC SessionLog (tg.proxy plane / media) with mtg jsonl window.

Usage:
  python _fc_diag/proxy_parity/correlate_plane_mtg.py \\
      --client path/to/tg_YYYYMMDD_HH.jsonl \\
      --mtg path/to/mtg_window.log \\
      [--phone-ip 109.252.61.3]
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


def parse_ts(o):
    for k in ("ts", "timestamp", "t", "time"):
        if k not in o:
            continue
        v = o[k]
        if isinstance(v, (int, float)):
            # mtg ms epoch
            if v > 1e12:
                return datetime.fromtimestamp(v / 1000, tz=timezone.utc)
            if v > 1e9:
                return datetime.fromtimestamp(v, tz=timezone.utc)
        try:
            return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        except Exception:
            pass
    return None


def load_jsonl(path: Path):
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", required=True, type=Path)
    ap.add_argument("--mtg", required=True, type=Path)
    ap.add_argument("--phone-ip", default="", help="Optional filter for mtg client-ip")
    args = ap.parse_args()

    client = load_jsonl(args.client)
    mtg = load_jsonl(args.mtg)

    planes = [o for o in client if o.get("cat") == "tg.proxy" and o.get("evt") == "plane"]
    stalls = [
        o
        for o in client
        if o.get("cat") == "tg.media" and str(o.get("evt", "")).startswith("stall")
    ]
    starts = [o for o in client if o.get("cat") == "tg.media" and o.get("evt") == "download_start"]

    print(f"client events={len(client)} plane={len(planes)} stall={len(stalls)} download_start={len(starts)}")

    # Per-minute mtg DF/relay
    by_min = defaultdict(lambda: {"df": 0, "rel": 0, "b": 0, "dcs": Counter()})
    for o in mtg:
        if args.phone_ip and o.get("client-ip") != args.phone_ip:
            continue
        t = parse_ts(o)
        if not t:
            continue
        key = t.strftime("%H:%M")
        if o.get("logger") == "proxy.domain-fronting":
            by_min[key]["df"] += 1
        if o.get("logger") == "proxy.relay":
            by_min[key]["rel"] += 1
            by_min[key]["dcs"][o.get("dc")] += 1
            m = re.search(r"written (\d+) bytes", str(o.get("message") or ""))
            if m:
                by_min[key]["b"] += int(m.group(1))

    print("\nmtg by minute UTC" + (f" ip={args.phone_ip}" if args.phone_ip else " (all IPs)"))
    for k in sorted(by_min):
        c = by_min[k]
        if c["df"] or c["rel"]:
            print(
                f"  {k} DF={c['df']:3d} rel={c['rel']:3d} bytes={c['b']:7d} dcs={dict(c['dcs'])}"
            )

    print("\nFC plane samples (last 12):")
    for o in planes[-12:]:
        t = parse_ts(o)
        inflight = o.get("inflight") or []
        print(
            f"  {t} conn={o.get('conn')} net={o.get('net')} "
            f"pong={o.get('lastPongMs')} slots={o.get('slots')} "
            f"inflight={len(inflight)} mediaReady={o.get('mediaReady')}"
        )

    if stalls:
        print(f"\nFC stalls: {len(stalls)} (showing up to 8)")
        for o in stalls[:8]:
            print(
                f"  {parse_ts(o)} evt={o.get('evt')} file={o.get('fileId')} "
                f"got={o.get('downloaded')}/{o.get('size')} "
                f"delta5s={o.get('bytesDelta5s')} conn={o.get('conn')} net={o.get('net')}"
            )


if __name__ == "__main__":
    main()
