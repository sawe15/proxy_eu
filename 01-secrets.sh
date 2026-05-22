#!/usr/bin/env bash
# Generates all secrets for a standalone proxy and writes proxy.conf.
# Run once on the machine that will host the proxy (or locally).
# Usage: ./01-secrets.sh [-r|--regenerate]
# Requires: curl, unzip, openssl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/proxy.conf"
GITIGNORE="$SCRIPT_DIR/.gitignore"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}==> $*${NC}"; }

FORCE_REGEN=0
for arg in "$@"; do
  case "$arg" in
    -r|--regenerate) FORCE_REGEN=1 ;;
    *) error "Unknown option: $arg. Usage: $0 [-r|--regenerate]" ;;
  esac
done

# ── prereqs ────────────────────────────────────────────────────────────────────
for cmd in curl unzip openssl; do
  command -v "$cmd" &>/dev/null || error "Required command not found: $cmd"
done

# ensure proxy.conf is gitignored before we write it
if [[ -f "$GITIGNORE" ]]; then
  grep -qxF "proxy.conf" "$GITIGNORE" || echo "proxy.conf" >> "$GITIGNORE"
else
  echo "proxy.conf" > "$GITIGNORE"
fi

# ── validate existing secrets ──────────────────────────────────────────────────
# Returns true if the value matches the given regex
valid() { [[ "${1:-}" =~ $2 ]]; }

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
B64_RE='^[A-Za-z0-9+/=_-]{40,}$'   # X25519 keys are ~43 base64url chars
HEX8_RE='^[0-9a-f]{16}$'           # SHORT_ID: 8 bytes = 16 hex chars
# ee + 16 random bytes (32 hex) + hex(www.cloudflare.com) — key MUST come before hostname
MTG_SNI_HEX_STATIC=$(printf '%s' "www.cloudflare.com" | od -An -tx1 | tr -d ' \n')
MTG_RE="^ee[0-9a-f]{32}${MTG_SNI_HEX_STATIC}$"
PASS_RE='^.{8,}$'

if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=proxy.conf
  source "$CONF_FILE"

  INVALID=()
  valid "${PROXY_VLESS_UUID:-}"             "$UUID_RE" || INVALID+=("PROXY_VLESS_UUID")
  valid "${PROXY_XRAY_PRIVATE_KEY:-}"       "$B64_RE"  || INVALID+=("PROXY_XRAY_PRIVATE_KEY")
  valid "${PROXY_XRAY_PUBLIC_KEY:-}"        "$B64_RE"  || INVALID+=("PROXY_XRAY_PUBLIC_KEY")
  valid "${PROXY_XRAY_SHORT_ID:-}"          "$HEX8_RE" || INVALID+=("PROXY_XRAY_SHORT_ID")
  valid "${PROXY_MTG_SECRET:-}"             "$MTG_RE"  || INVALID+=("PROXY_MTG_SECRET")
  valid "${PROXY_MONITORING_GRAFANA_PASSWORD:-}" "$PASS_RE" || INVALID+=("PROXY_MONITORING_GRAFANA_PASSWORD")

  if [[ ${#INVALID[@]} -eq 0 && $FORCE_REGEN -eq 0 ]]; then
    info "proxy.conf exists and all secrets are valid — nothing to do."
    info "  UUID:        ${PROXY_VLESS_UUID}"
    info "  Public key:  ${PROXY_XRAY_PUBLIC_KEY}"
    info "  Short ID:    ${PROXY_XRAY_SHORT_ID}"
    info "  MTG secret:  ${PROXY_MTG_SECRET}"
    exit 0
  fi

  if [[ ${#INVALID[@]} -gt 0 ]]; then
    warn "proxy.conf exists but the following secrets are missing or invalid:"
    for field in "${INVALID[@]}"; do
      warn "  - $field"
    done
    echo ""
  fi

  if [[ $FORCE_REGEN -eq 1 ]]; then
    warn "Force-regenerating all secrets (--regenerate flag)."
  else
    read -r -p "Regenerate all secrets? [y/N] " REPLY
    [[ "${REPLY,,}" == "y" ]] || { info "Aborted."; exit 0; }
  fi

  # preserve Telegram credentials across regeneration
  TG_BOT_TOKEN_SAVED="${PROXY_MONITORING_TG_BOT_TOKEN:-}"
  TG_CHAT_ID_SAVED="${PROXY_MONITORING_TG_CHAT_ID:-}"
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
# mtg v2 ee-secret format: 0xEE + 16 random bytes (hex) + hex(hostname)
MTG_SNI="www.cloudflare.com"
MTG_SNI_HEX=$(printf '%s' "$MTG_SNI" | od -An -tx1 | tr -d ' \n')
MTG_SECRET="ee$(openssl rand -hex 16)${MTG_SNI_HEX}"
GRAFANA_PASS=$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 20)

info "UUID:        $VLESS_UUID"
info "Public key:  $PUBLIC_KEY"
info "Short ID:    $SHORT_ID"
info "MTG secret:  $MTG_SECRET (SNI: $MTG_SNI)"

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
PROXY_MTG_SNI="${MTG_SNI}"
PROXY_MTG_PORT=15001

# ── Monitoring ─────────────────────────────────────────────────────────────────
PROXY_MONITORING_GRAFANA_PASSWORD="${GRAFANA_PASS}"
# Fill in before running 05-monitoring.sh:
PROXY_MONITORING_TG_BOT_TOKEN="${TG_BOT_TOKEN_SAVED:-}"
PROXY_MONITORING_TG_CHAT_ID="${TG_CHAT_ID_SAVED:-}"
EOF

chmod 600 "$CONF_FILE"
# give ownership to the invoking user so they can edit without sudo
if [[ -n "${SUDO_USER:-}" ]]; then
  chown "$SUDO_USER" "$CONF_FILE"
fi

echo ""
info "proxy.conf written to $CONF_FILE (mode 600, owner: ${SUDO_USER:-root})"
echo ""
warn "Before running 05-monitoring.sh, edit proxy.conf and set:"
warn "  PROXY_MONITORING_TG_BOT_TOKEN — from @BotFather"
warn "  PROXY_MONITORING_TG_CHAT_ID   — numeric ID of the target chat/channel"
