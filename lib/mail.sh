# shellcheck shell=bash
# sxgate mail — the public mail EDGE for the holistic mail service (maild).
#
# maild owns mailboxes + the HTTP/JMAP API and delivers internal mail directly; it never
# speaks SMTP to the internet. This module makes sxgate own the public network edge:
#
#   inbound   Cloudflare Email Routing → an Email Worker → HTTPS webhook to maild
#             (POST /api/services/mail/inbound, authenticated by a shared secret) — the only
#             way internet mail can reach a Cloudflare-Tunnel-only host (port 25 can't tunnel).
#   outbound  maild spools a message → the loopback egress relay (sxgate-mail-egress) →
#             DKIM-signed → submitted to a smarthost.
#   DNS       MX (via Email Routing), SPF, DKIM and DMARC records for the mail domain.
#
# Sourced by the `sxgate` CLI; relies on its helpers: die, log, warn, confirm, with_lock,
# atomic_write, load_conf, needs_root.

# ── config (env-overridable, like the rest of sxgate) ───────────────────────────
: "${MAIL_ETC:=/etc/sxgate/mail}"                         # edge state
: "${MAIL_CONF:=$MAIL_ETC/mail.conf}"                     # domain + smarthost
: "${MAIL_DKIM_DIR:=$MAIL_ETC/dkim}"                      # DKIM keypair
: "${MAIL_SELECTOR:=sxgate}"                              # DKIM selector
: "${MAIL_USER:=sxgate-mail}"                             # unprivileged egress owner
: "${MAIL_EGRESS_PORT:=8786}"                             # egress relay loopback port
: "${MAIL_LIBEXEC:=/usr/local/lib/sxgate}"               # where the egress binary lands
: "${MAIL_EGRESS_BIN:=$MAIL_LIBEXEC/sxgate-mail-egress}"
: "${MAIL_SMARTHOST_PASS:=$MAIL_ETC/smarthost-pass}"     # smarthost AUTH password
: "${MAIL_CF_TOKEN:=$MAIL_ETC/cf-token}"                 # Cloudflare API token (DNS); optional
: "${MAIL_WORKER_DIR:=$MAIL_ETC/worker}"                 # rendered Email Worker + wrangler.toml
: "${HOLISTIC_DIR:=/etc/holistic}"
: "${MAIL_INBOUND_SECRET_FILE:=$HOLISTIC_DIR/mail-inbound-secret}"  # shared with maild + worker
: "${MAIL_EDGE_SECRET_FILE:=$HOLISTIC_DIR/mail-edge-secret}"        # shared maild↔egress
: "${MAILD_UNIT:=mail.service}"                           # maild systemd unit (for the drop-in)
: "${MAILD_DROPIN_DIR:=/etc/systemd/system/$MAILD_UNIT.d}"
: "${HOLISTIC_GROUP:=holistic}"
: "${MAIL_SYSTEMD_DIR:=/etc/systemd/system}"
SXGATE_EDGE_DIR="${SXGATE_EDGE_DIR:-$SXGATE_DIR/edge}"    # repo edge/ (worker.js, egress/)

# ── helpers ─────────────────────────────────────────────────────────────────────
_mail_gen_secret() {
  # _mail_gen_secret <file> — create a 32-byte url-safe secret if absent (group-readable).
  local file=$1
  [ -s "$file" ] && return 0
  local s
  if command -v openssl >/dev/null 2>&1; then
    s=$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-43)
  else
    s=$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-43)
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$s" | atomic_write "$file"
  chmod 0640 "$file"
  getent group "$HOLISTIC_GROUP" >/dev/null 2>&1 && chgrp "$HOLISTIC_GROUP" "$file" 2>/dev/null || true
  log "generated secret: $file"
}

_mail_ensure_user() {
  [ "$(id -u)" -eq 0 ] || return 0
  command -v useradd >/dev/null 2>&1 || return 0
  id "$MAIL_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$MAIL_USER" 2>/dev/null \
    || warn "could not create system user '$MAIL_USER'"
  # Let the egress user read holistic-group secrets (the shared edge secret).
  getent group "$HOLISTIC_GROUP" >/dev/null 2>&1 && usermod -aG "$HOLISTIC_GROUP" "$MAIL_USER" 2>/dev/null || true
}

_mail_ensure_go() {
  command -v go >/dev/null 2>&1 && return 0
  log "installing Go toolchain (for the egress relay)..."
  apt-get update -qq && apt-get install -y -qq golang-go >/dev/null
  command -v go >/dev/null 2>&1 || die "Go install failed" 4
}

_mail_dkim_init() {
  # Generate the DKIM keypair if absent. Prints nothing; use 'mail dkim-record' to show it.
  mkdir -p "$MAIL_DKIM_DIR"
  chmod 0750 "$MAIL_DKIM_DIR" 2>/dev/null || true
  if [ ! -s "$MAIL_DKIM_DIR/private.pem" ]; then
    command -v openssl >/dev/null 2>&1 || die "openssl required for DKIM key generation" 4
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$MAIL_DKIM_DIR/private.pem" 2>/dev/null \
      || die "DKIM key generation failed" 4
    openssl pkey -in "$MAIL_DKIM_DIR/private.pem" -pubout -out "$MAIL_DKIM_DIR/public.pem" 2>/dev/null \
      || die "DKIM public key extraction failed" 4
    chmod 0640 "$MAIL_DKIM_DIR/private.pem"
    id "$MAIL_USER" >/dev/null 2>&1 && chgrp "$MAIL_USER" "$MAIL_DKIM_DIR/private.pem" 2>/dev/null || true
    log "generated DKIM keypair in $MAIL_DKIM_DIR"
  fi
}

_mail_dkim_pub() {
  # Print the base64 public key (DER SubjectPublicKeyInfo) for the DKIM TXT record.
  [ -s "$MAIL_DKIM_DIR/public.pem" ] || return 1
  grep -v '^-----' "$MAIL_DKIM_DIR/public.pem" | tr -d '\n'
}

_mail_conf_get() { [ -s "$MAIL_CONF" ] && (grep -m1 "^$1=" "$MAIL_CONF" 2>/dev/null | cut -d= -f2-) || true; }

_mail_write_conf() {
  # _mail_write_conf <domain> <relay-host> <relay-user> <webhook>
  mkdir -p "$MAIL_ETC"
  cat <<EOF | atomic_write "$MAIL_CONF"
# /etc/sxgate/mail/mail.conf — managed by 'sxgate mail'; safe to edit
MAIL_DOMAIN=$1
RELAY_HOST=$2
RELAY_USER=$3
WEBHOOK=$4
SELECTOR=$MAIL_SELECTOR
EOF
}

_mail_webhook_url() {
  # Resolve the public webhook maild is reachable at: explicit arg → instance.json origin →
  # https://<zone>/...  (Email Worker posts here through the tunnel).
  local explicit=${1:-}
  [ -n "$explicit" ] && { printf '%s' "$explicit"; return; }
  local origin=""
  [ -r "$HOLISTIC_DIR/../var/lib/holistic/instance.json" ] && :  # (left for clarity; real path below)
  if [ -r /var/lib/holistic/instance.json ]; then
    origin=$(grep -oE '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' /var/lib/holistic/instance.json 2>/dev/null \
      | sed -E 's/.*"origin"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n1)
  fi
  if [ -n "$origin" ]; then
    printf '%s/api/services/mail/inbound' "$origin"
  else
    printf 'https://%s/api/services/mail/inbound' "${MANAGED_ZONE:-CHANGE-ME}"
  fi
}

_mail_build_egress() {
  [ -d "$SXGATE_EDGE_DIR/egress" ] || die "egress source not found at $SXGATE_EDGE_DIR/egress" 5
  _mail_ensure_go
  mkdir -p "$MAIL_LIBEXEC"
  log "building sxgate-mail-egress..."
  ( cd "$SXGATE_EDGE_DIR/egress" && GOCACHE="/tmp/sxgate-egress-gocache" go build -o "$MAIL_EGRESS_BIN" . ) \
    || die "egress build failed" 4
  id "$MAIL_USER" >/dev/null 2>&1 && chown root:"$MAIL_USER" "$MAIL_EGRESS_BIN" 2>/dev/null || true
  chmod 0755 "$MAIL_EGRESS_BIN"
}

_mail_write_egress_unit() {
  local domain=$1 relay=$2 user=$3
  mkdir -p "$MAIL_SYSTEMD_DIR"
  cat <<EOF | atomic_write "$MAIL_SYSTEMD_DIR/sxgate-mail-egress.service"
[Unit]
Description=sxgate mail edge — outbound DKIM-signing SMTP relay
After=network.target

[Service]
User=$MAIL_USER
Group=$MAIL_USER
Environment=EGRESS_LISTEN=127.0.0.1:$MAIL_EGRESS_PORT
Environment=EGRESS_SECRET_FILE=$MAIL_EDGE_SECRET_FILE
Environment=EGRESS_DKIM_KEY=$MAIL_DKIM_DIR/private.pem
Environment=EGRESS_DKIM_SELECTOR=$MAIL_SELECTOR
Environment=EGRESS_DKIM_DOMAIN=$domain
Environment=EGRESS_SMARTHOST=$relay
Environment=EGRESS_SMARTHOST_USER=$user
Environment=EGRESS_SMARTHOST_PASS_FILE=$MAIL_SMARTHOST_PASS
ExecStart=$MAIL_EGRESS_BIN
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=true
RestrictRealtime=true

[Install]
WantedBy=multi-user.target
EOF
}

_mail_write_maild_dropin() {
  # Point maild at the egress relay without touching its base unit (decoupled).
  mkdir -p "$MAILD_DROPIN_DIR"
  cat <<EOF | atomic_write "$MAILD_DROPIN_DIR/10-edge.conf"
# Generated by 'sxgate mail setup' — wires maild's outbound queue to the sxgate edge.
[Service]
Environment=MAILD_EDGE_URL=http://127.0.0.1:$MAIL_EGRESS_PORT/outbound
Environment=MAILD_EDGE_SECRET_FILE=$MAIL_EDGE_SECRET_FILE
EOF
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl try-restart "$MAILD_UNIT" 2>/dev/null || true
  fi
}

_mail_render_worker() {
  local webhook=$1
  mkdir -p "$MAIL_WORKER_DIR"
  cp -f "$SXGATE_EDGE_DIR/worker.js" "$MAIL_WORKER_DIR/worker.js"
  cat <<EOF | atomic_write "$MAIL_WORKER_DIR/wrangler.toml"
# Generated by 'sxgate mail setup'. Deploy with:  wrangler deploy
# Then bind the secret:  wrangler secret put INBOUND_SECRET   (value = $MAIL_INBOUND_SECRET_FILE)
# Finally, in Cloudflare Email Routing, route the address(es) to this Worker.
name = "sxgate-mail-inbound"
main = "worker.js"
compatibility_date = "2024-11-01"

[vars]
MAILD_WEBHOOK = "$webhook"
EOF
}

_mail_dns() {
  # Print the DNS records the operator must publish; create the TXT ones via the Cloudflare
  # API when a token is present (best-effort). MX is managed by Email Routing, not here.
  local domain=$1 pub spf dmarc dkim
  pub=$(_mail_dkim_pub || true)
  spf="v=spf1 include:_spf.mx.cloudflare.net ~all"
  dmarc="v=DMARC1; p=none; rua=mailto:postmaster@$domain"
  dkim="v=DKIM1; k=rsa; p=$pub"
  log ""
  log "── DNS records for $domain ──"
  log "  MX      : enable Cloudflare Email Routing (it creates the MX records automatically)"
  log "  TXT  @                         : $spf"
  log "  TXT  ${MAIL_SELECTOR}._domainkey : $dkim"
  log "  TXT  _dmarc                    : $dmarc"
  if [ -s "$MAIL_CF_TOKEN" ]; then
    _mail_cf_upsert_txt "$domain" "@" "$spf"
    _mail_cf_upsert_txt "$domain" "${MAIL_SELECTOR}._domainkey" "$dkim"
    _mail_cf_upsert_txt "$domain" "_dmarc" "$dmarc"
  else
    log "  (no $MAIL_CF_TOKEN — add the records above manually, or drop a Cloudflare API token there)"
  fi
}

_mail_cf_upsert_txt() {
  # Best-effort create/update of a TXT record via the Cloudflare API. domain, name, content.
  local domain=$1 name=$2 content=$3 token zoneid fqdn
  token=$(cat "$MAIL_CF_TOKEN" 2>/dev/null) || return 0
  command -v curl >/dev/null 2>&1 || { warn "curl missing — cannot call Cloudflare API"; return 0; }
  zoneid=$(curl -fsS -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=$domain" 2>/dev/null \
    | grep -oE '"id":"[0-9a-f]{32}"' | head -n1 | cut -d'"' -f4) || true
  [ -n "$zoneid" ] || { warn "could not resolve Cloudflare zone id for $domain"; return 0; }
  [ "$name" = "@" ] && fqdn="$domain" || fqdn="$name.$domain"
  curl -fsS -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" \
    --data "$(printf '{"type":"TXT","name":"%s","content":"%s","ttl":300}' "$fqdn" "$content")" >/dev/null 2>&1 \
    && log "  cloudflare: TXT $fqdn upserted" \
    || warn "  cloudflare: TXT $fqdn upsert failed (may already exist — check the dashboard)"
}

# ── commands ──────────────────────────────────────────────────────────────────
_mail_setup() {
  local domain="" relay="" user="" webhook=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) domain=$2; shift 2 ;;
      --relay) relay=$2; shift 2 ;;
      --relay-user) user=$2; shift 2 ;;
      --webhook) webhook=$2; shift 2 ;;
      -h|--help) _mail_usage; return 0 ;;
      *) die "unknown flag: $1" 2 ;;
    esac
  done
  load_conf
  [ -n "$domain" ] || domain=${MANAGED_ZONE:-}
  [ -n "$domain" ] || die "set --domain <mailDomain> (or 'sxgate zone <domain>' first)" 5
  with_lock _mail_setup_locked "$domain" "$relay" "$user" "$webhook"
}
_mail_setup_locked() {
  local domain=$1 relay=$2 user=$3 webhook=$4
  mkdir -p "$MAIL_ETC" "$HOLISTIC_DIR"
  _mail_ensure_user
  _mail_gen_secret "$MAIL_INBOUND_SECRET_FILE"
  _mail_gen_secret "$MAIL_EDGE_SECRET_FILE"
  _mail_dkim_init
  webhook=$(_mail_webhook_url "$webhook")
  _mail_write_conf "$domain" "$relay" "$user" "$webhook"
  _mail_build_egress
  _mail_write_egress_unit "$domain" "$relay" "$user"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now sxgate-mail-egress >/dev/null 2>&1 || warn "could not start sxgate-mail-egress (configure --relay, then 'sxgate mail relay set')"
  fi
  _mail_write_maild_dropin
  _mail_render_worker "$webhook"
  _mail_dns "$domain"
  log ""
  log "── manual steps to finish inbound ──"
  log "  1. Cloudflare dashboard → Email → Email Routing → enable for $domain"
  log "  2. cd $MAIL_WORKER_DIR && wrangler deploy"
  log "  3. wrangler secret put INBOUND_SECRET   # paste $(cat "$MAIL_INBOUND_SECRET_FILE" 2>/dev/null || echo '<secret>')"
  log "  4. Email Routing → route your address(es) (or catch-all) to Worker 'sxgate-mail-inbound'"
  [ -n "$relay" ] || log "  5. outbound: 'sxgate mail relay set <smtp-host:port> [--user <u>]'"
  log ""
  log "verify the inbound contract against a running maild:  sudo sxgate mail test-inbound --to <user>@$domain"
}

_mail_cmd_dkim_init() { with_lock _mail_dkim_init; _mail_cmd_dkim_record; }

_mail_cmd_dkim_record() {
  local pub; pub=$(_mail_dkim_pub) || die "no DKIM key yet — run 'sxgate mail dkim-init'" 5
  local domain; domain=$(_mail_conf_get MAIL_DOMAIN); [ -n "$domain" ] || { load_conf; domain=${MANAGED_ZONE:-your-domain}; }
  printf '%s._domainkey.%s.  IN TXT  "v=DKIM1; k=rsa; p=%s"\n' "$MAIL_SELECTOR" "$domain" "$pub"
}

_mail_cmd_relay() {
  local sub=${1:-}; shift || true
  [ "$sub" = "set" ] || die "usage: sxgate mail relay set <host:port> [--user <u>]" 2
  local hostport=${1:-} user=""
  [ -n "$hostport" ] || die "usage: sxgate mail relay set <host:port> [--user <u>]" 2
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in --user) user=$2; shift 2 ;; *) die "unknown flag: $1" 2 ;; esac
  done
  [[ "$hostport" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "smarthost must be host:port" 3
  with_lock _mail_relay_locked "$hostport" "$user"
}
_mail_relay_locked() {
  local hostport=$1 user=$2 domain
  load_conf
  domain=$(_mail_conf_get MAIL_DOMAIN); [ -n "$domain" ] || domain=${MANAGED_ZONE:-}
  [ -n "$domain" ] || die "run 'sxgate mail setup --domain <d>' first" 5
  _mail_write_conf "$domain" "$hostport" "$user" "$(_mail_conf_get WEBHOOK)"
  if [ -n "$user" ]; then
    printf 'Smarthost password for %s@%s: ' "$user" "$hostport" >&2
    local pass; read -rs pass; echo >&2
    printf '%s' "$pass" | atomic_write "$MAIL_SMARTHOST_PASS"
    chmod 0640 "$MAIL_SMARTHOST_PASS"
    id "$MAIL_USER" >/dev/null 2>&1 && chgrp "$MAIL_USER" "$MAIL_SMARTHOST_PASS" 2>/dev/null || true
  fi
  _mail_write_egress_unit "$domain" "$hostport" "$user"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sxgate-mail-egress 2>/dev/null || warn "could not restart sxgate-mail-egress"
  fi
  log "outbound relay set: $hostport${user:+ (user $user)}"
}

_mail_cmd_worker() {
  load_conf
  local webhook; webhook=$(_mail_conf_get WEBHOOK); [ -n "$webhook" ] || webhook=$(_mail_webhook_url "")
  with_lock _mail_render_worker "$webhook"
  log "worker rendered in $MAIL_WORKER_DIR (webhook: $webhook)"
  log "deploy: cd $MAIL_WORKER_DIR && wrangler deploy && wrangler secret put INBOUND_SECRET"
}

_mail_cmd_test_inbound() {
  local to="" url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to=$2; shift 2 ;;
      --url) url=$2; shift 2 ;;
      *) die "unknown flag: $1" 2 ;;
    esac
  done
  [ -n "$to" ] || die "usage: sxgate mail test-inbound --to <user@domain> [--url <webhook>]" 2
  command -v curl >/dev/null 2>&1 || die "curl required" 4
  local secret; secret=$(cat "$MAIL_INBOUND_SECRET_FILE" 2>/dev/null) || die "no inbound secret ($MAIL_INBOUND_SECRET_FILE) — run 'sxgate mail setup'" 5
  [ -n "$url" ] || url="http://127.0.0.1:8775/api/services/mail/inbound"
  local from="edge-test@$(load_conf; echo "${MANAGED_ZONE:-example.test}")"
  local msg
  printf -v msg 'From: %s\r\nTo: %s\r\nSubject: sxgate edge test\r\n\r\nInbound contract OK.\r\n' "$from" "$to"
  log "POST $url  (rcpt=$to)"
  printf '%s' "$msg" | curl -sS -X POST \
    -H "X-Mail-Inbound-Secret: $secret" -H "X-Mail-Rcpt: $to" -H 'Content-Type: message/rfc822' \
    --data-binary @- "$url"
  echo
}

_mail_cmd_status() {
  load_conf
  echo "── sxgate mail edge ──"
  echo "domain:       $(_mail_conf_get MAIL_DOMAIN || echo '(unset)')"
  echo "webhook:      $(_mail_conf_get WEBHOOK || echo '(unset)')"
  echo "relay:        $(_mail_conf_get RELAY_HOST || echo '(unset)')${_:+}"
  echo "selector:     $MAIL_SELECTOR"
  echo "inbound sec:  $([ -s "$MAIL_INBOUND_SECRET_FILE" ] && echo present || echo MISSING)"
  echo "edge sec:     $([ -s "$MAIL_EDGE_SECRET_FILE" ] && echo present || echo MISSING)"
  echo "dkim key:     $([ -s "$MAIL_DKIM_DIR/private.pem" ] && echo present || echo MISSING)"
  echo "egress bin:   $([ -x "$MAIL_EGRESS_BIN" ] && echo "$MAIL_EGRESS_BIN" || echo '(not built)')"
  echo "maild dropin: $([ -f "$MAILD_DROPIN_DIR/10-edge.conf" ] && echo present || echo missing)"
  echo "worker:       $([ -f "$MAIL_WORKER_DIR/worker.js" ] && echo "$MAIL_WORKER_DIR" || echo '(not rendered)')"
  if command -v systemctl >/dev/null 2>&1; then
    echo
    echo "── systemctl status sxgate-mail-egress ──"
    systemctl --no-pager --lines=3 status sxgate-mail-egress 2>&1 || true
  fi
}

_mail_usage() {
  cat <<EOF
Usage:
  sxgate mail setup [--domain <d>] [--relay <host:port>] [--relay-user <u>] [--webhook <url>]
                                   provision the edge: secrets, DKIM, egress relay, maild
                                   drop-in, Email Worker, and the DNS records to publish
  sxgate mail relay set <host:port> [--user <u>]   configure the outbound smarthost
  sxgate mail dkim-init            generate the DKIM keypair + print the TXT record
  sxgate mail dkim-record          print the DKIM TXT record for DNS
  sxgate mail worker               (re)render the Cloudflare Email Worker + wrangler.toml
  sxgate mail test-inbound --to <user@domain> [--url <webhook>]
                                   POST a sample message to maild's inbound webhook
  sxgate mail status

Inbound rides Cloudflare Email Routing → an Email Worker → the maild webhook (the tunnel is
HTTP-only, so this is the only inbound path). Outbound is DKIM-signed by the local egress
relay and submitted to your smarthost. State: $MAIL_ETC ; shared secrets: $HOLISTIC_DIR.
EOF
}

cmd_mail() {
  local sub=${1:-help}
  case "$sub" in
    status|help|-h|--help|"") : ;;        # read-only / help: no root
    *) needs_root mail "$@" ;;            # re-exec the whole 'mail <sub> …' as root
  esac
  shift || true
  case "$sub" in
    setup) _mail_setup "$@" ;;
    relay) _mail_cmd_relay "$@" ;;
    dkim-init) _mail_cmd_dkim_init "$@" ;;
    dkim-record) _mail_cmd_dkim_record "$@" ;;
    worker) _mail_cmd_worker "$@" ;;
    test-inbound) _mail_cmd_test_inbound "$@" ;;
    status) _mail_cmd_status "$@" ;;
    ""|help|-h|--help) _mail_usage ;;
    *) die "unknown subcommand: mail $sub" 2 ;;
  esac
}
