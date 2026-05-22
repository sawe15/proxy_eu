#!/usr/bin/env bash
# Deploys a full monitoring stack on the proxy itself:
#   node_exporter → VictoriaMetrics ← vmagent
#                                    ← vmalert → alertmanager → Telegram
#   Grafana (port 3000, access via ssh -L 3000:localhost:3000)
#   Textfile collectors: mtg container health, xray service, fail2ban stats
# Requires: proxy.conf, root, Docker (for mtg health check)
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

if [[ -z "${PROXY_MONITORING_TG_BOT_TOKEN:-}" || -z "${PROXY_MONITORING_TG_CHAT_ID:-}" ]]; then
  warn "PROXY_MONITORING_TG_BOT_TOKEN or PROXY_MONITORING_TG_CHAT_ID not set in proxy.conf"
  warn "Telegram alerting will NOT work until you set them and restart alertmanager."
fi

# ── versions & ports ──────────────────────────────────────────────────────────
NODE_EXPORTER_VERSION="1.9.0"
VM_VERSION="1.115.0"
ALERTMANAGER_VERSION="0.28.1"
GRAFANA_VERSION="11.5.2"

PORT_NODE_EXPORTER=9100
PORT_VM=8428
PORT_VMAGENT=8429
PORT_VMALERT=8880
PORT_ALERTMANAGER=9093
PORT_GRAFANA=3000

MONITORING_CONFIG_DIR="/etc/monitoring"
MONITORING_RULES_DIR="$MONITORING_CONFIG_DIR/rules"
MONITORING_INSTALL_DIR="/usr/local/bin"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
VM_DATA_DIR="/var/lib/victoriametrics"
GRAFANA_DASHBOARD_DIR="/var/lib/grafana/dashboards"

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) DL_ARCH="arm64" ;;
  *)       DL_ARCH="amd64" ;;
esac

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$MONITORING_CONFIG_DIR" "$MONITORING_RULES_DIR" "$TEXTFILE_DIR" \
         "$VM_DATA_DIR" "$GRAFANA_DASHBOARD_DIR"

# ── helper: install binary from tar.gz ────────────────────────────────────────
install_binary() {
  local url="$1" archive="$2" binary="$3" dest="$4"
  if [[ -f "$dest" ]]; then
    info "$(basename "$dest") already installed — skipping download"
    return 0
  fi
  info "Downloading $(basename "$archive")..."
  curl -fsSL --retry 3 -o "$WORK_DIR/$archive" "$url"
  tar -xzf "$WORK_DIR/$archive" -C "$WORK_DIR/"
  local src
  src=$(find "$TMPDIR" -name "$binary" -type f | head -1)
  [[ -n "$src" ]] || error "Binary '$binary' not found in archive"
  install -m 755 "$src" "$dest"
  info "Installed: $dest"
}

# ── node_exporter ─────────────────────────────────────────────────────────────
header "Installing node_exporter v${NODE_EXPORTER_VERSION}"

NE_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${DL_ARCH}.tar.gz"
NE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NE_ARCHIVE}"
install_binary "$NE_URL" "$NE_ARCHIVE" "node_exporter" "$MONITORING_INSTALL_DIR/node_exporter"

id -u node_exporter &>/dev/null || useradd -rs /bin/false node_exporter
chown node_exporter:node_exporter "$TEXTFILE_DIR"

cat > /etc/systemd/system/node_exporter.service <<NE_SVC
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=${MONITORING_INSTALL_DIR}/node_exporter \\
  --web.listen-address=127.0.0.1:${PORT_NODE_EXPORTER} \\
  --collector.systemd \\
  --collector.processes \\
  --collector.textfile.directory=${TEXTFILE_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
NE_SVC

systemctl daemon-reload
systemctl enable --now node_exporter
info "node_exporter started on 127.0.0.1:${PORT_NODE_EXPORTER}"

# ── VictoriaMetrics ───────────────────────────────────────────────────────────
header "Installing VictoriaMetrics v${VM_VERSION}"

VM_ARCHIVE="victoria-metrics-linux-${DL_ARCH}-v${VM_VERSION}.tar.gz"
VM_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VM_VERSION}/${VM_ARCHIVE}"
install_binary "$VM_URL" "$VM_ARCHIVE" "victoria-metrics-prod" \
  "$MONITORING_INSTALL_DIR/victoria-metrics-prod"

cat > /etc/systemd/system/victoriametrics.service <<VM_SVC
[Unit]
Description=VictoriaMetrics
After=network.target

[Service]
ExecStart=${MONITORING_INSTALL_DIR}/victoria-metrics-prod \\
  -storageDataPath=${VM_DATA_DIR} \\
  -httpListenAddr=127.0.0.1:${PORT_VM} \\
  -retentionPeriod=30d
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
VM_SVC

systemctl daemon-reload
systemctl enable --now victoriametrics
info "VictoriaMetrics started on 127.0.0.1:${PORT_VM}"

# ── vmutils bundle (vmagent + vmalert) ────────────────────────────────────────
header "Installing vmagent + vmalert v${VM_VERSION}"

VMU_ARCHIVE="vmutils-linux-${DL_ARCH}-v${VM_VERSION}.tar.gz"
VMU_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VM_VERSION}/${VMU_ARCHIVE}"

if [[ ! -f "$MONITORING_INSTALL_DIR/vmagent-prod" || ! -f "$MONITORING_INSTALL_DIR/vmalert-prod" ]]; then
  info "Downloading $VMU_ARCHIVE..."
  curl -fsSL --retry 3 -o "$WORK_DIR/$VMU_ARCHIVE" "$VMU_URL"
  tar -xzf "$WORK_DIR/$VMU_ARCHIVE" -C "$WORK_DIR/"
  install -m 755 "$WORK_DIR/vmagent-prod" "$MONITORING_INSTALL_DIR/vmagent-prod"
  install -m 755 "$WORK_DIR/vmalert-prod" "$MONITORING_INSTALL_DIR/vmalert-prod"
  info "Installed vmagent-prod and vmalert-prod"
else
  info "vmagent-prod and vmalert-prod already installed"
fi

# ── vmagent config ────────────────────────────────────────────────────────────
cat > "$MONITORING_CONFIG_DIR/vmagent.yaml" <<VMAGENT_EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: node_exporter
    static_configs:
      - targets: ['127.0.0.1:${PORT_NODE_EXPORTER}']

  - job_name: victoriametrics
    static_configs:
      - targets: ['127.0.0.1:${PORT_VM}']

  - job_name: vmagent
    static_configs:
      - targets: ['127.0.0.1:${PORT_VMAGENT}']

  - job_name: vmalert
    static_configs:
      - targets: ['127.0.0.1:${PORT_VMALERT}']
VMAGENT_EOF

cat > /etc/systemd/system/vmagent.service <<VMAGENT_SVC
[Unit]
Description=vmagent
After=network.target victoriametrics.service

[Service]
ExecStart=${MONITORING_INSTALL_DIR}/vmagent-prod \\
  -promscrape.config=${MONITORING_CONFIG_DIR}/vmagent.yaml \\
  -remoteWrite.url=http://127.0.0.1:${PORT_VM}/api/v1/write \\
  -httpListenAddr=127.0.0.1:${PORT_VMAGENT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
VMAGENT_SVC

systemctl daemon-reload
systemctl enable --now vmagent

# ── vmalert rules ─────────────────────────────────────────────────────────────
cat > "$MONITORING_RULES_DIR/alerts.yaml" <<'RULES_EOF'
groups:
  - name: proxy.infra
    interval: 60s
    rules:
      - alert: HostHighCPU
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}%"

      - alert: HostHighMemory
        expr: 100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}%"

      - alert: DiskAlmostFull
        expr: 100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="rootfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="rootfs"}) > 85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk >85% on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}%"

      - alert: HostRebooted
        expr: (node_time_seconds - node_boot_time_seconds) < 300
        for: 0m
        labels:
          severity: info
        annotations:
          summary: "Host {{ $labels.instance }} was rebooted"

  - name: proxy.services
    interval: 30s
    rules:
      - alert: XrayDown
        expr: node_systemd_unit_state{name="xray.service",state="active"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "xray.service is DOWN on {{ $labels.instance }}"

      - alert: DockerDown
        expr: node_systemd_unit_state{name="docker.service",state="active"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "docker.service is DOWN on {{ $labels.instance }}"

      - alert: MTGContainerDown
        expr: mtg_container_running == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MTProxy container is not running"

      - alert: Fail2banDown
        expr: node_systemd_unit_state{name="fail2ban.service",state="active"} == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "fail2ban is DOWN — brute-force protection inactive"

  - name: proxy.monitoring
    interval: 60s
    rules:
      - alert: VmagentRemoteWriteErrors
        expr: rate(vmagent_remotewrite_retries_count_total[5m]) > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "vmagent remote write errors (VictoriaMetrics unreachable?)"
RULES_EOF

cat > /etc/systemd/system/vmalert.service <<VMALERT_SVC
[Unit]
Description=vmalert
After=network.target victoriametrics.service

[Service]
ExecStart=${MONITORING_INSTALL_DIR}/vmalert-prod \\
  -rule=${MONITORING_RULES_DIR}/alerts.yaml \\
  -datasource.url=http://127.0.0.1:${PORT_VM} \\
  -remoteWrite.url=http://127.0.0.1:${PORT_VM}/api/v1/write \\
  -notifier.url=http://127.0.0.1:${PORT_ALERTMANAGER} \\
  -httpListenAddr=127.0.0.1:${PORT_VMALERT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
VMALERT_SVC

systemctl daemon-reload
systemctl enable --now vmalert

# ── alertmanager ──────────────────────────────────────────────────────────────
header "Installing alertmanager v${ALERTMANAGER_VERSION}"

AM_ARCHIVE="alertmanager-${ALERTMANAGER_VERSION}.linux-${DL_ARCH}.tar.gz"
AM_URL="https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/${AM_ARCHIVE}"
install_binary "$AM_URL" "$AM_ARCHIVE" "alertmanager" "$MONITORING_INSTALL_DIR/alertmanager"

TG_BOT_TOKEN="${PROXY_MONITORING_TG_BOT_TOKEN:-FILL_IN_BOT_TOKEN}"
TG_CHAT_ID="${PROXY_MONITORING_TG_CHAT_ID:-0}"

cat > "$MONITORING_CONFIG_DIR/alertmanager.yaml" <<AM_EOF
global:
  resolve_timeout: 5m

route:
  receiver: telegram
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  group_by: [alertname, severity]

receivers:
  - name: telegram
    telegram_configs:
      - bot_token: "${TG_BOT_TOKEN}"
        chat_id: ${TG_CHAT_ID}
        parse_mode: HTML
        message: |
          {{ range .Alerts -}}
          <b>[{{ .Status | toUpper }}]</b> {{ .Labels.alertname }}
          Severity: {{ .Labels.severity }}
          {{ .Annotations.summary }}
          {{ end -}}
AM_EOF

chmod 600 "$MONITORING_CONFIG_DIR/alertmanager.yaml"

cat > /etc/systemd/system/alertmanager.service <<AM_SVC
[Unit]
Description=Alertmanager
After=network.target

[Service]
ExecStart=${MONITORING_INSTALL_DIR}/alertmanager \\
  --config.file=${MONITORING_CONFIG_DIR}/alertmanager.yaml \\
  --web.listen-address=127.0.0.1:${PORT_ALERTMANAGER} \\
  --storage.path=/var/lib/alertmanager
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
AM_SVC

mkdir -p /var/lib/alertmanager
systemctl daemon-reload
systemctl enable --now alertmanager

# ── Grafana ───────────────────────────────────────────────────────────────────
header "Installing Grafana v${GRAFANA_VERSION}"

apt-get install -f -y -qq   # fix any broken packages from prior runs
if ! dpkg -l grafana 2>/dev/null | grep -q '^ii'; then
  GRAFANA_DEB="grafana_${GRAFANA_VERSION}_${DL_ARCH}.deb"
  GRAFANA_URL="https://dl.grafana.com/oss/release/${GRAFANA_DEB}"
  info "Downloading $GRAFANA_DEB..."
  curl -fsSL --retry 3 -o "$WORK_DIR/$GRAFANA_DEB" "$GRAFANA_URL"
  apt-get install -y -qq "$WORK_DIR/$GRAFANA_DEB"
else
  info "Grafana already installed"
fi

GRAFANA_PASS="${PROXY_MONITORING_GRAFANA_PASSWORD:-admin}"

cat > /etc/grafana/grafana.ini <<GRAFANA_INI
[server]
http_addr = 127.0.0.1
http_port = ${PORT_GRAFANA}
domain    = localhost

[security]
admin_user     = admin
admin_password = ${GRAFANA_PASS}
disable_gravatar = true
cookie_secure = false

[users]
allow_sign_up = false

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled        = false
check_for_updates        = false
check_for_plugin_updates = false

[log]
mode  = console
level = warn
GRAFANA_INI

# datasource provisioning — fixed uid so dashboard panels can reference it
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/victoriametrics.yaml <<DS_EOF
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    uid: victoriametrics
    type: prometheus
    access: proxy
    url: http://127.0.0.1:${PORT_VM}
    isDefault: true
    editable: false
DS_EOF

# dashboard provisioning
mkdir -p /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/dashboards/proxy.yaml <<PROV_EOF
apiVersion: 1
providers:
  - name: proxy
    folder: Proxy
    type: file
    options:
      path: ${GRAFANA_DASHBOARD_DIR}
PROV_EOF

# ── Grafana dashboard JSON ────────────────────────────────────────────────────
cat > "$GRAFANA_DASHBOARD_DIR/proxy-overview.json" <<'DASH_EOF'
{
  "title": "Proxy Overview",
  "uid": "proxy-standalone",
  "schemaVersion": 38,
  "refresh": "30s",
  "time": {"from": "now-3h", "to": "now"},
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "CPU %",
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 70},
              {"color": "red", "value": 85}
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "CPU",
          "refId": "A"
        }
      ]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Memory %",
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 75},
              {"color": "red", "value": 90}
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)",
          "legendFormat": "Memory",
          "refId": "A"
        }
      ]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "Disk %",
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "yellow", "value": 70},
              {"color": "red", "value": 85}
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\",fstype!=\"rootfs\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!=\"rootfs\"})",
          "legendFormat": "Disk /",
          "refId": "A"
        }
      ]
    },
    {
      "id": 4,
      "type": "stat",
      "title": "Uptime",
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "dtdurations",
          "color": {"mode": "fixed", "fixedColor": "blue"},
          "thresholds": {
            "mode": "absolute",
            "steps": [{"color": "blue", "value": null}]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "node_time_seconds - node_boot_time_seconds",
          "legendFormat": "Uptime",
          "refId": "A"
        }
      ]
    },
    {
      "id": 5,
      "type": "stat",
      "title": "xray",
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 4},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "red", "value": null},
              {"color": "green", "value": 1}
            ]
          },
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {"text": "DOWN", "color": "red", "index": 0},
                "1": {"text": "UP",   "color": "green", "index": 1}
              }
            }
          ]
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "node_systemd_unit_state{name=\"xray.service\",state=\"active\"}",
          "legendFormat": "xray",
          "refId": "A"
        }
      ]
    },
    {
      "id": 6,
      "type": "stat",
      "title": "MTProxy",
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 4},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "red", "value": null},
              {"color": "green", "value": 1}
            ]
          },
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {"text": "DOWN", "color": "red",   "index": 0},
                "1": {"text": "UP",   "color": "green", "index": 1}
              }
            }
          ]
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "mtg_container_running",
          "legendFormat": "mtg",
          "refId": "A"
        }
      ]
    },
    {
      "id": 7,
      "type": "stat",
      "title": "fail2ban",
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 4},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "red", "value": null},
              {"color": "green", "value": 1}
            ]
          },
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {"text": "DOWN", "color": "red",   "index": 0},
                "1": {"text": "UP",   "color": "green", "index": 1}
              }
            }
          ]
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "node_systemd_unit_state{name=\"fail2ban.service\",state=\"active\"}",
          "legendFormat": "fail2ban",
          "refId": "A"
        }
      ]
    },
    {
      "id": 8,
      "type": "stat",
      "title": "Banned IPs (SSH)",
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 4},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "reduceOptions": {"values": false, "calcs": ["lastNotNull"], "fields": ""},
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "none",
        "justifyMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": null},
              {"color": "orange", "value": 5},
              {"color": "red",    "value": 20}
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "fail2ban_banned_ips{jail=\"sshd\"}",
          "legendFormat": "Banned",
          "refId": "A"
        }
      ]
    },
    {
      "id": 9,
      "type": "timeseries",
      "title": "Network Traffic",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "tooltip": {"mode": "multi", "sort": "none"},
        "legend":  {"displayMode": "list", "placement": "bottom"}
      },
      "fieldConfig": {
        "defaults": {
          "unit": "Bps",
          "color": {"mode": "palette-classic"}
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "rate(node_network_receive_bytes_total{device!=\"lo\"}[5m])",
          "legendFormat": "RX {{device}}",
          "refId": "A"
        },
        {
          "expr": "rate(node_network_transmit_bytes_total{device!=\"lo\"}[5m])",
          "legendFormat": "TX {{device}}",
          "refId": "B"
        }
      ]
    },
    {
      "id": 10,
      "type": "timeseries",
      "title": "CPU over time",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
      "datasource": {"type": "prometheus", "uid": "victoriametrics"},
      "options": {
        "tooltip": {"mode": "multi", "sort": "none"},
        "legend":  {"displayMode": "list", "placement": "bottom"}
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "color": {"mode": "palette-classic"}
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "100 - (avg by(cpu)(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "CPU {{cpu}}",
          "refId": "A"
        }
      ]
    }
  ]
}
DASH_EOF

systemctl daemon-reload
systemctl enable --now grafana-server

# grafana.ini admin_password only applies on first initialisation.
# Force-reset via grafana-cli so every re-run of this script keeps the
# password in sync with proxy.conf, even if Grafana was previously set up.
sleep 2
if grafana-cli admin reset-admin-password "${GRAFANA_PASS}" 2>/dev/null; then
  systemctl restart grafana-server
  info "Grafana admin password set from proxy.conf"
else
  warn "grafana-cli reset failed — password will apply on Grafana's first start"
fi
info "Grafana started on 127.0.0.1:${PORT_GRAFANA}"

# ── textfile collectors ────────────────────────────────────────────────────────
header "Installing textfile collectors"

# mtg container health
cat > /usr/local/bin/mtg-metrics.sh <<'MTG_COLLECTOR'
#!/usr/bin/env bash
set -euo pipefail
OUT="/var/lib/node_exporter/textfile_collector/mtg.prom"
TEMP=$(mktemp)
trap 'rm -f "$TEMP"' EXIT

if docker inspect mtg --format='{{.State.Running}}' 2>/dev/null | grep -q "^true$"; then
  echo "mtg_container_running 1" >> "$TEMP"
  RESTARTS=$(docker inspect mtg --format='{{.RestartCount}}' 2>/dev/null || echo 0)
  echo "mtg_container_restart_count ${RESTARTS}" >> "$TEMP"
else
  echo "mtg_container_running 0" >> "$TEMP"
  echo "mtg_container_restart_count 0" >> "$TEMP"
fi

mv "$TEMP" "$OUT"
MTG_COLLECTOR

chmod +x /usr/local/bin/mtg-metrics.sh

# fail2ban banned IP count per jail
cat > /usr/local/bin/fail2ban-metrics.sh <<'F2B_COLLECTOR'
#!/usr/bin/env bash
set -euo pipefail
OUT="/var/lib/node_exporter/textfile_collector/fail2ban.prom"
TEMP=$(mktemp)
trap 'rm -f "$TEMP"' EXIT

if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
  for jail in $(fail2ban-client status 2>/dev/null \
      | grep "Jail list" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | tr -d ' '); do
    count=$(fail2ban-client status "$jail" 2>/dev/null \
      | grep "Currently banned" | awk '{print $NF}' || echo 0)
    echo "fail2ban_banned_ips{jail=\"${jail}\"} ${count}" >> "$TEMP"
  done
else
  echo "fail2ban_banned_ips{jail=\"sshd\"} 0" >> "$TEMP"
fi

mv "$TEMP" "$OUT"
F2B_COLLECTOR

chmod +x /usr/local/bin/fail2ban-metrics.sh

# register crontab entries
(crontab -l 2>/dev/null | grep -v "mtg-metrics\|fail2ban-metrics" || true; \
 echo "* * * * * /usr/local/bin/mtg-metrics.sh 2>/dev/null"; \
 echo "* * * * * /usr/local/bin/fail2ban-metrics.sh 2>/dev/null") | crontab -

info "Textfile collectors installed (cron: every minute)"

# run once immediately to pre-populate
/usr/local/bin/mtg-metrics.sh    2>/dev/null || true
/usr/local/bin/fail2ban-metrics.sh 2>/dev/null || true

# ── done ──────────────────────────────────────────────────────────────────────
header "Monitoring stack deployed"
echo ""
info "Services:"
for svc in node_exporter victoriametrics vmagent vmalert alertmanager grafana-server; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $svc"
  else
    echo -e "  ${RED}✗${NC} $svc  ← check: journalctl -u $svc"
  fi
done

echo ""
info "Access Grafana (from your laptop):"
echo "  ssh -L 3000:localhost:3000 user@<proxy-ip>"
echo "  → http://localhost:3000  (admin / ${PROXY_MONITORING_GRAFANA_PASSWORD:-admin})"
echo ""

if [[ -z "${PROXY_MONITORING_TG_BOT_TOKEN:-}" ]]; then
  warn "Telegram alerts NOT configured. Edit proxy.conf then:"
  warn "  systemctl restart alertmanager"
fi
