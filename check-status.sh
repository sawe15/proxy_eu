#!/usr/bin/env bash
# Health check: services, ports, firewall, fail2ban.
# Run without sudo (sudo needed only for fail2ban stats).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/proxy.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }

[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# ── systemd services ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Systemd services ─────────────────────────────────${NC}"

SERVICES=(xray docker fail2ban node_exporter victoriametrics vmagent vmalert alertmanager grafana-server)
ALL_OK=1
for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "$svc"
  else
    STATE=$(systemctl is-active "$svc" 2>/dev/null || true)
    fail "$svc  (${STATE:-unknown})  → journalctl -u $svc -n 20"
    ALL_OK=0
  fi
done

# ── docker containers ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Docker containers ────────────────────────────────${NC}"

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  if docker inspect mtg --format='{{.State.Running}}' 2>/dev/null | grep -q "^true$"; then
    RESTARTS=$(docker inspect mtg --format='{{.RestartCount}}' 2>/dev/null || echo "?")
    ok "mtg  (restarts: ${RESTARTS})"
  else
    fail "mtg container is not running  → docker logs mtg"
    ALL_OK=0
  fi
else
  warn "Docker not available or not running"
fi

# ── ports ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Listening ports ──────────────────────────────────${NC}"

check_port() {
  local port="$1" label="$2"
  if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]" || \
     ss -tlnp 2>/dev/null | grep -q ":${port}$"; then
    ok "port ${port}/tcp  (${label})"
  else
    fail "port ${port}/tcp  (${label}) — not listening"
    ALL_OK=0
  fi
}

check_port "${PROXY_XRAY_PORT:-443}"  "xray VLESS"
check_port "${PROXY_MTG_PORT:-15001}" "MTProxy"

# monitoring ports (localhost only — expected)
for p in 9100 8428 8429 8880 9093 3000; do
  LABEL=""
  case $p in
    9100) LABEL="node_exporter" ;;
    8428) LABEL="victoriametrics" ;;
    8429) LABEL="vmagent" ;;
    8880) LABEL="vmalert" ;;
    9093) LABEL="alertmanager" ;;
    3000) LABEL="grafana" ;;
  esac
  if ss -tlnp 2>/dev/null | grep -qE "127\.0\.0\.1:${p}[[:space:]]|127\.0\.0\.1:${p}$|\[::1\]:${p}"; then
    ok "127.0.0.1:${p}  (${LABEL})"
  else
    fail "127.0.0.1:${p}  (${LABEL}) — not listening"
    ALL_OK=0
  fi
done

# ── UFW firewall ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Firewall (UFW) ───────────────────────────────────${NC}"

# ufw lives in /usr/sbin which is not in a regular user's PATH on Debian
UFW_BIN=$(command -v ufw 2>/dev/null || { [[ -x /usr/sbin/ufw ]] && echo /usr/sbin/ufw; } || true)

if [[ -n "$UFW_BIN" ]]; then
  UFW_STATUS=$(sudo "$UFW_BIN" status 2>/dev/null | head -1 || "$UFW_BIN" status 2>/dev/null | head -1 || true)
  if echo "$UFW_STATUS" | grep -q "active"; then
    ok "UFW active"
    sudo "$UFW_BIN" status 2>/dev/null | grep -E "ALLOW|DENY" | sed 's/^/      /' || true
  else
    warn "UFW installed but inactive"
  fi
else
  warn "ufw not installed"
fi

# ── fail2ban ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── fail2ban ─────────────────────────────────────────${NC}"

if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
  BANNED=$(fail2ban-client status sshd 2>/dev/null \
    | grep "Currently banned" | awk '{print $NF}' || echo "?")
  ok "fail2ban active  (SSH banned IPs: ${BANNED})"
else
  fail "fail2ban not running"
  ALL_OK=0
fi

# ── textfile collectors ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Textfile collectors ──────────────────────────────${NC}"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
for f in mtg.prom fail2ban.prom; do
  fpath="$TEXTFILE_DIR/$f"
  if [[ -f "$fpath" ]]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$fpath" 2>/dev/null || echo 0) ))
    PERM=$(stat -c %a "$fpath" 2>/dev/null || echo "?")
    if [[ $AGE -gt 180 ]]; then
      warn "$f  (last updated ${AGE}s ago — stale; check timer)"
    elif [[ "$PERM" == "600" ]]; then
      fail "$f  (perms 600 — node_exporter can't read it; re-run 05-monitoring.sh)"
      ALL_OK=0
    else
      ok "$f  (${AGE}s ago, perms ${PERM})"
    fi
  else
    fail "$f  missing — collector not running"
    ALL_OK=0
  fi
done

for timer in mtg-metrics fail2ban-metrics; do
  if systemctl is-active --quiet "${timer}.timer" 2>/dev/null; then
    ok "${timer}.timer"
  else
    warn "${timer}.timer not active  → systemctl enable --now ${timer}.timer"
  fi
done

# ── xray journalctl tail ──────────────────────────────────────────────────────
if ! systemctl is-active --quiet xray 2>/dev/null; then
  echo ""
  echo -e "${BOLD}── xray last log lines ──────────────────────────────${NC}"
  journalctl -u xray -n 10 --no-pager 2>/dev/null | sed 's/^/  /' || true
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
if [[ $ALL_OK -eq 1 ]]; then
  echo -e "  ${GREEN}${BOLD}All checks passed${NC}"
else
  echo -e "  ${RED}${BOLD}Some checks failed — see above${NC}"
fi
echo ""
