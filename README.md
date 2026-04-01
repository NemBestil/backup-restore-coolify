# Coolify Backup and Restore Scripts

This repository contains two Bash scripts for taking a full backup of a Docker host with Coolify and restoring that backup onto a fresh Coolify installation. This makes migration and disaster recovery painless, as you won't have to manually rebuild volumes, Compose files, SSH keys, or the Coolify database.

The backup flow is Docker-aware and Coolify-aware. It captures container metadata, custom networks, named volumes, Compose project files, images, bind mount contents, and extra Coolify state such as the application database, `.env` and SSH keys.

## Features

- Full Docker host inventory: containers, networks, volumes, images, Compose files, and bind mounts
- Coolify-specific backup of `/data/coolify`, database dump, SSH keys, and `APP_KEY`
- Restore script that reinstalls the same Coolify version and restores the captured state
- Optional image export with `docker save`
- Bind mount content backup enabled by default
- Optional `.tar.gz` archive output for easy transfer to another host

## Repository Contents

- `backup-coolify.sh`: creates a timestamped backup directory and, by default, a compressed archive
- `restore-coolify.sh`: restores a Coolify installation from a backup directory created by `backup-coolify.sh`

## Privacy and Data Handling

These scripts run on your own servers and operate on local Docker, filesystem, and Coolify data. They do not upload backups, share configuration data, or collect metrics or telemetry.

The one external network dependency in this repository is the restore flow, which downloads the official Coolify installer script. Any backup transfer with `scp`, `rsync`, or similar tools is fully under your control.

## Requirements and Assumptions

- Can only backup and restore Linux servers
- Root access via `sudo`
- Network access on the restore host, because the script downloads the official Coolify installer
- A backup created by `backup-coolify.sh` if you want to use `restore-coolify.sh`

The backup script is broadly useful for Docker environments, but the restore script in this repository is specifically designed for Coolify restores.

## Quick Start

Create a backup:

```bash
sudo bash ./backup-coolify.sh /var/backups/coolify
```

That creates:

- a directory like `/var/backups/coolify/backup_20260401_120000`
- and, by default, an archive like `/var/backups/coolify/docker-backup_20260401_120000.tar.gz`

If you transfer the archive to another machine, extract it first:

```bash
tar xzf docker-backup_20260401_120000.tar.gz
```

Then restore from the extracted backup directory:

```bash
sudo bash ./restore-coolify.sh /path/to/backup_20260401_120000
```

## How `backup-coolify.sh` Works

The backup script collects:

- Docker daemon info and `/etc/docker/daemon.json` if present
- Custom Docker networks via `docker network inspect`
- Full container metadata via `docker inspect`
- Named volume contents and volume metadata
- Docker images as compressed tarballs, or just an image pull list
- Compose files, `.env`, and nearby Dockerfile files from discovered project directories
- Bind mount inventory and, by default, bind mount data archives
- Coolify-specific files from `/data/coolify` when available
- A PostgreSQL dump from the `coolify-db` container when it is running
- A `manifest.json` describing the backup

### Backup Options

Environment variables control the behavior:

| Variable | Default | Effect |
| --- | --- | --- |
| `SAVE_IMAGES` | `true` | Save Docker images as `tar.gz` files. If `false`, only `images/image-list.txt` is written. |
| `PAUSE_CONTAINERS` | `true` | Pause running containers that use a volume while that volume is archived. |
| `BACKUP_BIND_MOUNTS` | `true` | Store bind mount contents. Set it to `false` to keep only the inventory list. |
| `CREATE_ARCHIVE` | `true` | Create a final `docker-backup_<timestamp>.tar.gz` archive. |

### Backup Examples

Default backup:

```bash
sudo bash ./backup-coolify.sh /var/backups/coolify
```

Skip image tarballs:

```bash
sudo env SAVE_IMAGES=false bash ./backup-coolify.sh /var/backups/coolify
```

Skip bind mount contents:

```bash
sudo env BACKUP_BIND_MOUNTS=false bash ./backup-coolify.sh /var/backups/coolify
```

Keep only the directory and do not create a tarball:

```bash
sudo env CREATE_ARCHIVE=false bash ./backup-coolify.sh /var/backups/coolify
```

## How `restore-coolify.sh` Works

The restore script expects an extracted backup directory with a `coolify/` subdirectory. It validates the required files, reads the saved Coolify version and `APP_KEY`, and then performs the restore in this order:

1. Install a fresh Coolify instance matching the saved version
2. Restore Docker named volumes from the archived volume data
3. Restore discovered Compose files and bind mount contents
4. Replace the Coolify PostgreSQL database with the saved dump
5. Restore SSH keys and merge `authorized_keys`
6. Set `APP_PREVIOUS_KEYS` so the old application key remains usable
7. Re-run the Coolify installer to restart the platform cleanly

### Restore Command

```bash
sudo bash ./restore-coolify.sh /path/to/backup_20260401_120000
```

### Prepare the Target Server

For best results, restore onto a fresh server that does not already have Docker installed. If the target server already has Docker, make sure it is completely clean before running the restore so old containers, images, networks, and volumes do not conflict with the restored Coolify environment.

The following commands are destructive and will remove existing Docker workloads and data:

```bash
sudo docker ps -aq | xargs -r sudo docker stop
sudo docker system prune -af --volumes
sudo docker volume ls -q | xargs -r sudo docker volume rm
```

### Restore Notes

- The script is interactive and asks for confirmation before it proceeds.
- It stops Coolify services during database restore.
- It restores the saved Coolify version automatically.
- After restore, let Coolify manage the application containers.
- Start services only from the Coolify web UI or the Coolify API, not from the shell with `docker`, `docker compose`, or similar commands.
- If the server IP changes, update DNS after the restore.

## Transferring a Backup

Keep this simple: copy either the archive or the extracted directory to the new host.

Using `scp`:

```bash
scp /var/backups/coolify/docker-backup_20260401_120000.tar.gz user@newserver:~/
```

Using `rsync`:

```bash
rsync -avP /var/backups/coolify/docker-backup_20260401_120000.tar.gz user@newserver:~/
```

If you prefer transferring the extracted directory instead of the archive:

```bash
rsync -avP /var/backups/coolify/backup_20260401_120000/ user@newserver:~/backup_20260401_120000/
```

If you transfer the archive, extract it on the target host before running `restore-coolify.sh`.

## Technical details

- `restore-coolify.sh` is intentionally Coolify-specific. It is not a generic Docker restore tool.
- The scripts assume conventional Linux filesystem locations such as `/data/coolify` and `/root/.ssh`.
- `jq` is installed automatically if missing when the host has `apt-get`, `dnf`, `yum`, `microdnf`, `apk`, `zypper`, or `pacman`.
- Bind mounts are archived by default. Set `BACKUP_BIND_MOUNTS=false` to keep inventory only.
- If `SAVE_IMAGES=false`, the backup still contains an image list that can be used to pull images again later.

## Provenance

Most of the code in this repository was originally written by Claude Opus. It has been thoroughly vetted and tested by senior software engineer [@bitnissen](https://github.com/bitnissen).

## License

Released under the MIT License. See [`LICENSE`](./LICENSE).
