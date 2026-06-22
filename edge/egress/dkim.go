package main

// Minimal RFC 6376 DKIM signer (relaxed/relaxed canonicalization, rsa-sha256). Pure stdlib
// so the egress relay stays a single CGO-free binary. The sxgate mail edge owns the DKIM
// keypair (it owns DNS too), so signing lives here, on the way out to the smarthost.

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

// headersSigned is the canonical order of headers we sign when present. From is mandatory.
var headersSigned = []string{
	"from", "to", "cc", "subject", "date", "message-id",
	"mime-version", "content-type", "content-transfer-encoding",
}

var wsp = regexp.MustCompile(`[ \t]+`)

type rawHeader struct {
	name  string
	value string // everything after the first colon, folding preserved (canon will unfold)
}

// LoadPrivateKey reads an RSA private key (PKCS#1 or PKCS#8 PEM).
func LoadPrivateKey(path string) (*rsa.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, errors.New("no PEM block in DKIM key")
	}
	if k, err := x509.ParsePKCS1PrivateKey(blk.Bytes); err == nil {
		return k, nil
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, err
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("DKIM key is not RSA")
	}
	return rk, nil
}

// Sign prepends a DKIM-Signature header to raw, signing over the relaxed canonicalization of
// the present headers + body with the given key. Now() is read for the t= tag.
func Sign(raw []byte, domain, selector string, key *rsa.PrivateKey) ([]byte, error) {
	return sign(raw, domain, selector, key, time.Now().Unix())
}

func sign(raw []byte, domain, selector string, key *rsa.PrivateKey, t int64) ([]byte, error) {
	headers, body := splitMessage(raw)

	bh := sha256.Sum256(canonBodyRelaxed(body))
	bhB64 := base64.StdEncoding.EncodeToString(bh[:])

	idx := map[string]rawHeader{}
	for _, h := range headers {
		idx[strings.ToLower(strings.TrimSpace(h.name))] = h // last occurrence wins
	}

	var signed []string
	var sb strings.Builder
	for _, n := range headersSigned {
		h, ok := idx[n]
		if !ok {
			continue
		}
		sb.WriteString(canonHeaderRelaxed(h.name, h.value))
		signed = append(signed, n)
	}
	if len(signed) == 0 {
		return nil, errors.New("no signable headers present (missing From?)")
	}

	valueNoB := fmt.Sprintf("v=1; a=rsa-sha256; c=relaxed/relaxed; d=%s; s=%s; t=%d; bh=%s; h=%s; b=",
		domain, selector, t, bhB64, strings.Join(signed, ":"))
	// The DKIM-Signature header is itself signed, with an empty b= and NO trailing CRLF.
	dkimCanon := strings.TrimSuffix(canonHeaderRelaxed("DKIM-Signature", valueNoB), "\r\n")
	sb.WriteString(dkimCanon)

	digest := sha256.Sum256([]byte(sb.String()))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return nil, err
	}
	final := "DKIM-Signature: " + valueNoB + base64.StdEncoding.EncodeToString(sig) + "\r\n"
	return append([]byte(final), raw...), nil
}

// splitMessage separates header fields (folding preserved) from the body.
func splitMessage(raw []byte) (headers []rawHeader, body []byte) {
	idx := bytes.Index(raw, []byte("\r\n\r\n"))
	sep := 4
	if idx < 0 {
		if i := bytes.Index(raw, []byte("\n\n")); i >= 0 {
			idx, sep = i, 2
		}
	}
	var head []byte
	if idx < 0 {
		head = raw
	} else {
		head = raw[:idx]
		body = raw[idx+sep:]
	}
	lines := strings.Split(strings.ReplaceAll(string(head), "\r\n", "\n"), "\n")
	var name string
	var val *strings.Builder
	flush := func() {
		if val != nil {
			headers = append(headers, rawHeader{name, val.String()})
		}
		val = nil
	}
	for _, ln := range lines {
		if ln == "" {
			continue
		}
		if ln[0] == ' ' || ln[0] == '\t' { // folded continuation
			if val != nil {
				val.WriteString("\r\n")
				val.WriteString(ln)
			}
			continue
		}
		flush()
		c := strings.IndexByte(ln, ':')
		if c < 0 {
			name, val = ln, &strings.Builder{}
			continue
		}
		name = ln[:c]
		val = &strings.Builder{}
		val.WriteString(ln[c+1:])
	}
	flush()
	return headers, body
}

// canonHeaderRelaxed implements RFC 6376 §3.4.2 (relaxed header canonicalization).
func canonHeaderRelaxed(name, value string) string {
	n := strings.ToLower(strings.TrimSpace(name))
	v := strings.ReplaceAll(value, "\r\n", "")
	v = strings.ReplaceAll(v, "\n", "")
	v = wsp.ReplaceAllString(v, " ")
	v = strings.TrimSpace(v)
	return n + ":" + v + "\r\n"
}

// canonBodyRelaxed implements RFC 6376 §3.4.4 (relaxed body canonicalization).
func canonBodyRelaxed(body []byte) []byte {
	s := strings.ReplaceAll(string(body), "\r\n", "\n")
	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		ln = wsp.ReplaceAllString(ln, " ")
		lines[i] = strings.TrimRight(ln, " ")
	}
	out := strings.TrimRight(strings.Join(lines, "\r\n"), "\r\n")
	if out == "" {
		return []byte{}
	}
	return []byte(out + "\r\n")
}
