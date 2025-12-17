#!/usr/bin/env bash
set -euo pipefail

# This container must be run with --privileged or at least NET_ADMIN

WG_IF="wg0"
WG_CONF="/etc/wireguard/wg0.conf"

WAN_IF="eth0"

OVPN_NET="10.8.0.0"
OVPN_MASK="255.255.255.0"
OVPN_PORT="1194"
OVPN_PROTO="udp"
OVPN_DEV="tun0"
OVPN_SERVER_NAME="server"
OVPN_SERVER_CONF="/etc/openvpn/server/server.conf"

EASYRSA_DIR="/etc/openvpn/easy-rsa"
PKI_DIR="${EASYRSA_DIR}/pki"
OVPN_SERVER_DIR="/etc/openvpn/server"
CLIENT_NAME="client1"
CLIENT_OUTPUT="/vpn-data/${CLIENT_NAME}.ovpn"

RT_TABLE_ID="100"
RT_TABLE_NAME="vpnwg"
FWMARK_HEX="0x1"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

if [[ -z "${VPN_PUBLIC_HOST:-}" ]]; then
  error "VPN_PUBLIC_HOST environment variable must be set (external hostname or IP)."
  exit 1
fi

info "Starting VPN gateway with VPN_PUBLIC_HOST=${VPN_PUBLIC_HOST}"

#########################
# 0. Ensure Easy-RSA    #
#########################

# /etc/openvpn is likely a volume; copy Easy-RSA scripts into it if missing
if [[ ! -f "${EASYRSA_DIR}/easyrsa" ]]; then
  info "Copying Easy-RSA scripts into ${EASYRSA_DIR}..."
  mkdir -p "${EASYRSA_DIR}"
  cp -r /usr/local/share/easy-rsa/* "${EASYRSA_DIR}/"
fi

#########################
# 1. WireGuard setup    #
#########################

if [[ ! -f "${WG_CONF}" ]]; then
  error "WireGuard config ${WG_CONF} not found. Mount it from host (e.g. ./wireguard/wg0.conf:/etc/wireguard/wg0.conf)."
  exit 1
fi

# Ensure Table = off in [Interface]
if ! grep -qE '^\s*Table\s*=\s*off\s*$' "${WG_CONF}"; then
  warn "Adding 'Table = off' to [Interface] section in ${WG_CONF}..."
  tmpfile=$(mktemp)
  in_iface=0
  table_added=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[Interface\] ]]; then
      in_iface=1
      echo "$line" >> "$tmpfile"
      continue
    elif [[ "$line" =~ ^\[Peer\] ]]; then
      if [[ $in_iface -eq 1 && $table_added -eq 0 ]]; then
        echo "Table = off" >> "$tmpfile"
        table_added=1
      fi
      in_iface=0
      echo "$line" >> "$tmpfile"
      continue
    fi
    echo "$line" >> "$tmpfile"
  done < "${WG_CONF}"

  if [[ $in_iface -eq 1 && $table_added -eq 0 ]]; then
    echo "Table = off" >> "$tmpfile"
  fi

  cp "$tmpfile" "${WG_CONF}"
  rm -f "$tmpfile"
fi

info "Bringing up WireGuard interface ${WG_IF} manually (no wg-quick)..."
ip link del dev "${WG_IF}" 2>/dev/null || true

ip link add "${WG_IF}" type wireguard
wg setconf "${WG_IF}" <(wg-quick strip "${WG_CONF}")

WG_ADDRS=$(grep -i '^Address' "${WG_CONF}" | head -n1 | cut -d'=' -f2- | tr -d ' ')
WG_MTU=$(grep -i '^MTU' "${WG_CONF}" | head -n1 | cut -d'=' -f2- | tr -d ' ' || true)

IFS=',' read -ra ADDR_ARR <<< "${WG_ADDRS}"
for addr in "${ADDR_ARR[@]}"; do
  if [[ -n "${addr}" ]]; then
    ip address add "${addr}" dev "${WG_IF}"
  fi
done

if [[ -n "${WG_MTU:-}" ]]; then
  ip link set mtu "${WG_MTU}" dev "${WG_IF}"
fi

ip link set up dev "${WG_IF}"

info "WireGuard ${WG_IF} is up:"
ip addr show "${WG_IF}" || true
wg show || true

#########################
# 2. IP forwarding      #
#########################

info "Enabling IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null

#########################
# 3. Easy-RSA / PKI     #
#########################

mkdir -p "${EASYRSA_DIR}"
cd "${EASYRSA_DIR}"

if [[ ! -d "${PKI_DIR}" ]]; then
  info "Initializing PKI..."
  EASYRSA_BATCH=1 ./easyrsa init-pki

  info "Building CA (no passphrase)..."
  EASYRSA_BATCH=1 ./easyrsa build-ca nopass

  info "Generating server key and certificate..."
  EASYRSA_BATCH=1 ./easyrsa gen-req "${OVPN_SERVER_NAME}" nopass
  EASYRSA_BATCH=1 ./easyrsa sign-req server "${OVPN_SERVER_NAME}"

  info "Generating DH params..."
  ./easyrsa gen-dh

  info "Generating TLS-auth key..."
  openvpn --genkey --secret ta.key
else
  warn "PKI already exists; reusing."
fi

#########################
# 4. Deploy server keys #
#########################

mkdir -p "${OVPN_SERVER_DIR}"

cp "${PKI_DIR}/ca.crt"                               "${OVPN_SERVER_DIR}/"
cp "${PKI_DIR}/private/${OVPN_SERVER_NAME}.key"      "${OVPN_SERVER_DIR}/server.key"
cp "${PKI_DIR}/issued/${OVPN_SERVER_NAME}.crt"       "${OVPN_SERVER_DIR}/server.crt"
cp "${PKI_DIR}/dh.pem"                               "${OVPN_SERVER_DIR}/"
cp "${EASYRSA_DIR}/ta.key"                           "${OVPN_SERVER_DIR}/"

chmod 600 "${OVPN_SERVER_DIR}/server.key" "${OVPN_SERVER_DIR}/ta.key"

#########################
# 5. OpenVPN server cfg #
#########################

info "Writing OpenVPN server config to ${OVPN_SERVER_CONF}..."

cat > "${OVPN_SERVER_CONF}" <<EOF
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev ${OVPN_DEV}

user nobody
group nogroup

ca ${OVPN_SERVER_DIR}/ca.crt
cert ${OVPN_SERVER_DIR}/server.crt
key ${OVPN_SERVER_DIR}/server.key
dh ${OVPN_SERVER_DIR}/dh.pem

tls-auth ${OVPN_SERVER_DIR}/ta.key 0
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2

server ${OVPN_NET} ${OVPN_MASK}
topology subnet

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

keepalive 10 120
persist-key
persist-tun

verb 3
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
EOF

#########################
# 6. Policy routing     #
#########################

info "Configuring policy routing (only OpenVPN clients via WireGuard)..."

if ! grep -qE "^[[:space:]]*${RT_TABLE_ID}[[:space:]]+${RT_TABLE_NAME}\b" /etc/iproute2/rt_tables; then
  echo "${RT_TABLE_ID} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
fi

if ! ip rule show | grep -q "fwmark ${FWMARK_HEX} lookup ${RT_TABLE_NAME}"; then
  ip rule add fwmark "${FWMARK_HEX}" table "${RT_TABLE_NAME}"
fi

if ! ip route show table "${RT_TABLE_NAME}" | grep -q "^default "; then
  ip route add default dev "${WG_IF}" table "${RT_TABLE_NAME}"
fi

ip rule show
ip route show table "${RT_TABLE_NAME}"

#########################
# 7. iptables           #
#########################

info "Configuring iptables rules..."

# Mark packets from OpenVPN subnet
if ! iptables -t mangle -C PREROUTING -s "${OVPN_NET}/24" -j MARK --set-mark "${FWMARK_HEX}" 2>/dev/null; then
  iptables -t mangle -A PREROUTING -s "${OVPN_NET}/24" -j MARK --set-mark "${FWMARK_HEX}"
fi

# Forwarding between tun0 and wg0
if ! iptables -C FORWARD -i "${OVPN_DEV}" -o "${WG_IF}" -s "${OVPN_NET}/24" -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -i "${OVPN_DEV}" -o "${WG_IF}" -s "${OVPN_NET}/24" -j ACCEPT
fi

if ! iptables -C FORWARD -i "${WG_IF}" -o "${OVPN_DEV}" -d "${OVPN_NET}/24" -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -i "${WG_IF}" -o "${OVPN_DEV}" -d "${OVPN_NET}/24" -j ACCEPT
fi

# NAT for clients going out via wg0
if ! iptables -t nat -C POSTROUTING -s "${OVPN_NET}/24" -o "${WG_IF}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "${OVPN_NET}/24" -o "${WG_IF}" -j MASQUERADE
fi

#########################
# 8. Client cert        #
#########################

info "Generating client certificate ${CLIENT_NAME} (if needed)..."

cd "${EASYRSA_DIR}"
if [[ ! -f "${PKI_DIR}/issued/${CLIENT_NAME}.crt" ]]; then
  EASYRSA_BATCH=1 ./easyrsa gen-req "${CLIENT_NAME}" nopass
  EASYRSA_BATCH=1 ./easyrsa sign-req client "${CLIENT_NAME}"
else
  warn "Client cert ${CLIENT_NAME} already exists; reusing."
fi

CLIENT_KEY="${PKI_DIR}/private/${CLIENT_NAME}.key"
CLIENT_CRT="${PKI_DIR}/issued/${CLIENT_NAME}.crt"
CA_CRT="${PKI_DIR}/ca.crt"
TA_KEY="${EASYRSA_DIR}/ta.key"

mkdir -p /vpn-data

info "Writing client config to ${CLIENT_OUTPUT}..."

cat > "${CLIENT_OUTPUT}" <<EOF
client
dev tun
proto ${OVPN_PROTO}
remote ${VPN_PUBLIC_HOST} ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun

cipher AES-256-GCM
auth SHA256
remote-cert-tls server
tls-version-min 1.2
key-direction 1

; MTU tuning (compatible with WireGuard MTU=1280)
tun-mtu 1200
mssfix 1160

verb 3

<ca>
$(cat "${CA_CRT}")
</ca>

<cert>
$(cat "${CLIENT_CRT}")
</cert>

<key>
$(cat "${CLIENT_KEY}")
</key>

<tls-auth>
$(cat "${TA_KEY}")
</tls-auth>
EOF

chmod 600 "${CLIENT_OUTPUT}"

info "Client config generated at ${CLIENT_OUTPUT}"

#########################
# 9. Start OpenVPN      #
#########################

info "Starting OpenVPN server process..."
exec openvpn --config "${OVPN_SERVER_CONF}"
