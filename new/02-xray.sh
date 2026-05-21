#!/usr/bin/env bash
# Installs xray-core and configures a standalone VLESS+Reality inbound on port 443.
# Requires: proxy.conf (from 01-secrets.sh), root, curl, unzip
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

[[ -n "${PROXY_XRAY_PRIVATE_KEY:-}" ]] || error "PROXY_XRAY_PRIVATE_KEY missing in proxy.conf"

XRAY_VERSION="1.8.24"
XRAY_INSTALL_DIR="/usr/local/bin"
XRAY_CONFIG_DIR="/etc/xray"
XRAY_LOG_DIR="/var/log/xray"

# ── install xray ───────────────────────────────────────────────────────────────
header "Installing xray v${XRAY_VERSION}"

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip" ;;
  *)       XRAY_ARCHIVE="Xray-linux-64.zip" ;;
esac

XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ARCHIVE}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading $XRAY_ARCHIVE..."
curl -fsSL --retry 3 -o "$TMPDIR/xray.zip" "$XRAY_URL"
unzip -q "$TMPDIR/xray.zip" -d "$TMPDIR/xray-extract/"

install -m 755 "$TMPDIR/xray-extract/xray"          "$XRAY_INSTALL_DIR/xray"
install -m 755 "$TMPDIR/xray-extract/geoip.dat"     /usr/local/share/xray/geoip.dat 2>/dev/null || \
  install -D -m 644 "$TMPDIR/xray-extract/geoip.dat" /usr/local/share/xray/geoip.dat
install -D -m 644 "$TMPDIR/xray-extract/geosite.dat" /usr/local/share/xray/geosite.dat 2>/dev/null || true

info "xray installed: $("$XRAY_INSTALL_DIR/xray" version | head -1)"

# ── directories ────────────────────────────────────────────────────────────────
header "Creating directories"

mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
chown nobody:nogroup "$XRAY_LOG_DIR" "$XRAY_CONFIG_DIR"
chmod 750 "$XRAY_CONFIG_DIR"

# ── config.json ────────────────────────────────────────────────────────────────
header "Writing /etc/xray/config.json"

cat > "$XRAY_CONFIG_DIR/config.json" <<XRAY_EOF
{
  "log": {
    "loglevel": "warning",
    "error":  "${XRAY_LOG_DIR}/error.log",
    "access": "${XRAY_LOG_DIR}/access.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "listen": "127.0.0.1:10085",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": { "statsUserUplink": true, "statsUserDownlink": true }
    },
    "system": {
      "statsInboundUplink":   true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "listen":   "0.0.0.0",
      "port":     ${PROXY_XRAY_PORT},
      "protocol": "vless",
      "tag":      "vless-in",
      "settings": {
        "clients": [
          {
            "id":    "${PROXY_VLESS_UUID}",
            "email": "user",
            "flow":  "${PROXY_XRAY_FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network":  "tcp",
        "security": "reality",
        "realitySettings": {
          "show":        false,
          "dest":        "${PROXY_XRAY_DEST}",
          "xver":        0,
          "serverNames": ["${PROXY_XRAY_SNI}"],
          "privateKey":  "${PROXY_XRAY_PRIVATE_KEY}",
          "shortIds":    ["${PROXY_XRAY_SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled":     true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",   "tag": "direct" },
    { "protocol": "blackhole", "tag": "block"  }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type":       "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type":    "field",
        "ip":      ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
XRAY_EOF

chmod 640 "$XRAY_CONFIG_DIR/config.json"
chown root:nogroup "$XRAY_CONFIG_DIR/config.json"

# ── validate config ────────────────────────────────────────────────────────────
header "Validating config"
"$XRAY_INSTALL_DIR/xray" run -test -config "$XRAY_CONFIG_DIR/config.json" \
  || error "xray config validation failed"

# ── systemd service ────────────────────────────────────────────────────────────
header "Installing systemd service"

cat > /etc/systemd/system/xray.service <<'SVC_EOF'
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io
After=network.target nss-lookup.target

[Service]
User=nobody
Group=nogroup
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable --now xray

# ── firewall ───────────────────────────────────────────────────────────────────
header "Configuring firewall"

if command -v ufw &>/dev/null; then
  ufw allow "${PROXY_XRAY_PORT}/tcp" comment "xray VLESS" > /dev/null
  info "UFW: allowed ${PROXY_XRAY_PORT}/tcp"
else
  warn "ufw not found — open port ${PROXY_XRAY_PORT}/tcp manually"
fi

# ── status ─────────────────────────────────────────────────────────────────────
header "Done"
systemctl is-active --quiet xray && info "xray is running" || warn "xray is NOT running (check: journalctl -u xray)"

echo ""
info "Client connection details:"
echo "  Protocol:   VLESS + Reality"
echo "  Address:    $(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo "  Port:       ${PROXY_XRAY_PORT}"
echo "  UUID:       ${PROXY_VLESS_UUID}"
echo "  Flow:       ${PROXY_XRAY_FLOW}"
echo "  Security:   reality"
echo "  SNI:        ${PROXY_XRAY_SNI}"
echo "  Public key: ${PROXY_XRAY_PUBLIC_KEY}"
echo "  Short ID:   ${PROXY_XRAY_SHORT_ID}"
