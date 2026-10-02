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

# ---------- root check -------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run this script as root (sudo)."

# ---------- preflight checks -------------------------------------------------
command -v nginx &>/dev/null      || die "nginx not installed. Run setup.sh first."
systemctl is-active --quiet nginx || die "nginx is not running. Run setup.sh first."

# ---------- helper functions -------------------------------------------------

reload_nginx() {
    info "Validating nginx config..."
    if ! nginx -t 2>/dev/null; then
        die "nginx config validation failed. No changes applied."
    fi
    success "Config valid."

    info "Reloading nginx..."
    if ! systemctl reload nginx; then
        die "nginx reload failed. Check journalctl -u nginx for details."
    fi
    success "nginx reloaded."
}

list_proxies() {
    echo ""
    printf "${BOLD}%-35s %-8s %-15s %-s${NC}\n" "Domain" "Port" "Type" "Backend"
    echo "--------------------------------------------------------------------------------"

    for conf in /etc/nginx/sites-enabled/*; do
        [[ -e "${conf}" ]] || continue

        DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' "${conf}" | tr -d ' ')
        PORT=$(grep -oP 'listen\s+\K[0-9]+' "${conf}" | head -1)

        if grep -q "upstream" "${conf}"; then
            TYPE="load-balanced"
            COUNT=$(grep -c "server " "${conf}" || true)
            BACKEND="${COUNT} backends"
        else
            TYPE="single"
            BACKEND=$(grep -oP 'proxy_pass\s+\K[^;]+' "${conf}" | tr -d ' ')
        fi

        printf "%-35s %-8s %-15s %-s\n" "${DOMAIN}" "${PORT}" "${TYPE}" "${BACKEND}"
    done

    echo "--------------------------------------------------------------------------------"
    echo ""
}

# ---------- entry management -------------------------------------------------

add_single() {
    read -rp "Domain name (e.g. app.humphrey-de-network): " DOMAIN
    [[ -z "${DOMAIN}" ]] && die "Domain name is required."

    if [[ -f "/etc/nginx/sites-available/${DOMAIN}" ]]; then
        die "Proxy for '${DOMAIN}' already exists. Remove it first."
    fi

    read -rp "Backend URL (e.g. http://127.0.0.1:3000): " BACKEND
    [[ -z "${BACKEND}" ]] && die "Backend URL is required."

    # basic backend URL format check
    if ! [[ "${BACKEND}" =~ ^https?:// ]]; then
        die "Backend URL must start with http:// or https://"
    fi

    read -rp "Port [80]: " PORT
    PORT="${PORT:-80}"

    if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
        die "Invalid port: ${PORT}"
    fi

    info "Writing proxy config..."
    cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server {
    listen ${PORT};
    server_name ${DOMAIN};

    location / {
        proxy_pass ${BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

    ln -s "/etc/nginx/sites-available/${DOMAIN}" \
          "/etc/nginx/sites-enabled/${DOMAIN}"
    success "Proxy config written and enabled."

    reload_nginx
    success "Proxy '${DOMAIN}' -> '${BACKEND}' added on port ${PORT}."
}

add_loadbalanced() {
    read -rp "Domain name (e.g. api.humphrey-de-network): " DOMAIN
    [[ -z "${DOMAIN}" ]] && die "Domain name is required."

    if [[ -f "/etc/nginx/sites-available/${DOMAIN}" ]]; then
        die "Proxy for '${DOMAIN}' already exists. Remove it first."
    fi

    read -rp "Port [80]: " PORT
    PORT="${PORT:-80}"

    if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
        die "Invalid port: ${PORT}"
    fi

    # load balancing method
    echo ""
    echo "Load balancing method:"
    echo "  1) round-robin  — distribute requests equally (default)"
    echo "  2) least_conn   — send to backend with fewest connections"
    echo "  3) ip_hash      — same client IP always hits same backend"
    echo ""
    read -rp "Choice [1-3]: " LB_CHOICE

    case "${LB_CHOICE}" in
        1) LB_METHOD="" ;;           # round-robin is default, no directive needed
        2) LB_METHOD="least_conn;" ;;
        3) LB_METHOD="ip_hash;" ;;
        *) die "Invalid choice." ;;
    esac

    # collect backends
    read -rp "How many backends? " COUNT
    if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || (( COUNT < 2 )); then
        die "Must have at least 2 backends for load balancing."
    fi

    BACKENDS=()
    for (( i=1; i<=COUNT; i++ )); do
        read -rp "Backend ${i} (e.g. http://127.0.0.1:300${i}): " B
        [[ -z "${B}" ]] && die "Backend URL is required."
        if ! [[ "${B}" =~ ^https?:// ]]; then
            die "Backend URL must start with http:// or https://"
        fi
        # strip protocol for upstream block — upstream only takes host:port
        B_STRIPPED=$(echo "${B}" | sed 's|https\?://||')
        BACKENDS+=("    server ${B_STRIPPED};")
    done

    info "Writing load balanced proxy config..."

    # build upstream block
    UPSTREAM_BLOCK="upstream ${DOMAIN} {"$'\n'
    [[ -n "${LB_METHOD}" ]] && UPSTREAM_BLOCK+="    ${LB_METHOD}"$'\n'
    for B in "${BACKENDS[@]}"; do
        UPSTREAM_BLOCK+="${B}"$'\n'
    done
    UPSTREAM_BLOCK+="}"

    cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
${UPSTREAM_BLOCK}

server {
    listen ${PORT};
    server_name ${DOMAIN};

    location / {
        proxy_pass http://${DOMAIN};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

    ln -s "/etc/nginx/sites-available/${DOMAIN}" \
          "/etc/nginx/sites-enabled/${DOMAIN}"
    success "Load balanced proxy config written and enabled."

    reload_nginx
    success "Load balanced proxy '${DOMAIN}' added with ${COUNT} backends on port ${PORT}."
}

remove_proxy() {
    list_proxies

    read -rp "Domain name to remove: " DOMAIN
    [[ -z "${DOMAIN}" ]] && die "Domain name is required."

    if [[ ! -f "/etc/nginx/sites-available/${DOMAIN}" ]]; then
        die "Proxy '${DOMAIN}' not found."
    fi

    echo ""
    warn "About to remove proxy for: ${DOMAIN}"
    read -rp "Confirm? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" != "y" ]]; then
        info "Aborted. No changes made."
        exit 0
    fi

    rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
    rm -f "/etc/nginx/sites-available/${DOMAIN}"
    success "Proxy config removed."

    reload_nginx
    success "Proxy '${DOMAIN}' removed."
}

# ---------- menu -------------------------------------------------------------

echo ""
echo "${BOLD}${CYAN}nginx Reverse Proxy Manager${NC}"
echo ""
echo "  1) Add proxy (single backend)"
echo "  2) Add proxy (load balanced)"
echo "  3) Remove proxy"
echo "  4) List proxies"
echo "  5) Exit"
echo ""
read -rp "Choice [1-5]: " CHOICE

case "${CHOICE}" in
    1) add_single ;;
    2) add_loadbalanced ;;
    3) remove_proxy ;;
    4) list_proxies ;;
    5) exit 0 ;;
    *) die "Invalid choice." ;;
esac