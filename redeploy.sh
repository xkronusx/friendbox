#!/usr/bin/env bash
# =============================================================================
#  redeploy.sh — Standalone container redeploy helper
#  sudo /opt/friendbox/scripts/redeploy.sh [service|--restart|--health]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

INSTALL_DIR="/opt/friendbox"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
SELECTED_FILE="${INSTALL_DIR}/.selected_containers"

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

[[ -f "$COMPOSE_FILE" ]] || { error "Compose file not found. Run sudo friendbox first."; exit 1; }
[[ -f "$ENV_FILE" ]]     || { error ".env not found. Run sudo friendbox first."; exit 1; }
[[ $EUID -ne 0 ]]        && { error "Run as root: sudo $0 $*"; exit 1; }

get_profile_args() {
  local args=()
  if [[ -f "$SELECTED_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && args+=(--profile "$line")
    done < "$SELECTED_FILE"
  fi
  printf '%s\n' "${args[@]}"
}

compose() {
  local profile_args=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && profile_args+=("$line")
  done < <(get_profile_args)
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${profile_args[@]}" "$@"
}

# Kernel-level resource report (cgroup v2 + PSI — Ubuntu 26.04 is cgroup v2 only).
#  • PSI: how long tasks stalled waiting for CPU / memory / IO over the last 10s.
#    Sustained memory or IO pressure is the early warning before streams buffer.
#  • OOM kills: per-container count from the container's own cgroup, so a download
#    client being killed for memory is visible even though it auto-restarts.
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
PSI_ROOT="${PSI_ROOT:-/proc/pressure}"

resource_report() {
  local r line avg col shown=false
  if [[ -r "${PSI_ROOT}/memory" ]]; then
    echo ""
    echo -e "${BOLD}Host pressure (PSI, 10s avg — % of time tasks were stalled)${RESET}"
    for r in cpu memory io; do
      [[ -r "${PSI_ROOT}/${r}" ]] || continue
      line=$(grep '^some' "${PSI_ROOT}/${r}")
      avg=${line#*avg10=}; avg=${avg%% *}
      col="${GREEN}"
      # whole-number compare: >=10% memory/io stall or >=50% cpu stall is notable
      case "$r" in
        cpu) (( ${avg%.*} >= 50 )) && col="${YELLOW}" ;;
        *)   (( ${avg%.*} >= 10 )) && col="${YELLOW}" ;;
      esac
      printf "  ${col}%-8s %s%%${RESET}\\n" "$r" "$avg"
    done
  fi

  [[ $# -gt 0 && -d "${CGROUP_ROOT}/system.slice" ]] || return 0
  local name id ev kills
  for name in "$@"; do
    id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || continue
    ev="${CGROUP_ROOT}/system.slice/docker-${id}.scope/memory.events"
    [[ -r "$ev" ]] || continue
    kills=$(awk '$1=="oom_kill"{print $2}' "$ev")
    if [[ "${kills:-0}" -gt 0 ]]; then
      if [[ "$shown" == "false" ]]; then
        echo ""; warn "Containers killed by the kernel for running out of memory:"; shown=true
      fi
      echo "  • ${name}: ${kills} OOM kill(s) since it last started"
    fi
  done
  [[ "$shown" == "true" ]] && echo -e "  ${DIM:-}Consider raising memory, adding swap, or lowering concurrent downloads.${RESET}"
  return 0
}

health_check() {
  echo ""
  echo -e "${BOLD}Container Health Report${RESET}"
  echo "─────────────────────────────────────────────────────"
  printf "%-24s %-15s %-20s\n" "NAME" "STATUS" "HEALTH"
  echo "─────────────────────────────────────────────────────"

  # Collect container names first
  local names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(compose ps --format '{{.Name}}' 2>/dev/null)

  if [[ ${#names[@]} -gt 0 ]]; then
    # Single docker inspect call for all containers — avoid N*2 subprocesses
    local inspect_out
    inspect_out=$(docker inspect "${names[@]}" 2>/dev/null)

    local name
    for name in "${names[@]}"; do
      local status health col
      status=$(printf '%s' "$inspect_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
c = next((x for x in data if x['Name'].lstrip('/') == name), None)
print(c['State']['Status'] if c else 'not found')
" "$name" 2>/dev/null || echo "not found")
      health=$(printf '%s' "$inspect_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
c = next((x for x in data if x['Name'].lstrip('/') == name), None)
if c and c['State'].get('Health'):
    print(c['State']['Health']['Status'])
else:
    print('n/a')
" "$name" 2>/dev/null || echo "n/a")
      case "$status" in
        running)  col="${GREEN}" ;;
        exited)   col="${RED}"   ;;
        *)        col="${YELLOW}" ;;
      esac
      printf "${col}%-24s %-15s %-20s${RESET}\n" "$name" "$status" "$health"
    done
  fi

  echo "─────────────────────────────────────────────────────"

  resource_report "${names[@]}"

  local bad
  bad=$(docker ps --filter "network=medianet" --filter "status=exited" --format "{{.Names}}" 2>/dev/null || true)
  if [[ -n "$bad" ]]; then
    echo ""
    warn "The following containers are not running:"
    echo "$bad" | while read -r c; do echo "  • $c"; done
    echo ""
    read -rp "Attempt to restart them? [y/N] " yn || true
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      echo "$bad" | while read -r c; do
        info "Restarting ${c}..."
        docker start "$c" && success "${c} started." || warn "Could not start ${c}."
      done
    fi
  else
    success "All active containers are running."
  fi
}

case "${1:-all}" in
  --health|-h)
    health_check ;;
  --restart|-r)
    info "Restarting all active containers..."
    compose restart
    success "Done." ;;
  all)
    info "Pulling latest images..."
    compose pull
    info "Recreating all active containers..."
    compose up -d --force-recreate
    success "All active containers redeployed." ;;
  *)
    svc="$1"
    info "Pulling image for ${svc}..."
    compose pull "$svc"
    info "Recreating ${svc}..."
    compose up -d --force-recreate "$svc"
    success "${svc} redeployed." ;;
esac
