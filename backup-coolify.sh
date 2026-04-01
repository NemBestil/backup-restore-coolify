#!/usr/bin/env bash
#
# backup-coolify.sh — Full Docker environment backup (v2)
#
# Backs up: container configs, images (optionally), named volumes (with labels),
#           networks (with full IPAM), docker-compose project dirs, bind mounts.
#
# Usage:  sudo ./backup-coolify.sh [BACKUP_DIR]
# Output: A timestamped directory in BACKUP_DIR (default: ./docker-backups)
#
# Env vars:
#   SAVE_IMAGES=false           Skip image tarballs (just save a pull-list)
#   PAUSE_CONTAINERS=false      Don't pause containers during volume backup
#   BACKUP_BIND_MOUNTS=false    Skip bind mount contents (default: backup contents)
#   CREATE_ARCHIVE=true         Tar.gz the backup dir when done

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────
BACKUP_ROOT="${1:-./docker-backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/backup_${TIMESTAMP}"
SAVE_IMAGES="${SAVE_IMAGES:-true}"
PAUSE_CONTAINERS="${PAUSE_CONTAINERS:-true}"
BACKUP_BIND_MOUNTS="${BACKUP_BIND_MOUNTS:-true}"
CREATE_ARCHIVE="${CREATE_ARCHIVE:-true}"

mkdir -p "${BACKUP_DIR}"/{containers,volumes,images,networks,compose,bind-mounts}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*"; }
die() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

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

# ── Pre-flight ──────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo) to access all volumes." >&2
    exit 1
fi
command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
ensure_jq

# ── 1. Docker daemon info ──────────────────────────────────────────────
log "Saving Docker daemon info..."
docker info > "${BACKUP_DIR}/docker-info.txt" 2>&1
[ -f /etc/docker/daemon.json ] && cp /etc/docker/daemon.json "${BACKUP_DIR}/daemon.json"

# ── 2. Networks (full IPAM config) ─────────────────────────────────────
log "Backing up custom networks..."
docker network ls --format '{{.Name}}' | while read -r net; do
    [[ "$net" =~ ^(bridge|host|none)$ ]] && continue
    docker network inspect "$net" > "${BACKUP_DIR}/networks/${net}.json"
    log "  Network: ${net}"
done

# ── 3. Container configs (full inspect) ────────────────────────────────
log "Backing up container configurations..."
docker ps -a --format '{{.ID}} {{.Names}}' | while read -r id name; do
    log "  Container: ${name}"
    docker inspect "$id" > "${BACKUP_DIR}/containers/${name}.inspect.json"

    # Also save the network details separately for easier restore
    # This captures: which networks, aliases per network, IP assignments
    docker inspect "$id" --format '{{json .NetworkSettings.Networks}}' \
        | jq '.' > "${BACKUP_DIR}/containers/${name}.networks.json" 2>/dev/null || true
done

# ── 4. Named volumes (with labels & ownership) ─────────────────────────
log "Backing up named volumes..."
for vol in $(docker volume ls -q); do
    log "  Volume: ${vol}"
    MOUNT=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')

    # Pause containers using this volume for consistency
    PAUSED=()
    if [ "$PAUSE_CONTAINERS" = "true" ]; then
        while IFS= read -r cid; do
            [ -z "$cid" ] && continue
            state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || true)
            if [ "$state" = "running" ]; then
                docker pause "$cid" 2>/dev/null && PAUSED+=("$cid")
            fi
        done < <(docker ps -q --filter "volume=${vol}")
    fi

    # Use --numeric-owner to preserve UID/GID exactly
    tar czf "${BACKUP_DIR}/volumes/${vol}.data.tar.gz" \
        --numeric-owner -C "$MOUNT" . 2>/dev/null || \
        log "  WARN: Could not backup volume ${vol}"

    for cid in "${PAUSED[@]}"; do
        docker unpause "$cid" 2>/dev/null || true
    done

    # Save full volume metadata including labels (critical for compose)
    docker volume inspect "$vol" > "${BACKUP_DIR}/volumes/${vol}.inspect.json"
done

# ── 5. Images ───────────────────────────────────────────────────────────
IMAGE_LIST=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)

if [ "$SAVE_IMAGES" = "true" ]; then
    log "Saving Docker images (SAVE_IMAGES=false to skip)..."
    echo "$IMAGE_LIST" | while read -r img; do
        safe=$(echo "$img" | tr '/:' '_')
        log "  Image: ${img}"
        docker save "$img" | gzip > "${BACKUP_DIR}/images/${safe}.tar.gz"
    done
else
    log "Skipping image tarballs, saving pull-list only."
fi
echo "$IMAGE_LIST" > "${BACKUP_DIR}/images/image-list.txt"

# ── 6. Docker-compose project directories ──────────────────────────────
# Back up the entire compose project dir, not just the yml file
log "Searching for compose projects..."
find / -maxdepth 5 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
    -o -name 'compose.yml' -o -name 'compose.yaml' \) \
    -not -path '*/proc/*' -not -path '*/sys/*' -not -path '*/snap/*' 2>/dev/null | while read -r f; do
    PROJECT_DIR="$(dirname "$f")"
    safe_name=$(echo "$PROJECT_DIR" | tr '/' '_' | sed 's/^_//')
    log "  Found: ${f}"

    # Save the compose file(s) and .env
    mkdir -p "${BACKUP_DIR}/compose/${safe_name}"
    # Copy all compose-related files from the project directory
    for pattern in docker-compose.yml docker-compose.yaml compose.yml compose.yaml \
                   docker-compose.override.yml docker-compose.override.yaml \
                   .env Dockerfile Dockerfile.*; do
        for match in "${PROJECT_DIR}"/$pattern; do
            [ -f "$match" ] && cp "$match" "${BACKUP_DIR}/compose/${safe_name}/"
        done
    done
    # Record the original path
    echo "$PROJECT_DIR" > "${BACKUP_DIR}/compose/${safe_name}/.original-path"
done

# ── 7. Bind mounts ─────────────────────────────────────────────────────
log "Inventorying bind mounts..."
docker ps -a --format '{{.Names}}' | while read -r name; do
    docker inspect "$name" --format \
        '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\t"}}{{.Destination}}{{"\t"}}{{.RW}}{{"\n"}}{{end}}{{end}}' \
        2>/dev/null
done | sort -u > "${BACKUP_DIR}/bind-mounts/inventory.txt"

if [ "$BACKUP_BIND_MOUNTS" = "true" ] && [ -s "${BACKUP_DIR}/bind-mounts/inventory.txt" ]; then
    log "Backing up bind mount contents..."
    while IFS=$'\t' read -r src dest rw; do
        [ -z "$src" ] && continue
        [ ! -e "$src" ] && { log "  WARN: ${src} does not exist, skipping"; continue; }
        safe=$(echo "$src" | tr '/' '_' | sed 's/^_//')
        log "  Bind mount: ${src}"
        tar czf "${BACKUP_DIR}/bind-mounts/${safe}.tar.gz" \
            --numeric-owner -C "$src" . 2>/dev/null || \
            log "  WARN: Could not backup bind mount ${src}"
        echo "$src" > "${BACKUP_DIR}/bind-mounts/${safe}.source-path"
    done < "${BACKUP_DIR}/bind-mounts/inventory.txt"
elif [ -s "${BACKUP_DIR}/bind-mounts/inventory.txt" ]; then
    log "  ⚠ Bind mounts found (set BACKUP_BIND_MOUNTS=false to skip contents and keep inventory only):"
    awk -F'\t' '{print "    " $1 " -> " $2}' "${BACKUP_DIR}/bind-mounts/inventory.txt"
fi

# ── 8. Coolify-specific backup ──────────────────────────────────────────
if [ -d "/data/coolify" ]; then
    log "Coolify detected! Backing up Coolify-specific data..."
    mkdir -p "${BACKUP_DIR}/coolify"

    # APP_KEY from .env (critical for restore)
    if [ -f /data/coolify/source/.env ]; then
        cp /data/coolify/source/.env "${BACKUP_DIR}/coolify/source.env"
        APP_KEY=$(grep '^APP_KEY=' /data/coolify/source/.env | cut -d= -f2-)
        log "  APP_KEY saved (starts with: ${APP_KEY:0:10}...)"
    fi

    # SSH keys
    if [ -d /data/coolify/ssh/keys ]; then
        cp -r /data/coolify/ssh/keys "${BACKUP_DIR}/coolify/ssh-keys"
        log "  SSH keys saved ($(ls /data/coolify/ssh/keys | wc -l) files)"
    fi

    # authorized_keys
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys "${BACKUP_DIR}/coolify/authorized_keys"
        log "  authorized_keys saved"
    fi

    # Coolify DB dump via pg_dump inside the container
    if docker ps --format '{{.Names}}' | grep -q '^coolify-db$'; then
        log "  Dumping Coolify database..."
        docker exec coolify-db pg_dump -U coolify -Fc coolify \
            > "${BACKUP_DIR}/coolify/coolify-db.dmp" 2>/dev/null
        log "  Database dump saved ($(du -h "${BACKUP_DIR}/coolify/coolify-db.dmp" | cut -f1))"
    else
        warn "  coolify-db container not running — skipping DB dump."
        warn "  Get a dump from Coolify Dashboard > Settings > Backup instead."
    fi

    # Coolify version
    COOLIFY_VER=$(docker inspect coolify --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep '^APP_VERSION=' | cut -d= -f2- || true)
    if [ -z "$COOLIFY_VER" ]; then
        COOLIFY_VER=$(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2 || echo "unknown")
    fi
    echo "$COOLIFY_VER" > "${BACKUP_DIR}/coolify/version.txt"
    log "  Coolify version: ${COOLIFY_VER}"

    log "  ★ To restore, use restore-coolify.sh instead of the generic restore script."
fi

# ── 9. Manifest ─────────────────────────────────────────────────────────
log "Writing manifest..."
cat > "${BACKUP_DIR}/manifest.json" <<EOF
{
  "version": 2,
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "docker_version": "$(docker version --format '{{.Server.Version}}')",
  "containers": $(docker ps -a -q | wc -l),
  "volumes": $(docker volume ls -q | wc -l),
  "images": $(echo "$IMAGE_LIST" | wc -l),
  "images_saved": ${SAVE_IMAGES},
  "bind_mounts_saved": ${BACKUP_BIND_MOUNTS}
}
EOF

# ── 9. Optional archive ────────────────────────────────────────────────
if [ "$CREATE_ARCHIVE" = "true" ]; then
    ARCHIVE="${BACKUP_ROOT}/docker-backup_${TIMESTAMP}.tar.gz"
    log "Creating archive..."
    tar czf "$ARCHIVE" -C "$BACKUP_ROOT" "backup_${TIMESTAMP}"
    log "Archive: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1))"
    log "Transfer: scp ${ARCHIVE} user@newserver:~/"
fi

log "Directory: ${BACKUP_DIR}"
log "Done!"
