#!/usr/bin/env bash
set -uo pipefail
NS=failure-demo
NODE=ambient-worker2      # ztunnel on this node gets killed
OUT=/tmp/ztunnel-kill
rm -rf "$OUT"; mkdir -p "$OUT"

IP_S1=$(kubectl get pod -n $NS probe-srv-w1 -o jsonpath='{.status.podIP}')
IP_S2=$(kubectl get pod -n $NS probe-srv-w2 -o jsonpath='{.status.podIP}')

probe() {  # $1=label $2=client pod $3=target ip
  while true; do
    ts=$(date +%s.%3N)
    code=$(kubectl exec -n $NS "$2" -- curl -s -m 2 -o /dev/null -w "%{http_code}" "http://$3/" 2>/dev/null)
    echo "$ts $1 ${code:-ERR}" >> "$OUT/$1.log"
    sleep 0.3
  done
}

echo "== preflight: all 4 paths must return 200 =="
for spec in "P1 probe-cli-w1 $IP_S1" "P2 probe-cli-w2 $IP_S2" "P3 probe-cli-w1 $IP_S2" "P4 probe-cli-w2 $IP_S1"; do
  read -r L CLI TGT <<< "$spec"
  c=$(kubectl exec -n $NS "$CLI" -- curl -s -m 3 -o /dev/null -w "%{http_code}" "http://$TGT/" 2>/dev/null)
  echo "$L ($CLI -> $TGT): ${c:-ERR}"
  [ "$c" = "200" ] || { echo "preflight failed, aborting"; exit 1; }
done

PIDS=()
probe P1 probe-cli-w1 "$IP_S1" & PIDS+=($!)
probe P2 probe-cli-w2 "$IP_S2" & PIDS+=($!)
probe P3 probe-cli-w1 "$IP_S2" & PIDS+=($!)
probe P4 probe-cli-w2 "$IP_S1" & PIDS+=($!)
sleep 10

OLD=$(kubectl get pod -n istio-system -l app=ztunnel --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
echo; echo "== killing $OLD (node $NODE) =="
T_KILL=$(date +%s.%3N)
kubectl delete pod -n istio-system "$OLD" --wait=false
NEW=""
for i in $(seq 1 240); do
  NEW=$(kubectl get pod -n istio-system -l app=ztunnel --field-selector spec.nodeName=$NODE --no-headers \
        -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].ready 2>/dev/null \
        | awk -v o="$OLD" '$1!=o && $2=="true"{print $1}')
  [ -n "$NEW" ] && break
  sleep 0.5
done
T_READY=$(date +%s.%3N)
echo "replacement ztunnel: ${NEW:-NONE}, ready after $(awk -v a="$T_KILL" -v b="$T_READY" 'BEGIN{printf "%.1f", b-a}')s"
sleep 15
kill "${PIDS[@]}" 2>/dev/null
wait 2>/dev/null

echo; echo "== RESULT (times relative to kill = 0s) =="
for p in P1 P2 P3 P4; do
  awk -v k="$T_KILL" -v n="$p" '
    { t++; if ($3 != "200") { f++; if (first == "") first = $1 - k; last = $1 - k } }
    END { printf "%s total=%d failed=%d first_fail=%s last_fail=%s\n", n, t, f+0,
          (first=="" ? "-" : sprintf("%.1fs", first)), (last=="" ? "-" : sprintf("%.1fs", last)) }
  ' "$OUT/$p.log"
done
cat "$OUT"/P*.log | sort -n > evidence/06-ztunnel-kill-raw.log
