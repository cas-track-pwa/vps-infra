#!/usr/bin/env bash
# Installs the invoice-create API endpoint from the ITFlow fork into the ITFlow
# webroot. Run after ITFlow itself is installed.
#
# Usage: ITFLOW_WEBROOT=/var/www/itflow ITFLOW_REF=invoice-create-api \
#        ITFLOW_REPO=https://github.com/cas-track-pwa/itflow.git \
#        sudo -E ./install-endpoint.sh
set -euo pipefail

ITFLOW_WEBROOT="${ITFLOW_WEBROOT:-/var/www/itflow}"
ITFLOW_REPO="${ITFLOW_REPO:?set ITFLOW_REPO}"
ITFLOW_REF="${ITFLOW_REF:-invoice-create-api}"

if [[ $EUID -ne 0 ]]; then
    echo "run as root (sudo -E)" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone --depth 1 --branch "$ITFLOW_REF" "$ITFLOW_REPO" "$workdir/itflow"
install -o www-data -g www-data -m 644 \
    "$workdir/itflow/api/v1/invoices/create.php" \
    "$ITFLOW_WEBROOT/api/v1/invoices/create.php"

echo "Installed create.php into $ITFLOW_WEBROOT/api/v1/invoices/"
