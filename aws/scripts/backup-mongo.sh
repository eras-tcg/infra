#!/bin/bash
# backup-mongo.sh: dumps the production database to the backups bucket by running eras-backup on the server
# (starting it if it sleeps; Atlas only lets in the server's address). Called daily by
# .github/workflows/backup-mongo.yml; the bucket keeps each dump 30 days.
set -euo pipefail
exec bash "$(dirname "$0")/server-run.sh" eras-backup
