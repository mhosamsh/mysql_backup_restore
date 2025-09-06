#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIGURATION (env-overridable) ────────────────────────────────────────────
MYSQL_PUBLISHED_PORT="${MYSQL_PUBLISHED_PORT:-33066}"   # Host port the container might publish
MYSQL_INTERNAL_PORT="${MYSQL_INTERNAL_PORT:-3306}"      # MySQL port inside the container
MYSQL_USER="${MYSQL_USER:-root_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-change_me_very_strong}"
STACK_NS="${STACK_NS:-dwdm}"                             # Docker Stack namespace (fallback)
SERVICE_NAME="${SERVICE_NAME:-mysql}"                   # Service/container name (fallback)

# Path to the backup .tar.gz created by your backup script
BACKUP_TAR="${1:-}"
if [[ -z "$BACKUP_TAR" ]]; then
  echo "Usage: $0 </path/to/mysql_backup_YYYY.MM.DD.HH.MM.SS.tar.gz>"
  exit 1
fi
if [[ ! -f "$BACKUP_TAR" ]]; then
  echo "❌ Backup file not found: $BACKUP_TAR"
  exit 1
fi

# ─── FIND THE CONTAINER ─────────────────────────────────────────────────────────
echo "🔍 Locating MySQL container…"
CONTAINER_ID=$(docker ps \
  --filter "publish=${MYSQL_PUBLISHED_PORT}" \
  --filter "status=running" \
  -q)

if [[ -z "$CONTAINER_ID" ]]; then
  echo "⚠️  No container on port ${MYSQL_PUBLISHED_PORT}, falling back to stack/label lookup…"
  CONTAINER_ID=$(docker ps \
    --filter "label=com.docker.stack.namespace=${STACK_NS}" \
    --filter "name=${SERVICE_NAME}" \
    -q | head -n1)
fi

if [[ -z "$CONTAINER_ID" ]]; then
  echo "❌ Could not find any running MySQL container!"
  exit 1
fi
echo "✔️  Using container: $CONTAINER_ID"

# ─── UNPACK BACKUP ──────────────────────────────────────────────────────────────
RESTORE_ROOT=$(mktemp -d -t mysql_restore_XXXXXX)
echo "📦 Extracting $BACKUP_TAR to $RESTORE_ROOT …"
tar -xvzf "$BACKUP_TAR" -C "$RESTORE_ROOT"

# The tar contains a single top-level directory; detect it.
TOP_DIR=$(find "$RESTORE_ROOT" -maxdepth 1 -type d ! -path "$RESTORE_ROOT" | head -n1)
if [[ -z "$TOP_DIR" ]]; then
  echo "❌ Could not locate extracted directory inside archive"
  exit 1
fi

# ─── DISCOVER DATABASES ─────────────────────────────────────────────────────────
# DBs are identified by files named '<db>_schema.sql'
mapfile -t DB_SCHEMAS < <(find "$TOP_DIR" -maxdepth 1 -type f -name "*_schema.sql" | sort)
if [[ ${#DB_SCHEMAS[@]} -eq 0 ]]; then
  echo "❌ No *_schema.sql files found. Is this a valid backup?"
  exit 1
fi

echo "🗂  Databases found in backup:"
for schema_file in "${DB_SCHEMAS[@]}"; do
  db=$(basename "$schema_file")
  db="${db%_schema.sql}"
  echo "   • $db"
done

# ─── RESTORE LOOP ───────────────────────────────────────────────────────────────
for schema_file in "${DB_SCHEMAS[@]}"; do
  db=$(basename "$schema_file")
  db="${db%_schema.sql}"

  echo "🔧 Creating database if not exists: \`$db\`"
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" \
    -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"

  echo "📐 Restoring schema (routines/triggers/events) for \`$db\` …"
  docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$db" < "$schema_file"

  echo "📥 Importing tables for \`$db\` (temporarily disabling FK checks)…"
  docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$db" \
    -e "SET FOREIGN_KEY_CHECKS=0;"

  # Import all files matching '<db>_*.sql' except the schema file
  mapfile -t TABLE_FILES < <(find "$TOP_DIR" -maxdepth 1 -type f -name "${db}_*.sql" ! -name "${db}_schema.sql" | sort)
  for tf in "${TABLE_FILES[@]}"; do
    tbl_display=$(basename "$tf")
    echo "   • $tbl_display"
    docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
      mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$db" < "$tf"
  done

  docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$db" \
    -e "SET FOREIGN_KEY_CHECKS=1;"

  echo "✅ Finished restoring \`$db\`"
done

# ─── CLEAN UP ───────────────────────────────────────────────────────────────────
echo "🧹 Cleaning up $RESTORE_ROOT"
rm -rf "$RESTORE_ROOT"

echo "🎉 Restore completed successfully."
