#!/usr/bin/env bash
# Smoke-checks the local services. Exit non-zero if anything is down.
#
#   ./scripts/healthcheck.sh
#
# Set TRACKER_URL to also check the PWA and bridge through Caddy, e.g.
#   TRACKER_URL=https://tracker.<tailnet> ./scripts/healthcheck.sh
set -uo pipefail

PORT="${PORT:-8787}"
ITFLOW_URL="${ITFLOW_URL:-http://127.0.0.1:8080}"
TRACKER_URL="${TRACKER_URL:-}"
fail=0

check() {
    local name="$1" url="$2"
    if curl -fsS -o /dev/null -m 5 "$url"; then
        echo "ok    $name ($url)"
    else
        echo "FAIL  $name ($url)"
        fail=1
    fi
}

check "sync /health" "http://127.0.0.1:$PORT/health"
check "itflow" "$ITFLOW_URL/"

if [[ -n "$TRACKER_URL" ]]; then
    check "tracker pwa" "$TRACKER_URL/"

    # The bridge answers 401 without a token; any response means it is alive.
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "$TRACKER_URL/itflow_create_invoice.php" || echo 000)"
    if [[ "$code" == "401" || "$code" == "200" ]]; then
        echo "ok    bridge (HTTP $code)"
    else
        echo "FAIL  bridge (HTTP $code)"
        fail=1
    fi
else
    echo "skip  tracker/bridge (set TRACKER_URL to enable)"
fi

exit "$fail"
