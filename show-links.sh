#!/usr/bin/env bash
# Prints ready-to-import proxy connection links.
# Run from any user without sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/proxy.conf"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

[[ -f "$CONF_FILE" ]] || { echo "proxy.conf not found — run 01-secrets.sh first" >&2; exit 1; }
source "$CONF_FILE"

SERVER_IP=$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
  || hostname -I | awk '{print $1}')

# Wrap IPv6 addresses in brackets for URL usage
if [[ "$SERVER_IP" == *:* ]]; then
  HOST="[${SERVER_IP}]"
else
  HOST="$SERVER_IP"
fi

# ── VLESS URI ──────────────────────────────────────────────────────────────────
# format: vless://uuid@host:port?type=tcp&security=reality&pbk=...&fp=chrome&sni=...&sid=...&flow=...#label
VLESS_LINK="vless://${PROXY_VLESS_UUID}@${HOST}:${PROXY_XRAY_PORT}?type=tcp&security=reality&pbk=${PROXY_XRAY_PUBLIC_KEY}&fp=chrome&sni=${PROXY_XRAY_SNI}&sid=${PROXY_XRAY_SHORT_ID}&flow=${PROXY_XRAY_FLOW}#proxy-eu"

# ── MTProxy links ──────────────────────────────────────────────────────────────
MTG_TG_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_MTG_PORT}&secret=${PROXY_MTG_SECRET}"
MTG_HTTPS_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_MTG_PORT}&secret=${PROXY_MTG_SECRET}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  VLESS + Reality${NC}  (port ${PROXY_XRAY_PORT}, SNI ${PROXY_XRAY_SNI})"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${VLESS_LINK}${NC}"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  MTProxy / Telegram${NC}  (port ${PROXY_MTG_PORT})"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${MTG_TG_LINK}${NC}"
echo ""
echo -e "${YELLOW}${MTG_HTTPS_LINK}${NC}"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Grafana${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  ssh -L 3000:localhost:3000 ${SUDO_USER:-sawe}@${SERVER_IP}"
echo "  → http://localhost:3000  (admin / ${PROXY_MONITORING_GRAFANA_PASSWORD})"
echo ""
