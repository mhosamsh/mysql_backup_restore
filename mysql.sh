#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────── CONFIG (overridable via env/CLI) ─────────────────────
MYSQL_PUBLISHED_PORT="${MYSQL_PUBLISHED_PORT:-33066}"
MYSQL_INTERNAL_PORT="${MYSQL_INTERNAL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-change_me_very_strong}"
STACK_NS="${STACK_NS:-dwdm}"
SERVICE_NAME="${SERVICE_NAME:-mysql}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/mysql-backup/backupfiles}"

# Excluded by default when using --all (or interactive option 1)
EXCLUDE_DBS_DEFAULT="performance_db information_schema mysql sys performance_schema"

# Parallel table dumps (per DB). 1 = sequential
JOBS="${JOBS:-1}"

# ─────────────────────────────── Helpers ────────────────────────────────────────
log() { printf "%s\n" "$*" >&2; }
die() { log "❌ $*"; exit 1; }
timestamp() { date +%Y.%m.%d.%H.%M.%S; }

usage() {
  cat <<EOF
mysql_backup_restore.sh - Integrated MySQL backup & restore (Docker aware)

BACKUP:
  $(basename "$0") backup [--all] [--db db1,db2,...] [--include performance_db] [--out DIR] [--jobs N] [-v]

RESTORE:
  $(basename "$0") restore --file /path/to/backup.tar.gz
                        [--skip-db db1,db2,...] [--only-db db1,db2,...]
                        [--skip-table db.tbl,db2.tbl2,...] [--only-table db.tbl,...]
                        [-v]

FLAGS:
  --all                       Backup all DBs except default excluded list
  --db list                   Backup only these DBs (comma-separated, unlimited)
  --include performance_db    Include performance_db in backup
  --out DIR                   Output directory (default: ${BACKUP_ROOT})
  --jobs N                    Parallel table dumps per DB (default: ${JOBS})
  --skip-db list              (restore) Skip these DBs
  --only-db list              (restore) Restore only these DBs
  --skip-table list           (restore) Skip these fully-qualified tables (db.table)
  --only-table list           (restore) Restore only these fully-qualified tables
  -v                          Verbose
  -h, --help                  Show help

INTERACTIVE (run with no args):
  1) Backup (default: exclude performance_db)
  2) Backup (pick one or MANY DBs)
  3) Restore (all or with skip/only filters)
  4) Quit

Notes:
- Schema files contain DDL (tables, routines, triggers, events).
- Table files are DATA ONLY (INSERTs), no CREATE TABLE or triggers.
- Dumps use --set-gtid-purged=OFF and --single-transaction for tables.
- Default excludes: ${EXCLUDE_DBS_DEFAULT}
EOF
}

find_container() {
  local cid

  # 1) Prefer Swarm service label (exact service)
  cid=$(docker ps \
    --filter "label=com.docker.swarm.service.name=${STACK_NS}_${SERVICE_NAME}" \
    --filter "status=running" \
    -q | head -n1)

  # 2) Fallback to published port (non-swarm / custom setups)
  if [[ -z "$cid" ]]; then
    log "⚠️  No container with service label ${STACK_NS}_${SERVICE_NAME}, falling back to port ${MYSQL_PUBLISHED_PORT}…"
    cid=$(docker ps \
      --filter "publish=${MYSQL_PUBLISHED_PORT}" \
      --filter "status=running" \
      -q | head -n1)
  fi

  [[ -n "$cid" ]] || die "Could not find any running MySQL container (service ${STACK_NS}_${SERVICE_NAME})!"
  echo "$cid"
}

mysql_exec() {
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$@"
}

mysqldump_exec() {
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
    mysqldump -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$@"
}

list_databases() {
  mysql_exec -Nse "SHOW DATABASES;"
}

# list logic helpers
list_to_set() {
  # normalize commas, trim spaces -> newline set
  echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF'
}

in_set() {
  # $1=item, $2=set (newline separated)
  local needle="$1" set="$2"
  printf "%s\n" "$set" | awk -v n="$needle" 'BEGIN{f=0} $0==n{f=1} END{exit !f}'
}

fq_match() {
  # exact match for fully-qualified db.table
  local item="$1" set="$2"
  in_set "$item" "$set"
}

# ─────────────────────────────── Backup ─────────────────────────────────────────
do_backup() {
  local selected_dbs exclude_list include_perf out_dir jobs verbose
  selected_dbs="${1:-}"   # comma-separated or empty
  exclude_list="$2"
  include_perf="$3"       # yes/no
  out_dir="$4"
  jobs="$5"
  verbose="$6"

  [[ "$include_perf" == "yes" ]] && exclude_list="${exclude_list//performance_db/}"

  local ts dir tarname
  ts=$(timestamp)
  dir="${out_dir}/mysql_backup_${ts}"
  mkdir -p "$dir"
  $verbose && log "📂 Backup directory: $dir"

  CONTAINER_ID=$(find_container)
  $verbose && log "✔️  Using container: $CONTAINER_ID"

  local dbs
  if [[ -n "$selected_dbs" ]]; then
    dbs="$(list_to_set "$selected_dbs" | tr '\n' ' ')"
  else
    dbs="$(list_databases)"
  fi

  local excluded=" $(echo "$exclude_list" | tr ' ' '\n' | awk 'NF' | tr '\n' ' ') "
  local final_dbs=()
  for db in $dbs; do
    [[ -z "$db" ]] && continue
    if [[ -z "$selected_dbs" ]]; then
      if [[ "$excluded" =~ \ $db\  ]]; then
        $verbose && log "⏭ Skipping $db"
        continue
      fi
    fi
    final_dbs+=("$db")
  done

  [[ ${#final_dbs[@]} -gt 0 ]] || die "No databases to back up."

  for db in "${final_dbs[@]}"; do
    log "📦 Backing up database: $db"

    # SCHEMA ONLY: tables, routines, triggers, events
    mysqldump_exec \
      --no-data \
      --routines \
      --triggers \
      --events \
      --set-gtid-purged=OFF \
      "$db" > "${dir}/${db}_schema.sql"

    # DATA ONLY per table (no CREATE TABLE, no triggers)
    mapfile -t tables < <(mysql_exec -Nse "SHOW TABLES IN \`${db}\`;")
    if [[ ${#tables[@]} -eq 0 ]]; then
      $verbose && log "   (no tables)"
      continue
    fi

    if [[ "$jobs" -gt 1 ]]; then
      sem_n=0
      for tbl in "${tables[@]}"; do
        $verbose && log "   • $db.$tbl (queued)"
        (
          mysqldump_exec \
            --single-transaction \
            --no-create-info \
            --skip-triggers \
            --set-gtid-purged=OFF \
            "$db" "$tbl" > "${dir}/${db}_${tbl}.sql"
        ) &
        (( sem_n++ ))
        if (( sem_n >= jobs )); then
          wait -n
          (( sem_n-- ))
        fi
      done
      wait
    else
      for tbl in "${tables[@]}"; do
        $verbose && log "   • $db.$tbl"
        mysqldump_exec \
          --single-transaction \
          --no-create-info \
          --skip-triggers \
          --set-gtid-purged=OFF \
          "$db" "$tbl" > "${dir}/${db}_${tbl}.sql"
      done
    fi
  done

  tarname="mysql_backup_${ts}.tar.gz"
  log "📦 Creating archive: ${out_dir}/${tarname}…"
  tar -cvzf "${out_dir}/${tarname}" -C "${out_dir}" "$(basename "$dir")"
  rm -rf "$dir"
  log "✅ Backup complete: ${out_dir}/${tarname}"
}

# ─────────────────────────────── Restore ────────────────────────────────────────
do_restore() {
  local tarfile="$1" verbose="$2" skip_db_list="$3" only_db_list="$4" \
        skip_tbl_list="$5" only_tbl_list="$6"

  [[ -f "$tarfile" ]] || die "Backup file not found: $tarfile"

  CONTAINER_ID=$(find_container)
  $verbose && log "✔️  Using container: $CONTAINER_ID"

  local tmp; tmp=$(mktemp -d -t mysql_restore_XXXXXX)
  log "📦 Extracting $tarfile to $tmp …"
  tar -xvzf "$tarfile" -C "$tmp"

  local top; top=$(find "$tmp" -maxdepth 1 -type d ! -path "$tmp" | head -n1)
  [[ -n "$top" ]] || die "Could not locate extracted directory inside archive"

  mapfile -t schemas < <(find "$top" -maxdepth 1 -type f -name "*_schema.sql" | sort)
  [[ ${#schemas[@]} -gt 0 ]] || die "No *_schema.sql files found. Is this a valid backup?"

  # Normalize lists
  local SKIP_DB_SET ONLY_DB_SET SKIP_TBL_SET ONLY_TBL_SET
  SKIP_DB_SET="$(list_to_set "$skip_db_list")"
  ONLY_DB_SET="$(list_to_set "$only_db_list")"
  SKIP_TBL_SET="$(list_to_set "$skip_tbl_list")"
  ONLY_TBL_SET="$(list_to_set "$only_tbl_list")"

  log "🗂  Databases present in archive:"
  for f in "${schemas[@]}"; do
    bn=$(basename "$f"); db="${bn%_schema.sql}"
    log "   • $db"
  done

  for schema_file in "${schemas[@]}"; do
    bn=$(basename "$schema_file"); db="${bn%_schema.sql}"

    # DB-level filtering
    if [[ -n "$ONLY_DB_SET" ]] && ! in_set "$db" "$ONLY_DB_SET"; then
      $verbose && log "⏭ (only-db) Skipping DB $db"
      continue
    fi
    if [[ -n "$SKIP_DB_SET" ]] && in_set "$db" "$SKIP_DB_SET"; then
      $verbose && log "⏭ (skip-db) Skipping DB $db"
      continue
    fi

    log "🔧 Ensuring database exists: \`$db\`"
    mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"

    log "📐 Restoring schema for \`$db\` …"
    docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
      mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$db" < "$schema_file"

    log "📥 Importing tables for \`$db\` (temporarily disabling FK checks)…"
    mysql_exec "$db" -e "SET FOREIGN_KEY_CHECKS=0;"

    mapfile -t tfs < <(find "$top" -maxdepth 1 -type f -name "${db}_*.sql" ! -name "${db}_schema.sql" | sort)

    for tf in "${tfs[@]}"; do
      tbn=$(basename "$tf")
      tbl="${tbn#${db}_}"; tbl="${tbl%.sql}"
      fq="${db}.${tbl}"

      # Table-level filtering
      if [[ -n "$ONLY_TBL_SET" ]] && ! fq_match "$fq" "$ONLY_TBL_SET"; then
        $verbose && log "   ⏭ (only-table) $fq"
        continue
      fi
      if [[ -n "$SKIP_TBL_SET" ]] && fq_match "$fq" "$ONLY_TBL_SET"; then
        $verbose && log "   ⏭ (skip-table) $fq"
        continue
      fi

      $verbose && log "   • Importing $fq"
      docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" "$CONTAINER_ID" \
        mysql -u"$MYSQL_USER" -h127.0.0.1 -P"$MYSQL_INTERNAL_PORT" "$db" < "$tf"
    done

    mysql_exec "$db" -e "SET FOREIGN_KEY_CHECKS=1;"
    log "✅ Finished restoring \`$db\`"
  done

  rm -rf "$tmp"
  log "🎉 Restore completed."
}

# ─────────────────────────────── Interactive UI ─────────────────────────────────
interactive_backup_all() {
  read -rp "Output directory [${BACKUP_ROOT}]: " ans; out="${ans:-$BACKUP_ROOT}"
  read -rp "Parallel jobs per DB (1=no parallel) [${JOBS}]: " j; jv="${j:-$JOBS}"
  do_backup "" "$EXCLUDE_DBS_DEFAULT" "no" "$out" "$jv" "true"
}

interactive_backup_pick_many() {
  CONTAINER_ID=$(find_container)
  mapfile -t dbs < <(list_databases)

  echo "Available DBs (enter numbers, comma or ranges like 1,3-5,10):"
  for i in "${!dbs[@]}"; do printf "%2d) %s\n" "$((i+1))" "${dbs[$i]}"; done
  read -rp "Select: " picks

  # expand ranges
  expand_nums() {
    local IFS=',' part
    for part in $1; do
      if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      else
        echo "$part"
      fi
    done
  }
  sel=""
  while read -r n; do
    [[ -z "$n" ]] && continue
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    idx=$((n-1))
    [[ $idx -ge 0 && $idx -lt ${#dbs[@]} ]] && sel+="${dbs[$idx]},"
  done < <(expand_nums "$picks")
  sel="${sel%,}"  # trim trailing comma

  read -rp "Include performance_db? [y/N]: " ip; ipf="no"; [[ "$ip" =~ ^[Yy]$ ]] && ipf="yes"
  read -rp "Output directory [${BACKUP_ROOT}]: " ans; out="${ans:-$BACKUP_ROOT}"
  read -rp "Parallel jobs per DB (1=no parallel) [${JOBS}]: " j; jv="${j:-$JOBS}"
  do_backup "$sel" "$EXCLUDE_DBS_DEFAULT" "$ipf" "$out" "$jv" "true"
}

interactive_restore() {
  read -rp "Path to backup tar.gz: " tarf
  echo "Restore scope:"
  echo "  1) Restore ALL (no skips)"
  echo "  2) Restore with filters (skip/only DBs/tables)"
  read -rp "Choose: " rch

  case "$rch" in
    1) do_restore "$tarf" "true" "" "" "" "" ;;
    2)
      read -rp "only DBs (comma list, blank=none): " onlydb
      read -rp "skip DBs (comma list, blank=none): " skipdb
      read -rp "only tables (db.tbl,db2.tbl2; blank=none): " onlytbl
      read -rp "skip tables (db.tbl,db2.tbl2; blank=none): " skiptbl
      do_restore "$tarf" "true" "$skipdb" "$onlydb" "$skiptbl" "$onlytbl"
      ;;
    *) echo "Cancelled."; exit 0;;
  esac
}

# ─────────────────────────────── CLI Parse ──────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "== MySQL Backup/Restore =="
  echo "1) Backup (default: exclude performance_db)"
  echo "2) Backup (pick one or MANY DBs)"
  echo "3) Restore (all or with skip/only filters)"
  echo "4) Quit"
  read -rp "Select: " choice
  case "$choice" in
    1) interactive_backup_all ;;
    2) interactive_backup_pick_many ;;
    3) interactive_restore ;;
    *) echo "Bye."; exit 0;;
  esac
  exit 0
fi

cmd="${1:-}"; shift || true
case "$cmd" in
  -h|--help) usage; exit 0;;
  backup)
    all=no; dbs=""; include_perf=no; out="${BACKUP_ROOT}"; verbose=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --all) all=yes ;;
        --db) shift; dbs="${1:-}" ;;
        --include) shift; [[ "${1:-}" == "performance_db" ]] && include_perf=yes ;;
        --out) shift; out="${1:-$out}" ;;
        --jobs) shift; JOBS="${1:-$JOBS}" ;;
        -v) verbose=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
      esac; shift || true
    done
    if [[ "$all" == "yes" && -n "$dbs" ]]; then
      die "Use either --all or --db, not both."
    fi
    do_backup "$dbs" "$EXCLUDE_DBS_DEFAULT" "$include_perf" "$out" "$JOBS" "$verbose"
    ;;
  restore)
    verbose=false; tarfile=""
    skip_db=""; only_db=""; skip_tbl=""; only_tbl=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) shift; tarfile="${1:-}" ;;
        --skip-db) shift; skip_db="${1:-}" ;;
        --only-db) shift; only_db="${1:-}" ;;
        --skip-table) shift; skip_tbl="${1:-}" ;;
        --only-table) shift; only_tbl="${1:-}" ;;
        -v) verbose=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
      esac; shift || true
    done
    [[ -n "$tarfile" ]] || die "Use: restore --file /path/to/backup.tar.gz"
    do_restore "$tarfile" "$verbose" "$skip_db" "$only_db" "$skip_tbl" "$only_tbl"
    ;;
  *)
    usage; exit 1;;
esac
