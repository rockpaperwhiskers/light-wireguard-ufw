#!/bin/bash

# Secure WireGuard server installer for Ubuntu 22.04 / 24.04 / 26.04

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt)
	fi
	if [[ ${VIRT} == "openvz" ]]; then
		echo "OpenVZ is not supported"
		exit 1
	fi
	if [[ ${VIRT} == "lxc" ]]; then
		echo "LXC is not supported"
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	if [[ "${ID}" != "ubuntu" ]]; then
		echo "This script only supports Ubuntu."
		exit 1
	fi
	RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
	if [[ ${RELEASE_YEAR} -lt 22 ]]; then
		echo "Ubuntu ${VERSION_ID} is not supported. Please use Ubuntu 22.04 or later."
		exit 1
	fi
	OS="ubuntu"
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

# Creates a new admin user, adds them to sudo, and installs their SSH public key.
function setupServer() {
	echo ""
	echo "=== Admin User Setup ==="
	echo ""

	ADMIN_USER=""
	until [[ ${ADMIN_USER} =~ ^[a-z_][a-z0-9_-]*$ ]]; do
		read -rp "Enter username for new admin user: " ADMIN_USER
	done

	if id "${ADMIN_USER}" &>/dev/null; then
		echo -e "${ORANGE}User '${ADMIN_USER}' already exists, skipping creation.${NC}"
	else
		adduser --gecos "" "${ADMIN_USER}"
	fi

	usermod -aG sudo "${ADMIN_USER}"
	echo -e "${GREEN}User '${ADMIN_USER}' added to the sudo group.${NC}"

	echo ""
	echo "Paste the SSH public key for ${ADMIN_USER} (e.g., ssh-ed25519 AAAA... or ssh-rsa AAAA...):"
	local SSH_PUB_KEY=""
	until [[ ${SSH_PUB_KEY} =~ ^(ssh-|ecdsa-|sk-) ]]; do
		read -rp "SSH public key: " SSH_PUB_KEY
	done

	local USER_HOME="/home/${ADMIN_USER}"
	mkdir -p "${USER_HOME}/.ssh"
	echo "${SSH_PUB_KEY}" >>"${USER_HOME}/.ssh/authorized_keys"
	chmod 700 "${USER_HOME}/.ssh"
	chmod 600 "${USER_HOME}/.ssh/authorized_keys"
	chown -R "${ADMIN_USER}:${ADMIN_USER}" "${USER_HOME}/.ssh"
	echo -e "${GREEN}SSH public key installed for '${ADMIN_USER}'.${NC}"
}

# Sets SSH port to 2222 and disables root login, then restarts SSH.
# Called at the end of installWireGuard so WireGuard is up before SSH is locked down.
function hardenSSH() {
	# Remove any conflicting Port or PermitRootLogin settings from drop-in files
	# (common on Ubuntu cloud images, e.g. /etc/ssh/sshd_config.d/60-cloudimg-settings.conf)
	for f in /etc/ssh/sshd_config.d/*.conf; do
		[ -f "$f" ] && sed -i -e '/^Port /d' -e '/^PermitRootLogin /d' "$f"
	done

	# Replace in main sshd_config (delete existing lines, append clean values)
	sed -i '/^#\?Port /d' /etc/ssh/sshd_config
	sed -i '/^#\?PermitRootLogin /d' /etc/ssh/sshd_config
	printf '\nPort 2222\nPermitRootLogin no\n' >>/etc/ssh/sshd_config

	systemctl restart ssh

	echo -e "${GREEN}SSH hardened: port changed to 2222, root login disabled.${NC}"
	echo ""
	echo -e "${ORANGE}=========================================================${NC}"
	echo -e "${ORANGE}  IMPORTANT: SSH is now on port 2222 and is restricted   ${NC}"
	echo -e "${ORANGE}  to the WireGuard interface only.                        ${NC}"
	echo -e "${ORANGE}  Connect your WireGuard client BEFORE your next SSH      ${NC}"
	echo -e "${ORANGE}  session, then reconnect as:                             ${NC}"
	echo -e "${ORANGE}    ssh -p 2222 <user>@${SERVER_WG_IPV4}                 ${NC}"
	echo -e "${ORANGE}=========================================================${NC}"
	echo ""
}

# Configures UFW: NAT masquerade in before.rules, WireGuard port, SSH restricted to wg.
function setupUFW() {
	local WG_SUBNET="${SERVER_WG_IPV4%.*}.0/24"
	local WG6_SUBNET
	WG6_SUBNET="$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')/64"

	# Enable IP forwarding via UFW's own sysctl config
	sed -i 's|^#\?net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
	sed -i 's|^#\?net/ipv6/conf/default/forwarding=.*|net/ipv6/conf/default/forwarding=1|' /etc/ufw/sysctl.conf
	sed -i 's|^#\?net/ipv6/conf/all/forwarding=.*|net/ipv6/conf/all/forwarding=1|' /etc/ufw/sysctl.conf

	# Allow forwarding between interfaces (needed for VPN routing)
	sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

	# Insert NAT masquerade block into before.rules (before the *filter section)
	if ! grep -q "BEGIN WireGuard NAT" /etc/ufw/before.rules; then
		sed -i "/^\*filter/i # BEGIN WireGuard NAT\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s ${WG_SUBNET} -o ${SERVER_PUB_NIC} -j MASQUERADE\nCOMMIT\n# END WireGuard NAT\n" \
			/etc/ufw/before.rules
	fi

	# IPv6 NAT
	if ! grep -q "BEGIN WireGuard NAT" /etc/ufw/before6.rules; then
		sed -i "/^\*filter/i # BEGIN WireGuard NAT\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s ${WG6_SUBNET} -o ${SERVER_PUB_NIC} -j MASQUERADE\nCOMMIT\n# END WireGuard NAT\n" \
			/etc/ufw/before6.rules
	fi

	# Remove any pre-existing port 22 rules that might otherwise leave SSH exposed
	ufw delete allow 22/tcp 2>/dev/null || true
	ufw delete allow ssh 2>/dev/null || true

	# Allow WireGuard UDP
	ufw allow "${SERVER_PORT}/udp" comment "WireGuard"

	# Allow SSH on 2222 only from the WireGuard interface
	ufw allow in on "${SERVER_WG_NIC}" to any port 2222 proto tcp comment "SSH via WireGuard"

	ufw default deny incoming
	ufw default allow outgoing
	ufw --force enable

	echo -e "${GREEN}UFW configured and enabled.${NC}"
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1
	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: getHomeDirForClient() requires a client name as argument"
		exit 1
	fi
	if [ -n "${ADMIN_USER}" ] && [ -d "/home/${ADMIN_USER}" ]; then
		HOME_DIR="/home/${ADMIN_USER}"
	elif [ -e "/home/${CLIENT_NAME}" ]; then
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
		HOME_DIR="/home/${SUDO_USER}"
	else
		HOME_DIR="/root"
	fi
	echo "$HOME_DIR"
}

function installQuestions() {
	echo "Welcome to the WireGuard installer!"
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""

	SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	read -rp "IPv4 or IPv6 public address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

	SERVER_NIC="$(ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i wg0 SERVER_WG_NIC
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server WireGuard IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		read -rp "Server WireGuard IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
	done

	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		read -rp "Server WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
	done

	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the clients: " -e -i 1.1.1.1 CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the clients (optional): " -e -i 1.0.0.1 CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
		echo -e "\nWireGuard uses a parameter called AllowedIPs to determine what is routed over the VPN."
		read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i '0.0.0.0/0,::/0' ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		fi
	done

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	read -n1 -r -p "Press any key to continue..."
}

function installWireGuard() {
	installQuestions

	apt-get update
	apt-get install -y wireguard ufw resolvconf qrencode

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}WireGuard installation failed. The 'wg' command was not found.${NC}"
		exit 1
	fi

	mkdir -p /etc/wireguard
	chmod 600 -R /etc/wireguard/

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}
ADMIN_USER=${ADMIN_USER}" >/etc/wireguard/params

	# UFW handles the firewall; no PostUp/PostDown rules needed in the WireGuard config
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf
	sysctl --system

	systemctl start "wg-quick@${SERVER_WG_NIC}"
	systemctl enable "wg-quick@${SERVER_WG_NIC}"

	systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	WG_RUNNING=$?

	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
		echo -e "${ORANGE}Check: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		echo -e "${ORANGE}If you see \"Cannot find device ${SERVER_WG_NIC}\", please reboot.${NC}"
	else
		echo -e "\n${GREEN}WireGuard is running.${NC}"
	fi

	# Generate the client conf now — SSH is still on port 22 with full root access,
	# and UFW is not yet active, so the file is reachable by any transfer method.
	newClient
	echo -e "${GREEN}If you want to add more clients, run this script again.${NC}"

	# Serve the conf from the admin user's home directory for browser download.
	# UFW is not yet enabled so the port is open without needing an explicit rule.
	local DOWNLOAD_PORT=51821
	(cd "/home/${ADMIN_USER}" && python3 -m http.server "${DOWNLOAD_PORT}" >/dev/null 2>&1) &
	local HTTP_PID=$!

	echo ""
	echo -e "${ORANGE}=========================================================${NC}"
	echo -e "${ORANGE}  SSH is still on port 22 with full root access.         ${NC}"
	echo -e "${ORANGE}  No firewall rules are active yet.                      ${NC}"
	echo -e "${ORANGE}                                                          ${NC}"
	echo -e "${ORANGE}  Download the client config using ANY of these methods: ${NC}"
	echo -e "${ORANGE}                                                          ${NC}"
	echo -e "${ORANGE}  Browser:                                                ${NC}"
	echo -e "${ORANGE}  http://${SERVER_PUB_IP}:${DOWNLOAD_PORT}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
	echo -e "${ORANGE}                                                          ${NC}"
	echo -e "${ORANGE}  SCP:                                                    ${NC}"
	echo -e "${ORANGE}  scp root@${SERVER_PUB_IP}:/home/${ADMIN_USER}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf .${NC}"
	echo -e "${ORANGE}                                                          ${NC}"
	echo -e "${ORANGE}  Mobile: scan the QR code printed above.                ${NC}"
	echo -e "${ORANGE}                                                          ${NC}"
	echo -e "${ORANGE}  After importing: connect WireGuard and verify you can  ${NC}"
	echo -e "${ORANGE}  reach ${SERVER_WG_IPV4}, then press Enter to apply UFW ${NC}"
	echo -e "${ORANGE}  rules and harden SSH.                                  ${NC}"
	echo -e "${ORANGE}  Ctrl+C exits without applying any security changes.    ${NC}"
	echo -e "${ORANGE}=========================================================${NC}"
	read -n1 -r -p ""

	kill "${HTTP_PID}" 2>/dev/null || true

	setupUFW
	hardenSSH

	# Place a copy of this script in the admin user's home so they can manage
	# clients after logging in via WireGuard. Requires sudo to run.
	local SCRIPT_DEST="/home/${ADMIN_USER}/wireguard-install.sh"
	cp "$0" "${SCRIPT_DEST}"
	chown "${ADMIN_USER}:${ADMIN_USER}" "${SCRIPT_DEST}"
	chmod 750 "${SCRIPT_DEST}"
	echo -e "${GREEN}Script copied to ${SCRIPT_DEST}${NC}"
	echo -e "${GREEN}To add more clients: ssh -p 2222 ${ADMIN_USER}@${SERVER_WG_IPV4}${NC}"
	echo -e "${GREEN}Then run: sudo ~/wireguard-install.sh${NC}"
}

function newClient() {
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	echo ""
	echo "Client configuration"
	echo ""
	echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."

	CLIENT_EXISTS=1
	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "Client name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${CLIENT_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
			echo ""
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo ""
		echo "The subnet configured supports only 253 clients."
		exit 1
	fi

	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	IPV4_EXISTS=1
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "Client WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${IPV4_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
			echo ""
		fi
	done

	BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
	IPV6_EXISTS=1
	until [[ ${IPV6_EXISTS} == '0' ]]; do
		read -rp "Client WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
		IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${IPV6_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
			echo ""
		fi
	done

	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

# Uncomment to set a custom MTU
# MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	local CONF_FILE="${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	chmod 600 "${CONF_FILE}"
	if [ -n "${ADMIN_USER}" ]; then
		chown "${ADMIN_USER}:${ADMIN_USER}" "${CONF_FILE}"
	fi

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	echo -e "\n${GREEN}=== Client configuration — copy this to your local machine ===${NC}"
	echo "---"
	cat "${CONF_FILE}"
	echo "---"

	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nQR Code (scan with the WireGuard mobile app):\n${NC}"
		qrencode -t ansiutf8 -l L <"${CONF_FILE}"
		echo ""
	fi

	echo -e "${GREEN}Config file saved to: ${CONF_FILE}${NC}"
	echo -e "${GREEN}Download later with: scp -P 2222 ${ADMIN_USER}@<server-ip>:${CONF_FILE} .${NC}"
}

function listClients() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing clients!"
		exit 1
	fi

	echo ""
	echo "Select the existing client you want to revoke"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
	sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
}

function uninstallWg() {
	echo ""
	echo -e "\n${RED}WARNING: This will uninstall WireGuard and remove all configuration files!${NC}"
	echo -e "${ORANGE}Please backup /etc/wireguard if you want to keep your configuration.\n${NC}"
	read -rp "Do you really want to remove WireGuard? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		systemctl stop "wg-quick@${SERVER_WG_NIC}"
		systemctl disable "wg-quick@${SERVER_WG_NIC}"

		apt-get remove -y wireguard wireguard-tools qrencode

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		# Remove UFW rules added by this script
		ufw delete allow "${SERVER_PORT}/udp" 2>/dev/null || true
		ufw delete allow in on "${SERVER_WG_NIC}" to any port 2222 proto tcp 2>/dev/null || true

		# Remove NAT masquerade blocks from UFW rules files
		sed -i '/# BEGIN WireGuard NAT/,/# END WireGuard NAT/d' /etc/ufw/before.rules
		sed -i '/# BEGIN WireGuard NAT/,/# END WireGuard NAT/d' /etc/ufw/before6.rules

		# Restore forwarding policy to default
		sed -i 's/^DEFAULT_FORWARD_POLICY="ACCEPT"/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw

		ufw reload

		sysctl --system

		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo "WireGuard failed to uninstall properly."
			exit 1
		else
			echo "WireGuard uninstalled successfully."
			exit 0
		fi
	else
		echo ""
		echo "Removal aborted!"
	fi
}

function manageMenu() {
	echo "Welcome to WireGuard-install!"
	echo ""
	echo "It looks like WireGuard is already installed."
	echo ""
	echo "What do you want to do?"
	echo "   1) Add a new client"
	echo "   2) List all clients"
	echo "   3) Revoke existing client"
	echo "   4) Uninstall WireGuard"
	echo "   5) Exit"
	until [[ ${MENU_OPTION} =~ ^[1-5]$ ]]; do
		read -rp "Select an option [1-5]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1)
		newClient
		;;
	2)
		listClients
		;;
	3)
		revokeClient
		;;
	4)
		uninstallWg
		;;
	5)
		exit 0
		;;
	esac
}

initialCheck

if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
	manageMenu
else
	setupServer
	installWireGuard
fi
