#!/usr/bin/env bash
set -euo pipefail

# ── Load secrets ──────────────────────────────────────────────
#AI: source project-specific env after pipeline.env loads
source "$(dirname "$0")/../secrets/keycloak.env"

# ── Backup directory setup ────────────────────────────────────
BACKUP_BASE="${BACKUPS:-~/backups}/keycloak"
DAY="$(date +%d)"
BACKUP_FILE="$BACKUP_BASE/keycloak-$DAY.tar.gz.gpg"

# create backup directory if needed
mkdir -p "$BACKUP_BASE"

# ── Temporary workspace ──────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Dump Postgres database ───────────────────────────────────
echo "Dumping Postgres DB..."
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" keycloak-postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  > "$TMPDIR/db.sql"

# ── Archive Keycloak data volume ──────────────────────────────
echo "Archiving Keycloak data volume..."
docker run --rm \
  -v keycloak_data:/data \
  -v "$TMPDIR":/backup \
  busybox \
  tar cf /backup/data.tar -C /data .

# ── Combine & compress ───────────────────────────────────────
echo "Creating combined archive..."
tar czf "$TMPDIR/backup.tar.gz" -C "$TMPDIR" db.sql data.tar

# ── Encrypt with GPG ─────────────────────────────────────────
echo "Encrypting backup to $BACKUP_FILE..."
gpg --batch --yes --output "$BACKUP_FILE" \
    --encrypt --recipient "$GPG_RECIPIENT" \
    "$TMPDIR/backup.tar.gz"

# ── Done ─────────────────────────────────────────────────────
echo "Backup completed: $BACKUP_FILE"
