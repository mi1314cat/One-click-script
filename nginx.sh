
    apt install -y nginx
   cat <<EOF >/etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    gzip on;

    server {
        listen ${PORT} ssl;
        server_name ${DOMAIN_LOWER};

        ssl_certificate       "${CERT_PATH}";
        ssl_certificate_key   "${KEY_PATH}";
        
        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m;
        ssl_session_tickets off;
        ssl_protocols    TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;

        location / {
            proxy_pass https://pan.imcxx.com;
            proxy_redirect off;
            sub_filter_once off;
            sub_filter "pan.imcxx.com" \$server_name;  # 替换为当前服务器的域名
            proxy_set_header Host \$host;  # 使用当前请求的主机名
            proxy_set_header X-Real-IP \$remote_addr;  # 使用客户端的真实 IP
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;  # 使用代理链的 IP
        }

        location ${WS_PATH} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:9999;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
    }
}
EOF


    systemctl reload nginx
