#!/usr/bin/env bash
# Master installer for a standalone proxy.
# Runs all setup scripts in order.
# Usage: sudo ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}╔══════════════════════════════════════════╗"; \
           printf "${BOLD}║  %-42s║${NC}\n" "$*"; \
           echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"; }

[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

for script in 01-secrets.sh 02-xray.sh 03-mtproxy.sh 04-harden.sh 05-monitoring.sh; do
  [[ -f "$SCRIPT_DIR/$script" ]] || error "Script not found: $SCRIPT_DIR/$script"
  chmod +x "$SCRIPT_DIR/$script"
done

# ── step 1: secrets ────────────────────────────────────────────────────────────
header "Step 1 / 5 — Generate secrets"
bash "$SCRIPT_DIR/01-secrets.sh"

# ── step 2: xray ──────────────────────────────────────────────────────────────
header "Step 2 / 5 — Install xray (VLESS+Reality, port 443)"
bash "$SCRIPT_DIR/02-xray.sh"

# ── step 3: mtproxy ───────────────────────────────────────────────────────────
header "Step 3 / 5 — Install MTProxy (port 15001)"
bash "$SCRIPT_DIR/03-mtproxy.sh"

# ── step 4: hardening ─────────────────────────────────────────────────────────
header "Step 4 / 5 — Apply hardening"
bash "$SCRIPT_DIR/04-harden.sh"

# ── step 5: monitoring ────────────────────────────────────────────────────────
header "Step 5 / 5 — Deploy monitoring stack"

CONF_FILE="$SCRIPT_DIR/proxy.conf"
# shellcheck source=proxy.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

if [[ -z "${PROXY_MONITORING_TG_BOT_TOKEN:-}" ]]; then
  warn "Telegram bot token not set."
  warn "Edit proxy.conf (PROXY_MONITORING_TG_BOT_TOKEN + PROXY_MONITORING_TG_CHAT_ID)"
  read -r -p "Continue monitoring install anyway? [y/N] " REPLY
  [[ "${REPLY,,}" == "y" ]] || { warn "Skipping monitoring. Run 05-monitoring.sh manually later."; exit 0; }
fi

bash "$SCRIPT_DIR/05-monitoring.sh"

# ── summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Installation complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
SERVER_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
  || hostname -I | awk '{print $1}')

echo -e "${BOLD}VLESS connection:${NC}"
echo "  Address:    $SERVER_IP"
echo "  Port:       ${PROXY_XRAY_PORT:-443}"
echo "  UUID:       ${PROXY_VLESS_UUID:-<see proxy.conf>}"
echo "  Flow:       ${PROXY_XRAY_FLOW:-xtls-rprx-vision}"
echo "  Security:   reality"
echo "  SNI:        ${PROXY_XRAY_SNI:-www.cloudflare.com}"
echo "  Public key: ${PROXY_XRAY_PUBLIC_KEY:-<see proxy.conf>}"
echo "  Short ID:   ${PROXY_XRAY_SHORT_ID:-<see proxy.conf>}"
echo ""
echo -e "${BOLD}MTProxy link:${NC}"
echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_MTG_PORT:-15001}&secret=${PROXY_MTG_SECRET:-<see proxy.conf>}"
echo ""
echo -e "${BOLD}Grafana:${NC}"
echo "  ssh -L 3000:localhost:3000 user@${SERVER_IP}"
echo "  → http://localhost:3000  (admin / ${PROXY_MONITORING_GRAFANA_PASSWORD:-<see proxy.conf>})"
echo ""
info "All secrets are in proxy.conf — keep it safe."
