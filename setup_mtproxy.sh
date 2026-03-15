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

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get -y install curl tar openssl ca-certificates
fi

if ! id -u mtproxy >/dev/null 2>&1; then
  useradd --system --home /var/lib/mtproxy --create-home --shell /usr/sbin/nologin mtproxy
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64)
    ASSET_ARCH_VARIANTS="amd64 x86_64"
    ;;
  arm64)
    ASSET_ARCH_VARIANTS="arm64 aarch64"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

fetch_mtg() {
  local url="$1"
  local out="$2"
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$out"
}

MTG_READY=0
for arch_variant in ${ASSET_ARCH_VARIANTS}; do
  for filename in "mtg-linux-${arch_variant}.tar.gz" "mtg-linux-${arch_variant}.tgz" "mtg-linux-${arch_variant}"; do
    URL="https://github.com/9seconds/mtg/releases/latest/download/${filename}"
    TARGET="$TMPDIR/${filename}"

    if fetch_mtg "$URL" "$TARGET" >/dev/null 2>&1; then
      if [[ "$filename" == *.tar.gz || "$filename" == *.tgz ]]; then
        tar -xzf "$TARGET" -C "$TMPDIR"
        if [[ -f "$TMPDIR/mtg" ]]; then
          install -m 0755 "$TMPDIR/mtg" /usr/local/bin/mtg
          MTG_READY=1
          break 2
        fi
      else
        install -m 0755 "$TARGET" /usr/local/bin/mtg
        MTG_READY=1
        break 2
      fi
    fi
  done
done

if [[ "$MTG_READY" -ne 1 ]]; then
  echo "Failed to download mtg release asset from GitHub. Check network/firewall or install mtg manually to /usr/local/bin/mtg." >&2
  exit 1
fi

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
