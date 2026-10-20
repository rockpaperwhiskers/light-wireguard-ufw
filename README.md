# WireGuard Installer (Ubuntu + UFW)

A bash script that installs and configures a WireGuard VPN server on Ubuntu, with UFW for firewall management and SSH hardening built in.

## What it does

**First run** — full server setup in one pass:

1. Creates a new admin user, adds them to `sudo`, and installs their SSH public key
2. Installs WireGuard and UFW
3. Starts WireGuard
4. Generates a client configuration file and QR code into the admin user's home directory
5. Pauses — SSH is still on port 22 with full root access, no firewall rules active yet. Download the conf file and connect via WireGuard before continuing.
6. After you press Enter: configures UFW with NAT masquerade rules, then hardens SSH:
   - Moves SSH to port 2222
   - Disables root login
   - Restricts SSH access to the WireGuard interface only

**Subsequent runs** — client management menu:
- Add a new client
- List all clients
- Revoke an existing client
- Uninstall WireGuard

## Requirements

- Ubuntu 22.04, 24.04, or 26.04
- Must be run as root

## Usage

```bash
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

The script will prompt for:
- New admin username and password
- SSH public key for that user
- Server public IP and network interface
- WireGuard interface name (default: `wg0`)
- WireGuard subnet (default: `10.66.66.1`)
- WireGuard UDP port (random from 49152–65535)
- DNS resolvers for clients (default: Cloudflare `1.1.1.1` / `1.0.0.1`)
- First client name

## Firewall (UFW)

The script configures UFW instead of raw iptables:

- **WireGuard UDP port** — allowed from anywhere
- **SSH on port 2222** — allowed only from the WireGuard interface
- **NAT masquerade** — written to `/etc/ufw/before.rules` and `/etc/ufw/before6.rules` so it persists across reboots without PostUp/PostDown hooks in the WireGuard config
- **IP forwarding** — enabled via `/etc/ufw/sysctl.conf`

## SSH access after setup

Before hardening SSH, the script pauses and opens a **temporary HTTP server on port 51821** so you can download the client config with any browser — no SCP or copy-paste required:

```
http://<server-ip>:51821/wg0-client-<name>.conf
```

Alternatively, while the script is paused SSH is still on port 22, so you can SCP in a second terminal:

```bash
scp root@<server-ip>:/home/<username>/wg0-client-<name>.conf .
```

Or scan the QR code printed in the terminal with the WireGuard mobile app.

Once you've imported the config, connected via WireGuard, and verified you can reach `10.66.66.1`, press Enter. The HTTP server shuts down, port 51821 is removed from UFW, and SSH is hardened:

```bash
ssh -p 2222 <username>@10.66.66.1
```

> **Important:** Do not press Enter until WireGuard is connected and working. Ctrl+C aborts without changing SSH.

## Client configuration files

Client `.conf` files are saved to the admin user's home directory (`/home/<username>/`) with `600` permissions, so only that user can read them.

A QR code is printed to the terminal at generation time for mobile clients.

To download a config file via SCP:

```bash
scp -P 2222 <username>@<server-ip>:/home/<username>/wg0-client-<name>.conf .
```

Run the script again to generate additional client configs — each lands in the same home directory.

## Uninstall

Run the script and choose option 4 from the menu. This will:
- Stop and disable the WireGuard service
- Remove WireGuard packages and `/etc/wireguard`
- Remove the UFW rules and NAT masquerade blocks added by this script
- Restore `DEFAULT_FORWARD_POLICY` to `DROP`

SSH hardening (port 2222, no root login) is **not** reversed automatically — adjust `/etc/ssh/sshd_config` manually if needed.

## License

[MIT](https://raw.githubusercontent.com/angristan/wireguard-install/master/LICENSE) — based on [angristan/wireguard-install](https://github.com/angristan/wireguard-install)
