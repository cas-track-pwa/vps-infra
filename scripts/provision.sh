#!/usr/bin/env bash
# Provision Time Tracker + ITFlow on a fresh Debian 13 VPS (Tailscale-only).
# Mirrors docs/deployment.md. Idempotent enough to re-run after config changes.
#
# Usage:
#   cp .env.example .env && nano .env
#   sudo -E ./scripts/provision.sh
#
# ITFlow's own installer is interactive, so this installs everything else and
# installs the fork's API endpoint only if the ITFlow webroot already exists.
# If it does not, finish the ITFlow install (see docs/deployment.md) and run:
#   sudo -E ./itflow/install-endpoint.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo -E ./scripts/provision.sh" >&2
    exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    echo "missing $ENV_FILE (copy .env.example and fill it in)" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${TAILNET_NAME:?set TAILNET_NAME in .env}"
: "${TIME_TRACKER_REPO:?set TIME_TRACKER_REPO in .env}"
: "${JWT_SECRET:?set JWT_SECRET in .env}"
: "${BRIDGE_TOKEN:?set BRIDGE_TOKEN in .env}"
: "${ITFLOW_API_KEY:?set ITFLOW_API_KEY in .env}"

TRACKER_WEBROOT="${TRACKER_WEBROOT:-/srv/tracker}"
ITFLOW_WEBROOT="${ITFLOW_WEBROOT:-/var/www/itflow}"
ITFLOW_BACKEND="${ITFLOW_BACKEND:-http://127.0.0.1:8080}"
SYNC_DIR="${SYNC_DIR:-/opt/time-tracker/server}"
TIME_TRACKER_REF="${TIME_TRACKER_REF:-master}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step_base() {
    log "Base packages, firewall, timezone"
    apt-get update
    apt-get install -y curl git ufw unattended-upgrades ca-certificates sqlite3 php8.4-fpm
    ufw allow OpenSSH
    ufw --force enable
    timedatectl set-timezone UTC
}

step_ttsync_user() {
    log "Service user"
    id -u ttsync >/dev/null 2>&1 || adduser --system --group --home /opt/time-tracker ttsync
}

step_tailscale() {
    log "Tailscale"
    command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
    if ! tailscale status >/dev/null 2>&1; then
        echo "Run 'sudo tailscale up' and complete auth, and enable MagicDNS + HTTPS in the admin console."
        tailscale up
    fi
}

step_node() {
    log "Node.js 22"
    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
    fi
}

step_sync() {
    log "Sync service"
    if [[ ! -d /opt/time-tracker/.git ]]; then
        sudo -u ttsync git clone --branch "$TIME_TRACKER_REF" "$TIME_TRACKER_REPO" /opt/time-tracker
    else
        sudo -u ttsync git -C /opt/time-tracker fetch --all
        sudo -u ttsync git -C /opt/time-tracker checkout "$TIME_TRACKER_REF"
        sudo -u ttsync git -C /opt/time-tracker pull --ff-only || true
    fi

    ( cd "$SYNC_DIR" && sudo -u ttsync npm ci --omit=dev )

    umask 077
    cat > "$SYNC_DIR/.env" <<EOF
JWT_SECRET=$JWT_SECRET
FALLBACK_ALLOWED_USERS=${FALLBACK_ALLOWED_USERS:-'[]'}
PORT=${PORT:-8787}
DB_PATH=$SYNC_DIR/data/tt.sqlite
EOF
    chown ttsync:ttsync "$SYNC_DIR/.env"

    sudo -u ttsync sh -c "cd '$SYNC_DIR' && npm run init-db"

    install -o root -g root -m 644 "$REPO_DIR/systemd/tt-sync.service" /etc/systemd/system/tt-sync.service
    systemctl daemon-reload
    systemctl enable --now tt-sync
    systemctl restart tt-sync
    sleep 1
    curl -fsS "http://127.0.0.1:${PORT:-8787}/health" && echo
}

step_tracker() {
    log "Tracker PWA + bridge"
    rm -rf "$TRACKER_WEBROOT"
    mkdir -p "$TRACKER_WEBROOT"
    cp -r /opt/time-tracker/public/. "$TRACKER_WEBROOT/"
    install -o www-data -g www-data -m 644 \
        /opt/time-tracker/integrations/bridge/itflow_create_invoice.php \
        "$TRACKER_WEBROOT/itflow_create_invoice.php"

    sed \
        -e "s|__ITFLOW_API_KEY__|$ITFLOW_API_KEY|g" \
        -e "s|__BRIDGE_TOKEN__|$BRIDGE_TOKEN|g" \
        -e "s|__DEFAULT_CATEGORY_ID__|${DEFAULT_CATEGORY_ID:-0}|g" \
        "$REPO_DIR/tracker/config.php.example" > "$TRACKER_WEBROOT/config.php"
    chown www-data:www-data "$TRACKER_WEBROOT/config.php"
    chmod 640 "$TRACKER_WEBROOT/config.php"
    chown -R www-data:www-data "$TRACKER_WEBROOT"

    # Same-origin API: point the client at /api/* behind Caddy.
    sed -i "s|const API_BASE = 'https://time-tracker.alexs-cas.workers.dev';|const API_BASE = '';|" "$TRACKER_WEBROOT/app.js"
    grep -q "const API_BASE = '';" "$TRACKER_WEBROOT/app.js" \
        || echo "WARN: API_BASE not rewritten; update app.js manually and bump sw.js CACHE_NAME"
}

step_caddy() {
    log "Caddy + tailscale module"
    if ! command -v caddy >/dev/null 2>&1; then
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update && apt-get install -y caddy
    fi

    if ! caddy list-modules 2>/dev/null | grep -q '^dns.providers.tailscale$'; then
        apt-get install -y golang-go
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
        "$(go env GOPATH)/bin/xcaddy" build --with github.com/tailscale/caddy-tailscale --output /usr/bin/caddy
    fi

    sed "s|{{TAILNET_NAME}}|$TAILNET_NAME|g" "$REPO_DIR/caddy/Caddyfile" > /etc/caddy/Caddyfile
    systemctl enable caddy
    systemctl restart caddy
}

step_itflow_endpoint() {
    if [[ -d "$ITFLOW_WEBROOT/api/v1" ]]; then
        log "ITFlow invoice-create endpoint"
        ITFLOW_WEBROOT="$ITFLOW_WEBROOT" ITFLOW_REPO="$ITFLOW_REPO" ITFLOW_REF="$ITFLOW_REF" \
            "$REPO_DIR/itflow/install-endpoint.sh"
    else
        log "ITFlow not found at $ITFLOW_WEBROOT"
        cat <<'EOF'
Install ITFlow first (see docs/deployment.md), then run:
    sudo -E ./itflow/install-endpoint.sh
and create an API key in ITFlow: Admin > API.
EOF
    fi
}

main() {
    step_base
    step_ttsync_user
    step_tailscale
    step_node
    step_sync
    step_tracker
    step_caddy
    step_itflow_endpoint
    log "Done. Verify with ./scripts/healthcheck.sh"
}

# With no arguments run everything; otherwise run only the named steps, e.g.
#   sudo -E ./scripts/provision.sh sync tracker
if [[ $# -gt 0 ]]; then
    for step in "$@"; do
        case "$step" in
            base) step_base ;;
            user) step_ttsync_user ;;
            tailscale) step_tailscale ;;
            node) step_node ;;
            sync) step_sync ;;
            tracker) step_tracker ;;
            caddy) step_caddy ;;
            itflow) step_itflow_endpoint ;;
            *) echo "unknown step: $step" >&2; exit 1 ;;
        esac
    done
    exit 0
fi

main "$@"
