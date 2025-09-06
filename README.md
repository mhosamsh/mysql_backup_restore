# MySQL Backup & Restore (Docker/Swarm-aware)

This repo contains three Bash scripts that safely back up and restore MySQL databases **running inside Docker (including Swarm)**. They autodetect the MySQL container, dump schemas and tables, and package everything into a single archive. Environment is configured via a `.env` file (no credentials hardcoded in scripts).

## Scripts

- `mysql.sh` — **Integrated CLI + interactive** tool for backups & restores (recommended).
- `backup_mysql.sh` — Simple one-shot backup helper (legacy).
- `restore_mysql.sh` — Simple one-shot restore helper (legacy).

> All scripts are **read-only** to the database (except during restore) and use `--single-transaction` for consistent table dumps (InnoDB).

---

## Features

- 🚢 **Docker/Swarm aware**: finds the running MySQL container by published port or stack labels.
- 🧱 **Schema + table dumps**: schemas (DDL, routines, triggers, events) + each table as its own file.
- 🧳 **Tarball packaging**: outputs `mysql_backup_YYYY.MM.DD.HH.MM.SS.tar.gz`.
- 🪫 **Excludes noisy DBs** by default: `information_schema mysql sys performance_schema performance_db`.
- 🧵 **Parallel dumps** per DB using `--jobs N` (set to `1` by default).
- 🧪 **Selective restore**: restore everything or only/skip specific DBs or individual tables.
- 🔐 **.env-driven**: no inline credentials/IPs; override via environment when needed.

---

## Requirements

- Linux host with **Bash 4+**
- **Docker CLI** access to the host running the MySQL container
- The MySQL container must be **running**

---

## Setup

1) **Copy the scripts** and make them executable:

```bash
chmod +x mysql.sh backup_mysql.sh restore_mysql.sh
```

2) **Create your environment file** from the sample and edit it:

```bash
cp .env.example .env
nano .env
```

3) **Load env vars when running** (choose one pattern):

- Export for current shell:
  ```bash
  set -a; source .env; set +a
  ./mysql.sh
  ```

- Or inject vars for a single command (no shell pollution):
  ```bash
  env $(grep -v '^#' .env | xargs) ./mysql.sh backup --all --out /var/backups/mysql
  ```

> The scripts already read values from the environment and have sensible defaults.

---

## Quick start (Interactive)

```bash
./mysql.sh
# 1) Backup (exclude performance_db by default)
# 2) Backup (pick one or MANY DBs)
# 3) Restore (all or with skip/only filters)
# 4) Quit
```

- The backup creates a timestamped tarball in the directory you choose.
- The restore asks for a `*.tar.gz` created by the backup and lets you filter scope.

---

## Backup (CLI examples)

### 1) Backup **all** except default excludes
```bash
./mysql.sh backup --all --out /var/backups/mysql
```

### 2) Backup **specific DBs**
```bash
./mysql.sh backup --db alarm_db,service_manager_db --out /var/backups/mysql
```

### 3) Include `performance_db` (normally excluded)
```bash
./mysql.sh backup --all --include performance_db --out /var/backups/mysql
```

### 4) Use **parallel table dumps** (per DB)
```bash
./mysql.sh backup --all --jobs 4 --out /var/backups/mysql
```

**Output**
- Working directory: `mysql_backup_YYYY.MM.DD.HH.MM.SS/`
  - `DB_schema.sql` (DDL, routines, triggers, events)
  - `DB_table.sql` per table
- Archive: `mysql_backup_YYYY.MM.DD.HH.MM.SS.tar.gz`

---

## Restore (CLI examples)

> The restore re-creates DBs if needed, imports schema first, then tables. Foreign keys are temporarily disabled per DB during imports.

### 1) Restore **everything** from a tarball
```bash
./mysql.sh restore --file /var/backups/mysql/mysql_backup_2025.09.06.10.05.55.tar.gz
```

### 2) Restore **only selected DBs**
```bash
./mysql.sh restore --file /path/backup.tar.gz --only-db alarm_db,service_manager_db
```

### 3) Restore **all except** some DBs
```bash
./mysql.sh restore --file /path/backup.tar.gz --skip-db performance_db
```

### 4) Restore **only certain tables**
```bash
./mysql.sh restore --file /path/backup.tar.gz   --only-table alarm_db.alarm_config,service_manager_db.users
```

### 5) Skip a heavy table (example)
```bash
./mysql.sh restore --file /path/backup.tar.gz --skip-table alarm_db.big_audit_log
```

---

## One-shot Helpers (legacy but useful)

### backup_mysql.sh
```bash
# Uses .env values; writes tar.gz to BACKUP_ROOT (or current dir if unset)
env $(grep -v '^#' .env | xargs) ./backup_mysql.sh
```

### restore_mysql.sh
```bash
# Provide the tarball path as the first arg
env $(grep -v '^#' .env | xargs) ./restore_mysql.sh /var/backups/mysql/mysql_backup_2025.09.06.10.05.55.tar.gz
```

---

## Environment (.env)

See `.env.example` and adjust. Variables (all optional; the scripts have defaults):

| Variable              | Purpose                                                                              | Example                          |
|-----------------------|--------------------------------------------------------------------------------------|----------------------------------|
| `MYSQL_PUBLISHED_PORT`| Host-published port used to locate the container (fallback to labels if not found)   | `33066`                          |
| `MYSQL_INTERNAL_PORT` | MySQL port **inside** the container                                                  | `3306`                           |
| `MYSQL_USER`          | MySQL user for dumps/restores                                                        | `root_user`                      |
| `MYSQL_PASSWORD`      | MySQL password                                                                       | `change_me_very_strong`          |
| `STACK_NS`            | Swarm stack namespace label (fallback discovery)                                     | `dwdm`                           |
| `SERVICE_NAME`        | Service/container name filter (fallback discovery)                                   | `mysql`                          |
| `BACKUP_ROOT`         | Directory to write backups to                                                        | `/var/backups/mysql`             |
| `JOBS`                | Parallel table dumps per DB during backup                                            | `4`                              |

**Discovery order** for the MySQL container:
1. Running container that **publishes** `MYSQL_PUBLISHED_PORT`
2. First running container matching labels: `com.docker.stack.namespace=${STACK_NS}` and `name~=${SERVICE_NAME}`

---

## Cron Example (daily backup & 7-day retention)

```cron
# Edit via: crontab -e
# Daily at 03:30, keep 7 days of archives
30 3 * * * cd /opt/mysql-backup && set -a; . ./.env; set +a;   ./mysql.sh backup --all --jobs "${JOBS:-2}" --out "${BACKUP_ROOT:-/var/backups/mysql}" >> /var/log/mysql_backup.log 2>&1

# Prune archives older than 7 days
0 4 * * * find "${BACKUP_ROOT:-/var/backups/mysql}" -type f -name 'mysql_backup_*.tar.gz' -mtime +7 -delete
```

> Ensure the cron user has permission to read `.env` and write to `BACKUP_ROOT`.

---

## Verification Tips

- List DBs inside a tarball quickly:
  ```bash
  tar -tzf mysql_backup_*.tar.gz | grep '_schema.sql$'
  ```

- Count total SQL files:
  ```bash
  tar -tzf mysql_backup_*.tar.gz | grep -E '\.sql$' | wc -l
  ```

- Smoke-test a schema file (no commit) against a scratch DB:
  ```bash
  mysql -u root -p -e 'CREATE DATABASE IF NOT EXISTS scratch;'
  zcat <(tar -xOzf mysql_backup_*.tar.gz --wildcards "*/alarm_db_schema.sql") |     mysql -u root -p scratch
  ```

---

## Security Notes

- Store `.env` with **600** permissions and keep it **out of Git**:
  ```bash
  echo ".env" >> .gitignore
  chmod 600 .env
  ```
- Prefer a **least-privileged MySQL user** with `SELECT`, `SHOW VIEW`, `TRIGGER`, and routine privileges for backups if possible.  
- Keep archives in a protected directory; they contain full data exports.  
- For large restores, ensure the container’s `max_allowed_packet` and `innodb_log_file_size` are appropriate.

---

## Troubleshooting

- **“Could not find any running MySQL container!”**  
  - Check that the MySQL container is running.  
  - Confirm `MYSQL_PUBLISHED_PORT` is actually published (e.g., `docker ps`).  
  - If not published, ensure `STACK_NS` and `SERVICE_NAME` match your Swarm labels/names.

- **Long backup times**  
  - Increase `--jobs` for parallel table dumps (I/O bound).  
  - Consider excluding heavy DBs (like `performance_db`).

- **FK errors on restore**  
  - The script wraps imports with `SET FOREIGN_KEY_CHECKS=0/1`. If you still see errors, restore dependent tables first using `--only-table` or run another pass.

---
