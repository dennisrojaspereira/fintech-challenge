#!/usr/bin/env bash
set -euo pipefail

PARTICIPANT_URL=${PARTICIPANT_URL:-http://localhost:8081}
WARMUP_SECONDS=${WARMUP_SECONDS:-20}
TEST_SECONDS=${TEST_SECONDS:-120}
RPS=${RPS:-5}
WARMUP_RPS=${WARMUP_RPS:-2}
DUPLICATE_PERCENT=${DUPLICATE_PERCENT:-10}
MAX_POLL_SECONDS=${MAX_POLL_SECONDS:-20}
SLEEP_BETWEEN_POLLS=${SLEEP_BETWEEN_POLLS:-1}

run_id=$(date +%Y%m%d%H%M%S)
report_dir="reports"
mkdir -p "$report_dir"
report_file="$report_dir/simple-test-$run_id.json"

tmpdir=$(mktemp -d)
latencies="$tmpdir/latencies.txt"
payments="$tmpdir/payments.txt"
errors="$tmpdir/errors.txt"
dedup_errors="$tmpdir/dedup_errors.txt"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

calc_sleep() {
  awk -v rps="$1" 'BEGIN { if (rps <= 0) { print 0.2 } else { printf "%.3f", 1/rps } }'
}

sleep_warmup=$(calc_sleep "$WARMUP_RPS")
sleep_main=$(calc_sleep "$RPS")

send_once() {
  local idem="$1"
  local txid="$2"
  local amount="$3"
  local receiver_key="$4"
  local client_ref="$5"
  local body
  body=$(printf '{"txid":"%s","amount":%s,"receiver_key":"%s","description":"teste","client_reference":"%s"}' "$txid" "$amount" "$receiver_key" "$client_ref")

  local resp
  resp=$(curl -sS -o "$tmpdir/resp.json" -w "\n%{http_code}\n%{time_total}\n" \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $idem" \
    -X POST "$PARTICIPANT_URL/pix/send" \
    -d "$body" || true)

  local http_code
  local time_total
  http_code=$(echo "$resp" | tail -n 2 | head -n 1)
  time_total=$(echo "$resp" | tail -n 1)

  if [[ -z "$http_code" || -z "$time_total" ]]; then
    echo "invalid_response" >> "$errors"
    echo "|0|0"
    return
  fi

  local latency_ms
  latency_ms=$(awk -v t="$time_total" 'BEGIN { printf "%.0f", t*1000 }')
  echo "$latency_ms" >> "$latencies"

  local payment_id
  payment_id=$(sed -n 's/.*"payment_id"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$tmpdir/resp.json")

  echo "$payment_id|$http_code|$latency_ms"
}

warmup() {
  echo "Warmup por ${WARMUP_SECONDS}s em ${WARMUP_RPS} RPS..."
  local end=$(( $(date +%s) + WARMUP_SECONDS ))
  local i=0
  while [[ $(date +%s) -lt $end ]]; do
    i=$((i+1))
    local idem="warmup-$run_id-$i"
    local txid="tx-w-$run_id-$i"
    send_once "$idem" "$txid" 1000 "chave@pix" "ref-w-$i" >/dev/null
    sleep "$sleep_warmup"
  done
}

main_load() {
  echo "Carga principal por ${TEST_SECONDS}s em ${RPS} RPS..."
  local end=$(( $(date +%s) + TEST_SECONDS ))
  local i=0
  while [[ $(date +%s) -lt $end ]]; do
    i=$((i+1))
    local idem="idem-$run_id-$i"
    local txid="tx-$run_id-$i"

    if (( RANDOM % 100 < DUPLICATE_PERCENT )); then
      local res1 res2 pid1 pid2
      res1=$(send_once "$idem" "$txid" 1500 "chave@pix" "ref-$i")
      res2=$(send_once "$idem" "$txid" 1500 "chave@pix" "ref-$i")
      pid1=$(echo "$res1" | cut -d '|' -f 1)
      pid2=$(echo "$res2" | cut -d '|' -f 1)
      if [[ -n "$pid1" && -n "$pid2" && "$pid1" != "$pid2" ]]; then
        echo "$idem:$pid1!=${pid2}" >> "$dedup_errors"
      fi
      [[ -n "$pid1" ]] && echo "$pid1" >> "$payments"
    else
      local res
      res=$(send_once "$idem" "$txid" 1500 "chave@pix" "ref-$i")
      local pid
      pid=$(echo "$res" | cut -d '|' -f 1)
      [[ -n "$pid" ]] && echo "$pid" >> "$payments"
    fi

    sleep "$sleep_main"
  done
}

reconcile() {
  echo "Reconciliação (poll) por até ${MAX_POLL_SECONDS}s por pagamento..."
  local finalized=0
  local pending=0

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local done=0
    local start=$(date +%s)
    while [[ $(date +%s) -lt $((start + MAX_POLL_SECONDS)) ]]; do
      local resp
      resp=$(curl -sS -o "$tmpdir/get.json" -w "\n%{http_code}\n" \
        -X GET "$PARTICIPANT_URL/pix/send/$pid" || true)

      local http_code
      http_code=$(echo "$resp" | tail -n 1)
      if [[ "$http_code" != "200" ]]; then
        sleep "$SLEEP_BETWEEN_POLLS"
        continue
      fi

      local status
      status=$(sed -n 's/.*"status"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$tmpdir/get.json")

      if [[ -n "$status" && "$status" != "PENDING" && "$status" != "SENT" && "$status" != "CREATED" ]]; then
        finalized=$((finalized+1))
        done=1
        break
      fi

      sleep "$SLEEP_BETWEEN_POLLS"
    done

    if [[ $done -eq 0 ]]; then
      pending=$((pending+1))
    fi
  done < "$payments"

  echo "$finalized|$pending"
}

warmup
main_load

reconcile_result=$(reconcile)
finalized=$(echo "$reconcile_result" | cut -d '|' -f 1)
pending=$(echo "$reconcile_result" | cut -d '|' -f 2)

total_requests=$(wc -l < "$latencies" | tr -d ' ')
http_errors=$(wc -l < "$errors" | tr -d ' ')
idem_mismatches=$(wc -l < "$dedup_errors" | tr -d ' ')

p95=0
p99=0
if [[ "$total_requests" -gt 0 ]]; then
  p95_index=$(( (total_requests*95 + 99) / 100 ))
  p99_index=$(( (total_requests*99 + 99) / 100 ))
  p95=$(sort -n "$latencies" | awk -v idx="$p95_index" 'NR==idx {print; exit}')
  p99=$(sort -n "$latencies" | awk -v idx="$p99_index" 'NR==idx {print; exit}')
fi

cat > "$report_file" <<JSON
{
  "participant_url": "${PARTICIPANT_URL}",
  "warmup_seconds": ${WARMUP_SECONDS},
  "test_seconds": ${TEST_SECONDS},
  "rps": ${RPS},
  "duplicate_percent": ${DUPLICATE_PERCENT},
  "total_requests": ${total_requests},
  "http_errors": ${http_errors},
  "idempotency_mismatches": ${idem_mismatches},
  "latency_ms_p95": ${p95},
  "latency_ms_p99": ${p99},
  "finalized": ${finalized},
  "pending": ${pending}
}
JSON

echo "Relatório gerado em: $report_file"
