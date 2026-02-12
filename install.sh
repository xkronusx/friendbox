#!/usr/bin/env bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/xkronusx/friendbox/main"

TMP_DIR="/tmp/friendbox-install"
mkdir -p "$TMP_DIR"

echo "Downloading friendbox..."

curl -fsSL "$REPO/scripts/bootstrap.sh" -o "$TMP_DIR/bootstrap.sh"
curl -fsSL "$REPO/docker-compose.yml" -o "$TMP_DIR/docker-compose.yml"

chmod +x "$TMP_DIR/bootstrap.sh"

sudo bash "$TMP_DIR/bootstrap.sh" "$TMP_DIR/docker-compose.yml"

echo "friendbox installation complete."
