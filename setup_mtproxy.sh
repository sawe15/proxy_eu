#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

MTPROXY_PORT="${MTPROXY_PORT:-443}"
MTPROXY_AD_TAG="${MTPROXY_AD_TAG:-}"
MTPROXY_DOMAIN="${MTPROXY_DOMAIN:-www.cloudflare.com}"
MTPROXY_BIND_IP="${MTPROXY_BIND_IP:-0.0.0.0}"

if ! id -u mtproxy >/dev/null 2>&1; then
  useradd --system --home /var/lib/mtproxy --create-home --shell /usr/sbin/nologin mtproxy
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) MTG_ARCH="amd64" ;;
  arm64) MTG_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

curl -fsSL "https://github.com/9seconds/mtg/releases/latest/download/mtg-linux-${MTG_ARCH}.tar.gz" -o "$TMPDIR/mtg.tgz"
tar -xzf "$TMPDIR/mtg.tgz" -C "$TMPDIR"
install -m 0755 "$TMPDIR/mtg" /usr/local/bin/mtg

SECRET_FILE="/etc/mtproxy-secret"
if [[ ! -f "$SECRET_FILE" ]]; then
  openssl rand -hex 16 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

SECRET="$(tr -d '\n' < "$SECRET_FILE")"
PUBLIC_IP="$(curl -4 -fsSL https://api.ipify.org || true)"

cat > /etc/systemd/system/mtproxy.service <<SERVICE
[Unit]
Description=MTProxy service for Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
ExecStart=/usr/local/bin/mtg run \
  --bind ${MTPROXY_BIND_IP}:${MTPROXY_PORT} \
  --secret ${SECRET} \
  --domain ${MTPROXY_DOMAIN} \
  ${MTPROXY_AD_TAG:+--ad-tag ${MTPROXY_AD_TAG}}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/mtproxy
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now mtproxy

echo "MTProxy started on ${MTPROXY_BIND_IP}:${MTPROXY_PORT}"
echo "Secret: ${SECRET}"
if [[ -n "$PUBLIC_IP" ]]; then
  echo "tg://proxy?server=${PUBLIC_IP}&port=${MTPROXY_PORT}&secret=dd${SECRET}"
else
  echo "Public IP unavailable. Build Telegram link manually."
fi
