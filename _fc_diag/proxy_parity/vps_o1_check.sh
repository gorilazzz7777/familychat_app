#!/bin/bash
set -e
echo "=== dial DCs ==="
for a in 149.154.175.50:443 149.154.167.51:443 149.154.175.100:443 149.154.167.91:443 149.154.171.5:443 91.108.56.100:443 91.108.56.165:443 91.105.192.100:443; do
  host=${a%:*}; port=${a#*:}
  if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then echo "$a -> OK"; else echo "$a -> FAIL"; fi
done
echo "=== cannot dial / dc203 last 2h mtg-wifi ==="
docker logs --since 2h mtg-wifi 2>&1 | grep -E 'cannot dial|"dc":203|unknown DC|fallback' | tail -30 || true
echo "=== phone 109.252.61.3 sample last 30m ==="
docker logs --since 30m mtg-wifi 2>&1 | grep -F '109.252.61.3' | grep -E 'dc|relay|Connected|finished|Stream' | tail -40 || true
echo "=== counts 2h ==="
docker logs --since 2h mtg-wifi 2>&1 | python3 -c '
import sys,re,collections
c=collections.Counter()
for line in sys.stdin:
  m=re.search(r"\"dc\":(\d+)", line)
  if m: c["dc"+m.group(1)]+=1
  if "cannot dial" in line: c["cannot_dial"]+=1
  if "109.252.61.3" in line:
    if "Stream has been started" in line: c["phone_start"]+=1
    if "domain-fronting" in line: c["phone_df"]+=1
    if "proxy.relay" in line: c["phone_relay"]+=1
    if m: c["phone_dc"+m.group(1)]+=1
print(dict(c))
'
echo "=== simple-run note ==="
echo "mtg simple-run has no allow-fallback flag; v2 default for simple-run = fallback ON"
docker exec mtg-wifi /mtg version || true
