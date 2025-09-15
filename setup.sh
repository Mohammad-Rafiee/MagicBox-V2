#!/bin/bash
# ==========================================================
# SoftEther VPN Bridge Installer and Initial Setup
# Modular Systemd Service Version with robust path handling
# ==========================================================

set -e  # Exit immediately on error

SETUP_DIR="$(pwd)/setup-files"

# === CONFIGURABLE PASSWORDS AND VARIABLES ===
SERVER_ADMIN_PASSWORD="12q12q"
CASCADE_PASSWORD="56t56t"
CASCADE_NAME="HetznerTestCascade"
CASCADE_SERVER="157.90.226.134:443"
CASCADE_HUB="HetznerTest_hub"
CASCADE_USER="TUN"
BRIDGE_HUB="Bridge"
ETH_DEVICE="eth0"

SE_VERSION="v4.44-9807-rtm"
SE_DATE="2025.04.16"
SE_FILE="softether-vpnbridge-${SE_VERSION}-${SE_DATE}-linux-x64-64bit.tar.gz"
SE_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/${SE_VERSION}/${SE_FILE}"
INSTALL_DIR="/usr/local/vpnbridge"

# --- Determine script directory for relative file paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Update & Install dependencies ---
echo "[*] Updating system and installing build tools..."
sudo apt update && sudo apt install -y build-essential gnupg2 gcc make wget git isc-dhcp-server python3 python3-venv

# --- Check and Download SoftEther VPN Bridge if needed ---
if [ -f "${SCRIPT_DIR}/${SE_FILE}" ]; then
    echo "[*] Found existing SoftEther package ${SE_FILE}, skipping download."
else
    echo "[*] Downloading SoftEther VPN Bridge package..."
    wget -O "${SE_FILE}" "${SE_URL}"
fi

# --- Extract and Build ---
echo "[*] Extracting package..."
tar -xvzf "${SE_FILE}"
cd vpnbridge
echo "[*] Building SoftEther VPN Bridge..."
make
cd ..

# --- Install to /usr/local ---
echo "[*] Installing to ${INSTALL_DIR}..."
if [ -d "${INSTALL_DIR}" ]; then
    echo "[*] Existing installation found at ${INSTALL_DIR}, removing it..."
    sudo rm -rf "${INSTALL_DIR}"
fi
sudo mv vpnbridge "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# --- Detect if SoftEther installation exists ---
if [ -x "${INSTALL_DIR}/vpnbridge" ]; then
    echo "[*] SoftEther VPN Bridge installed."
    set_password_needed=false
else
    echo "[*] SoftEther VPN Bridge not installed."
    set_password_needed=true
fi

# --- Set Permissions ---
echo "[*] Setting permissions..."
sudo chmod 600 *
sudo chmod 700 vpnbridge vpncmd

# --- Copy modular systemd service file ---
echo "[*] Copying systemd service file..."
sudo cp "${SETUP_DIR}/vpnbridge.service" /etc/systemd/system/vpnbridge.service

# --- Enable and Start Service ---
echo "[*] Enabling and starting vpnbridge service..."
sudo systemctl daemon-reexec
sudo systemctl enable vpnbridge.service
sudo systemctl start vpnbridge.service

# --- Wait a few seconds for service startup ---
sleep 3

# --- Post-install configuration ---
if [ "$set_password_needed" = true ]; then
    echo "[*] Setting SoftEther server administrator password..."
    sudo "${INSTALL_DIR}/vpncmd" /SERVER localhost /CMD ServerPasswordSet "${SERVER_ADMIN_PASSWORD}"
fi

echo "[*] Creating Bridge HUB and bridging to ${ETH_DEVICE}..."
sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /PASSWORD:"${SERVER_ADMIN_PASSWORD}" /CMD BridgeCreate "${BRIDGE_HUB}" /DEVICE:"${ETH_DEVICE}" /TAP:no

# --- Check if cascade exists, then offline and delete it ---
echo "[*] Checking if cascade '${CASCADE_NAME}' exists..."
cascade_exists=$(sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /PASSWORD:"${SERVER_ADMIN_PASSWORD}" /ADMINHUB:"${BRIDGE_HUB}" /CMD CascadeList | grep -w "${CASCADE_NAME}" || true)

if [ -n "$cascade_exists" ]; then
    echo "[*] Cascade '${CASCADE_NAME}' exists. Taking it offline and deleting..."
    sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /PASSWORD:"${SERVER_ADMIN_PASSWORD}" /ADMINHUB:"${BRIDGE_HUB}" /CMD CascadeOffline "${CASCADE_NAME}"
    sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /PASSWORD:"${SERVER_ADMIN_PASSWORD}" /ADMINHUB:"${BRIDGE_HUB}" /CMD CascadeDelete "${CASCADE_NAME}"
else
    echo "[*] Cascade '${CASCADE_NAME}' does not exist. No need to delete."
fi

echo "[*] Creating Cascade Connection..."
sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /PASSWORD:"${SERVER_ADMIN_PASSWORD}" /ADMINHUB:"${BRIDGE_HUB}" \
    /CMD CascadeCreate "${CASCADE_NAME}" /SERVER:"${CASCADE_SERVER}" /HUB:"${CASCADE_HUB}" /USERNAME:"${CASCADE_USER}"

echo "[*] Setting Cascade Connection Password..."
sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /PASSWORD:"${SERVER_ADMIN_PASSWORD}" /ADMINHUB:"${BRIDGE_HUB}" \
    /CMD CascadePasswordSet "${CASCADE_NAME}" /PASSWORD:"${CASCADE_PASSWORD}" /TYPE:standard

echo "[*] Bringing Cascade Connection online..."
sudo "${INSTALL_DIR}/vpncmd" localhost /SERVER /ADMINHUB:"${BRIDGE_HUB}" /PASSWORD:"${SERVER_ADMIN_PASSWORD}" \
    /CMD CascadeOnline "${CASCADE_NAME}"

echo "[*] Installation and configuration complete!"


# ==========================================================
# 6️⃣ Configure and Restart DHCP Server
# ==========================================================
echo "📡 Configuring DHCP server..."
sudo apt install -y isc-dhcp-server
sudo cp "${SETUP_DIR}/dhcpd.conf" /etc/dhcp/dhcpd.conf
sudo cp "${SETUP_DIR}/isc-dhcp-server" /etc/default/isc-dhcp-server
sudo cp "${SETUP_DIR}/isc-dhcp-server.service" /lib/systemd/system/isc-dhcp-server.service
sudo systemctl daemon-reload
sudo systemctl disable isc-dhcp-server
sudo systemctl enable isc-dhcp-server
sudo systemctl restart isc-dhcp-server

# ==========================================================
# 7️⃣ Install and Set Up WiFi Login Service
# ==========================================================
echo "🌐 Installing WiFi login service..."
sudo mkdir -p /opt/wifi-setup/templates
sudo cp "${SETUP_DIR}/wifi_config.py" /opt/wifi-setup/wifi_config.py
sudo cp "${SETUP_DIR}/index.html" /opt/wifi-setup/templates/index.html
sudo cp "${SETUP_DIR}/connected.html" /opt/wifi-setup/templates/connected.html
sudo cp "${SETUP_DIR}/wifi-setup.service" /etc/systemd/system/wifi-setup.service
sudo chmod -R 755 /opt/wifi-setup
sudo chown -R root:root /opt/wifi-setup

# Python venv setup
PYTHON_BIN="$(which python3)"
if [ ! -d "/opt/wifi-setup/.venv" ]; then
    echo "[*] Creating Python venv for wifi-setup..."
    sudo ${PYTHON_BIN} -m venv /opt/wifi-setup/.venv
fi
sudo /opt/wifi-setup/.venv/bin/pip install --upgrade pip
if [ -f "${SETUP_DIR}/requirements.txt" ]; then
    sudo /opt/wifi-setup/.venv/bin/pip install -r "${SETUP_DIR}/requirements.txt"
fi

# Enable and start FastAPI service
sudo systemctl daemon-reload
sudo systemctl enable wifi-setup.service
sudo systemctl start wifi-setup.service

# ==========================================================
# 8️⃣ Configure Netplan for Static IP
# ==========================================================
echo "🌍 Configuring static IP for eth0..."
sudo cp "${SETUP_DIR}/50-cloud-init.yaml" /etc/netplan/50-cloud-init.yaml
sudo netplan apply
sleep 5
if ! ip a show eth0 | grep -q "192.168.2.1"; then
    echo "⚠️  Network settings may not have applied correctly. Please check connectivity or reboot manually if needed."
    # sudo reboot
fi

echo "✅ All services configured and running!"