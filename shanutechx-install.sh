#!/bin/bash
##########################################################################
#  ShanuTechX Panel Installer v1.0.0
#  Brand   : ShanuTechX
#  Author  : Shanu  (github.com/ShanudhaTirosh/shanutechx-panel)
#  Based on: 3x-ui Panel by MHSanaei (github.com/MHSanaei/3x-ui)
#            netch-vpn installer by ShanuFX
#  License : GPLv3 (inherited from 3x-ui)
#
#  ⚠  SECURITY NOTICE — READ BEFORE DEPLOYING PUBLICLY  ⚠
#  The default password set by this script ("admin") is identical to the
#  well-known 3x-ui stock default. Automated scanners already try it.
#  CHANGE IT IMMEDIATELY after first login.  Instructions are printed in
#  the final summary below.  At minimum, place the panel behind a firewall
#  allowlist or VPN before exposing port 443 to the internet.
##########################################################################

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Run as root (sudo su - or sudo bash $0)" && exit 1

############################### BRAND OUTPUT ####################################################
msg_ok()   { echo -e "\e[1;42m $1 \e[0m"; }
msg_err()  { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf()  { echo -e "\e[1;35m$1\e[0m"; }    # Purple — ShanuTechX primary
msg_cyan() { echo -e "\e[1;36m$1\e[0m"; }    # Cyan   — accent
msg_warn() { echo -e "\e[1;33m⚠  $1\e[0m"; } # Yellow — warnings

clear; echo
msg_inf  '   _____ _                     _____         _    __  __'
msg_inf  '  / ____| |                   |_   _|       | |   \ \/ /'
msg_inf  ' | (___ | |__   __ _ _ __  _   _| | ___  ___| |__  >  < '
msg_inf  '  \___ \| |_ \ / _` | |_ \| | | || |/ _ \/ __| |_ \/ /\ \'
msg_inf  '  ____) | | | | (_| | | | | |_| || |  __/ (__| | | >  < '
msg_inf  ' |_____/|_| |_|\__,_|_| |_|\__,_||_|\___|\___\__|_/_/\_\'
echo
msg_cyan ' ┌────────────────────────────────────────────────────────────┐'
msg_cyan ' │   ShanuTechX Panel Installer  v1.0.0                       │'
msg_cyan ' │   Powered by Xray-core  ·  Built on 3x-ui                  │'
msg_cyan ' │   github.com/ShanudhaTirosh/shanutechx-panel                │'
msg_cyan ' └────────────────────────────────────────────────────────────┘'
echo
msg_warn "Default password is 'admin' — you MUST change it after first login!"
msg_warn "See the final summary for the exact command to do so."
echo

############################### VARIABLES #######################################################
PANEL_VERSION="latest"          # "latest" or a specific tag e.g. "v2.4.0"
PANEL_PORT=2053                  # Internal panel port (nginx proxies in front)
PANEL_USER="Shanu"               # Default admin username
PANEL_PASS="admin"               # ⚠ WEAK — change after first login
PANEL_PATH="ShanuTechX"          # Web base path  →  /ShanuTechX/
XUIDB="/etc/x-ui/x-ui.db"
XUI_DIR="/usr/local/x-ui"
XUI_BIN="${XUI_DIR}/x-ui"
SYSTEMD_UNIT="/etc/systemd/system/x-ui.service"
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

# Runtime-resolved values (filled in below)
domain=""
IP4=""
USE_TLS="n"
USE_BUILD="n"           # "y" = build from source, "n" = download release binary

############################### ARG PARSING #####################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -domain|-d)      domain="$2";       shift 2;;
    -port|-p)        PANEL_PORT="$2";   shift 2;;
    -user|-u)        PANEL_USER="$2";   shift 2;;
    -pass|-k)        PANEL_PASS="$2";   shift 2;;
    -build|-b)       USE_BUILD="y";     shift 1;;
    -version|-v)     PANEL_VERSION="$2";shift 2;;
    -tls)            USE_TLS="y";       shift 1;;
    *)               shift 1;;
  esac
done

############################### SERVER IP DETECTION #############################################
msg_inf "  Detecting server IP…"
IP4=$(ip route get 8.8.8.8 2>/dev/null | grep -Po 'src \K\S+' || true)
[[ -z "$IP4" ]] && IP4=$(curl -s --max-time 5 ipv4.icanhazip.com | tr -d '[:space:]' || true)
[[ -z "$IP4" ]] && IP4="<your-server-ip>"
msg_ok "Server IP: ${IP4}"

############################### DOMAIN PROMPT ###################################################
if [[ -z "$domain" ]]; then
  echo
  msg_inf "  Enter your domain for TLS (leave blank to use IP-only / HTTP):"
  read -rp "  Domain: " domain
fi

if [[ -n "$domain" ]]; then
  USE_TLS="y"
  msg_ok "Domain: ${domain} — TLS will be configured with certbot"
else
  domain="$IP4"
  msg_inf "  No domain provided — panel will be reachable over HTTP on port 80"
fi

############################### HELPERS #########################################################
get_port() { echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 )); }
check_free() { ! nc -z 127.0.0.1 "$1" &>/dev/null; }
make_port() { local p; while true; do p=$(get_port); check_free "$p" && echo "$p" && break; done; }
gen_hex() { openssl rand -hex "${1:-8}"; }

reality_port=443
short_id=$(gen_hex 8)

############################### DEPENDENCY INSTALL ##############################################
echo
msg_inf " ─── Installing system dependencies ──────────────────────────────"

$Pak update -yqq
$Pak install -yqq \
  curl wget unzip jq sqlite3 nginx certbot python3-certbot-nginx \
  ufw openssl net-tools imagemagick ca-certificates gnupg lsb-release

msg_ok "System dependencies installed"

############################### NODE.JS (only needed for source build) ###########################
if [[ "$USE_BUILD" == "y" ]]; then
  msg_inf " ─── Installing Node.js 20 LTS ───────────────────────────────────"
  if ! command -v node &>/dev/null || [[ $(node -e "process.exit(+process.version.slice(1)<20)") ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    $Pak install -yqq nodejs
  fi
  msg_ok "Node $(node --version)"

  msg_inf " ─── Installing Go 1.24 ──────────────────────────────────────────"
  if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null | awk '{print $3}' | tr -d 'go')" < "1.24" ]]; then
    GO_VER="1.24.3"
    wget -qO /tmp/go.tar.gz "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    export PATH="/usr/local/go/bin:$PATH"
    echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile.d/go.sh
  fi
  msg_ok "Go $(go version | awk '{print $3}')"
fi

############################### STOP & CLEAN OLD INSTALL ########################################
msg_inf " ─── Removing any previous x-ui installation ─────────────────────"
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
rm -rf "${XUI_DIR}" /etc/x-ui "${SYSTEMD_UNIT}"
systemctl daemon-reload
msg_ok "Old installation removed"

############################### DOWNLOAD OR BUILD ###############################################
mkdir -p "${XUI_DIR}"

if [[ "$USE_BUILD" == "y" ]]; then
  # ── Build from local source ─────────────────────────────────────────────
  msg_inf " ─── Building ShanuTechX from source ─────────────────────────────"
  SRCDIR="/tmp/shanutechx-build"
  rm -rf "$SRCDIR"
  mkdir -p "$SRCDIR"

  # Expect the source zip to be present (uploaded alongside this script)
  if [[ -f "/root/3x-ui-main.zip" ]]; then
    unzip -q /root/3x-ui-main.zip -d "$SRCDIR"
    SRCDIR="${SRCDIR}/3x-ui-main"
  elif [[ -d "/root/shanutechx-panel" ]]; then
    SRCDIR="/root/shanutechx-panel"
  else
    msg_err "Source not found. Place 3x-ui-main.zip in /root/ or clone your fork to /root/shanutechx-panel"
    exit 1
  fi

  # Apply branding patches (idempotent sed replacements)
  msg_inf "  Applying brand patches…"
  # Frontend HTML entry points
  sed -i 's|<title>Sign in</title>|<title>ShanuTechX – Sign in</title>|' \
    "${SRCDIR}/frontend/login.html"
  grep -q 'favicon.ico' "${SRCDIR}/frontend/login.html" || \
    sed -i 's|</head>|  <link rel="icon" href="/favicon.ico" sizes="any">\n  <link rel="icon" type="image/svg+xml" href="/favicon.svg">\n</head>|' \
    "${SRCDIR}/frontend/login.html"
  sed -i 's|<title>.*</title>|<title>ShanuTechX</title>|' "${SRCDIR}/frontend/index.html" || \
    sed -i 's|</head>|  <title>ShanuTechX</title>\n</head>|' "${SRCDIR}/frontend/index.html"
  grep -q 'favicon.ico' "${SRCDIR}/frontend/index.html" || \
    sed -i 's|</head>|  <link rel="icon" href="/favicon.ico" sizes="any">\n  <link rel="icon" type="image/svg+xml" href="/favicon.svg">\n</head>|' \
    "${SRCDIR}/frontend/index.html"

  # LoginPage brand name
  sed -i 's|className="brand-name">3X-UI<|className="brand-name">ShanuTechX<|g' \
    "${SRCDIR}/frontend/src/pages/login/LoginPage.tsx"

  # AppSidebar brand text
  sed -i "s|collapsed ? '3X' : '3X-UI'|collapsed ? 'ShX' : 'ShanuTechX'|g" \
    "${SRCDIR}/frontend/src/layouts/AppSidebar.tsx"
  sed -i 's|className="drawer-brand">3X-UI<|className="drawer-brand">ShanuTechX<|g' \
    "${SRCDIR}/frontend/src/layouts/AppSidebar.tsx"

  # Page title hook fallback
  sed -i "s|: '3X-UI'|: 'ShanuTechX'|g" \
    "${SRCDIR}/frontend/src/hooks/usePageTitle.ts"

  # Dashboard panel card title
  sed -i 's|<span>3X-UI</span>|<span>ShanuTechX</span>|g' \
    "${SRCDIR}/frontend/src/pages/index/IndexPage.tsx"

  # TOTP issuer
  sed -i "s|issuer: '3x-ui'|issuer: 'ShanuTechX'|g" \
    "${SRCDIR}/frontend/src/pages/settings/TwoFactorModal.tsx"

  # Backend defaults
  sed -i 's|defaultUsername = "admin"|defaultUsername = "Shanu"|' \
    "${SRCDIR}/internal/database/db.go"
  sed -i 's|getEnv("XUI_INIT_WEB_BASE_PATH", "/")|getEnv("XUI_INIT_WEB_BASE_PATH", "/ShanuTechX/")|' \
    "${SRCDIR}/internal/web/service/setting.go"

  # Copy favicons
  if [[ -f "/root/favicon.svg" ]]; then
    cp /root/favicon.svg "${SRCDIR}/frontend/public/favicon.svg"
    msg_ok "Custom favicon.svg installed"
  fi
  if [[ -f "/root/favicon.ico" ]]; then
    cp /root/favicon.ico "${SRCDIR}/frontend/public/favicon.ico"
    msg_ok "Custom favicon.ico installed"
  elif command -v convert &>/dev/null && [[ -f "${SRCDIR}/frontend/public/favicon.svg" ]]; then
    convert -background transparent "${SRCDIR}/frontend/public/favicon.svg" \
      -define icon:auto-resize=16,32,48 "${SRCDIR}/frontend/public/favicon.ico" 2>/dev/null \
      && msg_ok "favicon.ico generated from SVG" \
      || cp "${SRCDIR}/frontend/public/favicon.svg" "${SRCDIR}/frontend/public/favicon.ico"
  fi

  msg_inf "  Building frontend…"
  cd "${SRCDIR}/frontend"
  npm ci --silent
  npm run build --silent
  msg_ok "Frontend built"

  msg_inf "  Building Go backend…"
  cd "${SRCDIR}"
  XUI_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0-shanutechx")
  export CGO_ENABLED=1 GOOS=linux GOARCH=amd64
  go build -ldflags="-s -w -X 'main.version=${XUI_VERSION}'" -o "${XUI_DIR}/x-ui" .
  msg_ok "Backend built: ${XUI_DIR}/x-ui"

  # Copy Xray binary + assets if present in source
  [[ -d "${SRCDIR}/bin" ]] && cp -r "${SRCDIR}/bin" "${XUI_DIR}/"
  [[ -f "${SRCDIR}/config.json" ]] && cp "${SRCDIR}/config.json" "${XUI_DIR}/"

else
  # ── Download pre-built release from GitHub ──────────────────────────────
  msg_inf " ─── Downloading ShanuTechX release binary ───────────────────────"
  RELEASE_REPO="ShanudhaTirosh/shanutechx-panel"

  if [[ "$PANEL_VERSION" == "latest" ]]; then
    PANEL_VERSION=$(curl -s "https://api.github.com/repos/${RELEASE_REPO}/releases/latest" \
      | jq -r '.tag_name')
    [[ -z "$PANEL_VERSION" || "$PANEL_VERSION" == "null" ]] && PANEL_VERSION="v2.4.0"
  fi

  ARCH="amd64"
  RELEASE_URL="https://github.com/${RELEASE_REPO}/releases/download/${PANEL_VERSION}/shanutechx-linux-${ARCH}.tar.gz"
  wget -qO /tmp/x-ui.tar.gz "${RELEASE_URL}"
  tar -xzf /tmp/x-ui.tar.gz -C /tmp/ && mv /tmp/shanutechx /tmp/x-ui 2>/dev/null || true
  cp -r /tmp/x-ui/* "${XUI_DIR}/"
  rm -rf /tmp/x-ui /tmp/x-ui.tar.gz
  chmod +x "${XUI_BIN}"
  msg_ok "Downloaded ${PANEL_VERSION}"
fi

# Make the x-ui binary available system-wide
ln -sf "${XUI_BIN}" /usr/local/bin/x-ui
chmod +x "${XUI_BIN}"

############################### SYSTEMD SERVICE #################################################
msg_inf " ─── Installing systemd service ──────────────────────────────────"
cat > "${SYSTEMD_UNIT}" <<'SERVICE'
[Unit]
Description=ShanuTechX Panel — Xray management
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable x-ui
systemctl start x-ui
sleep 2

# Verify the service came up
if ! systemctl is-active --quiet x-ui; then
  msg_err "x-ui service failed to start — check: journalctl -u x-ui -n 50"
  exit 1
fi
msg_ok "x-ui service is running"

############################### APPLY CREDENTIALS + BASE PATH ###################################
msg_inf " ─── Applying ShanuTechX credentials and base path ──────────────"
systemctl stop x-ui

"${XUI_BIN}" setting \
  -username  "${PANEL_USER}" \
  -password  "${PANEL_PASS}" \
  -port      "${PANEL_PORT}" \
  -webBasePath "${PANEL_PATH}"

msg_ok "Credentials set: user=${PANEL_USER}  basePath=/${PANEL_PATH}/"

############################### DEFAULT INBOUND (VLESS+TCP+REALITY) #############################
msg_inf " ─── Creating default VLESS+REALITY inbound on port 443 ─────────"

# Generate X25519 key pair for REALITY
if [[ -f "${XUI_DIR}/bin/xray-linux-amd64" ]]; then
  XRAY_BIN="${XUI_DIR}/bin/xray-linux-amd64"
elif [[ -f "${XUI_DIR}/xray-linux-amd64" ]]; then
  XRAY_BIN="${XUI_DIR}/xray-linux-amd64"
elif command -v xray &>/dev/null; then
  XRAY_BIN="xray"
else
  XRAY_BIN=""
fi

if [[ -n "$XRAY_BIN" ]]; then
  PRIV_PUB=$("${XRAY_BIN}" x25519 2>/dev/null || true)
  private_key=$(echo "$PRIV_PUB" | awk '/Private/{print $NF}')
  public_key=$(echo "$PRIV_PUB"  | awk '/Public/{print $NF}')
else
  msg_warn "xray binary not found — generating placeholder keys (replace via panel UI)"
  private_key="REPLACE_WITH_REAL_PRIVATE_KEY"
  public_key="REPLACE_WITH_REAL_PUBLIC_KEY"
fi

short_id=$(openssl rand -hex 8)
mkdir -p /etc/x-ui

# Only insert if the inbounds table is empty (safe to re-run)
INBOUND_COUNT=$(sqlite3 "${XUIDB}" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo "0")
if [[ "$INBOUND_COUNT" -eq 0 ]]; then
  sqlite3 "${XUIDB}" <<SQL
INSERT INTO "inbounds"
  ("user_id","up","down","total","remark","enable","expiry_time",
   "listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES
  ('1','0','0','0','ShanuTechX-Reality','1','0','','443','vless',
   '{"clients":[],"decryption":"none","fallbacks":[]}',
   '{"network":"tcp","security":"reality","realitySettings":{"show":false,"xver":0,
     "dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],
     "privateKey":"${private_key}","shortIds":["${short_id}"],
     "settings":{"publicKey":"${public_key}","fingerprint":"chrome","spiderX":"/"}}}',
   'inbound-443',
   '{"enabled":true,"destOverride":["http","tls","quic","fakedns"],
     "metadataOnly":false,"routeOnly":false}');
SQL
  msg_ok "Default VLESS+REALITY inbound created on port 443"
else
  msg_inf "  Inbounds table already has entries — skipping default inbound insert"
fi

# Start the panel again
systemctl start x-ui
sleep 2
msg_ok "x-ui restarted with new configuration"

############################### NGINX REVERSE PROXY #############################################
msg_inf " ─── Configuring nginx reverse proxy ─────────────────────────────"

# Remove stale configs
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/shanutechx
rm -f /etc/nginx/sites-enabled/shanutechx

if [[ "$USE_TLS" == "y" && "$domain" != "$IP4" ]]; then
  # ── HTTPS config (with TLS) ──────────────────────────────────────────────
  cat > /etc/nginx/sites-available/shanutechx <<NGINX
# ShanuTechX Panel — generated by shanutechx-install.sh
# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS — panel reverse proxy
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff"                             always;
    add_header X-Frame-Options           "SAMEORIGIN"                          always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin"     always;

    # Panel
    location /${PANEL_PATH}/ {
        proxy_pass         http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    # Subscription paths (proxied from the panel's own sub listener)
    location /sub/ {
        proxy_pass         http://127.0.0.1:2096;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
NGINX

  ln -sf /etc/nginx/sites-available/shanutechx /etc/nginx/sites-enabled/shanutechx

  # Test nginx config first (before running certbot)
  nginx -t
  systemctl restart nginx

  # Obtain TLS certificate
  msg_inf "  Running certbot for ${domain}…"
  certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
    -d "${domain}" || {
      msg_warn "certbot failed — check DNS A record for ${domain} → ${IP4}"
      msg_warn "Panel is still accessible over HTTP on port 80 in the meantime"
    }

else
  # ── HTTP-only config (no domain / IP-only) ───────────────────────────────
  cat > /etc/nginx/sites-available/shanutechx <<NGINX
# ShanuTechX Panel — HTTP-only (no domain / TLS)
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location /${PANEL_PATH}/ {
        proxy_pass         http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location /sub/ {
        proxy_pass http://127.0.0.1:2096;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX

  ln -sf /etc/nginx/sites-available/shanutechx /etc/nginx/sites-enabled/shanutechx
  nginx -t
  systemctl restart nginx
fi

# Lock the panel to loopback so it is NOT directly reachable by public IP
"${XUI_BIN}" setting -listenIP "127.0.0.1" 2>/dev/null || true
msg_ok "Panel locked to 127.0.0.1 (only reachable through nginx)"

############################### FIREWALL ########################################################
msg_inf " ─── Configuring UFW firewall ────────────────────────────────────"
ufw --force reset  >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP"
ufw allow 443/tcp   comment "HTTPS / VLESS-REALITY"
ufw allow 443/udp   comment "QUIC / UDP"
# NOTE: the panel port (${PANEL_PORT}) is deliberately NOT opened externally —
# it must only be accessed via nginx on localhost.
ufw --force enable
msg_ok "UFW enabled: 22/tcp, 80/tcp, 443/tcp, 443/udp"

############################### CRON JOBS #######################################################
# Remove any old entries before re-adding so the script is idempotent
crontab -l 2>/dev/null | grep -v "x-ui\|certbot" | crontab - || true
(crontab -l 2>/dev/null; echo '@daily x-ui restart >/dev/null 2>&1 && nginx -s reload') | crontab -
if [[ "$USE_TLS" == "y" ]]; then
  (crontab -l 2>/dev/null; \
   echo '@monthly certbot renew --nginx --non-interactive --post-hook "nginx -s reload" >/dev/null 2>&1') \
   | crontab -
fi
msg_ok "Cron jobs installed"

############################### SYSCTL TUNING ###################################################
msg_inf " ─── Applying kernel network tuning ──────────────────────────────"
# Remove any duplicate entries first
grep -v "net.core\|net.ipv4.tcp\|fs.file-max\|net.ipv4.ip_local" \
  /etc/sysctl.conf > /tmp/sysctl_clean.conf 2>/dev/null || true
mv /tmp/sysctl_clean.conf /etc/sysctl.conf
cat >> /etc/sysctl.conf <<'SYSCTL'
fs.file-max                      = 1000000
net.core.rmem_max                = 16777216
net.core.wmem_max                = 16777216
net.ipv4.tcp_rmem                = 4096 87380 16777216
net.ipv4.tcp_wmem                = 4096 65536 16777216
net.ipv4.ip_local_port_range     = 10000 65535
net.ipv4.tcp_fastopen            = 3
net.ipv4.tcp_congestion_control  = bbr
net.core.default_qdisc           = fq
SYSCTL
sysctl -p >/dev/null 2>&1 || true
msg_ok "Kernel tuning applied"

############################### FINAL SUMMARY ###################################################
systemctl is-active --quiet x-ui && systemctl is-active --quiet nginx || {
  msg_err "One or more services are not running. Check:"
  echo "  journalctl -u x-ui -n 50 --no-pager"
  echo "  nginx -t && journalctl -u nginx -n 20 --no-pager"
  exit 1
}

clear; echo
msg_inf  '   _____ _                     _____         _    __  __'
msg_inf  '  / ____| |                   |_   _|       | |   \ \/ /'
msg_inf  ' | (___ | |__   __ _ _ __  _   _| | ___  ___| |__  >  < '
msg_inf  '  \___ \| |_ \ / _` | |_ \| | | || |/ _ \/ __| |_ \/ /\ \'
msg_inf  '  ____) | | | | (_| | | | | |_| || |  __/ (__| | | >  < '
msg_inf  ' |_____/|_| |_|\__,_|_| |_|\__,_||_|\___|\___\__|_/_/\_\'
echo
msg_cyan ' ┌────────────────────────────────────────────────────────────┐'
msg_cyan ' │   ShanuTechX Panel — Installation Complete!                │'
msg_cyan ' └────────────────────────────────────────────────────────────┘'
echo

msg_inf  " ─── Server ──────────────────────────────────────────────────────"
printf   "   IPv4        :  %s\n" "${IP4}"
[[ -n "${domain}" && "${domain}" != "${IP4}" ]] && \
  printf "   Domain      :  %s\n" "${domain}"
echo

msg_inf  " ─── Panel Access ────────────────────────────────────────────────"
if [[ "$USE_TLS" == "y" && "${domain}" != "${IP4}" ]]; then
  printf "   URL         :  https://%s/%s/\n" "${domain}" "${PANEL_PATH}"
else
  printf "   URL         :  http://%s/%s/\n"  "${IP4}"    "${PANEL_PATH}"
fi
printf   "   Username    :  %s\n"  "${PANEL_USER}"
printf   "   Password    :  %s\n"  "${PANEL_PASS}"
printf   "   Base path   :  /%s/\n" "${PANEL_PATH}"
printf   "   Panel port  :  %s  (internal — NOT exposed externally)\n" "${PANEL_PORT}"
echo

msg_inf  " ─── Default Inbound ─────────────────────────────────────────────"
printf   "   Protocol    :  VLESS + TCP + REALITY\n"
printf   "   Port        :  443  (public)\n"
printf   "   Server SNI  :  www.microsoft.com  (camouflage)\n"
printf   "   Public Key  :  %s\n"  "${public_key}"
printf   "   Short ID    :  %s\n"  "${short_id}"
echo

msg_inf  " ─── SSL ─────────────────────────────────────────────────────────"
if [[ "$USE_TLS" == "y" && "${domain}" != "${IP4}" ]]; then
  certbot certificates 2>/dev/null | grep -E 'Domains:|Expiry' || true
else
  printf "   No TLS — pass -domain <yourdomain.com> to enable HTTPS\n"
fi
echo

msg_inf  " ─── How to change the password (do this NOW before going live) ──"
printf   "   Method 1 — CLI (fastest):\n"
printf   "     x-ui setting -password 'YourStrongPasswordHere'\n"
printf   "     x-ui restart\n\n"
printf   "   Method 2 — Panel UI:\n"
printf   "     Log in → top-right menu → Change Password\n\n"
printf   "   Method 3 — direct CLI subcommand:\n"
printf   "     x-ui\n"
printf   "     Then type '7' (Change Admin Password) and follow the prompts.\n"
echo

msg_inf  " ─── Useful commands ─────────────────────────────────────────────"
printf   "   x-ui                   — interactive menu\n"
printf   "   x-ui start/stop/restart\n"
printf   "   x-ui status            — service status\n"
printf   "   x-ui log               — tail Xray logs\n"
printf   "   nginx -t               — test nginx config\n"
printf   "   systemctl restart nginx\n"
printf   "   certbot renew          — renew TLS cert manually\n"
echo

msg_warn "CHANGE THE PASSWORD NOW.  The default 'admin' is scanned for automatically."
msg_ok   " Installation complete!  Save the credentials above — they won't be shown again. "
echo

########################################## Powered by ShanuTechX / Netch Solutions ##############
