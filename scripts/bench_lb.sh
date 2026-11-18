#!/bin/bash
set -e
MODE="$1"
if [[ "$MODE" != "rr" && "$MODE" != "lc" && "$MODE" != "iphash" ]]; then
  echo "Pakai: bash /var/www/capstone/scripts/bench_lb.sh [rr|lc|iphash]"
  exit 1
fi

LOGFILE="/tmp/lb_result_${MODE}.txt"
exec > >(tee "$LOGFILE") 2>&1

cd /var/www/capstone
set -a && source .env && set +a

python3 - "$MODE" <<'PY'
import sys, re
mode = sys.argv[1]
directive = {
    "rr": "    # Round Robin (default - tanpa direktif khusus)",
    "lc": "    least_conn;    # Algoritma: Least Connection",
    "iphash": "    ip_hash;       # Algoritma: IP Hash (Sticky Session)",
}[mode]
with open("nginx.conf", "r", encoding="utf-8") as f:
    text = f.read().replace("\r\n", "\n")
text = re.sub(r"(upstream app_backend \{\n)([^\n]*\n)", r"\1" + directive + "\n", text, count=1)
with open("nginx.conf", "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
PY

docker compose restart nginx >/dev/null
sleep 2

echo "============================================================"
echo " MODE AKTIF: $MODE"
echo "============================================================"
echo "[1] Cek upstream di container nginx:"
docker compose exec -T nginx grep -A 4 "upstream app_backend" /etc/nginx/conf.d/default.conf

docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "UPDATE products SET stock = 50000 WHERE id <= 5;" >/dev/null

APP1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' capstone-app1-1)
APP2_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' capstone-app2-1)

sleep 2
SINCE_AB=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ""
echo "[2] Uji Resmi Modul: ab -n 1000 -c 50 http://168.110.212.41/api/products"
ab -n 1000 -c 50 http://168.110.212.41/api/products | grep -E "Complete requests|Failed requests|Non-2xx|Requests per second|Time per request:|50%|95%|100%"

sleep 1
LOGS_AB=$(docker compose logs nginx --since "$SINCE_AB" 2>/dev/null || true)
C1_AB=$(echo "$LOGS_AB" | grep -c "$APP1_IP:3000" || true)
C2_AB=$(echo "$LOGS_AB" | grep -c "$APP2_IP:3000" || true)
TOT_AB=$((C1_AB + C2_AB))
if [ "$TOT_AB" -gt 0 ]; then
  P1_AB=$(python3 -c "print(f'{($C1_AB/$TOT_AB)*100:.1f}')")
  P2_AB=$(python3 -c "print(f'{($C2_AB/$TOT_AB)*100:.1f}')")
else
  P1_AB="0.0"; P2_AB="0.0"
fi
echo "Distribusi AB (app1=$APP1_IP vs app2=$APP2_IP): app1=$C1_AB ($P1_AB%) | app2=$C2_AB ($P2_AB%)"

sleep 2
echo ""
echo "[3] Uji Beban Campuran POS Kafe 20 detik (70% GET + 30% POST ACID, 24 workers)"
python3 - <<'PY'
import json, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from collections import Counter

BASE = "http://168.110.212.41"
STOP_AT = time.time() + 20.0
results = []

def worker(wid):
    idx = wid
    out = []
    while time.time() < STOP_AT:
        t0 = time.perf_counter()
        if idx % 10 < 3:
            pid = (idx % 5) + 1
            req = urllib.request.Request(
                f"{BASE}/api/transactions",
                data=json.dumps({"product_id": pid, "quantity": 1, "payment_method": "QRIS", "cashier_name": f"Kasir-{wid}"}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            kind = "POST"
        else:
            req = urllib.request.Request(f"{BASE}/api/products")
            kind = "GET"
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = json.loads(r.read().decode())
                dt = (time.perf_counter() - t0) * 1000
                out.append((kind, r.status, body.get("served_by", "?"), dt))
        except Exception:
            out.append((kind, 0, "ERR", (time.perf_counter() - t0) * 1000))
        idx += 1
    return out

t_start = time.perf_counter()
with ThreadPoolExecutor(max_workers=24) as ex:
    for chunk in ex.map(worker, range(24)):
        results.extend(chunk)
elapsed = time.perf_counter() - t_start

ok = [r for r in results if r[1] in (200, 201)]
err = len(results) - len(ok)
cnt = Counter(r[2] for r in ok)
a1, a2 = cnt.get("app1", 0), cnt.get("app2", 0)
tot = a1 + a2 if (a1 + a2) > 0 else 1
gets = [r[3] for r in ok if r[0] == "GET"]
posts = [r[3] for r in ok if r[0] == "POST"]
avg_all = sum(r[3] for r in ok) / len(ok) if ok else 0
print(f"Total OK: {len(ok)} | Error: {err} | Durasi: {elapsed:.2f}s | RPS: {len(ok)/elapsed:.1f}")
print(f"Distribusi Mixed: app1={a1} ({a1/tot*100:.1f}%) | app2={a2} ({a2/tot*100:.1f}%)")
print(f"Latensi Mean: Overall={avg_all:.1f}ms | GET={sum(gets)/len(gets):.1f}ms (n={len(gets)}) | POST={sum(posts)/len(posts):.1f}ms (n={len(posts)})")
PY

sleep 2
echo ""
echo "[4] Metrik CPU & RAM Puncak (Prometheus):"
python3 - <<'PY'
import json, urllib.request, urllib.parse
def q(expr):
    url = "http://localhost:9090/api/v1/query?query=" + urllib.parse.quote(expr)
    with urllib.request.urlopen(url, timeout=5) as r:
        data = json.loads(r.read().decode())
        res = data.get("data", {}).get("result", [])
        return float(res[0]["value"][1]) if res else 0.0
cpu_30 = q('100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[30s])) * 100)')
cpu_1m = q('100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)')
ram_now = q('(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100')
print(f"CPU (30s): {cpu_30:.2f}% | CPU (1m): {cpu_1m:.2f}% | RAM terpakai: {ram_now:.2f}%")
PY

echo ""
echo "[5] Cuplikan 12 baris terakhir Log Nginx:"
docker compose logs nginx --tail=12
echo ""
echo "Log tersimpan di: $LOGFILE"
