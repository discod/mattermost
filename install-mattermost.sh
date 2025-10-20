#!/bin/bash
#
# Mattermost Custom Build Installation Script
# For Ubuntu 22.04/24.04
#
# This script installs your custom Mattermost fork with:
# - 2,500 user limit (increased from 250)
# - Unlimited message history (no 10,000 limit)
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Detect the actual user (when using sudo)
ACTUAL_USER=${SUDO_USER:-$USER}
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)

log_info "Mattermost Custom Build Installer"
echo "======================================"
echo ""
echo "This will install Mattermost with:"
echo "  - 2,500 user limit"
echo "  - Unlimited message history"
echo ""

# Configuration prompts
read -p "Enter your domain name (or press Enter to use IP:8065): " DOMAIN
read -p "Do you want to set up nginx reverse proxy? (y/n): " SETUP_NGINX
read -p "Do you want to set up SSL with Let's Encrypt? (requires domain) (y/n): " SETUP_SSL

if [[ "$SETUP_SSL" == "y" ]] && [[ -z "$DOMAIN" ]]; then
    log_error "SSL requires a domain name"
    exit 1
fi

if [[ "$SETUP_SSL" == "y" ]]; then
    read -p "Enter your email for Let's Encrypt: " SSL_EMAIL
fi

# Generate secure database password
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

log_info "Configuration Summary:"
echo "  Domain: ${DOMAIN:-http://localhost:8065}"
echo "  Setup Nginx: ${SETUP_NGINX}"
echo "  Setup SSL: ${SETUP_SSL}"
echo "  Database Password: (auto-generated)"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# Step 1: Update system
log_info "Updating system packages..."
apt update && apt upgrade -y

# Step 2: Install dependencies
log_info "Installing system dependencies..."
apt install -y build-essential git curl wget postgresql postgresql-contrib

# Step 3: Install Go 1.22
log_info "Installing Go 1.22..."
GO_VERSION="1.22.0"
if ! command -v go &> /dev/null || [[ $(go version | grep -oP '\d+\.\d+') < "1.21" ]]; then
    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
    rm go${GO_VERSION}.linux-amd64.tar.gz

    # Add to PATH for all users
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin

    log_info "Go $(go version) installed"
else
    log_info "Go already installed: $(go version)"
fi

# Step 4: Install Node.js 20.x
log_info "Installing Node.js 20.x..."
if ! command -v node &> /dev/null || [[ $(node -v | grep -oP '\d+') < "20" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
    log_info "Node.js $(node -v) and npm $(npm -v) installed"
else
    log_info "Node.js already installed: $(node -v)"
fi

# Step 5: Set up PostgreSQL
log_info "Setting up PostgreSQL database..."
sudo -u postgres psql << EOF
-- Drop existing database if exists
DROP DATABASE IF EXISTS mattermost;
DROP USER IF EXISTS mmuser;

-- Create fresh database
CREATE DATABASE mattermost;
CREATE USER mmuser WITH PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE mattermost TO mmuser;
ALTER DATABASE mattermost OWNER TO mmuser;
\c mattermost
GRANT USAGE, CREATE ON SCHEMA PUBLIC TO mmuser;
EOF

log_info "PostgreSQL database created"

# Step 6: Create mattermost user
log_info "Creating mattermost system user..."
if ! id -u mattermost &>/dev/null; then
    useradd --system --user-group --no-create-home mattermost
fi

# Step 7: Clone repository
log_info "Cloning Mattermost repository..."
INSTALL_DIR="/opt/mattermost"
rm -rf $INSTALL_DIR
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

git clone https://github.com/discod/mattermost.git .

# Step 8: Build server
log_info "Building Mattermost server (this may take 10-15 minutes)..."
cd $INSTALL_DIR/server
make build-linux

if [ ! -f "$INSTALL_DIR/server/bin/mattermost" ]; then
    log_error "Server build failed - binary not found"
    exit 1
fi

log_info "Server build completed successfully"

# Step 9: Build webapp
log_info "Building webapp (this may take 10-15 minutes)..."
cd $INSTALL_DIR/webapp

# Use the actual user for npm to avoid permission issues
sudo -u $ACTUAL_USER npm ci --legacy-peer-deps
sudo -u $ACTUAL_USER npm run build

if [ ! -d "$INSTALL_DIR/webapp/channels/dist" ]; then
    log_error "Webapp build failed - dist directory not found"
    exit 1
fi

log_info "Webapp build completed successfully"

# Step 10: Deploy webapp files
log_info "Deploying webapp files to client directory..."
rm -rf $INSTALL_DIR/client
mkdir -p $INSTALL_DIR/client
cp -r $INSTALL_DIR/webapp/channels/dist/* $INSTALL_DIR/client/

if [ ! -f "$INSTALL_DIR/client/root.html" ]; then
    log_error "Webapp deployment failed - root.html not found"
    exit 1
fi

log_info "Webapp deployed successfully"

# Step 11: Create additional directories and set up config
log_info "Setting up additional directories and configuration..."
cd $INSTALL_DIR
mkdir -p data logs config plugins

# Copy default config
cp $INSTALL_DIR/server/build/config/config.json $INSTALL_DIR/config/

# Configure config.json
if [[ -n "$DOMAIN" ]]; then
    if [[ "$SETUP_SSL" == "y" ]]; then
        SITE_URL="https://$DOMAIN"
    else
        SITE_URL="http://$DOMAIN"
    fi
else
    SITE_URL="http://localhost:8065"
fi

# Update config.json using jq or sed
if command -v jq &> /dev/null; then
    apt install -y jq
fi

cat > $INSTALL_DIR/config/config.json << EOF
{
  "ServiceSettings": {
    "SiteURL": "$SITE_URL",
    "ListenAddress": ":8065",
    "EnableLinkPreviews": true
  },
  "TeamSettings": {
    "SiteName": "Mattermost",
    "MaxUsersPerTeam": 2500,
    "EnableOpenServer": false,
    "EnableUserCreation": true,
    "EnableTeamCreation": true
  },
  "SqlSettings": {
    "DriverName": "postgres",
    "DataSource": "postgres://mmuser:$DB_PASSWORD@localhost:5432/mattermost?sslmode=disable&connect_timeout=10",
    "MaxIdleConns": 20,
    "MaxOpenConns": 300
  },
  "LogSettings": {
    "EnableConsole": true,
    "ConsoleLevel": "INFO",
    "EnableFile": true,
    "FileLevel": "INFO",
    "FileLocation": ""
  },
  "FileSettings": {
    "Directory": "./data/"
  },
  "EmailSettings": {
    "EnableSignUpWithEmail": true,
    "EnableSignInWithEmail": true,
    "EnableSignInWithUsername": true,
    "SendEmailNotifications": false,
    "RequireEmailVerification": false,
    "SMTPServer": "",
    "SMTPPort": "587"
  },
  "RateLimitSettings": {
    "Enable": false
  },
  "PluginSettings": {
    "Enable": true,
    "EnableUploads": true,
    "Directory": "./plugins",
    "ClientDirectory": "./client/plugins"
  }
}
EOF

# Set permissions
chown -R mattermost:mattermost $INSTALL_DIR
chmod -R g+w $INSTALL_DIR

log_info "Configuration completed"

# Step 11: Create systemd service
log_info "Creating systemd service..."
cat > /etc/systemd/system/mattermost.service << 'EOF'
[Unit]
Description=Mattermost
After=network.target postgresql.service

[Service]
Type=notify
ExecStart=/opt/mattermost/server/bin/mattermost
TimeoutStartSec=3600
KillMode=mixed
Restart=always
RestartSec=10
WorkingDirectory=/opt/mattermost
User=mattermost
Group=mattermost
LimitNOFILE=49152

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mattermost

log_info "Systemd service created"

# Step 12: Set up nginx (optional)
if [[ "$SETUP_NGINX" == "y" ]]; then
    log_info "Installing and configuring nginx..."
    apt install -y nginx

    cat > /etc/nginx/sites-available/mattermost << EOF
upstream mattermost_backend {
    server localhost:8065;
    keepalive 32;
}

proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=mattermost_cache:10m max_size=3g inactive=120m use_temp_path=off;

server {
    listen 80;
    server_name ${DOMAIN:-_};

    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 50M;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        client_body_timeout 60;
        send_timeout 300;
        lingering_timeout 5;
        proxy_connect_timeout 90;
        proxy_send_timeout 300;
        proxy_read_timeout 90s;
        proxy_http_version 1.1;
        proxy_pass http://mattermost_backend;
    }

    location / {
        client_max_body_size 50M;
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_cache mattermost_cache;
        proxy_cache_revalidate on;
        proxy_cache_min_uses 2;
        proxy_cache_use_stale timeout;
        proxy_cache_lock on;
        proxy_http_version 1.1;
        proxy_pass http://mattermost_backend;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/mattermost /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl enable nginx
    systemctl restart nginx

    log_info "Nginx configured and started"
fi

# Step 13: Set up SSL (optional)
if [[ "$SETUP_SSL" == "y" ]]; then
    log_info "Setting up SSL with Let's Encrypt..."
    apt install -y certbot python3-certbot-nginx

    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $SSL_EMAIL --redirect

    log_info "SSL certificate installed"
fi

# Step 14: Start Mattermost
log_info "Starting Mattermost..."
systemctl start mattermost

# Wait for startup
sleep 5

# Check status
if systemctl is-active --quiet mattermost; then
    log_info "Mattermost is running!"
else
    log_error "Mattermost failed to start. Check logs with: journalctl -u mattermost -n 50"
    exit 1
fi

# Save credentials
CREDENTIALS_FILE="$ACTUAL_HOME/mattermost-credentials.txt"
cat > $CREDENTIALS_FILE << EOF
========================================
Mattermost Installation Complete!
========================================

Access URL: $SITE_URL

Database Credentials:
  Database: mattermost
  User: mmuser
  Password: $DB_PASSWORD

Installation Directory: $INSTALL_DIR
Configuration File: $INSTALL_DIR/config/config.json

Useful Commands:
  Status:  sudo systemctl status mattermost
  Logs:    sudo journalctl -u mattermost -f
  Restart: sudo systemctl restart mattermost
  Stop:    sudo systemctl stop mattermost

Custom Features:
  ✓ User limit: 2,500 (increased from 250)
  ✓ Message history: Unlimited (no 10K limit)

Next Steps:
  1. Open $SITE_URL in your browser
  2. Create your admin account
  3. Create your first team
  4. Start collaborating!

EOF

chown $ACTUAL_USER:$ACTUAL_USER $CREDENTIALS_FILE

cat $CREDENTIALS_FILE

log_info "Installation completed successfully!"
log_info "Credentials saved to: $CREDENTIALS_FILE"

if [[ "$SETUP_NGINX" != "y" ]]; then
    log_warn "Remember to open port 8065 in your firewall:"
    log_warn "  sudo ufw allow 8065/tcp"
else
    log_warn "Remember to open ports 80 and 443 in your firewall:"
    log_warn "  sudo ufw allow 80/tcp"
    log_warn "  sudo ufw allow 443/tcp"
fi
