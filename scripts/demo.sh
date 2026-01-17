#!/usr/bin/env bash
set -euo pipefail

BASE_URL=${BASE_URL:-http://localhost:8080}

echo "1) Enviando (cenario: confirm)"
resp=$(curl -sS -X POST "$BASE_URL/provider/pix/send" \
  -H 'Content-Type: application/json' \
  -H 'X-Mock-Scenario: confirm' \
  -d '{"idempotency_key":"idem-demo","txid":"tx-demo","amount":1500,"receiver_key":"chave@pix"}')

echo "$resp" | (command -v jq >/dev/null && jq || cat)

id=$(echo "$resp" | sed -n 's/.*"provider_payment_id"[ ]*:[ ]*"\([^"]*\)".*/\1/p')

if [[ -z "$id" ]]; then
  echo "Nao consegui extrair provider_payment_id" >&2
  exit 1
fi

echo "2) Consultando status (pode demorar alguns segundos)"
for i in {1..10}; do
  curl -sS "$BASE_URL/provider/pix/payments/$id" | (command -v jq >/dev/null && jq || cat)
  sleep 1
 done
