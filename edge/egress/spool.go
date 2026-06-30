package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// maxAttempts caps relay retries before a job is dead-lettered (moved aside) instead of being
// retried forever — the backstop against an infinite re-delivery loop.
const maxAttempts = 6

// seenTTL is how long an accepted idempotency key is remembered, so a resubmission of the same
// message within this window is a no-op rather than a duplicate send.
const seenTTL = 30 * time.Minute

type job struct {
	ID          string    `json:"id"`
	Key         string    `json:"key"`
	From        string    `json:"from"`
	Rcpts       []string  `json:"rcpts"`
	Attempts    int       `json:"attempts"`
	QueuedAt    time.Time `json:"queuedAt"`
	NextAttempt time.Time `json:"nextAttempt"`
}

// spool is the edge's accept-and-queue store. handleOutbound persists a message and acks instantly;
// a background worker relays it to the smarthost with exponential backoff and dead-letters a job
// that keeps failing. An in-memory idempotency set drops duplicate submissions (same Message-ID).
//
// This decouples maild's HTTP call from the (potentially slow) smarthost upload: maild gets its 2xx
// in milliseconds and never times out mid-relay, which is what previously caused duplicate sends.
type spool struct {
	dir   string
	relay func(from string, rcpts []string, msg []byte) error
	kick  chan struct{}
	mu    sync.Mutex
	seen  map[string]time.Time
}

func newSpool(dir string, relay func(from string, rcpts []string, msg []byte) error) (*spool, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &spool{dir: dir, relay: relay, kick: make(chan struct{}, 1), seen: map[string]time.Time{}}
	s.loadSeen()
	return s, nil
}

// loadSeen seeds the dedup set from jobs still pending after a restart, so a message in flight when
// the edge restarts is not re-accepted (and re-sent) if maild resubmits during that window.
func (s *spool) loadSeen() {
	entries, _ := os.ReadDir(s.dir)
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		if b, err := os.ReadFile(filepath.Join(s.dir, e.Name())); err == nil {
			var j job
			if json.Unmarshal(b, &j) == nil && j.Key != "" {
				s.seen[j.Key] = j.QueuedAt
			}
		}
	}
}

// accept spools a message for relay. It returns accepted=false (a successful no-op) when the
// idempotency key was already accepted within seenTTL, so a resubmission never re-sends.
func (s *spool) accept(key, from string, rcpts []string, msg []byte) (id string, accepted bool, err error) {
	s.mu.Lock()
	if key != "" {
		if t, ok := s.seen[key]; ok && time.Since(t) < seenTTL {
			s.mu.Unlock()
			return "", false, nil
		}
	}
	s.mu.Unlock()

	id = uniqueID()
	if err := writeFileAtomic(filepath.Join(s.dir, id+".eml"), msg); err != nil {
		return "", false, err
	}
	meta, _ := json.MarshalIndent(job{ID: id, Key: key, From: from, Rcpts: rcpts, QueuedAt: time.Now().UTC()}, "", "  ")
	if err := writeFileAtomic(filepath.Join(s.dir, id+".json"), meta); err != nil {
		_ = os.Remove(filepath.Join(s.dir, id+".eml"))
		return "", false, err
	}
	s.mu.Lock()
	if key != "" {
		s.seen[key] = time.Now()
	}
	s.mu.Unlock()
	s.nudge()
	return id, true, nil
}

func (s *spool) nudge() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// run flushes due jobs on a ticker and whenever a message is accepted, until ctx is cancelled.
func (s *spool) run(ctx context.Context) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.prune()
			s.flush()
		case <-s.kick:
			s.flush()
		}
	}
}

func (s *spool) flush() {
	entries, _ := os.ReadDir(s.dir)
	now := time.Now()
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".json")
		if err := s.deliver(id, now); err != nil {
			log.Printf("egress: relay %s deferred: %v", id, err)
		}
	}
}

func (s *spool) deliver(id string, now time.Time) error {
	metaPath := filepath.Join(s.dir, id+".json")
	rawPath := filepath.Join(s.dir, id+".eml")
	mb, err := os.ReadFile(metaPath)
	if err != nil {
		return err
	}
	var j job
	if err := json.Unmarshal(mb, &j); err != nil {
		return err
	}
	if !j.NextAttempt.IsZero() && now.Before(j.NextAttempt) {
		return nil // backing off; not due yet
	}
	raw, err := os.ReadFile(rawPath)
	if err != nil {
		return err
	}
	if err := s.relay(j.From, j.Rcpts, raw); err == nil {
		_ = os.Remove(rawPath)
		_ = os.Remove(metaPath)
		return nil
	} else {
		j.Attempts++
		if j.Attempts >= maxAttempts {
			s.deadLetter(id, metaPath, rawPath, j)
			return fmt.Errorf("gave up after %d attempts: %w", j.Attempts, err)
		}
		j.NextAttempt = time.Now().Add(backoff(j.Attempts))
		nb, _ := json.MarshalIndent(j, "", "  ")
		_ = writeFileAtomic(metaPath, nb)
		return err
	}
}

// deadLetter moves a permanently-failed job into a "failed" subdir (which flush ignores) so it
// stops being retried; the bytes are preserved for inspection rather than dropped.
func (s *spool) deadLetter(id, metaPath, rawPath string, j job) {
	failedDir := filepath.Join(s.dir, "failed")
	if err := os.MkdirAll(failedDir, 0o700); err == nil {
		_ = os.Rename(rawPath, filepath.Join(failedDir, id+".eml"))
		_ = os.Rename(metaPath, filepath.Join(failedDir, id+".json"))
	} else {
		_ = os.Remove(rawPath)
		_ = os.Remove(metaPath)
	}
	log.Printf("egress: %s DEAD-LETTERED after %d attempts (from=%s to=%v)", id, j.Attempts, j.From, j.Rcpts)
}

func (s *spool) prune() {
	s.mu.Lock()
	for k, t := range s.seen {
		if time.Since(t) >= seenTTL {
			delete(s.seen, k)
		}
	}
	s.mu.Unlock()
}

// backoff is the delay before retry N: 30s, 1m, 2m, 4m, … capped at 10m.
func backoff(attempts int) time.Duration {
	d := 30 * time.Second
	for i := 1; i < attempts; i++ {
		d *= 2
		if d >= 10*time.Minute {
			return 10 * time.Minute
		}
	}
	return d
}

// idempotencyKey is the message's Message-ID (stable across resubmissions), or a content hash if it
// has none.
func idempotencyKey(raw []byte) string {
	if id := headerValue(raw, "Message-ID"); id != "" {
		return id
	}
	sum := sha256.Sum256(raw)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// headerValue returns the first matching header value from the message head, or "".
func headerValue(raw []byte, name string) string {
	lname := strings.ToLower(name) + ":"
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			break // end of headers
		}
		if strings.HasPrefix(strings.ToLower(line), lname) {
			return strings.TrimSpace(line[len(lname):])
		}
	}
	return ""
}

func uniqueID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%d-%s", time.Now().UnixNano(), hex.EncodeToString(b[:]))
}

func writeFileAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
