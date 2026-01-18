# fintech-challenge : Envio de Pix (Mock do Provedor)

Contamos com o apoio dos seguintes patrocinadores, que oferecerão benefícios exclusivos para os 3 primeiros colocados:

🟢 Woovi

Passagem aérea

Hospedagem

Visita ao datacenter da Woovi
Saiba mais: https://woovi.com/

🔵 Codecon

1 ingresso para o Codecon Summit
Saiba mais: https://codecon.dev/

🟣 FintechDev

Acesso completo ao curso FintechDev
Saiba mais: https://fintechdev.com.br/

Quer ser patrocinador ? Entre em contato https://technapratica.com.br

Este repositório entrega **um mock de provedor Pix** (simulador) + contratos (OpenAPI) para padronizar uma fintech-challenge focada em **resiliência, idempotência, deduplicação e reconciliação**.

A proposta: cada time implementa um serviço "participante" que expõe uma API mínima (`/pix/send`, `/webhooks/pix`, etc.) e conversa com o mock do provedor.

## O que tem aqui
- `mock-provider/`: mock do provedor Pix (HTTP) com caos (timeout, 5xx, duplicidade e fora de ordem)
- `participant-mock/`: participante mínimo para simular o backend no CI/local
- `contracts/participant-openapi.yaml`: contrato que cada time deve implementar
- `contracts/provider-openapi.yaml`: contrato do mock do provedor
- `docker-compose.yml`: sobe o mock localmente

---

## Rodando local (mock do provedor)
### Pré-requisitos
- Docker + Docker Compose

### Subir o mock
```bash
cd pix-fintech-challenge
docker compose up --build
```

Esse compose sobe também um **participante mock** em `http://localhost:8081`, para facilitar testes e CI.

Por padrão, o mock sobe com limites de CPU/memória (para fairness):
- CPU: 0.25
- Memória: 128 MB

Você pode ajustar esses valores no `docker-compose.yml`.

O mock fica em:
- Base URL: `http://localhost:8080`
- Health: `GET http://localhost:8080/health`

### Configurar o webhook do participante
O mock envia eventos para `WEBHOOK_URL` (definido no `docker-compose.yml`). Por padrão:
- `http://participant:8081/webhooks/pix` (quando usando o participante mock via compose)

Se você usar seu próprio participante fora do compose, ajuste `WEBHOOK_URL` para `http://host.docker.internal:8081/webhooks/pix` ou para o endereço que preferir.

Ou seja, seu serviço participante precisa estar rodando localmente na porta `8081` e expor `POST /webhooks/pix`.

No Linux, se `host.docker.internal` não resolver, você pode:
- trocar `WEBHOOK_URL` pelo seu IP local, ou
- usar `network_mode: host` no serviço do mock (mais simples, mas muda o isolamento).

#### Comportamento do webhook do mock
- Para cada pagamento, o mock envia **PENDING** e depois **CONFIRMED** ou **REJECTED**.
- Pode enviar **fora de ordem** (final antes de PENDING).
- Pode **duplicar o evento final** (mesmo conteúdo, `event_id` diferente).
- **Não há retry automático** no envio do webhook; se falhar, pode ser necessário reconciliar via `GET /provider/pix/payments/<id>`.
- Mesmo em cenários de timeout (`timeout_then_confirm/reject`), o webhook ainda é enviado após alguns milissegundos.

---

## Como o participante deve funcionar (regras do jogo)
O participante recebe a intenção de envio do cliente e processa em background:
- `POST /pix/send` **idempotente** (header `Idempotency-Key`)
- Persistir estado + auditoria
- Enviar para o provedor (mock)
- Fechar o estado final ao receber webhook (dedup por `event_id`)
- Ter reconciliação para pendências (consulta no provedor)

Contrato completo do participante:
- veja `contracts/participant-openapi.yaml`

---

## Chamando o mock do provedor
### 1) Iniciar envio no provedor (simulado)
```bash
curl -sS -X POST http://localhost:8080/provider/pix/send \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-Id: demo-123' \
  -d '{
    "idempotency_key": "idem-001",
    "txid": "tx-001",
    "amount": 1500,
    "receiver_key": "chave@pix",
    "description": "teste",
    "client_reference": "ref-001"
  }' | jq
```

O mock responde `202` com um `provider_payment_id`.

### 2) Consultar status no provedor (simulado)
```bash
curl -sS http://localhost:8080/provider/pix/payments/<provider_payment_id> | jq
```

---

## Caos e cenários de falha
Você pode forçar um cenário por request com o header `X-Mock-Scenario`:
- `success` → responde 202 e confirma via webhook
- `timeout_then_confirm` → simula timeout, mas confirma depois via webhook
- `timeout_then_reject` → simula timeout, mas rejeita depois via webhook
- `http500` → responde 500
- `accept_then_confirm` → responde 202 e confirma via webhook
- `accept_then_reject` → responde 202 e rejeita via webhook

Obs.: envio de eventos fora de ordem e duplicados é controlado por probabilidade via variáveis `P_OUT_OF_ORDER_EVENT` e `P_DUPLICATE_EVENT`.

Exemplo (forçando timeout):
```bash
curl -i -X POST http://localhost:8080/provider/pix/send \
  -H 'Content-Type: application/json' \
  -H 'X-Mock-Scenario: timeout_then_confirm' \
  -d '{"idempotency_key":"idem-002","txid":"tx-002","amount":1200,"receiver_key":"k"}'
```

### Modo probabilístico (default no compose)
Variáveis (ver `docker-compose.yml`):
- `P_TIMEOUT`, `P_HTTP500`, `P_DUPLICATE_EVENT`, `P_OUT_OF_ORDER_EVENT`
- `MIN_LATENCY_MS`, `MAX_LATENCY_MS`
- `FINALIZE_MIN_MS`, `FINALIZE_MAX_MS`

---

## Dica de checklist para o participante
- Idempotência: mesma `Idempotency-Key` → mesmo `payment_id` e sem duplicar envio
- Outbox/inbox (ou equivalente) para garantir entrega e reprocessamento
- Dedup webhook por `event_id`
- Máquina de estados com transições válidas (não regredir estado terminal)
- Retry com backoff + jitter e circuit breaker
- Timeouts definidos
- Observabilidade: logs estruturados, métricas, correlation-id, tracing
- Reconciliar pendências via consulta no provedor

---

## Teste simples (bash)
Um teste básico para validar idempotência, latência e reconciliação do participante.

O processo assume **10k enviando e 10k recebendo do Bacen** como referência de volume.

Pré-requisitos:
- Mock do provedor rodando em `http://localhost:8080`
- Participante rodando em `http://localhost:8081`

Diagrama de sequência do teste:
```mermaid
sequenceDiagram
  autonumber
  participant T as Simple Test
  participant P as Participante
  participant M as Provedor (Mock/Bacen)
  participant L as Ledger

  T->>P: GET /health
  P-->>T: 200 OK

  loop Warmup (RPS baixo)
    T->>P: POST /pix/send (Idempotency-Key)
    P->>L: registra hold/entrada
    P->>M: POST /provider/pix/send
    M-->>P: 202 Accepted
    P-->>T: 202 Accepted (payment_id)
  end

  loop Carga principal
    T->>P: POST /pix/send (Idempotency-Key)
    P->>L: registra hold/entrada
    P->>M: POST /provider/pix/send
    M-->>P: 202/5xx/timeout (cenário)
    P-->>T: 202 Accepted
  end

  M-->>P: POST /webhooks/pix (PENDING)
  M-->>P: POST /webhooks/pix (CONFIRMED/REJECTED)
  M-->>P: (opcional) webhook duplicado/fora de ordem
  P->>L: lança/fecha no ledger

  loop Reconciliação
    T->>P: GET /pix/send/{payment_id}
    P-->>T: status final
  end

  T->>P: GET /ledger/entries
  T->>P: GET /ledger/balances
  T-->>T: gera relatório JSON
```

Rodar o teste:
```bash
bash scripts/simple-test.sh
```

No Windows (PowerShell):
```powershell
./scripts/simple-test.ps1
```

Variáveis úteis:
- `PARTICIPANT_URL` (default: `http://localhost:8081`)
- `WARMUP_SECONDS` (default: 20)
- `TEST_SECONDS` (default: 120)
- `RPS` (default: 5)
- `DUPLICATE_PERCENT` (default: 10)
- `MAX_POLL_SECONDS` (default: 20)
- `RECONCILE_SAMPLE_SIZE` (default: 50)
- `BACEN_SEND_TARGET` (default: 10000)
- `BACEN_RECEIVE_TARGET` (default: 10000)

O script gera um relatório JSON em `reports/` com métricas básicas.
Para validação automática do **ledger**, recomenda-se ter `jq` instalado.

Exemplo de resultado esperado (valores ilustrativos):
```json
{
  "participant_url": "http://localhost:8081",
  "warmup_seconds": 20,
  "test_seconds": 120,
  "rps": 5,
  "duplicate_percent": 10,
  "bacen_send_target": 10000,
  "bacen_receive_target": 10000,
  "total_requests": 31852,
  "http_errors": 0,
  "idempotency_mismatches": 0,
  "latency_ms_p95": 6,
  "latency_ms_p99": 13,
  "finalized": 47,
  "pending": 3,
  "ledger": {
    "status": "checked",
    "ok": false,
    "invalid_postings": 0,
    "duplicate_postings": 0,
    "negative_balances": 1
  },
  "scores": {
    "ledger": 0,
    "resilience": 94,
    "states": 94,
    "operations": 0,
    "performance": 100
  },
  "notes": {
    "operations": "manual_review"
  },
  "approved": false
}
```

### CI (rodar o teste a cada commit)
Existe um workflow em [\.github/workflows/ci.yml](.github/workflows/ci.yml) que roda o teste simples em cada push/PR.

Para o CI funcionar, o participante precisa estar acessível. Configure a variável do repositório:
- `PARTICIPANT_URL` (ex.: `http://localhost:8081` ou o endereço público do seu participante)

O relatório do teste é publicado como artefato do workflow.

---

## Regras da competição e pontuação
### Objetivo
Construir um serviço resiliente que processe envios Pix com **idempotência**, **deduplicação**, **reconciliação** e **consistência final** dos estados.

### Duração e carga
- Janela de execução: 10 a 20 minutos.
- Carga variável com picos (ex.: 50–500 RPS).
- Mix de cenários com erros e eventos fora de ordem (via mock).

### Regras obrigatórias
- `POST /pix/send` idempotente (mesma `Idempotency-Key` → mesma resposta e sem duplicar envio).
- Deduplicação de webhooks por `event_id`.
- Estado final deve ser **CONFIRMED** ou **REJECTED** (sem regressão).
- Reconciliar pendências via consulta ao provedor.
- Não duplicar débito (um pagamento não pode liquidar duas vezes).

### Limites
- CPU e memória limitadas (definir no compose ou na infraestrutura).
- Timeouts de rede devem ser respeitados.
- Sem dependência de serviços externos não especificados.

### Métricas coletadas
- Taxa de sucesso (processos completos).
- Latência p95/p99 de `POST /pix/send`.
- Consistência final dos estados (sem divergências).
- Tolerância a falhas (retries sem duplicidade).

### Penalidades
- Pagamento liquidado mais de uma vez.
- Status divergente entre `GET /pix/payments` e base interna.
- Perda de evento ou estado “preso” indefinidamente.

### Pontuação (exemplo)
Pontuação normalizada entre 0 e 100:

$$
score = 100 \cdot \max\left(0, 0.55 \cdot S - 0.25 \cdot E - 0.20 \cdot L\right)
$$

Onde:
- $S$ = taxa de sucesso (0–1)
- $E$ = taxa de erros graves (0–1)
- $L$ = penalidade de latência (0–1), baseada em p95/p99

### Reprodutibilidade
- Semente fixa para o gerador de cenários.
- Relatório final com métricas + logs mínimos.

### Entregáveis
- Serviço participante executável.
- Instruções de execução (README).
- Relatório com métricas (ex.: JSON ou texto simples).

---

## Avaliação (score conceitual do Fintech Challenge)
O score responde a uma pergunta única:

**Esse backend consegue operar Pix sem perder dinheiro e sem colapsar sob falha?**

### Visão geral
O Fintech Challenge **não usa um único número mágico**.
O score é composto, baseado em critérios técnicos objetivos, com regras eliminatórias:

1) Primeiro valida se o sistema é financeiramente correto.
2) Depois mede se ele é resiliente e operável.
3) Só no final entra performance.

### Estrutura do score (pesos)
- Correção financeira (ledger): **40%**
- Resiliência e idempotência: **25%**
- Modelagem de estados: **15%**
- Operação e observabilidade: **10%**
- Performance: **10%**

---

### 1) Correção financeira (40%) – eliminatório
**Esse é o núcleo do challenge.**

O que é validado:
- Todo posting fecha: **débito = crédito**
- Nenhum double debit
- Nenhum saldo inconsistente
- Nenhum lançamento duplicado em retry/reprocessamento
- Estados terminais não alteram ledger

Como é medido:
- Automático via `/ledger/entries` e `/ledger/balances`

**Regra dura**:
Se falhar aqui, o score final é **zero**.
Não importa latência, stack ou arquitetura.

Isso reflete o mundo real: **fintech pode ser lenta, mas não pode errar dinheiro.**

---

### 2) Resiliência e idempotência (25%)
O que é testado:
- Timeout após envio
- Erros 5xx
- Retry com backoff
- Webhooks duplicados
- Eventos fora de ordem
- Confirmação tardia

Critérios de pontuação:
- Estado final correto
- Nenhuma duplicidade
- Recuperação automática
- Backlog processado após falha

Aqui o sistema é **maltratado** de propósito.

---

### 3) Modelagem de estados (15%)
Avaliação:
- Estados bem definidos
- Transições válidas
- Estados terminais imutáveis
- Nenhum estado ambíguo ou zumbi

Exemplos:
- `CONFIRMED` não pode voltar para `PENDING`
- `REJECTED` não pode gerar novos postings

Essa parte é parcialmente automática e parcialmente revisada.

---

### 4) Operação e observabilidade (10%)
Checklist:
- Logs estruturados
- `correlation_id`
- `payment_id` rastreável
- Métricas básicas (erro, latência, backlog)
- Capacidade de responder: “por que esse Pix está assim?”

Não é sobre stack de observabilidade, é sobre **operabilidade real**.

---

### 5) Performance (10%) – propositalmente secundário
O que conta:
- P95/P99 aceitáveis
- Sem degradação catastrófica
- Respeito a rate limit

O que não conta:
- Micro‑otimizações
- Hacks para ganhar benchmark

Performance **não compensa** erro financeiro.

---

### Como o score final é apresentado
O resultado não é só um número. É um relatório, por exemplo:

- Correção financeira: OK
- Resiliência: 82%
- Estados: OK
- Operação: OK
- Performance: 75%

**Resultado final: APROVADO**

Ou:

- Correção financeira: FALHOU

**Resultado final: REPROVADO**

---

### Diferença-chave para a rinha
Nao queremos: **“qual é o backend mais rápido?”**
Fintech Challenge pergunta: **“qual backend eu colocaria para operar Pix amanhã?”**

---

## Desafio extra: Ledger (para dificultar)
Além de manter o **status** do pagamento, cada implementação deve manter um **ledger contábil de dupla entrada** (double-entry) para garantir que o valor debitado e creditado fecha corretamente, mesmo com:
- retry, timeout e resposta duplicada
- eventos fora de ordem e duplicados
- reconciliação (consulta no provedor)

### Objetivo
Para cada pagamento, ao final do processamento, o saldo precisa refletir:
- o pagador foi debitado uma única vez quando o Pix é confirmado
- se o pagamento for rejeitado, qualquer "hold"/reserva deve ser estornada
- taxas devem ser registradas sem quebrar o fechamento contábil

### Reconciliação de Pagamentos

Em integrações Pix, timeout não significa falha.

Um Pix pode ser processado com sucesso pelo provedor (Bacen/PSP) mesmo que:

a requisição tenha retornado timeout,

o serviço do provedor tenha caído após processar,

o webhook de confirmação nunca chegue ou chegue atrasado.

Por isso, este desafio exige um mecanismo de reconciliação.

### O que é reconciliação

Reconciliação é um processo que verifica periodicamente pagamentos em estados intermediários (ex: PENDING) e consulta o provedor para descobrir o estado real da transação.

Ela garante que o sistema:

não deixe dinheiro preso em hold,

não fique indefinidamente inconsistente com o provedor,

converja para um estado final correto.

### Como implementar

A implementação é livre. Exemplos válidos:

um job periódico (cron/scheduler),

um worker contínuo,

um endpoint operacional acionado manualmente.

O importante é que pagamentos pendentes por tempo excessivo sejam reconciliados via:

GET /provider/payments/{provider_reference}

### Regras importantes

Reconciliação é fallback, não substitui webhooks.

O processo deve respeitar idempotência e deduplicação.

Estados terminais (CONFIRMED, REJECTED) não podem ser alterados.

Reprocessamento não pode gerar lançamentos duplicados no ledger.

### Regra de ouro

Webhooks são uma otimização.
Reconciliação é a garantia.

### Contas sugeridas (exemplo)
Você pode adaptar os nomes, mas mantenha a lógica de dupla entrada:
- `CUSTOMER_AVAILABLE` (saldo disponível do cliente)
- `CUSTOMER_HELD` (valor reservado/hold aguardando confirmação)
- `PIX_CLEARING` (conta transitória de compensação)
- `FEE_REVENUE` (receita de tarifa)

### Regras de posting (modelo recomendado)
Valor do Pix = `A` (centavos). Tarifa do envio = `F` (centavos, pode ser 0).

1) **Quando aceitar o POST /pix/send** (criou a intenção)
- Move para hold: `CUSTOMER_AVAILABLE -A` e `CUSTOMER_HELD +A`

2) **Quando enviar para o provedor**
- Não precisa movimentar saldo, só auditoria. (Opcional: registrar tentativa.)

3) **Quando receber CONFIRMED**
- Liquidar: `CUSTOMER_HELD -A` e `PIX_CLEARING +A`
- Tarifa (se houver): `CUSTOMER_AVAILABLE -F` e `FEE_REVENUE +F`

4) **Quando receber REJECTED**
- Estornar hold: `CUSTOMER_HELD -A` e `CUSTOMER_AVAILABLE +A`

5) **Eventos duplicados / retries**
- Cada posting deve ser idempotente (ex: `posting_id` derivado de `payment_id + etapa` ou `event_id`).

### Invariantes que serão cobradas
- **Soma de débitos = soma de créditos** em cada posting.
- Para um `payment_id`, no máximo **uma** liquidação final (CONFIRMED ou REJECTED).
- Saldos nunca ficam negativos (se você escolher impor essa regra).

### Endpoints opcionais do participante (para auditoria e scoring)
Recomendado expor:
- `GET /ledger/balances` → saldos atuais por conta
- `GET /ledger/entries?payment_id=...` → lançamentos de um pagamento

O contrato foi estendido em `contracts/participant-openapi.yaml`.

### Diagrama de sequência (com ledger)
```mermaid
sequenceDiagram
  autonumber
  participant C as Cliente
  participant API as Participante
  participant L as Ledger
  participant P as Provedor (mock)

  C->>API: POST /pix/send (Idempotency-Key, A)
  API->>L: Posting HOLD (Available -A, Held +A)
  API->>P: Enviar Pix
  P-->>API: Webhook CONFIRMED/REJECTED (event_id)
  alt CONFIRMED
    API->>L: Posting SETTLE (Held -A, Clearing +A)
    API->>L: Posting FEE (Available -F, FeeRevenue +F)
  else REJECTED
    API->>L: Posting RELEASE (Held -A, Available +A)
  end
```

---

## Licença
Uso interno para testes.
