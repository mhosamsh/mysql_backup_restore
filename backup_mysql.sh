#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIGURATION (env-overridable) ────────────────────────────────────────────
MYSQL_PUBLISHED_PORT="${MYSQL_PUBLISHED_PORT:-33066}"
MYSQL_INTERNAL_PORT="${MYSQL_INTERNAL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-change_me_very_strong}"
STACK_NS="${STACK_NS:-dwdm}"
SERVICE_NAME="${SERVICE_NAME:-mysql}"
BACKUP_ROOT="${BACKUP_ROOT:-.}"

# Excluded DBs by default
EXCLUDED="${EXCLUDED:-performance_db information_schema mysql sys performance_schema}"

# ─── PREPARE ────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y.%m.%d.%H.%M.%S)
BACKUP_DIR="${BACKUP_ROOT}/mysql_backup_${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

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

# ─── GET DATABASE LIST ──────────────────────────────────────────────────────────
echo "🎯 Retrieving database list…"
DATABASES=$(docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
  mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" \
  -Nse "SHOW DATABASES;")

for db in $DATABASES; do
  if [[ " $EXCLUDED " =~ " $db " ]]; then
    echo "⏭ Skipping $db"
    continue
  fi

  echo "📦 Backing up database: $db"

  # ─── DUMP SCHEMA ──────────────────────────────────────────────────────────────
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysqldump -u"$MYSQL_USER" \
      -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" \
      --no-data \
      --routines --triggers --events \
      --set-gtid-purged=OFF \
      "$db" > "${BACKUP_DIR}/${db}_schema.sql"

  # ─── GET TABLES ───────────────────────────────────────────────────────────────
  TABLES=$(docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" \
    -Nse "SHOW TABLES IN \`${db}\`;")

  # ─── DUMP TABLES ──────────────────────────────────────────────────────────────
  for tbl in $TABLES; do
    echo "   • $db.$tbl"
    docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
      mysqldump -u"$MYSQL_USER" \
        -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" \
        --single-transaction \
        --set-gtid-purged=OFF \
        "$db" "$tbl" > "${BACKUP_DIR}/${db}_${tbl}.sql"
  done
done

# ─── PACKAGE EVERYTHING ──────────────────────────────────────────────────────────
TAR_NAME="mysql_backup_${TIMESTAMP}.tar.gz"
echo "📦 Creating archive: ${BACKUP_ROOT}/${TAR_NAME}…"
tar -cvzf "${BACKUP_ROOT}/${TAR_NAME}" -C "${BACKUP_ROOT}" "$(basename "$BACKUP_DIR")"

# ─── CLEAN UP ───────────────────────────────────────────────────────────────────
rm -rf "$BACKUP_DIR"
echo "✅ Backup complete: ${BACKUP_ROOT}/${TAR_NAME}"
