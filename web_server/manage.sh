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

# Step 1 — root check
[[ $EUID -ne 0 ]] && die "Run this script as root (sudo)."

# Step 2 — preflight checks
command -v nginx &>/dev/null      || die "nginx not installed. Run setup.sh first."
systemctl is-active --quiet nginx || die "nginx is not running. Run setup.sh first."

# Step 3 — helper functions
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

list_vhosts() {
    echo ""
    printf "${BOLD}%-30s %-10s %-s${NC}\n" "Domain" "Port" "Document Root"
    echo "------------------------------------------------------------------------"

    for conf in /etc/nginx/sites-enabled/*; do
	# skip if no files match
	[[ -e "${conf}" ]] || continue

	DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' "${conf}" | tr -d ' ')
	PORT=$(grep -oP 'listen\s+\K[0-9]+' "${conf}" | head -1)
	ROOT=$(grep -oP 'root\s+\K[^;]+' "${conf}" | tr -d ' ')

	printf "%-30s %-10s %-s\n" "${DOMAIN}" "${PORT}" "${ROOT}"
    done

    echo "------------------------------------------------------------------------"
    echo ""
}

# Step 4 — add vhost
add_vhost() {
    read -rp "Domain name + zone (e.g. dommain -> my-website.dns1-local <- zone): " DOMAIN
    [[ -z "${DOMAIN}" ]] && die "Domain name is required."

    read -rp "Document root [/var/www/${DOMAIN}/]: " DOC_ROOT
    DOC_ROOT="${DOC_ROOT:-/var/www/${DOMAIN}/}"
    
    # reject relative paths
    if [[ "${DOC_ROOT}" != /* ]]; then
        die "Document root must be an absolute path (e.g. /var/www/example.com/)."
    fi
    
    # if path exists, check www-data can read it
    # if path does not exist yet, check parent directory is accessible
    if [[ -d "${DOC_ROOT}" ]]; then
        CHECK_PATH="${DOC_ROOT}"
    else
        CHECK_PATH=$(dirname "${DOC_ROOT}")
    fi
    
    if ! sudo -u www-data test -r "${CHECK_PATH}" 2>/dev/null; then
        echo ""
        warn "www-data does not have read access to ${CHECK_PATH}."
        warn "Fix with one of:"
        warn "  chmod o+rx ${CHECK_PATH}"
        warn "  chown -R www-data:www-data ${CHECK_PATH}"
        echo ""
        read -rp "Enter a different path, or press Enter to abort: " RETRY
        if [[ -z "${RETRY}" ]]; then
            die "Aborted — fix permissions and try again."
        fi
        DOC_ROOT="${RETRY}"
    fi

    read -rp "Port [80]: " PORT
    PORT="${PORT:-80}"

    # validate port is a number
    if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
	die "Invalid port: ${PORT}"
    fi

    # check if vhost already exists
    if [[ -f "/etc/nginx/sites-available/${DOMAIN}" ]]; then
	die "Virtual host '${DOMAIN}' already exists. Remove it first."
    fi

    # create document root
    info "Creating document root ${DOC_ROOT}..."
    mkdir -p "${DOC_ROOT}"

    # create default index.html
    cat > "${DOC_ROOT}/index.html" << EOF
<!DOCTYPE html>
<html>
<head><title>${DOMAIN}</title></head>
<body>
    <h1>${DOMAIN}</h1>
    <p>Virtual host is working.</p>
</body>
</html>
EOF

    # set correct ownership
    chown -R www-data:www-data "${DOC_ROOT}"
    success "Document root created."

    # write nginx vhost config
    info "Writing nginx config..."
    cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server {
    listen ${PORT};
    server_name ${DOMAIN};

    root ${DOC_ROOT};
    index index.html;

    location / {
	try_files \$uri \$uri/ =404;
    }
}
EOF

    # enable vhost by symlinking to sites-enabled
    ln -s "/etc/nginx/sites-available/${DOMAIN}" \
	  "/etc/nginx/sites-enabled/${DOMAIN}"
    success "Virtual host enabled."

    reload_nginx

    success "Virtual host '${DOMAIN}' added and serving on port ${PORT}."
}

# Step 5 — remove vhost
remove_vhost() {
    # show current vhosts first
    list_vhosts

    read -rp "Domain name to remove: " DOMAIN
    [[ -z "${DOMAIN}" ]] && die "Domain name is required."

    if [[ ! -f "/etc/nginx/sites-available/${DOMAIN}" ]]; then
	die "Virtual host '${DOMAIN}' not found."
    fi

    DOC_ROOT=$(grep -oP 'root\s+\K[^;]+' \
	"/etc/nginx/sites-available/${DOMAIN}" | tr -d ' ')

    echo ""
    warn "About to remove:"
    echo "    Domain      : ${DOMAIN}"
    echo "    Config      : /etc/nginx/sites-available/${DOMAIN}"
    echo "    Document root: ${DOC_ROOT}"
    echo ""
    read -rp "Also delete document root and files? [y/N]: " DEL_ROOT
    read -rp "Confirm removal? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" != "y" ]]; then
	info "Aborted. No changes made."
	exit 0
    fi

    # remove symlink and config
    rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
    rm -f "/etc/nginx/sites-available/${DOMAIN}"
    success "Virtual host config removed."

    # optionally remove document root
    if [[ "${DEL_ROOT,,}" == "y" ]]; then
	rm -rf "${DOC_ROOT}"
	success "Document root removed."
    else
	info "Document root kept at ${DOC_ROOT}."
    fi

    reload_nginx

    success "Virtual host '${DOMAIN}' removed."
}

# Step 6 — menu
echo ""
echo "${BOLD}${CYAN}nginx Web Server Manager${NC}"
echo ""
echo "  1) Add virtual host"
echo "  2) Remove virtual host"
echo "  3) List virtual hosts"
echo "  4) Exit"
echo ""
read -rp "Choice [1-4]: " CHOICE

case "${CHOICE}" in
    1) add_vhost ;;
    2) remove_vhost ;;
    3) list_vhosts ;;
    4) exit 0 ;;
    *) die "Invalid choice." ;;
esac