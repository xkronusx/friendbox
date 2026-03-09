#!/usr/bin/env bash
# =============================================================================
#  Friendbox Setup — Interactive Menu
#  curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/setup.sh | bash
#
#  Tested on: Ubuntu 24.04.4 LTS (Noble Numbat)
# =============================================================================

# Note: set -e / set -u intentionally omitted — this is an interactive menu
# script where non-zero exits from grep, [[ tests, and optional commands are
# normal and must not crash the session.

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_URL="https://raw.githubusercontent.com/xkronusx/friendbox/main"
INSTALL_DIR="/opt/friendbox"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
STATE_FILE="${INSTALL_DIR}/.state"
SELECTED_FILE="${INSTALL_DIR}/.selected_containers"
MERGERFS_MODES_FILE="${INSTALL_DIR}/.mergerfs_modes"
MERGERFS_POOL_FILE="${INSTALL_DIR}/.mergerfs_pool"
DNS_STATE_FILE="${INSTALL_DIR}/.dns_config"
INSTALL_FLAG="${INSTALL_DIR}/.installed"
MEDIA_ROOT="/mnt/media"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# menu_die is used inside menu-callable functions — shows error but returns to menu
menu_die() { error "$*"; return 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This action must be run as root. Use: sudo friendbox"
    return 1
  fi
}

pause() {
  echo ""
  read -rp "Press [Enter] to return to the menu..."
}

# ── Install state ─────────────────────────────────────────────────────────────
is_installed() {
  [[ -f "$INSTALL_FLAG" ]]
}

mark_installed() {
  _ensure_install_dir
  echo "installed=$(date '+%Y-%m-%d %H:%M:%S')" > "$INSTALL_FLAG"
  _own "$INSTALL_FLAG"
}

mark_uninstalled() {
  rm -f "$INSTALL_FLAG"
}

# chown a path to PUID:PGID (from .env, defaulting to 1000:1000).
# No-ops silently when not root.
_own() {
  [[ $EUID -ne 0 ]] && return 0
  local uid gid
  uid=$(grep '^PUID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true) ; uid="${uid:-1000}"
  gid=$(grep '^PGID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true) ; gid="${gid:-1000}"
  chown "${uid}:${gid}" "$@"
}

# Create the INSTALL_DIR tree and set ownership on every subdirectory.
_ensure_install_dir() {
  mkdir -p "${INSTALL_DIR}"/{config/traefik,scripts}
  _own "${INSTALL_DIR}" \
       "${INSTALL_DIR}/config" \
       "${INSTALL_DIR}/config/traefik" \
       "${INSTALL_DIR}/scripts"
}

# Recursively fix ownership of everything in INSTALL_DIR to PUID:PGID.
# Safe to call on every launch — fast no-op if already correct.
_fix_install_dir_ownership() {
  [[ $EUID -ne 0 ]] && return 0
  [[ ! -d "$INSTALL_DIR" ]] && return 0

  local uid gid
  uid=$(grep '^PUID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true) ; uid="${uid:-1000}"
  gid=$(grep '^PGID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true) ; gid="${gid:-1000}"

  chown -R "${uid}:${gid}" "${INSTALL_DIR}"

  # acme.json must be root:root 600 — Traefik v3 runs as root inside the
  # container and needs write access. Exclude it from the PUID:PGID chown.
  local acme="${INSTALL_DIR}/config/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    chown root:root "$acme"
    chmod 600 "$acme"
  fi

  # .env and .dns_config contain API keys and credentials — keep permissions tight
  local dns_cfg="${INSTALL_DIR}/.dns_config"
  [[ -f "$dns_cfg" ]] && chmod 600 "$dns_cfg"
  [[ -f "$ENV_FILE" ]] && chmod 600 "$ENV_FILE"
}

ensure_media_root() {
  # Create MEDIA_ROOT on every interactive launch so it always exists as a
  # mount point for MergerFS, or as a plain directory for single-drive setups.
  # Sets ownership of /mnt and MEDIA_ROOT to PUID:PGID (default 1000:1000).
  # Requires root — silently skipped otherwise.
  [[ $EUID -ne 0 ]] && return 0

  # Read PUID/PGID from .env if it exists, fall back to 1000:1000
  local uid="1000" gid="1000"
  if [[ -f "$ENV_FILE" ]]; then
    local env_uid env_gid
    env_uid=$(grep '^PUID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    env_gid=$(grep '^PGID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    [[ -n "$env_uid" ]] && uid="$env_uid"
    [[ -n "$env_gid" ]] && gid="$env_gid"
  fi

  if [[ ! -d "$MEDIA_ROOT" ]]; then
    mkdir -p "$MEDIA_ROOT"
    success "Created media root directory: ${MEDIA_ROOT}"
  fi

  # Own only MEDIA_ROOT — chowning /mnt itself is too broad and can
  # break other filesystem mounts that rely on root ownership of /mnt.
  chown "${uid}:${gid}" "$MEDIA_ROOT"
}

# Returns 0 (true) if the stack appears to have active containers
is_running() {
  # Must use compose_selected (not bare docker compose) so that profile-gated
  # containers are included — every service in this project is profile-gated,
  # so a call without --profile args would always see nothing and return false.
  compose_selected ps --status running 2>/dev/null | grep -q "running" || return 1
}

# ── OS compatibility check ────────────────────────────────────────────────────
check_os() {
  local os_id="" os_version="" os_pretty=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release 2>/dev/null || true
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_pretty="${PRETTY_NAME:-unknown}"
  fi

  local supported=false
  [[ "$os_id" == "ubuntu" && "$os_version" == "24.04" ]] && supported=true

  if [[ "$supported" == "true" ]]; then
    success "OS check passed: ${os_pretty}"
  else
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}║  ⚠  Unsupported Operating System                            ║${RESET}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Detected:${RESET}   ${os_pretty:-Unknown OS}"
    echo -e "  ${BOLD}Supported:${RESET}  Ubuntu 24.04 LTS (Noble Numbat)"
    echo ""
    echo -e "  Friendbox is tested and supported on ${BOLD}Ubuntu 24.04 LTS${RESET} only."
    echo -e "  Running on other systems may work but is not officially supported."
    echo -e "  Package names, service paths, and Docker install steps may differ."
    echo ""
    read -rp "  Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "Aborted. Please install Ubuntu 24.04.4 LTS and try again."
    warn "Continuing on unsupported OS — proceed with caution."
  fi
  echo ""
}

# ── Container catalogue ───────────────────────────────────────────────────────
CONTAINER_ORDER=(
  traefik portainer
  plex jellyfin
  sonarr radarr prowlarr bazarr
  qbittorrent qbittorrentvpn delugevpn nzbget
  overseerr ombi jellyseerr
  teamspeak6 mumble
  ampmc
  netbootxyz
)

declare -A CONTAINER_NAMES=(
  [traefik]="Traefik"
  [portainer]="Portainer"
  [plex]="Plex"
  [jellyfin]="Jellyfin"
  [sonarr]="Sonarr"
  [radarr]="Radarr"
  [prowlarr]="Prowlarr (nightly)"
  [bazarr]="Bazarr"
  [qbittorrent]="qBittorrent"
  [qbittorrentvpn]="qBittorrentVPN"
  [delugevpn]="DelugeVPN"
  [nzbget]="NZBGet"
  [overseerr]="Overseerr"
  [ombi]="Ombi v3 — media request manager (deprecated; consider Overseerr or Jellyseerr)"
  [jellyseerr]="Jellyseerr"
  [teamspeak6]="TeamSpeak 6"
  [mumble]="Mumble Server"
  [ampmc]="AMP (Game Server Panel)"
  [netbootxyz]="NetbootXYZ"
)

declare -A CONTAINER_DESC=(
  [traefik]="Reverse proxy + automatic HTTPS (recommended)"
  [portainer]="Docker management UI (recommended)"
  [plex]="Plex media server & player"
  [jellyfin]="Open-source media server (jellyfin/jellyfin)"
  [sonarr]="TV show library manager"
  [radarr]="Movie library manager"
  [prowlarr]="Indexer manager for Sonarr/Radarr"
  [bazarr]="Automatic subtitle downloader"
  [qbittorrent]="Torrent client — no VPN"
  [qbittorrentvpn]="Torrent client — routed through VPN (binhex)"
  [delugevpn]="Deluge torrent client — routed through VPN (binhex)"
  [nzbget]="Usenet download client"
  [overseerr]="Media request & discovery manager"
  [ombi]="Media request manager (Ombi v3) — DEPRECATED, consider Overseerr or Jellyseerr"
  [jellyseerr]="Jellyfin-native media request manager"
  [teamspeak6]="TeamSpeak 6 voice server"
  [mumble]="Open-source Mumble voice server"
  [ampmc]="Game server management panel (Minecraft etc.)"
  [netbootxyz]="PXE/network boot server"
)

declare -A CONTAINER_CATEGORY=(
  [traefik]="── Core Infrastructure"
  [plex]="── Media Servers"
  [sonarr]="── Library Management"
  [qbittorrent]="── Download Clients"
  [overseerr]="── Request Managers"
  [teamspeak6]="── Voice / Communication"
  [ampmc]="── Game Servers"
  [netbootxyz]="── Network Tools"
)

declare -A CONTAINER_ALWAYS=(
  [traefik]=false   [portainer]=false
  [plex]=false      [jellyfin]=false
  [sonarr]=false    [radarr]=false    [prowlarr]=false  [bazarr]=false
  [qbittorrent]=false [qbittorrentvpn]=false [delugevpn]=false [nzbget]=false
  [overseerr]=false [ombi]=false      [jellyseerr]=false
  [teamspeak6]=false [mumble]=false
  [ampmc]=false
  [netbootxyz]=false
)

# ── VPN containers (referenced by service credential menu) ────────────────────
VPN_CONTAINERS=(qbittorrentvpn delugevpn)

# ── Load / save selected containers ──────────────────────────────────────────
load_selected() {
  declare -gA SELECTED=()
  if [[ -f "$SELECTED_FILE" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && SELECTED[$line]=1
    done < "$SELECTED_FILE"
  else
    # No saved selection yet — default traefik + portainer selected
    SELECTED[traefik]=1
    SELECTED[portainer]=1
  fi
}

save_selected() {
  _ensure_install_dir
  : > "$SELECTED_FILE"
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] && echo "$key" >> "$SELECTED_FILE"
  done
  _own "$SELECTED_FILE"
}

# ── Container selection UI ────────────────────────────────────────────────────
select_containers() {
  load_selected

  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                   📦  Container Selection                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${DIM}Traefik and Portainer are recommended but optional.${RESET}"
    echo -e "  ${DIM}Without Traefik, services are accessible via direct port only.${RESET}"
    echo -e "  Toggle with the item number. ${BOLD}a${RESET}=all  ${BOLD}n${RESET}=none  ${BOLD}d${RESET}=done"
    echo ""

    local i=1
    declare -A IDX_MAP=()
    local key
    for key in "${CONTAINER_ORDER[@]}"; do
      if [[ -n "${CONTAINER_CATEGORY[$key]+_}" ]]; then
        echo -e "  ${BOLD}${CYAN}${CONTAINER_CATEGORY[$key]}${RESET}"
      fi
      local name="${CONTAINER_NAMES[$key]}"
      local desc="${CONTAINER_DESC[$key]}"
      local chosen=""
      [[ -n "${SELECTED[$key]+_}" ]] && chosen="1"

      if [[ -n "$chosen" ]]; then
        printf "  ${GREEN}[✔]${RESET} ${BOLD}%2d) %-24s${RESET} — %s\n" "$i" "$name" "$desc"
      else
        printf "  [ ] %2d) %-24s — %s\n" "$i" "$name" "$desc"
      fi

      IDX_MAP[$i]=$key
      i=$((i + 1))
    done

    echo ""
    echo -e "  ${BOLD}a)${RESET} Select all   ${BOLD}n)${RESET} Select none   ${BOLD}d)${RESET} Done"
    echo ""
    read -rp "  Choice: " choice

    case "$choice" in
      d|D) break ;;
      a|A)
        for key in "${CONTAINER_ORDER[@]}"; do SELECTED[$key]=1; done ;;
      n|N)
        for key in "${CONTAINER_ORDER[@]}"; do
          unset "SELECTED[$key]" 2>/dev/null || true
        done ;;
      ''|*[!0-9]*)
        warn "Enter a number, a, n, or d."; sleep 1 ;;
      *)
        if [[ -n "${IDX_MAP[$choice]+_}" ]]; then
          local k="${IDX_MAP[$choice]}"
          if [[ -n "${SELECTED[$k]+_}" ]]; then
            unset "SELECTED[$k]"
            # Warn if deselecting Traefik — services won't get HTTPS
            if [[ "$k" == "traefik" ]]; then
              warn "Traefik deselected — services will use direct port access only (no HTTPS)."
              sleep 2
            fi
          else
            SELECTED[$k]=1
          fi
        else
          warn "Invalid number."; sleep 1
        fi ;;
    esac
  done

  save_selected

  echo ""
  info "Selected containers:"
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] && echo "    ✔ ${CONTAINER_NAMES[$key]}"
  done
  # Reminder if no Traefik
  if [[ -z "${SELECTED[traefik]+_}" ]]; then
    echo ""
    warn "Traefik is not selected — services will be accessible via direct port only."
  fi
  # Reminder if VPN containers selected but not yet configured
  local vpn_selected=false
  local k
  for k in "${VPN_CONTAINERS[@]}"; do
    [[ -n "${SELECTED[$k]+_}" ]] && vpn_selected=true
  done
  if [[ "$vpn_selected" == "true" ]]; then
    echo ""
    info "VPN container(s) selected — use menu option 5 (Service credentials) to set VPN credentials before deploying."
  fi
  echo ""
  success "Selection saved."

  # Update USE_TRAEFIK and derived URL vars in .env to match the new selection.
  # This ensures Jellyfin and Plex don't reject direct connections when
  # Traefik is not selected.
  if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE" 2>/dev/null || true
    local _use_traefik="false"
    [[ -n "${SELECTED[traefik]+_}" ]] && _use_traefik="true"
    # Inline _env_set since we're outside configure_env here
    _env_set_inline() {
      local key="$1" val="$2"
      if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
      else
        echo "${key}=${val}" >> "$ENV_FILE"
      fi
    }
    _env_set_inline USE_TRAEFIK "$_use_traefik"

    # Set ROOT_REDIRECT_HOST — the bare-domain (https://DOMAIN) redirect target.
    # Priority: portainer > jellyfin > plex > overseerr > sonarr > first selected container.
    local _redir="portainer"
    local _redir_set=false
    for _cand in portainer jellyfin plex overseerr sonarr; do
      if [[ -n "${SELECTED[$_cand]+_}" ]]; then
        # Map container key to its subdomain
        declare -A _SD=([portainer]=portainer [jellyfin]=jellyfin [plex]=plex [overseerr]=overseerr [sonarr]=sonarr)
        _redir="${_SD[$_cand]}"
        _redir_set=true
        break
      fi
    done
    # If none of the preferred containers are selected, use the first selected one
    if [[ "$_redir_set" == "false" ]]; then
      declare -A _ALL_SD=([traefik]=traefik [portainer]=portainer [plex]=plex [jellyfin]=jellyfin
        [sonarr]=sonarr [radarr]=radarr [prowlarr]=prowlarr [bazarr]=bazarr
        [qbittorrent]=qbt [qbittorrentvpn]=qbtvpn [delugevpn]=deluge [nzbget]=nzbget
        [overseerr]=overseerr [ombi]=ombi [jellyseerr]=jellyseerr
        [ampmc]=amp [netbootxyz]=netboot)
      local _k
      for _k in "${CONTAINER_ORDER[@]}"; do
        if [[ -n "${SELECTED[$_k]+_}" && -n "${_ALL_SD[$_k]+_}" ]]; then
          _redir="${_ALL_SD[$_k]}"
          break
        fi
      done
    fi
    _env_set_inline ROOT_REDIRECT_HOST "$_redir"
  fi
}

# ── Profile args for docker compose ──────────────────────────────────────────
get_profile_args() {
  load_selected
  local args=()
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] && args+=(--profile "$key")
  done
  printf '%s\n' "${args[@]}"
}

compose_selected() {
  local profile_args=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && profile_args+=("$line")
  done < <(get_profile_args)
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${profile_args[@]}" "$@"
}

# ── Fetch helper ──────────────────────────────────────────────────────────────
fetch_remote() {
  local path="$1" dest="$2"
  if ! curl -fsSL "${REPO_URL}/${path}" -o "${dest}"; then
    error "Failed to fetch ${path} from repo."
    return 1
  fi
  return 0
}

# ── Startup auto-update ───────────────────────────────────────────────────────
# Called once at launch (before the menu). Downloads the latest versions of all
# repo-managed files, then re-execs the updated friendbox script so the rest of
# the session runs on fresh code. Passes --skip-update to the new process so it
# doesn't loop.  Skipped entirely when not root or when offline.
auto_update() {
  [[ $EUID -ne 0 ]] && return 0
  # Skip on first-time runs — nothing is installed yet, the compose file and
  # .env don't exist, so there's nothing useful to update or re-apply.
  is_installed || return 0

  echo -e "${CYAN}[INFO]${RESET}  Checking for updates..."
  _ensure_install_dir

  local failed=0
  curl -fsSL --max-time 10 "${REPO_URL}/setup.sh" \
      -o "/usr/local/bin/friendbox.new" 2>/dev/null || failed=$((failed+1))
  curl -fsSL --max-time 10 "${REPO_URL}/docker-compose.yml" \
      -o "${COMPOSE_FILE}.new"   2>/dev/null || failed=$((failed+1))

  if [[ $failed -gt 0 ]]; then
    echo -e "${YELLOW}[WARN]${RESET}  Could not reach GitHub - running with local files."
    rm -f "/usr/local/bin/friendbox.new" "${COMPOSE_FILE}.new"
    return 0
  fi

  # Validate downloads before replacing live files
  local compose_size script_size
  compose_size=$(wc -c < "${COMPOSE_FILE}.new" 2>/dev/null || echo 0)
  script_size=$(wc -c < "/usr/local/bin/friendbox.new" 2>/dev/null || echo 0)
  if [[ "$compose_size" -lt 1000 || "$script_size" -lt 1000 ]]; then
    echo -e "${YELLOW}[WARN]${RESET}  Downloaded files too small — possible truncated download. Skipping update."
    rm -f "/usr/local/bin/friendbox.new" "${COMPOSE_FILE}.new"
    return 0
  fi
  if ! bash -n /usr/local/bin/friendbox.new 2>/dev/null; then
    echo -e "${YELLOW}[WARN]${RESET}  Downloaded script failed syntax check — skipping update."
    rm -f "/usr/local/bin/friendbox.new" "${COMPOSE_FILE}.new"
    return 0
  fi
  if python3 -c "import yaml" 2>/dev/null; then
    if ! python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" \
        "${COMPOSE_FILE}.new" 2>/dev/null; then
      echo -e "${YELLOW}[WARN]${RESET}  Downloaded docker-compose.yml failed YAML parse — skipping update."
      rm -f "/usr/local/bin/friendbox.new" "${COMPOSE_FILE}.new"
      return 0
    fi
  fi

  mv "${COMPOSE_FILE}.new" "${COMPOSE_FILE}"
  _own "${COMPOSE_FILE}"

  # Re-apply Traefik patches to the freshly downloaded docker-compose.yml
  # BEFORE re-exec.  A fresh compose file from GitHub restores all certresolver
  # labels; for DuckDNS they must be stripped, and for all other providers
  # TRAEFIK_CERT_RESOLVER must be written to .env so labels expand correctly.
  # Jellyfin HW accel is also re-applied — a fresh compose resets the jellyfin
  # service to software transcoding, losing any VA-API/NVENC patch.
  if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE" 2>/dev/null || true
    if [[ -n "${TRAEFIK_ACME_PROVIDER:-}" ]]; then
      _traefik_write_config 2>/dev/null || true
    fi
    if [[ -n "${JELLYFIN_HW_ACCEL:-}" && "${JELLYFIN_HW_ACCEL}" != "none" ]]; then
      _jellyfin_hw_apply "${JELLYFIN_HW_ACCEL}" 2>/dev/null || true
    fi
  fi

  printf 'docker-compose.yml\n/usr/local/bin/friendbox\n' > "${INSTALL_DIR}/.update_notice"
  _own "${INSTALL_DIR}/.update_notice"

  mv /usr/local/bin/friendbox.new /usr/local/bin/friendbox
  chmod +x /usr/local/bin/friendbox

  # Regenerate the standalone redeploy helper from the new script's embedded
  # heredoc before re-exec — otherwise the old on-disk copy persists until the
  # next full_install or ensure_acme call.
  if [[ -f "${INSTALL_DIR}/scripts/redeploy.sh" ]]; then
    generate_redeploy_sh 2>/dev/null || true
  fi

  exec /usr/local/bin/friendbox --skip-update "$@"
}

sync_repo() {
  require_root
  echo ""
  echo -e "${BOLD}Syncing latest files from GitHub...${RESET}"
  echo ""
  _ensure_install_dir

  local script_ok=0 compose_ok=0

  printf "  %-34s " "friendbox script"
  if fetch_remote "setup.sh" "/usr/local/bin/friendbox.new" 2>/dev/null; then
    if ! bash -n /usr/local/bin/friendbox.new 2>/dev/null; then
      rm -f /usr/local/bin/friendbox.new
      echo -e "${RED}[FAILED]${RESET} (syntax check failed — file may be corrupt)"
    else
      mv /usr/local/bin/friendbox.new /usr/local/bin/friendbox
      chmod +x /usr/local/bin/friendbox
      echo -e "${GREEN}[OK]${RESET}"
      script_ok=1
    fi
  else
    rm -f /usr/local/bin/friendbox.new
    echo -e "${RED}[FAILED]${RESET}"
  fi

  printf "  %-34s " "docker-compose.yml"
  if fetch_remote "docker-compose.yml" "${COMPOSE_FILE}.new" 2>/dev/null; then
    local _csize; _csize=$(wc -c < "${COMPOSE_FILE}.new" 2>/dev/null || echo 0)
    if [[ "$_csize" -lt 1000 ]]; then
      rm -f "${COMPOSE_FILE}.new"
      echo -e "${RED}[FAILED]${RESET} (download too small — likely truncated)"
    elif python3 -c "import yaml" 2>/dev/null && \
         ! python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" \
             "${COMPOSE_FILE}.new" 2>/dev/null; then
      rm -f "${COMPOSE_FILE}.new"
      echo -e "${RED}[FAILED]${RESET} (YAML parse failed — file may be corrupt)"
    else
      mv "${COMPOSE_FILE}.new" "${COMPOSE_FILE}"
      _own "${COMPOSE_FILE}"
      echo -e "${GREEN}[OK]${RESET}"
      compose_ok=1
    fi
  else
    rm -f "${COMPOSE_FILE}.new"
    echo -e "${RED}[FAILED]${RESET}"
  fi
  echo ""
  if [[ $script_ok -eq 1 && $compose_ok -eq 1 ]]; then
    success "Sync complete. Run option 12 (Redeploy) to apply any image changes."
  elif [[ $script_ok -eq 0 && $compose_ok -eq 0 ]]; then
    warn "Sync failed. Check your internet connection."
    return 1
  else
    warn "Partial sync - check your internet connection."
  fi

  # Re-apply Traefik config patches if the compose file was replaced.
  # A fresh docker-compose.yml from GitHub has all certresolver labels intact —
  # for DuckDNS installs those labels must be stripped again, and for all providers
  # TRAEFIK_CERT_RESOLVER must be set to "letsencrypt".  Calling _traefik_write_config
  # here ensures the compose file and .env stay in sync after every sync.
  if [[ $compose_ok -eq 1 && -f "$ENV_FILE" ]]; then
    source "$ENV_FILE" 2>/dev/null || true
    if [[ -n "${TRAEFIK_ACME_PROVIDER:-}" ]]; then
      _traefik_write_config && info "Traefik config re-applied to updated docker-compose.yml."
    fi
    # Re-apply Jellyfin HW accel patch if one was previously configured.
    # A fresh compose file from GitHub resets the jellyfin service to software
    # transcoding — re-patching here keeps the user's HW accel setting intact.
    if [[ -n "${JELLYFIN_HW_ACCEL:-}" && "${JELLYFIN_HW_ACCEL}" != "none" ]]; then
      _jellyfin_hw_apply "${JELLYFIN_HW_ACCEL}" \
        && info "Jellyfin HW accel (${JELLYFIN_HW_ACCEL}) re-applied to updated docker-compose.yml."
    fi
  fi
  # Regenerate the standalone redeploy helper so it stays in sync with the
  # updated setup script — the helper is embedded as a heredoc in setup.sh and
  # can change between releases.
  if [[ -f "${INSTALL_DIR}/scripts/redeploy.sh" ]]; then
    generate_redeploy_sh 2>/dev/null || true
    info "redeploy.sh regenerated."
  fi
}

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  local cmd
  for cmd in docker curl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ! docker compose version &>/dev/null 2>&1; then
    missing+=("docker-compose-plugin")
  fi
  command -v htpasswd &>/dev/null || missing+=("apache2-utils")

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${missing[*]}"
    read -rp "Install them now? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "Cannot continue without dependencies."

    apt-get update -qq

    # Install docker-ce (official) rather than docker.io (Ubuntu-packaged)
    if ! command -v docker &>/dev/null; then
      info "Installing Docker CE (official)..."
      apt-get install -y ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # Install remaining missing packages
    local pkgs=()
    command -v curl     &>/dev/null || pkgs+=(curl)
    command -v htpasswd &>/dev/null || pkgs+=(apache2-utils)
    [[ ${#pkgs[@]} -gt 0 ]] && apt-get install -y "${pkgs[@]}"

    success "Dependencies installed."
  else
    success "All dependencies satisfied."
  fi

  # ── Diagnostic tools — installed unconditionally so they are present on
  #    existing installs that already had Docker/curl/htpasswd. ─────────────────
  # pciutils  → lspci  — GPU detection in Jellyfin HW accel checks.
  # vainfo               — VA-API capability verification (Intel/AMD).
  #   Package name varies by Ubuntu release: 'vainfo' on 22.04+, 'libva-utils'
  #   on some systems. We check dpkg (not command -v) to avoid re-running on
  #   every call if the binary is installed to a non-standard path.
  local _diag_pkgs=()
  dpkg -l pciutils  2>/dev/null | grep -q '^ii' || _diag_pkgs+=(pciutils)
  # Accept either vainfo or libva-utils as satisfying the vainfo requirement
  if ! dpkg -l vainfo     2>/dev/null | grep -q '^ii' && \
     ! dpkg -l libva-utils 2>/dev/null | grep -q '^ii'; then
    # Try 'vainfo' first (Ubuntu 22.04+); fall back to 'libva-utils' (older/Debian)
    if apt-cache show vainfo &>/dev/null 2>&1; then
      _diag_pkgs+=(vainfo)
    else
      _diag_pkgs+=(libva-utils)
    fi
  fi
  if [[ ${#_diag_pkgs[@]} -gt 0 ]]; then
    info "Installing diagnostic tools: ${_diag_pkgs[*]}..."
    apt-get update -qq
    apt-get install -y "${_diag_pkgs[@]}" \
      && success "Diagnostic tools installed." \
      || warn "Could not install ${_diag_pkgs[*]} — HW accel detection may be limited."
  fi

  # ── MergerFS — optional, only needed for storage pool feature ────────────────
  if command -v mergerfs &>/dev/null; then
    local mfs_ver
    mfs_ver=$(mergerfs --version 2>&1 | awk '{print $NF}' | head -1)
    success "mergerfs installed (${mfs_ver:-unknown version})."
  else
    info "mergerfs not installed — only required for the MergerFS storage pool (menu option 7)."
    info "It will be installed automatically when you run the pool setup."
  fi
}

# =============================================================================
#  MergerFS Storage Manager
# =============================================================================

_mergerfs_load_modes() {
  declare -gA DISK_MODES=()
  [[ -f "$MERGERFS_MODES_FILE" ]] || return 0
  local path mode
  while IFS='=' read -r path mode; do
    [[ -n "$path" && -n "$mode" ]] && DISK_MODES[$path]="$mode"
  done < "$MERGERFS_MODES_FILE"
}

_mergerfs_save_modes() {
  _ensure_install_dir
  : > "$MERGERFS_MODES_FILE"
  local path
  for path in "${!DISK_MODES[@]}"; do
    echo "${path}=${DISK_MODES[$path]}" >> "$MERGERFS_MODES_FILE"
  done
  _own "$MERGERFS_MODES_FILE"
}

_mergerfs_load_pool() {
  MERGERFS_POOL=""
  [[ -f "$MERGERFS_POOL_FILE" ]] && MERGERFS_POOL=$(cat "$MERGERFS_POOL_FILE") || true
}

_mergerfs_save_pool() {
  _ensure_install_dir
  echo "$1" > "$MERGERFS_POOL_FILE"
  _own "$MERGERFS_POOL_FILE"
}

_mergerfs_build_branch_list() {
  # For fstab: mergerfs v2 parses path=MODE in the source/device field.
  # RW/NC branches first, then RO. Format: /mnt/disk1=RW:/mnt/disk2=RO
  local rw_parts=() ro_parts=() path
  for path in "${!DISK_MODES[@]}"; do
    case "${DISK_MODES[$path]}" in
      RW) rw_parts+=("${path}=RW") ;;
      RO) ro_parts+=("${path}=RO") ;;
      NC) rw_parts+=("${path}=NC") ;;
    esac
  done
  local all=()
  [[ ${#rw_parts[@]} -gt 0 ]] && all+=("${rw_parts[@]}")
  [[ ${#ro_parts[@]} -gt 0 ]] && all+=("${ro_parts[@]}")
  local IFS=:
  echo "${all[*]-}"
}

_mergerfs_write_fstab() {
  local pool_path="$1"
  local branch_list
  branch_list=$(_mergerfs_build_branch_list)

  if [[ -z "$branch_list" ]]; then
    warn "No disks configured — fstab not updated."
    return 1
  fi

  # Remove any existing mergerfs entry for this pool
  sed -i "\|${pool_path}.*fuse.mergerfs|d" /etc/fstab

  # mergerfs v2 fstab format:
  #   source = path=RW:path=RW  (mode suffixes in source field, parsed by mergerfs)
  #   pool_path = the union mount point
  echo "${branch_list}  ${pool_path}  fuse.mergerfs  defaults,allow_other,use_ino,cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,fsname=mergerpool  0  0" >> /etc/fstab
  success "fstab updated."
}

_mergerfs_provision_branches() {
  # Creates the standard media subdirectory structure on every branch disk
  # and fixes ownership recursively. Must be called before/after mounting so
  # mergerfs can union-merge the directories across all drives.
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local uid="${PUID:-1000}" gid="${PGID:-1000}"
  _mergerfs_load_modes

  if [[ ${#DISK_MODES[@]} -eq 0 ]]; then
    warn "No disks configured — nothing to provision."
    return 1
  fi

  load_selected
  local subdirs=("movies" "tv")
  # Include downloads if any download client OR any arr that uses it is selected
  local _dl
  for _dl in qbittorrent qbittorrentvpn delugevpn nzbget sonarr radarr; do
    if [[ -n "${SELECTED[$_dl]+_}" ]]; then
      subdirs+=("downloads")
      break
    fi
  done
  # DelugeVPN uses /data/incomplete for in-progress downloads
  [[ -n "${SELECTED[delugevpn]+_}" ]] && subdirs+=("downloads/incomplete")
  local _p created=0

  for _p in "${!DISK_MODES[@]}"; do
    local _mode="${DISK_MODES[$_p]}"
    [[ ! -d "$_p" ]] && mkdir -p "$_p"

    if [[ "$_mode" == "RO" ]]; then
      # RO branch — only fix ownership on existing content, never create new dirs.
      # Creating subdirs on a RO branch would give mergerfs a writable-looking
      # directory entry and break RO semantics.
      chown -R "${uid}:${gid}" "$_p" 2>/dev/null || true
      success "  ${_p}  [${uid}:${gid}] (RO — ownership fixed, no subdirs created)"
    else
      # RW/NC branch — create the standard subdirectory structure
      local sub
      for sub in "${subdirs[@]}"; do
        mkdir -p "${_p}/${sub}"
      done
      chown -R "${uid}:${gid}" "$_p" 2>/dev/null || true
      success "  ${_p}  [${uid}:${gid}] (${_mode} — subdirs created, ownership fixed)"
    fi
    created=$((created + 1))
  done

  success "Branch provisioning complete (${created} disk(s), owner ${uid}:${gid})."
}

_mergerfs_remount() {
  local pool_path="$1"
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local uid="${PUID:-1000}" gid="${PGID:-1000}"

  # branch_list (with =MODE) is used by fstab; plain_paths for direct mount below
  local branch_list
  branch_list=$(_mergerfs_build_branch_list)

  if [[ -z "$branch_list" ]]; then
    warn "No disks configured — cannot mount pool."
    return 1
  fi

  mkdir -p "$pool_path"

  # Unmount first if already mounted
  if mountpoint -q "$pool_path" 2>/dev/null; then
    umount "$pool_path" 2>/dev/null || {
      warn "Could not unmount ${pool_path} — it may be in use."
      return 1
    }
  fi

  # mergerfs v2 binary accepts path=MODE in the source argument (same as fstab).
  # branch_list already contains the correct path=RW:path=RO format.
  local mount_out
  mount_out=$(mergerfs \
    -o allow_other,use_ino,cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,fsname=mergerpool \
    "${branch_list}" "${pool_path}" 2>&1)
  local mount_rc=$?
  if [[ $mount_rc -eq 0 ]]; then
    success "Pool mounted at ${pool_path}."
  else
    warn "mergerfs mount failed (exit ${mount_rc}):"
    warn "  ${mount_out}"
    warn "  Branch list: ${branch_list}"
    warn "  Mount point: ${pool_path}"
    return 1
  fi

  # Fix ownership of pool root after mounting
  chown "${uid}:${gid}" "$pool_path" 2>/dev/null || true
}

_mergerfs_show_status() {
  _mergerfs_load_modes
  _mergerfs_load_pool
  echo ""
  echo -e "${BOLD}MergerFS Pool: ${CYAN}${MERGERFS_POOL:-not configured}${RESET}"

  # Check if mergerfs is installed
  if ! command -v mergerfs &>/dev/null; then
    echo -e "  ${YELLOW}mergerfs is not installed. Use option 1 to install and configure.${RESET}"
    echo ""
    return 0
  fi

  echo "─────────────────────────────────────────────────────────────"
  printf "  ${BOLD}%-30s %-6s %-12s %-10s${RESET}\n" "Mount Point" "Mode" "Size" "Used"
  echo "─────────────────────────────────────────────────────────────"
  if [[ ${#DISK_MODES[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No disks configured yet.${RESET}"
  else
    local path mode col size used
    for path in $(printf '%s\n' "${!DISK_MODES[@]}" | sort); do
      mode="${DISK_MODES[$path]}"
      size="n/a"; used="n/a"
      if [[ -d "$path" ]]; then
        size=$(df -h "$path" 2>/dev/null | awk 'NR==2{print $2}') || size="n/a"
        used=$(df -h "$path" 2>/dev/null | awk 'NR==2{print $5}') || used="n/a"
      fi
      case "$mode" in
        RW) col="${GREEN}" ;; RO) col="${YELLOW}" ;; NC) col="${CYAN}" ;; *) col="${RESET}" ;;
      esac
      printf "  ${col}%-30s %-6s %-12s %-10s${RESET}\n" "$path" "$mode" "$size" "$used"
    done
  fi
  echo "─────────────────────────────────────────────────────────────"
  echo -e "  ${DIM}RW = Read/Write  |  RO = Read-Only  |  NC = No-Create (reads only, no new files)${RESET}"
  echo ""
}

_mergerfs_add_disk() {
  _mergerfs_load_modes; _mergerfs_load_pool
  echo ""
  echo -e "${BOLD}Add Disk to Pool${RESET}"
  read -rp "Disk mount path (e.g. /mnt/disk3): " disk
  [[ -z "$disk" ]] && { warn "No path entered."; return; }
  if [[ ! -d "$disk" ]]; then
    warn "${disk} does not exist. Creating it..."
    mkdir -p "$disk"
  fi
  chown "${PUID:-1000}:${PGID:-1000}" "$disk" 2>/dev/null || true
  echo ""
  echo "  Mode for ${disk}:"
  echo "  1) RW — Read/Write  (normal, files can be created here)"
  echo "  2) NC — No-Create   (reads fine, no new files written here)"
  echo "  3) RO — Read-Only   (existing files readable, no writes at all)"
  read -rp "  Mode (press Enter for default) [1]: " msel
  local mode
  case "${msel:-1}" in
    1) mode="RW" ;; 2) mode="NC" ;; 3) mode="RO" ;; *) warn "Defaulting to RW."; mode="RW" ;;
  esac
  DISK_MODES[$disk]="$mode"
  _mergerfs_save_modes
  [[ -n "$MERGERFS_POOL" ]] && { _mergerfs_write_fstab "$MERGERFS_POOL"; _mergerfs_remount "$MERGERFS_POOL"; }
  success "Disk ${disk} added as ${mode}."
}

_mergerfs_change_mode() {
  _mergerfs_load_modes; _mergerfs_load_pool
  [[ ${#DISK_MODES[@]} -eq 0 ]] && { warn "No disks configured yet."; return; }
  echo ""
  echo -e "${BOLD}Change Disk Mode${RESET}"
  local i=1
  declare -A IDX=()
  local path
  for path in $(printf '%s\n' "${!DISK_MODES[@]}" | sort); do
    echo "  ${i}) ${path}  [${DISK_MODES[$path]}]"
    IDX[$i]=$path; i=$((i + 1))
  done
  echo ""
  read -rp "Select disk number: " sel
  [[ -z "${IDX[$sel]+_}" ]] && { warn "Invalid selection."; return; }
  local chosen="${IDX[$sel]}"
  echo ""
  echo "  1) RW — Read/Write  2) NC — No-Create  3) RO — Read-Only"
  read -rp "  New mode [current: ${DISK_MODES[$chosen]}]: " msel
  case "${msel:-}" in
    1) DISK_MODES[$chosen]="RW" ;;
    2) DISK_MODES[$chosen]="NC" ;;
    3) DISK_MODES[$chosen]="RO" ;;
    *) warn "No change made."; return ;;
  esac
  _mergerfs_save_modes
  [[ -n "$MERGERFS_POOL" ]] && { _mergerfs_write_fstab "$MERGERFS_POOL"; _mergerfs_remount "$MERGERFS_POOL"; }
  success "${chosen} is now ${DISK_MODES[$chosen]}."
}

_mergerfs_remove_disk() {
  _mergerfs_load_modes; _mergerfs_load_pool
  [[ ${#DISK_MODES[@]} -eq 0 ]] && { warn "No disks configured yet."; return; }
  echo ""
  echo -e "${BOLD}Remove Disk from Pool${RESET}"
  local i=1
  declare -A IDX=()
  local path
  for path in $(printf '%s\n' "${!DISK_MODES[@]}" | sort); do
    echo "  ${i}) ${path}  [${DISK_MODES[$path]}]"
    IDX[$i]=$path; i=$((i + 1))
  done
  echo ""
  read -rp "Select disk number to remove: " sel
  [[ -z "${IDX[$sel]+_}" ]] && { warn "Invalid selection."; return; }
  local chosen="${IDX[$sel]}"
  warn "Removing ${chosen} from the pool. Data on this disk is NOT deleted."
  read -rp "Confirm? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return; }
  unset "DISK_MODES[$chosen]"
  _mergerfs_save_modes
  [[ -n "$MERGERFS_POOL" ]] && { _mergerfs_write_fstab "$MERGERFS_POOL"; _mergerfs_remount "$MERGERFS_POOL"; }
  success "${chosen} removed from pool."
}

_mergerfs_initial_setup() {
  # ── Already-configured guard ─────────────────────────────────────────────────
  _mergerfs_load_pool
  if [[ -n "$MERGERFS_POOL" && ${#DISK_MODES[@]} -gt 0 ]] 2>/dev/null; then
    _mergerfs_load_modes
    if [[ ${#DISK_MODES[@]} -gt 0 ]]; then
      echo ""
      warn "A MergerFS pool is already configured at: ${BOLD}${MERGERFS_POOL}${RESET}"
      warn "Re-running initial setup will replace the existing pool configuration."
      echo ""
      read -rp "  Reconfigure the pool from scratch? [y/N] " yn
      [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted — use options 2–5 to modify the existing pool."; return 0; }
      echo ""
    fi
  fi

  info "Installing mergerfs..."
  if ! apt-get install -y mergerfs 2>/dev/null; then
    warn "Could not install mergerfs automatically."
    warn "Install it manually: sudo apt-get install mergerfs"
    warn "Then return to this menu to configure the pool."
    return
  fi
  _mergerfs_load_modes
  _ensure_install_dir
  echo ""
  echo -e "${BOLD}MergerFS Pool Configuration${RESET}"
  echo "Enter each disk path you want to pool, one at a time."
  echo "Press Enter with no input when done adding disks."
  echo -e "${DIM}  For mode selection, press Enter to accept the default [1].${RESET}"
  echo ""
  local added=0 disk mode
  while true; do
    read -rp "Disk mount path (or Enter to finish): " disk
    [[ -z "$disk" ]] && break
    if [[ ! -d "$disk" ]]; then
      warn "${disk} does not exist. Creating it..."
      mkdir -p "$disk"
    fi
    chown "${PUID:-1000}:${PGID:-1000}" "$disk" 2>/dev/null || true
    echo "  1) RW — Read/Write (default)  2) NC — No-Create  3) RO — Read-Only"
    read -rp "  Mode [1]: " msel
    case "${msel:-1}" in
      1) mode="RW" ;; 2) mode="NC" ;; 3) mode="RO" ;; *) warn "Defaulting to RW."; mode="RW" ;;
    esac
    DISK_MODES[$disk]="$mode"
    success "  → ${disk} added as ${mode}"
    added=$((added + 1))
    echo ""
  done

  if [[ $added -eq 0 ]]; then
    warn "No disks entered — pool setup cancelled."
    return
  fi

  # Source .env so MEDIA_ROOT reflects any value already configured
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local current_media="${MEDIA_ROOT:-/mnt/media}"
  echo ""
  read -rp "Pool mount path [${current_media}]: " pool_input
  local pool_path="${pool_input:-${current_media}}"
  mkdir -p "$pool_path"
  chown "${PUID:-1000}:${PGID:-1000}" "$pool_path" 2>/dev/null || true

  _mergerfs_save_modes
  _mergerfs_save_pool "$pool_path"
  _mergerfs_write_fstab "$pool_path"
  _mergerfs_remount "$pool_path"

  # Keep MEDIA_ROOT in .env in sync with the actual pool path so containers
  # mount the right directory.
  if [[ -f "$ENV_FILE" ]]; then
    if grep -q "^MEDIA_ROOT=" "$ENV_FILE" 2>/dev/null; then
      sed -i "s|^MEDIA_ROOT=.*|MEDIA_ROOT=${pool_path}|" "$ENV_FILE"
    else
      echo "MEDIA_ROOT=${pool_path}" >> "$ENV_FILE"
    fi
    MEDIA_ROOT="$pool_path"
    success "MEDIA_ROOT updated to ${pool_path} in .env"
  fi

  success "MergerFS pool configured at ${pool_path}."
}

_mergerfs_show_pool_detail() {
  _mergerfs_load_modes
  _mergerfs_load_pool

  echo ""
  echo -e "${BOLD}${CYAN}MergerFS Pool Detail${RESET}"
  echo "══════════════════════════════════════════════════════════════"

  # ── Installation status ──────────────────────────────────────────────────────
  if command -v mergerfs &>/dev/null; then
    local mfs_ver
    mfs_ver=$(mergerfs --version 2>&1 | awk '{print $NF}' | head -1)
    echo -e "  ${BOLD}mergerfs version :${RESET} ${GREEN}${mfs_ver:-installed}${RESET}"
  else
    echo -e "  ${BOLD}mergerfs         :${RESET} ${YELLOW}not installed${RESET}"
  fi

  # ── Pool mount point ─────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Pool path        :${RESET} ${MERGERFS_POOL:-${YELLOW}not configured${RESET}}"

  if [[ -n "$MERGERFS_POOL" ]]; then
    if mountpoint -q "$MERGERFS_POOL" 2>/dev/null; then
      echo -e "  ${BOLD}Pool mounted     :${RESET} ${GREEN}yes${RESET}"
      local pool_size pool_used pool_avail pool_pct
      pool_size=$(df -h "$MERGERFS_POOL" 2>/dev/null | awk 'NR==2{print $2}') || pool_size="n/a"
      pool_used=$(df -h "$MERGERFS_POOL" 2>/dev/null | awk 'NR==2{print $3}') || pool_used="n/a"
      pool_avail=$(df -h "$MERGERFS_POOL" 2>/dev/null | awk 'NR==2{print $4}') || pool_avail="n/a"
      pool_pct=$(df -h  "$MERGERFS_POOL" 2>/dev/null | awk 'NR==2{print $5}') || pool_pct="n/a"
      echo -e "  ${BOLD}Pool size        :${RESET} ${pool_size}  used: ${pool_used}  free: ${pool_avail}  (${pool_pct} full)"
    else
      echo -e "  ${BOLD}Pool mounted     :${RESET} ${YELLOW}no — run option 1 or reboot to mount${RESET}"
    fi
  fi

  # ── Configured drives ────────────────────────────────────────────────────────
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  printf "  ${BOLD}%-32s %-6s %-10s %-10s %-8s${RESET}\n" "Drive Path" "Mode" "Size" "Used" "Avail"
  echo "──────────────────────────────────────────────────────────────"

  if [[ ${#DISK_MODES[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No drives configured yet. Use option 1 to set up the pool.${RESET}"
  else
    local path mode col size used avail mounted_marker
    for path in $(printf '%s\n' "${!DISK_MODES[@]}" | sort); do
      mode="${DISK_MODES[$path]}"
      size="n/a"; used="n/a"; avail="n/a"; mounted_marker=""

      if [[ -d "$path" ]]; then
        # Use findmnt to check if a filesystem is mounted at exactly this path.
        # mountpoint -q fails for paths that are directories but not mount roots.
        # findmnt also lets us show what device is mounted there.
        local fmnt_dev
        fmnt_dev=$(findmnt -n -o SOURCE "$path" 2>/dev/null)
        if [[ -n "$fmnt_dev" ]]; then
          mounted_marker=" ${GREEN}● ${fmnt_dev}${RESET}"
          # Only use df on confirmed-mounted paths for accurate per-drive stats
          size=$(df  -h "$path" 2>/dev/null | awk 'NR==2{print $2}') || size="n/a"
          used=$(df  -h "$path" 2>/dev/null | awk 'NR==2{print $3}') || used="n/a"
          avail=$(df -h "$path" 2>/dev/null | awk 'NR==2{print $4}') || avail="n/a"
        else
          mounted_marker=" ${YELLOW}○ not mounted${RESET}"
          size="n/a"; used="n/a"; avail="n/a"
        fi
      else
        mounted_marker=" ${RED}? path missing${RESET}"
      fi

      case "$mode" in
        RW) col="${GREEN}" ;; RO) col="${YELLOW}" ;; NC) col="${CYAN}" ;; *) col="${RESET}" ;;
      esac

      printf "  ${col}%-32s %-6s %-10s %-10s %-8s${RESET}" "$path" "$mode" "$size" "$used" "$avail"
      echo -e "${mounted_marker}"
    done
  fi

  echo "──────────────────────────────────────────────────────────────"
  echo -e "  ${DIM}${GREEN}●${RESET}${DIM} = drive mounted   ${DIM}○${RESET}${DIM} = not mounted   ${YELLOW}?${RESET}${DIM} = path not found${RESET}"
  echo -e "  ${DIM}RW = Read/Write  |  NC = No-Create  |  RO = Read-Only${RESET}"

  # ── Live mount info from the kernel ─────────────────────────────────────────
  if [[ -n "$MERGERFS_POOL" ]] && command -v findmnt &>/dev/null; then
    local fstab_line
    fstab_line=$(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MERGERFS_POOL" 2>/dev/null)
    if [[ -n "$fstab_line" ]]; then
      echo ""
      echo -e "  ${BOLD}Live mount entry:${RESET}"
      echo -e "  ${DIM}${fstab_line}${RESET}"
    fi
  fi
  echo ""
}


_mergerfs_mount_pool() {
  _mergerfs_load_modes
  _mergerfs_load_pool
  echo ""
  echo -e "${BOLD}Mount / Remount MergerFS Pool${RESET}"
  echo ""
  if [[ -z "$MERGERFS_POOL" ]]; then
    warn "No pool configured. Run option 1 (Initial pool setup) first."
    return 1
  fi
  if [[ ${#DISK_MODES[@]} -eq 0 ]]; then
    warn "No disks in pool. Run option 1 or 2 to add disks first."
    return 1
  fi
  echo -e "  Pool path : ${CYAN}${MERGERFS_POOL}${RESET}"
  echo -e "  Disks     : ${#DISK_MODES[@]}"
  echo ""
  if mountpoint -q "$MERGERFS_POOL" 2>/dev/null; then
    info "Pool is currently mounted. Remounting..."
  else
    info "Pool is not mounted. Mounting now..."
  fi
  info "(Run option 7 to create subdirs and fix ownership on branch disks.)"
  _mergerfs_remount "$MERGERFS_POOL"
}

_mergerfs_clear_mountpoint() {
  _mergerfs_load_pool
  local pool_path="${MERGERFS_POOL:-/mnt/media}"
  echo ""
  echo -e "${BOLD}Unmount MergerFS Pool${RESET}"
  echo -e "${DIM}  Cleanly unmounts ${pool_path} without touching data on any branch disk.${RESET}"
  echo ""

  # ── Guard: not mounted ───────────────────────────────────────────────────────
  if ! mountpoint -q "$pool_path" 2>/dev/null; then
    info "${pool_path} is not currently mounted — nothing to unmount."
    return 0
  fi

  # ── Show what is mounted ─────────────────────────────────────────────────────
  local fstype; fstype=$(findmnt -no FSTYPE "$pool_path" 2>/dev/null)
  local source;  source=$(findmnt -no SOURCE "$pool_path" 2>/dev/null)
  echo -e "  Mount point : ${CYAN}${pool_path}${RESET}"
  echo -e "  FS type     : ${fstype:-unknown}"
  echo -e "  Source      : ${source:-unknown}"
  echo ""

  # ── Check for processes with open file handles ───────────────────────────────
  local open_procs=""
  if command -v lsof &>/dev/null; then
    open_procs=$(lsof +D "$pool_path" 2>/dev/null | awk 'NR>1 {print $1, $2}' | sort -u)
  fi

  if [[ -n "$open_procs" ]]; then
    warn "The following processes have open files on ${pool_path}:"
    echo "$open_procs" | while IFS= read -r line; do
      echo -e "    ${YELLOW}${line}${RESET}"
    done
    echo ""
    warn "Unmounting while these are running may interrupt them."
    echo ""
    echo "  Options:"
    echo "  1) Stop Docker containers using the pool first, then unmount"
    echo "  2) Force unmount now (lazy — detaches immediately, safe for data)"
    echo "  3) Abort"
    echo ""
    read -rp "  Choice [1/2/3]: " choice
    case "$choice" in
      1)
        echo ""
        info "Stopping all running Docker containers..."
        docker stop $(docker ps -q 2>/dev/null) 2>/dev/null || true
        sleep 2
        ;;
      2)
        echo ""
        warn "Proceeding with lazy unmount..."
        ;;
      3|*)
        info "Aborted — pool remains mounted."
        return 0
        ;;
    esac
  else
    echo ""
    read -rp "  Unmount ${pool_path}? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted — pool remains mounted."; return 0; }
    echo ""
  fi

  # ── Attempt clean unmount, fall back to lazy ─────────────────────────────────
  info "Unmounting ${pool_path}..."
  if umount "$pool_path" 2>/dev/null; then
    success "Pool unmounted cleanly."
  else
    info "Clean unmount busy — trying lazy unmount (umount -l)..."
    if umount -l "$pool_path" 2>/dev/null; then
      success "Pool detached (lazy unmount). Processes will finish with existing handles."
    else
      warn "Could not unmount ${pool_path}."
      warn "Still in use — check with: lsof +D ${pool_path}"
      return 1
    fi
  fi

  # ── Confirm no longer mounted ────────────────────────────────────────────────
  if mountpoint -q "$pool_path" 2>/dev/null; then
    warn "${pool_path} still appears mounted after unmount attempt."
    return 1
  fi

  echo ""
  success "${pool_path} is now unmounted. Branch disks are untouched."
  info "Run option 6 (Mount / remount pool) to mount again."
}

setup_mergerfs() {
  require_root
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               💾  MergerFS Storage Manager              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    _mergerfs_show_status
    echo "  1) Initial pool setup (first time)"
    echo "  2) Add a disk to the pool"
    echo "  3) Change a disk's mode (RW / RO)"
    echo "  4) Remove a disk from the pool"
    echo "  5) Show pool & drive details"
    echo "  6) Mount / remount pool"
    echo "  7) Fix ownership & create subdirs on all drives"
    echo "  8) Unmount pool"
    echo "  9) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) _mergerfs_initial_setup      || true; pause ;;
      2) _mergerfs_add_disk           || true; pause ;;
      3) _mergerfs_change_mode        || true; pause ;;
      4) _mergerfs_remove_disk        || true; pause ;;
      5) _mergerfs_show_pool_detail   || true; pause ;;
      6) _mergerfs_mount_pool         || true; pause ;;
      7) _mergerfs_provision_branches || true; pause ;;
      8) _mergerfs_clear_mountpoint   || true; pause ;;
      9) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Environment & Network
# =============================================================================

configure_env() {
  echo ""
  echo -e "${BOLD}Environment Configuration${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  [[ -f "$ENV_FILE" ]]   && source "$ENV_FILE"   2>/dev/null || true
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true

  read -rp "Your domain (e.g. example.com) [${DOMAIN:-}]: " input
  DOMAIN="${input:-${DOMAIN:-example.com}}"
  DOMAIN="${DOMAIN//[[:space:]]/}"    # strip any accidental whitespace
  read -rp "ACME/Let's Encrypt email [${ACME_EMAIL:-}]: " input
  ACME_EMAIL="${input:-${ACME_EMAIL:-admin@example.com}}"
  ACME_EMAIL="${ACME_EMAIL//[[:space:]]/}"  # strip any accidental whitespace
  read -rp "Config root path [${CONFIG_ROOT:-/opt/friendbox/config}]: " input
  CONFIG_ROOT="${input:-${CONFIG_ROOT:-/opt/friendbox/config}}"
  read -rp "Media root path [${MEDIA_ROOT:-/mnt/media}]: " input
  MEDIA_ROOT="${input:-${MEDIA_ROOT:-/mnt/media}}"
  read -rp "PUID [${PUID:-1000}]: " input; PUID="${input:-${PUID:-1000}}"
  read -rp "PGID [${PGID:-1000}]: " input; PGID="${input:-${PGID:-1000}}"
  if ! [[ "$PUID" =~ ^[0-9]+$ ]] || ! [[ "$PGID" =~ ^[0-9]+$ ]]; then
    warn "PUID and PGID must be integers. Defaulting to 1000:1000."
    PUID=1000; PGID=1000
  fi
  read -rp "Timezone [${TZ:-America/Toronto}]: " input
  TZ="${input:-${TZ:-America/Toronto}}"
  # Derive USE_TRAEFIK from saved container selection — no prompts here.
  # Traefik dashboard credentials are configured separately via menu option 4.
  load_selected
  local USE_TRAEFIK="false"
  [[ -n "${SELECTED[traefik]+_}" ]] && USE_TRAEFIK="true"

  # Only prompt for and persist PLEX_CLAIM when Plex is selected AND not yet
  # claimed. Once the container has run and been claimed, the token is consumed
  # and the env var is no longer needed. Also skip if Plex isn't selected at all.
  local plex_running=false
  if docker inspect plex --format '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
    plex_running=true
  fi
  if [[ -n "${SELECTED[plex]+_}" && "$plex_running" == "false" ]]; then
    echo ""
    echo -e "  ${BOLD}Plex Claim Token${RESET}"
    echo -e "  ${DIM}Get a fresh token from: https://www.plex.tv/claim  (expires in ~4 minutes)${RESET}"
    echo -e "  ${DIM}Enter it right before completing setup so it doesn't expire.${RESET}"
    echo -e "  ${DIM}Leave blank to skip — you can claim via the Plex web UI after first start.${RESET}"
    echo ""
    read -rp "  Plex claim token [${PLEX_CLAIM:-none}]: " input
    PLEX_CLAIM="${input:-${PLEX_CLAIM:-}}"
  fi

  # Preserve existing TRAEFIK_AUTH by reading it raw from the file —
  # NOT from the bash-eval'd environment. Bcrypt hashes contain $$ sequences
  # that get unescaped when .env is sourced, corrupting the hash if written back.
  local existing_auth
  existing_auth=$(grep '^TRAEFIK_AUTH=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
  existing_auth="${existing_auth:-disabled}"

  _ensure_install_dir

  # Write base keys — preserve any extra keys (provider creds, DNS config, etc.)
  # that were appended by other menu functions.
  _env_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
      echo "${key}=${val}" >> "$ENV_FILE"
    fi
  }

  # Seed the file if it doesn't exist yet
  if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"   # contains API keys, VPN creds, hashed passwords
  fi

  _env_set PUID         "${PUID}"
  _env_set PGID         "${PGID}"
  _env_set TZ           "${TZ}"
  _env_set DOMAIN       "${DOMAIN}"
  _env_set ACME_EMAIL   "${ACME_EMAIL}"
  _env_set CONFIG_ROOT  "${CONFIG_ROOT}"
  _env_set MEDIA_ROOT   "${MEDIA_ROOT}"
  _env_set USE_TRAEFIK  "${USE_TRAEFIK}"
  _env_set TRAEFIK_AUTH "${existing_auth}"
  [[ -n "${SELECTED[plex]+_}" && "$plex_running" == "false" ]] && _env_set PLEX_CLAIM "${PLEX_CLAIM:-}"

  _own "$ENV_FILE"
  success ".env updated (${ENV_FILE})"
  if [[ "$USE_TRAEFIK" == "true" ]]; then
    info "Traefik is selected — use menu option 4 (Traefik configuration) to set dashboard credentials."
  fi
}

# =============================================================================
#  Traefik Configuration
# =============================================================================

# Generates /opt/friendbox/config/traefik/traefik.yml from current .env values.
# Must be called after any Traefik setting changes and before containers start.
# Removes any directory that may exist at the file path before writing.
_traefik_write_config() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  # TRAEFIK_CERT_RESOLVER must be set in .env so docker-compose.yml labels expand
  # correctly.  For DuckDNS we strip those labels from the compose file entirely
  # (wildcard cert via entrypoint, not per-router); for all other providers the
  # labels stay and the var must equal the resolver name ("letsencrypt").
  local _provider="${TRAEFIK_ACME_PROVIDER:-http}"
  sed -i '/^TRAEFIK_CERT_RESOLVER=/d' "$ENV_FILE" 2>/dev/null || true
  if [[ "$_provider" != "duckdns" ]]; then
    echo "TRAEFIK_CERT_RESOLVER=letsencrypt" >> "$ENV_FILE"
  fi

  local traefik_dir="${INSTALL_DIR}/config/traefik"
  local traefik_cfg="${traefik_dir}/traefik.yml"

  mkdir -p "$traefik_dir"

  # If a directory was accidentally created at the file path, remove it
  if [[ -d "$traefik_cfg" ]]; then
    rm -rf "$traefik_cfg"
    warn "Removed directory at ${traefik_cfg} — replacing with config file."
  fi

  local provider="${TRAEFIK_ACME_PROVIDER:-http}"
  local email="${ACME_EMAIL:-admin@example.com}"

  # Staging CA has much higher rate limits — use for testing until certs work.
  # Switch to production once you confirm the full ACME flow succeeds.
  local ca_server
  if [[ "${ACME_STAGING:-false}" == "true" ]]; then
    ca_server="https://acme-staging-v02.api.letsencrypt.org/directory"
    warn "ACME staging CA active — certs will be issued but NOT trusted by browsers."
    warn "Set ACME_STAGING=false and clear acme.json when ready for production."
  else
    ca_server="https://acme-v02.api.letsencrypt.org/directory"
  fi

  # ── Build the certificatesResolvers block based on provider ─────────────────
  local resolvers_block
  case "$provider" in
    cloudflare)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      caServer: ${ca_server}
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - \"1.1.1.1:53\"
          - \"1.0.0.1:53\""
      ;;
    duckdns)
      # DuckDNS can only set TXT records on the root domain, not sub-subdomains.
      # Per-host cert requests (traefik.domain.duckdns.org) always fail because
      # lego looks for _acme-challenge.traefik.domain.duckdns.org which DuckDNS
      # cannot create. The only working approach is a single wildcard cert
      # (*.domain.duckdns.org) requested at the entrypoint level.
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      caServer: ${ca_server}
      dnsChallenge:
        provider: duckdns
        propagation:
          delayBeforeChecks: 60s
        resolvers:
          - \"1.1.1.1:53\"
          - \"8.8.8.8:53\""
      ;;
    godaddy)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      caServer: ${ca_server}
      dnsChallenge:
        provider: godaddy
        resolvers:
          - \"8.8.8.8:53\""
      ;;
    namecheap)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      caServer: ${ca_server}
      dnsChallenge:
        provider: namecheap
        resolvers:
          - \"8.8.8.8:53\""
      ;;
    http|*)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      caServer: ${ca_server}
      httpChallenge:
        entryPoint: web"
      ;;
  esac

  # For DuckDNS: declare the wildcard domain on the entrypoint so Traefik requests
  # *.domain.duckdns.org once. Individual routers must have tls=true but NO
  # certresolver label — an empty certresolver value still triggers per-router
  # ACME attempts. We patch the compose file directly to strip or restore the
  # certresolver label lines depending on the provider.
  local tls_block
  if [[ "$provider" == "duckdns" ]]; then
    tls_block="    http:
      tls:
        domains:
          - main: \"${DOMAIN}\"
            sans:
              - \"*.${DOMAIN}\""
    # Strip certresolver labels from compose file — routers inherit wildcard from entrypoint
    sed -i '/traefik\.http\.routers\.[^.]*\.tls\.certresolver=/d' "$COMPOSE_FILE"
    info "DuckDNS: removed certresolver labels from routers (wildcard cert via entrypoint)."
  else
    tls_block=""
    # Restore certresolver labels if they were previously stripped for DuckDNS
    # Check each router and add back the label if missing
    python3 - "$COMPOSE_FILE" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Find all router names that have tls=true but no certresolver label
routers = re.findall(r'traefik\.http\.routers\.([^.]+)\.tls=true', content)
for router in routers:
    certresolver_label = f'traefik.http.routers.{router}.tls.certresolver=${{TRAEFIK_CERT_RESOLVER}}'
    tls_label = f'traefik.http.routers.{router}.tls=true'
    if certresolver_label not in content:
        content = content.replace(
            f'- "{tls_label}"',
            f'- "{tls_label}"\n      - "{certresolver_label}"'
        )
with open(path, 'w') as f:
    f.write(content)
print("certresolver labels restored.")
PYEOF
  fi

  cat > "$traefik_cfg" <<EOF
# traefik.yml — generated by friendbox
# Provider: ${provider}
# Do not edit manually — regenerated by 'sudo friendbox' → option 4.

api:
  dashboard: true
  insecure: true

ping: {}

log:
  level: INFO

accessLog: {}

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
${tls_block:+${tls_block}
}
  traefik:
    address: ":8080"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: false

certificatesResolvers:
${resolvers_block}
EOF

  _own "$traefik_cfg"

  # ── Write dynamic config — security headers middleware ───────────────────────
  local dynamic_dir="${traefik_dir}/dynamic"
  mkdir -p "$dynamic_dir"
  # Only write headers.yml when it does not already exist — preserves any
  # user customisations to CSP, frame options, or custom headers.
  # To reset to defaults: rm ${CONFIG_ROOT}/traefik/dynamic/headers.yml
  if [[ ! -f "${dynamic_dir}/headers.yml" ]]; then
    cat > "${dynamic_dir}/headers.yml" <<'HDEOF'
http:
  middlewares:
    secHeaders:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        customFrameOptionsValue: "SAMEORIGIN"
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=(), payment=()"
        customResponseHeaders:
          X-Robots-Tag: "noindex,nofollow,nosnippet,noarchive,notranslate,noimageindex"
HDEOF
  fi
  _own "$dynamic_dir"

  success "traefik.yml written (provider: ${provider})."
}

_traefik_show_status() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected
  echo ""
  local auth_set="not set"
  [[ -n "${TRAEFIK_AUTH:-}" && "${TRAEFIK_AUTH:-}" != "disabled" ]] && auth_set="configured"

  local provider_label="${TRAEFIK_ACME_PROVIDER:-not set}"

  if [[ -n "${SELECTED[traefik]+_}" ]]; then
    echo -e "  ${BOLD}Status        :${RESET} ${GREEN}selected (will deploy)${RESET}"
  else
    echo -e "  ${BOLD}Status        :${RESET} ${YELLOW}not selected${RESET}"
  fi
  local traefik_cfg="${INSTALL_DIR}/config/traefik/traefik.yml"
  if [[ -f "$traefik_cfg" ]]; then
    echo -e "  ${BOLD}traefik.yml   :${RESET} ${GREEN}exists${RESET}"
  else
    echo -e "  ${BOLD}traefik.yml   :${RESET} ${RED}MISSING — save any setting below to generate${RESET}"
  fi
  if [[ -z "${DOMAIN:-}" || "${DOMAIN:-}" == "example.com" ]]; then
    echo -e "  ${BOLD}Domain        :${RESET} ${RED}${DOMAIN:-not set}  ← set via option 2${RESET}"
  else
    echo -e "  ${BOLD}Domain        :${RESET} ${DOMAIN}"
  fi
  if [[ -z "${ACME_EMAIL:-}" || "${ACME_EMAIL:-}" == "admin@example.com" ]]; then
    echo -e "  ${BOLD}ACME email    :${RESET} ${RED}${ACME_EMAIL:-not set}  ← set via option 2${RESET}"
  else
    echo -e "  ${BOLD}ACME email    :${RESET} ${ACME_EMAIL}"
  fi
  echo -e "  ${BOLD}ACME provider :${RESET} ${provider_label}"
  echo -e "  ${BOLD}Dashboard     :${RESET} ${auth_set}"
  if [[ "${ACME_STAGING:-false}" == "true" ]]; then
    echo -e "  ${BOLD}ACME CA       :${RESET} ${YELLOW}STAGING (untrusted certs — use option 4 to switch to production)${RESET}"
  else
    echo -e "  ${BOLD}ACME CA       :${RESET} ${GREEN}production${RESET}"
  fi
  local _redir_host="${ROOT_REDIRECT_HOST:-portainer}"
  echo -e "  ${BOLD}Root redirect :${RESET} https://${_redir_host}.${DOMAIN:-yourdomain.com}  ${DIM}(option 4 → 8 to change)${RESET}"

  # Per-provider credential summary
  case "${TRAEFIK_ACME_PROVIDER:-}" in
    cloudflare)
      if [[ -n "${CF_DNS_API_TOKEN:-}" ]]; then
        echo -e "  ${BOLD}CF API token  :${RESET} [set]"
      else
        echo -e "  ${BOLD}CF API token  :${RESET} not set"
      fi
      echo -e "  ${BOLD}CF API email  :${RESET} ${CF_API_EMAIL:-not set}"
      ;;
    duckdns)
      if [[ -n "${DUCKDNS_TOKEN:-}" ]]; then
        echo -e "  ${BOLD}DuckDNS token :${RESET} [set]"
      else
        echo -e "  ${BOLD}DuckDNS token :${RESET} not set"
      fi
      ;;
    godaddy)
      echo -e "  ${BOLD}GoDaddy key   :${RESET} ${GODADDY_API_KEY:-not set}"
      if [[ -n "${GODADDY_API_SECRET:-}" ]]; then
        echo -e "  ${BOLD}GoDaddy secret:${RESET} [set]"
      else
        echo -e "  ${BOLD}GoDaddy secret:${RESET} not set"
      fi
      ;;
    namecheap)
      echo -e "  ${BOLD}NC API user   :${RESET} ${NAMECHEAP_API_USER:-not set}"
      if [[ -n "${NAMECHEAP_API_KEY:-}" ]]; then
        echo -e "  ${BOLD}NC API key    :${RESET} [set]"
      else
        echo -e "  ${BOLD}NC API key    :${RESET} not set"
      fi
      ;;
    http|"")
      echo -e "  ${DIM}  HTTP challenge — no extra credentials needed.${RESET}"
      ;;
  esac
  echo ""
}


_traefik_validate() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local pass=0 fail=0

  _chk() {
    # _chk "label" 0|1 "detail"
    local label="$1" ok="$2" detail="${3:-}"
    if [[ "$ok" == "1" ]]; then
      echo -e "  ${GREEN}[PASS]${RESET} ${label}${detail:+  ${DIM}${detail}${RESET}}"
      pass=$((pass + 1))
    else
      echo -e "  ${RED}[FAIL]${RESET} ${label}${detail:+  ${DIM}${detail}${RESET}}"
      fail=$((fail + 1))
    fi
  }

  echo ""
  echo -e "${BOLD}Traefik Pre-flight Checks${RESET}"
  echo ""

  # ── 1. traefik.yml exists ────────────────────────────────────────────────────
  local cfg="${INSTALL_DIR}/config/traefik/traefik.yml"
  if [[ -f "$cfg" ]]; then
    _chk "traefik.yml exists" 1 "$cfg"
  else
    _chk "traefik.yml exists" 0 "run option 2 or 3 to generate it"
  fi

  # ── 2. acme.json exists and has correct permissions ──────────────────────────
  local acme="${INSTALL_DIR}/config/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    local perms; perms=$(stat -c "%a" "$acme" 2>/dev/null)
    local owner; owner=$(stat -c "%U:%G" "$acme" 2>/dev/null)
    if [[ "$perms" == "600" && "$owner" == "root:root" ]]; then
      _chk "acme.json exists (root:root 600)" 1 "$acme"
    elif [[ "$perms" != "600" ]]; then
      _chk "acme.json permissions" 0 "got ${perms}, need 600 — run: chmod 600 $acme"
    else
      _chk "acme.json ownership" 0 "got ${owner}, need root:root — run: chown root:root $acme"
    fi
  else
    _chk "acme.json exists" 0 "run option 8 (Provision / fix directory ownership) to create it"
  fi

  # ── 3. Domain is set and not placeholder ─────────────────────────────────────
  if [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]]; then
    _chk "Domain configured" 1 "${DOMAIN}"
  else
    _chk "Domain configured" 0 "set a real domain via option 2"
  fi

  # ── 4. ACME email is set and not placeholder ─────────────────────────────────
  if [[ -n "${ACME_EMAIL:-}" && "${ACME_EMAIL:-}" != "admin@example.com" ]]; then
    _chk "ACME email configured" 1 "${ACME_EMAIL}"
  else
    _chk "ACME email configured" 0 "set a real email via option 2"
  fi

  # ── 5. ACME provider is set ───────────────────────────────────────────────────
  local provider="${TRAEFIK_ACME_PROVIDER:-}"
  if [[ -n "$provider" ]]; then
    _chk "ACME provider set" 1 "${provider}"
  else
    _chk "ACME provider set" 0 "configure via option 3"
  fi

  # ── 6. Provider credentials present ──────────────────────────────────────────
  case "$provider" in
    cloudflare)
      [[ -n "${CF_DNS_API_TOKEN:-}" ]] \
        && _chk "Cloudflare API token" 1 \
        || _chk "Cloudflare API token" 0 "set via option 3"
      [[ -n "${CF_API_EMAIL:-}" ]] \
        && _chk "Cloudflare email" 1 "${CF_API_EMAIL}" \
        || _chk "Cloudflare email" 0 "set via option 3"
      ;;
    duckdns)
      [[ -n "${DUCKDNS_TOKEN:-}" ]] \
        && _chk "DuckDNS token" 1 \
        || _chk "DuckDNS token" 0 "set via option 3"
      ;;
    godaddy)
      [[ -n "${GODADDY_API_KEY:-}" ]] \
        && _chk "GoDaddy API key" 1 "${GODADDY_API_KEY}" \
        || _chk "GoDaddy API key" 0 "set via option 3"
      [[ -n "${GODADDY_API_SECRET:-}" ]] \
        && _chk "GoDaddy API secret" 1 \
        || _chk "GoDaddy API secret" 0 "set via option 3"
      ;;
    namecheap)
      [[ -n "${NAMECHEAP_API_USER:-}" ]] \
        && _chk "Namecheap API user" 1 "${NAMECHEAP_API_USER}" \
        || _chk "Namecheap API user" 0 "set via option 3"
      [[ -n "${NAMECHEAP_API_KEY:-}" ]] \
        && _chk "Namecheap API key" 1 \
        || _chk "Namecheap API key" 0 "set via option 3"
      [[ -n "${NAMECHEAP_API_IP:-}" ]] \
        && _chk "Namecheap API source IP" 1 "${NAMECHEAP_API_IP}" \
        || _chk "Namecheap API source IP" 0 "required by Namecheap API — set via option 3"
      ;;
    http)
      _chk "HTTP challenge (no creds needed)" 1
      ;;
    *)
      _chk "Provider credentials" 0 "unknown provider: ${provider:-not set}"
      ;;
  esac

  # ── 7. traefik image selected ─────────────────────────────────────────────────
  load_selected
  if [[ -n "${SELECTED[traefik]+_}" ]]; then
    _chk "Traefik selected for deploy" 1
  else
    _chk "Traefik selected for deploy" 0 "select Traefik via main menu option 2"
  fi

  # ── 8. Dashboard auth configured ─────────────────────────────────────────────
  if [[ -n "${TRAEFIK_AUTH:-}" && "${TRAEFIK_AUTH:-}" != "disabled" ]]; then
    _chk "Dashboard auth configured" 1
  else
    _chk "Dashboard auth configured" 0 "set credentials via option 1 (optional but recommended)"
  fi

  # ── 9. DNS: domain resolves ───────────────────────────────────────────────────
  echo ""
  echo -e "  ${DIM}── Network checks (require internet) ──────────────${RESET}"
  if [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]]; then
    if command -v dig &>/dev/null; then
      local resolved; resolved=$(dig +short "${DOMAIN}" A 2>/dev/null | head -1)
      [[ -n "$resolved" ]] \
        && _chk "Domain resolves (DNS)" 1 "${DOMAIN} → ${resolved}" \
        || _chk "Domain resolves (DNS)" 0 "${DOMAIN} returned no A record"
    elif command -v nslookup &>/dev/null; then
      local resolved; resolved=$(nslookup "${DOMAIN}" 2>/dev/null | awk '/^Address:/{print $2}' | tail -1)
      [[ -n "$resolved" ]] \
        && _chk "Domain resolves (DNS)" 1 "${DOMAIN} → ${resolved}" \
        || _chk "Domain resolves (DNS)" 0 "${DOMAIN} returned no A record"
    else
      echo -e "  ${DIM}[SKIP] DNS resolution — dig/nslookup not available${RESET}"
    fi
  else
    echo -e "  ${DIM}[SKIP] DNS resolution — domain not configured${RESET}"
  fi

  # ── 10. HTTP challenge: ports 80/443 reachable ───────────────────────────────
  if [[ "${provider:-}" == "http" ]]; then
    for port in 80 443; do
      if command -v nc &>/dev/null; then
        if nc -z -w3 0.0.0.0 "$port" 2>/dev/null; then
          _chk "Port ${port} listening" 1
        else
          _chk "Port ${port} listening" 0 "Traefik may not be running or port is blocked"
        fi
      elif ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        _chk "Port ${port} listening" 1
      else
        _chk "Port ${port} listening" 0 "Traefik may not be running or port is blocked"
      fi
    done
  fi

  # ── 11. DuckDNS token reachability test ──────────────────────────────────────
  if [[ "${provider:-}" == "duckdns" && -n "${DUCKDNS_TOKEN:-}" ]]; then
    local subdomain="${DOMAIN%%.*}"
    local duck_resp
    duck_resp=$(curl -fsSL --max-time 5 \
      "https://www.duckdns.org/update?domains=${subdomain}&token=${DUCKDNS_TOKEN}&ip=" 2>/dev/null)
    if [[ "$duck_resp" == "OK" ]]; then
      _chk "DuckDNS token valid (API ping)" 1
    else
      _chk "DuckDNS token valid (API ping)" 0 "got: ${duck_resp:-no response} — check token"
    fi
  fi

  # ── 12. Cloudflare token reachability test ───────────────────────────────────
  if [[ "${provider:-}" == "cloudflare" && -n "${CF_DNS_API_TOKEN:-}" ]]; then
    local cf_resp
    cf_resp=$(curl -fsSL --max-time 5 \
      -H "Authorization: Bearer ${CF_DNS_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)
    if echo "$cf_resp" | grep -q '"success":true'; then
      _chk "Cloudflare token valid (API verify)" 1
    else
      _chk "Cloudflare token valid (API verify)" 0 "token rejected or unreachable"
    fi
  fi

  # ── 13. traefik.yml YAML structure sanity ────────────────────────────────────
  if [[ -f "$cfg" ]]; then
    if grep -q "^certificatesResolvers:" "$cfg" && grep -q "letsencrypt:" "$cfg"; then
      _chk "traefik.yml has certificatesResolvers" 1
    else
      _chk "traefik.yml has certificatesResolvers" 0 "regenerate via option 2 or 3"
    fi
    if grep -q "^entryPoints:" "$cfg"; then
      _chk "traefik.yml has entryPoints" 1
    else
      _chk "traefik.yml has entryPoints" 0 "regenerate via option 2 or 3"
    fi
    local acme_storage; acme_storage=$(grep "storage:" "$cfg" 2>/dev/null | awk '{print $2}')
    if [[ "$acme_storage" == "/etc/traefik/acme.json" ]]; then
      _chk "acme.json storage path correct" 1 "${acme_storage}"
    else
      _chk "acme.json storage path correct" 0 "got: ${acme_storage:-missing} — regenerate config"
    fi
  fi

  # ── 14. Let's Encrypt rate limit check (crt.sh CT logs) ───────────────────
  # LE limit: 5 duplicate certs per registered domain per rolling 7 days.
  if [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]]; then
    echo ""
    echo -e "  ${DIM}── Let's Encrypt rate limit check ─────────────────${RESET}"
    local _le_resp
    _le_resp=$(curl -fsSL --max-time 10 \
      "https://crt.sh/?q=%.${DOMAIN}&output=json" 2>/dev/null)
    if [[ -z "$_le_resp" || "$_le_resp" == "[]" || "$_le_resp" == "null" ]]; then
      echo -e "  ${DIM}[SKIP] crt.sh unreachable or no certs found yet for ${DOMAIN}${RESET}"
    else
      local _le_json _le_py
      _le_json=$(mktemp /tmp/crtsh_XXXXXX.json)
      _le_py=$(mktemp /tmp/crtsh_XXXXXX.py)
      echo "$_le_resp" > "$_le_json"
      cat > "$_le_py" << 'PYEOF'
import json, sys, datetime
tmpfile  = sys.argv[1]
week_ago = int(sys.argv[2])
try:
    with open(tmpfile) as f: certs = json.load(f)
except Exception:
    print("parse_error"); sys.exit(0)
recent = []
for c in certs:
    issuer = (c.get("issuer_name") or "").lower()
    if "let's encrypt" not in issuer and "letsencrypt" not in issuer:
        continue
    nb = (c.get("not_before") or c.get("entry_timestamp") or "").replace(" ","T").rstrip("Z")
    try:
        ts = int(datetime.datetime.strptime(nb[:19], "%Y-%m-%dT%H:%M:%S")
                 .replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        continue
    if ts >= week_ago:
        recent.append((ts, c.get("common_name",""), nb[:10]))
recent.sort(reverse=True)
print(len(recent))
if recent:
    oldest_ts = recent[-1][0]
    reset_dt  = datetime.datetime.utcfromtimestamp(oldest_ts + 7*86400)
    print(reset_dt.strftime("%Y-%m-%d %H:%M UTC"))
    for ts, cn, d in recent[:5]:
        print(f"  {d}  {cn}")
PYEOF
      local _le_week_ago=$(( $(date +%s) - 7 * 86400 ))
      local _le_out
      _le_out=$(python3 "$_le_py" "$_le_json" "$_le_week_ago" 2>/dev/null)
      rm -f "$_le_json" "$_le_py"
      if [[ "$_le_out" == "parse_error" || -z "$_le_out" ]]; then
        echo -e "  ${DIM}[SKIP] Could not parse crt.sh response${RESET}"
      else
        local _le_count _le_reset _le_lines
        _le_count=$(echo "$_le_out" | head -1)
        _le_reset=$(echo "$_le_out" | sed -n '2p')
        _le_lines=$(echo "$_le_out" | tail -n +3)
        if [[ "$_le_count" -ge 5 ]]; then
          _chk "LE rate limit (${_le_count}/5 this week)" 0 \
            "RATE LIMITED — ${_le_count} certs in last 7 days (max: 5)"
          [[ -n "$_le_reset" ]] && \
            echo -e "  ${DIM}  Limit resets: ${_le_reset}${RESET}"
          echo -e "  ${DIM}  Recent certificates issued:${RESET}"
          while IFS= read -r _ln; do
            [[ -n "$_ln" ]] && echo -e "  ${DIM}${_ln}${RESET}"
          done <<< "$_le_lines"
        elif [[ "$_le_count" -ge 3 ]]; then
          _chk "LE rate limit (${_le_count}/5 this week)" 1 \
            "approaching limit — use remaining slots carefully"
          [[ -n "$_le_reset" ]] && \
            echo -e "  ${DIM}  Earliest slot reopens: ${_le_reset}${RESET}"
        else
          _chk "LE rate limit (${_le_count}/5 this week)" 1 "well within limit"
        fi
      fi
    fi
  else
    echo -e "  ${DIM}[SKIP] LE rate limit — domain not configured${RESET}"
  fi

  # ── Summary ───────────────────────────────────────────────────────────────────
  echo ""
  if [[ $fail -eq 0 ]]; then
    success "All checks passed (${pass}/${pass}) — Traefik should be able to obtain certificates."
  else
    warn "${fail} check(s) failed, ${pass} passed — fix the issues above before deploying."
  fi
  echo ""
}

_traefik_live_diag() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local api="http://localhost:8080/api"
  echo ""
  echo -e "${BOLD}${CYAN}Traefik Live Routing Diagnostics${RESET}"
  echo "══════════════════════════════════════════════════════════════"

  # ── Check if the traefik container is actually running first ─────────────────
  local traefik_state
  traefik_state=$(docker inspect traefik --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  case "$traefik_state" in
    running)
      success "Traefik container is running"
      ;;
    missing)
      error "Traefik container does not exist — deploy it first:"
      error "  Main menu → option 12 → option 1 (or ensure Traefik is selected)"
      return 1
      ;;
    exited|dead)
      error "Traefik container has exited. Last logs:"
      docker logs traefik --tail=20 2>/dev/null | sed 's/^/  /'
      echo ""
      error "To restart: docker start traefik"
      error "If it keeps crashing, the config may be invalid — regenerate via option 4 → option 3."
      return 1
      ;;
    restarting)
      warn "Traefik container is restarting — it may be crash-looping."
      warn "Check logs: docker logs traefik --tail=30"
      return 1
      ;;
    *)
      warn "Traefik container state: ${traefik_state}"
      ;;
  esac

  # ── Is the API port actually reachable? ──────────────────────────────────────
  if ! curl -fs --max-time 3 "${api}/overview" >/dev/null 2>&1; then
    echo ""
    error "Traefik is running but the API is not responding on localhost:8080."
    echo ""
    echo -e "  ${BOLD}Possible causes:${RESET}"
    echo -e "  ${DIM}1. traefik.yml is missing 'api: insecure: true' — regenerate it:${RESET}"
    echo -e "  ${DIM}   option 4 → option 3 (re-select your ACME provider to regenerate)${RESET}"
    echo -e "  ${DIM}2. The 'traefik' entrypoint on :8080 is missing from traefik.yml${RESET}"
    echo -e "  ${DIM}3. traefik.yml on disk is outdated — regenerate and restart Traefik${RESET}"
    echo ""
    echo -e "  ${BOLD}Current traefik.yml api section:${RESET}"
    local cfg="${INSTALL_DIR}/config/traefik/traefik.yml"
    if [[ -f "$cfg" ]]; then
      grep -A3 "^api:" "$cfg" 2>/dev/null | sed 's/^/  /' || echo "  (could not read)"
    else
      echo -e "  ${RED}traefik.yml not found at ${cfg}${RESET}"
      echo -e "  ${DIM}Run option 4 → option 3 to generate it.${RESET}"
    fi
    echo ""
    echo -e "  ${BOLD}Last 20 Traefik log lines:${RESET}"
    docker logs traefik --tail=20 2>/dev/null | sed 's/^/  /' || echo "  (no logs)"
    return 1
  fi
  success "Traefik API reachable at localhost:8080"

  # ── Registered routers ───────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}HTTP Routers:${RESET}"
  local routers_json
  routers_json=$(curl -fs --max-time 5 "${api}/http/routers" 2>/dev/null)
  if [[ -z "$routers_json" || "$routers_json" == "[]" ]]; then
    warn "No HTTP routers registered — Traefik has not picked up any container labels."
    warn "Check: docker inspect <container> | grep traefik"
  else
    echo "$routers_json" | python3 -c "
import json, sys
routers = json.load(sys.stdin)
for r in sorted(routers, key=lambda x: x.get('name','')):
    name   = r.get('name','?')
    rule   = r.get('rule','?')
    status = r.get('status','?')
    ep     = ','.join(r.get('using', r.get('entryPoints',[])))
    err    = r.get('err','') or r.get('error','') or ''
    marker = '✓' if status == 'enabled' else '✗'
    print(f'  {marker} {name:<30} {rule}')
    if err:
        print(f'    ERROR: {err}')
" 2>/dev/null || echo "$routers_json" | python3 -m json.tool | grep -E '"name"|"rule"|"status"|"error"'
  fi

  # ── Services and backend health ──────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}HTTP Services (backend health):${RESET}"
  local services_json
  services_json=$(curl -fs --max-time 5 "${api}/http/services" 2>/dev/null)
  if [[ -n "$services_json" && "$services_json" != "[]" ]]; then
    echo "$services_json" | python3 -c "
import json, sys
services = json.load(sys.stdin)
for s in sorted(services, key=lambda x: x.get('name','')):
    name = s.get('name','?')
    if '@internal' in name: continue
    status = s.get('status','?')
    servers = s.get('loadBalancer',{}).get('servers',[]) or []
    urls = [srv.get('url','?') for srv in servers]
    server_statuses = s.get('serverStatus',{}) or {}
    marker = '✓' if status == 'enabled' else '✗'
    print(f'  {marker} {name:<35} {status}')
    for url, st in server_statuses.items():
        health_marker = '✓' if st == 'UP' else '✗'
        print(f'      {health_marker} {url}  [{st}]')
    if not server_statuses and urls:
        for u in urls: print(f'      → {u}')
" 2>/dev/null || true
  fi

  # ── Container network check ──────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}Container → medianet IP addresses:${RESET}"
  load_selected
  local cname
  # Check all selected containers, not just a hardcoded subset
  for cname in "${CONTAINER_ORDER[@]}"; do
    [[ -z "${SELECTED[$cname]+_}" ]] && continue
    if docker inspect "$cname" &>/dev/null 2>&1; then
      local ip
      ip=$(docker inspect "$cname" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "medianet"}}{{$v.IPAddress}}{{end}}{{end}}' \
        2>/dev/null)
      if [[ -n "$ip" ]]; then
        echo -e "  ${GREEN}✓${RESET} ${cname}: ${ip}"
      else
        echo -e "  ${YELLOW}○${RESET} ${cname}: not on medianet (or not running)"
      fi
    fi
  done

  # ── DOMAIN sanity check ──────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}DOMAIN sanity:${RESET}"
  local raw_domain
  raw_domain=$(grep '^DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
  local trimmed_domain="${raw_domain// /}"   # strip spaces
  trimmed_domain="${trimmed_domain//[$'\t\r\n']/}"  # strip whitespace
  if [[ "$raw_domain" != "$trimmed_domain" ]]; then
    warn "DOMAIN in .env has trailing whitespace: '${raw_domain}'"
    warn "This breaks Host() rules — run option 2 to resave it."
  else
    echo -e "  ${GREEN}✓${RESET} DOMAIN='${trimmed_domain}' (no whitespace)"
  fi

  # ── acme.json cert check ─────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}Certificates in acme.json:${RESET}"
  local acme_file="${INSTALL_DIR}/config/traefik/acme.json"
  if [[ -f "$acme_file" && -s "$acme_file" ]]; then
    python3 -c "
import json, sys
try:
    with open('${acme_file}') as f: data = json.load(f)
    resolver = data.get('letsencrypt', {})
    certs = resolver.get('Certificates') or []
    if not certs:
        print('  No certificates stored yet — ACME has not completed successfully')
    else:
        for c in certs:
            domain = c.get('domain',{})
            main   = domain.get('main','?')
            sans   = domain.get('sans',[])
            print(f'  ✓ {main}  SANs: {sans}')
except Exception as e:
    print(f'  Could not parse acme.json: {e}')
" 2>/dev/null
  else
    warn "acme.json is empty or missing — no certs issued yet"
  fi

  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo -e "${DIM}Full router list: curl -s http://localhost:8080/api/http/routers | python3 -m json.tool${RESET}"
  echo ""
}

_traefik_emergency_recover() {
  require_root || return 1
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}${YELLOW}Traefik Emergency Recovery${RESET}"
  echo ""
  echo -e "  Use this when Traefik is stuck, crashed, or the dashboard is unreachable."
  echo -e "  It will:"
  echo -e "  ${DIM}  1. Stop the Traefik container${RESET}"
  echo -e "  ${DIM}  2. Clear acme.json (removes all stored certificates)${RESET}"
  echo -e "  ${DIM}  3. Regenerate traefik.yml from current settings${RESET}"
  echo -e "  ${DIM}  4. Restart Traefik${RESET}"
  echo ""
  warn "All stored TLS certificates will be cleared."
  warn "Traefik will request new ones on restart — this may take a few minutes."
  echo ""
  read -rp "  Proceed? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }

  echo ""

  # Stop Traefik
  local traefik_state
  traefik_state=$(docker inspect traefik --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "$traefik_state" == "missing" ]]; then
    warn "Traefik container does not exist — skipping stop."
  else
    info "Stopping Traefik..."
    docker stop traefik 2>/dev/null || true
    success "Traefik stopped."
  fi

  # Clear acme.json
  local acme="${CONFIG_ROOT:-/opt/friendbox/config}/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    truncate -s 0 "$acme"
    chown root:root "$acme"
    chmod 600 "$acme"
    success "acme.json cleared (${acme})."
  else
    # Create it fresh if missing
    mkdir -p "$(dirname "$acme")"
    touch "$acme"
    chown root:root "$acme"
    chmod 600 "$acme"
    success "acme.json created fresh (${acme})."
  fi

  # Regenerate traefik.yml
  _traefik_write_config

  # Start Traefik — use compose so certresolver label changes are picked up
  if [[ "$traefik_state" != "missing" ]]; then
    info "Starting Traefik..."
    compose_selected up -d --force-recreate traefik
    success "Traefik started."
    echo ""
    info "Dashboard should be reachable at: http://$(hostname -I 2>/dev/null | awk '{print $1}'):8080/dashboard/"
    info "If HTTPS cert renewal still fails, run: option 4 → option 5 (pre-flight checks)"
  else
    info "Traefik container was not found — deploy the full stack first:"
    info "  Main menu → option 12 → option 1"
  fi
}

_traefik_set_redirect() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected

  # Build an ordered list of selected containers that have a web UI subdomain
  # (voice-only services like teamspeak6 and mumble are excluded).
  declare -A _SUB=(
    [traefik]=traefik   [portainer]=portainer [plex]=plex
    [jellyfin]=jellyfin [sonarr]=sonarr       [radarr]=radarr
    [prowlarr]=prowlarr [bazarr]=bazarr       [qbittorrent]=qbt
    [qbittorrentvpn]=qbtvpn [delugevpn]=deluge [nzbget]=nzbget
    [overseerr]=overseerr   [ombi]=ombi       [jellyseerr]=jellyseerr
    [ampmc]=amp             [netbootxyz]=netboot
  )

  local keys=() subdomains=()
  local k
  for k in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$k]+_}" && -n "${_SUB[$k]+_}" ]] || continue
    keys+=("$k")
    subdomains+=("${_SUB[$k]}")
  done

  local current="${ROOT_REDIRECT_HOST:-portainer}"
  local d="${DOMAIN:-yourdomain.com}"

  echo ""
  echo -e "${BOLD}Root Domain Redirect${RESET}"
  echo -e "${DIM}  Visiting https://${d} redirects to https://<subdomain>.${d}${RESET}"
  echo -e "${DIM}  Current target: ${CYAN}${current}.${d}${RESET}"
  echo ""

  if [[ ${#keys[@]} -eq 0 ]]; then
    warn "No containers with a web UI are selected."
    warn "Select containers first (option 2), then return here."
    return 1
  fi

  local i
  for i in "${!keys[@]}"; do
    # $'\e[...]' (ANSI C quoting) stores the actual ESC byte in the variable,
    # so printf/echo print it correctly without needing -e interpretation.
    local _green=$'\e[0;32m' _reset=$'\e[0m' _dim=$'\e[2m'
    local marker="  "
    [[ "${subdomains[$i]}" == "$current" ]] && marker="${_green}▶${_reset} "
    local _num _name _url
    printf -v _num  "%2d"   "$((i+1))"
    printf -v _name "%-14s" "${CONTAINER_NAMES[${keys[$i]}]}"
    printf -v _url  "https://%s.%s" "${subdomains[$i]}" "$d"
    printf "  %s%s) %s  %shttps://%s.%s%s\n" \
      "$marker" "$_num" "$_name" "$_dim" "${subdomains[$i]}" "$d" "$_reset"
  done
  echo ""
  echo -e "   c) Enter a custom subdomain"
  echo -e "   q) Cancel"
  echo ""

  while true; do
    read -rp "  Choice: " sel
    case "$sel" in
      q|Q) info "Cancelled — redirect unchanged."; return 0 ;;
      c|C)
        echo ""
        read -rp "  Custom subdomain (just the label, e.g. 'home'): " custom
        custom="${custom// /}"   # strip any spaces
        if [[ -z "$custom" ]]; then
          warn "Empty input — redirect unchanged."
          return 1
        fi
        ROOT_REDIRECT_HOST="$custom"
        ;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && \
           (( sel >= 1 && sel <= ${#keys[@]} )); then
          ROOT_REDIRECT_HOST="${subdomains[$((sel-1))]}"
        else
          warn "Invalid choice."
          continue
        fi
        ;;
    esac
    break
  done

  # Persist to .env
  if grep -q '^ROOT_REDIRECT_HOST=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^ROOT_REDIRECT_HOST=.*|ROOT_REDIRECT_HOST=${ROOT_REDIRECT_HOST}|" "$ENV_FILE"
  else
    echo "ROOT_REDIRECT_HOST=${ROOT_REDIRECT_HOST}" >> "$ENV_FILE"
  fi

  echo ""
  success "Root redirect set to: ${CYAN}https://${ROOT_REDIRECT_HOST}.${d}${RESET}"
  info "Redeploy Traefik (option 12) to apply the change."
}

configure_traefik() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║             🔀  Traefik Configuration                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    _traefik_show_status

    echo "  1) Set dashboard credentials (username + password)"
    echo "  2) Update domain / ACME email"
    echo "  3) Configure ACME challenge provider"
    echo "  4) Toggle staging / production CA"
    echo "  5) Run pre-flight checks"
    echo "  6) Live routing diagnostics"
    echo "  7) Emergency recovery (clear certs + restart Traefik)"
    echo "  8) Set root domain redirect target"
    echo "  9) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) _traefik_set_auth           || true; pause ;;
      2) _traefik_set_domain         || true; pause ;;
      3) _traefik_set_provider       || true; pause ;;
      4) _traefik_toggle_staging     || true; pause ;;
      5) _traefik_validate           || true; pause ;;
      6) _traefik_live_diag          || true; pause ;;
      7) _traefik_emergency_recover  || true; pause ;;
      8) _traefik_set_redirect       || true; pause ;;
      9) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

_traefik_toggle_staging() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}ACME Staging / Production CA${RESET}"
  echo ""
  local current="${ACME_STAGING:-false}"

  if [[ "$current" == "true" ]]; then
    echo -e "  Current mode : ${YELLOW}STAGING${RESET} (Let's Encrypt staging CA — certs not trusted by browsers)"
    echo ""
    echo "  Staging certs confirm the ACME flow works without burning production quota."
    echo "  Switch to production once you see a successful certificate in the logs."
    echo ""
    read -rp "  Switch to PRODUCTION CA? [y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      sed -i 's/^ACME_STAGING=.*/ACME_STAGING=false/' "$ENV_FILE"
      success "Switched to PRODUCTION CA."
    else
      info "Staying on staging CA."
      return 0
    fi
  else
    echo -e "  Current mode : ${GREEN}PRODUCTION${RESET} (Let's Encrypt production CA)"
    echo ""
    warn "Rate limit reached or testing? Switch to staging to verify your config."
    warn "Staging certs are signed by a fake CA — browsers will warn, but the"
    warn "ACME flow is identical so you can confirm everything works."
    echo ""
    read -rp "  Switch to STAGING CA? [y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      if grep -q '^ACME_STAGING=' "$ENV_FILE" 2>/dev/null; then
        sed -i 's/^ACME_STAGING=.*/ACME_STAGING=true/' "$ENV_FILE"
      else
        echo "ACME_STAGING=true" >> "$ENV_FILE"
      fi
      success "Switched to STAGING CA."
    else
      info "Staying on production CA."
      return 0
    fi
  fi

  # Regenerate traefik.yml with the new CA server URL
  _traefik_write_config
  success "traefik.yml regenerated."

  # Clear acme.json so Traefik requests a fresh cert from the new CA.
  # Keeping a cert issued by the old CA causes Traefik to loop trying to
  # renew it against a CA that won't accept it.
  local acme="${CONFIG_ROOT:-/opt/friendbox/config}/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    truncate -s 0 "$acme"
    success "acme.json cleared."
  fi

  # Restart Traefik if it is currently running
  local traefik_state
  traefik_state=$(docker inspect traefik --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "$traefik_state" == "running" || "$traefik_state" == "exited" ]]; then
    info "Restarting Traefik to apply new CA and compose config..."
    compose_selected up -d --force-recreate traefik
    success "Traefik restarted."
  else
    info "Traefik is not running — start it with: sudo friendbox → option 12"
  fi
}

_traefik_set_auth() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}Traefik Dashboard Credentials${RESET}"
  echo -e "${DIM}Secures the Traefik dashboard at https://traefik.${DOMAIN:-yourdomain.com}${RESET}"
  echo -e "${DIM}  Press Enter on username to keep the value shown in [brackets].${RESET}"
  echo ""

  if ! command -v htpasswd &>/dev/null; then
    warn "htpasswd not found. Installing apache2-utils..."
    apt-get install -y apache2-utils || { error "Could not install apache2-utils."; return 1; }
  fi

  echo -n "Dashboard username [${TRAEFIK_USER:-admin}]: "
  read -r input
  local dash_user="${input:-${TRAEFIK_USER:-admin}}"
  echo -n "Dashboard password (press Enter to keep existing): "
  read -rs dash_pass; echo ""
  if [[ -z "$dash_pass" ]]; then
    if [[ -n "${TRAEFIK_AUTH:-}" && "${TRAEFIK_AUTH:-}" != "disabled" ]]; then
      info "Password unchanged — keeping existing credentials."
      sed -i '/^TRAEFIK_USER=/d' "$ENV_FILE" 2>/dev/null || true
      echo "TRAEFIK_USER=${dash_user}" >> "$ENV_FILE"
      success "Traefik username updated."
      return 0
    else
      warn "No existing password set — please enter a password."
      return 1
    fi
  fi

  local new_auth
  new_auth=$(htpasswd -nbB "$dash_user" "$dash_pass" | sed 's/\$/\$\$/g')

  sed -i '/^TRAEFIK_AUTH=/d;/^TRAEFIK_USER=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'TRAEFIK_USER=%s\nTRAEFIK_AUTH=%s\n' "$dash_user" "$new_auth" >> "$ENV_FILE"
  success "Traefik dashboard credentials saved."
  info "Redeploy Traefik (menu option 12 → option 2 → select Traefik) to apply changes."
}

_traefik_set_domain() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}Traefik Domain / ACME Email${RESET}"
  echo -e "${DIM}These are used by Traefik for automatic HTTPS certificate issuance.${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  echo -n "Domain (e.g. example.com) [${DOMAIN:-}]: "
  read -r input
  local new_domain="${input:-${DOMAIN:-}}"
  new_domain="${new_domain//[[:space:]]/}"  # strip any accidental whitespace
  [[ -z "$new_domain" ]] && { warn "Domain cannot be empty."; return 1; }
  echo -n "ACME email [${ACME_EMAIL:-}]: "
  read -r input
  local new_email="${input:-${ACME_EMAIL:-}}"
  new_email="${new_email//[[:space:]]/}"  # strip any accidental whitespace
  [[ -z "$new_email" ]] && { warn "ACME email cannot be empty."; return 1; }

  sed -i '/^DOMAIN=/d;/^ACME_EMAIL=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'DOMAIN=%s\nACME_EMAIL=%s\n' "$new_domain" "$new_email" >> "$ENV_FILE"
  success "Domain and ACME email updated."
  warn "If Traefik is already running, delete acme.json and redeploy Traefik to re-issue certificates."
  _traefik_write_config
}

_traefik_set_provider() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}ACME Challenge Provider${RESET}"
  echo -e "${DIM}Traefik uses ACME to get automatic HTTPS certificates from Let's Encrypt.${RESET}"
  echo -e "${DIM}HTTP challenge is simplest. DNS challenge is required for wildcard certs${RESET}"
  echo -e "${DIM}or if port 80 is blocked on your network.${RESET}"
  echo ""
  echo -e "  1) HTTP challenge  ${DIM}(default — ports 80/443 must be open)${RESET}"
  echo -e "  2) Cloudflare      ${DIM}(DNS challenge via Cloudflare API)${RESET}"
  echo -e "  3) DuckDNS         ${DIM}(DNS challenge via DuckDNS token)${RESET}"
  echo -e "  4) GoDaddy         ${DIM}(DNS challenge via GoDaddy API)${RESET}"
  echo -e "  5) Namecheap       ${DIM}(DNS challenge via Namecheap API)${RESET}"
  echo ""
  echo -n "  Select provider [current: ${TRAEFIK_ACME_PROVIDER:-http}]: "
  read -r sel

  local provider
  case "${sel:-}" in
    1) provider="http"       ;;
    2) provider="cloudflare" ;;
    3) provider="duckdns"    ;;
    4) provider="godaddy"    ;;
    5) provider="namecheap"  ;;
    "") provider="${TRAEFIK_ACME_PROVIDER:-http}" ;;
    *)  warn "Invalid selection."; return 1 ;;
  esac

  # Clear all provider-specific vars so switching providers leaves no stale keys
  sed -i '/^TRAEFIK_ACME_PROVIDER=/d
          /^CF_DNS_API_TOKEN=/d
          /^CF_API_EMAIL=/d
          /^CF_API_KEY=/d
          /^DUCKDNS_TOKEN=/d
          /^GODADDY_API_KEY=/d
          /^GODADDY_API_SECRET=/d
          /^NAMECHEAP_API_USER=/d
          /^NAMECHEAP_API_KEY=/d' "$ENV_FILE" 2>/dev/null || true

  echo "TRAEFIK_ACME_PROVIDER=${provider}" >> "$ENV_FILE"

  # Branch to provider-specific credential prompts
  case "$provider" in
    http)
      success "ACME provider set to HTTP challenge."
      info "Ensure ports 80 and 443 are open and forwarded to this machine."
      ;;
    cloudflare) _traefik_provider_cloudflare ;;
    duckdns)    _traefik_provider_duckdns    ;;
    godaddy)    _traefik_provider_godaddy    ;;
    namecheap)  _traefik_provider_namecheap  ;;
  esac
  _traefik_write_config
}

_traefik_provider_cloudflare() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}Cloudflare DNS Challenge Credentials${RESET}"
  echo -e "${DIM}  Create a scoped API token at: dash.cloudflare.com → My Profile → API Tokens${RESET}"
  echo -e "${DIM}  Required permissions: Zone / DNS / Edit  +  Zone / Zone / Read${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""

  echo -n "Cloudflare account email [${CF_API_EMAIL:-}]: "
  read -r input
  local cf_email="${input:-${CF_API_EMAIL:-}}"
  [[ -z "$cf_email" ]] && { warn "Email required."; return 1; }

  echo -n "Cloudflare API token (press Enter to keep existing): "
  read -rs input; echo ""
  local cf_token
  if [[ -n "$input" ]]; then
    cf_token="$input"
  elif [[ -n "${CF_DNS_API_TOKEN:-}" ]]; then
    cf_token="$CF_DNS_API_TOKEN"
    info "API token unchanged."
  else
    warn "API token is required."; return 1
  fi

  sed -i '/^CF_API_EMAIL=/d;/^CF_DNS_API_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'CF_API_EMAIL=%s\nCF_DNS_API_TOKEN=%s\n' "$cf_email" "$cf_token" >> "$ENV_FILE"
  success "Cloudflare credentials saved."
}

_traefik_provider_duckdns() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}DuckDNS DNS Challenge Credentials${RESET}"
  echo -e "${DIM}  Find your token at: www.duckdns.org (shown after login)${RESET}"
  echo -e "${DIM}  Press Enter to keep current value. Leave blank to clear.${RESET}"
  echo ""

  echo -n "DuckDNS token [${DUCKDNS_TOKEN:-}]: "
  read -r input
  local duck_token
  if [[ -n "$input" ]]; then
    duck_token="$input"
  elif [[ -n "${DUCKDNS_TOKEN:-}" ]]; then
    duck_token="$DUCKDNS_TOKEN"
    info "Token unchanged."
  else
    warn "Token is required."; return 1
  fi

  sed -i '/^DUCKDNS_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  echo "DUCKDNS_TOKEN=${duck_token}" >> "$ENV_FILE"
  success "DuckDNS credentials saved."
}

_traefik_provider_godaddy() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}GoDaddy DNS Challenge Credentials${RESET}"
  echo -e "${DIM}  Create a Production API key at: developer.godaddy.com → Keys${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""

  echo -n "GoDaddy API key [${GODADDY_API_KEY:-}]: "
  read -r input
  local gd_key="${input:-${GODADDY_API_KEY:-}}"
  [[ -z "$gd_key" ]] && { warn "API key required."; return 1; }

  echo -n "GoDaddy API secret (press Enter to keep existing): "
  read -rs input; echo ""
  local gd_secret
  if [[ -n "$input" ]]; then
    gd_secret="$input"
  elif [[ -n "${GODADDY_API_SECRET:-}" ]]; then
    gd_secret="$GODADDY_API_SECRET"
    info "Secret unchanged."
  else
    warn "API secret is required."; return 1
  fi

  sed -i '/^GODADDY_API_KEY=/d;/^GODADDY_API_SECRET=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'GODADDY_API_KEY=%s\nGODDADDY_API_SECRET=%s\n' "$gd_key" "$gd_secret" >> "$ENV_FILE"
  success "GoDaddy credentials saved."
}

_traefik_provider_namecheap() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}Namecheap DNS Challenge Credentials${RESET}"
  echo -e "${DIM}  Enable API access at: ap.www.namecheap.com → Profile → Tools → API Access${RESET}"
  echo -e "${DIM}  Your IP must be whitelisted in Namecheap's API settings.${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""

  echo -n "Namecheap API username [${NAMECHEAP_API_USER:-}]: "
  read -r input
  local nc_user="${input:-${NAMECHEAP_API_USER:-}}"
  [[ -z "$nc_user" ]] && { warn "API username required."; return 1; }

  echo -n "Namecheap API key (press Enter to keep existing): "
  read -rs input; echo ""
  local nc_key
  if [[ -n "$input" ]]; then
    nc_key="$input"
  elif [[ -n "${NAMECHEAP_API_KEY:-}" ]]; then
    nc_key="$NAMECHEAP_API_KEY"
    info "API key unchanged."
  else
    warn "API key is required."; return 1
  fi

  echo -n "Namecheap API source IP (press Enter to auto-detect, must be whitelisted in NC API settings) [${NAMECHEAP_API_IP:-}]: "
  read -r input
  local nc_ip
  if [[ -n "$input" ]]; then
    nc_ip="$input"
  elif [[ -n "${NAMECHEAP_API_IP:-}" ]]; then
    nc_ip="$NAMECHEAP_API_IP"
    info "Source IP unchanged: ${nc_ip}"
  else
    info "Detecting public IP..."
    nc_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) || nc_ip=""
    if [[ -n "$nc_ip" ]]; then
      info "Detected: ${nc_ip}"
      warn "Ensure this IP is whitelisted in Namecheap API settings before deploying."
    else
      warn "Could not detect public IP. Enter it manually or whitelist your IP at Namecheap."
      nc_ip=""
    fi
  fi

  sed -i '/^NAMECHEAP_API_USER=/d;/^NAMECHEAP_API_KEY=/d;/^NAMECHEAP_API_IP=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'NAMECHEAP_API_USER=%s\nNAMECHEAP_API_KEY=%s\n' "$nc_user" "$nc_key" >> "$ENV_FILE"
  [[ -n "$nc_ip" ]] && printf 'NAMECHEAP_API_IP=%s\n' "$nc_ip" >> "$ENV_FILE"
  success "Namecheap credentials saved."
}

# =============================================================================
#  Service Credentials (VPN, AMP, Mumble)
# =============================================================================

_creds_show_status() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected
  echo ""

  # Jellyfin HW accel status
  if [[ -n "${SELECTED[jellyfin]+_}" ]]; then
    local _jf_hw="${JELLYFIN_HW_ACCEL:-none}"
    local _jf_col="${DIM}"
    [[ "$_jf_hw" != "none" ]] && _jf_col="${GREEN}"
    echo -e "  ${BOLD}Jellyfin HW accel :${RESET} ${_jf_col}${_jf_hw}${RESET}"
    echo ""
  fi

  # VPN
  local vpn_containers=()
  local k
  for k in "${VPN_CONTAINERS[@]}"; do
    [[ -n "${SELECTED[$k]+_}" ]] && vpn_containers+=("${CONTAINER_NAMES[$k]}")
  done
  if [[ ${#vpn_containers[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}VPN containers :${RESET} ${vpn_containers[*]}"
    echo -e "  ${BOLD}VPN provider   :${RESET} ${VPN_PROV:-not set}"
    echo -e "  ${BOLD}VPN client     :${RESET} ${VPN_CLIENT:-not set}"
    echo -e "  ${BOLD}VPN user       :${RESET} ${VPN_USER:-not set}"
    echo -e "  ${BOLD}VPN password   :${RESET} ${VPN_PASS:+[set]}"
    echo -e "  ${BOLD}LAN CIDR       :${RESET} ${LAN_NETWORK:-not set}"
  else
    echo -e "  ${DIM}No VPN containers selected.${RESET}"
  fi
  echo ""

  # AMP
  if [[ -n "${SELECTED[ampmc]+_}" ]]; then
    echo -e "  ${BOLD}AMP username   :${RESET} ${AMP_USER:-not set}"
    echo -e "  ${BOLD}AMP password   :${RESET} ${AMP_PASS:+[set]}"
    echo ""
  fi

  # Mumble
  if [[ -n "${SELECTED[mumble]+_}" ]]; then
    echo -e "  ${BOLD}Mumble superuser password :${RESET} ${MUMBLE_SUPERUSER_PASSWORD:+[set]}"
    echo ""
  fi
}

configure_service_credentials() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           🔑  Service Credentials                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    _creds_show_status

    # Build menu dynamically based on what's selected
    load_selected
    local opt_num=1
    declare -A CRED_OPTS=()

    local vpn_needed=false
    local k
    for k in "${VPN_CONTAINERS[@]}"; do
      [[ -n "${SELECTED[$k]+_}" ]] && vpn_needed=true
    done

    if [[ "$vpn_needed" == "true" ]]; then
      echo "  ${opt_num}) Configure VPN credentials"
      CRED_OPTS[$opt_num]="vpn"
      opt_num=$((opt_num + 1))
    fi

    if [[ -n "${SELECTED[ampmc]+_}" ]]; then
      echo "  ${opt_num}) Configure AMP credentials"
      CRED_OPTS[$opt_num]="amp"
      opt_num=$((opt_num + 1))
    fi

    if [[ -n "${SELECTED[mumble]+_}" ]]; then
      echo "  ${opt_num}) Configure Mumble superuser password"
      CRED_OPTS[$opt_num]="mumble"
      opt_num=$((opt_num + 1))
    fi

    if [[ -n "${SELECTED[jellyfin]+_}" ]]; then
      echo "  ${opt_num}) Jellyfin — configure hardware acceleration"
      CRED_OPTS[$opt_num]="jellyfin_hw_setup"
      opt_num=$((opt_num + 1))
      echo "  ${opt_num}) Jellyfin — run hardware acceleration diagnostic"
      CRED_OPTS[$opt_num]="jellyfin_hw_check"
      opt_num=$((opt_num + 1))
    fi

    if [[ $opt_num -eq 1 ]]; then
      echo -e "  ${DIM}No services requiring configuration are currently selected.${RESET}"
      echo -e "  ${DIM}Select VPN containers, AMP, Mumble, or Jellyfin first (option 2).${RESET}"
    fi

    echo "  ${opt_num}) Back to main menu"
    CRED_OPTS[$opt_num]="back"
    echo ""
    read -rp "  Choice: " choice

    if [[ -z "${CRED_OPTS[$choice]+_}" ]]; then
      warn "Invalid choice."; sleep 1; continue
    fi

    case "${CRED_OPTS[$choice]}" in
      vpn)              _creds_configure_vpn    || true; pause ;;
      amp)              _creds_configure_amp    || true; pause ;;
      mumble)           _creds_configure_mumble || true; pause ;;
      jellyfin_hw_setup) _jellyfin_hw_setup     || true; pause ;;
      jellyfin_hw_check) _jellyfin_hw_check     || true; pause ;;
      back)             return ;;
    esac
  done
}

_creds_configure_vpn() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}VPN Credentials${RESET}"
  echo -e "${DIM}Used by qBittorrentVPN and/or DelugeVPN.${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""

  read -rp "VPN provider (pia, airvpn, mullvad, custom) [${VPN_PROV:-pia}]: " input
  VPN_PROV="${input:-${VPN_PROV:-pia}}"
  read -rp "VPN client (openvpn, wireguard) [${VPN_CLIENT:-openvpn}]: " input
  VPN_CLIENT="${input:-${VPN_CLIENT:-openvpn}}"
  read -rp "VPN username [${VPN_USER:-}]: " input
  VPN_USER="${input:-${VPN_USER:-}}"
  read -srp "VPN password (press Enter to keep existing): " input; echo ""
  if [[ -n "$input" ]]; then
    VPN_PASS="$input"
  elif [[ -z "${VPN_PASS:-}" ]]; then
    warn "VPN password is required."; return 1
  else
    info "VPN password unchanged."
  fi
  # Include both your LAN subnet AND the Docker bridge subnet.
  # The bridge subnet lets Traefik reach the VPN container for health checks
  # and reverse proxying despite the VPN tunnel being active.
  # Detect the actual medianet subnet Docker assigned — it varies per install.
  local docker_subnet
  docker_subnet=$(docker network inspect medianet --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
  local lan_default="192.168.1.0/24${docker_subnet:+,${docker_subnet}}"
  read -rp "LAN network CIDR [${LAN_NETWORK:-${lan_default}}]: " input
  LAN_NETWORK="${input:-${LAN_NETWORK:-${lan_default}}}"

  local var
  for var in VPN_PROV VPN_CLIENT VPN_USER VPN_PASS LAN_NETWORK; do
    sed -i "/^${var}=/d" "$ENV_FILE" 2>/dev/null || true
    echo "${var}=${!var}" >> "$ENV_FILE"
  done
  success "VPN credentials saved."
}

_creds_configure_amp() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}AMP (Game Server Panel) Credentials${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  read -rp "AMP admin username [${AMP_USER:-admin}]: " input
  AMP_USER="${input:-${AMP_USER:-admin}}"
  read -srp "AMP admin password (press Enter to keep existing): " input; echo ""
  if [[ -n "$input" ]]; then
    AMP_PASS="$input"
  elif [[ -z "${AMP_PASS:-}" ]]; then
    warn "AMP password is required."; return 1
  else
    info "AMP password unchanged."
  fi
  sed -i '/^AMP_USER=/d;/^AMP_PASS=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'AMP_USER=%s\nAMP_PASS=%s\n' "$AMP_USER" "$AMP_PASS" >> "$ENV_FILE"
  success "AMP credentials saved."
}

_creds_configure_mumble() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}Mumble Superuser Password${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  read -srp "Mumble superuser password [${MUMBLE_SUPERUSER_PASSWORD:-changeme}]: " input
  MUMBLE_SUPERUSER_PASSWORD="${input:-${MUMBLE_SUPERUSER_PASSWORD:-changeme}}"
  echo ""
  if [[ "$MUMBLE_SUPERUSER_PASSWORD" == "changeme" ]]; then
    warn "Password is still set to 'changeme' — change this before exposing Mumble to the internet."
  fi
  sed -i '/^MUMBLE_SUPERUSER_PASSWORD=/d' "$ENV_FILE" 2>/dev/null || true
  echo "MUMBLE_SUPERUSER_PASSWORD=${MUMBLE_SUPERUSER_PASSWORD}" >> "$ENV_FILE"
  success "Mumble password saved."
}

generate_redeploy_sh() {
  local dest="${INSTALL_DIR}/scripts/redeploy.sh"
  _ensure_install_dir

  cat > "$dest" <<'REDEPLOY'
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
REDEPLOY

  chmod +x "$dest"
  _own "$dest"
}

# =============================================================================
#  Backup & Restore
# =============================================================================

BACKUP_DIR="${INSTALL_DIR}/backups"

backup_config() {
  require_root || return 1
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

  local cfg="${CONFIG_ROOT:-/opt/friendbox/config}"
  if [[ ! -d "$cfg" ]]; then
    warn "Config directory not found: ${cfg}"
    warn "Run option 8 (Provision / fix directory ownership) first."
    return 1
  fi

  mkdir -p "$BACKUP_DIR"
  _own "$BACKUP_DIR"

  local timestamp archive_name archive_path
  timestamp=$(date '+%Y%m%d_%H%M%S')
  archive_name="friendbox_backup_${timestamp}.tar.gz"
  archive_path="${BACKUP_DIR}/${archive_name}"

  echo ""
  echo -e "${BOLD}Creating backup...${RESET}"
  echo -e "  ${DIM}Config : ${cfg}${RESET}"
  echo -e "  ${DIM}Archive: ${archive_path}${RESET}"
  echo ""

  # Stop containers before backing up so database files are in a consistent state.
  # SQLite databases (Sonarr, Radarr, Prowlarr, etc.) can be mid-write while running,
  # producing a corrupt or inconsistent backup if snapshotted live.
  local _was_running=false
  if is_running 2>/dev/null; then
    _was_running=true
    info "Stopping containers for a consistent backup..."
    compose_selected stop 2>/dev/null || true
    success "Containers stopped."
    echo ""
  fi

  # Check disk space
  local cfg_kb free_kb
  cfg_kb=$(du -sk "$cfg" 2>/dev/null | awk '{print $1}') || cfg_kb=0
  free_kb=$(df -k "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}') || free_kb=0
  if [[ "$cfg_kb" -gt 0 && "$free_kb" -gt 0 && "$cfg_kb" -gt "$free_kb" ]]; then
    warn "Not enough disk space — config is ~${cfg_kb}KB, free is ${free_kb}KB."
    # Restart containers before returning so we don't leave them stopped on failure
    if [[ "$_was_running" == "true" ]]; then
      info "Restarting containers..."
      compose_selected start 2>/dev/null || true
    fi
    return 1
  fi

  # Collect state files alongside the config dir
  local state_files=() sf
  for sf in "$ENV_FILE" "$SELECTED_FILE" "$DNS_STATE_FILE" \
            "$MERGERFS_MODES_FILE" "$MERGERFS_POOL_FILE" \
            "$INSTALL_FLAG" "$STATE_FILE"; do
    [[ -f "$sf" ]] && state_files+=("${sf#/}")
  done

  # Exclude acme.json — it is env-specific and will be regenerated on restore.
  # The tar is built relative to /, so the exclude path must match the full
  # relative path within the archive (without leading slash).
  local acme_rel="${cfg#/}/traefik/acme.json"
  if tar -czf "$archive_path" \
      --exclude="$acme_rel" \
      -C / "${cfg#/}" "${state_files[@]}" 2>/dev/null; then
    local size
    size=$(du -sh "$archive_path" 2>/dev/null | awk '{print $1}')
    chown root:root "$archive_path"
    chmod 600 "$archive_path"
    success "Backup created: ${archive_name} (${size:-?})"
    info "Location: ${archive_path}"
    # Keep only the 10 most recent
    local old
    old=$(ls -1t "${BACKUP_DIR}"/friendbox_backup_*.tar.gz 2>/dev/null | tail -n +11)
    if [[ -n "$old" ]]; then
      local pruned=0
      while IFS= read -r o; do rm -f "$o"; pruned=$((pruned+1)); done <<< "$old"
      info "Pruned ${pruned} old backup(s) — keeping 10 most recent."
    fi
  else
    rm -f "$archive_path"
    error "Backup failed — check disk space and permissions."
    # Restart containers even on failure so we don't leave them stopped
    if [[ "$_was_running" == "true" ]]; then
      info "Restarting containers..."
      compose_selected start 2>/dev/null || true
    fi
    return 1
  fi

  # Restart containers that were stopped for the backup
  if [[ "$_was_running" == "true" ]]; then
    echo ""
    info "Restarting containers..."
    compose_selected start 2>/dev/null || true
    success "Containers restarted."
  fi
}

restore_config() {
  require_root || return 1
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

  echo ""
  echo -e "${BOLD}Restore — Config Snapshot${RESET}"
  echo ""

  local backups=() f
  while IFS= read -r f; do backups+=("$f"); done \
    < <(ls -1t "${BACKUP_DIR}"/friendbox_backup_*.tar.gz 2>/dev/null)

  if [[ ${#backups[@]} -eq 0 ]]; then
    warn "No backups found in ${BACKUP_DIR}."
    info "Create one first with option 1."
    return 1
  fi

  echo "  Available backups (newest first):"
  echo ""
  local i=1
  for f in "${backups[@]}"; do
    local size ts
    size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    ts=$(basename "$f" | sed 's/friendbox_backup_//;s/\.tar\.gz//' | sed 's/_/ /')
    printf "  %2d) %s  ${DIM}(%s)${RESET}\n" "$i" "$ts" "${size:-?}"
    i=$((i+1))
  done
  echo ""
  read -rp "  Select backup to restore [1]: " sel
  sel="${sel:-1}"
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "${#backups[@]}" ]]; then
    warn "Invalid selection."; return 1
  fi

  local chosen="${backups[$((sel-1))]}"
  echo ""
  echo -e "  Restoring: ${CYAN}$(basename "$chosen")${RESET}"
  echo ""
  warn "This will OVERWRITE current config files with the selected backup."
  warn "Running containers will not be stopped — redeploy after restore to apply changes."
  echo ""
  read -rp "  Proceed? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }

  echo ""
  info "Extracting archive..."
  if tar -xzf "$chosen" -C / 2>/dev/null; then
    # Re-source .env so restored values are active for the steps below
    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
    # acme.json must always be root:root 600 — recreate it fresh if absent
    local acme="${CONFIG_ROOT:-/opt/friendbox/config}/traefik/acme.json"
    mkdir -p "$(dirname "$acme")"
    [[ ! -f "$acme" ]] && touch "$acme"
    chown root:root "$acme"; chmod 600 "$acme"
    # Fix ownership of all restored files
    _fix_install_dir_ownership
    # Regenerate traefik.yml from restored .env so it matches current provider settings
    if [[ -n "${TRAEFIK_ACME_PROVIDER:-}" ]]; then
      _traefik_write_config && info "traefik.yml regenerated from restored settings."
    fi
    # Re-apply Jellyfin HW accel patch if it was configured in the restored .env.
    # The docker-compose.yml on disk may be newer than the backup and won't have
    # the HW-ACCEL block — re-patching ensures the configured method is active.
    if [[ -n "${JELLYFIN_HW_ACCEL:-}" && "${JELLYFIN_HW_ACCEL}" != "none" ]]; then
      _jellyfin_hw_apply "${JELLYFIN_HW_ACCEL}" \
        && info "Jellyfin HW accel (${JELLYFIN_HW_ACCEL}) re-applied from restored settings."
    fi
    success "Restore complete."
    echo ""
    read -rp "  Redeploy all containers now to apply restored config? [Y/n] " _rd_yn
    if [[ ! "${_rd_yn:-y}" =~ ^[Nn]$ ]]; then
      info "Redeploying containers..."
      _jellyfin_fix_markers
      compose_selected up -d --force-recreate
      success "Containers redeployed with restored config."
    else
      info "Containers are still running with old config — redeploy when ready: option 12"
    fi
  else
    error "Extraction failed — archive may be corrupt."
    return 1
  fi
}

_backup_list_delete() {
  echo ""
  local backups=() f
  while IFS= read -r f; do backups+=("$f"); done \
    < <(ls -1t "${BACKUP_DIR}"/friendbox_backup_*.tar.gz 2>/dev/null)

  if [[ ${#backups[@]} -eq 0 ]]; then
    warn "No backups found in ${BACKUP_DIR}."; return
  fi

  echo -e "${BOLD}Stored Backups${RESET}"
  echo "──────────────────────────────────────────────────────"
  printf "  %-4s %-22s %-8s\n" "No." "Timestamp" "Size"
  echo "──────────────────────────────────────────────────────"
  local i=1
  for f in "${backups[@]}"; do
    local size ts
    size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    ts=$(basename "$f" | sed 's/friendbox_backup_//;s/\.tar\.gz//' | sed 's/_/ /')
    printf "  %-4s %-22s %-8s\n" "${i})" "$ts" "${size:-?}"
    i=$((i+1))
  done
  echo "──────────────────────────────────────────────────────"
  echo ""
  echo "  Enter a number to delete, or press Enter to go back."
  echo ""
  read -rp "  Choice: " sel
  [[ -z "$sel" ]] && return
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "${#backups[@]}" ]]; then
    warn "Invalid selection."; return
  fi
  local target="${backups[$((sel-1))]}"
  read -rp "  Delete $(basename "$target")? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] \
    && rm -f "$target" && success "Deleted $(basename "$target")." \
    || info "Aborted."
}

setup_backup() {
  require_root || return 1
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               💾  Backup & Restore                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    local count newest
    count=$(ls -1 "${BACKUP_DIR}"/friendbox_backup_*.tar.gz 2>/dev/null | wc -l) || count=0
    newest=$(ls -1t "${BACKUP_DIR}"/friendbox_backup_*.tar.gz 2>/dev/null | head -1)
    if [[ "$count" -gt 0 && -n "$newest" ]]; then
      local newest_ts
      newest_ts=$(basename "$newest" | sed 's/friendbox_backup_//;s/\.tar\.gz//' | sed 's/_/ /')
      echo -e "  ${BOLD}Backups stored :${RESET} ${count}  ${DIM}(max 10 kept)${RESET}"
      echo -e "  ${BOLD}Most recent    :${RESET} ${newest_ts}"
    else
      echo -e "  ${BOLD}Backups stored :${RESET} ${YELLOW}none${RESET}"
    fi
    echo -e "  ${BOLD}Backup location:${RESET} ${BACKUP_DIR}"
    echo ""
    echo "  1) Create backup now"
    echo "  2) Restore from backup"
    echo "  3) List / delete backups"
    echo "  4) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) backup_config        || true; pause ;;
      2) restore_config       || true; pause ;;
      3) _backup_list_delete  || true; pause ;;
      4) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

check_port_conflicts() {
  # Warn if ports needed by selected containers are already bound by a non-Docker process.
  # Pass --interactive to prompt the user whether to continue after showing conflicts.
  # Without the flag, just report and return 0 (informational mode for menu option 15).
  local _interactive=false
  [[ "${1:-}" == "--interactive" ]] && _interactive=true
  load_selected
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

  declare -A _PM=(
    [traefik]="80/tcp:HTTP 443/tcp:HTTPS 8080/tcp:Traefik-dashboard"
    [portainer]="9000/tcp:Portainer"
    [plex]="32400/tcp:Plex 32410/udp:Plex-GDM1 32412/udp:Plex-GDM2 32413/udp:Plex-GDM3 32414/udp:Plex-GDM4"
    [jellyfin]="8096/tcp:Jellyfin"
    [sonarr]="8989/tcp:Sonarr"
    [radarr]="7878/tcp:Radarr"
    [prowlarr]="9696/tcp:Prowlarr"
    [bazarr]="6767/tcp:Bazarr"
    [qbittorrent]="8082/tcp:qBittorrent 6881/tcp:qBT-peer 6881/udp:qBT-peer-UDP"
    [qbittorrentvpn]="8181/tcp:qBittorrentVPN"
    [delugevpn]="8112/tcp:DelugeVPN 58846/tcp:Deluge-daemon"
    [nzbget]="6789/tcp:NZBGet"
    [overseerr]="5055/tcp:Overseerr"
    [ombi]="3579/tcp:Ombi"
    [jellyseerr]="5056/tcp:Jellyseerr"
    [ampmc]="8085/tcp:AMP 25565/tcp:Minecraft"
    [netbootxyz]="69/udp:TFTP 3000/tcp:NetbootXYZ 8083/tcp:NetbootXYZ-assets"
    [mumble]="64738/tcp:Mumble-TCP 64738/udp:Mumble-UDP"
    [teamspeak6]="9987/udp:TS6-voice 10011/tcp:TS6-query 30033/tcp:TS6-filetransfer"
  )

  local conflicts=0 key entry port proto label
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -z "${SELECTED[$key]+_}" ]] && continue
    [[ -z "${_PM[$key]+_}" ]] && continue
    for entry in ${_PM[$key]}; do
      port="${entry%%/*}"
      proto="${entry##*/}"; proto="${proto%%:*}"
      label="${entry##*:}"
      local ss_flag="-tlnp"; [[ "$proto" == "udp" ]] && ss_flag="-ulnp"
      if ss $ss_flag 2>/dev/null | grep -q ":${port} "; then
        local holder
        holder=$(ss $ss_flag 2>/dev/null | awk "/:${port} /{print \$NF}" | head -1)
        echo "$holder" | grep -qi "docker\|proxy" && continue
        warn "Port ${port}/${proto} (${label}) is already in use by: ${holder:-unknown}"
        conflicts=$((conflicts + 1))
      fi
    done
  done

  if [[ $conflicts -gt 0 ]]; then
    echo ""
    warn "${conflicts} port conflict(s) found — affected containers may fail to start silently."
    echo ""
    if [[ "$_interactive" == "true" ]]; then
      read -rp "  Continue anyway? [y/N] " yn
      [[ "$yn" =~ ^[Yy]$ ]] || return 1
    fi
  else
    success "No port conflicts detected."
  fi
}

ensure_network() {
  if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Start it with: sudo systemctl start docker"
  fi

  # Find ALL Docker networks whose name contains "medianet" — catches both
  # "medianet" (current) and "friendbox_medianet" (created by older Compose
  # versions that prefixed the name with the project directory).
  local stale_nets
  stale_nets=$(docker network ls --format '{{.Name}}' | grep -i "medianet" || true)

  if [[ -z "$stale_nets" ]]; then
    success "No existing medianet network — will be created on first start."
    return 0
  fi

  local net
  for net in $stale_nets; do
    if [[ "$net" == "medianet" ]]; then
      success "Docker network 'medianet' already exists."
      return 0
    fi

    # Stale variant (e.g. friendbox_medianet) — remove it
    warn "Found stale network '${net}' — removing so Compose can recreate as 'medianet'..."
    local attached
    attached=$(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
    if [[ -n "$attached" ]]; then
      info "Stopping containers attached to ${net}: ${attached}"
      docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down 2>/dev/null || true
    fi
    if docker network rm "$net" 2>/dev/null; then
      success "Removed stale network '${net}'."
    else
      error "Could not remove network '${net}'. Try manually: docker network rm ${net}"
      return 1
    fi
  done
}

ensure_acme() {
  # Only needed when Traefik is selected
  load_selected
  if [[ -z "${SELECTED[traefik]+_}" ]]; then
    info "Traefik not selected — skipping acme.json setup."
    return
  fi
  local acme_path="${INSTALL_DIR}/config/traefik/acme.json"
  mkdir -p "$(dirname "$acme_path")"
  [[ -f "$acme_path" ]] || touch "$acme_path"
  # Traefik v3 runs as root inside the container — acme.json must be root:root 600.
  # If owned by another user, Traefik can read but not write it, causing the
  # "Testing certificate renew" loop.
  chown root:root "$acme_path"
  chmod 600 "$acme_path"
  success "acme.json ready (owner: root:root, permissions: 600)."
  # Always (re)generate traefik.yml from current settings before deploying
  _traefik_write_config
  # Always (re)generate the standalone redeploy helper before deploying
  generate_redeploy_sh
}

# ── Directory provisioning ────────────────────────────────────────────────────

# =============================================================================
#  Jellyfin — Hardware Acceleration
# =============================================================================
# Supported acceleration methods:
#
#   vaapi  — Intel iGPU (Quick Sync) and AMD GPU.
#            Host requirements:
#              • i915, xe (Intel), or amdgpu (AMD) kernel module loaded
#              • /dev/dri/renderD128 and /dev/dri/card0 device nodes present
#              • 'render' group exists (created automatically by the driver)
#            Compose requirements:
#              • devices: /dev/dri mounts
#              • group_add: render GID (so the container can open renderD128)
#
#   nvenc  — NVIDIA GPU via NVENC hardware encoder.
#            Host requirements:
#              • NVIDIA proprietary driver installed
#              • nvidia-container-toolkit installed
#              • Docker nvidia runtime registered
#                (sudo nvidia-ctk runtime configure --runtime=docker
#                 then: sudo systemctl restart docker)
#            Compose requirements:
#              • runtime: nvidia
#              • NVIDIA_VISIBLE_DEVICES / NVIDIA_DRIVER_CAPABILITIES env vars
#
#   none   — Software (CPU) transcoding. No special host or compose changes.
#
# _jellyfin_hw_apply() surgically patches docker-compose.yml, fenced by
# "# HW-ACCEL-START" / "# HW-ACCEL-END" markers. Safe to call multiple times;
# previous patches are removed before the new one is inserted.
# =============================================================================

_jellyfin_detect_gpu() {
  # Probe available GPU hardware.
  # Each detected device is emitted as one pipe-separated line:
  #   TYPE|DEVICE_NAME|DRIVER_STATUS|NOTE
  # TYPE: intel | amd | nvidia | unknown
  #
  # lspci default output format:
  #   "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 630 (rev 02)"
  #   "01:00.0 3D controller: NVIDIA Corporation GP107M [GeForce GTX 1050 Ti Mobile]"
  #   "00:08.1 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Radeon 680M"
  # The class keyword (VGA/3D/Display) appears BEFORE the vendor name.
  # We match on the class first, then identify vendor from the same line.

  if command -v lspci &>/dev/null; then
    while IFS= read -r _line; do
      local _name _type _drv
      # Strip the PCI address prefix and class label to get a clean device name
      _name=$(echo "$_line" | sed 's/^[0-9a-fA-F.:]*[[:space:]]*//' \
                            | sed 's/^[^:]*: //')

      # Identify vendor from the device description.
      # virtio-gpu must be checked first — its lspci line may contain "[AMD/ATI]"
      # as the subsystem vendor, which would otherwise trigger the AMD branch.
      if echo "$_line" | grep -qi 'virtio'; then
        _type="virtio"
        # virtio-gpu uses the virtio_gpu kernel module (present when /dev/dri exists)
        if lsmod 2>/dev/null | grep -qE '^virtio_gpu[[:space:]]|^virtio-gpu[[:space:]]'; then
          _drv="virtio_gpu loaded (VM display adapter — no HW transcoding)"
        elif [[ -d /dev/dri ]]; then
          _drv="virtio_gpu active (/dev/dri present — no HW transcoding)"
        else
          _drv="NO DRIVER — try: sudo modprobe virtio-gpu"
        fi
      elif echo "$_line" | grep -qi 'intel'; then
        _type="intel"
        if lsmod 2>/dev/null | grep -q '^i915[[:space:]]'; then
          _drv="i915 loaded"
        elif lsmod 2>/dev/null | grep -q '^xe[[:space:]]'; then
          _drv="xe loaded (Arc/Meteor Lake)"
        else
          _drv="NO DRIVER — try: sudo modprobe i915"
        fi
      elif echo "$_line" | grep -qiE 'AMD|Advanced Micro Devices|ATI'; then
        _type="amd"
        if lsmod 2>/dev/null | grep -q '^amdgpu[[:space:]]'; then
          _drv="amdgpu loaded"
        else
          _drv="NO DRIVER — try: sudo modprobe amdgpu"
        fi
      elif echo "$_line" | grep -qi 'NVIDIA'; then
        _type="nvidia"
        if lsmod 2>/dev/null | grep -q '^nvidia[[:space:]]'; then
          _drv="nvidia module loaded"
        else
          _drv="NO DRIVER — install NVIDIA driver"
        fi
      else
        _type="unknown"
        _drv="unknown"
      fi

      echo "${_type}|${_name}|${_drv}|GPU"
    done < <(lspci 2>/dev/null \
      | grep -iE '(VGA compatible controller|3D controller|Display controller)' \
      || true)
  fi

  # ── Fallback when pciutils not installed ──────────────────────────────────
  if ! command -v lspci &>/dev/null; then
    if [[ -d /dev/dri ]]; then
      echo "unknown|/dev/dri present (GPU type unclear)|unknown|install pciutils for GPU details"
    fi
    if [[ -e /dev/nvidia0 ]]; then
      local _drv
      lsmod 2>/dev/null | grep -q '^nvidia[[:space:]]' \
        && _drv="nvidia module loaded" || _drv="NO DRIVER"
      echo "nvidia|/dev/nvidia0 device node found|${_drv}|NVIDIA GPU"
    fi
  fi
}

_jellyfin_hw_check() {
  # Full hardware acceleration diagnostic. Reads the live host state.
  # Safe to call at any time — makes no changes.
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

  echo ""
  echo -e "${BOLD}${CYAN}Jellyfin Hardware Acceleration Diagnostics${RESET}"
  echo "══════════════════════════════════════════════════════════════"
  local _cur="${JELLYFIN_HW_ACCEL:-none}"
  echo -e "  ${BOLD}Configured method :${RESET} ${_cur}"
  echo ""

  # ── 1. GPU detection via lspci / device nodes ────────────────────────────
  echo -e "  ${BOLD}── Detected GPUs ──────────────────────────────────────────${RESET}"
  local _gpus=() _g
  while IFS= read -r _g; do
    [[ -n "$_g" ]] && _gpus+=("$_g")
  done < <(_jellyfin_detect_gpu)

  local _virtio_found=false
  if [[ ${#_gpus[@]} -eq 0 ]]; then
    if ! command -v lspci &>/dev/null; then
      echo -e "  ${YELLOW}[WARN]${RESET}  No GPU detected — lspci not available."
      echo -e "         ${DIM}Install pciutils for GPU detection: sudo apt install pciutils${RESET}"
    else
      echo -e "  ${YELLOW}[WARN]${RESET}  No display/GPU device found via lspci."
      echo -e "         ${DIM}This may be a headless or virtual machine with no GPU passthrough.${RESET}"
    fi
  else
    for _g in "${_gpus[@]}"; do
      local _type _name _drv _note
      IFS='|' read -r _type _name _drv _note <<< "$_g"
      local _col="${CYAN}"
      [[ "$_drv" == *"NO DRIVER"* ]] && _col="${RED}"
      [[ "$_type" == "virtio" ]] && _col="${YELLOW}"
      echo -e "  ${_col}[${_type^^}]${RESET}  ${_name}"
      echo -e "         ${DIM}Driver : ${_drv}${RESET}"
      [[ "$_type" == "virtio" ]] && _virtio_found=true
    done
    if [[ "$_virtio_found" == "true" ]]; then
      echo ""
      echo -e "  ${YELLOW}[NOTE]${RESET}  virtio-gpu is a paravirtual display adapter for VMs."
      echo -e "         ${DIM}It provides /dev/dri nodes but does NOT support hardware video${RESET}"
      echo -e "         ${DIM}encode/decode (VA-API transcoding). Jellyfin should be configured${RESET}"
      echo -e "         ${DIM}to use software (CPU) transcoding on this host.${RESET}"
    fi
  fi
  echo ""

  # ── 2. /dev/dri device nodes ────────────────────────────────────────────
  echo -e "  ${BOLD}── /dev/dri Device Nodes (VA-API) ─────────────────────────${RESET}"
  if [[ -d /dev/dri ]]; then
    local _node _found_render=false
    for _node in /dev/dri/card* /dev/dri/renderD*; do
      [[ -e "$_node" ]] || continue
      local _perms _owner
      _perms=$(stat -c "%a" "$_node" 2>/dev/null)
      _owner=$(stat -c "%U:%G" "$_node" 2>/dev/null)
      echo -e "  ${GREEN}[FOUND]${RESET}  ${_node}  ${DIM}(perms ${_perms}  owner ${_owner})${RESET}"
      [[ "$_node" == */renderD* ]] && _found_render=true
    done
    if [[ "$_found_render" == "false" ]]; then
      echo -e "  ${YELLOW}[WARN]${RESET}  /dev/dri exists but no renderD* node found."
      echo -e "         ${DIM}renderD128 is required for VA-API transcoding.${RESET}"
    fi
  else
    echo -e "  ${YELLOW}[NONE]${RESET}   /dev/dri directory not present on this host."
    echo -e "         ${DIM}Normal on NVIDIA-only or CPU-only systems.${RESET}"
    echo -e "         ${DIM}Intel iGPU: sudo modprobe i915   AMD: sudo modprobe amdgpu${RESET}"
  fi
  echo ""

  # ── 3. render / video groups ─────────────────────────────────────────────
  echo -e "  ${BOLD}── Device Groups ──────────────────────────────────────────${RESET}"
  local _rgid _vgid
  _rgid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
  _vgid=$(getent group video  2>/dev/null | cut -d: -f3 || true)
  if [[ -n "$_rgid" ]]; then
    echo -e "  ${GREEN}[OK]${RESET}    render group  GID ${_rgid}"
    echo -e "         ${DIM}Containers in this group can open /dev/dri/renderD* nodes.${RESET}"
  else
    echo -e "  ${YELLOW}[WARN]${RESET}  render group not found."
    echo -e "         ${DIM}Created automatically when the GPU driver module loads.${RESET}"
    echo -e "         ${DIM}Manual fix if needed: sudo groupadd -r render${RESET}"
  fi
  if [[ -n "$_vgid" ]]; then
    echo -e "  ${GREEN}[OK]${RESET}    video group   GID ${_vgid}"
  else
    echo -e "  ${DIM}[INFO]  video group not found (optional for most setups)${RESET}"
  fi
  echo ""

  # ── 4. NVIDIA toolkit / runtime ─────────────────────────────────────────
  echo -e "  ${BOLD}── NVIDIA Stack ───────────────────────────────────────────${RESET}"
  local _nvidia_gpu=false
  if command -v nvidia-smi &>/dev/null; then
    local _smi
    _smi=$(nvidia-smi --query-gpu=name,driver_version,memory.total \
      --format=csv,noheader 2>/dev/null | head -4)
    if [[ -n "$_smi" ]]; then
      _nvidia_gpu=true
      echo -e "  ${GREEN}[OK]${RESET}    nvidia-smi — GPU(s) detected:"
      while IFS= read -r _l; do
        echo -e "         ${DIM}${_l}${RESET}"
      done <<< "$_smi"
    else
      echo -e "  ${YELLOW}[WARN]${RESET}  nvidia-smi present but returned no GPU."
    fi
  else
    echo -e "  ${DIM}[SKIP]  nvidia-smi not found — no NVIDIA GPU or driver missing.${RESET}"
  fi

  local _nctk=false
  if command -v nvidia-ctk &>/dev/null \
     || dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
    _nctk=true
    echo -e "  ${GREEN}[OK]${RESET}    nvidia-container-toolkit installed"
  else
    if [[ "$_nvidia_gpu" == "true" ]]; then
      echo -e "  ${RED}[FAIL]${RESET}  nvidia-container-toolkit NOT installed"
      echo -e "         ${DIM}Required for Docker GPU passthrough. Install guide:${RESET}"
      echo -e "         ${DIM}https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/${RESET}"
    else
      echo -e "  ${DIM}[SKIP]  nvidia-container-toolkit — not applicable${RESET}"
    fi
  fi

  if docker info 2>/dev/null | grep -q "nvidia"; then
    echo -e "  ${GREEN}[OK]${RESET}    Docker nvidia runtime registered"
  else
    if [[ "$_nvidia_gpu" == "true" ]]; then
      echo -e "  ${RED}[FAIL]${RESET}  Docker nvidia runtime NOT registered"
      echo -e "         ${DIM}sudo nvidia-ctk runtime configure --runtime=docker${RESET}"
      echo -e "         ${DIM}sudo systemctl restart docker${RESET}"
    else
      echo -e "  ${DIM}[SKIP]  Docker nvidia runtime — not applicable${RESET}"
    fi
  fi
  echo ""

  # ── 5. VA-API userspace check ───────────────────────────────────────────
  echo -e "  ${BOLD}── VA-API Userspace (Intel / AMD) ─────────────────────────${RESET}"
  # Locate vainfo — it may live at /usr/bin/vainfo or be installed but not in PATH
  local _vainfo_bin
  _vainfo_bin=$(command -v vainfo 2>/dev/null     || { [[ -x /usr/bin/vainfo ]] && echo /usr/bin/vainfo; }     || true)
  if [[ -n "$_vainfo_bin" ]]; then
    # vainfo requires XDG_RUNTIME_DIR. When running as root under sudo this is
    # typically unset, causing "XDG_RUNTIME_DIR is invalid or not set" errors
    # that have nothing to do with VA-API support. Set a temporary dir if needed.
    local _xdg_tmp=""
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
      _xdg_tmp="/tmp/.va-diag-$$"
      mkdir -p "$_xdg_tmp"
      export XDG_RUNTIME_DIR="$_xdg_tmp"
    fi
    local _va
    # Capture full output (not head -8) so we can count profiles from it without
    # a second invocation. The temp XDG dir is cleaned up immediately after, so
    # any second vainfo call would point to a deleted directory.
    _va=$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" "$_vainfo_bin" 2>&1)
    [[ -n "$_xdg_tmp" ]] && { rm -rf "$_xdg_tmp"; unset XDG_RUNTIME_DIR; }
    if echo "$_va" | grep -q "vainfo: Supported"; then
      local _cnt
      _cnt=$(echo "$_va" | grep -c "VAProfile" || true)
      echo -e "  ${GREEN}[OK]${RESET}    vainfo — VA-API available (${_cnt} profiles)"
    elif echo "$_va" | grep -qiE "XDG_RUNTIME_DIR|can.t connect to X"; then
      echo -e "  ${YELLOW}[WARN]${RESET}  vainfo: XDG_RUNTIME_DIR error (display not accessible as root)"
      echo -e "         ${DIM}VA-API library is present; run vainfo as a normal user to verify.${RESET}"
    else
      echo -e "  ${YELLOW}[WARN]${RESET}  vainfo reported an error:"
      echo -e "         ${DIM}$(echo "$_va" | head -3)${RESET}"
    fi
  elif dpkg -l vainfo 2>/dev/null | grep -q '^ii'     || dpkg -l libva-utils 2>/dev/null | grep -q '^ii'; then
    echo -e "  ${YELLOW}[WARN]${RESET}  vainfo package is installed but binary not found in PATH."
    echo -e "         ${DIM}Try: /usr/bin/vainfo  or reinstall: sudo apt install --reinstall vainfo${RESET}"
  else
    echo -e "  ${DIM}[INFO]  vainfo not installed — optional deeper VA-API capability check.${RESET}"
    echo -e "         ${DIM}Install: sudo apt install vainfo${RESET}"
  fi
  echo ""

  # ── 6. Compose patch state ──────────────────────────────────────────────
  echo -e "  ${BOLD}── docker-compose.yml Patch State ─────────────────────────${RESET}"
  if [[ -f "$COMPOSE_FILE" ]]; then
    if grep -q "HW-ACCEL-VAAPI" "$COMPOSE_FILE" 2>/dev/null; then
      echo -e "  ${GREEN}[ACTIVE]${RESET} VA-API (Intel/AMD) device passthrough applied"
      # Check whether the GID in the file still matches the live system
      local _live_rgid
      _live_rgid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
      if [[ -n "$_live_rgid" ]]; then
        if grep -q "\"${_live_rgid}\"  # render" "$COMPOSE_FILE" 2>/dev/null; then
          echo -e "         ${DIM}render GID ${_live_rgid} matches compose group_add — OK${RESET}"
        else
          echo -e "  ${YELLOW}[STALE]${RESET} render GID in compose does not match live GID ${_live_rgid}"
          echo -e "         ${DIM}Re-run option 5 → Jellyfin HW accel to refresh.${RESET}"
        fi
      fi
    elif grep -q "HW-ACCEL-NVENC" "$COMPOSE_FILE" 2>/dev/null; then
      echo -e "  ${GREEN}[ACTIVE]${RESET} NVIDIA NVENC passthrough applied"
    else
      echo -e "  ${DIM}[NONE]${RESET}   No HW accel patch in compose (software transcoding)"
    fi
  else
    echo -e "  ${DIM}[SKIP]  compose file not found — install first${RESET}"
  fi
  echo ""
  echo -e "  ${DIM}To configure: option 5 → Jellyfin hardware acceleration${RESET}"
  echo -e "  ${DIM}To apply:     option 12 → redeploy single container → select Jellyfin${RESET}"
  echo ""
}

_jellyfin_hw_apply() {
  # Patch docker-compose.yml to configure hardware acceleration for Jellyfin.
  # Argument: vaapi | nvenc | none
  # Uses Python to surgically modify only the jellyfin service block.
  # Fenced with "# HW-ACCEL-START" / "# HW-ACCEL-END" — safe to call repeatedly.
  local _method="${1:-none}"

  [[ -f "$COMPOSE_FILE" ]] \
    || { warn "compose file not found — run Full Install (option 1) first."; return 1; }
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

  # Collect live group IDs for the group_add block
  local _rgid _vgid
  _rgid=$(getent group render 2>/dev/null | cut -d: -f3 || echo "")
  _vgid=$(getent group video  2>/dev/null | cut -d: -f3 || echo "")

  info "Patching docker-compose.yml for Jellyfin HW accel: ${_method}..."

  python3 - "$COMPOSE_FILE" "$_method" "$_rgid" "$_vgid" << 'PYEOF'
import sys, re

path   = sys.argv[1]
method = sys.argv[2]   # vaapi | nvenc | none
rgid   = sys.argv[3]   # render group GID (may be empty string)
vgid   = sys.argv[4]   # video  group GID (may be empty string)

with open(path) as f:
    content = f.read()

# ── Step 1: Strip any previous HW-ACCEL fenced block ─────────────────────────
lines   = content.split('\n')
cleaned = []
inside  = False
for ln in lines:
    if '# HW-ACCEL-START' in ln:
        inside = True
        continue
    if '# HW-ACCEL-END' in ln:
        inside = False
        continue
    if not inside:
        cleaned.append(ln)
content = '\n'.join(cleaned)

# ── Step 2: Build the new fenced block ───────────────────────────────────────
# The bare environment block that the original compose has (3 lines of indent).
BARE_ENV = (
    '    environment:\n'
    '      - PUID=${PUID}\n'
    '      - PGID=${PGID}\n'
    '      - TZ=${TZ}'
)

if method == 'vaapi':
    grp = ''
    if rgid:
        grp += f'      - "{rgid}"  # render — allows container to open /dev/dri/renderD*\n'
    if vgid:
        grp += f'      - "{vgid}"  # video\n'
    if not grp:
        grp  =  '      # render group not found on this host; add GID manually if needed\n'
    block = (
        '    # HW-ACCEL-START\n'
        '    # HW-ACCEL-VAAPI — managed by friendbox (option 5 → Jellyfin HW accel)\n'
        '    # VA-API hardware transcoding — Intel iGPU (Quick Sync) and AMD GPU.\n'
        '    # Requires: GPU driver loaded, /dev/dri/renderD128 present, render group exists.\n'
        '    # To disable: option 5 → Jellyfin HW accel → None.\n'
        '    devices:\n'
        '      - /dev/dri/renderD128:/dev/dri/renderD128\n'
        '      - /dev/dri/card0:/dev/dri/card0\n'
        '    group_add:\n'
        + grp
        + '    environment:\n'
        '      - PUID=${PUID}\n'
        '      - PGID=${PGID}\n'
        '      - TZ=${TZ}\n'
        '      - JELLYFIN_HW_ACCEL=vaapi\n'
        '    # HW-ACCEL-END'
    )
elif method == 'nvenc':
    block = (
        '    # HW-ACCEL-START\n'
        '    # HW-ACCEL-NVENC — managed by friendbox (option 5 → Jellyfin HW accel)\n'
        '    # NVIDIA NVENC hardware transcoding.\n'
        '    # Requires: NVIDIA driver, nvidia-container-toolkit, Docker nvidia runtime.\n'
        '    # To disable: option 5 → Jellyfin HW accel → None.\n'
        '    runtime: nvidia\n'
        '    environment:\n'
        '      - PUID=${PUID}\n'
        '      - PGID=${PGID}\n'
        '      - TZ=${TZ}\n'
        '      - NVIDIA_VISIBLE_DEVICES=all\n'
        '      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility\n'
        '      - JELLYFIN_HW_ACCEL=nvenc\n'
        '    # HW-ACCEL-END'
    )
else:
    block = None  # none — just restore bare environment:

# ── Step 3: Locate the jellyfin service block ─────────────────────────────────
jf_start = content.find('\n  jellyfin:\n')
if jf_start == -1:
    print('ERROR: jellyfin service not found in compose file', file=sys.stderr)
    sys.exit(1)

# End of jellyfin block = start of the next top-level service key (2-space indent)
nxt = re.search(r'\n  [a-zA-Z]', content[jf_start + 1:])
jf_end = (jf_start + 1 + nxt.start()) if nxt else len(content)
jf_section = content[jf_start:jf_end]

# ── Step 4: Splice the block in / restore bare env ───────────────────────────
if block is not None:
    # Replace the bare environment block with our new fenced block.
    if BARE_ENV in jf_section:
        jf_section = jf_section.replace(BARE_ENV, block, 1)
    else:
        # Bare env was already replaced by a previous patch (which we just stripped).
        # Insert before the volumes: key.
        jf_section = re.sub(
            r'(\n    volumes:)',
            '\n' + block + r'\1',
            jf_section, count=1
        )
else:
    # Restore bare environment if it is missing after stripping the old block.
    if BARE_ENV not in jf_section:
        jf_section = jf_section.replace(
            '\n    volumes:',
            '\n' + BARE_ENV + '\n    volumes:',
            1
        )

content = content[:jf_start] + jf_section + content[jf_end:]

with open(path, 'w') as f:
    f.write(content)

print(f'compose patched: {method}')
PYEOF

  local _rc=$?
  if [[ $_rc -eq 0 ]]; then
    # Record the chosen method in .env so other functions can read it
    sed -i '/^JELLYFIN_HW_ACCEL=/d' "$ENV_FILE" 2>/dev/null || true
    echo "JELLYFIN_HW_ACCEL=${_method}" >> "$ENV_FILE"
    _own "$COMPOSE_FILE"
    success "docker-compose.yml updated — Jellyfin HW accel: ${_method}"
    info "Redeploy Jellyfin to activate: option 12 → option 2 → select Jellyfin"
  else
    warn "Compose patch failed — file is unchanged."
    return 1
  fi
}

_jellyfin_hw_setup() {
  # Interactive wizard to select and apply hardware acceleration for Jellyfin.
  # The detection summary and menu are printed at the top of every loop iteration
  # so that returning from the full diagnostic (option 4) always shows the full menu.
  local _has_dri=false _has_nvidia=false _has_intel=false _has_amd=false _rgid _nctk _cur _yn _sel

  while true; do
    clear
    echo ""
    echo -e "${BOLD}Jellyfin — Hardware Acceleration${RESET}"
    echo -e "${DIM}  Offloads video transcoding to a GPU, dramatically reducing CPU"
    echo -e "  usage for 4K, HDR, and HEVC streams.${RESET}"
    echo ""

    # Re-probe live state on every iteration so display stays accurate
    _has_dri=false; _has_nvidia=false; _has_intel=false; _has_amd=false
    [[ -d /dev/dri ]] && _has_dri=true
    if [[ "$_has_dri" == "true" ]]; then
      lsmod 2>/dev/null | grep -qE '^i915[[:space:]]|^xe[[:space:]]' && _has_intel=true
      lsmod 2>/dev/null | grep -q '^amdgpu[[:space:]]'               && _has_amd=true
    fi
    command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1 && _has_nvidia=true

    # Show hardware found via lspci, then layer driver/runtime status on top
    local _gpu_line _gpu_shown=false
    while IFS= read -r _gpu_line; do
      local _gtype _gname _gdrv
      IFS='|' read -r _gtype _gname _gdrv _ <<< "$_gpu_line"
      local _gcol="${CYAN}"
      [[ "$_gdrv" == *"NO DRIVER"* ]] && _gcol="${YELLOW}"
      echo -e "  ${_gcol}[${_gtype^^}]${RESET}  ${_gname}"
      echo -e "         ${DIM}Driver : ${_gdrv}${RESET}"
      _gpu_shown=true
      [[ "$_gtype" == "intel" || "$_gtype" == "amd" ]] && _has_dri=true
      if [[ "$_gtype" == "virtio" ]]; then
        echo -e "  ${YELLOW}[NOTE]${RESET}   virtio-gpu detected — paravirtual adapter, no HW transcoding"
        echo -e "           ${DIM}VA-API is not available on virtio-gpu. Use option 3 (None).${RESET}"
      fi
    done < <(_jellyfin_detect_gpu)

    if [[ "$_gpu_shown" == "false" ]]; then
      echo -e "  ${DIM}[INFO]  No GPU detected via lspci / device nodes${RESET}"
    fi
    echo ""

    # VA-API readiness (Intel/AMD)
    if [[ "$_has_dri" == "true" ]]; then
      echo -e "  ${GREEN}[VA-API]${RESET}  /dev/dri present"
    else
      echo -e "  ${DIM}[VA-API]  /dev/dri not found — Intel/AMD hardware acceleration unavailable${RESET}"
    fi

    # NVIDIA readiness
    if [[ "$_has_nvidia" == "true" ]]; then
      echo -e "  ${GREEN}[NVIDIA]${RESET}  nvidia-smi OK"
      _nctk=false
      { command -v nvidia-ctk &>/dev/null \
        || dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; } && _nctk=true
      if [[ "$_nctk" == "false" ]]; then
        echo -e "  ${RED}[NVIDIA]${RESET}  nvidia-container-toolkit missing — required for Docker GPU passthrough"
        echo -e "           ${DIM}Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/${RESET}"
      fi
      if ! docker info 2>/dev/null | grep -q "nvidia"; then
        echo -e "  ${RED}[NVIDIA]${RESET}  Docker nvidia runtime not registered"
        echo -e "           ${DIM}Fix: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker${RESET}"
      fi
    fi

    _rgid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
    if [[ "$_has_dri" == "true" && -z "$_rgid" ]]; then
      echo -e "  ${YELLOW}[WARN]${RESET}    render group not found — VA-API access may fail"
      echo -e "           ${DIM}Fix: sudo groupadd -r render${RESET}"
    fi

    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
    _cur="${JELLYFIN_HW_ACCEL:-none}"
    echo ""
    echo -e "  Current : ${BOLD}${_cur}${RESET}"
    echo ""
    echo "  1) VA-API  — Intel iGPU (Quick Sync) / AMD  [needs /dev/dri]"
    echo "  2) NVENC   — NVIDIA GPU                     [needs nvidia-container-toolkit]"
    echo "  3) None    — Software transcoding            [no GPU required]"
    echo "  4) Run full diagnostic"
    echo "  q) Cancel"
    echo ""

    read -rp "  Choice: " _sel
    case "$_sel" in
      1)
        if [[ "$_has_dri" == "false" ]]; then
          echo ""
          warn "/dev/dri not found — VA-API requires Intel/AMD GPU with driver loaded."
          warn "The compose patch can still be applied; the container will fail to"
          warn "start until the GPU driver is installed and /dev/dri appears."
          echo ""
          read -rp "  Apply VA-API patch anyway? [y/N] " _yn
          [[ "${_yn}" =~ ^[Yy]$ ]] || continue
        fi
        _jellyfin_hw_apply vaapi || return 1
        echo ""
        echo -e "  ${BOLD}After redeploying, finish setup in the Jellyfin web UI:${RESET}"
        echo -e "  ${DIM}  Admin → Playback → Transcoding${RESET}"
        echo -e "  ${DIM}  Hardware acceleration : VA-API${RESET}"
        echo -e "  ${DIM}  VA-API device         : /dev/dri/renderD128${RESET}"
        echo -e "  ${DIM}  Enable the codec checkboxes your GPU supports.${RESET}"
        return 0 ;;
      2)
        if [[ "$_has_nvidia" == "false" ]]; then
          echo ""
          warn "NVIDIA GPU not confirmed via nvidia-smi."
          read -rp "  Apply NVENC patch anyway? [y/N] " _yn
          [[ "${_yn}" =~ ^[Yy]$ ]] || continue
        fi
        _jellyfin_hw_apply nvenc || return 1
        echo ""
        echo -e "  ${BOLD}After redeploying, finish setup in the Jellyfin web UI:${RESET}"
        echo -e "  ${DIM}  Admin → Playback → Transcoding${RESET}"
        echo -e "  ${DIM}  Hardware acceleration : NVENC${RESET}"
        echo -e "  ${DIM}  Enable NVENC encoder and relevant codec checkboxes.${RESET}"
        return 0 ;;
      3)
        _jellyfin_hw_apply none || return 1
        return 0 ;;
      4)
        _jellyfin_hw_check
        echo -e "  ${DIM}Press Enter to return to the menu...${RESET}"
        read -r _dummy || true ;;
      q|Q) info "Cancelled."; return 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

_jellyfin_fix_markers() {
  # Jellyfin writes path-marker files on first start (.jellyfin-config, .jellyfin-data,
  # etc.) to identify how each directory is being used. If the config directory was
  # previously mounted as a different Jellyfin path, the wrong marker causes an
  # unhandled exception crash-loop on every subsequent start.
  # Run this before every compose up to catch the problem before it occurs.
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local jf_dir="${CONFIG_ROOT:-/opt/friendbox/config}/jellyfin"
  [[ -d "$jf_dir" ]] || return 0

  local conflict=false
  for marker in "${jf_dir}/.jellyfin-data" "${jf_dir}/.jellyfin-metadata" "${jf_dir}/.jellyfin-plugins"; do
    if [[ -f "$marker" ]]; then
      rm -f "$marker"
      warn "Removed conflicting Jellyfin marker: $(basename "$marker")"
      conflict=true
    fi
  done
  [[ "$conflict" == "true" ]] && success "Jellyfin markers cleared — container will start cleanly."
  return 0
}

provision_directories() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected

  local uid="${PUID:-1000}"
  local gid="${PGID:-1000}"
  local cfg="${CONFIG_ROOT:-/opt/friendbox/config}"
  local media="${MEDIA_ROOT:-/mnt/media}"

  info "Provisioning directories (owner ${uid}:${gid})..."

  # Create system user/group if they don't exist
  if ! getent group "$gid" &>/dev/null; then
    groupadd --gid "$gid" friendbox 2>/dev/null \
      && info "Created group GID ${gid}." \
      || warn "Could not create group GID ${gid} — may already exist."
  fi
  if ! getent passwd "$uid" &>/dev/null; then
    useradd --uid "$uid" --gid "$gid" --no-create-home \
      --shell /usr/sbin/nologin friendbox 2>/dev/null \
      && info "Created user UID ${uid}." \
      || warn "Could not create user UID ${uid} — may already exist."
  fi

  # Create INSTALL_DIR tree and fix ownership of all existing files in it
  _ensure_install_dir
  _fix_install_dir_ownership
  success "  ${INSTALL_DIR}  [${uid}:${gid}] (recursive)"

  # Always-on config dirs
  mkdir -p "${cfg}/traefik" "${cfg}/traefik/dynamic" "${cfg}/portainer"
  chown -R "${uid}:${gid}" "${cfg}/traefik" "${cfg}/portainer"

  # traefik.yml and acme.json must exist as FILES before Traefik starts.
  # Docker auto-creates missing host paths as root:root directories — a dir at
  # either path breaks Traefik silently. Create them here so option 8 is safe.
  if [[ -n "${SELECTED[traefik]+_}" ]]; then
    local _yml="${cfg}/traefik/traefik.yml"
    local _acme="${cfg}/traefik/acme.json"
    # Remove accidental directories at these paths
    [[ -d "$_yml" ]]  && rm -rf "$_yml"  && warn "Removed dir at ${_yml} — replacing with file."
    [[ -d "$_acme" ]] && rm -rf "$_acme" && warn "Removed dir at ${_acme} — replacing with file."
    # Generate traefik.yml if missing or empty
    if [[ ! -s "$_yml" ]]; then
      _traefik_write_config
      success "  ${_yml}  (generated)"
    fi
    # Only write headers.yml when it does not already exist — preserves any
    # user customisations to CSP, frame options, or custom headers.
    # To reset to defaults: rm ${CONFIG_ROOT}/traefik/dynamic/headers.yml
    local _headers="${cfg}/traefik/dynamic/headers.yml"
    mkdir -p "${cfg}/traefik/dynamic"
    if [[ ! -f "$_headers" ]]; then
    cat > "$_headers" <<'HDEOF'
http:
  middlewares:
    secHeaders:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        customFrameOptionsValue: "SAMEORIGIN"
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=(), payment=()"
        customResponseHeaders:
          X-Robots-Tag: "noindex,nofollow,nosnippet,noarchive,notranslate,noimageindex"
HDEOF
    success "  ${_headers}  (written)"
    else
      info "  ${_headers}  (exists — preserved)"
    fi
    # Create acme.json as an empty file with correct ownership if missing
    if [[ ! -f "$_acme" ]]; then
      touch "$_acme"
      success "  ${_acme}  (created)"
    fi
    chown root:root "$_acme"
    chmod 600 "$_acme"
  fi

  # Media root — do NOT chown /mnt itself; it is a system directory
  # that may contain other mounts which rely on root ownership.
  mkdir -p "$media"
  chown "${uid}:${gid}" "$media"

  # Media subdirs — create on every mergerfs branch so the union shows them all.
  # If mergerfs is not configured, fall back to creating directly on the pool path.
  _mergerfs_load_modes
  if [[ ${#DISK_MODES[@]} -gt 0 ]]; then
    _mergerfs_provision_branches
  else
    local subdir
    for subdir in movies tv; do
      mkdir -p "${media}/${subdir}"
      chown "${uid}:${gid}" "${media}/${subdir}"
    done
    # Create downloads if any download client OR any arr that uses it is selected
    local _dl_client
    for _dl_client in qbittorrent qbittorrentvpn delugevpn nzbget sonarr radarr; do
      if [[ -n "${SELECTED[$_dl_client]+_}" ]]; then
        mkdir -p "${media}/downloads"
        chown "${uid}:${gid}" "${media}/downloads"
        break
      fi
    done
    # DelugeVPN uses /data/incomplete for in-progress downloads
    if [[ -n "${SELECTED[delugevpn]+_}" ]]; then
      mkdir -p "${media}/downloads/incomplete"
      chown "${uid}:${gid}" "${media}/downloads/incomplete"
    fi
  fi

  # Per-selected-container config dirs
  declare -A CFG_DIRS=(
    [plex]="plex"               [jellyfin]="jellyfin"
    [sonarr]="sonarr"           [radarr]="radarr"
    [prowlarr]="prowlarr"       [bazarr]="bazarr"
    [qbittorrent]="qbittorrent" [qbittorrentvpn]="qbittorrentvpn"
    [delugevpn]="delugevpn"     [nzbget]="nzbget"
    [overseerr]="overseerr"     [ombi]="ombi"
    [jellyseerr]="jellyseerr"   [teamspeak6]="teamspeak6"
    [mumble]="mumble"           [ampmc]="ampmc"
    [netbootxyz]="netbootxyz"
  )

  local created=0 key dir
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -z "${SELECTED[$key]+_}" ]]  && continue
    [[ -z "${CFG_DIRS[$key]+_}" ]]  && continue
    dir="${cfg}/${CFG_DIRS[$key]}"
    mkdir -p "$dir"
    chown -R "${uid}:${gid}" "$dir"
    success "  ${dir}  [${uid}:${gid}]"
    created=$((created + 1))
  done

  # Plex transcode dir — keeps transcode temp files out of the config volume
  if [[ -n "${SELECTED[plex]+_}" ]]; then
    mkdir -p "${cfg}/plex-transcode"
    chown -R "${uid}:${gid}" "${cfg}/plex-transcode"
    success "  ${cfg}/plex-transcode  [${uid}:${gid}]"
  fi

  # Jellyfin cache dir — must be a persistent host mount or cache is lost on every
  # container recreate, forcing a full metadata/thumbnail regeneration
  if [[ -n "${SELECTED[jellyfin]+_}" ]]; then
    mkdir -p "${cfg}/jellyfin-cache"
    chown -R "${uid}:${gid}" "${cfg}/jellyfin-cache"
    success "  ${cfg}/jellyfin-cache  [${uid}:${gid}]"

    # Verify HW accel prerequisites if a method is configured
    local _jf_hw="${JELLYFIN_HW_ACCEL:-none}"
    if [[ "$_jf_hw" == "vaapi" ]]; then
      if [[ -e /dev/dri/renderD128 ]]; then
        success "  /dev/dri/renderD128  [VA-API device present]"
      else
        warn "Jellyfin VA-API is configured but /dev/dri/renderD128 is missing."
        warn "Verify GPU driver is loaded: lsmod | grep -E 'i915|amdgpu|xe'"
        warn "Reconfigure via option 5 → Jellyfin hardware acceleration."
      fi
      local _jf_rgid
      _jf_rgid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
      if [[ -z "$_jf_rgid" ]]; then
        warn "render group not found — VA-API /dev/dri access may be denied."
        warn "Auto-fix: sudo groupadd -r render  then redeploy Jellyfin."
      fi
    elif [[ "$_jf_hw" == "nvenc" ]]; then
      if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        success "  NVIDIA GPU  [nvidia-smi OK — NVENC ready]"
      else
        warn "Jellyfin NVENC is configured but nvidia-smi reports no GPU."
        warn "Check NVIDIA driver and nvidia-container-toolkit."
        warn "Run option 5 → Jellyfin hardware acceleration for full diagnostics."
      fi
    fi

    # Jellyfin writes marker files (.jellyfin-config, .jellyfin-data, etc.) to
    # whichever directories it uses on first start. If the same host directory
    # was previously used as a different path (e.g. mounted as /data then later
    # as /config), Jellyfin's sanity check throws an unhandled exception and the
    # container crash-loops with "Expected to find only .jellyfin-config but found
    # marker for .jellyfin-data". Detect and remove conflicting markers now, before
    # the container starts, so the user gets a clear message instead of a crash loop.
    local jf_dir="${cfg}/jellyfin"
    if [[ -d "$jf_dir" ]]; then
      local conflict=false
      # A config-mount should contain .jellyfin-config, not .jellyfin-data or others
      for marker in "${jf_dir}/.jellyfin-data" "${jf_dir}/.jellyfin-metadata" "${jf_dir}/.jellyfin-plugins"; do
        if [[ -f "$marker" ]]; then
          warn "Conflicting Jellyfin marker found: ${marker}"
          rm -f "$marker"
          success "Removed conflicting marker: $(basename "$marker")"
          conflict=true
        fi
      done
      if [[ "$conflict" == "true" ]]; then
        info "Conflicting markers removed. Jellyfin will start cleanly."
        info "If Jellyfin was previously working, your config is preserved."
        info "If it still crashes, wipe the config dir:"
        info "  sudo rm -rf ${jf_dir} && sudo friendbox (option 8)"
      fi
    fi
  fi

  if [[ -n "${SELECTED[netbootxyz]+_}" ]]; then
    mkdir -p "${media}/netboot/assets"
    chown -R "${uid}:${gid}" "${media}/netboot"
  fi

  # acme.json must be root:root 600 — Traefik v3 runs as root inside the container
  local acme="${cfg}/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    chown root:root "$acme"
    chmod 600 "$acme"
    success "  ${acme}  [root:root 600]"
  fi

  echo ""
  success "✅ Provisioned ${created} container config dirs + media subdirs."
  echo -e "   ${DIM}Owner: ${uid}:${gid}${RESET}"
}

# =============================================================================
#  DNS A Record Manager
# =============================================================================

_dns_load() {
  DNS_PROVIDER="" DNS_DOMAIN=""
  DNS_CF_EMAIL="" DNS_CF_API_KEY="" DNS_CF_ZONE_ID=""
  DNS_DUCKDNS_TOKEN="" DNS_DUCKDNS_SUBDOMAIN=""
  DNS_GODADDY_KEY="" DNS_GODADDY_SECRET=""
  DNS_NAMECHEAP_USER="" DNS_NAMECHEAP_API_KEY="" DNS_NAMECHEAP_SOURCE_IP=""
  [[ -f "$DNS_STATE_FILE" ]] && source "$DNS_STATE_FILE" 2>/dev/null || true
}

_dns_save() {
  _ensure_install_dir
  # Use printf "%s" for each value so special characters ($, \, spaces) in
  # credentials are written literally and not expanded or truncated.
  # A double-quoted heredoc would expand $VAR sequences inside API keys.
  {
    printf 'DNS_PROVIDER=%s\n'        "$DNS_PROVIDER"
    printf 'DNS_DOMAIN=%s\n'          "$DNS_DOMAIN"
    printf 'DNS_CF_EMAIL=%s\n'        "$DNS_CF_EMAIL"
    printf 'DNS_CF_API_KEY=%s\n'      "$DNS_CF_API_KEY"
    printf 'DNS_CF_ZONE_ID=%s\n'      "$DNS_CF_ZONE_ID"
    printf 'DNS_DUCKDNS_TOKEN=%s\n'   "$DNS_DUCKDNS_TOKEN"
    printf 'DNS_DUCKDNS_SUBDOMAIN=%s\n' "$DNS_DUCKDNS_SUBDOMAIN"
    printf 'DNS_GODADDY_KEY=%s\n'     "$DNS_GODADDY_KEY"
    printf 'DNS_GODADDY_SECRET=%s\n'  "$DNS_GODADDY_SECRET"
    printf 'DNS_NAMECHEAP_USER=%s\n'  "$DNS_NAMECHEAP_USER"
    printf 'DNS_NAMECHEAP_API_KEY=%s\n' "$DNS_NAMECHEAP_API_KEY"
    printf 'DNS_NAMECHEAP_SOURCE_IP=%s\n' "$DNS_NAMECHEAP_SOURCE_IP"
  } > "$DNS_STATE_FILE"
  _own "$DNS_STATE_FILE"
  chmod 600 "$DNS_STATE_FILE"
}

_dns_get_public_ip() {
  local ip
  ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null) \
    || ip=$(curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null) \
    || { warn "Could not detect public IP."; return 1; }
  echo "$ip"
}

_dns_get_subdomains() {
  load_selected 2>/dev/null || true
  declare -A SUB_MAP=(
    [traefik]="traefik"       [portainer]="portainer"
    [plex]="plex"             [jellyfin]="jellyfin"
    [sonarr]="sonarr"         [radarr]="radarr"
    [prowlarr]="prowlarr"     [bazarr]="bazarr"
    [qbittorrent]="qbt"       [qbittorrentvpn]="qbtvpn"
    [delugevpn]="deluge"      [nzbget]="nzbget"
    [overseerr]="overseerr"   [ombi]="ombi"
    [jellyseerr]="jellyseerr" [teamspeak6]="ts6"         [mumble]="mumble"
    [ampmc]="amp"             [netbootxyz]="netboot"
  )
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" && -n "${SUB_MAP[$key]+_}" ]] && echo "${SUB_MAP[$key]}"
  done
}

_dns_show_status() {
  _dns_load
  echo ""
  echo -e "  ${BOLD}Provider :${RESET} ${DNS_PROVIDER:-${YELLOW}not configured${RESET}}"
  echo -e "  ${BOLD}Domain   :${RESET} ${DNS_DOMAIN:-${YELLOW}not configured${RESET}}"
  if [[ -n "$DNS_PROVIDER" ]]; then
    case "$DNS_PROVIDER" in
      cloudflare)
        echo -e "  ${BOLD}CF Email :${RESET} ${DNS_CF_EMAIL:-—}"
        echo -e "  ${BOLD}Zone ID  :${RESET} ${DNS_CF_ZONE_ID:-—}"
        echo -e "  ${BOLD}API Key  :${RESET} ${DNS_CF_API_KEY:+[set]}"
        ;;
      duckdns)
        echo -e "  ${BOLD}Subdomain:${RESET} ${DNS_DUCKDNS_SUBDOMAIN:-—}"
        echo -e "  ${BOLD}Token    :${RESET} ${DNS_DUCKDNS_TOKEN:+[set]}"
        ;;
      godaddy)
        echo -e "  ${BOLD}API Key  :${RESET} ${DNS_GODADDY_KEY:+[set]}"
        echo -e "  ${BOLD}Secret   :${RESET} ${DNS_GODADDY_SECRET:+[set]}"
        ;;
      namecheap)
        echo -e "  ${BOLD}Username :${RESET} ${DNS_NAMECHEAP_USER:-—}"
        echo -e "  ${BOLD}API Key  :${RESET} ${DNS_NAMECHEAP_API_KEY:+[set]}"
        echo -e "  ${BOLD}Source IP:${RESET} ${DNS_NAMECHEAP_SOURCE_IP:-—}"
        ;;
    esac
  fi
  echo ""
}

_dns_configure_cloudflare() {
  _dns_load
  echo ""
  echo -e "${BOLD}Cloudflare — DNS A Record Setup${RESET}"
  echo -e "${DIM}Credentials: dash.cloudflare.com → domain → Overview → API section${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  read -rp "Domain (e.g. example.com) [${DNS_DOMAIN:-}]: " input
  DNS_DOMAIN="${input:-${DNS_DOMAIN:-}}"
  [[ -z "$DNS_DOMAIN" ]] && { warn "Domain required."; return; }
  read -rp "Cloudflare account email [${DNS_CF_EMAIL:-}]: " input
  DNS_CF_EMAIL="${input:-${DNS_CF_EMAIL:-}}"
  read -srp "Global API Key or API Token (press Enter to keep existing): " input; echo ""
  if [[ -n "$input" ]]; then
    DNS_CF_API_KEY="$input"
  elif [[ -z "${DNS_CF_API_KEY:-}" ]]; then
    warn "API key required."; return
  else
    info "API key unchanged."
  fi

  echo ""
  info "Looking up Zone ID for ${DNS_DOMAIN}..."
  local zone_resp zone_id
  zone_resp=$(curl -fsSL --max-time 10 \
    -H "X-Auth-Email: ${DNS_CF_EMAIL}" \
    -H "X-Auth-Key: ${DNS_CF_API_KEY}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=${DNS_DOMAIN}&status=active" 2>/dev/null) || zone_resp=""
  zone_id=$(echo "$zone_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ -n "$zone_id" ]]; then
    success "Zone ID found: ${zone_id}"
    DNS_CF_ZONE_ID="$zone_id"
  else
    warn "Could not auto-detect Zone ID."
    read -rp "Enter Zone ID manually (press Enter to keep existing) [${DNS_CF_ZONE_ID:-}]: " input
    DNS_CF_ZONE_ID="${input:-${DNS_CF_ZONE_ID:-}}"
  fi
  DNS_PROVIDER="cloudflare"
  _dns_save
  success "Cloudflare config saved."
}

_dns_update_cloudflare() {
  _dns_load
  [[ -z "$DNS_CF_API_KEY" || -z "$DNS_CF_ZONE_ID" || -z "$DNS_DOMAIN" ]] \
    && { error "Cloudflare not fully configured."; return 1; }
  local ip; ip=$(_dns_get_public_ip) || return 1
  info "Public IP: ${ip}"

  local subdomains=()
  while IFS= read -r sub; do subdomains+=("$sub"); done < <(_dns_get_subdomains)
  subdomains+=("@")

  local updated=0 failed=0 sub name existing_id payload result
  for sub in "${subdomains[@]}"; do
    [[ "$sub" == "@" ]] && name="${DNS_DOMAIN}" || name="${sub}.${DNS_DOMAIN}"
    existing_id=$(curl -fsSL --max-time 10 \
      -H "X-Auth-Email: ${DNS_CF_EMAIL}" -H "X-Auth-Key: ${DNS_CF_API_KEY}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${DNS_CF_ZONE_ID}/dns_records?type=A&name=${name}" \
      2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    payload="{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}"
    if [[ -n "$existing_id" ]]; then
      result=$(curl -fsSL --max-time 10 -X PUT \
        -H "X-Auth-Email: ${DNS_CF_EMAIL}" -H "X-Auth-Key: ${DNS_CF_API_KEY}" \
        -H "Content-Type: application/json" --data "$payload" \
        "https://api.cloudflare.com/client/v4/zones/${DNS_CF_ZONE_ID}/dns_records/${existing_id}" 2>/dev/null)
    else
      result=$(curl -fsSL --max-time 10 -X POST \
        -H "X-Auth-Email: ${DNS_CF_EMAIL}" -H "X-Auth-Key: ${DNS_CF_API_KEY}" \
        -H "Content-Type: application/json" --data "$payload" \
        "https://api.cloudflare.com/client/v4/zones/${DNS_CF_ZONE_ID}/dns_records" 2>/dev/null)
    fi
    if echo "$result" | grep -q '"success":true'; then
      success "  ${name} → ${ip}"; updated=$((updated + 1))
    else
      warn "  Failed: ${name}"; failed=$((failed + 1))
    fi
  done
  echo ""
  success "Cloudflare: ${updated} records set, ${failed} failed."
}

_dns_configure_duckdns() {
  _dns_load
  echo ""
  echo -e "${BOLD}DuckDNS — DNS Update Setup${RESET}"
  echo -e "${DIM}Free dynamic DNS — token at duckdns.org/account${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  read -rp "DuckDNS subdomain prefix (e.g. 'myhome') [${DNS_DUCKDNS_SUBDOMAIN:-}]: " input
  DNS_DUCKDNS_SUBDOMAIN="${input:-${DNS_DUCKDNS_SUBDOMAIN:-}}"
  [[ -z "$DNS_DUCKDNS_SUBDOMAIN" ]] && { warn "Subdomain required."; return; }
  DNS_DOMAIN="${DNS_DUCKDNS_SUBDOMAIN}.duckdns.org"
  read -srp "DuckDNS token (press Enter to keep existing): " input; echo ""
  if [[ -n "$input" ]]; then
    DNS_DUCKDNS_TOKEN="$input"
  elif [[ -z "${DNS_DUCKDNS_TOKEN:-}" ]]; then
    warn "Token required."; return
  else
    info "Token unchanged."
  fi
  DNS_PROVIDER="duckdns"
  _dns_save
  success "DuckDNS config saved. Domain: ${DNS_DOMAIN}"
}

_dns_update_duckdns() {
  _dns_load
  [[ -z "$DNS_DUCKDNS_TOKEN" || -z "$DNS_DUCKDNS_SUBDOMAIN" ]] \
    && { error "DuckDNS not fully configured."; return 1; }
  local ip; ip=$(_dns_get_public_ip) || return 1
  info "Public IP: ${ip}"
  local result
  result=$(curl -fsSL --max-time 10 \
    "https://www.duckdns.org/update?domains=${DNS_DUCKDNS_SUBDOMAIN}&token=${DNS_DUCKDNS_TOKEN}&ip=${ip}" 2>/dev/null)
  if [[ "$result" == "OK" ]]; then
    success "DuckDNS updated: ${DNS_DUCKDNS_SUBDOMAIN}.duckdns.org → ${ip}"
    warn "DuckDNS supports one hostname — use Traefik routing for multiple services."
  else
    error "DuckDNS update failed: ${result}"
  fi
}

_dns_configure_godaddy() {
  _dns_load
  echo ""
  echo -e "${BOLD}GoDaddy — DNS A Record Setup${RESET}"
  echo -e "${DIM}API keys: developer.godaddy.com → API Keys (use Production, not OTE)${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  read -rp "Domain (e.g. example.com) [${DNS_DOMAIN:-}]: " input
  DNS_DOMAIN="${input:-${DNS_DOMAIN:-}}"
  [[ -z "$DNS_DOMAIN" ]] && { warn "Domain required."; return; }
  read -rp "GoDaddy API Key [${DNS_GODADDY_KEY:-}]: " input
  DNS_GODADDY_KEY="${input:-${DNS_GODADDY_KEY:-}}"
  read -srp "GoDaddy API Secret (press Enter to keep existing): " input; echo ""
  if [[ -n "$input" ]]; then
    DNS_GODADDY_SECRET="$input"
  elif [[ -z "${DNS_GODADDY_SECRET:-}" ]]; then
    warn "Key and secret required."; return
  else
    info "API secret unchanged."
  fi
  [[ -z "$DNS_GODADDY_KEY" ]] && { warn "API key required."; return; }
  DNS_PROVIDER="godaddy"
  _dns_save
  success "GoDaddy config saved."
}

_dns_update_godaddy() {
  _dns_load
  [[ -z "$DNS_GODADDY_KEY" || -z "$DNS_GODADDY_SECRET" || -z "$DNS_DOMAIN" ]] \
    && { error "GoDaddy not fully configured."; return 1; }
  local ip; ip=$(_dns_get_public_ip) || return 1
  info "Public IP: ${ip}"
  local subdomains=()
  while IFS= read -r sub; do subdomains+=("$sub"); done < <(_dns_get_subdomains)
  subdomains+=("@")
  local updated=0 failed=0 payload auth sub http_code label
  payload="[{\"data\":\"${ip}\",\"ttl\":600}]"
  auth="sso-key ${DNS_GODADDY_KEY}:${DNS_GODADDY_SECRET}"
  for sub in "${subdomains[@]}"; do
    http_code=$(curl -fsSL --max-time 10 -o /dev/null -w "%{http_code}" -X PUT \
      -H "Authorization: ${auth}" -H "Content-Type: application/json" \
      --data "$payload" \
      "https://api.godaddy.com/v1/domains/${DNS_DOMAIN}/records/A/${sub}" 2>/dev/null) || http_code="000"
    [[ "$sub" == "@" ]] && label="${DNS_DOMAIN}" || label="${sub}.${DNS_DOMAIN}"
    if [[ "$http_code" == "200" ]]; then
      success "  ${label} → ${ip}"; updated=$((updated + 1))
    else
      warn "  Failed: ${label} (HTTP ${http_code})"; failed=$((failed + 1))
    fi
  done
  echo ""
  success "GoDaddy: ${updated} records set, ${failed} failed."
}

_dns_configure_namecheap() {
  _dns_load
  echo ""
  echo -e "${BOLD}Namecheap — Dynamic DNS Setup${RESET}"
  echo -e "${DIM}Enable Dynamic DNS: Domain List → Manage → Advanced DNS${RESET}"
  echo -e "${DIM}⚠ Namecheap DDNS updates one host at a time via their Dynamic DNS endpoint.${RESET}"
  echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${RESET}"
  echo ""
  read -rp "Namecheap username [${DNS_NAMECHEAP_USER:-}]: " input
  DNS_NAMECHEAP_USER="${input:-${DNS_NAMECHEAP_USER:-}}"
  read -rp "Domain (e.g. example.com) [${DNS_DOMAIN:-}]: " input
  DNS_DOMAIN="${input:-${DNS_DOMAIN:-}}"
  [[ -z "$DNS_DOMAIN" ]] && { warn "Domain required."; return; }
  read -srp "Dynamic DNS Password (press Enter to keep existing): " input; echo ""
  if [[ -n "$input" ]]; then
    DNS_NAMECHEAP_API_KEY="$input"
  elif [[ -z "${DNS_NAMECHEAP_API_KEY:-}" ]]; then
    warn "Password required."; return
  else
    info "Password unchanged."
  fi
  info "Detecting public IP..."
  local pub_ip; pub_ip=$(_dns_get_public_ip 2>/dev/null) || pub_ip=""
  read -rp "Whitelisted public IP (press Enter to use detected) [${DNS_NAMECHEAP_SOURCE_IP:-${pub_ip}}]: " input
  DNS_NAMECHEAP_SOURCE_IP="${input:-${DNS_NAMECHEAP_SOURCE_IP:-${pub_ip}}}"
  DNS_PROVIDER="namecheap"
  _dns_save
  success "Namecheap config saved."
}

_dns_update_namecheap() {
  _dns_load
  [[ -z "$DNS_NAMECHEAP_API_KEY" || -z "$DNS_DOMAIN" ]] \
    && { error "Namecheap not fully configured."; return 1; }
  local ip; ip=$(_dns_get_public_ip) || return 1
  info "Public IP: ${ip}"
  local tld="${DNS_DOMAIN##*.}"
  local sld="${DNS_DOMAIN%.*}"
  local subdomains=()
  while IFS= read -r sub; do subdomains+=("$sub"); done < <(_dns_get_subdomains)
  subdomains+=("@")
  local updated=0 failed=0 sub result label err
  for sub in "${subdomains[@]}"; do
    result=$(curl -fsSL --max-time 10 \
      "https://dynamicdns.park-your-domain.com/update?host=${sub}&domain=${sld}.${tld}&password=${DNS_NAMECHEAP_API_KEY}&ip=${ip}" 2>/dev/null)
    [[ "$sub" == "@" ]] && label="${DNS_DOMAIN}" || label="${sub}.${DNS_DOMAIN}"
    if echo "$result" | grep -q "<ErrCount>0<"; then
      success "  ${label} → ${ip}"; updated=$((updated + 1))
    else
      err=$(echo "$result" | grep -o '<Err1>[^<]*</Err1>' | sed 's/<[^>]*>//g')
      warn "  Failed: ${label} ${err:+(${err})}"; failed=$((failed + 1))
    fi
  done
  echo ""
  success "Namecheap: ${updated} records set, ${failed} failed."
}

_dns_verify_propagation() {
  # After a DNS update, confirm the record is visible from a public resolver.
  # Tries 3 times with 10s gaps before giving up gracefully.
  _dns_load
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local domain="${DNS_DOMAIN:-${DOMAIN:-}}"
  [[ -z "$domain" ]] && return 0

  local expected_ip
  expected_ip=$(_dns_get_public_ip 2>/dev/null) \
    || { info "Could not detect public IP — skipping propagation check."; return 0; }

  command -v dig &>/dev/null \
    || { info "dig not found — skipping propagation check (install dnsutils to enable)."; return 0; }

  echo ""
  info "Verifying DNS propagation for ${domain} via 1.1.1.1..."
  local attempt resolved
  for attempt in 1 2 3; do
    resolved=$(dig +short "${domain}" A @1.1.1.1 2>/dev/null | head -1)
    if [[ "$resolved" == "$expected_ip" ]]; then
      success "DNS propagated ✔  ${domain} → ${resolved}"
      return 0
    fi
    if [[ $attempt -lt 3 ]]; then
      info "  Not yet visible (got '${resolved:-no record}') — waiting 10s... (${attempt}/3)"
      sleep 10
    fi
  done
  warn "DNS not yet visible at 1.1.1.1 after 3 checks."
  warn "  Expected: ${expected_ip}  Got: ${resolved:-no record}"
  warn "  Propagation can take a few minutes — Traefik will retry cert issuance automatically."
}

_dns_update_now() {
  _dns_load
  [[ -z "$DNS_PROVIDER" ]] && { error "No DNS provider configured."; return 1; }
  case "$DNS_PROVIDER" in
    cloudflare) _dns_update_cloudflare ;;
    duckdns)    _dns_update_duckdns    ;;
    godaddy)    _dns_update_godaddy    ;;
    namecheap)  _dns_update_namecheap  ;;
    *)          error "Unknown provider: ${DNS_PROVIDER}" ;;
  esac
  _dns_verify_propagation
}

_dns_show_subdomains() {
  _dns_load
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local d="${DNS_DOMAIN:-${DOMAIN:-yourdomain.com}}"
  echo ""
  echo -e "${BOLD}A Records that will be created/updated${RESET}"
  echo "─────────────────────────────────────────"
  echo -e "  ${GREEN}@${RESET}  ${d}  (root)"
  local sub
  while IFS= read -r sub; do
    echo -e "  ${GREEN}✔${RESET}  ${sub}.${d}"
  done < <(_dns_get_subdomains)
  echo "─────────────────────────────────────────"
  echo -e "  ${DIM}All records point to your current public IP.${RESET}"
  echo ""
}

_dns_install_cron() {
  local cron_script="/usr/local/bin/friendbox-dns-update"
  cat > "$cron_script" <<'CRONEOF'
#!/usr/bin/env bash
# Friendbox automatic DNS updater — managed by friendbox
INSTALL_DIR="/opt/friendbox"
source "${INSTALL_DIR}/.dns_config" 2>/dev/null || exit 0
[[ -z "$DNS_PROVIDER" ]] && exit 0

IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) || exit 1
CACHE_FILE="/tmp/.friendbox_dns_ip"
LAST_IP=$(cat "$CACHE_FILE" 2>/dev/null || true)
[[ "$IP" == "$LAST_IP" ]] && exit 0

_ok=false
case "$DNS_PROVIDER" in
  duckdns)
    _result=$(curl -fsSL --max-time 10 \
      "https://www.duckdns.org/update?domains=${DNS_DUCKDNS_SUBDOMAIN}&token=${DNS_DUCKDNS_TOKEN}&ip=${IP}" 2>/dev/null)
    [[ "$_result" == "OK" ]] && _ok=true
    ;;
  cloudflare|godaddy|namecheap)
    /usr/local/bin/friendbox --dns-update >/dev/null 2>&1 && _ok=true || true
    ;;
esac
# Only cache the IP on confirmed success — a failed update must retry next run
"$_ok" && echo "$IP" > "$CACHE_FILE"
CRONEOF
  chmod +x "$cron_script"
  local cron_file="/etc/cron.d/friendbox-dns"
  echo "*/5 * * * * root ${cron_script} >> /var/log/friendbox-dns.log 2>&1" > "$cron_file"
  chmod 644 "$cron_file"

  # Install logrotate config so the cron log doesn't grow unbounded
  cat > /etc/logrotate.d/friendbox-dns << 'LREOF'
/var/log/friendbox-dns.log {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  create 0644 root root
}
LREOF

  success "Cron job installed: ${cron_file}"
  success "Log rotation installed: /etc/logrotate.d/friendbox-dns"
  info "DNS checked/updated every 5 minutes. Logs: /var/log/friendbox-dns.log"
}

_dns_remove_cron() {
  local cron_file="/etc/cron.d/friendbox-dns"
  local cron_script="/usr/local/bin/friendbox-dns-update"
  local logrotate_file="/etc/logrotate.d/friendbox-dns"
  if [[ -f "$cron_file" ]]; then
    rm -f "$cron_file"
    success "Cron job removed."
    [[ -f "$cron_script"    ]] && rm -f "$cron_script"    && info "  Removed: ${cron_script}"
    [[ -f "$logrotate_file" ]] && rm -f "$logrotate_file" && info "  Removed: ${logrotate_file}"
  else
    warn "No cron job found."
  fi
}

configure_dns() {
  # Fetch the public IP once before entering the menu loop.
  # _dns_get_public_ip makes up to 3 sequential curl calls (max 15s total) —
  # calling it on every render iteration causes the menu to hang for several
  # seconds each time the loop restarts. Fetch once, reuse for the session.
  local _dns_cached_ip
  echo -e "  ${DIM}Detecting public IP...${RESET}"
  _dns_cached_ip=$(_dns_get_public_ip 2>/dev/null) || _dns_cached_ip="unknown"

  while true; do
    _dns_load
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              🌐  DNS A Record Manager                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    _dns_show_status
    echo -e "  ${DIM}Current public IP: ${_dns_cached_ip}${RESET}"
    echo ""
    echo "  ── Configure Provider ───────────────────────────────────"
    echo "  1) Cloudflare"
    echo "  2) DuckDNS"
    echo "  3) GoDaddy"
    echo "  4) Namecheap"
    echo ""
    echo "  ── Actions ──────────────────────────────────────────────"
    echo "  5) Update DNS now (push current IP to all A records)"
    echo "  6) Show subdomains that will be managed"
    echo "  7) Install auto-update cron job (every 5 minutes)"
    echo "  8) Remove auto-update cron job"
    echo "  9) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) _dns_configure_cloudflare || true; pause ;;
      2) _dns_configure_duckdns    || true; pause ;;
      3) _dns_configure_godaddy    || true; pause ;;
      4) _dns_configure_namecheap  || true; pause ;;
      5) _dns_update_now           || true; pause ;;
      6) _dns_show_subdomains      || true; pause ;;
      7) _dns_install_cron         || true; pause ;;
      8) _dns_remove_cron          || true; pause ;;
      9) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Core Install & Operations
# =============================================================================

full_install() {
  require_root || return 1

  # ── Already-installed guard ──────────────────────────────────────────────────
  if is_installed; then
    local installed_at
    installed_at=$(grep '^installed=' "$INSTALL_FLAG" 2>/dev/null | cut -d= -f2- || true)
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}║  ⚠  Friendbox is already installed                          ║${RESET}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Installed on: ${BOLD}${installed_at:-unknown}${RESET}"
    echo ""
    echo -e "  Running Full Install again will:"
    echo -e "  ${DIM}  • Re-download config files from GitHub${RESET}"
    echo -e "  ${DIM}  • Overwrite your current .env settings${RESET}"
    echo -e "  ${DIM}  • Re-run container selection and redeploy${RESET}"
    echo ""
    echo -e "  For most changes, use the individual menu options instead:"
    echo -e "  ${DIM}  • Options 2–5  — change containers / config / credentials${RESET}"
    echo -e "  ${DIM}  • Option 12    — redeploy containers${RESET}"
    echo -e "  ${DIM}  • Option 13    — pull latest images${RESET}"
    echo ""
    read -rp "  Re-run Full Install anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted — returning to menu."; return 0; }
    echo ""
  fi

  check_os
  check_deps
  sync_repo
  select_containers    # must run before configure_env so Plex/Traefik selections are known
  configure_env
  ensure_network
  ensure_acme
  provision_directories
  _jellyfin_fix_markers

  # ── Pre-flight check: warn if Traefik not fully configured ───────────────────
  load_selected
  if [[ -n "${SELECTED[traefik]+_}" ]]; then
    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
    local _pf_warn=false
    if [[ -z "${DOMAIN:-}" || "${DOMAIN:-}" == "example.com" ]]; then
      warn "Domain is not configured — Traefik will not obtain HTTPS certificates."
      _pf_warn=true
    fi
    if [[ -z "${ACME_EMAIL:-}" || "${ACME_EMAIL:-}" == "admin@example.com" ]]; then
      warn "ACME email is not configured — required for Let's Encrypt."
      _pf_warn=true
    fi
    if [[ -z "${TRAEFIK_ACME_PROVIDER:-}" ]]; then
      warn "No ACME DNS provider configured — HTTPS certificates will not be issued."
      warn "Configure after install via: option 4 → option 3"
      _pf_warn=true
    fi
    if [[ "$_pf_warn" == "true" ]]; then
      echo ""
      echo -e "  ${DIM}These warnings won't stop the install. Fix them via option 4 after deploy.${RESET}"
      echo ""
      read -rp "  Continue anyway? [Y/n] " _pf_yn
      [[ "${_pf_yn:-y}" =~ ^[Nn]$ ]] && { info "Aborted — configure Traefik via option 4, then run option 1 again."; return 0; }
    fi
  fi

  # ── Port conflict check ───────────────────────────────────────────────────────
  check_port_conflicts --interactive || return 1

  info "Starting selected containers..."
  compose_selected up -d
  echo ""
  success "✅ Friendbox is up!" 
  mark_installed
  echo ""
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
  echo -e "  ${BOLD}Next steps if needed:${RESET}"
  echo -e "  ${DIM}  • Traefik dashboard password  → menu option  4${RESET}"
  echo -e "  ${DIM}  • VPN / AMP / Mumble / Jellyfin HW → menu option  5${RESET}"
  echo -e "  ${DIM}  • DNS A record setup           → menu option  6${RESET}"
  echo -e "  ${DIM}  • MergerFS storage pool        → menu option  7${RESET}"
  echo -e "  ${DIM}  • Backup your config           → menu option 16${RESET}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"

  # ── TeamSpeak 6: surface the admin token if TS6 was deployed ─────────────────
  load_selected
  if [[ -n "${SELECTED[teamspeak6]+_}" ]]; then
    echo ""
    info "Checking for TeamSpeak 6 admin privilege token..."
    local _ts_tok="" _ts_try
    for _ts_try in 1 2 3 4 5; do
      _ts_tok=$(docker logs teamspeak6 2>/dev/null \
        | grep -iE "token=|privilege" | grep -oE '[A-Za-z0-9+/]{40,}|token=[^ ]+' | head -1)
      [[ -n "$_ts_tok" ]] && break
      sleep 3
    done
    if [[ -n "$_ts_tok" ]]; then
      echo ""
      echo -e "  ${BOLD}${YELLOW}TeamSpeak 6 Admin Token${RESET}"
      echo -e "  ${CYAN}${_ts_tok}${RESET}"
      echo -e "  ${DIM}Use this in the TS6 client to claim server admin. It is only shown once.${RESET}"
    else
      echo ""
      info "TS6 admin token not yet in logs."
      info "Retrieve it manually: docker logs teamspeak6 | grep -i token"
    fi
  fi

  echo ""
  print_urls
}

print_urls() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected
  local d="${DOMAIN:-yourdomain.com}"
  local use_traefik="${USE_TRAEFIK:-}"
  # If USE_TRAEFIK not set in .env, infer from selection
  [[ -z "$use_traefik" ]] && { [[ -n "${SELECTED[traefik]+_}" ]] && use_traefik="true" || use_traefik="false"; }

  # ── Detect local IPv4 address ────────────────────────────────────────────────
  # Try ip route first (most reliable — picks the interface used for outbound
  # traffic), then fall back to hostname -I (first address), then give up with
  # a clear placeholder so the user knows what to fill in.
  local host_ip=""
  host_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  if [[ -z "$host_ip" ]]; then
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$host_ip" ]]; then
    host_ip="<server-ip>"
    warn "Could not detect local IP — replace <server-ip> in the URLs below."
  fi

  echo ""
  if [[ "$use_traefik" == "true" ]]; then
    echo -e "${BOLD}Active Service URLs${RESET} ${DIM}(via Traefik HTTPS)${RESET}"
    declare -A URL_MAP=(
      [traefik]="https://traefik.${d}"       [portainer]="https://portainer.${d}"
      [plex]="https://plex.${d}"             [jellyfin]="https://jellyfin.${d}"
      [sonarr]="https://sonarr.${d}"         [radarr]="https://radarr.${d}"
      [prowlarr]="https://prowlarr.${d}"     [bazarr]="https://bazarr.${d}"
      [qbittorrent]="https://qbt.${d}"       [qbittorrentvpn]="https://qbtvpn.${d}"
      [delugevpn]="https://deluge.${d}"      [nzbget]="https://nzbget.${d}"
      [overseerr]="https://overseerr.${d}"   [ombi]="https://ombi.${d}"
      [jellyseerr]="https://jellyseerr.${d}" [teamspeak6]="ts6.${d}:9987 (UDP)"
      [mumble]="mumble.${d}:64738"           [ampmc]="https://amp.${d}"
      [netbootxyz]="https://netboot.${d}"
    )
  else
    echo -e "${BOLD}Active Service URLs${RESET} ${DIM}(direct port access — no Traefik)${RESET}"
    echo -e "  ${DIM}Server IP: ${CYAN}${host_ip}${RESET}"
    declare -A URL_MAP=(
      [portainer]="http://${host_ip}:9000"
      [plex]="http://${host_ip}:32400/web"
      [jellyfin]="http://${host_ip}:8096"
      [sonarr]="http://${host_ip}:8989"
      [radarr]="http://${host_ip}:7878"
      [prowlarr]="http://${host_ip}:9696"
      [bazarr]="http://${host_ip}:6767"
      [qbittorrent]="http://${host_ip}:8082"
      [qbittorrentvpn]="http://${host_ip}:8181"
      [delugevpn]="http://${host_ip}:8112"
      [nzbget]="http://${host_ip}:6789"
      [overseerr]="http://${host_ip}:5055"
      [ombi]="http://${host_ip}:3579"
      [jellyseerr]="http://${host_ip}:5056"
      [teamspeak6]="${host_ip}:9987 (UDP voice)"
      [mumble]="${host_ip}:64738"
      [ampmc]="http://${host_ip}:8085"
      [netbootxyz]="http://${host_ip}:3000"
    )
  fi

  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" && -n "${URL_MAP[$key]+_}" ]] \
      && printf "  %-26s : ${CYAN}%s${RESET}\n" "${CONTAINER_NAMES[$key]}" "${URL_MAP[$key]}"
  done
  echo ""
}

show_status() {
  info "Container status:"
  compose_selected ps 2>/dev/null \
    || docker ps --filter "network=medianet" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

redeploy_menu() {
  while true; do
    echo ""
    echo -e "${BOLD}Redeploy Options${RESET}"
    echo "  1) Redeploy ALL active containers (pull latest images + recreate)"
    echo "  2) Redeploy a SINGLE container"
    echo "  3) Restart all active containers (no pull)"
    echo "  4) Change container selection then redeploy"
    echo "  5) Back"
    echo ""
    read -rp "Choice: " choice
    case "$choice" in
      1)
        info "Pulling latest images and redeploying..."
        _jellyfin_fix_markers
        compose_selected pull
        compose_selected up -d --force-recreate
        success "All active containers redeployed."
        pause
        ;;
      2)
        echo ""
        load_selected
        # Build a numbered list of currently selected containers
        local _svc_keys=() _i _k
        for _k in "${CONTAINER_ORDER[@]}"; do
          [[ -n "${SELECTED[$_k]+_}" ]] && _svc_keys+=("$_k")
        done
        if [[ ${#_svc_keys[@]} -eq 0 ]]; then
          warn "No containers are currently selected."; sleep 1; continue
        fi
        echo -e "${BOLD}Select container to redeploy:${RESET}"
        echo ""
        for _i in "${!_svc_keys[@]}"; do
          printf "  %2d) %s\n" "$((_i+1))" "${CONTAINER_NAMES[${_svc_keys[$_i]}]}"
        done
        echo ""
        read -rp "  Choice: " _sel
        if ! [[ "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#_svc_keys[@]} )); then
          warn "Invalid selection."; sleep 1; continue
        fi
        local svc="${_svc_keys[$((_sel-1))]}"
        [[ "$svc" == "jellyfin" ]] && _jellyfin_fix_markers
        compose_selected pull "$svc"
        compose_selected up -d --force-recreate "$svc"
        success "${CONTAINER_NAMES[$svc]} redeployed."
        pause
        ;;
      3)
        _jellyfin_fix_markers
        compose_selected restart
        success "All containers restarted."
        pause
        ;;
      4)
        select_containers
        _jellyfin_fix_markers
        # Sync USE_TRAEFIK in .env to match the updated selection — print_urls
        # and _traefik_show_status read this key to decide what URLs to display.
        load_selected
        local _ut="false"; [[ -n "${SELECTED[traefik]+_}" ]] && _ut="true"
        if grep -q "^USE_TRAEFIK=" "$ENV_FILE" 2>/dev/null; then
          sed -i "s|^USE_TRAEFIK=.*|USE_TRAEFIK=${_ut}|" "$ENV_FILE"
        else
          echo "USE_TRAEFIK=${_ut}" >> "$ENV_FILE"
        fi
        # Re-provision acme.json and regenerate traefik.yml in case Traefik was
        # just added to (or removed from) the selection.
        ensure_acme
        # Re-apply Jellyfin HW accel patch — the container re-selection may have
        # added Jellyfin for the first time, or a prior sync_repo/auto_update may
        # have reset the compose file to software transcoding since the last deploy.
        [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
        if [[ -n "${JELLYFIN_HW_ACCEL:-}" && "${JELLYFIN_HW_ACCEL}" != "none" ]]; then
          _jellyfin_hw_apply "${JELLYFIN_HW_ACCEL}" \
            && info "Jellyfin HW accel (${JELLYFIN_HW_ACCEL}) re-applied."
        fi
        compose_selected up -d --remove-orphans
        success "Stack updated."
        pause
        ;;
      5) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

update_stack() {
  require_root
  sync_repo

  # Snapshot digests before pull to detect what actually changed
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  local _prof=(); local _l
  while IFS= read -r _l; do [[ -n "$_l" ]] && _prof+=("$_l"); done \
    < <(get_profile_args)

  declare -A _before=()
  local _img
  while IFS= read -r _img; do
    [[ -z "$_img" ]] && continue
    local _d; _d=$(docker inspect --format='{{index .RepoDigests 0}}' "$_img" 2>/dev/null || true)
    _before[$_img]="${_d:-none}"
  done < <(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
    "${_prof[@]}" config --images 2>/dev/null)

  _jellyfin_fix_markers
  compose_selected pull
  compose_selected up -d

  # Report changes
  local _updated=0 _same=0
  echo ""
  echo -e "${BOLD}Image update summary:${RESET}"
  while IFS= read -r _img; do
    [[ -z "$_img" ]] && continue
    local _nd; _nd=$(docker inspect --format='{{index .RepoDigests 0}}' "$_img" 2>/dev/null || true)
    local _lbl="${_img##*/}"
    if [[ "${_before[$_img]:-none}" != "${_nd:-none}" ]]; then
      echo -e "  ${GREEN}↑ updated${RESET}   ${_lbl}"
      _updated=$((_updated+1))
    else
      echo -e "  ${DIM}  current   ${_lbl}${RESET}"
      _same=$((_same+1))
    fi
  done < <(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
    "${_prof[@]}" config --images 2>/dev/null)
  echo ""
  [[ $_updated -gt 0 ]] \
    && success "${_updated} image(s) updated, ${_same} already current." \
    || success "All ${_same} image(s) already up to date."
}

teardown() {
  echo ""
  warn "This will STOP and REMOVE all containers (data/config is preserved)."
  read -rp "Are you sure? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return; }
  compose_selected down --remove-orphans
  # Remove the medianet network so a subsequent install doesn't hit a subnet
  # pool overlap error when Compose tries to recreate it.
  if docker network inspect medianet &>/dev/null 2>&1; then
    docker network rm medianet 2>/dev/null \
      && success "Removed Docker network 'medianet'." \
      || warn "Could not remove 'medianet' network — remove manually if reinstalling: docker network rm medianet"
  fi
  mark_uninstalled
  success "Containers removed. Run option 1 to reinstall."
}

full_reset() {
  require_root || return 1
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}${RED}⚠  Full Reset${RESET}"
  echo ""
  echo -e "  This will permanently delete:"
  echo -e "  ${RED}  • All Friendbox containers${RESET}"
  echo -e "  ${RED}  • All Docker images pulled by Friendbox${RESET}"
  echo -e "  ${RED}  • The medianet Docker network${RESET}"
  echo -e "  ${RED}  • All config data in ${CONFIG_ROOT:-/opt/friendbox/config}${RESET}"
  echo -e "  ${RED}  • All state files (.env, .selected_containers, etc.)${RESET}"
  echo -e "  ${RED}  • The /usr/local/bin/friendbox command${RESET}"
  echo ""
  echo -e "  ${BOLD}Media files in ${MEDIA_ROOT:-/mnt/media} are NOT deleted.${RESET}"
  echo -e "  ${BOLD}Backups in ${BACKUP_DIR:-/opt/friendbox/backups} are NOT deleted.${RESET}"
  echo ""
  warn "This cannot be undone. Create a backup first (option 16) if needed."
  echo ""
  read -rp "  Type RESET to confirm: " confirm
  [[ "$confirm" == "RESET" ]] || { info "Aborted."; return 0; }
  echo ""

  info "Stopping and removing containers..."
  compose_selected down --remove-orphans 2>/dev/null || true

  info "Removing Docker images..."
  if [[ -f "$COMPOSE_FILE" ]]; then
    local img
    while IFS= read -r img; do
      [[ -z "$img" ]] && continue
      docker rmi "$img" 2>/dev/null && info "  Removed: ${img}" || true
    done < <(grep 'image:' "$COMPOSE_FILE" 2>/dev/null | awk '{print $2}' | sort -u)
  fi

  if docker network inspect medianet &>/dev/null 2>&1; then
    docker network rm medianet 2>/dev/null \
      && success "Removed Docker network 'medianet'." || true
  fi

  local cfg="${CONFIG_ROOT:-/opt/friendbox/config}"
  if [[ -d "$cfg" ]]; then
    rm -rf "$cfg"
    success "Removed config directory: ${cfg}"
  fi

  local sf
  for sf in "$ENV_FILE" "$STATE_FILE" "$SELECTED_FILE" "$MERGERFS_MODES_FILE" \
            "$MERGERFS_POOL_FILE" "$DNS_STATE_FILE" "$INSTALL_FLAG" \
            "${INSTALL_DIR}/docker-compose.yml" "${INSTALL_DIR}/scripts/redeploy.sh"; do
    [[ -f "$sf" ]] && rm -f "$sf" && info "  Removed: ${sf}"
  done

  # Remove DNS cron job and helper script if they exist
  local _dns_cron="/etc/cron.d/friendbox-dns"
  local _dns_script="/usr/local/bin/friendbox-dns-update"
  local _dns_logrotate="/etc/logrotate.d/friendbox-dns"
  [[ -f "$_dns_cron"     ]] && rm -f "$_dns_cron"     && info "  Removed: ${_dns_cron}"
  [[ -f "$_dns_script"   ]] && rm -f "$_dns_script"   && info "  Removed: ${_dns_script}"
  [[ -f "$_dns_logrotate" ]] && rm -f "$_dns_logrotate" && info "  Removed: ${_dns_logrotate}"

  # Remove the binary last — we're still executing from it in memory
  rm -f /usr/local/bin/friendbox
  success "Removed /usr/local/bin/friendbox"

  echo ""
  success "✅ Full reset complete. Friendbox has been removed."
  info "Media files in ${MEDIA_ROOT:-/mnt/media} are untouched."
  info "To reinstall: curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/setup.sh | sudo bash"
  echo ""
  exit 0
}


view_logs() {
  echo ""
  read -rp "Container name (leave blank for all active): " svc
  echo ""
  echo "  1) Follow live logs (Ctrl+C to stop)"
  echo "  2) Dump last 200 lines and return to menu"
  echo ""
  read -rp "  Choice [1]: " log_choice
  log_choice="${log_choice:-1}"
  echo ""
  if [[ "$log_choice" == "2" ]]; then
    if [[ -z "$svc" ]]; then compose_selected logs --tail=200 2>/dev/null
    else compose_selected logs --tail=200 "$svc" 2>/dev/null; fi
  else
    info "Following logs — press Ctrl+C to stop and return to the menu."
    if [[ -z "$svc" ]]; then compose_selected logs --tail=100 -f
    else compose_selected logs --tail=100 -f "$svc"; fi
  fi
}

# =============================================================================
#  Main Menu
# =============================================================================

main_menu() {
  require_root || exit 1

  # ── Show auto-update notice if files were just refreshed from GitHub ─────────
  local notice_file="${INSTALL_DIR}/.update_notice"
  if [[ -f "$notice_file" ]]; then
    echo ""
    echo -e "${GREEN}[OK]${RESET}    Files updated from GitHub:"
    while IFS= read -r line; do
      echo -e "        ${DIM}✔ ${line}${RESET}"
    done < "$notice_file"
    rm -f "$notice_file"
    echo ""
    pause
  fi

  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║          📦  Friendbox Manager           ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
    load_selected
    local count="${#SELECTED[@]}"

    # ── Install status badge ─────────────────────────────────────────────────
    if is_installed; then
      local installed_at
      installed_at=$(grep '^installed=' "$INSTALL_FLAG" 2>/dev/null | cut -d= -f2- || true)
      echo -e "  ${GREEN}✔ INSTALLED${RESET}  ${DIM}${installed_at:+since ${installed_at}}${RESET}"
    else
      echo -e "  ${YELLOW}○ NOT YET INSTALLED${RESET}  ${DIM}Run option 1 to get started.${RESET}"
    fi
    echo -e "  ${DIM}Selected containers: ${count}${RESET}"
    echo ""

    echo "  ── Setup ────────────────────────────────"
    echo "   1) Full Install (first time setup)"
    echo "   2) Select containers"
    echo "   3) Configure .env (paths, PUID, timezone)"
    echo "   4) Traefik configuration"
    echo "   5) Service credentials & hardware acceleration"
    echo "   6) DNS A record manager"
    echo "   7) MergerFS storage manager"
    echo ""
    echo "  ── Operations ───────────────────────────"
    echo "   8) Provision / fix directory ownership"
    echo "   9) Sync latest files from GitHub"
    echo "  10) Show container status"
    echo "  11) View service URLs"
    echo "  12) Redeploy containers"
    echo "  13) Update stack (pull latest images)"
    echo "  14) View logs"
    echo "  15) Check port conflicts"
    echo "  16) Backup & Restore"
    echo "  17) Teardown (stop & remove containers)"
    echo "  18) Full Reset (wipe everything)"
    echo "   q) Quit"
    echo ""
    read -rp "Select option: " opt

    # ── Gate operations-section items when not installed ─────────────────────
    if ! is_installed && [[ "$opt" =~ ^(10|11|12|13|14|17)$ ]]; then
      echo ""
      warn "Friendbox has not been installed yet."
      warn "Run option 1 (Full Install) first, then use the operations menu."
      pause
      continue
    fi

    case "$opt" in
      1)  full_install                    || true; pause ;;
      2)  select_containers               || true; pause ;;
      3)  configure_env                   || true; pause ;;
      4)  configure_traefik                      ;;   # has its own loop+return
      5)  configure_service_credentials          ;;   # has its own loop+return
      6)  configure_dns                          ;;   # has its own loop+return
      7)  setup_mergerfs                         ;;   # has its own loop+return
      8)  provision_directories           || true; pause ;;
      9)  sync_repo                       || true; pause ;;
      10) show_status                     || true; pause ;;
      11) print_urls                      || true; pause ;;
      12) redeploy_menu                          ;;   # has its own loop+return
      13) update_stack                    || true; pause ;;
      14) view_logs                       || true; pause ;;
      15) check_port_conflicts            || true; pause ;;
      16) setup_backup                           ;;   # has its own loop+return
      17) teardown                        || true; pause ;;
      18) full_reset                      || true; pause ;;
      q|Q) echo "Goodbye!"; exit 0 ;;
      *) warn "Invalid option '$opt'"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Entrypoint
# =============================================================================

# ── Handle --dns-update BEFORE any terminal/bootstrap detection ─────────────
# The cron script calls `friendbox --dns-update` with stdin redirected from /dev/null.
# If checked after [[ ! -t 0 ]], the bootstrap branch would fire and overwrite the
# installed script every 5 minutes.  Intercept the flag here, unconditionally.
for _arg in "$@"; do
  if [[ "$_arg" == "--dns-update" ]]; then
    _dns_update_now
    exit $?
  fi
done

if [[ ! -t 0 ]]; then
  # Non-interactive (piped via curl | bash) — bootstrap only
  echo -e "${BOLD}${CYAN}Friendbox Setup — Bootstrap${RESET}"
  echo ""
  info "Downloading setup script to /usr/local/bin/friendbox ..."
  curl -fsSL "${REPO_URL}/setup.sh" -o /usr/local/bin/friendbox
  chmod +x /usr/local/bin/friendbox
  success "Done! Run the interactive menu with:"
  echo ""
  echo -e "    ${BOLD}sudo friendbox${RESET}"
  echo ""
else
  # Interactive launch — check for --skip-update flag (set by auto_update after
  # re-exec so we don't loop) then run the menu.
  SKIP_UPDATE=false
  for arg in "$@"; do
    [[ "$arg" == "--skip-update" ]] && SKIP_UPDATE=true
  done

  if [[ "$SKIP_UPDATE" == "false" ]]; then
    auto_update "$@"
    # auto_update either exec'd (and we never reach here) or skipped due to
    # no-root / offline — either way, fall through to the menu below.
  fi

  ensure_media_root
  _fix_install_dir_ownership
  main_menu
fi
