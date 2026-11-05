#!/bin/bash
# /usr/local/bin/installomp-entrypoint — PID 1 supervisor for omp-hosted
#
# Adapted from hermes-hosted v8 (2026-10-20, 5 rejected Fred lessons) with
# the OMP deltas. WHY A CUSTOM SUPERVISOR: Fred's tenant sandbox denies exec
# of files under /run, which structurally kills s6-overlay boots; the
# upstream oh-my-pi image uses tini+omp as PID 1, which we must replace
# anyway (the TUI lives inside a tmux session — the main program is the
# supervisor, not `omp`). everclaw/IOC has run this pattern on Fred since
# launch.
#
# Boot sequence:
#   Phase 1  forensics + writability probes:
#              - identity, mounts, write tests (v9.2 lesson: logged every
#                boot, straight into the container log)
#              - agent HOME chain: /home/agent first, fallback /tmp/omp-home
#              - /data cache chain (upstream ENV CARGO_HOME/RUSTUP_HOME/
#                CARGO_TARGET_DIR point at /data; relocate when unwritable)
#              - privilege-drop probe (setpriv to agent uid) — Fred may EPERM
#                the uid/gid syscalls (hermes v9 lesson); DEGRADED-ROOT mode
#                then runs everything as root (IOC fleet pattern).
#   Phase 2  cont-init (root): /etc/cont-init.d/01-installomp-config.sh —
#            headless models.yml + config.yml + workspace AGENTS.md.
#            MUST succeed; a failed bootstrap aborts the container.
#   Phase 3  services (privilege-dropped where available):
#              auth-proxy    :18789  0.0.0.0   the ONLY ingress (Privy JWT)
#              web-terminal  :7681   127.0.0.1 ttyd → tmux attach → omp TUI
#              cig-adapter   :18900  127.0.0.1 loopback CIG inference shim
#   Phase 4  supervise: wait/restart with per-service backoff.
#
# Product invariants (re-asserted AFTER cont-init so nothing can silently
# weaken them): ttyd binds 127.0.0.1 ALWAYS — the auth-proxy is the only
# ingress; a non-loopback ttyd would expose an unauthenticated terminal.
#
# Env contract: see README.md. Docker env reaches PID 1 intact (no /init
# scrubbing; the OMP base has no s6 heritage, so no with-contenv phase).

set -u
shopt -s nullglob

log() { printf '[installomp] %s\n' "$*"; }

# --- forensics (v9.2: every boot) ---
log "forensics: $(id)"
log "forensics: homes: $(ls -ld / /home /home/agent /data /tmp /run /root 2>&1 | sed 's/^/  /' | tr '\n' ';')"
log "forensics: mounts: $(grep -E ' /data| /home| /tmp| /run| / ' /proc/mounts | awk '{print $2, $3, $4, "src="substr($1,1,40)}' | tr '\n' ';')"
for _p in /home/agent /data /tmp /run; do
  if touch "$_p/.installomp-wtest" 2>/dev/null; then
    log "forensics: WRITE OK: $_p"; rm -f "$_p/.installomp-wtest"
  else
    log "forensics: WRITE FAIL: $_p"
  fi
done

# --- agent HOME chain (~/.omp state must be writable) ---
AGENT_HOME=""
for _cand in /home/agent /tmp/omp-home; do
  if mkdir -p "$_cand" 2>/dev/null && touch "$_cand/.installomp-wtest" 2>/dev/null; then
    rm -f "$_cand/.installomp-wtest"
    AGENT_HOME="$_cand"
    break
  fi
done
if [ -z "$AGENT_HOME" ]; then
  log "FATAL: no writable agent HOME candidate — aborting"
  exit 115
fi
if [ "$AGENT_HOME" != "/home/agent" ]; then
  log "WARN: agent HOME relocated to $AGENT_HOME (/home/agent unwritable on this backend)"
  mkdir -p "$AGENT_HOME/workspace" 2>/dev/null || true
fi
export OMP_STATE_HOME="$AGENT_HOME"
export OMP_WORKSPACE="${OMP_WORKSPACE:-$AGENT_HOME/workspace}"

# --- /data cache chain (upstream ENV: CARGO_HOME/RUSTUP_HOME/CARGO_TARGET_DIR
#     default under /data/cache — relocate when the backend attach is
#     unwritable; hermes lease 01a15a53 lesson) ---
CACHE_BASE=""
for _cand in /data/cache /tmp/omp-cache; do
  if mkdir -p "$_cand" 2>/dev/null && touch "$_cand/.wtest" 2>/dev/null; then
    rm -f "$_cand/.wtest"
    CACHE_BASE="$_cand"
    break
  fi
done
if [ -n "$CACHE_BASE" ] && [ "$CACHE_BASE" != "/data/cache" ]; then
  log "WARN: toolchain caches relocated to $CACHE_BASE (/data unwritable on this backend)"
  export CARGO_HOME="$CACHE_BASE/cargo"
  export CARGO_TARGET_DIR="$CACHE_BASE/cargo-target"
  export RUSTUP_HOME="$CACHE_BASE/rustup"
  mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR" "$RUSTUP_HOME" 2>/dev/null || true
fi

# --- privilege-drop probe (hermes v9 lesson: Fred may EPERM the drop) ---
DROP_CMD=(setpriv --reuid "${AGENT_UID:-10000}" --regid "${AGENT_UID:-10000}" --clear-groups)
DROPS_ENABLED=1
if "${DROP_CMD[@]}" /bin/true 2>/dev/null; then
  log "privilege drop to 'agent' verified — services will run as agent (normal mode)"
else
  DROPS_ENABLED=0
  log "WARN: privilege drop to 'agent' unavailable (EPERM) — DEGRADED-ROOT mode:"
  log "WARN: all services will run as root (everclaw/IOC fleet pattern; container isolation is the security boundary)"
fi

as_agent() { # run a command as the agent user when drops are available
  if [ "$DROPS_ENABLED" = 1 ]; then
    "${DROP_CMD[@]}" env HOME="$OMP_STATE_HOME" "$@"
  else
    env HOME="$OMP_STATE_HOME" "$@"
  fi
}

# ---------------------------------------------------------------- Phase 2 ---
run_continit() {
  local script rc
  for script in /etc/cont-init.d/01-installomp-config.sh; do
    if [ ! -x "$script" ]; then
      log "FATAL: cont-init script missing or not executable: $script"
      exit 112
    fi
    log "cont-init: running $script"
    sh "$script"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      log "FATAL: cont-init failed ($script, exit $rc) — aborting (bootstrap contract)"
      exit 112
    fi
  done
}

# ---------------------------------------------------------------- Phase 3 ---
# Product invariants: the web terminal is ALWAYS loopback — the auth-proxy
# is the only ingress; a non-loopback ttyd would expose an unauthenticated
# terminal surface behind nothing.
export TTYD_HOST=127.0.0.1

declare -A PIDS=()    # service name -> pid
declare -A FAILS=()   # service name -> consecutive failed starts
declare -A STAMP=()   # service name -> last start epoch (backoff reset)

svc_pid_ok() { kill -0 "${PIDS[$1]:-999999}" 2>/dev/null; }

spawn_service() {
  local name="$1" pid
  case "$name" in
    auth-proxy)
      as_agent /usr/local/bin/auth-proxy &
      ;;
    web-terminal)
      # bin/omp-session: ensures the tmux session exists (running the omp
      # TUI in a restart wrapper), then execs ttyd in the FOREGROUND —
      # the supervised process IS ttyd; a ttyd crash restarts it, and the
      # wrapper re-ensures the tmux session (user session survives).
      as_agent /usr/local/bin/omp-session &
      ;;
    cig-adapter)
      as_agent /usr/local/bin/cig-adapter &
      ;;
    *)
      log "FATAL: unknown service $name"
      exit 113
      ;;
  esac
  pid=$!
  PIDS[$name]=$pid
  STAMP[$name]=$(date +%s)
  log "service $name started (pid $pid)"
}

had_stable_uptime() { # true when the service had been up ≥300s → reset backoff
  local now
  now=$(date +%s)
  [ $((now - ${STAMP[$1]:-0})) -ge 300 ]
}

backoff_seconds() { # 2,4,8,16,32,64 — capped
  local n=${FAILS[$1]:-1}
  [ "$n" -gt 6 ] && n=6
  echo $((2 ** n))
}

supervise() {
  local name delay rc
  while :; do
    wait -n
    rc=$?
    for name in auth-proxy web-terminal cig-adapter; do
      [ -n "${PIDS[$name]:-}" ] || continue
      svc_pid_ok "$name" && continue
      log "service $name (pid ${PIDS[$name]}) exited (rc $rc)"
      unset "PIDS[$name]"
      if had_stable_uptime "$name"; then
        FAILS[$name]=1
      else
        FAILS[$name]=$(( ${FAILS[$name]:-0} + 1 ))
      fi
      delay=$(backoff_seconds "$name")
      log "service $name: restart #$(( ${FAILS[$name]:-1} )) in ${delay}s"
      sleep "$delay"
      spawn_service "$name"
    done
  done
}

shutdown() {
  local pid name i alive
  log "SIGTERM/SIGINT — stopping services"
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    for pid in "${PIDS[@]}"; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    [ "$alive" = 0 ] && break
    sleep 1
  done
  for pid in "${PIDS[@]}"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done
  log "all services stopped — exiting"
  exit 0
}

# ------------------------------------------------------------------ main ---
[ "$(id -u)" = 0 ] || log "NOTE: starting as uid $(id -u) (non-root start; drops still apply where possible)"

log "omp-hosted entrypoint starting (PID 1 supervisor, no s6)"
trap 'shutdown' TERM INT
run_continit
# Re-assert invariants AFTER cont-init (a manifest-supplied value cannot
# weaken the product contract).
export TTYD_HOST=127.0.0.1

log "starting services: auth-proxy web-terminal cig-adapter"
spawn_service auth-proxy
spawn_service web-terminal
spawn_service cig-adapter
supervise
