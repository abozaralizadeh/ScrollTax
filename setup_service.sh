#!/usr/bin/env bash
# Sets up, or updates, the ScrollTax backend on a Debian or Ubuntu VM.
# Run it as root. The first run installs everything. Every run after that updates and restarts.
#
#   sudo ./setup_service.sh
#   sudo DOMAIN=api.example.com ./setup_service.sh     # also sets up HTTPS with Caddy
#
# Logs:   journalctl -u scrolltax.service -f
# Files:  /opt/scrolltax/backend/logs/scrolltax.log (capped, copy it to your computer for debugging)
set -euo pipefail

APP_DIR=/opt/scrolltax
APP_USER=scrolltax
SERVICE=scrolltax
NODE_MAJOR=24
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n==> %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Please run this as root: sudo $0" >&2
  exit 1
fi

say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl rsync openssl >/dev/null

node_ok() {
  command -v node >/dev/null 2>&1 && [[ "$(node -p 'process.versions.node.split(".")[0]')" -ge $NODE_MAJOR ]]
}
if ! node_ok; then
  say "Installing Node.js $NODE_MAJOR"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "Node $(node -v)"

say "Creating the service user and folders"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR"

say "Copying the code (your .env, data and logs are left alone)"
rsync -a --delete \
  --exclude '.env' --exclude 'data/' --exclude 'logs/' --exclude 'node_modules/' \
  "$SRC_DIR/backend/" "$APP_DIR/backend/"
rsync -a --delete "$SRC_DIR/web/" "$APP_DIR/web/"
mkdir -p "$APP_DIR/backend/data" "$APP_DIR/backend/logs"

say "Installing the backend's packages"
(cd "$APP_DIR/backend" && npm ci --omit=dev --no-audit --no-fund --silent)

ENV_FILE="$APP_DIR/backend/.env"
if [[ ! -f $ENV_FILE ]]; then
  say "Creating $ENV_FILE with a fresh secret"
  cp "$APP_DIR/backend/.env.example" "$ENV_FILE"
  sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=$(openssl rand -hex 32)|" "$ENV_FILE"
  echo "APPLE_MODE is 'fake' in this file. That's only for testing. Never open the server to the public like that."
fi
chmod 600 "$ENV_FILE"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

say "Installing the services"
install -m 644 "$SRC_DIR/deploy/scrolltax.service" /etc/systemd/system/scrolltax.service
install -m 644 "$SRC_DIR/deploy/scrolltax-backup.service" /etc/systemd/system/scrolltax-backup.service
install -m 644 "$SRC_DIR/deploy/scrolltax-backup.timer" /etc/systemd/system/scrolltax-backup.timer
systemctl daemon-reload
systemctl enable --now scrolltax-backup.timer >/dev/null
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

if [[ -n ${DOMAIN:-} ]]; then
  say "Setting up HTTPS for $DOMAIN with Caddy"
  if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' >/etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null
  fi
  sed "s/api.example.com/$DOMAIN/" "$SRC_DIR/deploy/Caddyfile.example" >/etc/caddy/Caddyfile
  systemctl reload caddy || systemctl restart caddy
fi

say "Checking that it started"
PORT=$(grep -E '^PORT=' "$ENV_FILE" | cut -d= -f2 || true)
for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${PORT:-8787}/healthz" >/dev/null 2>&1; then
    echo "ScrollTax backend is up."
    echo "Watch the logs with: journalctl -u scrolltax.service -f"
    exit 0
  fi
  sleep 0.5
done
echo "The backend did not answer. Look at: journalctl -u scrolltax.service -n 50 --no-pager" >&2
exit 1
