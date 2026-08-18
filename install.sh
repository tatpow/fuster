#!/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/tatpow/fuster/main"

echo " _____          _            "
echo "|  ___|   _ ___| |_ ___ _ __ "
echo "| |_ | | | / __| __/ _ \\ '__|"
echo "|  _|| |_| \\__ \\ ||  __/ |   "
echo "|_|   \\__,_|___/\\__\\___|_|   "
echo "            make sites mo-o-ore faster!"
echo
echo "NOTE: if you're deploying this site as a placeholder/stub for"
echo "something else, make sure you've already fully set up all other"
echo "required resources first (e.g. 3x-ui, Remnawave, etc.) before"
echo "running this script. This script only sets up the site itself —"
echo "it will not install, configure, or connect anything else for you."
echo
read -p "Press Enter to continue, or Ctrl+C to abort..."
echo

confirm () {
    read -p "$1 (y/n): " ans
    [ "$ans" = "y" ]
}

read -p "Domain for this site (e.g. site.example.com): " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
    echo "Domain is required. Aborting."
    exit 1
fi

read -p "Extra domain to also cover (Enter to skip): " BASE_DOMAIN

DOMAIN_ARGS="-d $MAIN_DOMAIN"
SERVER_NAMES="$MAIN_DOMAIN"
if [ -n "$BASE_DOMAIN" ]; then
    DOMAIN_ARGS="$DOMAIN_ARGS -d $BASE_DOMAIN"
    SERVER_NAMES="$MAIN_DOMAIN $BASE_DOMAIN"
fi

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
if [ -n "$BASE_DOMAIN" ]; then
    check_dns "$BASE_DOMAIN" || DNS_OK=0
fi

if [ "$DNS_OK" -eq 0 ]; then
    echo
    read -p "DNS doesn't fully match yet. Continue anyway? (y/n): " CONTINUE_ANYWAY
    [ "$CONTINUE_ANYWAY" != "y" ] && { echo "Fix DNS and re-run."; exit 1; }
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
if confirm "Install required packages (nginx, curl, socat, cron, dnsutils)?"; then
    apt update && apt upgrade -y
    apt install -y nginx curl socat cron dnsutils
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
else
    echo "Skipping — nginx config below will still point here, so make sure the files exist."
fi

echo
echo "--- SSL certificate ---"
if confirm "Issue an SSL certificate for $SERVER_NAMES via acme.sh (standalone, stops nginx briefly)?"; then
    if [ ! -d ~/.acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@"$MAIN_DOMAIN"
    fi

    systemctl stop nginx || true
    ~/.acme.sh/acme.sh --issue $DOMAIN_ARGS --standalone

    mkdir -p /root/cert/"$MAIN_DOMAIN"
    ~/.acme.sh/acme.sh --install-cert $DOMAIN_ARGS \
        --fullchain-file /root/cert/"$MAIN_DOMAIN"/fullchain.pem \
        --key-file /root/cert/"$MAIN_DOMAIN"/privkey.pem \
        --reloadcmd "systemctl reload nginx"
else
    echo "Skipping — nginx config below expects certs already at /root/cert/$MAIN_DOMAIN/"
fi

echo
echo "--- Configuring nginx (127.0.0.1:8080) ---"
if confirm "Write nginx config for $SERVER_NAMES and (re)start nginx?"; then
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
    server_name $SERVER_NAMES;

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
    systemctl start nginx
    systemctl enable nginx
else
    echo "Skipping nginx config."
fi

echo
echo "--- Firewall ---"
if confirm "Configure ufw (open SSH + 443)?"; then
    if command -v ufw >/dev/null 2>&1; then
        SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oP ':\K[0-9]+' | head -n1)
        SSH_PORT=${SSH_PORT:-22}
        ufw allow "$SSH_PORT"/tcp
        ufw allow 443/tcp
        echo "Opened: $SSH_PORT (SSH), 443."
        if confirm "Enable ufw now?"; then
            ufw --force enable
            ufw status verbose
        fi
    else
        echo "ufw not found — skipping firewall setup."
    fi
else
    echo "Skipping firewall configuration."
fi

echo
echo "=================================================="
echo " Site is up"
echo "=================================================="
echo "Check it: curl -k https://127.0.0.1:8080"
echo
echo "This script only sets up the site. Anything else (dashboard, etc.)"
echo "needs to be installed and configured separately."
