#!/usr/bin/env bash
# Backs up the three stateful pieces and optionally ships them to object storage.
#
#   sudo -E ./scripts/backup.sh
#
# Configure the offsite push by exporting one of:
#   RESTIC_REPOSITORY + RESTIC_PASSWORD   (restic, e.g. B2 via rclone: b2:bucket:path)
#   RCLONE_DEST                           (e.g. b2:bucket:vps-backups)
# If neither is set, artifacts are left in $BACKUP_DIR.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
STAMP="$(date +%F_%H%M%S)"
DEST="$BACKUP_DIR/$STAMP"
SYNC_DB="${SYNC_DB:-/opt/time-tracker/server/data/tt.sqlite}"
ITFLOW_DB="${ITFLOW_DB:-itflow}"
ITFLOW_UPLOADS="${ITFLOW_UPLOADS:-/var/www/itflow/uploads}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo -E ./scripts/backup.sh" >&2
    exit 1
fi

mkdir -p "$DEST"

echo "==> SQLite snapshot (consistent, via .backup)"
if [[ -f "$SYNC_DB" ]]; then
    sqlite3 "$SYNC_DB" ".backup '$DEST/tt.sqlite'"
fi

echo "==> MariaDB dump"
if command -v mariadb-dump >/dev/null 2>&1; then
    mariadb-dump --single-transaction --routines --events "$ITFLOW_DB" | gzip > "$DEST/$ITFLOW_DB.sql.gz"
fi

echo "==> ITFlow uploads"
if [[ -d "$ITFLOW_UPLOADS" ]]; then
    tar -czf "$DEST/itflow-uploads.tar.gz" -C "$(dirname "$ITFLOW_UPLOADS")" "$(basename "$ITFLOW_UPLOADS")"
fi

echo "Artifacts in $DEST"

if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
    echo "==> restic backup"
    restic backup "$DEST"
    restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
elif [[ -n "${RCLONE_DEST:-}" ]]; then
    echo "==> rclone copy"
    rclone copy "$DEST" "$RCLONE_DEST/$STAMP"
else
    echo "No RESTIC_REPOSITORY or RCLONE_DEST set; leaving local artifacts only."
fi

echo "==> Pruning local backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} +
