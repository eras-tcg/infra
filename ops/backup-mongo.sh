#!/usr/bin/env bash
# Dump the production MongoDB (eras_db) to a gzip archive on the VPS and keep the last N days.
# Runs on the self-hosted runner. The URI is read from the prod DriveManager .env and never printed.
#
# Usage: backup-mongo.sh [retention_days]   (default 14)
set -euo pipefail

retention="${1:-14}"
env_file="/etc/drive-manager/.env"
dir="${BACKUP_DIR:-$HOME/backups/mongo}"
mkdir -p "$dir"; chmod 700 "$dir"

uri=$(grep -E '^MONGODB_URI=' "$env_file" | head -1 | cut -d= -f2-)
[ -n "$uri" ] || { echo "MONGODB_URI not found in $env_file" >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$dir/eras_db-$stamp.archive.gz"

# mongodump from the official image; the URI goes in through the environment, not the command line
docker run --rm --user "$(id -u):$(id -g)" -e MONGODB_URI="$uri" -v "$dir:/backup" mongo:7 \
  sh -c 'mongodump --uri "$MONGODB_URI" --gzip --archive=/backup/'"$(basename "$out")"' --quiet'

size=$(stat -c %s "$out")
[ "$size" -gt 1024 ] || { echo "backup too small ($size bytes), something is wrong" >&2; exit 1; }
chmod 600 "$out"
echo "backup ok: $(basename "$out") ($((size / 1024)) KiB)"

find "$dir" -name 'eras_db-*.archive.gz' -mtime +"$retention" -print -delete | sed 's/^/deleted old: /'
echo "backups kept: $(ls "$dir" | wc -l)"
