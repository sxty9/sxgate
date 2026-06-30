package main

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeSMTP is a tiny one-shot SMTP sink: it accepts a single message and records the DATA.
type fakeSMTP struct {
	ln   net.Listener
	mu   sync.Mutex
	data string
	done chan struct{}
}

func startFakeSMTP(t *testing.T) *fakeSMTP {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("fake smtp listen: %v", err)
	}
	f := &fakeSMTP{ln: ln, done: make(chan struct{})}
	go f.serve()
	t.Cleanup(func() { _ = ln.Close() })
	return f
}

func (f *fakeSMTP) addr() string { return f.ln.Addr().String() }

func (f *fakeSMTP) serve() {
	conn, err := f.ln.Accept()
	if err != nil {
		return
	}
	defer conn.Close()
	r := bufio.NewReader(conn)
	w := func(s string) { fmt.Fprintf(conn, "%s\r\n", s) }
	w("220 fake ESMTP")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		cmd := strings.ToUpper(strings.TrimSpace(line))
		switch {
		case strings.HasPrefix(cmd, "EHLO"), strings.HasPrefix(cmd, "HELO"):
			w("250-fake greets you")
			w("250 HELP") // no STARTTLS / AUTH advertised
		case strings.HasPrefix(cmd, "MAIL FROM"):
			w("250 OK")
		case strings.HasPrefix(cmd, "RCPT TO"):
			w("250 OK")
		case cmd == "DATA":
			w("354 End data with <CR><LF>.<CR><LF>")
			var b strings.Builder
			for {
				dl, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if dl == ".\r\n" || dl == ".\n" {
					break
				}
				if strings.HasPrefix(dl, "..") { // dot-unstuffing
					dl = dl[1:]
				}
				b.WriteString(dl)
			}
			f.mu.Lock()
			f.data = b.String()
			f.mu.Unlock()
			w("250 OK queued")
			close(f.done)
		case cmd == "QUIT":
			w("221 Bye")
			return
		default:
			w("250 OK")
		}
	}
}

func writeTestKey(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("genkey: %v", err)
	}
	der := x509.MarshalPKCS1PrivateKey(key)
	p := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: der})
	path := filepath.Join(t.TempDir(), "dkim.pem")
	if err := os.WriteFile(path, p, 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	return path
}

func TestHandleOutboundRelaysAndSigns(t *testing.T) {
	smtp := startFakeSMTP(t)
	cfg := &config{
		secret:    "edge-secret",
		dkimKey:   writeTestKey(t),
		selector:  "sxgate",
		domain:    "example.test",
		smarthost: smtp.addr(),
	}
	sp, err := newSpool(t.TempDir(), cfg.relay)
	if err != nil {
		t.Fatalf("newSpool: %v", err)
	}
	cfg.spool = sp

	req := httptest.NewRequest(http.MethodPost, "/outbound", strings.NewReader(sampleMsg))
	req.Header.Set("X-Mail-Edge-Secret", "edge-secret")
	req.Header.Set("X-Mail-From", "alice@example.test")
	req.Header.Set("X-Mail-Rcpt", "bob@elsewhere.test, carol@elsewhere.test")
	rec := httptest.NewRecorder()

	cfg.handleOutbound(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	// Accept-and-queue: the handler acked; the worker relays. Flush once to deliver synchronously.
	cfg.spool.flush()
	select {
	case <-smtp.done:
	case <-time.After(5 * time.Second):
		t.Fatal("fake smtp never received the message")
	}
	smtp.mu.Lock()
	got := smtp.data
	smtp.mu.Unlock()
	if !strings.Contains(got, "DKIM-Signature: ") {
		t.Errorf("relayed message is not DKIM-signed:\n%s", got)
	}
	if !strings.Contains(got, "Subject: DKIM round trip") {
		t.Errorf("relayed message lost its headers:\n%s", got)
	}
}

func TestHandleOutboundAuthAndConfig(t *testing.T) {
	// Wrong secret → 401.
	cfg := &config{secret: "right", smarthost: "127.0.0.1:1"}
	req := httptest.NewRequest(http.MethodPost, "/outbound", strings.NewReader(sampleMsg))
	req.Header.Set("X-Mail-Edge-Secret", "wrong")
	req.Header.Set("X-Mail-From", "a@example.test")
	req.Header.Set("X-Mail-Rcpt", "b@x.test")
	rec := httptest.NewRecorder()
	cfg.handleOutbound(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("bad secret: status = %d, want 401", rec.Code)
	}

	// No smarthost configured → 503.
	cfg2 := &config{secret: "s"}
	req2 := httptest.NewRequest(http.MethodPost, "/outbound", strings.NewReader(sampleMsg))
	req2.Header.Set("X-Mail-Edge-Secret", "s")
	req2.Header.Set("X-Mail-From", "a@example.test")
	req2.Header.Set("X-Mail-Rcpt", "b@x.test")
	rec2 := httptest.NewRecorder()
	cfg2.handleOutbound(rec2, req2)
	if rec2.Code != http.StatusServiceUnavailable {
		t.Errorf("no smarthost: status = %d, want 503", rec2.Code)
	}
}

// TestSpoolDedup: re-accepting the same idempotency key is a no-op (one spooled job), so a
// resubmission never re-sends.
func TestSpoolDedup(t *testing.T) {
	dir := t.TempDir()
	sp, err := newSpool(dir, func(string, []string, []byte) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("Message-ID: <dup@x>\r\n\r\nhi")
	key := idempotencyKey(msg)
	if _, ok, _ := sp.accept(key, "a@b.test", []string{"c@d.test"}, msg); !ok {
		t.Fatal("first accept should succeed")
	}
	if _, ok, _ := sp.accept(key, "a@b.test", []string{"c@d.test"}, msg); ok {
		t.Error("duplicate accept should be a no-op")
	}
	n := 0
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("spooled %d jobs, want 1 (dedup)", n)
	}
}

// TestSpoolDeadLetters: a persistently failing relay is retried at most maxAttempts times and then
// dead-lettered — no infinite loop.
func TestSpoolDeadLetters(t *testing.T) {
	var calls int
	dir := t.TempDir()
	sp, err := newSpool(dir, func(string, []string, []byte) error {
		calls++
		return fmt.Errorf("relay down")
	})
	if err != nil {
		t.Fatal(err)
	}
	id, ok, err := sp.accept("k1", "a@b.test", []string{"c@d.test"}, []byte("Message-ID: <k1>\r\n\r\nhi"))
	if err != nil || !ok {
		t.Fatalf("accept: id=%q ok=%v err=%v", id, ok, err)
	}
	// Advance 'now' each call so the backoff never defers the attempt.
	for i := 0; i < maxAttempts+3; i++ {
		_ = sp.deliver(id, time.Now().Add(time.Duration(i+1)*time.Hour))
	}
	if calls > maxAttempts {
		t.Errorf("relay called %d times, want at most %d", calls, maxAttempts)
	}
	if _, err := os.Stat(filepath.Join(dir, id+".json")); !os.IsNotExist(err) {
		t.Errorf("job still active after dead-letter (err=%v)", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "failed", id+".json")); err != nil {
		t.Errorf("job not dead-lettered to failed/: %v", err)
	}
}
