#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

MTPROXY_PORT="${MTPROXY_PORT:-443}"
MTPROXY_INTERNAL_PORT="${MTPROXY_INTERNAL_PORT:-3128}"
MTPROXY_DOMAIN="${MTPROXY_DOMAIN:-www.cloudflare.com}"
MTPROXY_SECRET="${MTPROXY_SECRET:-}"
MTG_DOCKER_TAG="${MTG_DOCKER_TAG:-2}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nineseconds/mtg:${MTG_DOCKER_TAG}}"
MTG_CONFIG_PATH="${MTG_CONFIG_PATH:-/etc/mtg.toml}"

if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get -y install docker.io ca-certificates curl
fi

systemctl enable --now docker

if [[ -z "$MTPROXY_SECRET" ]]; then
  MTPROXY_SECRET="$(docker run --rm "$DOCKER_IMAGE" generate-secret --hex "$MTPROXY_DOMAIN")"
fi

mkdir -p "$(dirname "$MTG_CONFIG_PATH")"
cat > "$MTG_CONFIG_PATH" <<CFG
secret = "${MTPROXY_SECRET}"
bind-to = "0.0.0.0:${MTPROXY_INTERNAL_PORT}"
CFG
chmod 600 "$MTG_CONFIG_PATH"

if docker ps -a --format '{{.Names}}' | rg -xq 'mtg-proxy'; then
  docker rm -f mtg-proxy >/dev/null
fi

docker pull "$DOCKER_IMAGE"
docker run -d \
  --name mtg-proxy \
  --restart unless-stopped \
  -p "${MTPROXY_PORT}:${MTPROXY_INTERNAL_PORT}" \
  -v "${MTG_CONFIG_PATH}:/config.toml:ro" \
  "$DOCKER_IMAGE" run /config.toml

PUBLIC_IP="$(curl -4 -fsSL https://api.ipify.org || true)"

echo "MTProxy docker container started: ${DOCKER_IMAGE}"
echo "Config: ${MTG_CONFIG_PATH}"
echo "Secret: ${MTPROXY_SECRET}"
if [[ -n "$PUBLIC_IP" ]]; then
  echo "tg://proxy?server=${PUBLIC_IP}&port=${MTPROXY_PORT}&secret=${MTPROXY_SECRET}"
else
  echo "Public IP unavailable. Build Telegram link manually."
fi
