#!/bin/bash
#
# Truzt Ubuntu Install/Reinstall Script
# Installs Truzt if not present, or uninstalls and reinstalls if already installed
#
# IMPORTANT: This script preserves the peer registration in /etc/netbird/config.json
# The peer will reconnect with its existing identity and group assignments after reinstall.
#

set -e

# Global variable for temp directory (for cleanup)
TEMP_DIR=""

# Cleanup function - removes temp files on exit
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        echo -e "${GREEN}      Cleaned up temporary files.${NC}"
    fi
}

# Set trap to cleanup on exit, error, or interrupt
trap cleanup EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="Truzt"
BINARY_NAME="truzt"
UI_BINARY_NAME="truzt-ui"
SERVICE_NAME="truzt"

# Legacy app name (Trust with 's' instead of 'z')
LEGACY_APP_NAME="Trust"
LEGACY_BINARY_NAME="trust"
LEGACY_UI_BINARY_NAME="trust-ui"
LEGACY_SERVICE_NAME="trust"

# Paths - Note: config is still at /etc/netbird (code hasn't been migrated to /etc/truzt)
CONFIG_DIR="/etc/netbird"
LOG_DIR="/var/log/truzt"
LOG_DIR_LEGACY="/var/log/netbird"
LOG_DIR_LEGACY_TRUST="/var/log/trust"

DOWNLOAD_BASE_URL="https://pkgs.truzt.lk/release"
VERSION_URL="${DOWNLOAD_BASE_URL}/latest/version"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_NAME="amd64" ;;
    aarch64) ARCH_NAME="arm64" ;;
    *)      echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
esac

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Truzt Ubuntu Install Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Architecture: ${ARCH_NAME}"
echo ""

# Check if Truzt is installed
is_truzt_installed() {
    if command -v truzt &>/dev/null || dpkg -l | grep -q "truzt"; then
        return 0
    fi
    return 1
}

# Check if legacy Trust (with 's') is installed
is_legacy_trust_installed() {
    if command -v trust &>/dev/null || dpkg -l | grep -q "^ii  trust "; then
        return 0
    fi
    return 1
}

# Uninstall legacy Trust (with 's') installation
uninstall_legacy_trust() {
    echo -e "${YELLOW}Legacy Trust (with 's') installation detected...${NC}"
    echo ""

    # Stop legacy UI
    echo -e "${YELLOW}Stopping legacy Trust UI...${NC}"
    pkill -x "trust-ui" 2>/dev/null || true
    pkill -x "Trust" 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}      Legacy UI stopped.${NC}"

    # Stop and uninstall legacy daemon
    echo -e "${YELLOW}Stopping legacy Trust daemon service...${NC}"
    if command -v trust &>/dev/null; then
        sudo trust service stop 2>/dev/null || true
        echo -e "${GREEN}      Legacy daemon stopped.${NC}"

        echo -e "${YELLOW}Uninstalling legacy Trust daemon service...${NC}"
        sudo trust service uninstall 2>/dev/null || true
        echo -e "${GREEN}      Legacy daemon service uninstalled.${NC}"
    else
        # Try systemctl directly
        sudo systemctl stop trust 2>/dev/null || true
        sudo systemctl disable trust 2>/dev/null || true
        echo -e "${GREEN}      Legacy service stopped.${NC}"
    fi

    # Remove legacy package if installed via dpkg/apt
    echo -e "${YELLOW}Removing legacy Trust package...${NC}"
    if dpkg -l | grep -q "^ii  trust "; then
        sudo dpkg --purge trust 2>/dev/null || true
        echo -e "${GREEN}      Legacy package removed.${NC}"
    elif dpkg -l | grep -q "^ii  trust-full "; then
        sudo dpkg --purge trust-full 2>/dev/null || true
        echo -e "${GREEN}      Legacy package removed.${NC}"
    else
        echo -e "${GREEN}      No legacy package found.${NC}"
    fi

    # Clean legacy Trust logs (but NOT config - preserve peer registration)
    if [ -d "$LOG_DIR_LEGACY_TRUST" ]; then
        sudo rm -rf "${LOG_DIR_LEGACY_TRUST:?}"/*
        echo -e "${GREEN}      Cleaned ${LOG_DIR_LEGACY_TRUST}${NC}"
    fi

    echo -e "${GREEN}      Legacy Trust installation removed.${NC}"
    echo ""
}

# Check if running as root for certain operations
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Some operations require sudo. You may be prompted for your password.${NC}"
    fi
}

# Kill running app
stop_ui() {
    echo -e "${YELLOW}Stopping Truzt UI...${NC}"
    pkill -x "truzt-ui" 2>/dev/null || true
    pkill -x "Truzt" 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}      UI stopped.${NC}"
}

# Stop and uninstall daemon service
stop_daemon() {
    echo -e "${YELLOW}Stopping Truzt daemon service...${NC}"
    if command -v truzt &>/dev/null; then
        sudo truzt service stop 2>/dev/null || true
        echo -e "${GREEN}      Daemon stopped.${NC}"

        echo -e "${YELLOW}Uninstalling Truzt daemon service...${NC}"
        sudo truzt service uninstall 2>/dev/null || true
        echo -e "${GREEN}      Daemon service uninstalled.${NC}"
    else
        echo -e "${GREEN}      No daemon found, skipping.${NC}"
    fi
}

# Remove application (but NOT config - preserves peer registration)
remove_app() {
    echo -e "${YELLOW}Removing application...${NC}"

    # Remove the package if installed
    if dpkg -l | grep -q "truzt"; then
        sudo dpkg --purge truzt 2>/dev/null || true
        sudo dpkg --purge truzt-full 2>/dev/null || true
        echo -e "${GREEN}      Package removed.${NC}"
    fi

    echo -e "${GREEN}      Application removed.${NC}"
}

# Clean logs (but preserve config for peer registration)
clean_logs() {
    echo -e "${YELLOW}Cleaning log files...${NC}"

    # Clean truzt logs
    if [ -d "$LOG_DIR" ]; then
        sudo rm -rf "${LOG_DIR:?}"/*
        echo -e "${GREEN}      Cleaned ${LOG_DIR}${NC}"
    fi

    # Clean legacy netbird logs
    if [ -d "$LOG_DIR_LEGACY" ]; then
        sudo rm -rf "${LOG_DIR_LEGACY:?}"/*
        echo -e "${GREEN}      Cleaned ${LOG_DIR_LEGACY}${NC}"
    fi

    # Note: We do NOT remove config files to preserve peer registration
    # Config is at /etc/netbird/config.json (contains peer private key and registration)
    echo -e "${GREEN}      Logs cleaned. (Peer registration in ${CONFIG_DIR} preserved)${NC}"
}

# Get latest version
get_latest_version() {
    echo -e "${YELLOW}Fetching latest version...${NC}"

    LATEST_VERSION=$(curl -sL "$VERSION_URL" | tr -d '[:space:]')

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}      Failed to fetch latest version from ${VERSION_URL}${NC}"
        exit 1
    fi

    echo -e "${GREEN}      Latest version: ${LATEST_VERSION}${NC}"
}

# Download and install
download_and_install() {
    echo -e "${YELLOW}Downloading and installing Truzt v${LATEST_VERSION}...${NC}"

    # Construct download URL for Ubuntu deb
    # Format: https://pkgs.truzt.lk/release/v2.6.1/truzt-full_2.6.1_linux_amd64.deb
    DEB_URL="${DOWNLOAD_BASE_URL}/v${LATEST_VERSION}/truzt-full_${LATEST_VERSION}_linux_${ARCH_NAME}.deb"

    echo -e "      Download URL: ${DEB_URL}"

    # Create temp directory (will be cleaned up by trap on EXIT)
    TEMP_DIR=$(mktemp -d)
    DEB_FILE="${TEMP_DIR}/truzt-full_${LATEST_VERSION}_linux_${ARCH_NAME}.deb"

    # Download
    echo -e "      Downloading..."
    if ! curl -fsSL -o "$DEB_FILE" "$DEB_URL"; then
        echo -e "${RED}      Failed to download from ${DEB_URL}${NC}"
        exit 1
    fi

    echo -e "${GREEN}      Download complete.${NC}"

    # Install the package
    echo -e "      Installing package..."
    sudo dpkg -i "$DEB_FILE" || sudo apt-get install -f -y

    echo -e "${GREEN}      Installation complete.${NC}"

    # Note: TEMP_DIR cleanup handled by trap on EXIT
}

# Start services
start_services() {
    echo -e "${YELLOW}Starting Truzt services...${NC}"

    # Install and start daemon
    if command -v truzt &>/dev/null; then
        sudo truzt service install 2>/dev/null || true
        sudo truzt service start 2>/dev/null || true
        echo -e "${GREEN}      Daemon service started.${NC}"
    fi

    # Start the UI if installed and we're in a graphical session
    if command -v truzt-ui &>/dev/null && [ -n "$DISPLAY" ]; then
        nohup truzt-ui >/dev/null 2>&1 &
        echo -e "${GREEN}      UI launched.${NC}"
    fi
}

# Verify installation
verify_installation() {
    echo ""
    echo -e "${YELLOW}Verifying installation...${NC}"

    if command -v truzt &>/dev/null; then
        INSTALLED_VERSION=$(truzt version 2>/dev/null || echo "unknown")
        echo -e "${GREEN}      Truzt version: ${INSTALLED_VERSION}${NC}"
    fi

    # Check if peer config exists (registration preserved)
    if [ -f "${CONFIG_DIR}/config.json" ]; then
        echo -e "${GREEN}      Peer config preserved at: ${CONFIG_DIR}/config.json${NC}"
    else
        echo -e "${YELLOW}      No existing peer config found. You will need to register this peer.${NC}"
    fi
}

# Main execution
main() {
    check_sudo

    # Get latest version first
    get_latest_version

    # Check for and remove legacy Trust (with 's') installation first
    if is_legacy_trust_installed; then
        uninstall_legacy_trust
    fi

    if is_truzt_installed; then
        echo -e "${YELLOW}Truzt is already installed. Performing reinstall...${NC}"
        echo ""

        # Kill app if running
        stop_ui

        # Stop and uninstall daemon
        stop_daemon

        # Remove app files
        remove_app

        # Clean logs
        clean_logs

        # Download and install new version
        download_and_install

        # Start services
        start_services

        # Verify
        verify_installation

        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  Reinstallation complete!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo -e "Your peer registration has been preserved."
        echo -e "If you need to re-login, run: ${YELLOW}truzt up${NC}"
    else
        echo -e "${YELLOW}Truzt is not installed. Performing fresh install...${NC}"
        echo ""

        # Download and install
        download_and_install

        # Start services
        start_services

        # Verify
        verify_installation

        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  Installation complete!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo -e "To connect, run: ${YELLOW}truzt up${NC}"
    fi
}

# Run main function
main "$@"
