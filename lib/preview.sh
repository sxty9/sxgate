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

_pv_used_ports() { grep -hsoE '^PORT=[0-9]+' "$PREVIEW_ETC"/instances/*.env 2>/dev/null | cut -d= -f2; }

_pv_alloc_port() {
  local p used; used=$(_pv_used_ports)
  for ((p = PREVIEW_PORT_LO; p <= PREVIEW_PORT_HI; p++)); do
    printf '%s\n' "$used" | grep -qx "$p" && continue
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

# Render one dispatcher vhost: every preview listens on the dispatcher port and is keyed
# by Host; cloudflared forwards the original Host, so Caddy multiplexes by it.
_pv_render_vhost() {
  local host=$1 mode=$2 wt=$3 root=$4 api=$5 port=$6
  printf 'http://%s:%s {\n\tbind 127.0.0.1 ::1\n' "$host" "$PREVIEW_DISPATCH_PORT"
  case "$mode" in
    proxy)
      printf '\treverse_proxy 127.0.0.1:%s\n' "$port" ;;
    static)
      printf '\troot * %s/%s\n\ttry_files {path} /index.html\n\tfile_server\n' "$wt" "$root" ;;
    static_proxy | *)
      printf '\thandle %s/* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$api" "$port"
      printf '\thandle {\n\t\troot * %s/%s\n\t\ttry_files {path} /index.html\n\t\tfile_server\n\t}\n' "$wt" "$root" ;;
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
    [ -n "${backup:-}" ] && { cp -a "$backup" "$CONFIG_FILE"; die "cloudflared rejected the wildcard ingress; rolled back" 4; }
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
  rm -f "$PREVIEW_ETC/sites.d/$slug.caddy" "$PREVIEW_ETC/instances/$slug.env" "$PREVIEW_ETC/instances/$slug.meta" 2>/dev/null || true
}

_pv_chown() {
  [ "$(id -u)" -eq 0 ] && id "$PREVIEW_USER" >/dev/null 2>&1 \
    && chown -R "$PREVIEW_USER:$PREVIEW_USER" "$PREVIEW_ROOT/$1" 2>/dev/null
  return 0
}

_pv_cmd_up() {
  local repo='' from='' branch=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --from) from=$2; shift 2 ;;
      -h | --help) _pv_usage; return 0 ;;
      -*) die "unknown flag: $1" 2 ;;
      *) [ -z "$branch" ] && branch=$1 || die "unexpected argument: $1" 2; shift ;;
    esac
  done
  [ -n "$branch" ] || die "usage: sxgate preview up [--repo <path>] [--from <base>] <branch>" 2
  load_conf
  [ -n "${MANAGED_ZONE:-}" ] || die "no zone set — run 'sxgate zone <domain>' first" 5
  [ -f "$PREVIEW_ETC/Caddyfile" ] || die "preview not set up — run 'sxgate preview setup' first" 5
  local repo_root
  repo_root=$(_pv_find_repo "${repo:-$PWD}") || die "no .sxgate/preview.conf found in ${repo:-$PWD} or its parents" 5
  with_lock _pv_up_locked "$repo_root" "$branch" "$from"
}

_pv_up_locked() {
  local repo_root=$1 branch=$2 from=$3
  local mf="$repo_root/.sxgate/preview.conf"
  eval "$(_pv_read_manifest "$mf")" || die "could not read manifest $mf" 5
  [ -n "$SERVICE" ] || die "manifest $mf is missing SERVICE" 3
  validate_service_name "$SERVICE"
  : "${MODE:=static_proxy}" "${API_PREFIX:=/api}" "${RUN_CWD:=.}"

  local slug host wt state
  slug=$(_pv_slug "$branch" "$SERVICE")
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,61}$ ]] || die "computed slug '$slug' is not a valid DNS label" 3
  host="$slug.$MANAGED_ZONE"
  wt="$PREVIEW_ROOT/$slug/repo"
  state="$PREVIEW_ROOT/$slug/state"
  [ -e "$PREVIEW_ETC/instances/$slug.meta" ] && die "preview '$slug' already exists — use 'sxgate preview rebuild $branch' or 'down' first" 3

  local port; port=$(_pv_alloc_port) || die "no free preview port in $PREVIEW_PORT_LO-$PREVIEW_PORT_HI" 1

  # 1. isolated worktree
  mkdir -p "$PREVIEW_ROOT/$slug"
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo_root" worktree add "$wt" "$branch" >/dev/null 2>&1 \
      || { _pv_rollback "$slug" "$repo_root"; die "git worktree add failed for branch '$branch' (already checked out?)" 1; }
  else
    git -C "$repo_root" worktree add -b "$branch" "$wt" "${from:-HEAD}" >/dev/null 2>&1 \
      || { _pv_rollback "$slug" "$repo_root"; die "git worktree add -b '$branch' from '${from:-HEAD}' failed" 1; }
  fi

  # 2. build (manifest BUILD or HOOK build)
  mkdir -p "$state"
  if [ -n "${HOOK:-}" ]; then
    ( cd "$wt" && PORT="$port" bash "$wt/$HOOK" build "$wt" "$state" ) \
      || { _pv_rollback "$slug" "$repo_root"; die "hook build failed" 1; }
  elif [ -n "${BUILD:-}" ]; then
    ( cd "$wt" && bash -c "$(_pv_expand "$BUILD" "$wt" "$state" "$MANAGED_ZONE" "$port")" ) \
      || { _pv_rollback "$slug" "$repo_root"; die "build failed" 1; }
  fi

  # 3. seed (optional) — stdout shown to the user as notes
  local notes=''
  if [ -n "${SEED:-}" ]; then
    notes=$( cd "$wt" && PORT="$port" bash -c "$(_pv_expand "$SEED" "$wt" "$state" "$MANAGED_ZONE" "$port")" ) \
      || warn "seed command failed"
  fi
  _pv_chown "$slug"

  # 4. dispatcher vhost
  _pv_render_vhost "$host" "$MODE" "$wt" "${ROOT:-}" "$API_PREFIX" "$port" \
    | atomic_write "$PREVIEW_ETC/sites.d/$slug.caddy"

  # 5. backend instance (if the service has one)
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
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload 2>/dev/null || true
      systemctl enable --now "sxgate-preview@$slug" >/dev/null 2>&1 || warn "could not start sxgate-preview@$slug"
    fi
  fi

  # 6. publish + record
  _pv_reload_dispatcher
  _pv_write_meta "$slug" "$branch" "$SERVICE" "$repo_root" "$port" "$host" "$MODE"
  _pv_chown "$slug"

  log "preview up: https://$host"
  log "  slug=$slug  branch=$branch  service=$SERVICE  port=$port  mode=$MODE"
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
  } | atomic_write "$PREVIEW_ETC/instances/$1.meta"
}

# ── rebuild / down / ls ───────────────────────────────────────────────────────
_pv_cmd_rebuild() {
  local arg=${1:-}; [ -n "$arg" ] || die "usage: sxgate preview rebuild <slug|branch>" 2
  load_conf
  local slug; slug=$(_pv_resolve_slug "$arg") || die "no preview matching '$arg'" 3
  with_lock _pv_rebuild_locked "$slug"
}
_pv_rebuild_locked() {
  local slug=$1 repo wt state
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

_pv_cmd_down() {
  local arg=${1:-}; [ -n "$arg" ] || die "usage: sxgate preview down <slug|branch>" 2
  load_conf
  local slug; slug=$(_pv_resolve_slug "$arg") || die "no preview matching '$arg'" 3
  confirm "remove preview '$slug' (worktree, instance, route)?" || die "aborted" 10
  with_lock _pv_down_locked "$slug"
}
_pv_down_locked() {
  local slug=$1 repo wt
  repo=$(_pv_meta_get "$slug" REPO); wt="$PREVIEW_ROOT/$slug/repo"
  command -v systemctl >/dev/null 2>&1 && systemctl disable --now "sxgate-preview@$slug" >/dev/null 2>&1
  rm -f "$PREVIEW_ETC/sites.d/$slug.caddy" "$PREVIEW_ETC/instances/$slug.env" "$PREVIEW_ETC/instances/$slug.meta"
  _pv_reload_dispatcher
  [ -n "$repo" ] && [ -d "$wt" ] && git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "${PREVIEW_ROOT:?}/$slug"
  log "preview down: $slug"
}

_pv_cmd_ls() {
  local m slug any=0
  printf '%-30s %-18s %-6s %s\n' SLUG BRANCH PORT URL
  for m in "$PREVIEW_ETC"/instances/*.meta; do
    [ -e "$m" ] || continue
    any=1; slug=$(basename "${m%.meta}")
    printf '%-30s %-18s %-6s https://%s\n' \
      "$slug" "$(_pv_meta_get "$slug" BRANCH)" "$(_pv_meta_get "$slug" PORT)" "$(_pv_meta_get "$slug" HOST)"
  done
  [ "$any" = 0 ] && log "(no previews)"
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

A service repo opts in with .sxgate/preview.conf (sourced; placeholders {worktree} {state}
{zone} {port}). Keys: SERVICE, BUILD, MODE (static_proxy|proxy|static), ROOT, API_PREFIX,
RUN, RUN_CWD, RUN_ENV, SEED, HEALTHCHECK, HOOK. Preview URL = <branch>-<service>.<zone>.
EOF
}

cmd_preview() {
  local sub=${1:-}
  case "$sub" in
    ls | list | "" | -h | --help) : ;;   # read-only / help: no root
    *) needs_root preview "$@" ;;          # re-exec the whole 'preview <sub> …' as root
  esac
  shift || true
  case "$sub" in
    setup) _pv_cmd_setup "$@" ;;
    up) _pv_cmd_up "$@" ;;
    rebuild) _pv_cmd_rebuild "$@" ;;
    down) _pv_cmd_down "$@" ;;
    ls | list) _pv_cmd_ls "$@" ;;
    "" | -h | --help) _pv_usage ;;
    *) die "unknown subcommand: preview $sub" 2 ;;
  esac
}
