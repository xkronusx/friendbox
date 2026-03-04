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

  # acme.json must be 600 — Traefik requires it, but does NOT require root ownership
  local acme="${INSTALL_DIR}/config/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    chown "${uid}:${gid}" "$acme"
    chmod 600 "$acme"
  fi

  # .dns_config contains API keys — keep permissions tight
  local dns_cfg="${INSTALL_DIR}/.dns_config"
  [[ -f "$dns_cfg" ]] && chmod 600 "$dns_cfg"
}

ensure_media_root() {
  # Create /mnt/media on every interactive launch so it always exists as a
  # mount point for MergerFS, or as a plain directory for single-drive setups.
  # Sets ownership of /mnt and /mnt/media to PUID:PGID (default 1000:1000).
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

  # Own /mnt and /mnt/media — containers and the media user need traversal rights
  chown "${uid}:${gid}" /mnt
  chown "${uid}:${gid}" "$MEDIA_ROOT"
}

# Returns 0 (true) if the stack appears to have active containers
is_running() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps --status running \
    2>/dev/null | grep -q "running" || return 1
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
    echo -e "  ${BOLD}Supported:${RESET}  Ubuntu 24.04.4 LTS (Noble Numbat)"
    echo ""
    echo -e "  Friendbox is tested and supported on ${BOLD}Ubuntu 24.04.4 LTS${RESET} only."
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
  [ombi]="Ombi v3"
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
  [ombi]="Media request manager (Ombi v3)"
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

  mv "${COMPOSE_FILE}.new" "${COMPOSE_FILE}"
  _own "${COMPOSE_FILE}"

  printf 'docker-compose.yml\n/usr/local/bin/friendbox\n' > "${INSTALL_DIR}/.update_notice"
  _own "${INSTALL_DIR}/.update_notice"

  mv /usr/local/bin/friendbox.new /usr/local/bin/friendbox
  chmod +x /usr/local/bin/friendbox
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
    mv /usr/local/bin/friendbox.new /usr/local/bin/friendbox
    chmod +x /usr/local/bin/friendbox
    echo -e "${GREEN}[OK]${RESET}"
    script_ok=1
  else
    rm -f /usr/local/bin/friendbox.new
    echo -e "${RED}[FAILED]${RESET}"
  fi

  printf "  %-34s " "docker-compose.yml"
  if fetch_remote "docker-compose.yml" "${COMPOSE_FILE}.new" 2>/dev/null; then
    mv "${COMPOSE_FILE}.new" "${COMPOSE_FILE}"
    _own "${COMPOSE_FILE}"
    echo -e "${GREEN}[OK]${RESET}"
    compose_ok=1
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
  # Returns plain colon-separated source paths (RW first, then RO).
  # Mode suffixes go in branch-config= option, NOT in the source field.
  local rw_paths=() ro_paths=() path
  for path in "${!DISK_MODES[@]}"; do
    case "${DISK_MODES[$path]}" in
      RW|NC) rw_paths+=("$path") ;;
      RO)    ro_paths+=("$path") ;;
    esac
  done
  local all=()
  [[ ${#rw_paths[@]} -gt 0 ]] && all+=("${rw_paths[@]}")
  [[ ${#ro_paths[@]} -gt 0 ]] && all+=("${ro_paths[@]}")
  local IFS=:
  echo "${all[*]-}"
}

_mergerfs_build_branch_config() {
  # Returns the branch-config= value with per-path mode suffixes, e.g.:
  # /mnt/disk1=RW:/mnt/disk2=RO
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
  local branch_list branch_config
  branch_list=$(_mergerfs_build_branch_list)
  branch_config=$(_mergerfs_build_branch_config)

  if [[ -z "$branch_list" ]]; then
    warn "No disks configured — fstab not updated."
    return 1
  fi

  # Remove any existing mergerfs entry for this pool
  sed -i "\|${pool_path}.*fuse.mergerfs|d" /etc/fstab

  # Correct fstab format:
  #   source field  = plain colon-separated paths (no =MODE suffixes)
  #   branch-config = per-branch RW/RO/NC modes in the options field
  echo "${branch_list}  ${pool_path}  fuse.mergerfs  defaults,allow_other,use_ino,cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,branch-config=${branch_config},fsname=mergerfs  0  0" >> /etc/fstab
  success "fstab updated."
}

_mergerfs_remount() {
  local pool_path="$1"
  if mountpoint -q "$pool_path"; then
    umount "$pool_path" 2>/dev/null && mount "$pool_path" \
      && success "Pool remounted at ${pool_path}." \
      || warn "Could not remount — reboot may be required."
  else
    mount "$pool_path" 2>/dev/null \
      && success "Pool mounted at ${pool_path}." \
      || warn "Mount may require a reboot."
  fi
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
  [[ ! -d "$disk" ]] && { warn "${disk} does not exist. Creating it..."; mkdir -p "$disk"; }
  echo ""
  echo "  Mode for ${disk}:"
  echo "  1) RW — Read/Write  (normal, files can be created here)"
  echo "  2) RO — Read-Only   (existing files readable, no writes at all)"
  read -rp "  Mode (press Enter for default) [1]: " msel
  local mode
  case "${msel:-1}" in
    1) mode="RW" ;; 2) mode="RO" ;; *) warn "Defaulting to RW."; mode="RW" ;;
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
  echo "  1) RW — Read/Write  2) RO — Read-Only"
  read -rp "  New mode [current: ${DISK_MODES[$chosen]}]: " msel
  case "${msel:-}" in
    1) DISK_MODES[$chosen]="RW" ;;
    2) DISK_MODES[$chosen]="RO" ;;
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
    [[ ! -d "$disk" ]] && { warn "${disk} does not exist. Creating it..."; mkdir -p "$disk"; }
    echo "  1) RW — Read/Write (default)  2) RO — Read-Only"
    read -rp "  Mode [1]: " msel
    case "${msel:-1}" in
      1) mode="RW" ;; 2) mode="RO" ;; *) warn "Defaulting to RW."; mode="RW" ;;
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

  local pool_path="$MEDIA_ROOT"
  mkdir -p "$pool_path"

  _mergerfs_save_modes
  _mergerfs_save_pool "$pool_path"
  _mergerfs_write_fstab "$pool_path"
  _mergerfs_remount "$pool_path"

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
        size=$(df  -h "$path" 2>/dev/null | awk 'NR==2{print $2}') || size="n/a"
        used=$(df  -h "$path" 2>/dev/null | awk 'NR==2{print $3}') || used="n/a"
        avail=$(df -h "$path" 2>/dev/null | awk 'NR==2{print $4}') || avail="n/a"
        # Check if something is actually mounted at this path (not just a directory)
        mountpoint -q "$path" 2>/dev/null && mounted_marker=" ${GREEN}●${RESET}" || mounted_marker=" ${DIM}○${RESET}"
      else
        mounted_marker=" ${YELLOW}?${RESET}"
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

_mergerfs_deploy() {
  echo ""
  echo -e "${BOLD}Deploy Stack with MergerFS Pool${RESET}"
  echo -e "${DIM}Provisions directories, starts all selected containers, and marks the install complete.${RESET}"
  echo ""

  # ── Pre-flight checks ────────────────────────────────────────────────────────
  local abort=false

  # .env must exist and have a domain set
  if [[ ! -f "$ENV_FILE" ]]; then
    error "No .env file found at ${ENV_FILE}."
    error "Run menu option 3 (Configure .env) before deploying."
    abort=true
  else
    local domain_check
    domain_check=$(grep '^DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    if [[ -z "$domain_check" || "$domain_check" == "example.com" ]]; then
      warn "DOMAIN in .env is not set or is still the placeholder value."
      warn "Run menu option 3 to configure your domain before deploying."
      abort=true
    fi
  fi

  # compose file must exist
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    error "No docker-compose.yml found at ${COMPOSE_FILE}."
    error "Run menu option 9 (Sync files from GitHub) first."
    abort=true
  fi

  # at least one container must be selected
  load_selected
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    warn "No containers are selected. Run menu option 2 to select containers first."
    abort=true
  fi

  # warn (but don't abort) if the pool path isn't mounted
  _mergerfs_load_pool
  if [[ -n "$MERGERFS_POOL" ]] && ! mountpoint -q "$MERGERFS_POOL" 2>/dev/null; then
    warn "MergerFS pool is configured at ${MERGERFS_POOL} but is not currently mounted."
    warn "Containers will start, but media directories may be missing or empty until the pool is mounted."
    echo ""
    read -rp "  Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
    echo ""
  fi

  [[ "$abort" == "true" ]] && return 1

  # ── Confirm before deploying ─────────────────────────────────────────────────
  info "Selected containers (${#SELECTED[@]}):"
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] && echo "    ✔ ${CONTAINER_NAMES[$key]}"
  done
  echo ""
  read -rp "Deploy now? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
  echo ""

  # ── Deploy sequence ──────────────────────────────────────────────────────────
  ensure_network    || return 1
  ensure_acme       || return 1
  provision_directories || return 1

  info "Starting selected containers..."
  compose_selected up -d || { error "docker compose failed — check logs with menu option 14."; return 1; }

  mark_installed
  echo ""
  success "✅ Stack deployed successfully!"
  echo ""
  print_urls
}

_mergerfs_mount_pool() {
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
    info "Pool is currently mounted. Remounting with latest fstab settings..."
  else
    info "Pool is not mounted. Mounting now..."
  fi
  _mergerfs_remount "$MERGERFS_POOL"
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
    echo "  7) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) _mergerfs_initial_setup    || true; pause ;;
      2) _mergerfs_add_disk         || true; pause ;;
      3) _mergerfs_change_mode      || true; pause ;;
      4) _mergerfs_remove_disk      || true; pause ;;
      5) _mergerfs_show_pool_detail || true; pause ;;
      6) _mergerfs_mount_pool       || true; pause ;;
      7) return ;;
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
  read -rp "ACME/Let's Encrypt email [${ACME_EMAIL:-}]: " input
  ACME_EMAIL="${input:-${ACME_EMAIL:-admin@example.com}}"
  read -rp "Config root path [${CONFIG_ROOT:-/opt/friendbox/config}]: " input
  CONFIG_ROOT="${input:-${CONFIG_ROOT:-/opt/friendbox/config}}"
  read -rp "PUID [${PUID:-1000}]: " input; PUID="${input:-${PUID:-1000}}"
  read -rp "PGID [${PGID:-1000}]: " input; PGID="${input:-${PGID:-1000}}"
  read -rp "Timezone [${TZ:-America/Toronto}]: " input
  TZ="${input:-${TZ:-America/Toronto}}"

  # Derive USE_TRAEFIK from saved container selection — no prompts here.
  # Traefik dashboard credentials are configured separately via menu option 4.
  load_selected
  local USE_TRAEFIK="false"
  [[ -n "${SELECTED[traefik]+_}" ]] && USE_TRAEFIK="true"

  # Preserve existing TRAEFIK_AUTH if already set; don't overwrite it here.
  local existing_auth="${TRAEFIK_AUTH:-disabled}"

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
  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"

  _env_set PUID         "${PUID}"
  _env_set PGID         "${PGID}"
  _env_set TZ           "${TZ}"
  _env_set DOMAIN       "${DOMAIN}"
  _env_set ACME_EMAIL   "${ACME_EMAIL}"
  _env_set CONFIG_ROOT  "${CONFIG_ROOT}"
  _env_set MEDIA_ROOT   "${MEDIA_ROOT}"
  _env_set USE_TRAEFIK  "${USE_TRAEFIK}"
  _env_set TRAEFIK_AUTH "${existing_auth}"

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

  # ── Build the certificatesResolvers block based on provider ─────────────────
  local resolvers_block
  case "$provider" in
    cloudflare)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - \"1.1.1.1:53\"
          - \"1.0.0.1:53\""
      ;;
    duckdns)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
      dnsChallenge:
        provider: duckdns
        delayBeforeCheck: 60
        resolvers:
          - \"ns1.duckdns.org:53\"
          - \"ns2.duckdns.org:53\""
      ;;
    godaddy)
      resolvers_block="  letsencrypt:
    acme:
      email: ${email}
      storage: /etc/traefik/acme.json
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
      httpChallenge:
        entryPoint: web"
      ;;
  esac

  cat > "$traefik_cfg" <<EOF
# traefik.yml — generated by friendbox
# Provider: ${provider}
# Do not edit manually — regenerated by 'sudo friendbox' → option 4.

api:
  dashboard: true
  insecure: false

log:
  level: INFO

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

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: medianet

certificatesResolvers:
${resolvers_block}
EOF

  _own "$traefik_cfg"
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
    if [[ "$perms" == "600" ]]; then
      _chk "acme.json exists (600)" 1 "$acme"
    else
      _chk "acme.json permissions" 0 "got ${perms}, need 600 — run: chmod 600 $acme"
    fi
  else
    _chk "acme.json exists" 0 "run option 8 (Provision directories) to create it"
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
    echo "  4) Run pre-flight checks"
    echo "  5) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) _traefik_set_auth     || true; pause ;;
      2) _traefik_set_domain   || true; pause ;;
      3) _traefik_set_provider || true; pause ;;
      4) _traefik_validate     || true; pause ;;
      5) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
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
  info "Redeploy Traefik (menu option 12 → option 2 → traefik) to apply changes."
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
  [[ -z "$new_domain" ]] && { warn "Domain cannot be empty."; return 1; }
  echo -n "ACME email [${ACME_EMAIL:-}]: "
  read -r input
  local new_email="${input:-${ACME_EMAIL:-}}"
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

  sed -i '/^NAMECHEAP_API_USER=/d;/^NAMECHEAP_API_KEY=/d' "$ENV_FILE" 2>/dev/null || true
  printf 'NAMECHEAP_API_USER=%s\nNAMECHEAP_API_KEY=%s\n' "$nc_user" "$nc_key" >> "$ENV_FILE"
  success "Namecheap credentials saved."
}

# =============================================================================
#  Service Credentials (VPN, AMP, Mumble)
# =============================================================================

_creds_show_status() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected
  echo ""

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

    if [[ $opt_num -eq 1 ]]; then
      echo -e "  ${DIM}No services requiring credentials are currently selected.${RESET}"
      echo -e "  ${DIM}Select VPN containers, AMP, or Mumble first (menu option 3).${RESET}"
    fi

    echo "  ${opt_num}) Back to main menu"
    CRED_OPTS[$opt_num]="back"
    echo ""
    read -rp "  Choice: " choice

    if [[ -z "${CRED_OPTS[$choice]+_}" ]]; then
      warn "Invalid choice."; sleep 1; continue
    fi

    case "${CRED_OPTS[$choice]}" in
      vpn)    _creds_configure_vpn    || true; pause ;;
      amp)    _creds_configure_amp    || true; pause ;;
      mumble) _creds_configure_mumble || true; pause ;;
      back)   return ;;
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
  read -rp "LAN network CIDR [${LAN_NETWORK:-192.168.1.0/24}]: " input
  LAN_NETWORK="${input:-${LAN_NETWORK:-192.168.1.0/24}}"

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
  sed -i '/^MUMBLE_SUPERUSER_PASSWORD=/d' "$ENV_FILE" 2>/dev/null || true
  echo "MUMBLE_SUPERUSER_PASSWORD=${MUMBLE_SUPERUSER_PASSWORD}" >> "$ENV_FILE"
  success "Mumble password saved."
}

generate_redeploy_sh() {
  local dest="${INSTALL_DIR}/scripts/redeploy.sh"
  _ensure_install_dir

  cat > "$dest" <<'REDEPLOY'
#!/usr/bin/env bash
# /opt/friendbox/scripts/redeploy.sh — standalone redeploy helper
# Usage:
#   sudo redeploy.sh              # pull latest images + recreate all containers
#   sudo redeploy.sh sonarr       # pull + recreate a single container
#   sudo redeploy.sh --restart    # restart all containers without pulling
#   sudo redeploy.sh --health     # show running container health/status

set -euo pipefail

INSTALL_DIR="/opt/friendbox"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
SELECTED_FILE="${INSTALL_DIR}/.selected_containers"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo $0 $*"
[[ -f "$COMPOSE_FILE" ]] || error "docker-compose.yml not found at ${COMPOSE_FILE}"
[[ -f "$ENV_FILE" ]]     || error ".env not found at ${ENV_FILE}"

# Build --profile args from saved selection
profile_args=()
if [[ -f "$SELECTED_FILE" ]]; then
  while IFS= read -r svc; do
    [[ -n "$svc" ]] && profile_args+=(--profile "$svc")
  done < "$SELECTED_FILE"
fi

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${profile_args[@]}" "$@"; }

case "${1:-}" in
  --restart)
    info "Restarting all active containers..."
    dc restart
    success "All containers restarted."
    ;;
  --health)
    dc ps
    ;;
  "")
    info "Pulling latest images..."
    dc pull
    info "Recreating all active containers..."
    dc up -d --force-recreate
    success "All containers redeployed."
    ;;
  -*)
    echo "Usage: $0 [--restart|--health|<container-name>]" >&2
    exit 1
    ;;
  *)
    svc="$1"
    info "Pulling latest image for ${svc}..."
    dc pull "$svc"
    info "Recreating ${svc}..."
    dc up -d --force-recreate "$svc"
    success "${svc} redeployed."
    ;;
esac
REDEPLOY

  chmod +x "$dest"
  _own "$dest"
}

ensure_network() {
  if ! docker network inspect medianet &>/dev/null; then
    docker network create --driver bridge medianet
    success "Docker network 'medianet' created."
  else
    info "Docker network 'medianet' already exists."
  fi
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
  # Own as PUID:PGID — Traefik requires 600 but does NOT require root ownership
  _own "$acme_path"
  chmod 600 "$acme_path"
  success "acme.json ready (owner: 1000:1000, permissions: 600)."
  # Always (re)generate traefik.yml from current settings before deploying
  _traefik_write_config
  # Always (re)generate the standalone redeploy helper before deploying
  generate_redeploy_sh
}

# ── Directory provisioning ────────────────────────────────────────────────────
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
  mkdir -p "${cfg}/traefik" "${cfg}/portainer"
  chown -R "${uid}:${gid}" "${cfg}/traefik" "${cfg}/portainer"

  # /mnt and media root — containers and the media user need traversal rights
  chown "${uid}:${gid}" /mnt
  mkdir -p "$media"
  chown "${uid}:${gid}" "$media"

  # Media subdirs
  local subdir
  for subdir in movies tv downloads music; do
    mkdir -p "${media}/${subdir}"
    chown "${uid}:${gid}" "${media}/${subdir}"
  done

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

  if [[ -n "${SELECTED[netbootxyz]+_}" ]]; then
    mkdir -p "${media}/netboot/assets"
    chown -R "${uid}:${gid}" "${media}/netboot"
  fi

  # acme.json must be 600 — Traefik requires it, but does NOT require root ownership
  local acme="${cfg}/traefik/acme.json"
  if [[ -f "$acme" ]]; then
    chown "${uid}:${gid}" "$acme"
    chmod 600 "$acme"
    success "  ${acme}  [${uid}:${gid} 600]"
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
  cat > "$DNS_STATE_FILE" <<EOF
DNS_PROVIDER=${DNS_PROVIDER}
DNS_DOMAIN=${DNS_DOMAIN}
DNS_CF_EMAIL=${DNS_CF_EMAIL}
DNS_CF_API_KEY=${DNS_CF_API_KEY}
DNS_CF_ZONE_ID=${DNS_CF_ZONE_ID}
DNS_DUCKDNS_TOKEN=${DNS_DUCKDNS_TOKEN}
DNS_DUCKDNS_SUBDOMAIN=${DNS_DUCKDNS_SUBDOMAIN}
DNS_GODADDY_KEY=${DNS_GODADDY_KEY}
DNS_GODADDY_SECRET=${DNS_GODADDY_SECRET}
DNS_NAMECHEAP_USER=${DNS_NAMECHEAP_USER}
DNS_NAMECHEAP_API_KEY=${DNS_NAMECHEAP_API_KEY}
DNS_NAMECHEAP_SOURCE_IP=${DNS_NAMECHEAP_SOURCE_IP}
EOF
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
    [jellyseerr]="jellyseerr" [teamspeak6]="ts6"
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

case "$DNS_PROVIDER" in
  duckdns)
    curl -fsSL "https://www.duckdns.org/update?domains=${DNS_DUCKDNS_SUBDOMAIN}&token=${DNS_DUCKDNS_TOKEN}&ip=${IP}" >/dev/null 2>&1
    ;;
  cloudflare|godaddy|namecheap)
    /usr/local/bin/friendbox --dns-update >/dev/null 2>&1 || true
    ;;
esac
echo "$IP" > "$CACHE_FILE"
CRONEOF
  chmod +x "$cron_script"
  local cron_file="/etc/cron.d/friendbox-dns"
  echo "*/5 * * * * root ${cron_script} >> /var/log/friendbox-dns.log 2>&1" > "$cron_file"
  chmod 644 "$cron_file"
  success "Cron job installed: ${cron_file}"
  info "DNS checked/updated every 5 minutes. Logs: /var/log/friendbox-dns.log"
}

_dns_remove_cron() {
  local cron_file="/etc/cron.d/friendbox-dns"
  if [[ -f "$cron_file" ]]; then rm -f "$cron_file"; success "Cron job removed."
  else warn "No cron job found."; fi
}

configure_dns() {
  while true; do
    _dns_load
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              🌐  DNS A Record Manager                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    _dns_show_status
    local pub_ip; pub_ip=$(_dns_get_public_ip 2>/dev/null) || pub_ip="unknown"
    echo -e "  ${DIM}Current public IP: ${pub_ip}${RESET}"
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
  configure_env
  select_containers
  ensure_network
  ensure_acme
  provision_directories
  info "Starting selected containers..."
  compose_selected up -d
  echo ""
  success "✅ Friendbox is up!"
  mark_installed
  echo ""
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
  echo -e "  ${BOLD}Next steps if needed:${RESET}"
  echo -e "  ${DIM}  • Traefik dashboard password  → menu option  4${RESET}"
  echo -e "  ${DIM}  • VPN / AMP / Mumble creds    → menu option  5${RESET}"
  echo -e "  ${DIM}  • DNS A record setup           → menu option  6${RESET}"
  echo -e "  ${DIM}  • MergerFS storage pool        → menu option  7${RESET}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
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
      [qbittorrent]="http://${host_ip}:8080"
      [qbittorrentvpn]="http://${host_ip}:8181"
      [delugevpn]="http://${host_ip}:8112"
      [nzbget]="http://${host_ip}:6789"
      [overseerr]="http://${host_ip}:5055"
      [ombi]="http://${host_ip}:3579"
      [jellyseerr]="http://${host_ip}:5055"
      [teamspeak6]="${host_ip}:9987 (UDP voice)"
      [mumble]="${host_ip}:64738"
      [ampmc]="http://${host_ip}:8080"
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
        compose_selected pull
        compose_selected up -d --force-recreate
        success "All active containers redeployed."
        pause
        ;;
      2)
        echo ""
        read -rp "Container name (e.g. sonarr): " svc
        [[ -z "$svc" ]] && { warn "No name entered."; sleep 1; continue; }
        compose_selected pull "$svc"
        compose_selected up -d --force-recreate "$svc"
        success "${svc} redeployed."
        pause
        ;;
      3)
        compose_selected restart
        success "All containers restarted."
        pause
        ;;
      4)
        select_containers
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
  compose_selected pull
  compose_selected up -d
  success "Stack updated."
}

teardown() {
  echo ""
  warn "This will STOP and REMOVE all containers (data/config is preserved)."
  read -rp "Are you sure? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return; }
  compose_selected down --remove-orphans
  mark_uninstalled
  success "Containers removed. Run option 1 to reinstall."
}

view_logs() {
  echo ""
  read -rp "Container name (leave blank for all active): " svc
  if [[ -z "$svc" ]]; then compose_selected logs --tail=100 -f
  else compose_selected logs --tail=100 -f "$svc"; fi
}

# =============================================================================
#  Main Menu
# =============================================================================

main_menu() {
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
    echo "   5) Service credentials (VPN / AMP / Mumble)"
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
    echo "  15) Teardown (stop & remove containers)"
    echo "   q) Quit"
    echo ""
    read -rp "Select option: " opt

    # ── Gate operations-section items when not installed ─────────────────────
    if ! is_installed && [[ "$opt" =~ ^(10|11|12|13|14|15)$ ]]; then
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
      12) redeploy_menu                          ;;   # now has its own loop+return
      13) update_stack                    || true; pause ;;
      14) view_logs                       || true; pause ;;
      15) teardown                        || true; pause ;;
      q|Q) echo "Goodbye!"; exit 0 ;;
      *) warn "Invalid option '$opt'"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Entrypoint
# =============================================================================

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
