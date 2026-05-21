#!/usr/bin/env bash
# Generates all secrets for a standalone proxy and writes proxy.conf
# Run once on the machine that will host the proxy (or locally).
# Requires: curl, unzip, openssl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/proxy.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}==> $*${NC}"; }

# ── prereqs ────────────────────────────────────────────────────────────────────
for cmd in curl unzip openssl; do
  command -v "$cmd" &>/dev/null || error "Required command not found: $cmd"
done

if [[ -f "$CONF_FILE" ]]; then
  warn "proxy.conf already exists at $CONF_FILE"
  read -r -p "Overwrite? [y/N] " REPLY
  [[ "${REPLY,,}" == "y" ]] || { info "Aborted."; exit 0; }
fi

# ── download xray for x25519 keygen ────────────────────────────────────────────
header "Downloading xray for key generation"

XRAY_VERSION="1.8.24"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip" ;;
  *)       XRAY_ARCHIVE="Xray-linux-64.zip" ;;
esac

XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ARCHIVE}"
info "Fetching $XRAY_URL"
curl -fsSL --retry 3 -o "$TMPDIR/xray.zip" "$XRAY_URL"
unzip -q "$TMPDIR/xray.zip" xray -d "$TMPDIR/"
chmod +x "$TMPDIR/xray"

# ── generate secrets ────────────────────────────────────────────────────────────
header "Generating secrets"

KEYPAIR=$("$TMPDIR/xray" x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/Private key/{print $NF}')
PUBLIC_KEY=$(echo "$KEYPAIR"  | awk '/Public key/{print $NF}')
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || error "Failed to generate X25519 keypair"

VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
MTG_SECRET="ee$(openssl rand -hex 16)"
GRAFANA_PASS=$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 20)

info "UUID:        $VLESS_UUID"
info "Public key:  $PUBLIC_KEY"
info "Short ID:    $SHORT_ID"
info "MTG secret:  $MTG_SECRET"

# ── write proxy.conf ────────────────────────────────────────────────────────────
header "Writing proxy.conf"

cat > "$CONF_FILE" <<EOF
# Standalone proxy configuration — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# chmod 600 this file; never commit it to git.

# ── VLESS / xray ───────────────────────────────────────────────────────────────
PROXY_VLESS_UUID="${VLESS_UUID}"
PROXY_XRAY_PRIVATE_KEY="${PRIVATE_KEY}"
PROXY_XRAY_PUBLIC_KEY="${PUBLIC_KEY}"
PROXY_XRAY_SHORT_ID="${SHORT_ID}"
PROXY_XRAY_PORT=443
PROXY_XRAY_SNI="www.cloudflare.com"
PROXY_XRAY_DEST="www.cloudflare.com:443"
PROXY_XRAY_FLOW="xtls-rprx-vision"

# ── MTProxy ────────────────────────────────────────────────────────────────────
PROXY_MTG_SECRET="${MTG_SECRET}"
PROXY_MTG_PORT=15001

# ── Monitoring ─────────────────────────────────────────────────────────────────
PROXY_MONITORING_GRAFANA_PASSWORD="${GRAFANA_PASS}"
# Fill in before running 05-monitoring.sh:
PROXY_MONITORING_TG_BOT_TOKEN=""
PROXY_MONITORING_TG_CHAT_ID=""
EOF

chmod 600 "$CONF_FILE"

echo ""
info "proxy.conf written to $CONF_FILE"
echo ""
warn "Before running 05-monitoring.sh, edit proxy.conf and set:"
warn "  PROXY_MONITORING_TG_BOT_TOKEN — from @BotFather"
warn "  PROXY_MONITORING_TG_CHAT_ID   — numeric ID of the target chat/channel"
