# shellcheck shell=bash
# sxgate preview — per-branch sandbox previews for ANY sxgate-hosted service.
#
# A preview is a branch of a service repo, built + run in isolation and reachable at
# <feature>-<service>.<zone> (flat, one label → covered by the free *.<zone> cert).
# The tunnel is touched ONCE (a wildcard ingress → a local dispatcher Caddy); per-branch
# up/down only edit the dispatcher's drop-ins + systemd instances — never cloudflared/DNS.
#
# Each service repo describes how to build/run itself in `.sxgate/preview.conf`
# (a sourced shell fragment; placeholders {worktree} {state} {zone} {port} are expanded
# by the engine). Sandbox isolation (fake auth, throwaway data) is the service's own
# concern, expressed via RUN_ENV — the engine is service-agnostic.
#
# This file is sourced by the `sxgate` CLI and relies on its helpers: die, log, warn,
# confirm, with_lock, atomic_write, backup_config, yaml_split, yaml_emit,
# reload_cloudflared, validate_service_name, load_conf, needs_root.

# ── config (env-overridable, like the rest of sxgate) ───────────────────────────
: "${PREVIEW_ETC:=/etc/sxgate/preview}"          # Caddyfile + sites.d/ + instances/
: "${PREVIEW_ROOT:=/srv/sxgate-previews}"        # per-slug worktree + state
: "${PREVIEW_LIBEXEC:=/usr/local/lib/sxgate}"    # the per-instance launcher
: "${PREVIEW_SYSTEMD_DIR:=/etc/systemd/system}"  # where unit files land
: "${PREVIEW_DISPATCH_PORT:=21490}"              # the dispatcher Caddy listener (loopback)
: "${PREVIEW_PORT_LO:=8800}"                     # backend port pool
: "${PREVIEW_PORT_HI:=8899}"
: "${PREVIEW_USER:=sxgate-preview}"              # unprivileged owner of dispatcher + instances
: "${PREVIEW_CADDY:=caddy}"                      # caddy binary

# ── per-user isolation (DevLab) ─────────────────────────────────────────────────
# When PREVIEW_RUNAS is set, EVERY step that touches branch-authored bytes (reading the
# manifest, the worktree checkout, BUILD/HOOK/SEED, and the long-lived RUN service) executes
# ONLY as that Linux user via the pinned, path-confined PREVIEW_EXEC — never as root. Root keeps
# only branch-code-free wiring (ports, sites.d/instances/drop-in, daemon-reload). Unset ⇒ the
# engine behaves byte-for-byte as before (the operator's own previews are unaffected).
: "${PREVIEW_RUNAS:=}"   # target Linux user for untrusted steps (DevLab: the requesting user)
: "${PREVIEW_EXEC:=}"    # pinned confined executor reaching PREVIEW_RUNAS (DevLab: devlab-exec)
: "${PREVIEW_BASE:=}"    # user-owned base for worktree+state when PREVIEW_RUNAS set

# ── helpers ─────────────────────────────────────────────────────────────────────

# Branch + service → a single DNS label slug, e.g. "feat/profile" + "holistic"
#   → "feat-profile-holistic".
_pv_slug() {
  local b
  b=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')
  printf '%s-%s' "$b" "$2"
}

# Expand engine placeholders. $1=string $2=worktree $3=state $4=zone $5=port.
# Runtime values use {port} (NOT $PORT) so the manifest can be safely sourced.
_pv_expand() {
  local s=$1
  s=${s//\{worktree\}/$2}
  s=${s//\{state\}/$3}
  s=${s//\{zone\}/$4}
  s=${s//\{port\}/${5:-}}
  printf '%s' "$s"
}

# ── preview password gate ────────────────────────────────────────────────────────
# Every preview created with PREVIEW_PASSWORD set is protected by a simple passphrase of
# three random codewords (apple-tiger-moon), enforced at the dispatcher via Caddy basic_auth
# (bcrypt). The gate is rendered by root into the dispatcher vhost, so branch code can never
# read or remove it. The plaintext is stored root-owned (0640 root:$PREVIEW_PW_GROUP) so the
# operator — and DevLab, which shows it to the user to share — can retrieve it; the vhost holds
# only the bcrypt hash. External testers need no account: just the passphrase (user: preview).
: "${PREVIEW_PW_GROUP:=root}"   # group that may read the plaintext (.pw); DevLab sets it to 'devlab'

# Curated, unambiguous, family-friendly wordlist (no lookalikes like l/1/o/0). 128 words →
# 128^3 ≈ 2M combos; fronted by Cloudflare + slow bcrypt this is ample for a preview gate.
_PV_WORDS=(
  amber anchor apple arch arrow autumn bamboo basil beacon berry birch bison
  bloom brave breeze bright bronze brook cabin cactus canyon cedar cherry cloud
  clover cobalt comet copper coral cove crane crisp crystal dawn delta desert
  diamond dune eagle ember falcon fern flame flint forest fox garnet ginger
  glacier granite harbor hazel heron honey ivory jade jasmine juniper kayak koala
  lagoon lantern lark laurel lemon lily lotus lunar maple marble meadow mint
  mirror misty moss nectar nimbus north oak ocean olive onyx opal orbit
  otter pebble pepper pine plum polar prairie pumpkin quartz quill rapid raven
  reef ripple river robin rose ruby sage sable saffron sapphire shadow shell
  silver slate solar spark sphinx spruce storm summit sunny tango teal thistle
  tiger topaz tulip tundra umber velvet violet walnut willow zephyr zinc
)

# Emit three random words joined by '-'. Uses /dev/urandom (not $RANDOM) for real entropy.
_pv_gen_password() {
  local n=${#_PV_WORDS[@]} out=() i r
  for _ in 1 2 3; do
    r=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
    i=$(( r % n ))
    out+=("${_PV_WORDS[$i]}")
  done
  ( IFS='-'; printf '%s' "${out[*]}" )
}

# bcrypt-hash a passphrase with the caddy binary (for the dispatcher basic_auth block).
_pv_hash_password() {
  "$PREVIEW_CADDY" hash-password --algorithm bcrypt --plaintext "$1"
}

# Walk up from $1 (or $PWD) to find the repo holding .sxgate/preview.conf; print its root.
_pv_find_repo() {
  local d=${1:-$PWD}
  d=$(cd "$d" 2>/dev/null && pwd) || return 1
  while :; do
    [ -f "$d/.sxgate/preview.conf" ] && { printf '%s' "$d"; return 0; }
    [ "$d" = "/" ] && return 1
    d=$(dirname "$d")
  done
}

# Source a manifest in a subshell and emit `declare` lines for the known keys, so the
# caller imports ONLY those (top-level code in the manifest stays contained to the
# subshell). No `set -u`: a stray $var in a value expands empty instead of aborting.
_pv_read_manifest() {
  ( set -eo pipefail
    SERVICE='' BUILD='' MODE='static_proxy' ROOT='' API_PREFIX='/api' \
      RUN='' RUN_CWD='.' RUN_ENV='' SEED='' HEALTHCHECK='' HOOK=''
    # shellcheck disable=SC1090
    . "$1"
    declare -p SERVICE BUILD MODE ROOT API_PREFIX RUN RUN_CWD RUN_ENV SEED HEALTHCHECK HOOK
  )
}

# Untrusted step indirection: run the pinned confined executor AS the target user.
_pv_uexec() { sudo -n -u "$PREVIEW_RUNAS" "$PREVIEW_EXEC" "$@"; }

# The manifest key set the engine understands (the ONLY names ever imported).
_PV_KEYS=(SERVICE BUILD MODE ROOT API_PREFIX RUN RUN_CWD RUN_ENV SEED HEALTHCHECK HOOK)

# SAFE manifest read for the per-user path — the counterpart to _pv_read_manifest that NEVER
# lets branch bytes reach a root shell. The executor (as U) sources the manifest with its own
# output muted, then emits ONLY the known keys as NUL-delimited KEY=VALUE via a slash-pathed
# printf (immune to function shadowing). Here (root) we parse that stream as pure DATA — read
# -d '' with first-wins per key, NO eval — so a hostile manifest can neither run code at root nor
# inject extra keys. Populates the _PV_KEYS variables. Requires PREVIEW_RUNAS/PREVIEW_EXEC.
_pv_read_manifest_safe() {
  local mf=$1 k v rec seen=' '
  SERVICE='' BUILD='' MODE='static_proxy' ROOT='' API_PREFIX='/api' \
    RUN='' RUN_CWD='.' RUN_ENV='' SEED='' HEALTHCHECK='' HOOK=''
  while IFS= read -r -d '' rec; do
    k=${rec%%=*}; v=${rec#*=}
    case "$seen" in *" $k "*) continue ;; esac      # first-wins (defeats trailing/EXIT-trap records)
    case " ${_PV_KEYS[*]} " in *" $k "*) : ;; *) continue ;; esac  # known keys only
    printf -v "$k" '%s' "$v"                          # assign by fixed-name; value is inert data
    seen="$seen$k "
  done < <(_pv_uexec pv-manifest "$mf")
  [ -n "$SERVICE" ]
}

_pv_used_ports() { grep -hsoE '^PORT=[0-9]+' "$PREVIEW_ETC"/instances/*.env 2>/dev/null | cut -d= -f2; }

_pv_alloc_port() {
  local p used bound; used=$(_pv_used_ports)
  # review #3: also skip ports that are actually bound right now, so a pre-squatted port is never
  # handed to a new preview. (Does not close the restart-window squat — see the unix-socket follow-up.)
  bound=$(ss -ltnH 2>/dev/null | grep -oE '127.0.0.1:[0-9]+|\[::1\]:[0-9]+|0.0.0.0:[0-9]+|\*:[0-9]+' | grep -oE '[0-9]+$')
  for ((p = PREVIEW_PORT_LO; p <= PREVIEW_PORT_HI; p++)); do
    printf '%s\n' "$used" | grep -qx "$p" && continue
    printf '%s\n' "$bound" | grep -qx "$p" && continue
    printf '%s' "$p"; return 0
  done
  return 1
}

_pv_meta_get() { grep -m1 "^$2=" "$PREVIEW_ETC/instances/$1.meta" 2>/dev/null | cut -d= -f2-; }

# Resolve a user-given slug-or-branch to a concrete slug (unique branch match allowed).
_pv_resolve_slug() {
  local arg=$1 m hits=()
  [ -e "$PREVIEW_ETC/instances/$arg.meta" ] && { printf '%s' "$arg"; return 0; }
  for m in "$PREVIEW_ETC"/instances/*.meta; do
    [ -e "$m" ] || continue
    grep -qx "BRANCH=$arg" "$m" && hits+=("$(basename "${m%.meta}")")
  done
  [ "${#hits[@]}" -eq 1 ] && { printf '%s' "${hits[0]}"; return 0; }
  return 1
}

# An SPA shell must NEVER be cached. Its <script src> points at a content-hashed bundle, so a stale
# index.html pins the browser to a stale app — and iOS Safari will happily serve BOTH the shell and
# its bundle from disk without touching the network, so a preview can silently keep serving code
# from days ago while the tester swears they reloaded. (This cost a real debugging round on studiq.)
# Hashed build assets stay cacheable: their names change when their contents do.
#
# The matcher is deliberately project-agnostic: anything WITHOUT a file extension is a shell request
# (`/`, and every SPA deep link that try_files rewrites to index.html), plus *.html itself. Every
# build asset has an extension, so nothing that should be cached is caught by this.
# `$indent` is the leading tab depth, so this composes inside a `handle { … }` block too.
_pv_render_nocache() {
  local indent=$1
  printf '%s@spa_shell {\n%s\tnot path_regexp \\.[A-Za-z0-9]+$\n%s}\n' "$indent" "$indent" "$indent"
  printf '%sheader @spa_shell Cache-Control "no-store, must-revalidate"\n' "$indent"
  printf '%s@spa_html path *.html\n' "$indent"
  printf '%sheader @spa_html Cache-Control "no-store, must-revalidate"\n' "$indent"
}

# Render one dispatcher vhost: every preview listens on the dispatcher port and is keyed
# by Host; cloudflared forwards the original Host, so Caddy multiplexes by it.
_pv_render_vhost() {
  local host=$1 mode=$2 wt=$3 root=$4 api=$5 port=$6 pwhash=${7:-}
  printf 'http://%s:%s {\n\tbind 127.0.0.1 ::1\n' "$host" "$PREVIEW_DISPATCH_PORT"
  # Password gate (root-rendered; branch code can neither read nor drop it). Applies to the
  # whole site, so it protects both the static and the proxied handles below.
  if [ -n "$pwhash" ]; then
    printf '\tbasic_auth {\n\t\tpreview %s\n\t}\n' "$pwhash"
  fi
  case "$mode" in
    proxy)
      printf '\treverse_proxy 127.0.0.1:%s\n' "$port" ;;
    static)
      _pv_render_nocache $'\t'
      printf '\troot * %s/%s\n\ttry_files {path} /index.html\n\tfile_server\n' "$wt" "$root" ;;
    static_proxy | *)
      printf '\thandle %s/* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$api" "$port"
      printf '\thandle {\n'
      _pv_render_nocache $'\t\t'
      printf '\t\troot * %s/%s\n\t\ttry_files {path} /index.html\n\t\tfile_server\n\t}\n' "$wt" "$root" ;;
  esac
  printf '}\n'
}

_pv_reload_dispatcher() {
  if command -v "$PREVIEW_CADDY" >/dev/null 2>&1; then
    "$PREVIEW_CADDY" validate --config "$PREVIEW_ETC/Caddyfile" --adapter caddyfile >/dev/null 2>&1 \
      || die "preview Caddyfile invalid; not reloading dispatcher" 4
  fi
  command -v systemctl >/dev/null 2>&1 && {
    systemctl reload sxgate-preview-proxy 2>/dev/null \
      || systemctl restart sxgate-preview-proxy 2>/dev/null \
      || warn "could not reload the preview dispatcher (sxgate-preview-proxy)"
  }
  return 0
}

# ── setup (one-time) ────────────────────────────────────────────────────────────
_pv_ensure_user() {
  [ "$(id -u)" -eq 0 ] || return 0
  command -v useradd >/dev/null 2>&1 || return 0
  id "$PREVIEW_USER" >/dev/null 2>&1 && return 0
  useradd --system --no-create-home --shell /usr/sbin/nologin "$PREVIEW_USER" 2>/dev/null \
    || warn "could not create system user '$PREVIEW_USER'"
}

_pv_write_launcher() {
  mkdir -p "$PREVIEW_LIBEXEC"
  cat > "$PREVIEW_LIBEXEC/preview-run" <<'EOF'
#!/usr/bin/env bash
# sxgate preview launcher — runs one preview instance's backend.
# systemd passes the slug as $1; the per-instance EnvironmentFile provides
# SXGATE_PV_CWD, SXGATE_PV_RUN and the manifest's run-env.
set -euo pipefail
cd "${SXGATE_PV_CWD:?missing SXGATE_PV_CWD}"
exec bash -c "${SXGATE_PV_RUN:?missing SXGATE_PV_RUN}"
EOF
  chmod 0755 "$PREVIEW_LIBEXEC/preview-run"
}

_pv_write_base_caddy() {
  mkdir -p "$PREVIEW_ETC/sites.d"
  cat > "$PREVIEW_ETC/Caddyfile" <<EOF
# sxgate preview dispatcher — plain HTTP on loopback; TLS terminates at the Cloudflare edge.
# Managed by 'sxgate preview'. One vhost per live sandbox lives in sites.d/.
{
	auto_https off
	admin off
}

http://:$PREVIEW_DISPATCH_PORT {
	bind 127.0.0.1 ::1
	respond "sxgate preview: no sandbox for this host" 404
}

import $PREVIEW_ETC/sites.d/*.caddy
EOF
}

_pv_write_units() {
  local caddy_bin; caddy_bin=$(command -v "$PREVIEW_CADDY" || echo /usr/bin/caddy)
  mkdir -p "$PREVIEW_SYSTEMD_DIR"
  cat > "$PREVIEW_SYSTEMD_DIR/sxgate-preview-proxy.service" <<EOF
[Unit]
Description=sxgate preview dispatcher (Caddy)
After=network.target

[Service]
ExecStart=$caddy_bin run --config $PREVIEW_ETC/Caddyfile --adapter caddyfile
ExecReload=$caddy_bin reload --config $PREVIEW_ETC/Caddyfile --adapter caddyfile --force
Restart=on-failure
RestartSec=2
User=$PREVIEW_USER
Group=$PREVIEW_USER

[Install]
WantedBy=multi-user.target
EOF
  cat > "$PREVIEW_SYSTEMD_DIR/sxgate-preview@.service" <<EOF
[Unit]
Description=sxgate preview instance %i
After=network.target

[Service]
EnvironmentFile=$PREVIEW_ETC/instances/%i.env
ExecStart=$PREVIEW_LIBEXEC/preview-run %i
Restart=on-failure
RestartSec=2
User=$PREVIEW_USER
Group=$PREVIEW_USER

[Install]
WantedBy=multi-user.target
EOF
}

# Add the wildcard ingress (`*.<zone>` → dispatcher) ONCE, as the last rule before the
# catch-all (first match wins, so specific service routes keep precedence). This is the
# only sanctioned wildcard in config.yml — route_add still forbids it.
_pv_ensure_wildcard() {
  [ -e "$CONFIG_FILE" ] || die "cloudflared config not found ($CONFIG_FILE) — run 'sxgate setup' first" 5
  local host="*.$MANAGED_ZONE" url="http://localhost:$PREVIEW_DISPATCH_PORT" d
  d=$(mktemp -d)
  yaml_split "$d" < "$CONFIG_FILE"
  if awk -F'\t' -v h="$host" '$1==h{f=1} END{exit !f}' "$d/tuples"; then
    log "wildcard ingress already present ($host → $url)"
    rm -rf "$d"; return 0
  fi
  printf '%s\t%s\n' "$host" "$url" >> "$d/tuples"
  local backup; backup=$(backup_config || true)
  yaml_emit "$d" | atomic_write "$CONFIG_FILE"
  rm -rf "$d"
  if command -v cloudflared >/dev/null 2>&1 && ! cloudflared tunnel ingress validate "$CONFIG_FILE" >/dev/null 2>&1; then
    [ -n "${backup:-}" ] && { atomic_write "$CONFIG_FILE" < "$backup"; die "cloudflared rejected the wildcard ingress; rolled back" 4; }
    die "cloudflared rejected the wildcard ingress" 4
  fi
  reload_cloudflared reload 2>/dev/null || warn "reload cloudflared manually (systemctl reload cloudflared)"
  log "wildcard ingress added: $host → $url"
}

_pv_cmd_setup() {
  load_conf
  [ -n "${MANAGED_ZONE:-}" ] || die "no zone set — run 'sxgate zone <domain>' first" 5
  with_lock _pv_setup_locked
}
_pv_setup_locked() {
  mkdir -p "$PREVIEW_ETC/sites.d" "$PREVIEW_ETC/instances" "$PREVIEW_ROOT" "$PREVIEW_LIBEXEC"
  _pv_ensure_user
  _pv_write_launcher
  _pv_write_base_caddy
  _pv_write_units
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now sxgate-preview-proxy >/dev/null 2>&1 || warn "could not start sxgate-preview-proxy"
  fi
  _pv_ensure_wildcard
  log ""
  log "preview routing ready. One manual step remains (cloudflared can't create wildcard DNS):"
  log "  Cloudflare dashboard → DNS → add a *proxied* record:"
  log "    Type CNAME   Name *   Target <tunnel-id>.cfargotunnel.com   (zone: $MANAGED_ZONE)"
  log ""
  log "Then, from a repo containing .sxgate/preview.conf:"
  log "  sudo sxgate preview up <branch>"
}

# ── up ──────────────────────────────────────────────────────────────────────────
_pv_rollback() {
  local slug=$1 repo=$2
  [ -n "$repo" ] && [ -d "$PREVIEW_ROOT/$slug/repo" ] \
    && git -C "$repo" worktree remove --force "$PREVIEW_ROOT/$slug/repo" 2>/dev/null || true
  rm -rf "${PREVIEW_ROOT:?}/$slug" 2>/dev/null || true
  rm -f "$PREVIEW_ETC/sites.d/$slug.caddy" "$PREVIEW_ETC/instances/$slug.env" "$PREVIEW_ETC/instances/$slug.meta" "$PREVIEW_ETC/instances/$slug.pw" 2>/dev/null || true
}

_pv_chown() {
  [ "$(id -u)" -eq 0 ] && id "$PREVIEW_USER" >/dev/null 2>&1 \
    && chown -R "$PREVIEW_USER:$PREVIEW_USER" "$PREVIEW_ROOT/$1" 2>/dev/null
  return 0
}

# Validate the per-user execution identity BEFORE any sudo -u. No-op unless PREVIEW_RUNAS is set.
_pv_validate_runas() {
  [ -n "$PREVIEW_RUNAS" ] || return 0
  [[ "$PREVIEW_RUNAS" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid --as-user '$PREVIEW_RUNAS'" 2
  id -u "$PREVIEW_RUNAS" >/dev/null 2>&1 || die "no such user: $PREVIEW_RUNAS" 2
  local groups; groups=$(id -nG "$PREVIEW_RUNAS" 2>/dev/null | tr ' ' '\n')
  printf '%s\n' "$groups" | grep -qxE 'hp_devlab_access|sudo' \
    || die "$PREVIEW_RUNAS is not preview-eligible (needs hp_devlab_access)" 77
  # fix #2: refuse to run untrusted code as a user who carries a privileged read group — gid
  # devlab/holistic would let the long-lived RUN read every workspace + the AES link-key.
  printf '%s\n' "$groups" | grep -qxE 'devlab|holistic' \
    && die "$PREVIEW_RUNAS is in a privileged group (devlab/holistic) — refusing" 77
  [ -n "$PREVIEW_EXEC" ] && [ -x "$PREVIEW_EXEC" ] || die "--exec <executor> required (+executable) with --as-user" 2
  [ -n "$PREVIEW_BASE" ] || die "--base <dir> required with --as-user" 2
}

_pv_cmd_up() {
  local repo='' from='' branch=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --from) from=$2; shift 2 ;;
      --as-user) PREVIEW_RUNAS=$2; shift 2 ;;
      --exec) PREVIEW_EXEC=$2; shift 2 ;;
      --base) PREVIEW_BASE=$2; shift 2 ;;
      -h | --help) _pv_usage; return 0 ;;
      -*) die "unknown flag: $1" 2 ;;
      *) [ -z "$branch" ] && branch=$1 || die "unexpected argument: $1" 2; shift ;;
    esac
  done
  [ -n "$branch" ] || die "usage: sxgate preview up [--repo <path>] [--from <base>] <branch>" 2
  load_conf
  [ -n "${MANAGED_ZONE:-}" ] || die "no zone set — run 'sxgate zone <domain>' first" 5
  [ -f "$PREVIEW_ETC/Caddyfile" ] || die "preview not set up — run 'sxgate preview setup' first" 5
  _pv_validate_runas
  local repo_root
  if [ -n "$PREVIEW_RUNAS" ]; then
    # The repo is the user's own workspace — never walk/stat the tree as root. Trust the caller's
    # --repo (devlab-preview derives it from the session user) and require the manifest present.
    [ -n "$repo" ] || die "--repo is required with --as-user" 2
    repo_root=$repo
    [ -f "$repo_root/.sxgate/preview.conf" ] || die "no .sxgate/preview.conf in $repo_root" 5
  else
    repo_root=$(_pv_find_repo "${repo:-$PWD}") || die "no .sxgate/preview.conf found in ${repo:-$PWD} or its parents" 5
  fi
  with_lock _pv_up_locked "$repo_root" "$branch" "$from"
}

# RUNAS-aware rollback: in the per-user path everything is undone AS the user via the executor.
_pv_rollback_any() {
  if [ -n "$PREVIEW_RUNAS" ]; then
    local slug=$1 repo=$2
    [ -n "$repo" ] && _pv_uexec pv-worktree-remove "$repo" "$PREVIEW_BASE/$slug/repo" >/dev/null 2>&1 || true
    _pv_uexec pv-rm "$PREVIEW_BASE/$slug" >/dev/null 2>&1 || true
    rm -f "$PREVIEW_ETC/sites.d/$slug.caddy" "$PREVIEW_ETC/instances/$slug".{env,meta,pw} 2>/dev/null || true
    rm -rf "$PREVIEW_SYSTEMD_DIR/sxgate-preview@$slug.service.d" 2>/dev/null || true
  else
    _pv_rollback "$@"
  fi
}

# Per-slug systemd drop-in: run the untrusted RUN backend AS the user (never root, never group
# devlab), sandboxed to its own preview dir. Overrides the template's User=$PREVIEW_USER.
_pv_write_dropin() {
  local slug=$1 d="$PREVIEW_SYSTEMD_DIR/sxgate-preview@$slug.service.d"
  mkdir -p "$d"
  cat > "$d/runas.conf" <<EOF
[Service]
User=$PREVIEW_RUNAS
Group=$PREVIEW_RUNAS
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=tmpfs
ReadWritePaths=$PREVIEW_BASE/$slug
InaccessiblePaths=-/var/lib/devlab/links -/etc/devlab
# review #6: bound a runaway/fork-bombing RUN on the shared host.
MemoryMax=768M
CPUQuota=100%
TasksMax=256
EOF
}

_pv_up_locked() {
  local repo_root=$1 branch=$2 from=$3
  local mf="$repo_root/.sxgate/preview.conf"
  if [ -n "$PREVIEW_RUNAS" ]; then
    _pv_read_manifest_safe "$mf" || die "could not read manifest $mf (missing SERVICE?)" 5   # fix #1: no root eval
  else
    eval "$(_pv_read_manifest "$mf")" || die "could not read manifest $mf" 5
    [ -n "$SERVICE" ] || die "manifest $mf is missing SERVICE" 3
  fi
  validate_service_name "$SERVICE"
  : "${MODE:=static_proxy}" "${API_PREFIX:=/api}" "${RUN_CWD:=.}"

  local slug host wt state
  slug=$(_pv_slug "$branch" "$SERVICE")
  [ -n "$PREVIEW_RUNAS" ] && slug="$PREVIEW_RUNAS-$slug"          # fix #3: namespace per user
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,61}$ ]] || die "computed slug '$slug' is not a valid DNS label" 3
  host="$slug.$MANAGED_ZONE"
  if [ -n "$PREVIEW_RUNAS" ]; then
    wt="$PREVIEW_BASE/$slug/repo"; state="$PREVIEW_BASE/$slug/state"
  else
    wt="$PREVIEW_ROOT/$slug/repo"; state="$PREVIEW_ROOT/$slug/state"
  fi
  [ -e "$PREVIEW_ETC/instances/$slug.meta" ] && die "preview '$slug' already exists — use 'sxgate preview rebuild $branch' or 'down' first" 3

  local port; port=$(_pv_alloc_port) || die "no free preview port in $PREVIEW_PORT_LO-$PREVIEW_PORT_HI" 1

  # 1. isolated worktree
  if [ -n "$PREVIEW_RUNAS" ]; then
    # Detached checkout of the committed branch SHA, AS the user (their own repo → git's
    # dubious-ownership guard never fires, and root never touches the user's .git).
    _pv_uexec pv-worktree-add "$repo_root" "$wt" "$branch" \
      || { _pv_rollback_any "$slug" "$repo_root"; die "worktree add failed for '$branch'" 1; }
  else
    mkdir -p "$PREVIEW_ROOT/$slug"
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repo_root" worktree add "$wt" "$branch" >/dev/null 2>&1 \
        || { _pv_rollback "$slug" "$repo_root"; die "git worktree add failed for branch '$branch' (already checked out?)" 1; }
    else
      git -C "$repo_root" worktree add -b "$branch" "$wt" "${from:-HEAD}" >/dev/null 2>&1 \
        || { _pv_rollback "$slug" "$repo_root"; die "git worktree add -b '$branch' from '${from:-HEAD}' failed" 1; }
    fi
  fi

  # 2. build (manifest BUILD or HOOK). Root only EXPANDS placeholders (pure substitution, no eval);
  # the untrusted command runs as the user via the executor (DEVLAB_PV_CMD env, never argv).
  if [ -n "$PREVIEW_RUNAS" ]; then
    _pv_uexec pv-mkdir "$state" || { _pv_rollback_any "$slug" "$repo_root"; die "could not create state dir" 1; }
    if [ -n "${HOOK:-}" ]; then
      DEVLAB_PV_CMD="PORT=$port bash $wt/$HOOK build $wt $state" _pv_uexec pv-build "$wt" \
        || { _pv_rollback_any "$slug" "$repo_root"; die "hook build failed" 1; }
    elif [ -n "${BUILD:-}" ]; then
      DEVLAB_PV_CMD="$(_pv_expand "$BUILD" "$wt" "$state" "$MANAGED_ZONE" "$port")" _pv_uexec pv-build "$wt" \
        || { _pv_rollback_any "$slug" "$repo_root"; die "build failed" 1; }
    fi
  else
    mkdir -p "$state"
    if [ -n "${HOOK:-}" ]; then
      ( cd "$wt" && PORT="$port" bash "$wt/$HOOK" build "$wt" "$state" ) \
        || { _pv_rollback "$slug" "$repo_root"; die "hook build failed" 1; }
    elif [ -n "${BUILD:-}" ]; then
      ( cd "$wt" && bash -c "$(_pv_expand "$BUILD" "$wt" "$state" "$MANAGED_ZONE" "$port")" ) \
        || { _pv_rollback "$slug" "$repo_root"; die "build failed" 1; }
    fi
  fi

  # 3. seed (optional) — stdout shown to the user as notes
  local notes=''
  if [ -n "${SEED:-}" ]; then
    if [ -n "$PREVIEW_RUNAS" ]; then
      notes=$(DEVLAB_PV_CMD="$(_pv_expand "$SEED" "$wt" "$state" "$MANAGED_ZONE" "$port")" _pv_uexec pv-build "$wt") \
        || warn "seed command failed"
    else
      notes=$( cd "$wt" && PORT="$port" bash -c "$(_pv_expand "$SEED" "$wt" "$state" "$MANAGED_ZONE" "$port")" ) \
        || warn "seed command failed"
    fi
  fi
  [ -z "$PREVIEW_RUNAS" ] && _pv_chown "$slug"

  # 3a. pure-static manifest under RUNAS → synthesize a user-owned static server (the shared
  # dispatcher can't read the user's worktree, so it must be served by the user's own process).
  if [ -n "$PREVIEW_RUNAS" ] && [ -z "${RUN:-}" ] && [ -z "${HOOK:-}" ]; then
    RUN="python3 -m http.server {port} --bind 127.0.0.1 --directory {worktree}/${ROOT:-.}"
  fi

  # 3b. password gate (DevLab forces PREVIEW_PASSWORD=1; legacy CLI opt-in). The hash goes into the
  # root-owned vhost; the plaintext is stored root-owned for retrieval/sharing.
  local pwhash='' pw='' pwfile="$PREVIEW_ETC/instances/$slug.pw"
  if [ -n "${PREVIEW_PASSWORD:-}" ]; then
    pw=$(_pv_gen_password)
    pwhash=$(_pv_hash_password "$pw") || { _pv_rollback_any "$slug" "$repo_root"; die "could not hash preview password (caddy hash-password failed)" 4; }
    ( umask 077; printf '%s\n' "$pw" > "$pwfile" )
    chgrp "$PREVIEW_PW_GROUP" "$pwfile" 2>/dev/null && chmod 0640 "$pwfile" 2>/dev/null || true
  fi

  # 4. dispatcher vhost. Under RUNAS force proxy mode (dispatcher can't read the user tree).
  local eff_mode="$MODE"
  [ -n "$PREVIEW_RUNAS" ] && eff_mode=proxy
  _pv_render_vhost "$host" "$eff_mode" "$wt" "${ROOT:-}" "$API_PREFIX" "$port" "$pwhash" \
    | atomic_write "$PREVIEW_ETC/sites.d/$slug.caddy"

  # 5. backend instance (if the service has one — always, under RUNAS, from step 3a)
  if [ -n "${RUN:-}" ] || [ -n "${HOOK:-}" ]; then
    local run runcwd
    if [ -n "${HOOK:-}" ]; then
      run="bash $wt/$HOOK serve $wt $port $state"
    else
      run=$(_pv_expand "$RUN" "$wt" "$state" "$MANAGED_ZONE" "$port")
    fi
    runcwd=$(_pv_expand "$RUN_CWD" "$wt" "$state" "$MANAGED_ZONE" "$port")
    case "$runcwd" in /*) ;; *) runcwd="$wt/$runcwd" ;; esac
    _pv_write_instance_env "$slug" "$port" "$runcwd" "$run" "$wt" "$state"
    [ -n "$PREVIEW_RUNAS" ] && _pv_write_dropin "$slug"     # fix #2: run RUN as the user, sandboxed
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload 2>/dev/null || true
      systemctl enable --now "sxgate-preview@$slug" >/dev/null 2>&1 || warn "could not start sxgate-preview@$slug"
    fi
  fi

  # 6. publish + record
  _pv_reload_dispatcher
  _pv_write_meta "$slug" "$branch" "$SERVICE" "$repo_root" "$port" "$host" "$MODE"
  [ -z "$PREVIEW_RUNAS" ] && _pv_chown "$slug"

  log "preview up: https://$host"
  log "  slug=$slug  branch=$branch  service=$SERVICE  port=$port  mode=$eff_mode"
  [ -n "$pw" ] && log "  password: $pw   (login user: preview)"
  if [ -n "$notes" ]; then
    log "  ── notes ──"
    printf '%s\n' "$notes" | sed 's/^/  /'
  fi
}

_pv_write_instance_env() {
  local slug=$1 port=$2 cwd=$3 run=$4 wt=$5 state=$6
  {
    printf 'PORT=%s\n' "$port"
    printf 'SXGATE_PV_CWD=%s\n' "$cwd"
    printf 'SXGATE_PV_RUN=%s\n' "$run"
    if [ -n "${RUN_ENV:-}" ]; then
      while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        printf '%s\n' "$(_pv_expand "$line" "$wt" "$state" "$MANAGED_ZONE" "$port")"
      done <<< "$RUN_ENV"
    fi
  } | atomic_write "$PREVIEW_ETC/instances/$slug.env"
  # fix #6: the env can carry RUN_ENV values — keep it out of world-read. systemd reads it as
  # root before dropping to User=, so it need not be user-readable.
  [ -n "$PREVIEW_RUNAS" ] && chmod 0640 "$PREVIEW_ETC/instances/$slug.env" 2>/dev/null
}

_pv_write_meta() {
  {
    printf 'SLUG=%s\n' "$1"
    printf 'BRANCH=%s\n' "$2"
    printf 'SERVICE=%s\n' "$3"
    printf 'REPO=%s\n' "$4"
    printf 'PORT=%s\n' "$5"
    printf 'HOST=%s\n' "$6"
    printf 'MODE=%s\n' "$7"
    # Root-written ownership record — the authoritative guard for down/rebuild (a user can't forge
    # it; instances/ is root-only). Present only for per-user previews.
    [ -n "$PREVIEW_RUNAS" ] && printf 'OWNER=%s\n' "$PREVIEW_RUNAS"
  } | atomic_write "$PREVIEW_ETC/instances/$1.meta"
  # review #9: don't leak every user's OWNER/PORT/REPO/BRANCH world-readably. devlabd reads it via
  # group devlab.
  [ -n "$PREVIEW_RUNAS" ] && { chgrp devlab "$PREVIEW_ETC/instances/$1.meta" 2>/dev/null; chmod 0640 "$PREVIEW_ETC/instances/$1.meta" 2>/dev/null; }
}

# ── rebuild / down / ls ───────────────────────────────────────────────────────
_pv_cmd_rebuild() {
  local arg=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --as-user | --exec | --base) die "rebuild does not support per-user mode — use down + up" 2 ;;
      -*) die "unknown flag: $1" 2 ;;
      *) [ -z "$arg" ] && arg=$1 || die "unexpected argument: $1" 2; shift ;;
    esac
  done
  [ -n "$arg" ] || die "usage: sxgate preview rebuild <slug|branch>" 2
  load_conf
  local slug; slug=$(_pv_resolve_slug "$arg") || die "no preview matching '$arg'" 3
  with_lock _pv_rebuild_locked "$slug"
}
_pv_rebuild_locked() {
  local slug=$1 repo wt state
  # A per-user preview's repo/manifest is user-owned; rebuilding it via the root CLI would
  # root-eval / root-git untrusted code. Refuse — those are rebuilt as the owner (down+up).
  [ -n "$(_pv_meta_get "$slug" OWNER)" ] && die "'$slug' is a per-user (DevLab) preview — rebuild it there, not via the operator CLI" 3
  repo=$(_pv_meta_get "$slug" REPO); wt="$PREVIEW_ROOT/$slug/repo"; state="$PREVIEW_ROOT/$slug/state"
  [ -d "$wt" ] || die "worktree missing for '$slug'" 5
  git -C "$wt" pull --ff-only >/dev/null 2>&1 || warn "git pull skipped (no upstream / local branch) — rebuilding current worktree"
  local port; port=$(_pv_meta_get "$slug" PORT)
  eval "$(_pv_read_manifest "$repo/.sxgate/preview.conf")" || die "could not read manifest" 5
  if [ -n "${HOOK:-}" ]; then
    ( cd "$wt" && PORT="$port" bash "$wt/$HOOK" build "$wt" "$state" ) || die "hook build failed" 1
  elif [ -n "${BUILD:-}" ]; then
    ( cd "$wt" && bash -c "$(_pv_expand "$BUILD" "$wt" "$state" "$MANAGED_ZONE" "$port")" ) || die "build failed" 1
  fi
  _pv_chown "$slug"
  command -v systemctl >/dev/null 2>&1 && systemctl restart "sxgate-preview@$slug" >/dev/null 2>&1
  _pv_reload_dispatcher
  log "preview rebuilt: $slug"
}

# Under RUNAS, a user may only touch their OWN previews: the slug must be <user>-prefixed AND the
# root-written OWNER= meta must match. (No-op for the legacy operator path.)
_pv_assert_owner() {
  [ -n "$PREVIEW_RUNAS" ] || return 0
  case "$1" in "$PREVIEW_RUNAS"-*) : ;; *) die "not your preview: $1" 77 ;; esac
  [ "$(_pv_meta_get "$1" OWNER)" = "$PREVIEW_RUNAS" ] || die "owner mismatch for preview '$1'" 77
}

_pv_cmd_down() {
  local arg=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --as-user) PREVIEW_RUNAS=$2; shift 2 ;;
      --exec) PREVIEW_EXEC=$2; shift 2 ;;
      --base) PREVIEW_BASE=$2; shift 2 ;;
      --yes) SXGATE_YES=1; shift ;;
      -*) die "unknown flag: $1" 2 ;;
      *) [ -z "$arg" ] && arg=$1 || die "unexpected argument: $1" 2; shift ;;
    esac
  done
  [ -n "$arg" ] || die "usage: sxgate preview down [--as-user U] <slug|branch>" 2
  load_conf
  _pv_validate_runas
  local slug; slug=$(_pv_resolve_slug "$arg") || die "no preview matching '$arg'" 3
  # A per-user preview must be torn down AS its owner (never root-touch the user's repo). Refuse
  # the legacy path for owned previews unless the owner is supplied.
  if [ -z "$PREVIEW_RUNAS" ] && [ -n "$(_pv_meta_get "$slug" OWNER)" ]; then
    die "'$slug' is a per-user (DevLab) preview — remove it there (or pass --as-user <owner>)" 3
  fi
  _pv_assert_owner "$slug"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,61}$ ]] || die "invalid slug '$slug'" 3   # fix #3: no traversal
  confirm "remove preview '$slug' (worktree, instance, route)?" || die "aborted" 10
  with_lock _pv_down_locked "$slug"
}
_pv_down_locked() {
  local slug=$1 repo wt
  repo=$(_pv_meta_get "$slug" REPO)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "sxgate-preview@$slug" >/dev/null 2>&1
    systemctl reset-failed "sxgate-preview@$slug" >/dev/null 2>&1 || true   # review #10: no leftover failed units
  fi
  rm -f "$PREVIEW_ETC/sites.d/$slug.caddy" "$PREVIEW_ETC/instances/$slug.env" "$PREVIEW_ETC/instances/$slug.meta" "$PREVIEW_ETC/instances/$slug.pw"
  if [ -n "$PREVIEW_RUNAS" ]; then
    rm -rf "$PREVIEW_SYSTEMD_DIR/sxgate-preview@$slug.service.d"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
    _pv_reload_dispatcher
    wt="$PREVIEW_BASE/$slug/repo"
    [ -n "$repo" ] && _pv_uexec pv-worktree-remove "$repo" "$wt" >/dev/null 2>&1 || true
    _pv_uexec pv-rm "$PREVIEW_BASE/$slug" >/dev/null 2>&1 || true
  else
    _pv_reload_dispatcher
    wt="$PREVIEW_ROOT/$slug/repo"
    [ -n "$repo" ] && [ -d "$wt" ] && git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "${PREVIEW_ROOT:?}/$slug"
  fi
  log "preview down: $slug"
}

_pv_cmd_ls() {
  local m slug any=0 lock
  printf '%-30s %-18s %-6s %-6s %s\n' SLUG BRANCH PORT AUTH URL
  for m in "$PREVIEW_ETC"/instances/*.meta; do
    [ -e "$m" ] || continue
    any=1; slug=$(basename "${m%.meta}")
    lock=$([ -f "$PREVIEW_ETC/instances/$slug.pw" ] && echo 'pw' || echo '-')
    printf '%-30s %-18s %-6s %-6s https://%s\n' \
      "$slug" "$(_pv_meta_get "$slug" BRANCH)" "$(_pv_meta_get "$slug" PORT)" "$lock" "$(_pv_meta_get "$slug" HOST)"
  done
  [ "$any" = 0 ] && log "(no previews)"
  return 0
}

# Print a preview's passphrase (root-only; the .pw file is root-owned). Also useful to DevLab,
# which reads the file directly via its group.
_pv_cmd_pw() {
  local arg=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --as-user) PREVIEW_RUNAS=$2; shift 2 ;;
      --exec | --base) shift 2 ;;   # accepted for symmetry; unused by pw
      -*) die "unknown flag: $1" 2 ;;
      *) [ -z "$arg" ] && arg=$1 || die "unexpected argument: $1" 2; shift ;;
    esac
  done
  [ -n "$arg" ] || die "usage: sxgate preview pw [--as-user U] <slug|branch>" 2
  load_conf
  local slug; slug=$(_pv_resolve_slug "$arg") || die "no preview matching '$arg'" 3
  _pv_assert_owner "$slug"   # review #8: authoritative OWNER check (not just a slug-prefix match)
  local f="$PREVIEW_ETC/instances/$slug.pw"
  [ -f "$f" ] || die "preview '$slug' has no password set" 3
  cat "$f"
}

# ── teardown (called by top-level `sxgate teardown`) ──────────────────────────────
# The preview subsystem owns artifacts OUTSIDE /etc/sxgate (systemd units, the libexec
# launcher, the worktree root, a system user). Only this file knows those paths, so the
# removal lives here (single source of truth) and the core teardown just calls it.

# Emit one human line per preview artifact that currently exists (for `--dry-run`).
_pv_teardown_plan() {
  local m
  for m in "$PREVIEW_ETC"/instances/*.meta; do
    [ -e "$m" ] || continue
    printf '  systemd unit  sxgate-preview@%s\n' "$(basename "${m%.meta}")"
  done
  [ -e "$PREVIEW_SYSTEMD_DIR/sxgate-preview-proxy.service" ] && printf '  systemd unit  sxgate-preview-proxy\n'
  [ -e "$PREVIEW_SYSTEMD_DIR/sxgate-preview@.service" ]      && printf '  systemd unit  sxgate-preview@ (template)\n'
  [ -d "$PREVIEW_ETC" ]                 && printf '  dir           %s\n' "$PREVIEW_ETC"
  [ -d "$PREVIEW_ROOT" ]                && printf '  dir           %s  (worktrees + build state)\n' "$PREVIEW_ROOT"
  [ -e "$PREVIEW_LIBEXEC/preview-run" ] && printf '  file          %s\n' "$PREVIEW_LIBEXEC/preview-run"
  if [ "$(id -u)" -eq 0 ] && id "$PREVIEW_USER" >/dev/null 2>&1; then
    printf '  system user   %s\n' "$PREVIEW_USER"
  fi
  return 0
}

# Actually remove every preview artifact. Idempotent + best-effort (never aborts teardown).
_pv_teardown() {
  local m slug have_systemd=0
  command -v systemctl >/dev/null 2>&1 && have_systemd=1
  # Stop + disable each live instance, then the dispatcher.
  for m in "$PREVIEW_ETC"/instances/*.meta; do
    [ -e "$m" ] || continue
    slug=$(basename "${m%.meta}")
    [ "$have_systemd" = 1 ] && systemctl disable --now "sxgate-preview@$slug" >/dev/null 2>&1 || true
  done
  [ "$have_systemd" = 1 ] && systemctl disable --now sxgate-preview-proxy >/dev/null 2>&1 || true
  # Remove the unit files, then reload the manager.
  rm -f "$PREVIEW_SYSTEMD_DIR/sxgate-preview-proxy.service" \
        "$PREVIEW_SYSTEMD_DIR/sxgate-preview@.service" 2>/dev/null || true
  [ "$have_systemd" = 1 ] && systemctl daemon-reload >/dev/null 2>&1 || true
  # Remove on-disk state (dirs guarded with :? so an unset var can never rm -rf /).
  rm -rf "${PREVIEW_ETC:?}" "${PREVIEW_ROOT:?}" 2>/dev/null || true
  rm -f "$PREVIEW_LIBEXEC/preview-run" 2>/dev/null || true
  rmdir "$PREVIEW_LIBEXEC" 2>/dev/null || true   # only if now empty
  # Drop the unprivileged system user (root only; best-effort).
  if [ "$(id -u)" -eq 0 ] && command -v userdel >/dev/null 2>&1 && id "$PREVIEW_USER" >/dev/null 2>&1; then
    userdel "$PREVIEW_USER" >/dev/null 2>&1 || warn "could not remove system user '$PREVIEW_USER'"
  fi
  return 0
}

# ── dispatch ────────────────────────────────────────────────────────────────────
_pv_usage() {
  cat <<EOF
Usage:
  sxgate preview setup                              one-time: wildcard ingress + dispatcher + units
  sxgate preview up [--repo <path>] [--from <base>] <branch>
  sxgate preview rebuild <slug|branch>              re-pull + rebuild + restart
  sxgate preview down <slug|branch>                 stop + remove route + worktree
  sxgate preview ls
  sxgate preview pw <slug|branch>                   print the preview's passphrase (if protected)

Set PREVIEW_PASSWORD=1 on 'up' to gate the preview behind a 3-word passphrase (Caddy basic_auth,
login user 'preview'); the passphrase is printed once and re-shown by 'preview pw'.

A service repo opts in with .sxgate/preview.conf (sourced; placeholders {worktree} {state}
{zone} {port}). Keys: SERVICE, BUILD, MODE (static_proxy|proxy|static), ROOT, API_PREFIX,
RUN, RUN_CWD, RUN_ENV, SEED, HEALTHCHECK, HOOK. Preview URL = <branch>-<service>.<zone>.
EOF
}

cmd_preview() {
  local sub=${1:-}
  case "$sub" in
    ls | list | "" | -h | --help) : ;;   # read-only / help: no root
    *) needs_root preview "$@" ;;          # re-exec as root: up/down/rebuild/setup, and pw (root file)
  esac
  shift || true
  case "$sub" in
    setup) _pv_cmd_setup "$@" ;;
    up) _pv_cmd_up "$@" ;;
    rebuild) _pv_cmd_rebuild "$@" ;;
    down) _pv_cmd_down "$@" ;;
    ls | list) _pv_cmd_ls "$@" ;;
    pw) _pv_cmd_pw "$@" ;;
    "" | -h | --help) _pv_usage ;;
    *) die "unknown subcommand: preview $sub" 2 ;;
  esac
}
