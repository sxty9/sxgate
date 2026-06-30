// Command sxgate-mail-egress is the outbound half of the sxgate mail edge. maild spools a
// message and POSTs it here (loopback, authenticated by a shared secret); this relay
// DKIM-signs it and submits it to the configured smarthost over SMTP (STARTTLS + AUTH).
// maild never speaks SMTP to the internet itself — the edge owns DKIM + the smarthost.
//
// Config is read from the environment (set by the systemd unit `sxgate mail setup` generates):
//
//	EGRESS_LISTEN              loopback address (default 127.0.0.1:8786)
//	EGRESS_SECRET_FILE         shared maild↔edge secret (default /etc/holistic/mail-edge-secret)
//	EGRESS_DKIM_KEY            DKIM private key PEM (default /etc/sxgate/mail/dkim/private.pem)
//	EGRESS_DKIM_SELECTOR       DKIM selector (default sxgate)
//	EGRESS_DKIM_DOMAIN         signing domain (the mail domain)
//	EGRESS_SMARTHOST           host:port of the submission relay (e.g. smtp.provider.com:587)
//	EGRESS_SMARTHOST_USER      SMTP AUTH user (optional)
//	EGRESS_SMARTHOST_PASS_FILE file holding the SMTP AUTH password (optional)
package main

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/smtp"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type config struct {
	listen    string
	secret    string
	dkimKey   string
	selector  string
	domain    string
	smarthost string
	user      string
	pass      string
	spoolDir  string
	spool     *spool
}

func loadConfig() *config {
	c := &config{
		listen:    getenv("EGRESS_LISTEN", "127.0.0.1:8786"),
		secret:    readFile(getenv("EGRESS_SECRET_FILE", "/etc/holistic/mail-edge-secret")),
		dkimKey:   getenv("EGRESS_DKIM_KEY", "/etc/sxgate/mail/dkim/private.pem"),
		selector:  getenv("EGRESS_DKIM_SELECTOR", "sxgate"),
		domain:    strings.TrimSpace(os.Getenv("EGRESS_DKIM_DOMAIN")),
		smarthost: strings.TrimSpace(os.Getenv("EGRESS_SMARTHOST")),
		user:      strings.TrimSpace(os.Getenv("EGRESS_SMARTHOST_USER")),
		pass:      readFile(os.Getenv("EGRESS_SMARTHOST_PASS_FILE")),
		spoolDir:  getenv("EGRESS_SPOOL", defaultSpool()),
	}
	if _, err := os.Stat(c.dkimKey); err != nil {
		c.dkimKey = "" // no key yet → relay unsigned (edge not fully provisioned)
	}
	return c
}

// defaultSpool is the systemd StateDirectory (/var/lib/sxgate-mail-egress) when present, else a
// fixed path; the actual queue lives in a "spool" subdir of it.
func defaultSpool() string {
	if sd := strings.TrimSpace(os.Getenv("STATE_DIRECTORY")); sd != "" {
		if i := strings.IndexByte(sd, ':'); i >= 0 {
			sd = sd[:i]
		}
		return filepath.Join(sd, "spool")
	}
	return "/var/lib/sxgate-mail-egress/spool"
}

func main() {
	c := loadConfig()
	sp, err := newSpool(c.spoolDir, c.relay)
	if err != nil {
		log.Fatalf("sxgate-mail-egress: spool %s: %v", c.spoolDir, err)
	}
	c.spool = sp

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go c.spool.run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	mux.HandleFunc("POST /outbound", c.handleOutbound)

	ln, err := net.Listen("tcp", c.listen)
	if err != nil {
		log.Fatalf("sxgate-mail-egress: listen %s: %v", c.listen, err)
	}
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		log.Printf("sxgate-mail-egress on %s (domain=%q smarthost=%q dkim=%v spool=%q)", c.listen, c.domain, c.smarthost, c.dkimKey != "", c.spoolDir)
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Fatalf("sxgate-mail-egress: %v", err)
		}
	}()

	<-ctx.Done()
	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
}

func (c *config) handleOutbound(w http.ResponseWriter, r *http.Request) {
	if c.secret == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Mail-Edge-Secret")), []byte(c.secret)) != 1 {
		http.Error(w, `{"detail":"unauthorized"}`, http.StatusUnauthorized)
		return
	}
	from := strings.TrimSpace(r.Header.Get("X-Mail-From"))
	rcpts := splitList(r.Header.Get("X-Mail-Rcpt"))
	if from == "" || len(rcpts) == 0 {
		http.Error(w, `{"detail":"missing from/rcpt"}`, http.StatusBadRequest)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 50<<20))
	if err != nil {
		http.Error(w, `{"detail":"read error"}`, http.StatusBadRequest)
		return
	}
	if c.smarthost == "" {
		http.Error(w, `{"detail":"no smarthost configured"}`, http.StatusServiceUnavailable)
		return
	}
	if c.spool == nil {
		http.Error(w, `{"detail":"spool unavailable"}`, http.StatusInternalServerError)
		return
	}

	msg := raw
	if c.dkimKey != "" && c.domain != "" {
		if key, err := LoadPrivateKey(c.dkimKey); err != nil {
			log.Printf("egress: load dkim key: %v", err)
		} else if signed, err := Sign(raw, c.domain, c.selector, key); err != nil {
			log.Printf("egress: dkim sign failed: %v", err)
		} else {
			msg = signed
		}
	}

	// Accept-and-queue: persist the (signed) message and ack immediately, then relay asynchronously.
	// The fast ack means maild's HTTP call can't time out mid-relay and re-submit — the duplicate
	// bug. A resubmission of the same Message-ID is deduplicated to a no-op.
	id, accepted, err := c.spool.accept(idempotencyKey(msg), from, rcpts, msg)
	if err != nil {
		log.Printf("egress: spool accept failed: %v", err)
		http.Error(w, `{"detail":"spool error"}`, http.StatusInternalServerError)
		return
	}
	if accepted {
		log.Printf("egress: accepted %s (from=%s rcpts=%d)", id, from, len(rcpts))
	}
	w.Header().Set("Content-Type", "application/json")
	if accepted {
		_, _ = w.Write([]byte(`{"ok":true,"accepted":true}`))
	} else {
		_, _ = w.Write([]byte(`{"ok":true,"accepted":false,"duplicate":true}`))
	}
}

// relay submits msg to the smarthost via SMTP. STARTTLS is required before AUTH (credentials are
// never sent in cleartext); the connection has a dial timeout and an overall deadline so a hung
// smarthost cannot block a worker indefinitely.
func (c *config) relay(from string, rcpts []string, msg []byte) error {
	host, _, err := net.SplitHostPort(c.smarthost)
	if err != nil {
		host = c.smarthost
	}
	conn, err := net.DialTimeout("tcp", c.smarthost, 30*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	// Generous overall deadline: a large message's DATA upload can take a while, but it must not
	// hang forever.
	_ = conn.SetDeadline(time.Now().Add(5 * time.Minute))
	cl, err := smtp.NewClient(conn, host)
	if err != nil {
		return err
	}
	defer cl.Close()
	if err := cl.Hello(heloName()); err != nil {
		return err
	}
	if ok, _ := cl.Extension("STARTTLS"); ok {
		if err := cl.StartTLS(&tls.Config{ServerName: host}); err != nil {
			return err
		}
	} else if c.user != "" {
		return fmt.Errorf("smarthost %s offers no STARTTLS; refusing to send AUTH credentials in cleartext", c.smarthost)
	}
	if c.user != "" {
		if ok, _ := cl.Extension("AUTH"); ok {
			if err := cl.Auth(smtp.PlainAuth("", c.user, c.pass, host)); err != nil {
				return err
			}
		} else {
			return fmt.Errorf("smarthost %s does not advertise AUTH", c.smarthost)
		}
	}
	if err := cl.Mail(from); err != nil {
		return err
	}
	for _, rc := range rcpts {
		if err := cl.Rcpt(rc); err != nil {
			return err
		}
	}
	wc, err := cl.Data()
	if err != nil {
		return err
	}
	if _, err := wc.Write(msg); err != nil {
		_ = wc.Close()
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return cl.Quit()
}

func heloName() string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "localhost"
}

func getenv(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func readFile(path string) string {
	if path == "" {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}
