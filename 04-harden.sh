#!/usr/bin/env bash
# Applies security hardening: sysctl, SSH config, fail2ban, unattended-upgrades.
# SSH access: key-only, no password, no root login.
# Does NOT lock out dynamic IPs — access is via SSH key from any IP.
# Requires: root
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}==> $*${NC}"; }

[[ $EUID -eq 0 ]] || error "Run as root (sudo $0)"

# ── safety: confirm SSH key is present ────────────────────────────────────────
header "SSH key safety check"

KEY_FOUND=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [[ -f "$f" ]] && grep -qE "^(ssh-|ecdsa-|sk-)" "$f" 2>/dev/null \
    && { info "SSH key found in $f"; KEY_FOUND=1; break; }
done

[[ $KEY_FOUND -eq 1 ]] \
  || error "No SSH authorized_keys found! Add your public key before running this script."

# ── disable unnecessary services ──────────────────────────────────────────────
header "Disabling unnecessary services"

for svc in rpcbind avahi-daemon cups bluetooth; do
  if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}"; then
    systemctl disable --now "$svc" 2>/dev/null && info "Disabled: $svc" || true
  fi
done

# ── sysctl hardening ──────────────────────────────────────────────────────────
header "Applying sysctl hardening"

cat > /etc/sysctl.d/99-hardening.conf <<'SYSCTL_EOF'
# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# No ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# No source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# No IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Ignore broadcast pings
net.ipv4.icmp_echo_ignore_broadcasts = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# No IP forwarding (standalone proxy, userspace-only)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0

# ASLR
kernel.randomize_va_space = 2

# Restrict core dumps
fs.suid_dumpable = 0

# Protect hardlinks and symlinks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Restrict /proc visibility
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# Restrict ptrace to child processes only
kernel.yama.ptrace_scope = 1

# Increase connection limits for proxy workloads
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
SYSCTL_EOF

sysctl -p /etc/sysctl.d/99-hardening.conf > /dev/null
info "sysctl rules applied"

# ── disable core dumps ────────────────────────────────────────────────────────
cat > /etc/security/limits.d/99-no-coredumps.conf <<'EOF'
* hard core 0
EOF

# ── SSH hardening ─────────────────────────────────────────────────────────────
header "Hardening SSH"

mkdir -p /etc/ssh/sshd_config.d

if ! grep -qE "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config 2>/dev/null; then
  echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
fi

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'SSH_EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding yes
# local port-forwarding is required for Grafana SSH tunnel (ssh -L 3000:localhost:3000)
AllowTcpForwarding local
X11Forwarding no
PrintMotd no
Banner /etc/issue.net
SSH_EOF

sshd -t || error "sshd config validation failed — check /etc/ssh/sshd_config.d/99-hardening.conf"

cat > /etc/issue.net <<'BANNER_EOF'
***************************************************************************
Unauthorized access to this system is prohibited.
All connections are monitored and logged.
***************************************************************************
BANNER_EOF

systemctl restart ssh 2>/dev/null || systemctl restart sshd
info "SSH hardened and restarted"

# ── fail2ban ──────────────────────────────────────────────────────────────────
header "Installing and configuring fail2ban"

apt-get install -f -y -qq   # fix any broken packages from prior runs
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local <<'F2B_EOF'
[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 5
backend   = systemd
# No whitelisted IPs — user connects from dynamic address

[sshd]
enabled = true
F2B_EOF

systemctl enable --now fail2ban
systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
info "fail2ban enabled (SSH jail: ban after 5 attempts / 10 min window)"

# ── unattended security upgrades ──────────────────────────────────────────────
header "Enabling automatic security updates"

apt-get install -y -qq unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT_EOF

DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "$VERSION_CODENAME"))

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<UNATT_EOF
Unattended-Upgrade::Allowed-Origins {
  "\${distro_id}:${DISTRO_CODENAME}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UNATT_EOF

info "Automatic security upgrades enabled (no auto-reboot)"

# ── /run/shm hardening ────────────────────────────────────────────────────────
if ! grep -q "tmpfs /run/shm" /etc/fstab 2>/dev/null; then
  echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
  mount -o remount /run/shm 2>/dev/null || true
fi

# ── secure file permissions ───────────────────────────────────────────────────
header "Setting secure file permissions"

chmod 600 /etc/crontab         2>/dev/null || true
chmod 600 /etc/ssh/sshd_config 2>/dev/null || true
chmod 700 /root                2>/dev/null || true

# ── ufw baseline ──────────────────────────────────────────────────────────────
header "Configuring UFW baseline"

if ! command -v ufw &>/dev/null; then
  apt-get install -y -qq ufw
fi

ufw allow 22/tcp comment "SSH" > /dev/null
ufw --force enable > /dev/null
info "UFW enabled. SSH (22/tcp) allowed."
warn "Ports 443 and 15001 are opened by 02-xray.sh and 03-mtproxy.sh respectively."

# ── done ──────────────────────────────────────────────────────────────────────
header "Hardening complete"
echo ""
info "Summary of changes:"
echo "  - sysctl: IP spoofing, ICMP, SYN flood, ASLR, ptrace, hardlink/symlink hardening"
echo "  - SSH:    key-only auth, no root, MaxAuthTries=3, local TCP forwarding only"
echo "  - fail2ban: SSH jail, ban 1h after 5 failed attempts"
echo "  - Auto-upgrades: security packages only, no auto-reboot"
echo "  - UFW: default-deny, SSH allowed"
