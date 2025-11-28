#!/usr/bin/env bash
set -euo pipefail

# Auto-resize do filesystem raiz após expandir disco na VM (Proxmox)
# Suporta: LVM (PV/LV), ext4, xfs, btrfs.
# Não trata LUKS/criptografia (detecta e aborta com aviso).

log(){ printf "\n[+] %s\n" "$*"; }
err(){ printf "\n[!] %s\n" "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { err "comando requerido não encontrado: $1"; exit 1; }
}

# 0) Sanidade: root?
if [[ $EUID -ne 0 ]]; then
  err "precisa rodar como root"; exit 1
fi

# 1) Info do root
ROOT_SRC="$(findmnt -no SOURCE /)"
FSTYPE="$(findmnt -no FSTYPE /)"
ROOT_NAME="$(lsblk -no NAME "$ROOT_SRC" 2>/dev/null || true)"   # sda2 ou dm-0 etc.

log "Root source: $ROOT_SRC  | FS: $FSTYPE"

# 2) Bloqueio: LUKS/crypt?
if lsblk -no TYPE "$ROOT_SRC" 2>/dev/null | grep -q '^crypt$'; then
  err "Root está criptografado (LUKS/crypt). Este script não trata esse caso."
  exit 1
fi

# 3) Instalar utilitários necessários (sem prompts)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends cloud-guest-utils gdisk parted || true
# lvm2 só se for LVM
if [[ "$ROOT_SRC" == /dev/mapper/* ]]; then
  apt-get install -y --no-install-recommends lvm2 || true
fi

# Funções auxiliares
disk_and_part_from_dev() {
  local part_dev="$1"  # ex: /dev/sda2 ou /dev/nvme0n1p3
  local base name disk part
  name="$(basename "$part_dev")"

  if [[ "$name" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
    disk="/dev/${name%p*}"             # nvme0n1
    part="${name##*p}"                 # 3
  elif [[ "$name" =~ ^vd[a-z][0-9]+$ || "$name" =~ ^sd[a-z][0-9]+$ ]]; then
    disk="/dev/${name%%[0-9]*}"        # /dev/vda ou /dev/sda
    part="${name##*[!0-9]}"            # 2
  else
    # fallback robusto via lsblk
    local pk="$(lsblk -no pkname "$part_dev")"
    local pn="$(lsblk -no PARTN "$part_dev" || true)"
    if [[ -n "$pk" && -n "$pn" ]]; then
      disk="/dev/$pk"; part="$pn"
    else
      err "não foi possível determinar disco/partição de $part_dev"
      exit 1
    fi
  fi
  printf "%s %s\n" "$disk" "$part"
}

grow_partition() {
  local disk="$1" part="$2"
  log "Executando growpart em $disk partição $part..."
  require growpart
  # rescan do kernel (melhora chance de sucesso do growpart)
  if [[ -e "/sys/class/block/$(basename "$disk")/device/rescan" ]]; then
    echo 1 > "/sys/class/block/$(basename "$disk")/device/rescan" || true
  fi
  partprobe "$disk" || true
  growpart "$disk" "$part"
  partprobe "$disk" || true
}

resize_fs_non_lvm() {
  local part_dev="$1" fstype="$2"
  case "$fstype" in
    ext4|ext3)
      log "Redimensionando filesystem $fstype com resize2fs..."
      require resize2fs
      resize2fs "$part_dev"
      ;;
    xfs)
      log "Redimensionando XFS (online) com xfs_growfs..."
      require xfs_growfs
      xfs_growfs /
      ;;
    btrfs)
      log "Redimensionando Btrfs (online) para máximo..."
      require btrfs
      btrfs filesystem resize max /
      ;;
    *)
      err "Filesystem $fstype não suportado automaticamente."
      exit 1
      ;;
  esac
}

if [[ "$ROOT_SRC" == /dev/mapper/* ]]; then
  # ======== CAMINHO LVM ========
  log "Detectado LVM."
  require lvs
  require pvs
  require pvresize
  require lvextend

  # Qual LV é o '/'?
  read -r VG LV <<<"$(lvs --noheadings -o vg_name,lv_name "$ROOT_SRC" | awk '{print $1, $2}')"
  [[ -n "$VG" && -n "$LV" ]] || { err "não consegui identificar VG/LV a partir de $ROOT_SRC"; exit 1; }
  log "VG=$VG  LV=$LV"

  # Descobrir o PV que contém o VG (assume 1 PV principal)
  PV_DEV="$(pvs --noheadings -o pv_name,vg_name | awk -v v="$VG" '$2==v {print $1; exit}')"
  [[ -n "$PV_DEV" ]] || { err "não encontrei PV para VG $VG"; exit 1; }

  read -r DISK PARTNUM <<<"$(disk_and_part_from_dev "$PV_DEV")"
  log "PV=$PV_DEV  |  Disco=$DISK  Partição=$PARTNUM"

  grow_partition "$DISK" "$PARTNUM"

  log "pvresize em $PV_DEV..."
  pvresize "$PV_DEV"

  log "lvextend -r (crescer LV do root até usar todo FREE)..."
  lvextend -r -l +100%FREE "/dev/$VG/$LV"

  log "✅ Resize LVM concluído."

else
  # ======== CAMINHO NÃO-LVM (partição direta) ========
  PART_DEV="$ROOT_SRC"
  read -r DISK PARTNUM <<<"$(disk_and_part_from_dev "$PART_DEV")"
  log "Dispositivo raiz: $PART_DEV  |  Disco=$DISK  Partição=$PARTNUM"

  grow_partition "$DISK" "$PARTNUM"

  resize_fs_non_lvm "$PART_DEV" "$FSTYPE"

  log "✅ Resize não-LVM concluído."
fi

log "Finalizado. Espaço novo deve aparecer em: df -h"