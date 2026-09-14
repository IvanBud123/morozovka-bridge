# Автоматически сгенерировано morozovka-bridge
# Сервис: ${SERVICE_NAME} (TCP)
upstream ${SERVICE_NAME}_backend {
    server ${PI_VPN_IP}:${VPN_PORT};
}

server {
    listen ${EXTERNAL_PORT} so_keepalive=on;
    proxy_pass ${SERVICE_NAME}_backend;
    proxy_timeout 600s;
    proxy_connect_timeout 5s;
}
