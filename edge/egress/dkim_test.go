package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
)

func TestCanonHeaderRelaxed(t *testing.T) {
	cases := []struct{ name, value, want string }{
		{"Subject", " Hello   World  ", "subject:Hello World\r\n"},
		{"From", " Alice <a@b.test>", "from:Alice <a@b.test>\r\n"},
		{"X-Folded", " one\r\n  two   three", "x-folded:one two three\r\n"},
	}
	for _, c := range cases {
		if got := canonHeaderRelaxed(c.name, c.value); got != c.want {
			t.Errorf("canonHeaderRelaxed(%q,%q) = %q, want %q", c.name, c.value, got, c.want)
		}
	}
}

func TestCanonBodyRelaxed(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"a  b \r\nc\r\n\r\n", "a b\r\nc\r\n"},
		{"line\r\n\r\n\r\n", "line\r\n"},
		{"", ""},
		{"   \r\n", ""},
	}
	for _, c := range cases {
		if got := string(canonBodyRelaxed([]byte(c.in))); got != c.want {
			t.Errorf("canonBodyRelaxed(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

const sampleMsg = "From: Alice <alice@example.test>\r\n" +
	"To: bob@example.test\r\n" +
	"Subject: DKIM round trip\r\n" +
	"Date: Mon, 02 Jan 2006 15:04:05 -0700\r\n" +
	"Message-ID: <abc123@example.test>\r\n" +
	"MIME-Version: 1.0\r\n" +
	"Content-Type: text/plain; charset=utf-8\r\n" +
	"\r\n" +
	"Hello DKIM world.\r\nSecond line.\r\n"

func TestSignAndIndependentVerify(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("genkey: %v", err)
	}
	signed, err := Sign([]byte(sampleMsg), "example.test", "sxgate", key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if !strings.HasPrefix(string(signed), "DKIM-Signature: ") {
		t.Fatalf("signed message must start with DKIM-Signature header")
	}

	// Independent verification, mirroring a real verifier.
	headers, body := splitMessage(signed)
	var dkim rawHeader
	idx := map[string]rawHeader{}
	for _, h := range headers {
		ln := strings.ToLower(strings.TrimSpace(h.name))
		if ln == "dkim-signature" {
			dkim = h
		} else {
			idx[ln] = h
		}
	}
	if dkim.name == "" {
		t.Fatal("no DKIM-Signature header found")
	}
	tags := parseDKIMTags(dkim.value)

	// 1) body hash
	bh := sha256.Sum256(canonBodyRelaxed(body))
	if got := base64.StdEncoding.EncodeToString(bh[:]); got != tags["bh"] {
		t.Fatalf("body hash mismatch: got %s want %s", got, tags["bh"])
	}

	// 2) signature over the h= headers + the dkim header with empty b=
	var sb strings.Builder
	for _, n := range strings.Split(tags["h"], ":") {
		h, ok := idx[n]
		if !ok {
			t.Fatalf("h= lists %q but it is not in the message", n)
		}
		sb.WriteString(canonHeaderRelaxed(h.name, h.value))
	}
	emptied := emptyBTag(dkim.value)
	sb.WriteString(strings.TrimSuffix(canonHeaderRelaxed("DKIM-Signature", emptied), "\r\n"))

	digest := sha256.Sum256([]byte(sb.String()))
	sig, err := base64.StdEncoding.DecodeString(tags["b"])
	if err != nil {
		t.Fatalf("decode b=: %v", err)
	}
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], sig); err != nil {
		t.Fatalf("DKIM signature did not verify: %v", err)
	}
}

// emptyBTag blanks the b= tag's value (the signature), leaving every other tag intact —
// what a verifier does before recomputing the header hash.
func emptyBTag(value string) string {
	parts := strings.Split(value, ";")
	for i, p := range parts {
		if strings.HasPrefix(strings.TrimSpace(p), "b=") {
			parts[i] = " b="
		}
	}
	return strings.Join(parts, ";")
}

// parseDKIMTags parses "k=v; k2=v2; ..." into a map (whitespace-trimmed).
func parseDKIMTags(s string) map[string]string {
	m := map[string]string{}
	for _, part := range strings.Split(s, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		eq := strings.IndexByte(part, '=')
		if eq < 0 {
			continue
		}
		m[strings.TrimSpace(part[:eq])] = strings.TrimSpace(part[eq+1:])
	}
	return m
}
