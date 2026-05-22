#!/usr/bin/env bash
# Installs Docker and runs an mtg (MTProxy) container on port 15001.
# Requires: proxy.conf (from 01-secrets.sh), root, curl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/proxy.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}==> $*${NC}"; }

[[ $EUID -eq 0 ]] || error "Run as root (sudo $0)"
[[ -f "$CONF_FILE" ]] || error "proxy.conf not found — run 01-secrets.sh first"
# shellcheck source=proxy.conf
source "$CONF_FILE"

[[ -n "${PROXY_MTG_SECRET:-}" ]] || error "PROXY_MTG_SECRET missing in proxy.conf"

MTG_IMAGE="nineseconds/mtg:2"
MTG_CONTAINER="mtg"

# ── install docker ─────────────────────────────────────────────────────────────
header "Installing Docker"

if command -v docker &>/dev/null; then
  info "Docker already installed: $(docker --version)"
else
  . /etc/os-release
  case "$ID" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg lsb-release

      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$ID/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$ID $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io
      ;;
    *)
      error "Unsupported OS: $ID. Install Docker manually and re-run."
      ;;
  esac

  systemctl enable --now docker
  info "Docker installed: $(docker --version)"

  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER"
    info "Added $SUDO_USER to docker group (re-login or run: newgrp docker)"
  fi
fi

systemctl is-active --quiet docker || { systemctl start docker; sleep 2; }

# ── deploy mtg container ───────────────────────────────────────────────────────
header "Deploying mtg container"

if docker inspect "$MTG_CONTAINER" &>/dev/null; then
  RUNNING_SECRET=$(docker inspect "$MTG_CONTAINER" \
    --format '{{range .Args}}{{.}} {{end}}' 2>/dev/null | grep -oE 'ee[0-9a-f]+' || true)
  if [[ "$RUNNING_SECRET" == "$PROXY_MTG_SECRET" ]]; then
    info "Container '$MTG_CONTAINER' already running with correct secret — skipping"
  else
    warn "Recreating container (secret changed)"
    docker rm -f "$MTG_CONTAINER"
  fi
fi

if ! docker inspect "$MTG_CONTAINER" &>/dev/null; then
  info "Pulling $MTG_IMAGE..."
  docker pull "$MTG_IMAGE"

  info "Starting container on port ${PROXY_MTG_PORT}..."
  docker run -d \
    --name "$MTG_CONTAINER" \
    --restart unless-stopped \
    -p "${PROXY_MTG_PORT}:3128" \
    "$MTG_IMAGE" \
    simple-run 0.0.0.0:3128 "${PROXY_MTG_SECRET}"
fi

sleep 2
docker inspect "$MTG_CONTAINER" --format '{{.State.Status}}' | grep -q "running" \
  || error "Container '$MTG_CONTAINER' failed to start (docker logs $MTG_CONTAINER)"

# ── firewall ───────────────────────────────────────────────────────────────────
header "Configuring firewall"

if command -v ufw &>/dev/null; then
  ufw allow "${PROXY_MTG_PORT}/tcp" comment "MTProxy" > /dev/null
  info "UFW: allowed ${PROXY_MTG_PORT}/tcp"
else
  warn "ufw not found — open port ${PROXY_MTG_PORT}/tcp manually"
fi

# ── print links ────────────────────────────────────────────────────────────────
header "Done"

SERVER_IP=$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
  || hostname -I | awk '{print $1}')

echo ""
info "MTProxy is running on port ${PROXY_MTG_PORT}"
echo ""
echo "  Telegram proxy link:"
echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_MTG_PORT}&secret=${PROXY_MTG_SECRET}"
echo ""
echo "  Or via https link:"
echo "  https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_MTG_PORT}&secret=${PROXY_MTG_SECRET}"
echo ""
info "Monitor: docker logs -f $MTG_CONTAINER"
