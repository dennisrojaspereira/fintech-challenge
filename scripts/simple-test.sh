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
ledger_entries_file="$tmpdir/ledger-entries.json"
ledger_balances_file="$tmpdir/ledger-balances.json"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

calc_sleep() {
  awk -v rps="$1" 'BEGIN { if (rps <= 0) { print 0.2 } else { printf "%.3f", 1/rps } }'
}

wait_for_participant() {
  echo "Aguardando participante em $PARTICIPANT_URL/health..."
  for i in {1..30}; do
    if curl -fsS "$PARTICIPANT_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Participante não respondeu em $PARTICIPANT_URL/health" >&2
  return 1
}

clamp_0_100() {
  local v="$1"
  awk -v v="$v" 'BEGIN { if (v < 0) v = 0; if (v > 100) v = 100; printf "%.0f", v }'
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

  : > "$tmpdir/resp.json"
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
  if [[ -s "$tmpdir/resp.json" ]]; then
    payment_id=$(sed -n 's/.*"payment_id"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$tmpdir/resp.json")
  else
    payment_id=""
  fi

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

check_ledger() {
  ledger_status="missing"
  ledger_invalid_postings=0
  ledger_duplicate_postings=0
  ledger_negative_balances=0

  if ! command -v jq >/dev/null 2>&1; then
    ledger_status="skipped_no_jq"
    return
  fi

  local code_entries
  code_entries=$(curl -sS -o "$ledger_entries_file" -w "%{http_code}" \
    -X GET "$PARTICIPANT_URL/ledger/entries" || true)

  if [[ "$code_entries" != "200" ]]; then
    ledger_status="missing"
    return
  fi

  ledger_status="checked"

  ledger_invalid_postings=$(jq '[.entries[] | (
      (.lines | map(select(.direction=="DEBIT")|.amount) | add // 0) as $d |
      (.lines | map(select(.direction=="CREDIT")|.amount) | add // 0) as $c |
      select($d != $c)
    )] | length' "$ledger_entries_file")

  ledger_duplicate_postings=$(jq '[.entries[].posting_id] | group_by(.) | map(select(length>1)) | length' "$ledger_entries_file")

  local code_balances
  code_balances=$(curl -sS -o "$ledger_balances_file" -w "%{http_code}" \
    -X GET "$PARTICIPANT_URL/ledger/balances" || true)
  if [[ "$code_balances" == "200" ]]; then
    ledger_negative_balances=$(jq '[.balances[] | select(.amount < 0)] | length' "$ledger_balances_file")
  fi
}

wait_for_participant
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

check_ledger

total_finalized=$((finalized + pending))
success_rate=0
if [[ "$total_finalized" -gt 0 ]]; then
  success_rate=$(awk -v f="$finalized" -v t="$total_finalized" 'BEGIN { printf "%.4f", f/t }')
fi
error_rate=0
if [[ "$total_requests" -gt 0 ]]; then
  error_rate=$(awk -v e="$http_errors" -v t="$total_requests" 'BEGIN { printf "%.4f", e/t }')
fi
idem_rate=0
if [[ "$total_requests" -gt 0 ]]; then
  idem_rate=$(awk -v e="$idem_mismatches" -v t="$total_requests" 'BEGIN { printf "%.4f", e/t }')
fi

resilience_score=$(clamp_0_100 $(awk -v s="$success_rate" -v e="$error_rate" -v i="$idem_rate" 'BEGIN { printf "%.0f", 100*(s - e - i) }'))
state_score=$(clamp_0_100 $(awk -v s="$success_rate" 'BEGIN { printf "%.0f", 100*s }'))

perf_score=$(clamp_0_100 $(awk -v p95="$p95" -v p99="$p99" 'BEGIN {
  p95_pen = (p95 > 200) ? (p95 - 200) * 0.10 : 0;
  p99_pen = (p99 > 500) ? (p99 - 500) * 0.05 : 0;
  score = 100 - p95_pen - p99_pen;
  printf "%.0f", score;
}'))

ledger_ok=false
ledger_score=0
if [[ "$ledger_status" == "checked" ]]; then
  if [[ "$ledger_invalid_postings" -eq 0 && "$ledger_duplicate_postings" -eq 0 && "$ledger_negative_balances" -eq 0 ]]; then
    ledger_ok=true
    ledger_score=100
  else
    ledger_ok=false
    ledger_score=0
  fi
fi

ops_score=0
ops_status="manual_review"

overall_approved=false
if [[ "$ledger_ok" == "true" && "$resilience_score" -ge 70 && "$state_score" -ge 70 ]]; then
  overall_approved=true
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
  "pending": ${pending},
  "ledger": {
    "status": "${ledger_status}",
    "ok": ${ledger_ok},
    "invalid_postings": ${ledger_invalid_postings},
    "duplicate_postings": ${ledger_duplicate_postings},
    "negative_balances": ${ledger_negative_balances}
  },
  "scores": {
    "ledger": ${ledger_score},
    "resilience": ${resilience_score},
    "states": ${state_score},
    "operations": ${ops_score},
    "performance": ${perf_score}
  },
  "notes": {
    "operations": "${ops_status}",
    "ledger_requires_jq": true
  },
  "approved": ${overall_approved}
}
JSON

echo "Relatório gerado em: $report_file"
