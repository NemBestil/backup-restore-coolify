#!/usr/bin/env bash
#
# restore-coolify.sh — Fully automatic Coolify restore from backup
#
# Usage:  sudo ./restore-coolify.sh <backup_directory>
# Example: sudo ./restore-coolify.sh ~/docker-backups/backup_20260331_200813
#
# Everything needed is in the backup directory created by docker-backup.sh:
#   coolify/coolify-db.dmp     — Postgres database dump
#   coolify/source.env         — Contains APP_KEY
#   coolify/ssh-keys/          — SSH key files
#   coolify/authorized_keys    — authorized_keys from old server
#   coolify/version.txt        — Coolify version
#   volumes/                   — Docker volume data
#   compose/                   — Compose project files
#   bind-mounts/               — Bind mount data (if backed up)

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*"; }
die() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0

    log "jq not found, attempting automatic installation..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -yqq jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q jq
    elif command -v microdnf >/dev/null 2>&1; then
        microdnf install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install jq
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed jq
    else
        die "jq is required, but no supported package manager was found. Install jq manually and rerun."
    fi

    command -v jq >/dev/null 2>&1 || die "jq installation failed. Install jq manually and rerun."
}

# ── Args & validation ──────────────────────────────────────────────────
BACKUP_DIR="${1:-}"
[ -z "$BACKUP_DIR" ] && die "Usage: sudo $0 <backup_directory>"
[ ! -d "$BACKUP_DIR" ] && die "Not a directory: ${BACKUP_DIR}"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
[ "$(id -u)" -ne 0 ] && die "Run as root (sudo)."

COOLIFY_DIR="${BACKUP_DIR}/coolify"
[ ! -d "$COOLIFY_DIR" ] && die "No coolify/ subdirectory found. Was this made with the Coolify-aware docker-backup.sh?"

# Validate all required files
ERRORS=()
[ ! -f "${COOLIFY_DIR}/coolify-db.dmp" ] && ERRORS+=("coolify/coolify-db.dmp")
[ ! -f "${COOLIFY_DIR}/source.env" ]     && ERRORS+=("coolify/source.env")
[ ! -d "${COOLIFY_DIR}/ssh-keys" ]       && ERRORS+=("coolify/ssh-keys/")
[ ! -f "${COOLIFY_DIR}/version.txt" ]    && ERRORS+=("coolify/version.txt")
[ ${#ERRORS[@]} -gt 0 ] && die "Incomplete backup, missing: $(printf '%s, ' "${ERRORS[@]}")"

# Extract config from backup
DB_DUMP="${COOLIFY_DIR}/coolify-db.dmp"
OLD_APP_KEY=$(grep '^APP_KEY=' "${COOLIFY_DIR}/source.env" | cut -d= -f2-)
COOLIFY_VERSION=$(cat "${COOLIFY_DIR}/version.txt")
[ -z "$OLD_APP_KEY" ] && die "APP_KEY not found in coolify/source.env"
[ -z "$COOLIFY_VERSION" ] && die "Empty coolify/version.txt"

log "════════════════════════════════════════════════════════════"
log "  Coolify Restore — fully automatic"
log "  Backup:   ${BACKUP_DIR}"
log "  Version:  ${COOLIFY_VERSION}"
log "  APP_KEY:  ${OLD_APP_KEY:0:10}..."
log "  DB dump:  $(du -h "$DB_DUMP" | cut -f1)"
log "  SSH keys: $(ls "${COOLIFY_DIR}/ssh-keys" | wc -l) files"
log "════════════════════════════════════════════════════════════"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
[[ ! "${CONFIRM:-Y}" =~ ^[Yy] ]] && { log "Aborted."; exit 0; }

ensure_jq

# ═══ Step 1/7: Install fresh Coolify ═══════════════════════════════════
log "═══ Step 1/7: Installing Coolify ${COOLIFY_VERSION} ═══"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^coolify$'; then
    log "Coolify already installed — skipping."
else
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s "$COOLIFY_VERSION"
fi

log "Waiting for coolify-db..."
for _ in $(seq 1 60); do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^coolify-db$' && break
    sleep 2
done
docker ps --format '{{.Names}}' | grep -q '^coolify-db$' || die "coolify-db did not start."
log "Coolify running."

# ═══ Step 2/7: Restore Docker volumes ═════════════════════════════════
log "═══ Step 2/7: Restoring Docker volumes ═══"
RESTORED=0
if [ -d "${BACKUP_DIR}/volumes" ]; then
    shopt -s nullglob
    VOL_FILES=("${BACKUP_DIR}"/volumes/*.data.tar.gz)
    shopt -u nullglob

    if [ ${#VOL_FILES[@]} -eq 0 ]; then
        die "No *.data.tar.gz files in volumes/. Backup may be from an older, incompatible format — re-run docker-backup.sh."
    fi

    for volfile in "${VOL_FILES[@]}"; do
        VOL_NAME=$(basename "$volfile" .data.tar.gz)
        META="${BACKUP_DIR}/volumes/${VOL_NAME}.inspect.json"

        # Read volume driver + labels from metadata
        DRIVER="local"
        LABEL_ARGS=""
        if [ -f "$META" ]; then
            DRIVER=$(jq -r '.[0].Driver // "local"' "$META")
            while IFS= read -r label; do
                [ -z "$label" ] && continue
                LABEL_ARGS+=" --label $(printf '%q' "$label")"
            done < <(jq -r '.[0].Labels // {} | to_entries[] | "\(.key)=\(.value)"' "$META" 2>/dev/null || true)
        fi

        # Create volume if it doesn't exist (with labels)
        if ! docker volume inspect "$VOL_NAME" &>/dev/null; then
            eval "docker volume create --driver ${DRIVER}${LABEL_ARGS} ${VOL_NAME}" || {
                log "  WARN: Failed to create volume ${VOL_NAME}, skipping."
                continue
            }
        fi

        # Always overwrite with backup data
        MOUNT=$(docker volume inspect "$VOL_NAME" --format '{{.Mountpoint}}')
        tar xzf "$volfile" --numeric-owner -C "$MOUNT"
        log "  Restored: ${VOL_NAME}"
        RESTORED=$((RESTORED + 1))
    done
fi
log "  ${RESTORED} volumes restored."

# ═══ Step 3/7: Restore compose files & bind mounts ════════════════════
log "═══ Step 3/7: Restoring compose files & bind mounts ═══"
if [ -d "${BACKUP_DIR}/compose" ]; then
    for projdir in "${BACKUP_DIR}"/compose/*/; do
        [ -d "$projdir" ] || continue
        ORIG_PATH=""
        [ -f "${projdir}/.original-path" ] && ORIG_PATH=$(cat "${projdir}/.original-path")
        if [ -n "$ORIG_PATH" ]; then
            mkdir -p "$ORIG_PATH"
            cp "${projdir}"/* "$ORIG_PATH/" 2>/dev/null || true
            rm -f "${ORIG_PATH}/.original-path"
            log "  Compose: ${ORIG_PATH}"
        fi
    done
fi

if [ -d "${BACKUP_DIR}/bind-mounts" ]; then
    for tarfile in "${BACKUP_DIR}"/bind-mounts/*.tar.gz; do
        [ -f "$tarfile" ] || continue
        base=$(basename "$tarfile" .tar.gz)
        SRC_PATH_FILE="${BACKUP_DIR}/bind-mounts/${base}.source-path"
        [ -f "$SRC_PATH_FILE" ] && DEST=$(cat "$SRC_PATH_FILE") || DEST="/$(echo "$base" | tr '_' '/')"
        mkdir -p "$DEST"
        tar xzf "$tarfile" --numeric-owner -C "$DEST"
        log "  Bind mount: ${DEST}"
    done
fi

# ═══ Step 4/7: Restore Coolify database ═══════════════════════════════
log "═══ Step 4/7: Restoring Coolify database ═══"

# Stop everything that touches the database
log "Stopping ALL Coolify containers (except coolify-db)..."
for svc in $(docker ps --format '{{.Names}}' | grep '^coolify' | grep -v '^coolify-db$'); do
    docker stop "$svc" 2>/dev/null || true
done
sleep 3

# Also stop any soketi container that may hold connections
docker stop soketi 2>/dev/null || true

# Ensure coolify-db is running
docker ps --format '{{.Names}}' | grep -q '^coolify-db$' || { docker start coolify-db; sleep 5; }

# Terminate any remaining connections to the coolify database
log "Terminating active database connections..."
docker exec coolify-db psql -U coolify -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'coolify' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1 || true

# Drop and recreate the database for a clean restore
log "Dropping and recreating coolify database..."
docker exec coolify-db psql -U coolify -d postgres -c "DROP DATABASE IF EXISTS coolify;" >/dev/null 2>&1
docker exec coolify-db psql -U coolify -d postgres -c "CREATE DATABASE coolify OWNER coolify;" >/dev/null 2>&1

# Restore into the empty database
log "Running pg_restore..."
cat "$DB_DUMP" \
    | docker exec -i coolify-db \
        pg_restore --verbose --no-acl --no-owner -U coolify -d coolify 2>&1 \
    | tail -3
log "Database restored."

# Sync the DB password: the fresh install's .env has a new DB_PASSWORD,
# but the coolify app will use it to connect. Set the Postgres user's
# password to match whatever the current .env says.
CURRENT_DB_PASS=$(grep '^DB_PASSWORD=' /data/coolify/source/.env | cut -d= -f2-)
if [ -n "$CURRENT_DB_PASS" ]; then
    log "Syncing database user password to match .env..."
    docker exec coolify-db psql -U coolify -d postgres -c \
        "ALTER USER coolify WITH PASSWORD '${CURRENT_DB_PASS}';" >/dev/null 2>&1
    log "Database password synced."
else
    log "⚠ Could not read DB_PASSWORD from .env — you may need to fix this manually."
fi

# ═══ Step 5/7: Restore SSH keys ═══════════════════════════════════════
log "═══ Step 5/7: Restoring SSH keys ═══"
rm -f /data/coolify/ssh/keys/*
cp "${COOLIFY_DIR}/ssh-keys"/* /data/coolify/ssh/keys/
chmod 600 /data/coolify/ssh/keys/*
log "$(ls /data/coolify/ssh/keys | wc -l) SSH key files restored."

if [ -f "${COOLIFY_DIR}/authorized_keys" ]; then
    mkdir -p /root/.ssh
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue
        grep -qF "$key" /root/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /root/.ssh/authorized_keys
    done < "${COOLIFY_DIR}/authorized_keys"
    chmod 600 /root/.ssh/authorized_keys
    log "authorized_keys updated."
fi

# ═══ Step 6/7: Set APP_PREVIOUS_KEYS ══════════════════════════════════
log "═══ Step 6/7: Setting APP_PREVIOUS_KEYS ═══"
ENV_FILE="/data/coolify/source/.env"
[ ! -f "$ENV_FILE" ] && die ".env not found — Coolify install may have failed."
sed -i '/^APP_PREVIOUS_KEYS=/d' "$ENV_FILE"
echo "APP_PREVIOUS_KEYS=${OLD_APP_KEY}" >> "$ENV_FILE"
log "Done."

# ═══ Step 7/7: Restart Coolify ════════════════════════════════════════
log "═══ Step 7/7: Restarting Coolify ═══"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s "$COOLIFY_VERSION"

echo ""
log "════════════════════════════════════════════════════════════"
log "  ✓ Restore complete!"
log ""
log "  → Open Coolify dashboard, log in with old credentials"
log "  → Coolify manages all containers after restore"
log "  → Start services only from the Coolify web UI or API, not from the shell"
log "  → Update DNS if server IP changed"
log "════════════════════════════════════════════════════════════"
