# OpenVPN → WireGuard Gateway (Docker)

This project provides a Dockerized VPN gateway that chains an OpenVPN server through an existing WireGuard interface (e.g. Cloudflare WARP). OpenVPN clients connect to the container, and their traffic is transparently routed out via WireGuard, while the host’s own traffic is unaffected.

**Key features:**

- OpenVPN server in a container (`tun0`) for remote clients.
- WireGuard client (`wg0`) inside the same container (e.g. WARP).
- Policy routing + iptables so **only OpenVPN client traffic** goes via WireGuard.
- The host’s own traffic (and SSH) remains on its normal default route.
- Easy-RSA PKI initialized automatically on first run.
- Client config `client1.ovpn` generated automatically.
- All keys and configs persisted in Docker volumes, so they’re only generated once per host.

---

## Requirements

- A Linux host with:
  - Docker
  - `docker compose` or `docker-compose`
- A working WireGuard config for your provider, e.g. `wg0.conf` for Cloudflare WARP:
  ```ini
  [Interface]
  PrivateKey = ...
  Address = 172.16.0.2/32, 2606:4700:110:847d:519:6b80:eefd:afe/128
  DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
  MTU = 1280
  # "Table = off" is enforced by the container
  # Table = off

  [Peer]
  PublicKey = ...
  AllowedIPs = 0.0.0.0/0, ::/0
  Endpoint = engage.cloudflareclient.com:2408
  ```
- A public IP or DNS name on your host, reachable by OpenVPN clients.

---

## Quick Start

### 1. Create project directory and volumes

On your host:

```bash
mkdir -p vpn-gateway
cd vpn-gateway

mkdir -p openvpn vpn-data wireguard
```

Copy your existing WireGuard config into `wireguard/wg0.conf`:

```bash
cp /etc/wireguard/wg0.conf wireguard/wg0.conf
# or create/edit vpn-gateway/wireguard/wg0.conf manually
```

### 2. Create `docker-compose.yml`

Create `docker-compose.yml`:

```yaml
services:
  vpn-gateway:
    image: ama15/openvpn-wg-gateway:latest
    container_name: vpn-gateway
    privileged: true
    environment:
      # Replace with your host's public IP or DNS, as seen by clients
      - VPN_PUBLIC_HOST=YOUR_PUBLIC_IP_OR_DNS
    volumes:
      - ./vpn-data:/vpn-data
      - ./openvpn:/etc/openvpn
      - ./wireguard/wg0.conf:/etc/wireguard/wg0.conf:ro
    ports:
      - "1194:1194/udp"
    restart: unless-stopped
```

Replace `YOUR_PUBLIC_IP_OR_DNS` with your real external IP or hostname.

### 3. Start the gateway

```bash
docker compose up -d
docker logs -f vpn-gateway
```

On first run you should see:

- WireGuard `wg0` being brought up.
- PKI initialization (`Initializing PKI…`, `Building CA…`).
- Server and client certificates created.
- A line like:
  ```text
  [INFO]  Client config generated at /vpn-data/client1.ovpn
  ```
- OpenVPN log finishing with `Initialization Sequence Completed`.

### 4. Get the client config

On the host:

```bash
ls vpn-data
# client1.ovpn should be present

cat vpn-data/client1.ovpn | head -n 20
```

Copy `client1.ovpn` to a client machine, e.g.:

```bash
scp root@YOUR_PUBLIC_IP_OR_DNS:~/vpn-gateway/vpn-data/client1.ovpn .
```

### 5. Connect as a client

On your client machine with OpenVPN installed:

```bash
sudo openvpn --config client1.ovpn
```

Once connected:

```bash
curl https://ifconfig.me
```

You should see the IP of your WireGuard provider (e.g., Cloudflare WARP), not your client’s normal internet IP.

If everything works, OpenVPN clients are now chained through WireGuard:

```text
Client → OpenVPN (container) → WireGuard (container) → Internet
```

---

## Persistence and First-Run Behavior

This setup persists **all important state** in volumes:

- `/etc/openvpn` → `./openvpn` on the host:
  - Easy-RSA PKI: CA, server certs, `client1` cert.
  - OpenVPN server config.
- `/vpn-data` → `./vpn-data`:
  - Generated client config(s), e.g. `client1.ovpn`.

On **first run** on a host:

- PKI is initialized and CA+server certs are created.
- A client certificate (`client1`) is created.
- `client1.ovpn` is generated with inline certs/keys.

On **subsequent runs**:

- The container detects that `PKI_DIR` already exists and **reuses**:
  - CA
  - server cert/key
  - client cert/key
- It logs messages like:
  ```text
  [WARN]  PKI already exists; reusing.
  [WARN]  Client cert client1 already exists; reusing.
  ```
- The client config file may be rewritten with the same certs/keys (harmless), but certs are **not** regenerated.

So restarting or recreating containers does **not** invalidate existing client configs.

---

## How It Works (Architecture)

### WireGuard

- The container expects `/etc/wireguard/wg0.conf` (mounted from host).
- At startup, the entrypoint:
  - Ensures `Table = off` is present in the `[Interface]` section (to avoid automatic default route changes).
  - Creates the `wg0` interface:
    ```bash
    ip link add wg0 type wireguard
    wg setconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)
    ```
  - Parses `Address` and `MTU` from the config and applies them:
    ```bash
    ip address add 172.16.0.2/32 dev wg0
    ip link set mtu 1280 dev wg0
    ip link set up dev wg0
    ```
- WireGuard handles the secure tunnel to your provider (e.g., Cloudflare WARP).

### OpenVPN + PKI (Easy-RSA)

- Easy-RSA scripts live in `/usr/local/share/easy-rsa` in the image.
- At runtime, the entrypoint:
  - Copies them to `/etc/openvpn/easy-rsa` if missing (because `/etc/openvpn` is a volume).
  - Initializes PKI on first run:
    ```bash
    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    ./easyrsa gen-dh
    openvpn --genkey --secret ta.key
    ```
  - Deploys certs/keys to `/etc/openvpn/server`.
  - Writes `/etc/openvpn/server/server.conf` with:
    ```ini
    port 1194
    proto udp
    dev tun0
    server 10.8.0.0 255.255.255.0
    push "redirect-gateway def1 bypass-dhcp"
    push "dhcp-option DNS 1.1.1.1"
    push "dhcp-option DNS 1.0.0.1"
    tls-auth ta.key 0
    cipher AES-256-GCM
    auth SHA256
    ```
- A client cert `client1` is created (once) and `client1.ovpn` is generated with inline `<ca>`, `<cert>`, `<key>`, `<tls-auth>`.

### Policy Routing and iptables (No SSH / Host Routing Impact)

Inside the container:

- Policy routing:
  ```bash
  echo "100 vpnwg" >> /etc/iproute2/rt_tables  # if not already there
  ip rule add fwmark 0x1 table vpnwg
  ip route add default dev wg0 table vpnwg
  ```
- iptables:
  - **Mark** all packets from OpenVPN clients (10.8.0.0/24):
    ```bash
    iptables -t mangle -A PREROUTING -s 10.8.0.0/24 -j MARK --set-mark 0x1
    ```
  - **Forward** between `tun0` and `wg0`:
    ```bash
    iptables -A FORWARD -i tun0 -o wg0 -s 10.8.0.0/24 -j ACCEPT
    iptables -A FORWARD -i wg0 -o tun0 -d 10.8.0.0/24 -j ACCEPT
    ```
  - **NAT** client traffic when it leaves via `wg0`:
    ```bash
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o wg0 -j MASQUERADE
    ```

Effect:

- Traffic from 10.8.0.0/24 gets `fwmark=0x1`, uses the `vpnwg` table, and exits via `wg0`.
- Traffic from **any other source** (e.g., the container’s own processes or the host) is **not marked**, and uses the main routing table (normal host networking).
- If WireGuard breaks, marked traffic has no usable default route and simply loses connectivity; it does **not** silently fall back to another route.

---

## Changing Protocol (UDP ↔ TCP) and Port

By default, this image uses:

- Protocol: `udp`
- Port: `1194`

These values are configured in `entrypoint.sh` at build time, and are used both for:

- The generated server config.
- The generated client config.

### Change to TCP

If you are building your own image, edit `entrypoint.sh`:

```bash
# Before
OVPN_PORT="1194"
OVPN_PROTO="udp"

# After (example: TCP 1194)
OVPN_PORT="1194"
OVPN_PROTO="tcp"
```

Then rebuild:

```bash
docker build -t ama15/openvpn-wg-gateway:tcp .
docker push ama15/openvpn-wg-gateway:tcp
```

And in your `docker-compose.yml`:

```yaml
services:
  vpn-gateway:
    image: ama15/openvpn-wg-gateway:tcp
    container_name: vpn-gateway
    privileged: true
    environment:
      - VPN_PUBLIC_HOST=YOUR_PUBLIC_IP_OR_DNS
    volumes:
      - ./vpn-data:/vpn-data
      - ./openvpn:/etc/openvpn
      - ./wireguard/wg0.conf:/etc/wireguard/wg0.conf:ro
    ports:
      - "1194:1194/tcp"
    restart: unless-stopped
```

Your `client1.ovpn` will now contain `proto tcp`.

### Change Port

To use a different port (e.g., 443), do both:

1. Edit `entrypoint.sh`:

   ```bash
   OVPN_PORT="443"
   # OVPN_PROTO="udp" or "tcp" as desired
   ```

2. Update `docker-compose.yml`:

   ```yaml
   ports:
     - "443:443/udp"   # or /tcp if using TCP
   ```

Rebuild and redeploy. The generated `client1.ovpn` will use the new port.

> If you don’t want to build your own variants, you can fork this repo, adjust `entrypoint.sh`, and build your own image (e.g. `youruser/openvpn-wg-gateway:tcp443`).

---

## Security & Leak Considerations

- Only the OpenVPN client subnet (`10.8.0.0/24`) is marked and routed through WireGuard.
- The container does **not** install a default route via `wg0` in the main table, only in the `vpnwg` table tied to the mark.
- There are **no** MASQUERADE rules for `10.8.0.0/24` on `eth0`, so client traffic cannot accidentally escape via the host’s normal route unless you add such rules yourself.
- If WireGuard fails, OpenVPN clients will lose internet access (fail-closed behavior), rather than leaky fallback to some other path.

To further harden:

- Add explicit drops for any 10.8.0.0/24 traffic trying to exit via non-WG interfaces.
- Add health checks to stop OpenVPN if `wg0` is down.

---

## Troubleshooting

- See logs:

  ```bash
  docker logs -f vpn-gateway
  ```

- Check inside the container:

  ```bash
  docker exec -it vpn-gateway bash

  wg show
  ip addr show wg0
  ip addr show tun0
  ip rule show
  ip route show table vpnwg
  iptables -t mangle -L -n -v
  iptables -t nat -L -n -v
  tail -n 100 /var/log/openvpn.log
  ```

- If you change WireGuard or OpenVPN settings, you may want to remove the persisted state (be careful, this wipes keys):

  ```bash
  docker compose down
  rm -rf openvpn vpn-data
  mkdir -p openvpn vpn-data
  docker compose up -d
  ```

  This forces a full re-init of PKI and configs.

---

## License

[MIT](LICENSE) or similar (fill in as appropriate).
