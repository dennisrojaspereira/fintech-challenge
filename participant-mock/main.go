package main

import (
	"bytes"
	crand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

type Config struct {
	Port        string
	ProviderURL string
}

type SendRequest struct {
	TxID        string `json:"txid"`
	Amount      int64  `json:"amount"`
	ReceiverKey string `json:"receiver_key"`
	Description string `json:"description"`
	ClientRef   string `json:"client_reference"`
}

type SendAccepted struct {
	PaymentID string `json:"payment_id"`
	Status    string `json:"status"`
}

type ProviderSendRequest struct {
	IdempotencyKey string `json:"idempotency_key"`
	TxID           string `json:"txid"`
	Amount         int64  `json:"amount"`
	ReceiverKey    string `json:"receiver_key"`
	Description    string `json:"description"`
	ClientRef      string `json:"client_reference"`
}

type ProviderSendResponse struct {
	ProviderPaymentID string `json:"provider_payment_id"`
	Status            string `json:"status"`
}

type Payment struct {
	PaymentID         string
	ProviderPaymentID string
	IdempotencyKey    string
	Amount            int64
	Status            string
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

type WebhookEvent struct {
	EventID           string `json:"event_id"`
	ProviderPaymentID string `json:"provider_payment_id"`
	Type              string `json:"type"`
	OccurredAt        string `json:"occurred_at"`
	CorrelationID     string `json:"correlation_id"`
}

type LedgerLine struct {
	Account   string `json:"account"`
	Direction string `json:"direction"`
	Amount    int64  `json:"amount"`
}

type LedgerEntry struct {
	PostingID  string       `json:"posting_id"`
	PaymentID  string       `json:"payment_id"`
	OccurredAt string       `json:"occurred_at"`
	Kind       string       `json:"kind"`
	Lines      []LedgerLine `json:"lines"`
}

type LedgerBalances struct {
	AsOf     string `json:"as_of"`
	Balances []struct {
		Account string `json:"account"`
		Amount  int64  `json:"amount"`
	} `json:"balances"`
}

type Store struct {
	mu               sync.Mutex
	byPaymentID      map[string]*Payment
	byIdempotencyKey map[string]string
	byProviderID     map[string]string
	byCorrelationID  map[string]string
	seenEventIDs     map[string]struct{}
	ledgerEntries    []LedgerEntry
	ledgerByPosting  map[string]struct{}
	balances         map[string]int64
}

func main() {
	cfg := readConfig()
	st := &Store{
		byPaymentID:      map[string]*Payment{},
		byIdempotencyKey: map[string]string{},
		byProviderID:     map[string]string{},
		byCorrelationID:  map[string]string{},
		seenEventIDs:     map[string]struct{}{},
		ledgerEntries:    []LedgerEntry{},
		ledgerByPosting:  map[string]struct{}{},
		balances:         map[string]int64{},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/pix/send", func(w http.ResponseWriter, r *http.Request) { handleSend(cfg, st, w, r) })
	mux.HandleFunc("/pix/send/", func(w http.ResponseWriter, r *http.Request) { handleGet(cfg, st, w, r) })
	mux.HandleFunc("/webhooks/pix", func(w http.ResponseWriter, r *http.Request) { handleWebhook(st, w, r) })
	mux.HandleFunc("/ledger/entries", func(w http.ResponseWriter, r *http.Request) { handleLedgerEntries(st, w, r) })
	mux.HandleFunc("/ledger/balances", func(w http.ResponseWriter, r *http.Request) { handleLedgerBalances(st, w, r) })

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("participant-mock listening on :%s | provider=%s", cfg.Port, cfg.ProviderURL)
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

	return Config{
		Port:        getStr("PORT", "8081"),
		ProviderURL: getStr("PROVIDER_URL", "http://mock-provider:8080"),
	}
}

func handleSend(cfg Config, st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	idem := r.Header.Get("Idempotency-Key")
	if idem == "" {
		http.Error(w, "missing Idempotency-Key", http.StatusBadRequest)
		return
	}

	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if req.TxID == "" || req.Amount <= 0 || req.ReceiverKey == "" {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}

	st.mu.Lock()
	if existingID, ok := st.byIdempotencyKey[idem]; ok {
		p := st.byPaymentID[existingID]
		st.mu.Unlock()
		writeJSON(w, http.StatusAccepted, SendAccepted{PaymentID: p.PaymentID, Status: p.Status})
		return
	}

	paymentID := newID()
	p := &Payment{
		PaymentID:      paymentID,
		IdempotencyKey: idem,
		Amount:         req.Amount,
		Status:         "CREATED",
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
	}
	st.byPaymentID[paymentID] = p
	st.byIdempotencyKey[idem] = paymentID
	st.byCorrelationID[paymentID] = paymentID
	st.mu.Unlock()

	addLedgerHold(st, paymentID, req.Amount)

	go callProvider(cfg, st, p, req)

	writeJSON(w, http.StatusAccepted, SendAccepted{PaymentID: paymentID, Status: p.Status})
}

func handleGet(cfg Config, st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	prefix := "/pix/send/"
	id := r.URL.Path
	if len(id) < len(prefix)+1 {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	id = id[len(prefix):]

	st.mu.Lock()
	p, ok := st.byPaymentID[id]
	st.mu.Unlock()
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"payment_id":          p.PaymentID,
		"status":              p.Status,
		"provider_payment_id": p.ProviderPaymentID,
		"created_at":          p.CreatedAt.Format(time.RFC3339Nano),
		"updated_at":          p.UpdatedAt.Format(time.RFC3339Nano),
	})
}

func handleWebhook(st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var ev WebhookEvent
	if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	st.mu.Lock()
	if _, seen := st.seenEventIDs[ev.EventID]; seen {
		st.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
		return
	}
	st.seenEventIDs[ev.EventID] = struct{}{}

	var p *Payment
	if ev.ProviderPaymentID != "" {
		if pid, ok := st.byProviderID[ev.ProviderPaymentID]; ok {
			p = st.byPaymentID[pid]
		}
	}
	if p == nil && ev.CorrelationID != "" {
		if pid, ok := st.byCorrelationID[ev.CorrelationID]; ok {
			p = st.byPaymentID[pid]
		}
	}
	st.mu.Unlock()

	if p == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	applyWebhook(st, p, ev.Type)
	w.WriteHeader(http.StatusNoContent)
}

func handleLedgerEntries(st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	st.mu.Lock()
	entries := make([]LedgerEntry, len(st.ledgerEntries))
	copy(entries, st.ledgerEntries)
	st.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

func handleLedgerBalances(st *Store, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	st.mu.Lock()
	balances := make([]struct {
		Account string `json:"account"`
		Amount  int64  `json:"amount"`
	}, 0, len(st.balances))
	for k, v := range st.balances {
		balances = append(balances, struct {
			Account string `json:"account"`
			Amount  int64  `json:"amount"`
		}{Account: k, Amount: v})
	}
	st.mu.Unlock()

	resp := LedgerBalances{
		AsOf:     time.Now().UTC().Format(time.RFC3339Nano),
		Balances: balances,
	}
	writeJSON(w, http.StatusOK, resp)
}

func callProvider(cfg Config, st *Store, p *Payment, req SendRequest) {
	payload := ProviderSendRequest{
		IdempotencyKey: p.IdempotencyKey,
		TxID:           req.TxID,
		Amount:         req.Amount,
		ReceiverKey:    req.ReceiverKey,
		Description:    req.Description,
		ClientRef:      req.ClientRef,
	}
	b, _ := json.Marshal(payload)

	url := cfg.ProviderURL + "/provider/pix/send"
	reqHTTP, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	reqHTTP.Header.Set("Content-Type", "application/json")
	reqHTTP.Header.Set("X-Correlation-Id", p.PaymentID)

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(reqHTTP)
	if err != nil {
		log.Printf("provider error: %v", err)
		return
	}
	defer resp.Body.Close()

	var provResp ProviderSendResponse
	_ = json.NewDecoder(resp.Body).Decode(&provResp)

	st.mu.Lock()
	if provResp.ProviderPaymentID != "" {
		p.ProviderPaymentID = provResp.ProviderPaymentID
		st.byProviderID[provResp.ProviderPaymentID] = p.PaymentID
	}
	p.Status = "PENDING"
	p.UpdatedAt = time.Now().UTC()
	st.mu.Unlock()
}

func applyWebhook(st *Store, p *Payment, eventType string) {
	st.mu.Lock()
	current := p.Status
	st.mu.Unlock()

	finalType := normalizeStatus(eventType)
	if finalType == "" {
		return
	}
	if current == "CONFIRMED" || current == "REJECTED" {
		return
	}

	switch finalType {
	case "CONFIRMED":
		addLedgerSettle(st, p.PaymentID, p.Amount)
	case "REJECTED":
		addLedgerRelease(st, p.PaymentID, p.Amount)
	}

	st.mu.Lock()
	p.Status = finalType
	p.UpdatedAt = time.Now().UTC()
	st.mu.Unlock()
}

func addLedgerHold(st *Store, paymentID string, amount int64) {
	entry := LedgerEntry{
		PostingID:  paymentID + ":HOLD",
		PaymentID:  paymentID,
		OccurredAt: time.Now().UTC().Format(time.RFC3339Nano),
		Kind:       "HOLD",
		Lines: []LedgerLine{
			{Account: "CUSTOMER_AVAILABLE", Direction: "DEBIT", Amount: amount},
			{Account: "CUSTOMER_HELD", Direction: "CREDIT", Amount: amount},
		},
	}
	appendEntry(st, entry)
}

func addLedgerSettle(st *Store, paymentID string, amount int64) {
	entry := LedgerEntry{
		PostingID:  paymentID + ":SETTLE",
		PaymentID:  paymentID,
		OccurredAt: time.Now().UTC().Format(time.RFC3339Nano),
		Kind:       "SETTLE",
		Lines: []LedgerLine{
			{Account: "CUSTOMER_HELD", Direction: "DEBIT", Amount: amount},
			{Account: "PIX_CLEARING", Direction: "CREDIT", Amount: amount},
		},
	}
	appendEntry(st, entry)
}

func addLedgerRelease(st *Store, paymentID string, amount int64) {
	entry := LedgerEntry{
		PostingID:  paymentID + ":RELEASE",
		PaymentID:  paymentID,
		OccurredAt: time.Now().UTC().Format(time.RFC3339Nano),
		Kind:       "RELEASE",
		Lines: []LedgerLine{
			{Account: "CUSTOMER_HELD", Direction: "DEBIT", Amount: amount},
			{Account: "CUSTOMER_AVAILABLE", Direction: "CREDIT", Amount: amount},
		},
	}
	appendEntry(st, entry)
}

func appendEntry(st *Store, entry LedgerEntry) {
	st.mu.Lock()
	if _, exists := st.ledgerByPosting[entry.PostingID]; exists {
		st.mu.Unlock()
		return
	}
	st.ledgerByPosting[entry.PostingID] = struct{}{}
	st.ledgerEntries = append(st.ledgerEntries, entry)
	for _, line := range entry.Lines {
		if line.Direction == "DEBIT" {
			st.balances[line.Account] -= line.Amount
		} else {
			st.balances[line.Account] += line.Amount
		}
	}
	st.mu.Unlock()
}

func normalizeStatus(s string) string {
	switch s {
	case "PENDING":
		return "PENDING"
	case "CONFIRMED":
		return "CONFIRMED"
	case "REJECTED":
		return "REJECTED"
	default:
		return ""
	}
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

func parseInt(v string, def int) int {
	if v == "" {
		return def
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return i
}
