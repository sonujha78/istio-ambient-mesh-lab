#!/usr/bin/env bash
set -uo pipefail
NS=ambient-demo
OUT=/tmp/waypoint-kill
rm -rf "$OUT"; mkdir -p "$OUT"

RIP=$(kubectl get pod -n $NS -l app=reviews,version=v1 -o jsonpath='{.items[0].status.podIP}')

probe() {  # $1=label $2=url $3=mode (code|body)
  while true; do
    ts=$(date +%s.%3N)
    if [ "$3" = body ]; then
      res=$(kubectl exec -n $NS deploy/curl -- curl -s -m 3 -w "\n%{http_code}" "$2" 2>/dev/null)
      code=$(echo "$res" | tail -1)
      echo "$res" | grep -q "currently unavailable" && code="200-DEGRADED"
    else
      code=$(kubectl exec -n $NS deploy/curl -- curl -s -m 3 -o /dev/null -w "%{http_code}" "$2" 2>/dev/null)
    fi
    echo "$ts $1 ${code:-ERR}" >> "$OUT/$1.log"
    sleep 0.3
  done
}

echo "== preflight =="
for spec in "W1 http://reviews:9080/reviews/0" "W2 http://ratings:9080/ratings/0" "W3 http://productpage:9080/productpage" "W4 http://$RIP:9080/reviews/0"; do
  read -r L URL <<< "$spec"
  c=$(kubectl exec -n $NS deploy/curl -- curl -s -m 3 -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null)
  echo "$L ($URL): ${c:-ERR}"
  if [ "$c" != "200" ] && [ "$L" != "W4" ]; then echo "preflight failed, aborting"; exit 1; fi
done

PIDS=()
probe W1 "http://reviews:9080/reviews/0" code & PIDS+=($!)
probe W2 "http://ratings:9080/ratings/0" code & PIDS+=($!)
probe W3 "http://productpage:9080/productpage" body & PIDS+=($!)
probe W4 "http://$RIP:9080/reviews/0" code & PIDS+=($!)
sleep 10

SEL="gateway.networking.k8s.io/gateway-name=waypoint"
OLD=$(kubectl get pod -n $NS -l $SEL -o jsonpath='{.items[0].metadata.name}')
echo; echo "== killing waypoint pod $OLD =="
T_KILL=$(date +%s.%3N)
kubectl delete pod -n $NS "$OLD" --wait=false
NEW=""
for i in $(seq 1 240); do
  NEW=$(kubectl get pod -n $NS -l $SEL --no-headers \
        -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].ready 2>/dev/null \
        | awk -v o="$OLD" '$1!=o && $2=="true"{print $1}')
  [ -n "$NEW" ] && break
  sleep 0.5
done
T_READY=$(date +%s.%3N)
echo "replacement waypoint: ${NEW:-NONE}, ready after $(awk -v a="$T_KILL" -v b="$T_READY" 'BEGIN{printf "%.1f", b-a}')s"
sleep 15
kill "${PIDS[@]}" 2>/dev/null
wait 2>/dev/null

echo; echo "== RESULT (times relative to kill = 0s) =="
for p in W1 W2 W3 W4; do
  awk -v k="$T_KILL" -v n="$p" '
    { t++; c[$3]++; if ($3 != "200") { f++; if (first == "") first = $1 - k; last = $1 - k } }
    END { printf "%s total=%d non200=%d first=%s last=%s codes:", n, t, f+0,
          (first=="" ? "-" : sprintf("%.1fs", first)), (last=="" ? "-" : sprintf("%.1fs", last));
          for (x in c) printf " %s=%d", x, c[x]; printf "\n" }
  ' "$OUT/$p.log"
done
cat "$OUT"/W*.log | sort -n > evidence/06-waypoint-kill-raw.log
