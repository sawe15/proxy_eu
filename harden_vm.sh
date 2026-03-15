#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

SSH_PORT="${SSH_PORT:-22}"
ALLOW_MTPROXY_PORTS="${ALLOW_MTPROXY_PORTS:-443 8888}"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y install \
  ufw fail2ban unattended-upgrades apt-listchanges curl ca-certificates

# SSH hardening
SSHD_CFG="/etc/ssh/sshd_config"
cp "$SSHD_CFG" "${SSHD_CFG}.bak.$(date +%F-%H%M%S)"
sed -ri 's/^#?PermitRootLogin\s+.*/PermitRootLogin no/' "$SSHD_CFG"
sed -ri 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' "$SSHD_CFG"
sed -ri 's/^#?KbdInteractiveAuthentication\s+.*/KbdInteractiveAuthentication no/' "$SSHD_CFG"
sed -ri 's/^#?X11Forwarding\s+.*/X11Forwarding no/' "$SSHD_CFG"
sed -ri 's/^#?MaxAuthTries\s+.*/MaxAuthTries 3/' "$SSHD_CFG"
if ! grep -q '^AllowTcpForwarding no' "$SSHD_CFG"; then
  echo 'AllowTcpForwarding no' >> "$SSHD_CFG"
fi
systemctl restart ssh || systemctl restart sshd

# fail2ban baseline
cat > /etc/fail2ban/jail.d/sshd.local <<JAIL
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
systemctl enable --now fail2ban

# unattended upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT

# sysctl hardening
cat > /etc/sysctl.d/99-hardening.conf <<'SYSCTL'
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
SYSCTL
sysctl --system >/dev/null

# Firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
for port in ${ALLOW_MTPROXY_PORTS}; do
  ufw allow "${port}/tcp"
done
ufw --force enable

systemctl enable unattended-upgrades

echo "Hardening complete."
echo "Open ports: SSH ${SSH_PORT}, MTProxy ${ALLOW_MTPROXY_PORTS}"
