#!/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/tatpow/fuster/main"

echo " _____           _             "
echo "|  ___|   _ ___| |_ ___ _ __ "
echo "| |_ | | | / __| __/ _ \ '__|"
echo "|  _|| |_| \__ \ ||  __/ |   "
echo "|_|   \__,_|___/\__\___|_|   "
echo "            make sites mo-o-ore faster!"
echo
echo "NOTE: This script sets up Nginx Stream (SNI routing) + Stub."
echo "Make sure 3x-ui is already installed."
echo
read -p "Press Enter to continue, or Ctrl+C to abort..."
echo

confirm () {
    read -p "$1 (y/n): " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

read -p "Main Domain for VPN & Stub (e.g., test.bossand.fun): " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
    echo "Main domain is required. Aborting."
    exit 1
fi

read -p "Subscription Domain (e.g., testsub.bossand.fun, Enter to skip): " SUB_DOMAIN

read -p "Xray Reality Port [default 3443]: " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-3443}

SUB_PORT=2096
STUB_PORT=8080

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
if [ -n "$SUB_DOMAIN" ]; then
    check_dns "$SUB_DOMAIN" || DNS_OK=0
fi

if [ "$DNS_OK" -eq 0 ]; then
    echo
    read -p "DNS doesn't fully match yet. Continue anyway? (y/n): " CONTINUE_ANYWAY
    [ "$CONTINUE_ANYWAY" != "y" ] && [ "$CONTINUE_ANYWAY" != "Y" ] && { echo "Fix DNS and re-run."; exit 1; }
fi

echo
echo "--- Pick a page style ---"
echo "1) 503 :: SYS_OVERLOAD  (system under heavy load)"
echo "2) 403 :: AdBlock notice"
echo "3) Admin login screen (with fake-auth service worker)"
read -p "Choose [1-3]: " STUB_CHOICE

case "$STUB_CHOICE" in
    2) STUB_FILE="ad.html"; HTTP_STATUS=403 ;;
    3) STUB_FILE="admin.html"; HTTP_STATUS=200 ;;
    *) STUB_FILE="503.html"; HTTP_STATUS=503 ;;
esac

echo "Selected: $STUB_FILE (HTTP status: $HTTP_STATUS)"

echo
echo "--- Installing packages ---"
if confirm "Install required packages (nginx, curl, socat, cron, dnsutils, libnginx-mod-stream)?"; then
    apt update && apt upgrade -y
    apt install -y nginx curl socat cron dnsutils libnginx-mod-stream
else
    echo "Skipping — make sure these are already installed, or later steps may fail."
fi

echo
echo "--- Deploying page ---"
if confirm "Deploy the selected page ($STUB_FILE) to /var/www/stub?"; then
    mkdir -p /var/www/stub
    curl -fsSL "$REPO_RAW/stub/$STUB_FILE" -o /var/www/stub/index.html
    if [ "$STUB_CHOICE" = "3" ]; then
        curl -fsSL "$REPO_RAW/stub/sw.js" -o /var/www/stub/sw.js
    fi
fi

echo
echo "--- SSL certificates ---"
# 1. Main Domain Cert
if confirm "Issue SSL certificate for MAIN domain ($MAIN_DOMAIN)?"; then
    if [ ! -d ~/.acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@"$MAIN_DOMAIN"
    fi
    systemctl stop nginx || true
    ~/.acme.sh/acme.sh --issue -d "$MAIN_DOMAIN" --standalone
    systemctl start nginx || true
    mkdir -p /root/cert/"$MAIN_DOMAIN"
    ~/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" --fullchain-file /root/cert/"$MAIN_DOMAIN"/fullchain.pem --key-file /root/cert/"$MAIN_DOMAIN"/privkey.pem --reloadcmd "systemctl reload nginx"
    echo "[OK] Main cert ready."
fi

# 2. Sub Domain Cert (Only if provided)
if [ -n "$SUB_DOMAIN" ]; then
    if confirm "Issue SEPARATE SSL certificate for SUB domain ($SUB_DOMAIN)?"; then
        systemctl stop nginx || true
        ~/.acme.sh/acme.sh --issue -d "$SUB_DOMAIN" --standalone
        systemctl start nginx || true
        mkdir -p /root/cert/"$SUB_DOMAIN"
        ~/.acme.sh/acme.sh --install-cert -d "$SUB_DOMAIN" --fullchain-file /root/cert/"$SUB_DOMAIN"/fullchain.pem --key-file /root/cert/"$SUB_DOMAIN"/privkey.pem --reloadcmd "systemctl reload nginx"
        echo "[OK] Sub cert ready."
    fi
fi

systemctl start nginx || true

echo
echo "--- Configuring Nginx (Stream + Stub) ---"
if confirm "Write Nginx stream config (port 443) and stub config (port $STUB_PORT)?"; then
    
    # Backup original nginx.conf
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d%H%M%S)
    
    # Create new nginx.conf with stream block
    cat > /etc/nginx/nginx.conf << NGINXCONF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

stream {
    map \$ssl_preread_server_name \$backend_node {
NGINXCONF

    # Dynamically add subdomain routing only if it exists
    if [ -n "$SUB_DOMAIN" ]; then
        echo "        $SUB_DOMAIN  127.0.0.1:$SUB_PORT;" >> /etc/nginx/nginx.conf
    fi
    
    cat >> /etc/nginx/nginx.conf << NGINXCONF2
        default      127.0.0.1:$XRAY_PORT;
    }

    server {
        listen 443;
        proxy_pass \$backend_node;
        ssl_preread on;
    }
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXCONF2

    # Create stub server config
    if [ "$HTTP_STATUS" = "200" ]; then
        LOCATION_BLOCK="location / { }"
    else
        LOCATION_BLOCK="location = /index.html { internal; }
    location / { return $HTTP_STATUS; }
    error_page $HTTP_STATUS /index.html;"
    fi

    cat > /etc/nginx/sites-available/stub << EOF
server {
    listen 127.0.0.1:$STUB_PORT ssl;
    server_name $MAIN_DOMAIN;

    ssl_certificate     /root/cert/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /root/cert/$MAIN_DOMAIN/privkey.pem;

    root /var/www/stub;
    index index.html;
    $LOCATION_BLOCK
}
EOF

    ln -sf /etc/nginx/sites-available/stub /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t
    systemctl restart nginx
    echo "[OK] Nginx configured successfully."
fi

echo
echo "--- Firewall ---"
if confirm "Configure ufw (open SSH + 443)?"; then
    if command -v ufw >/dev/null 2>&1; then
        SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oP ':\K[0-9]+' | head -n1)
        SSH_PORT=${SSH_PORT:-22}
        ufw allow "$SSH_PORT"/tcp
        ufw allow 443/tcp
        echo "Opened: $SSH_PORT (SSH), 443 (HTTPS/Stream)."
        if confirm "Enable ufw now?"; then
            ufw --force enable
            ufw status verbose
        fi
    else
        echo "ufw not found — skipping firewall setup."
    fi
fi

echo
echo "=================================================="
echo " SETUP COMPLETE!"
echo "=================================================="
echo
