#!/usr/bin/env bash
# =============================================================================
#  Friendbox Setup — Interactive Menu
#  curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/setup.sh | bash
#
#  Tested on: Ubuntu 24.04.4 LTS (Noble Numbat)
# =============================================================================

set -euo pipefail

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

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "This action must be run as root. Use sudo."
}

pause() {
  echo ""
  read -rp "Press [Enter] to return to the menu..."
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
  [traefik]="Reverse proxy + automatic HTTPS (required)"
  [portainer]="Docker management UI (required)"
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
  [traefik]=true    [portainer]=true
  [plex]=false      [jellyfin]=false
  [sonarr]=false    [radarr]=false    [prowlarr]=false  [bazarr]=false
  [qbittorrent]=false [qbittorrentvpn]=false [delugevpn]=false [nzbget]=false
  [overseerr]=false [ombi]=false      [jellyseerr]=false
  [teamspeak6]=false [mumble]=false
  [ampmc]=false
  [netbootxyz]=false
)

# ── VPN containers ────────────────────────────────────────────────────────────
VPN_CONTAINERS=(qbittorrentvpn delugevpn)

needs_vpn_config() {
  local k
  for k in "${VPN_CONTAINERS[@]}"; do
    [[ -n "${SELECTED[$k]+_}" ]] && return 0
  done
  return 1
}

configure_vpn() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}VPN Configuration${RESET}"
  echo -e "${DIM}Required for qBittorrentVPN and/or DelugeVPN.${RESET}"
  echo ""
  read -rp "VPN provider (pia, airvpn, mullvad, custom) [${VPN_PROV:-pia}]: " input
  VPN_PROV="${input:-${VPN_PROV:-pia}}"
  read -rp "VPN client (openvpn, wireguard) [${VPN_CLIENT:-openvpn}]: " input
  VPN_CLIENT="${input:-${VPN_CLIENT:-openvpn}}"
  read -rp "VPN username [${VPN_USER:-}]: " input
  VPN_USER="${input:-${VPN_USER:-}}"
  read -srp "VPN password: " VPN_PASS; echo ""
  read -rp "LAN network CIDR [${LAN_NETWORK:-192.168.1.0/24}]: " input
  LAN_NETWORK="${input:-${LAN_NETWORK:-192.168.1.0/24}}"

  local var
  for var in VPN_PROV VPN_CLIENT VPN_USER VPN_PASS LAN_NETWORK; do
    sed -i "/^${var}=/d" "$ENV_FILE" 2>/dev/null || true
    echo "${var}=${!var}" >> "$ENV_FILE"
  done
  success "VPN config saved."
}

configure_extras() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

  if [[ -n "${SELECTED[ampmc]+_}" ]]; then
    echo ""
    echo -e "${BOLD}AMP (Game Server Panel) Credentials${RESET}"
    read -rp "AMP admin username [${AMP_USER:-admin}]: " input
    AMP_USER="${input:-${AMP_USER:-admin}}"
    read -srp "AMP admin password: " AMP_PASS; echo ""
    sed -i '/^AMP_USER=/d;/^AMP_PASS=/d' "$ENV_FILE" 2>/dev/null || true
    printf 'AMP_USER=%s\nAMP_PASS=%s\n' "$AMP_USER" "$AMP_PASS" >> "$ENV_FILE"
    success "AMP credentials saved."
  fi

  if [[ -n "${SELECTED[mumble]+_}" ]]; then
    echo ""
    echo -e "${BOLD}Mumble Superuser Password${RESET}"
    read -srp "Mumble superuser password [changeme]: " MUMBLE_SUPERUSER_PASSWORD
    MUMBLE_SUPERUSER_PASSWORD="${MUMBLE_SUPERUSER_PASSWORD:-changeme}"
    echo ""
    sed -i '/^MUMBLE_SUPERUSER_PASSWORD=/d' "$ENV_FILE" 2>/dev/null || true
    echo "MUMBLE_SUPERUSER_PASSWORD=${MUMBLE_SUPERUSER_PASSWORD}" >> "$ENV_FILE"
    success "Mumble password saved."
  fi
}

# ── Load / save selected containers ──────────────────────────────────────────
load_selected() {
  declare -gA SELECTED=()
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ "${CONTAINER_ALWAYS[$key]}" == "true" ]] && SELECTED[$key]=1
  done
  if [[ -f "$SELECTED_FILE" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && SELECTED[$line]=1
    done < "$SELECTED_FILE"
  fi
}

save_selected() {
  mkdir -p "${INSTALL_DIR}"
  : > "$SELECTED_FILE"
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] && echo "$key" >> "$SELECTED_FILE"
  done
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
    echo -e "  ${DIM}Traefik and Portainer are always installed.${RESET}"
    echo -e "  Toggle with the item number. ${BOLD}a${RESET}=all  ${BOLD}n${RESET}=none  ${BOLD}d${RESET}=done"
    echo ""

    local i=1
    declare -A IDX_MAP=()
    local key
    for key in "${CONTAINER_ORDER[@]}"; do
      if [[ -n "${CONTAINER_CATEGORY[$key]+_}" ]]; then
        echo -e "  ${BOLD}${CYAN}${CONTAINER_CATEGORY[$key]}${RESET}"
      fi
      local always="${CONTAINER_ALWAYS[$key]}"
      local name="${CONTAINER_NAMES[$key]}"
      local desc="${CONTAINER_DESC[$key]}"
      local chosen=""
      [[ -n "${SELECTED[$key]+_}" ]] && chosen="1"

      if [[ "$always" == "true" ]]; then
        printf "  ${DIM}[✔] %2d) %-24s — %s${RESET}\n" "$i" "$name" "$desc"
      elif [[ -n "$chosen" ]]; then
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
          [[ "${CONTAINER_ALWAYS[$key]}" == "true" ]] && continue
          unset "SELECTED[$key]" 2>/dev/null || true
        done ;;
      ''|*[!0-9]*)
        warn "Enter a number, a, n, or d."; sleep 1 ;;
      *)
        if [[ -n "${IDX_MAP[$choice]+_}" ]]; then
          local k="${IDX_MAP[$choice]}"
          if [[ "${CONTAINER_ALWAYS[$k]}" == "true" ]]; then
            warn "${CONTAINER_NAMES[$k]} is required and cannot be deselected."; sleep 1
          elif [[ -n "${SELECTED[$k]+_}" ]]; then
            unset "SELECTED[$k]"
          else
            SELECTED[$k]=1
          fi
        else
          warn "Invalid number."; sleep 1
        fi ;;
    esac
  done

  save_selected
  needs_vpn_config && configure_vpn
  configure_extras

  echo ""
  info "Selected containers:"
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] && echo "    ✔ ${CONTAINER_NAMES[$key]}"
  done
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
  curl -fsSL "${REPO_URL}/${path}" -o "${dest}" || die "Failed to fetch ${path} from repo."
}

sync_repo() {
  info "Syncing latest files from GitHub..."
  mkdir -p "${INSTALL_DIR}"/{config/traefik,scripts}
  fetch_remote "docker-compose.yml"           "${COMPOSE_FILE}"
  fetch_remote "config/traefik/traefik.yml"   "${INSTALL_DIR}/config/traefik/traefik.yml"
  fetch_remote "scripts/redeploy.sh"          "${INSTALL_DIR}/scripts/redeploy.sh"
  chmod +x "${INSTALL_DIR}/scripts/redeploy.sh"
  success "Repo synced to ${INSTALL_DIR}"
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
  : > "$MERGERFS_MODES_FILE"
  local path
  for path in "${!DISK_MODES[@]}"; do
    echo "${path}=${DISK_MODES[$path]}" >> "$MERGERFS_MODES_FILE"
  done
}

_mergerfs_load_pool() {
  MERGERFS_POOL=""
  [[ -f "$MERGERFS_POOL_FILE" ]] && MERGERFS_POOL=$(cat "$MERGERFS_POOL_FILE")
}

_mergerfs_save_pool() { echo "$1" > "$MERGERFS_POOL_FILE"; }

_mergerfs_build_branch_list() {
  local rw_branches=() ro_branches=() path
  for path in "${!DISK_MODES[@]}"; do
    case "${DISK_MODES[$path]}" in
      RW) rw_branches+=("${path}=RW") ;;
      RO) ro_branches+=("${path}=RO") ;;
      NC) ro_branches+=("${path}=NC") ;;
    esac
  done
  local all=("${rw_branches[@]}" "${ro_branches[@]}")
  local IFS=:
  echo "${all[*]}"
}

_mergerfs_write_fstab() {
  local pool_path="$1"
  local branch_list
  branch_list=$(_mergerfs_build_branch_list)
  sed -i "\|${pool_path}.*fuse.mergerfs|d" /etc/fstab
  echo "${branch_list}  ${pool_path}  fuse.mergerfs  defaults,allow_other,use_ino,cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,fsname=mergerfs  0  0" >> /etc/fstab
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
  echo "  2) NC — No-Create   (existing files readable, no new files written here)"
  echo "  3) RO — Read-Only   (existing files readable, no writes at all)"
  read -rp "  Mode [1]: " msel
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

_mergerfs_protect_os() {
  _mergerfs_load_modes; _mergerfs_load_pool
  echo ""
  echo -e "${BOLD}Protect OS Drive${RESET}"
  echo -e "${DIM}Adds the OS filesystem as NC — mergerfs reads existing data but"
  echo -e "redirects all new writes to your RW disks, draining it over time.${RESET}"
  echo ""
  local os_mount
  os_mount=$(df / 2>/dev/null | awk 'NR==2{print $6}')
  echo -e "  Detected OS mount: ${CYAN}${os_mount:-/}${RESET}"
  echo ""
  read -rp "OS mount path to add as NC [${os_mount:-/}]: " input
  local os_path="${input:-${os_mount:-/}}"
  if [[ -n "${DISK_MODES[$os_path]+_}" ]]; then
    warn "${os_path} is already in the pool as ${DISK_MODES[$os_path]}."
    read -rp "Update it to NC? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; return; }
  fi
  DISK_MODES[$os_path]="NC"
  _mergerfs_save_modes
  [[ -n "$MERGERFS_POOL" ]] && { _mergerfs_write_fstab "$MERGERFS_POOL"; _mergerfs_remount "$MERGERFS_POOL"; }
  success "OS drive ${os_path} added as NC."
}

_mergerfs_initial_setup() {
  info "Installing mergerfs..."
  apt-get install -y mergerfs || die "Could not install mergerfs."
  _mergerfs_load_modes
  mkdir -p "${INSTALL_DIR}"
  echo ""
  echo -e "${BOLD}MergerFS Pool Configuration${RESET}"
  echo "Enter each disk path you want to pool, one at a time."
  echo ""
  local added=0 disk mode
  while true; do
    read -rp "Disk mount path (or Enter to finish): " disk
    [[ -z "$disk" ]] && break
    [[ ! -d "$disk" ]] && { warn "${disk} does not exist. Creating it..."; mkdir -p "$disk"; }
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
  [[ $added -eq 0 ]] && die "No disks entered. Aborting mergerfs setup."

  local pool_path="/mnt/media"
  read -rp "Pool mount point [${pool_path}]: " custom_pool
  [[ -n "$custom_pool" ]] && pool_path="$custom_pool"
  mkdir -p "$pool_path"

  _mergerfs_save_modes
  _mergerfs_save_pool "$pool_path"
  _mergerfs_write_fstab "$pool_path"
  _mergerfs_remount "$pool_path"

  sed -i '/^MEDIA_ROOT=/d' "${STATE_FILE}" 2>/dev/null || true
  echo "MEDIA_ROOT=${pool_path}" >> "${STATE_FILE}"

  echo ""
  read -rp "Would you like to protect the OS drive as NC now? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] && _mergerfs_protect_os
  success "MergerFS pool configured at ${pool_path}."
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
    echo "  3) Change a disk's mode (RW / NC / RO)"
    echo "  4) Remove a disk from the pool"
    echo "  5) Protect OS drive (set as NC)"
    echo "  6) Back to main menu"
    echo ""
    read -rp "  Choice: " choice
    case "$choice" in
      1) _mergerfs_initial_setup; pause ;;
      2) _mergerfs_add_disk;      pause ;;
      3) _mergerfs_change_mode;   pause ;;
      4) _mergerfs_remove_disk;   pause ;;
      5) _mergerfs_protect_os;    pause ;;
      6) return ;;
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
  [[ -f "$ENV_FILE" ]]   && source "$ENV_FILE"   2>/dev/null || true
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true

  read -rp "Your domain (e.g. example.com) [${DOMAIN:-}]: " input
  DOMAIN="${input:-${DOMAIN:-example.com}}"
  read -rp "ACME/Let's Encrypt email [${ACME_EMAIL:-}]: " input
  ACME_EMAIL="${input:-${ACME_EMAIL:-admin@example.com}}"
  read -rp "Media root path [${MEDIA_ROOT:-/mnt/media}]: " input
  MEDIA_ROOT="${input:-${MEDIA_ROOT:-/mnt/media}}"
  read -rp "Config root path [${CONFIG_ROOT:-/opt/friendbox/config}]: " input
  CONFIG_ROOT="${input:-${CONFIG_ROOT:-/opt/friendbox/config}}"
  read -rp "PUID [${PUID:-1000}]: " input; PUID="${input:-${PUID:-1000}}"
  read -rp "PGID [${PGID:-1000}]: " input; PGID="${input:-${PGID:-1000}}"
  read -rp "Timezone [${TZ:-America/Toronto}]: " input
  TZ="${input:-${TZ:-America/Toronto}}"

  local TRAEFIK_AUTH
  if command -v htpasswd &>/dev/null; then
    read -rp "Traefik dashboard username [admin]: " dash_user
    dash_user="${dash_user:-admin}"
    read -srp "Traefik dashboard password: " dash_pass; echo ""
    TRAEFIK_AUTH=$(htpasswd -nbB "$dash_user" "$dash_pass" | sed 's/\$/\$\$/g')
  else
    warn "htpasswd not found — install apache2-utils for dashboard auth."
    TRAEFIK_AUTH="admin:\$\$apr1\$\$placeholder"
  fi

  mkdir -p "${INSTALL_DIR}"
  cat > "$ENV_FILE" <<EOF
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
CONFIG_ROOT=${CONFIG_ROOT}
MEDIA_ROOT=${MEDIA_ROOT}
TRAEFIK_AUTH=${TRAEFIK_AUTH}
EOF
  success ".env written to ${ENV_FILE}"
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
  local acme_path="${INSTALL_DIR}/config/traefik/acme.json"
  mkdir -p "$(dirname "$acme_path")"
  [[ -f "$acme_path" ]] || touch "$acme_path"
  chmod 600 "$acme_path"
  success "acme.json ready (permissions: 600)."
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

  # Install dir
  mkdir -p "${INSTALL_DIR}"
  chown "${uid}:${gid}" "${INSTALL_DIR}"

  # Always-on config dirs
  mkdir -p "${cfg}/traefik" "${cfg}/portainer"
  chown -R "${uid}:${gid}" "${cfg}/traefik" "${cfg}/portainer"

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

  # acme.json must stay root-owned at 600 for Traefik
  local acme="${cfg}/traefik/acme.json"
  [[ -f "$acme" ]] || touch "$acme"
  chmod 600 "$acme"

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
  mkdir -p "${INSTALL_DIR}"
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
  echo ""
  read -rp "Domain (e.g. example.com) [${DNS_DOMAIN:-}]: " input
  DNS_DOMAIN="${input:-${DNS_DOMAIN:-}}"
  [[ -z "$DNS_DOMAIN" ]] && { warn "Domain required."; return; }
  read -rp "Cloudflare account email [${DNS_CF_EMAIL:-}]: " input
  DNS_CF_EMAIL="${input:-${DNS_CF_EMAIL:-}}"
  read -srp "Global API Key or API Token: " DNS_CF_API_KEY; echo ""
  [[ -z "$DNS_CF_API_KEY" ]] && { warn "API key required."; return; }

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
    read -rp "Enter Zone ID manually [${DNS_CF_ZONE_ID:-}]: " input
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
  echo ""
  read -rp "DuckDNS subdomain prefix (e.g. 'myhome') [${DNS_DUCKDNS_SUBDOMAIN:-}]: " input
  DNS_DUCKDNS_SUBDOMAIN="${input:-${DNS_DUCKDNS_SUBDOMAIN:-}}"
  [[ -z "$DNS_DUCKDNS_SUBDOMAIN" ]] && { warn "Subdomain required."; return; }
  DNS_DOMAIN="${DNS_DUCKDNS_SUBDOMAIN}.duckdns.org"
  read -srp "DuckDNS token: " DNS_DUCKDNS_TOKEN; echo ""
  [[ -z "$DNS_DUCKDNS_TOKEN" ]] && { warn "Token required."; return; }
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
  echo ""
  read -rp "Domain (e.g. example.com) [${DNS_DOMAIN:-}]: " input
  DNS_DOMAIN="${input:-${DNS_DOMAIN:-}}"
  [[ -z "$DNS_DOMAIN" ]] && { warn "Domain required."; return; }
  read -rp "GoDaddy API Key [${DNS_GODADDY_KEY:-}]: " input
  DNS_GODADDY_KEY="${input:-${DNS_GODADDY_KEY:-}}"
  read -srp "GoDaddy API Secret: " DNS_GODADDY_SECRET; echo ""
  [[ -z "$DNS_GODADDY_KEY" || -z "$DNS_GODADDY_SECRET" ]] && { warn "Key and secret required."; return; }
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
  echo ""
  read -rp "Namecheap username [${DNS_NAMECHEAP_USER:-}]: " input
  DNS_NAMECHEAP_USER="${input:-${DNS_NAMECHEAP_USER:-}}"
  read -rp "Domain (e.g. example.com) [${DNS_DOMAIN:-}]: " input
  DNS_DOMAIN="${input:-${DNS_DOMAIN:-}}"
  [[ -z "$DNS_DOMAIN" ]] && { warn "Domain required."; return; }
  read -srp "Dynamic DNS Password (from Advanced DNS panel): " DNS_NAMECHEAP_API_KEY; echo ""
  [[ -z "$DNS_NAMECHEAP_API_KEY" ]] && { warn "Password required."; return; }
  info "Detecting public IP..."
  local pub_ip; pub_ip=$(_dns_get_public_ip 2>/dev/null) || pub_ip=""
  read -rp "Whitelisted public IP [${DNS_NAMECHEAP_SOURCE_IP:-${pub_ip}}]: " input
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
      1) _dns_configure_cloudflare; pause ;;
      2) _dns_configure_duckdns;    pause ;;
      3) _dns_configure_godaddy;    pause ;;
      4) _dns_configure_namecheap;  pause ;;
      5) _dns_update_now;           pause ;;
      6) _dns_show_subdomains;      pause ;;
      7) _dns_install_cron;         pause ;;
      8) _dns_remove_cron;          pause ;;
      9) return ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Core Install & Operations
# =============================================================================

full_install() {
  require_root
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
  print_urls
}

print_urls() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true
  load_selected
  local d="${DOMAIN:-yourdomain.com}"
  echo ""
  echo -e "${BOLD}Active Service URLs${RESET}"
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
  local key
  for key in "${CONTAINER_ORDER[@]}"; do
    [[ -n "${SELECTED[$key]+_}" ]] \
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
      ;;
    2)
      echo ""
      read -rp "Container name (e.g. sonarr): " svc
      [[ -z "$svc" ]] && { warn "No name entered."; return; }
      compose_selected pull "$svc"
      compose_selected up -d --force-recreate "$svc"
      success "${svc} redeployed."
      ;;
    3) compose_selected restart; success "All containers restarted." ;;
    4)
      select_containers
      compose_selected up -d --remove-orphans
      success "Stack updated."
      ;;
    5) return ;;
    *) warn "Invalid choice." ;;
  esac
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
  success "Containers removed."
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
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║          📦  Friendbox Manager           ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
    load_selected
    local count="${#SELECTED[@]}"
    echo -e "  ${DIM}Active containers: ${count}${RESET}"
    echo ""
    echo "  1) Full Install (first time setup)"
    echo "  2) Select containers to install"
    echo "  3) Configure / Reconfigure .env"
    echo "  4) DNS A record manager"
    echo "  5) MergerFS storage manager"
    echo "  6) Sync latest files from GitHub"
    echo "  7) Provision / fix directory ownership"
    echo "  8) Show container status"
    echo "  9) View service URLs"
    echo " 10) Redeploy containers"
    echo " 11) Update stack (pull latest images)"
    echo " 12) View logs"
    echo " 13) Teardown (stop & remove containers)"
    echo "  q) Quit"
    echo ""
    read -rp "Select option: " opt
    case "$opt" in
      1)  full_install;             pause ;;
      2)  select_containers;        pause ;;
      3)  configure_env;            pause ;;
      4)  configure_dns;            pause ;;
      5)  setup_mergerfs;           pause ;;
      6)  sync_repo;                pause ;;
      7)  provision_directories;    pause ;;
      8)  show_status;              pause ;;
      9)  print_urls;               pause ;;
      10) redeploy_menu;            pause ;;
      11) update_stack;             pause ;;
      12) view_logs ;;
      13) teardown;                 pause ;;
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
  main_menu
fi
