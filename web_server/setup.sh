#!/usr/bin/env bash

set -euo pipefail
# -e          : exit on error
# -u          : treat unset variable as error
# -o pipefail : if a pipe fails, whole program fails

# colours
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
BOLD=$(tput bold)
NC=$(tput sgr0)

info()    { echo "${CYAN}[*]${NC} $*"; }
success() { echo "${GREEN}[+]${NC} $*"; }
warn()    { echo "${YELLOW}[!]${NC} $*"; }
die()     { echo "${RED}[-] ERROR:${NC} $*" >&2; exit 1; }

# Step 2 — root check
[[ $EUID -ne 0 ]] && die "Run this script as root (sudo)."

# Step 3 — install
info "Updating package index..."
apt-get update -qq

info "Installing nginx..."
apt-get install -y -qq nginx

if ! command -v nginx &>/dev/null; then
    die "nginx installation failed — 'nginx' not found."
fi
success "nginx installed successfully."

# Step 4 — remove default site
info "Removing default nginx site..."
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default
success "Default site removed."

# Step 5 — write base nginx.conf
info "Writing base nginx.conf..."
cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    # basic settings
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;

    # hide nginx version from response headers
    server_tokens off;

    # mime types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    # load virtual host configs
    include /etc/nginx/sites-enabled/*;
}
EOF
success "nginx.conf written."

# Step 6 — validate, enable, start
info "Validating nginx config..."
if ! nginx -t; then
    die "nginx config validation failed."
fi
success "nginx config looks good."

info "Enabling and starting nginx..."
systemctl enable --now nginx
success "nginx enabled and started."

info "Checking service status..."
if ! systemctl is-active --quiet nginx; then
    die "nginx failed to start. Run 'systemctl status nginx' for details."
fi
success "nginx is running."

# Step 7 — closing banner
echo ""
echo "${BOLD}${GREEN}============================================${NC}"
echo "${BOLD}${GREEN}  nginx Setup Complete!${NC}"
echo "${BOLD}${GREEN}============================================${NC}"
echo ""
warn "Add virtual hosts  : sudo bash manage.sh"
warn "Check logs         : journalctl -u nginx -f"
warn "Check config       : nginx -t"