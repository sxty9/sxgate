#!/usr/bin/env bash
# Test runner for sxgate. Plain bash; mocks cloudflared + systemctl. No external deps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SXGATE="$SCRIPT_DIR/../sxgate"

# ── test harness ──────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT=""

color() { tput setaf "$1" 2>/dev/null || true; }
reset() { tput sgr0 2>/dev/null || true; }

ok()   { color 2; printf '  ✓ %s\n' "$1"; reset; PASS=$((PASS+1)); }
fail() { color 1; printf '  ✗ %s\n     %s\n' "$1" "$2"; reset; FAIL=$((FAIL+1)); FAILED_TESTS+=("$CURRENT: $1"); }

assert_eq()       { [ "$1" = "$2" ] && ok "$3" || fail "$3" "expected '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] && ok "$3" || fail "$3" "'$1' does not contain '$2'"; }
assert_file_exists() { [ -e "$1" ] && ok "$2" || fail "$2" "file not found: $1"; }
assert_file_contains() {
  [ -e "$1" ] || { fail "$3" "file missing: $1"; return; }
  if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3" "'$1' does not contain '$2'"; fi
}
assert_file_not_contains() {
  [ -e "$1" ] || { fail "$3" "file missing: $1"; return; }
  if grep -qF -- "$2" "$1"; then fail "$3" "'$1' unexpectedly contains '$2'"; else ok "$3"; fi
}
assert_exit() {
  local want=$1; shift
  local got=0
  ( "$@" ) >/dev/null 2>&1 || got=$?
  [ "$got" -eq "$want" ] && ok "exit $want from: $*" || fail "exit $want from: $*" "got exit $got"
}

setup_env() {
  TMP=$(mktemp -d)
  export SXGATE_CONF="$TMP/sxgate.conf"
  export SERVICES_FILE="$TMP/services"
  export BACKUP_DIR="$TMP/backups"
  export CONFIG_FILE="$TMP/config.yml"
  export LOCK_FILE="$TMP/sxgate.lock"
  export MANAGED_ZONE="test.example"
  export TUNNEL_NAME="sxgate"
  export SXGATE_YES=1
  export SXGATE_QUIET=1
  export SXGATE_NO_SUDO=1
  export HOME="$TMP"            # isolate ~/.cloudflared for setup/login checks
  mkdir -p "$BACKUP_DIR" "$TMP/.cloudflared"

  # Mock cloudflared + systemctl onto PATH
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/cloudflared" <<'EOF'
#!/bin/sh
# Mock cloudflared
case "$1 $2" in
  "tunnel list")
    case "$3" in
      "--output")
        echo '[{"id":"mock-tunnel-id","name":"sxgate","created_at":"2024-01-01"}]'
        ;;
      *)
        printf 'ID\tNAME\nmock-tunnel-id\tsxgate\n'
        ;;
    esac
    exit 0
    ;;
  "tunnel ingress")
    case "$3" in
      validate)
        # Sniff the target file for a fake-malformed marker (used to test rollback).
        cfg=$4
        if [ -n "$cfg" ] && [ -f "$cfg" ] && grep -q '^# CF_INVALID' "$cfg"; then
          echo "Validation failed" >&2
          exit 1
        fi
        echo "OK"
        exit 0
        ;;
    esac
    ;;
  "tunnel route")
    # tunnel route dns <name> <host>
    echo "dns route created for $5"
    exit 0
    ;;
  "tunnel info")
    echo "tunnel $3 ok"
    exit 0
    ;;
  "tunnel create")
    echo "Created tunnel $3 with id mock-tunnel-id"
    exit 0
    ;;
  "tunnel login")
    echo "logged in"
    exit 0
    ;;
  "service install")
    exit 0
    ;;
esac
echo "mock cloudflared: unhandled args: $*" >&2
exit 1
EOF
  chmod +x "$TMP/bin/cloudflared"

  cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/bin/systemctl"

  # Mock caddy (preview dispatcher): validate/run/reload all succeed.
  cat > "$TMP/bin/caddy" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/bin/caddy"

  # Preview engine state → all under $TMP, small port pool.
  export PREVIEW_ETC="$TMP/preview-etc"
  export PREVIEW_ROOT="$TMP/preview-root"
  export PREVIEW_LIBEXEC="$TMP/libexec"
  export PREVIEW_SYSTEMD_DIR="$TMP/systemd"
  export PREVIEW_DISPATCH_PORT=21490
  export PREVIEW_PORT_LO=8800
  export PREVIEW_PORT_HI=8802

  # `flock` may not exist on macOS; provide a no-op stub if missing.
  if ! command -v flock >/dev/null 2>&1; then
    cat > "$TMP/bin/flock" <<'EOF'
#!/bin/sh
# noop flock stub for environments without util-linux
exit 0
EOF
    chmod +x "$TMP/bin/flock"
  fi

  export PATH="$TMP/bin:$PATH"
}

teardown_env() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  unset TMP
}

run_test() {
  CURRENT=$1
  printf '\n%s\n' "── $1 ──"
  setup_env
  # Run the test body
  "$1" || fail "$1" "test body raised an error"
  teardown_env
}

# Helper: write a populated config.yml
write_populated_config() {
  cat > "$CONFIG_FILE" <<'EOF'
tunnel: mock-tunnel-id
credentials-file: /root/.cloudflared/mock-tunnel-id.json
ingress:
  - hostname: test.example
    service: http://localhost:8080
  - hostname: api.test.example
    service: http://localhost:3000
  - service: http_status:404
EOF
}

write_empty_config() {
  cat > "$CONFIG_FILE" <<'EOF'
tunnel: mock-tunnel-id
credentials-file: /root/.cloudflared/mock-tunnel-id.json
ingress:
  - service: http_status:404
EOF
}

# ── tests ─────────────────────────────────────────────────────────────────────

test_help_and_version() {
  out=$("$SXGATE" --version)
  assert_contains "$out" "sxgate 0" "--version prints version"
  out=$("$SXGATE" --help)
  assert_contains "$out" "Usage:" "--help prints usage"
}

test_init_scaffolds_config() {
  # No existing config — init should scaffold one.
  cat > "$SXGATE_CONF" <<EOF
TUNNEL_NAME=sxgate
MANAGED_ZONE=test.example
CONFIG_FILE=$CONFIG_FILE
EOF
  "$SXGATE" init --zone test.example >/dev/null
  assert_file_exists "$CONFIG_FILE" "config.yml scaffolded"
  assert_file_contains "$CONFIG_FILE" "tunnel: mock-tunnel-id" "tunnel ID written"
  assert_file_contains "$CONFIG_FILE" "http_status:404" "catch-all present"
  assert_file_exists "$SERVICES_FILE" "services file created"
  assert_file_exists "$SXGATE_CONF" "sxgate.conf written"
  assert_file_contains "$SXGATE_CONF" "MANAGED_ZONE=test.example" "zone persisted"
}

test_init_preserves_existing_config() {
  write_populated_config
  before=$(cat "$CONFIG_FILE")
  "$SXGATE" init --zone test.example >/dev/null
  after=$(cat "$CONFIG_FILE")
  assert_eq "$after" "$before" "existing config preserved"
  # Backup should be present
  count=$(ls -1 "$BACKUP_DIR"/config.yml.* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -ge 1 ]; then ok "backup created on init"; else fail "backup created on init" "no backups found"; fi
}

test_service_crud() {
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  assert_file_contains "$SERVICES_FILE" "blog=http://localhost:2368" "service added"

  # Idempotent same URL
  out=$("$SXGATE" service add blog http://localhost:2368 2>&1)
  count=$(grep -c '^blog=' "$SERVICES_FILE")
  assert_eq "$count" "1" "idempotent re-add does not duplicate"

  # Update URL
  "$SXGATE" service add blog http://localhost:9999 >/dev/null
  assert_file_contains "$SERVICES_FILE" "blog=http://localhost:9999" "URL updated"
  assert_file_not_contains "$SERVICES_FILE" "blog=http://localhost:2368" "old URL gone"

  # Add second service
  "$SXGATE" service add api http://localhost:3000 >/dev/null
  out=$("$SXGATE" service ls)
  assert_contains "$out" "blog" "ls lists blog"
  assert_contains "$out" "api" "ls lists api"

  # Remove
  "$SXGATE" service rm blog >/dev/null
  assert_file_not_contains "$SERVICES_FILE" "^blog=" "blog removed"
}

test_service_validation() {
  write_empty_config
  assert_exit 3 "$SXGATE" service add BadName http://localhost:1
  assert_exit 3 "$SXGATE" service add good not-a-url
  assert_exit 3 "$SXGATE" service add good "javascript:alert(1)"
  "$SXGATE" service add good http_status:200 >/dev/null && ok "http_status URL accepted" || fail "http_status URL accepted" "rejected"
}

test_route_add_inserts_above_catchall() {
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  "$SXGATE" route add blog.test.example blog >/dev/null
  assert_file_contains "$CONFIG_FILE" "hostname: blog.test.example" "hostname written"
  assert_file_contains "$CONFIG_FILE" "service: http://localhost:2368" "URL resolved"
  # Catch-all still last line of ingress block
  tail_line=$(tail -n1 "$CONFIG_FILE")
  assert_contains "$tail_line" "http_status:404" "catch-all still last"
}

test_route_idempotent_and_update() {
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  "$SXGATE" service add blog2 http://localhost:2369 >/dev/null
  "$SXGATE" route add blog.test.example blog >/dev/null
  before=$(cat "$CONFIG_FILE")
  "$SXGATE" route add blog.test.example blog >/dev/null
  after=$(cat "$CONFIG_FILE")
  assert_eq "$after" "$before" "re-add same service is idempotent"

  # Update to different service
  "$SXGATE" route add blog.test.example blog2 >/dev/null
  count=$(grep -c "hostname: blog.test.example" "$CONFIG_FILE")
  assert_eq "$count" "1" "no duplicate route after update"
  assert_file_contains "$CONFIG_FILE" "service: http://localhost:2369" "new URL written"
}

test_route_rejects_out_of_zone() {
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  assert_exit 3 "$SXGATE" route add blog.otherdomain.com blog
}

test_route_rejects_missing_service() {
  write_empty_config
  assert_exit 3 "$SXGATE" route add blog.test.example nonexistent
}

test_route_rm() {
  write_populated_config
  "$SXGATE" route rm api.test.example >/dev/null
  assert_file_not_contains "$CONFIG_FILE" "api.test.example" "host removed"
  assert_file_contains "$CONFIG_FILE" "test.example" "other host still present"
  assert_file_contains "$CONFIG_FILE" "http_status:404" "catch-all preserved"
  # rm nonexistent → exit 3
  assert_exit 3 "$SXGATE" route rm nope.test.example
}

test_route_ls_joins_services() {
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  "$SXGATE" route add blog.test.example blog >/dev/null
  out=$("$SXGATE" route ls)
  assert_contains "$out" "blog.test.example" "ls shows hostname"
  assert_contains "$out" "blog" "ls shows service name"
  assert_contains "$out" "http://localhost:2368" "ls shows URL"
}

test_service_rm_blocked_by_routes() {
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  "$SXGATE" route add blog.test.example blog >/dev/null
  assert_exit 3 "$SXGATE" service rm blog
  # With --force succeeds
  "$SXGATE" service rm blog --force >/dev/null && ok "--force overrides" || fail "--force overrides" "did not succeed"
  # Route remains
  assert_file_contains "$CONFIG_FILE" "blog.test.example" "route URL still inline"
}

test_route_ls_marks_unregistered() {
  write_populated_config
  out=$("$SXGATE" route ls)
  # No services registered → both hostnames show '?' under SERVICE column
  q_count=$(printf '%s\n' "$out" | grep -c '?')
  if [ "$q_count" -ge 2 ]; then ok "unregistered routes flagged"; else fail "unregistered routes flagged" "expected ≥2 '?' in: $out"; fi
}

test_validation_failure_rolls_back() {
  write_populated_config
  "$SXGATE" service add api http://localhost:3000 >/dev/null
  # Make next validate() fail by prepending the magic marker to the next-written file.
  # We do that by overriding the mock to inject the marker on write — simpler: just write a wrapper.
  cat > "$TMP/bin/cloudflared" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "tunnel ingress")
    [ "$3" = "validate" ] && { echo "Validation failed" >&2; exit 1; }
    ;;
  "tunnel route") echo ok; exit 0 ;;
  "tunnel list")
    [ "$3" = "--output" ] && echo '[{"id":"mock-tunnel-id","name":"sxgate"}]' || echo "sxgate"
    exit 0 ;;
esac
exit 0
EOF
  before=$(cat "$CONFIG_FILE")
  # Should fail and roll back
  rc=0
  "$SXGATE" route add new.test.example api >/dev/null 2>&1 || rc=$?
  after=$(cat "$CONFIG_FILE")
  if [ "$rc" -eq 4 ]; then ok "exit 4 on validate failure"; else fail "exit 4 on validate failure" "got $rc"; fi
  assert_eq "$after" "$before" "config rolled back to backup"
}

test_yaml_parser_rejects_missing_catchall() {
  cat > "$CONFIG_FILE" <<'EOF'
tunnel: mock-tunnel-id
credentials-file: /tmp/x.json
ingress:
  - hostname: a.test.example
    service: http://localhost:1
EOF
  "$SXGATE" service add a http://localhost:1 >/dev/null
  # Mutation should fail because catch-all is missing
  assert_exit 5 "$SXGATE" route add b.test.example a
}

test_backup_rotation() {
  write_populated_config
  "$SXGATE" service add a http://localhost:1 >/dev/null
  "$SXGATE" service add b http://localhost:2 >/dev/null
  # Force 7 mutations
  for i in 1 2 3 4 5 6 7; do
    "$SXGATE" route add "h$i.test.example" a >/dev/null
    sleep 1   # ensure unique timestamps (UTC, second-resolution)
  done
  count=$(ls -1 "$BACKUP_DIR"/config.yml.* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -le 5 ]; then ok "rotation keeps ≤5 backups (have $count)"; else fail "rotation keeps ≤5 backups" "have $count"; fi
}

test_setup_bootstraps() {
  # cert.pem present → ensure_login skipped; mock tunnel exists → no create needed.
  touch "$HOME/.cloudflared/cert.pem"
  "$SXGATE" setup >/dev/null 2>&1 || fail "setup runs" "setup exited nonzero"
  assert_file_exists "$CONFIG_FILE" "setup scaffolds config.yml"
  assert_file_contains "$CONFIG_FILE" "tunnel: mock-tunnel-id" "setup writes tunnel id"
  assert_file_contains "$CONFIG_FILE" "http_status:404" "setup writes catch-all"
  assert_file_exists "$SXGATE_CONF" "setup writes sxgate.conf"
  assert_file_exists "$SERVICES_FILE" "setup creates services file"
  assert_file_contains "$SXGATE_CONF" "MANAGED_ZONE=" "setup leaves zone empty (decoupled)"
  # Idempotent: second run preserves the config (+ backs it up)
  before=$(cat "$CONFIG_FILE")
  "$SXGATE" setup >/dev/null 2>&1
  after=$(cat "$CONFIG_FILE")
  assert_eq "$after" "$before" "second setup preserves config"
}

test_zone_set_and_show() {
  : > "$SXGATE_CONF"
  "$SXGATE" zone test.example >/dev/null
  assert_file_contains "$SXGATE_CONF" "MANAGED_ZONE=test.example" "zone persisted to conf"
  out=$("$SXGATE" zone)
  assert_contains "$out" "test.example" "zone (no arg) shows current zone"
  assert_exit 3 "$SXGATE" zone "not a domain"
}

test_init_zone_optional() {
  unset MANAGED_ZONE
  : > "$SXGATE_CONF"
  "$SXGATE" init >/dev/null 2>&1 || fail "init without zone" "init exited nonzero"
  assert_file_exists "$CONFIG_FILE" "init without zone scaffolds config"
  assert_file_exists "$SXGATE_CONF" "init without zone writes conf"
}

test_route_requires_zone() {
  unset MANAGED_ZONE
  : > "$SXGATE_CONF"
  write_empty_config
  "$SXGATE" service add blog http://localhost:2368 >/dev/null
  assert_exit 5 "$SXGATE" route add blog.test.example blog
}

test_ssh_service_and_route() {
  write_empty_config
  # ssh:// is now an accepted service scheme
  "$SXGATE" service add ssh ssh://localhost:22 >/dev/null \
    && ok "ssh:// service accepted" || fail "ssh:// service accepted" "rejected"
  assert_file_contains "$SERVICES_FILE" "ssh=ssh://localhost:22" "ssh service stored"
  # routing the ssh subdomain to it writes a normal ingress rule
  "$SXGATE" route add ssh.test.example ssh >/dev/null
  assert_file_contains "$CONFIG_FILE" "hostname: ssh.test.example" "ssh hostname written"
  assert_file_contains "$CONFIG_FILE" "service: ssh://localhost:22" "ssh service url written"
  tail_line=$(tail -n1 "$CONFIG_FILE")
  assert_contains "$tail_line" "http_status:404" "catch-all still last"
  # tcp:// stays rejected on purpose (ssh-only loosening)
  assert_exit 3 "$SXGATE" service add db tcp://localhost:5432
}

# ── preview tests ───────────────────────────────────────────────────────────────

# Create a throwaway git service repo at $TMP/svc with a .sxgate/preview.conf + a feat/x branch.
make_service_repo() {
  local mode=${1:-static_proxy} repo="$TMP/svc"
  mkdir -p "$repo/.sxgate"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  if [ "$mode" = proxy ]; then
    cat > "$repo/.sxgate/preview.conf" <<'EOF'
SERVICE="demo"
MODE="proxy"
RUN="/bin/true --port {port}"
EOF
  else
    cat > "$repo/.sxgate/preview.conf" <<'EOF'
SERVICE="demo"
BUILD="mkdir -p dist && echo hi > dist/index.html"
MODE="static_proxy"
ROOT="dist"
API_PREFIX="/api"
RUN="/bin/true serve --port {port}"
RUN_CWD="."
RUN_ENV="
FOO=bar
STATE_DIR={state}
"
SEED="echo invite=ABC123"
HEALTHCHECK="/api/health"
EOF
  fi
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  git -C "$repo" branch feat/x
  printf '%s' "$repo"
}

test_preview_setup() {
  write_empty_config
  "$SXGATE" preview setup >/dev/null 2>&1 || fail "preview setup runs" "nonzero exit"
  assert_file_exists "$PREVIEW_ETC/Caddyfile" "dispatcher Caddyfile written"
  assert_file_contains "$PREVIEW_ETC/Caddyfile" "import $PREVIEW_ETC/sites.d/*.caddy" "imports sites.d"
  assert_file_contains "$PREVIEW_ETC/Caddyfile" ":21490" "listens on dispatch port"
  assert_file_exists "$PREVIEW_LIBEXEC/preview-run" "launcher installed"
  assert_file_exists "$PREVIEW_SYSTEMD_DIR/sxgate-preview@.service" "instance template installed"
  assert_file_exists "$PREVIEW_SYSTEMD_DIR/sxgate-preview-proxy.service" "dispatcher unit installed"
  # Wildcard MUST be YAML-quoted (a bare leading * is a YAML alias → cloudflared rejects it).
  assert_file_contains "$CONFIG_FILE" 'hostname: "*.test.example"' "wildcard ingress added (quoted)"
  assert_file_not_contains "$CONFIG_FILE" 'hostname: *.test.example' "wildcard not emitted unquoted"
  tail_line=$(tail -n1 "$CONFIG_FILE"); assert_contains "$tail_line" "http_status:404" "catch-all still last"
  "$SXGATE" preview setup >/dev/null 2>&1
  count=$(grep -cF 'hostname: "*.test.example"' "$CONFIG_FILE")
  assert_eq "$count" "1" "wildcard ingress not duplicated (idempotent round-trip)"
}

test_preview_up_static_proxy() {
  local repo; repo=$(make_service_repo static_proxy)
  write_empty_config
  "$SXGATE" preview setup >/dev/null 2>&1
  "$SXGATE" preview up --repo "$repo" feat/x >/dev/null 2>&1 || fail "preview up runs" "nonzero exit"
  local slug=feat-x-demo
  assert_file_exists "$PREVIEW_ROOT/$slug/repo/dist/index.html" "BUILD produced static output in the worktree"
  assert_file_contains "$PREVIEW_ETC/sites.d/$slug.caddy" "http://$slug.test.example:21490" "vhost keyed by host:dispatch-port"
  assert_file_contains "$PREVIEW_ETC/sites.d/$slug.caddy" "reverse_proxy 127.0.0.1:8800" "api proxied to backend port"
  assert_file_contains "$PREVIEW_ETC/sites.d/$slug.caddy" "$PREVIEW_ROOT/$slug/repo/dist" "static root points into worktree"
  assert_file_contains "$PREVIEW_ETC/instances/$slug.env" "PORT=8800" "port recorded"
  assert_file_contains "$PREVIEW_ETC/instances/$slug.env" "--port 8800" "RUN expanded {port}"
  assert_file_contains "$PREVIEW_ETC/instances/$slug.env" "STATE_DIR=$PREVIEW_ROOT/$slug/state" "RUN_ENV expanded {state}"
  assert_file_contains "$PREVIEW_ETC/instances/$slug.meta" "BRANCH=feat/x" "meta records branch"
  out=$("$SXGATE" preview ls)
  assert_contains "$out" "$slug" "ls shows the slug"
  assert_contains "$out" "feat-x-demo.test.example" "ls shows the URL host"
}

test_preview_proxy_mode() {
  local repo; repo=$(make_service_repo proxy)
  write_empty_config
  "$SXGATE" preview setup >/dev/null 2>&1
  "$SXGATE" preview up --repo "$repo" feat/x >/dev/null 2>&1 || fail "proxy up runs" "nonzero exit"
  local slug=feat-x-demo
  assert_file_contains "$PREVIEW_ETC/sites.d/$slug.caddy" "reverse_proxy 127.0.0.1:8800" "proxy mode reverse-proxies"
  assert_file_not_contains "$PREVIEW_ETC/sites.d/$slug.caddy" "file_server" "proxy mode has no static server"
}

test_preview_up_requires_setup() {
  local repo; repo=$(make_service_repo proxy)
  write_empty_config
  assert_exit 5 "$SXGATE" preview up --repo "$repo" feat/x
}

test_preview_port_allocation() {
  local repo; repo=$(make_service_repo proxy)
  write_empty_config
  "$SXGATE" preview setup >/dev/null 2>&1
  "$SXGATE" preview up --repo "$repo" feat/x >/dev/null 2>&1
  git -C "$repo" branch feat/y
  "$SXGATE" preview up --repo "$repo" feat/y >/dev/null 2>&1
  local p1 p2
  p1=$(grep '^PORT=' "$PREVIEW_ETC/instances/feat-x-demo.env" | cut -d= -f2)
  p2=$(grep '^PORT=' "$PREVIEW_ETC/instances/feat-y-demo.env" | cut -d= -f2)
  [ "$p1" != "$p2" ] && ok "concurrent previews get distinct ports" || fail "distinct ports" "both got $p1"
}

test_preview_down() {
  local repo; repo=$(make_service_repo proxy)
  write_empty_config
  "$SXGATE" preview setup >/dev/null 2>&1
  "$SXGATE" preview up --repo "$repo" feat/x >/dev/null 2>&1
  local slug=feat-x-demo
  "$SXGATE" preview down "$slug" >/dev/null 2>&1 || fail "down runs" "nonzero exit"
  [ ! -e "$PREVIEW_ETC/sites.d/$slug.caddy" ] && ok "vhost drop-in removed" || fail "vhost removed" "still present"
  [ ! -e "$PREVIEW_ETC/instances/$slug.env" ] && ok "instance env removed" || fail "instance env removed" "present"
  [ ! -d "$PREVIEW_ROOT/$slug" ] && ok "worktree dir removed" || fail "worktree dir removed" "present"
}

# ── run all ───────────────────────────────────────────────────────────────────
TESTS=(
  test_help_and_version
  test_setup_bootstraps
  test_zone_set_and_show
  test_init_zone_optional
  test_route_requires_zone
  test_init_scaffolds_config
  test_init_preserves_existing_config
  test_service_crud
  test_service_validation
  test_ssh_service_and_route
  test_route_add_inserts_above_catchall
  test_route_idempotent_and_update
  test_route_rejects_out_of_zone
  test_route_rejects_missing_service
  test_route_rm
  test_route_ls_joins_services
  test_service_rm_blocked_by_routes
  test_route_ls_marks_unregistered
  test_validation_failure_rolls_back
  test_yaml_parser_rejects_missing_catchall
  test_backup_rotation
  test_preview_setup
  test_preview_up_static_proxy
  test_preview_proxy_mode
  test_preview_up_requires_setup
  test_preview_port_allocation
  test_preview_down
)

# Allow running a single test by name
if [ $# -gt 0 ]; then
  TESTS=("$@")
fi

for t in "${TESTS[@]}"; do
  run_test "$t"
done

printf '\n────────────────────────────\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailed:\n'
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
