#!/usr/bin/env bash
# ВНИМАНИЕ: выполняется на ВНЕШНЕМ сервере.
# Переменные: VPN_PORT, VPN_PROTO, VPN_NETWORK, VPN_NETMASK, PI_VPN_IP, EXTERNAL_VPN_IP
set -euo pipefail

log() { echo "[remote] $*"; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openvpn easy-rsa nginx socat iptables-persistent curl

# ---------- OpenVPN PKI ----------
if [[ ! -f /etc/openvpn/server/ca.crt ]]; then
    log "Инициализация PKI"
    rm -rf /etc/openvpn/easy-rsa
    make-cadir /etc/openvpn/easy-rsa
    cd /etc/openvpn/easy-rsa

    ./easyrsa --batch init-pki
    ./easyrsa --batch --req-cn="morozovka-bridge-CA" build-ca nopass
    ./easyrsa --batch gen-req server nopass
    ./easyrsa --batch sign-req server server
    ./easyrsa --batch gen-req client nopass
    ./easyrsa --batch sign-req client client
    ./easyrsa gen-dh
    ./easyrsa gen-crl
    openvpn --genkey secret ta.key

    mkdir -p /etc/openvpn/server
    cp pki/ca.crt pki/issued/server.crt pki/private/server.key \
       pki/dh.pem pki/crl.pem ta.key /etc/openvpn/server/
    chmod 600 /etc/openvpn/server/*.key /etc/openvpn/server/ta.key

    mkdir -p /root/morozovka-bridge-client
    cp pki/ca.crt pki/issued/client.crt pki/private/client.key ta.key \
       /root/morozovka-bridge-client/
    chmod -R go-rwx /root/morozovka-bridge-client
else
    log "PKI уже существует — пропускаем"
fi

# ---------- ccd: фиксированный IP для Малинки ----------
mkdir -p /etc/openvpn/server/ccd
cat > /etc/openvpn/server/ccd/client <<EOF
ifconfig-push ${PI_VPN_IP} ${VPN_NETMASK}
EOF

# ---------- Конфиг OpenVPN-сервера ----------
cat > /etc/openvpn/server/server.conf <<EOF
port ${VPN_PORT}
proto ${VPN_PROTO}
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh /etc/openvpn/server/dh.pem
tls-auth /etc/openvpn/server/ta.key 0
crl-verify /etc/openvpn/server/crl.pem
server ${VPN_NETWORK} ${VPN_NETMASK}
ifconfig-pool-persist /etc/openvpn/server/ipp.txt
client-config-dir /etc/openvpn/server/ccd
keepalive 10 120
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
tls-version-min 1.2
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
verb 3
EOF

mkdir -p /var/log/openvpn
systemctl enable openvpn-server@server
systemctl restart openvpn-server@server

# ---------- Форвардинг + firewall ----------
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-morozovka-bridge.conf
sysctl -p /etc/sysctl.d/99-morozovka-bridge.conf

iptables -t nat -C POSTROUTING -s "${VPN_NETWORK}/24" -o eth0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${VPN_NETWORK}/24" -o eth0 -j MASQUERADE
iptables -C FORWARD -i tun0 -o eth0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
iptables -C FORWARD -i eth0 -o tun0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
netfilter-persistent save

# ---------- Nginx ----------
mkdir -p /etc/nginx/stream.d
rm -f /etc/nginx/sites-enabled/default

# Включаем stream-блок (если ещё нет)
if ! grep -q "stream.d" /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf <<'NGINXEOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
NGINXEOF
fi

systemctl enable nginx
systemctl restart nginx

log "Внешний сервер настроен."
