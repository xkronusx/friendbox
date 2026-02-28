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

get_profile_args() {
  local args=(--profile traefik --profile portainer)
  if [[ -f "$SELECTED_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "traefik" && "$line" != "portainer" ]] \
        && args+=(--profile "$line")
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

health_check() {
  echo ""
  echo -e "${BOLD}Container Health Report${RESET}"
  echo "─────────────────────────────────────────────────────"
  printf "%-24s %-15s %-20s\n" "NAME" "STATUS" "HEALTH"
  echo "─────────────────────────────────────────────────────"

  while IFS= read -r name; do
    local status health
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not found")
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$name" 2>/dev/null || echo "n/a")
    case "$status" in
      running)  col="${GREEN}" ;;
      exited)   col="${RED}"   ;;
      *)        col="${YELLOW}" ;;
    esac
    printf "${col}%-24s %-15s %-20s${RESET}\n" "$name" "$status" "$health"
  done < <(compose ps --format '{{.Name}}' 2>/dev/null)

  echo "─────────────────────────────────────────────────────"

  local bad
  bad=$(docker ps --filter "network=medianet" --filter "status=exited" --format "{{.Names}}" 2>/dev/null || true)
  if [[ -n "$bad" ]]; then
    echo ""
    warn "The following containers are not running:"
    echo "$bad" | while read -r c; do echo "  • $c"; done
    echo ""
    read -rp "Attempt to restart them? [y/N] " yn
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
