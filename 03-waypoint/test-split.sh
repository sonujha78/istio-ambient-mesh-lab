#!/usr/bin/env bash
# Usage: ./test-split.sh [N requests]
set -euo pipefail
N=${1:-100}
declare -A count=([v1]=0 [v2]=0 [v3]=0)
for i in $(seq 1 "$N"); do
  v=$(kubectl exec -n ambient-demo deploy/curl -- curl -s http://reviews:9080/reviews/0 \
        | grep -o 'reviews-v[0-9]' | head -1 | cut -d- -f2)
  count[$v]=$(( ${count[$v]:-0} + 1 ))
done
echo "requests=$N  v1=${count[v1]}  v2=${count[v2]}  v3=${count[v3]}"
