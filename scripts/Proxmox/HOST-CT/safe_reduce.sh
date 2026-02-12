#!/usr/bin/env bash
set -euo pipefail

SAFETY_GIB=0            # folga acima do mínimo (ajuste se quiser)
BACKUP_COMPRESS="zstd"
BACKUP_MODE="stop"
BACKUP_STORAGE=""       # vazio = deixa o padrão do seu Proxmox; ou fixe "local", "backup", etc.

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[safe_reduce] $*"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

CTID="${1:-}"
[[ -n "$CTID" ]] || die "Usage: $0 <CTID>"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be numeric"

require_cmd pct
require_cmd vzdump
require_cmd pvesm
require_cmd e2fsck
require_cmd resize2fs
require_cmd lvreduce
require_cmd blkid
require_cmd dumpe2fs
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd findmnt
require_cmd lsblk

CONF="/etc/pve/lxc/${CTID}.conf"
[[ -f "$CONF" ]] || die "Config not found: $CONF"

ROOTFS_LINE="$(grep -E '^rootfs:' "$CONF" | head -n1 || true)"
[[ -n "$ROOTFS_LINE" ]] || die "Could not find rootfs: line in $CONF"

ROOTVOL="$(echo "$ROOTFS_LINE" | awk '{print $2}' | awk -F',' '{print $1}')"
[[ "$ROOTVOL" == *:* ]] || die "Unexpected rootfs volume format: $ROOTVOL"

log "CTID=$CTID rootfs=$ROOTVOL"

VOLPATH="$(pvesm path "$ROOTVOL" 2>/dev/null || true)"
[[ -n "$VOLPATH" ]] || die "Could not resolve volume path: pvesm path $ROOTVOL"
log "Resolved volume path: $VOLPATH"

[[ -b "$VOLPATH" ]] || die "Resolved path is not a block device (expects LVM LV): $VOLPATH"
if findmnt -rn -S "$VOLPATH" >/dev/null 2>&1; then
  die "Volume is mounted on host. Unmount first."
fi

FSTYPE="$(blkid -o value -s TYPE "$VOLPATH" 2>/dev/null || true)"
[[ "$FSTYPE" == "ext4" ]] || die "Filesystem must be ext4 to shrink. Detected: ${FSTYPE:-unknown}"

CUR_BYTES="$(lsblk -bndo SIZE "$VOLPATH" | head -n1 | tr -d '[:space:]' || true)"
[[ -n "$CUR_BYTES" ]] || die "Could not determine current LV size"

STATUS="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
[[ -n "$STATUS" ]] || die "Could not get CT status (invalid CTID?)"

if [[ "$STATUS" != "stopped" ]]; then
  log "Stopping CT $CTID..."
  pct stop "$CTID"
fi

log "Creating backup via vzdump (compress=$BACKUP_COMPRESS mode=$BACKUP_MODE)..."
if [[ -n "$BACKUP_STORAGE" ]]; then
  vzdump "$CTID" --mode "$BACKUP_MODE" --compress "$BACKUP_COMPRESS" --storage "$BACKUP_STORAGE" >/dev/null
else
  vzdump "$CTID" --mode "$BACKUP_MODE" --compress "$BACKUP_COMPRESS" >/dev/null
fi
log "Backup completed."

log "Running e2fsck..."
e2fsck -fy "$VOLPATH" >/dev/null
log "e2fsck OK."

BLKSZ="$(dumpe2fs -h "$VOLPATH" 2>/dev/null | awk -F': ' '/Block size/ {print $2}' | tr -d '[:space:]')"
[[ -n "$BLKSZ" ]] || die "Could not read block size from dumpe2fs"

MINBLOCKS="$(resize2fs -P "$VOLPATH" 2>/dev/null | awk -F': ' '/Estimated minimum size/ {print $2}' | tr -d '[:space:]')"
[[ -n "$MINBLOCKS" ]] || die "Could not read minimum size from resize2fs -P"

GIB_BYTES=$((1024*1024*1024))
SAFETY_BYTES=$((SAFETY_GIB * GIB_BYTES))

MIN_BYTES=$(( MINBLOCKS * BLKSZ ))
RAW_TARGET_BYTES=$(( MIN_BYTES + SAFETY_BYTES ))
TARGET_BYTES=$(( ( (RAW_TARGET_BYTES + GIB_BYTES - 1) / GIB_BYTES ) * GIB_BYTES ))  # align up to 1GiB

if (( TARGET_BYTES >= CUR_BYTES )); then
  log "Nothing to shrink: target >= current."
  log "Current: $((CUR_BYTES/GIB_BYTES)) GiB ; Target: $((TARGET_BYTES/GIB_BYTES)) GiB (min+${SAFETY_GIB}GiB)"
  log "Starting CT $CTID..."
  pct start "$CTID"
  exit 0
fi

TARGET_GIB=$(( TARGET_BYTES / GIB_BYTES ))
TARGET_STR="${TARGET_GIB}G"

log "Computed minimum ~ $((MIN_BYTES/GIB_BYTES)) GiB (blocks=$MINBLOCKS, block_size=${BLKSZ}B)"
log "Target shrink size: ${TARGET_STR} (min + ${SAFETY_GIB}GiB, aligned 1GiB)"
log "Current size: $((CUR_BYTES/GIB_BYTES)) GiB -> Target: $TARGET_GIB GiB"

log "Shrinking filesystem to $TARGET_STR..."
resize2fs "$VOLPATH" "$TARGET_STR"

log "Shrinking LVM LV to $TARGET_STR..."
lvreduce -L "$TARGET_STR" "$VOLPATH" -y >/dev/null

log "Updating $CONF rootfs size=..."
if echo "$ROOTFS_LINE" | grep -q 'size='; then
  sed -i -E "0,/^rootfs:/{s/(^rootfs: [^,]+,.*)size=[0-9]+[GM]/\1size=${TARGET_STR}/}" "$CONF"
else
  sed -i -E "0,/^rootfs:/{s|^(rootfs: [^,]+)(.*)$|\1\2,size=${TARGET_STR}|}" "$CONF"
fi

log "Starting CT $CTID..."
pct start "$CTID"

log "Best-effort: df -h / inside CT"
pct exec "$CTID" -- df -h / || true

log "Done."