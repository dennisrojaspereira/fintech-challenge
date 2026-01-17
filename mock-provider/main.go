package main

import (
	"bytes"
	crand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	mrand "math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

type Config struct {
	Port             string
	WebhookURL       string
	FailureMode      string
	PTimeout         float64
	PHTTP500         float64
	PDuplicateEvent  float64
	POutOfOrderEvent float64
	MinLatencyMS     int
	MaxLatencyMS     int
	FinalizeMinMS    int
	FinalizeMaxMS    int
}

type SendRequest struct {
	IdempotencyKey string `json:"idempotency_key"`
	TxID           string `json:"txid"`
	Amount         int64  `json:"amount"`
	ReceiverKey    string `json:"receiver_key"`
	Description    string `json:"description"`
	ClientRef      string `json:"client_reference"`
}

type SendResponse struct {
	ProviderPaymentID string `json:"provider_payment_id"`
	Status            string `json:"status"`
}

type Payment struct {
	ProviderPaymentID string
	IdempotencyKey    string
	TxID              string
	Amount            int64
	ReceiverKey       string
	Description       string
	ClientRef         string
	Status            string // PENDING | CONFIRMED | REJECTED
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

type WebhookEvent struct {
	EventID           string `json:"event_id"`
	ProviderPaymentID string `json:"provider_payment_id"`
	Type              string `json:"type"` // PENDING | CONFIRMED | REJECTED
	OccurredAt        string `json:"occurred_at"`
	CorrelationID     string `json:"correlation_id"`
}

type Store struct {
	mu        sync.Mutex
	byID      map[string]*Payment
	byIdemKey map[string]string
}

func main() {
	mrand.Seed(time.Now().UnixNano())
	cfg := readConfig()
	st := &Store{byID: map[string]*Payment{}, byIdemKey: map[string]string{}}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/provider/pix/send", func(w http.ResponseWriter, r *http.Request) { handleSend(cfg, st, w, r) })
	mux.HandleFunc("/provider/pix/payments/", func(w http.ResponseWriter, r *http.Request) { handleGet(st, w, r) })
	mux.HandleFunc("/admin/scenarios", func(w http.ResponseWriter, r *http.Request) { handleScenarioList(w) })

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("mock-provider listening on :%s | webhook=%s | failure_mode=%s", cfg.Port, cfg.WebhookURL, cfg.FailureMode)
	log.Fatal(srv.ListenAndServe())
}

func readConfig() Config {
	getStr := func(key, def string) string {
		v := os.Getenv(key)
		if v == "" {
			return def
		}
		return v
	}
	getF := func(key string, def float64) float64 {
		v := os.Getenv(key)
		if v == "" {
			return def
		}
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return def
		}
		return f
	}
	getI := func(key string, def int) int {
		v := os.Getenv(key)
		if v == "" {
			return def
		}
		i, err := strconv.Atoi(v)
		if err != nil {
			return def
		}
		return i
	}

	return Config{
		Port:             getStr("PORT", "8080"),
		WebhookURL:       getStr("WEBHOOK_URL", "http://host.docker.internal:8081/webhooks/pix"),
		FailureMode:      getStr("FAILURE_MODE", "probabilistic"),
		PTimeout:         getF("P_TIMEOUT", 0.10),
		PHTTP500:         getF("P_HTTP500", 0.05),
		PDuplicateEvent:  getF("P_DUPLICATE_EVENT", 0.15),
		POutOfOrderEvent: getF("P_OUT_OF_ORDER_EVENT", 0.10),
		MinLatencyMS:     getI("MIN_LATENCY_MS", 50),
		MaxLatencyMS:     getI("MAX_LATENCY_MS", 350),
		FinalizeMinMS:    getI("FINALIZE_MIN_MS", 400),
		FinalizeMaxMS:    getI("FINALIZE_MAX_MS", 1500),
	}
}

func handleScenarioList(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"header": "X-Mock-Scenario",
		"scenarios": []string{
			"success",
			"timeout_then_confirm",
			"timeout_then_reject",
			"http500",
			"accept_then_confirm",
			"accept_then_reject",
		},
	})
}

func handleSend(cfg Config, st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	correlationID := r.Header.Get("X-Correlation-Id")
	if correlationID == "" {
		correlationID = newID()
	}

	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if req.IdempotencyKey == "" {
		http.Error(w, "idempotency_key is required", http.StatusBadRequest)
		return
	}

	// Latencia base
	sleepMS := randInt(cfg.MinLatencyMS, cfg.MaxLatencyMS)
	time.Sleep(time.Duration(sleepMS) * time.Millisecond)

	scenario := r.Header.Get("X-Mock-Scenario")
	if scenario == "" {
		scenario = pickScenario(cfg)
	}

	// Idempotencia (do lado do provedor): mesma idempotency_key devolve o mesmo provider_payment_id
	st.mu.Lock()
	if existingID, ok := st.byIdemKey[req.IdempotencyKey]; ok {
		p := st.byID[existingID]
		st.mu.Unlock()
		writeJSON(w, http.StatusOK, SendResponse{ProviderPaymentID: p.ProviderPaymentID, Status: p.Status})
		return
	}
	providerID := newID()
	payment := &Payment{
		ProviderPaymentID: providerID,
		IdempotencyKey:    req.IdempotencyKey,
		TxID:              req.TxID,
		Amount:            req.Amount,
		ReceiverKey:       req.ReceiverKey,
		Description:       req.Description,
		ClientRef:         req.ClientRef,
		Status:            "PENDING",
		CreatedAt:         time.Now().UTC(),
		UpdatedAt:         time.Now().UTC(),
	}
	st.byID[providerID] = payment
	st.byIdemKey[req.IdempotencyKey] = providerID
	st.mu.Unlock()

	switch scenario {
	case "http500":
		http.Error(w, "temporary provider error", http.StatusInternalServerError)
		return
	case "timeout_then_confirm":
		go finalizeLater(cfg, st, providerID, correlationID, "CONFIRMED")
		time.Sleep(4 * time.Second)
		http.Error(w, "gateway timeout", http.StatusGatewayTimeout)
		return
	case "timeout_then_reject":
		go finalizeLater(cfg, st, providerID, correlationID, "REJECTED")
		time.Sleep(4 * time.Second)
		http.Error(w, "gateway timeout", http.StatusGatewayTimeout)
		return
	case "accept_then_reject":
		go finalizeLater(cfg, st, providerID, correlationID, "REJECTED")
		writeJSON(w, http.StatusAccepted, SendResponse{ProviderPaymentID: providerID, Status: "PENDING"})
		return
	case "accept_then_confirm":
		go finalizeLater(cfg, st, providerID, correlationID, "CONFIRMED")
		writeJSON(w, http.StatusAccepted, SendResponse{ProviderPaymentID: providerID, Status: "PENDING"})
		return
	case "success":
		go finalizeLater(cfg, st, providerID, correlationID, "CONFIRMED")
		writeJSON(w, http.StatusAccepted, SendResponse{ProviderPaymentID: providerID, Status: "PENDING"})
		return
	default:
		go finalizeLater(cfg, st, providerID, correlationID, "CONFIRMED")
		writeJSON(w, http.StatusAccepted, SendResponse{ProviderPaymentID: providerID, Status: "PENDING"})
		return
	}
}

func handleGet(st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	prefix := "/provider/pix/payments/"
	id := r.URL.Path
	if len(id) < len(prefix)+1 {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	id = id[len(prefix):]

	st.mu.Lock()
	p, ok := st.byID[id]
	st.mu.Unlock()
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"provider_payment_id": p.ProviderPaymentID,
		"status":              p.Status,
		"amount":              p.Amount,
		"receiver_key":        p.ReceiverKey,
		"txid":                p.TxID,
		"client_reference":    p.ClientRef,
		"created_at":          p.CreatedAt.Format(time.RFC3339Nano),
		"updated_at":          p.UpdatedAt.Format(time.RFC3339Nano),
	})
}

func finalizeLater(cfg Config, st *Store, providerID, correlationID, finalType string) {
	finalDelay := randInt(cfg.FinalizeMinMS, cfg.FinalizeMaxMS)
	time.Sleep(time.Duration(finalDelay) * time.Millisecond)

	st.mu.Lock()
	p, ok := st.byID[providerID]
	if ok {
		p.Status = finalType
		p.UpdatedAt = time.Now().UTC()
	}
	st.mu.Unlock()
	if !ok {
		return
	}

	pending := WebhookEvent{
		EventID:           newID(),
		ProviderPaymentID: providerID,
		Type:              "PENDING",
		OccurredAt:        time.Now().UTC().Format(time.RFC3339Nano),
		CorrelationID:     correlationID,
	}
	final := WebhookEvent{
		EventID:           newID(),
		ProviderPaymentID: providerID,
		Type:              finalType,
		OccurredAt:        time.Now().UTC().Format(time.RFC3339Nano),
		CorrelationID:     correlationID,
	}

	dup := mrand.Float64() < cfg.PDuplicateEvent
	outOfOrder := mrand.Float64() < cfg.POutOfOrderEvent

	// Pode mandar fora de ordem
	if outOfOrder {
		sendWebhook(cfg.WebhookURL, final)
		time.Sleep(time.Duration(randInt(30, 120)) * time.Millisecond)
		sendWebhook(cfg.WebhookURL, pending)
	} else {
		sendWebhook(cfg.WebhookURL, pending)
		time.Sleep(time.Duration(randInt(30, 120)) * time.Millisecond)
		sendWebhook(cfg.WebhookURL, final)
	}

	if dup {
		// Duplica o evento final (mesmo event_id nao, mas payload repetido)
		final2 := final
		final2.EventID = newID()
		time.Sleep(time.Duration(randInt(20, 100)) * time.Millisecond)
		sendWebhook(cfg.WebhookURL, final2)
	}
}

func pickScenario(cfg Config) string {
	if cfg.FailureMode == "off" {
		return "success"
	}
	r := mrand.Float64()
	if r < cfg.PHTTP500 {
		return "http500"
	}
	r -= cfg.PHTTP500
	if r < cfg.PTimeout {
		// metade confirma, metade rejeita
		if mrand.Intn(2) == 0 {
			return "timeout_then_confirm"
		}
		return "timeout_then_reject"
	}
	return "accept_then_confirm"
}

func sendWebhook(url string, ev WebhookEvent) {
	b, _ := json.Marshal(ev)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "pix-mock-provider/1.0")

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("webhook error: %v", err)
		return
	}
	_ = resp.Body.Close()
	log.Printf("webhook sent: type=%s provider_payment_id=%s status=%d", ev.Type, ev.ProviderPaymentID, resp.StatusCode)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func newID() string {
	b := make([]byte, 16)
	if _, err := crand.Read(b); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

func randInt(min, max int) int {
	if max <= min {
		return min
	}
	return min + mrand.Intn(max-min+1)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		dur := time.Since(start)
		log.Printf("%s %s %s", r.Method, r.URL.Path, fmtDuration(dur))
	})
}

func fmtDuration(d time.Duration) string {
	return fmt.Sprintf("%dms", d.Milliseconds())
}
