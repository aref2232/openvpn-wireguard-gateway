FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
      openvpn easy-rsa \
      wireguard wireguard-tools \
      iptables iproute2 && \
    rm -rf /var/lib/apt/lists/*

# We'll create these at runtime too, but it's fine to have them here
RUN mkdir -p /etc/openvpn/easy-rsa /etc/openvpn/server /etc/wireguard /vpn-data

# Keep a copy of Easy-RSA scripts in a stable location
RUN mkdir -p /usr/local/share/easy-rsa && \
    if [ -d /usr/share/easy-rsa ]; then cp -r /usr/share/easy-rsa/* /usr/local/share/easy-rsa/; fi

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1194/udp

ENV VPN_PUBLIC_HOST=""

ENTRYPOINT ["/entrypoint.sh"]
