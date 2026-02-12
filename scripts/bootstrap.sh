#!/usr/bin/env bash
set -euo pipefail

COMPOSE_SOURCE="$1"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

USER_NAME=${SUDO_USER:-$(logname 2>/dev/null || echo root)}

echo "Updating system..."
apt update -y

# -----------------------------
# Required packages (excluding curl)
# -----------------------------
REQUIRED=(
  ca-certificates
  gnupg
  lsb-release
  software-properties-common
)

for pkg in "${REQUIRED[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    apt install -y "$pkg"
  fi
done

# -----------------------------
# GNOME Desktop (if missing)
# -----------------------------
if ! dpkg -s ubuntu-gnome-desktop &>/dev/null; then
  apt install -y ubuntu-gnome-desktop
fi

systemctl enable gdm || true

# -----------------------------
# Install Docker (if missing)
# -----------------------------
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
  fi

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# -----------------------------
# Docker group
# -----------------------------
if ! getent group docker > /dev/null; then
  groupadd docker
fi

if ! id -nG "$USER_NAME" | grep -qw docker; then
  usermod -aG docker "$USER_NAME"
fi

# -----------------------------
# Create friendbox storage
# -----------------------------
FRIENDBOX_BASE="/mnt/friendbox"

mkdir -p \
  $FRIENDBOX_BASE/config/{jellyfin,portainer,sonarr,radarr,delugevpn,teamspeak} \
  $FRIENDBOX_BASE/downloads \
  $FRIENDBOX_BASE/movies \
  $FRIENDBOX_BASE/tv

chown -R "$USER_NAME":docker $FRIENDBOX_BASE

# -----------------------------
# Install stack
# -----------------------------
INSTALL_DIR="/opt/friendbox"
mkdir -p "$INSTALL_DIR"

cp "$COMPOSE_SOURCE" "$INSTALL_DIR/docker-compose.yml"

cd "$INSTALL_DIR"
docker compose up -d

echo ""
echo "======================================"
echo "friendbox installed."
echo ""
echo "Log out and back in for docker group."
echo ""
echo "Jellyfin  : http://SERVER_IP:8096"
echo "Portainer : https://SERVER_IP:9443"
echo "Sonarr    : http://SERVER_IP:8989"
echo "Radarr    : http://SERVER_IP:7878"
echo "DelugeVPN : http://SERVER_IP:8112"
echo "TeamSpeak : UDP 9987"
echo "======================================"
