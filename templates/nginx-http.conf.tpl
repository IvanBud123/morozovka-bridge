# Автоматически сгенерировано morozovka-bridge
# Сервис: ${SERVICE_NAME}
server {
    listen ${EXTERNAL_PORT};
    listen [::]:${EXTERNAL_PORT};
    server_name ${DOMAIN};

    client_max_body_size 512M;

    location / {
        proxy_pass http://${PI_VPN_IP}:${VPN_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
