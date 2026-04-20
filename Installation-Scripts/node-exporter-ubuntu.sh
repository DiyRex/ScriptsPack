#!/bin/bash
# install_node_exporter.sh
# Installs Prometheus Node Exporter on Ubuntu as a systemd service

set -e

# Configuration
NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_USER="node_exporter"
INSTALL_DIR="/usr/local/bin"
ARCH="linux-amd64"

# Must run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "==> Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

# Create dedicated system user (no shell, no home)
if ! id "$NODE_EXPORTER_USER" &>/dev/null; then
    echo "==> Creating user: $NODE_EXPORTER_USER"
    useradd --no-create-home --shell /bin/false "$NODE_EXPORTER_USER"
fi

# Download and extract
cd /tmp
echo "==> Downloading..."
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"

echo "==> Extracting..."
tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"

# Move binary and set ownership
echo "==> Installing binary to ${INSTALL_DIR}..."
mv "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" "${INSTALL_DIR}/"
chown "${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER}" "${INSTALL_DIR}/node_exporter"
chmod +x "${INSTALL_DIR}/node_exporter"

# Cleanup
rm -rf "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}"*

# Create systemd service
echo "==> Creating systemd service..."
cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
Type=simple
ExecStart=${INSTALL_DIR}/node_exporter
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
echo "==> Starting service..."
systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

# Configure UFW firewall
if command -v ufw >/dev/null 2>&1; then
    ufw allow 9100/tcp comment 'Prometheus Node Exporter'
    echo "✓ UFW rule added for port 9100/tcp"
fi

# Verify
sleep 2
if systemctl is-active --quiet node_exporter; then
    echo ""
    echo "✓ Node Exporter installed successfully!"
    echo "  Status: $(systemctl is-active node_exporter)"
    echo "  Metrics: http://localhost:9100/metrics"
    echo ""
    echo "  Check status:  sudo systemctl status node_exporter"
    echo "  View logs:     sudo journalctl -u node_exporter -f"
else
    echo "✗ Service failed to start. Check: sudo journalctl -u node_exporter"
    exit 1
fi
