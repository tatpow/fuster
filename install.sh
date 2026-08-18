#!/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/tatpow/fuster/main"

echo " _____           _             "
echo "|  ___|   _ ___| |_ ___ _ __ "
echo "| |_ | | | / __| __/ _ \ '__|"
echo "|  _|| |_| \__ \ ||  __/ |   "
echo "|_|   \__,_|___/\__\___|_|   "
echo "            Stealth Mode Setup"
echo
echo "Эта схема: Xray слушает 443. Nginx слушает только локально (8080 и 8081)."
echo "Xray сам разруливает трафик через fallback."
echo
read -p "Press Enter to continue, or Ctrl+C to abort..."
echo

confirm () {
    read -p "$1 (y/n): " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

read -p "Main Domain for VPN & Stub (e.g., w.domen.ru): " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
    echo "Main domain is required. Aborting."
    exit 1
fi

read -p "Subscription Domain (e.g., sub.domen.ru): " SUB_DOMAIN
if [ -z "$SUB_DOMAIN" ]; then
    echo "Subscription domain is required for this setup. Aborting."
    exit 1
fi

read -p "Internal 3x-ui Subscription Port [default 2053]: " SUB_PORT
SUB_PORT=${SUB_PORT:-2053}

echo
echo "--- DNS check ---"
SERVER_IP=$(curl -4 -s ifconfig.me)
echo "This server's IP: $SERVER_IP"

check_dns () {
    local d="$1"
    local resolved
    resolved=$(dig +short "$d" | tail -n1)
    if [ "$resolved" != "$SERVER_IP" ]; then
        echo "  [!] $d -> '$resolved' (expected $SERVER_IP)"
        return 1
    else
        echo "  [OK] $d -> $SERVER_IP"
        return 0
    fi
}

DNS_OK=1
check_dns "$MAIN_DOMAIN" || DNS_OK=0
check_dns "$SUB_DOMAIN" || DNS_OK=0

if [ "$DNS_OK" -eq 0 ]; then
    echo
    read -p "DNS doesn't fully match yet. Continue anyway? (y/n): " CONTINUE_ANYWAY
    [ "$CONTINUE_ANYWAY" != "y" ] && [ "$CONTINUE_ANYWAY" != "Y" ] && { echo "Fix DNS and re-run."; exit 1; }
fi

echo
echo "--- Pick a stub page style ---"
echo "1) 503 :: SYS_OVERLOAD"
echo "2) 403 :: AdBlock notice"
echo "3) Admin login screen"
read -p "Choose [1-3]: " STUB_CHOICE

case "$STUB_CHOICE" in
    2) STUB_FILE="ad.html"; HTTP_STATUS=403 ;;
    3) STUB_FILE="admin.html"; HTTP_STATUS=200 ;;
    *) STUB_FILE="503.html"; HTTP_STATUS=503 ;;
esac

echo
echo "--- Installing packages ---"
if confirm "Install nginx, curl, socat, cron, dnsutils?"; then
    apt update && apt upgrade -y
    apt install -y nginx curl socat cron dnsutils
fi

echo
echo "--- Deploying stub page ---"
if confirm "Deploy stub to /var/www/stub?"; then
    mkdir -p /var/www/stub
    curl -fsSL "$REPO_RAW/stub/$STUB_FILE" -o /var/www/stub/index.html
    if [ "$STUB_CHOICE" = "3" ]; then
        curl -fsSL "$REPO_RAW/stub/sw.js" -o /var/www/stub/sw.js
    fi
fi

echo
echo "--- SSL Certificates ---"
if confirm "Issue SSL for MAIN domain ($MAIN_DOMAIN)?"; then
    if [ ! -d ~/.acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@"$MAIN_DOMAIN"
    fi
    systemctl stop nginx || true
    ~/.acme.sh/acme.sh --issue -d "$MAIN_DOMAIN" --standalone
    ~/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --fullchain-file /root/cert/"$MAIN_DOMAIN"/fullchain.pem \
        --key-file /root/cert/"$MAIN_DOMAIN"/privkey.pem \
        --reloadcmd "systemctl reload nginx"
    echo "[OK] Main cert ready."
fi

if confirm "Issue SSL for SUB domain ($SUB_DOMAIN)?"; then
    systemctl stop nginx || true
    ~/.acme.sh/acme.sh --issue -d "$SUB_DOMAIN" --standalone
    ~/.acme.sh/acme.sh --install-cert -d "$SUB_DOMAIN" \
        --fullchain-file /root/cert/"$SUB_DOMAIN"/fullchain.pem \
        --key-file /root/cert/"$SUB_DOMAIN"/privkey.pem \
        --reloadcmd "systemctl reload nginx"
    echo "[OK] Sub cert ready."
fi

systemctl start nginx || true

echo
echo "--- Configuring Nginx (Local Fallbacks) ---"
if confirm "Write local Nginx configs and restart?"; then
    
    # 1. Конфиг для ЗАГЛУШКИ (слушает локально, сюда Xray сбросит обычный браузерный трафик w.domen.ru)
    if [ "$HTTP_STATUS" = "200" ]; then
        LOCATION_BLOCK="location / { }"
    else
        LOCATION_BLOCK="location = /index.html { internal; }
    location / { return $HTTP_STATUS; }
    error_page $HTTP_STATUS /index.html;"
    fi

    cat > /etc/nginx/sites-available/stub <<EOF
server {
    listen 127.0.0.1:8080 ssl;
    server_name $MAIN_DOMAIN;

    ssl_certificate     /root/cert/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /root/cert/$MAIN_DOMAIN/privkey.pem;

    root /var/www/stub;
    index index.html;
    $LOCATION_BLOCK
}
EOF
    ln -sf /etc/nginx/sites-available/stub /etc/nginx/sites-enabled/

    # 2. Конфиг для ПОДПИСКИ (слушает локально, сюда Xray сбросит трафик sub.domen.ru)
    cat > /etc/nginx/sites-available/sub <<EOF
server {
    listen 127.0.0.1:8081 ssl;
    server_name $SUB_DOMAIN;

    ssl_certificate     /root/cert/$SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key /root/cert/$SUB_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/sub /etc/nginx/sites-enabled/

    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl restart nginx
    systemctl enable nginx
    echo "[OK] Nginx configured."
fi

echo
echo "--- Firewall ---"
if confirm "Configure ufw (open SSH + 443)?"; then
    if command -v ufw >/dev/null 2>&1; then
        SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oP ':\K[0-9]+' | head -n1)
        SSH_PORT=${SSH_PORT:-22}
        ufw allow "$SSH_PORT"/tcp
        ufw allow 443/tcp
        echo "Opened: $SSH_PORT (SSH), 443 (HTTPS/Xray)."
        if confirm "Enable ufw now?"; then
            ufw --force enable
            ufw status verbose
        fi
    fi
fi

echo
echo "=================================================="
echo " SETUP COMPLETE!"
echo "=================================================="
echo "Теперь зайди в панель 3x-ui и настрой Inbound:"
echo "1. Port: 443"
echo "2. TLS: ВКЛЮЧИТЬ (указать пути к /root/cert/$MAIN_DOMAIN/...)"
echo "3. Fallbacks (Добавить два правила):"
echo "   - Rule 1: SNI = '$SUB_DOMAIN'  --> dest = 8081"
echo "   - Rule 2: (оставить пустым)    --> dest = 8080"
echo "4. В настройках панели (Panel Settings) укажи Subscription Port: $SUB_PORT"
echo "=================================================="
