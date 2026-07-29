#!/usr/bin/env bash
set -Eeuo pipefail

# safe_reduce_ct_v3_0.sh
# Reducao segura de rootfs ext4 de containers LXC em LVM/LVM-thin no Proxmox.
# Nao funciona para VMs QEMU, ZFS, XFS, Ceph, directory storage ou volumes com particoes.

SAFETY_GIB=1
MIN_FREE_GIB=2
MAX_FS_USAGE_PCT=90
BACKUP_COMPRESS="zstd"
BACKUP_MODE="stop"
BACKUP_STORAGE=""
SKIP_BACKUP=0
FORCE_HIGH_POOL=0
POOL_ABORT_PCT=95
POOL_META_ABORT_PCT=90
PRE_FSTRIM=1
POST_FSTRIM=0
REQUIRE_TAIL_DISCARD=1
TARGET_OVERRIDE_GIB=""
STOP_TIMEOUT=60
DRY_RUN=0
FSCK_AUTO_FIX=0

SUCCESS=0
WAS_RUNNING=0
STOPPED_BY_SCRIPT=0
CT_STARTED=0
FS_SHRUNK=0
LV_SHRUNK=0
CONF_CHANGED=0
ROLLBACK_IN_PROGRESS=0

CONF=""
ROOTFS_LINE_ORIGINAL=""
PVE_VOLPATH=""
CANON_VOLPATH=""
VOLPATH=""
STORAGE_ID=""
STORAGE_TYPE=""
LV_ATTR=""
VG_NAME=""
LV_NAME=""
POOL_LV=""
CUR_BYTES=0
TARGET_BYTES=0
CTID=""

log()  { printf '[safe_reduce] %s\n' "$*" >&2; }
warn() { printf '[safe_reduce] WARNING: %s\n' "$*" >&2; }
die()  { printf '[safe_reduce] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Comando obrigatorio ausente: $1"
}

detect_backup_storage() {
  (( SKIP_BACKUP == 1 )) && return 0

  local status_output
  local -a candidates=()

  if [[ -n "$BACKUP_STORAGE" ]]; then
    if ! status_output="$(pvesm status \
      --storage "$BACKUP_STORAGE" \
      --content backup \
      --enabled 1 2>&1)"; then
      die "Nao foi possivel validar o storage de backup '$BACKUP_STORAGE': $status_output"
    fi

    if ! awk -v sid="$BACKUP_STORAGE" \
      'NR > 1 && $1 == sid && $3 == "active" { found=1 } END { exit !found }' \
      <<< "$status_output"; then
      printf '%s\n' "$status_output" >&2
      die "O storage '$BACKUP_STORAGE' nao esta ativo, habilitado ou nao aceita conteudo backup."
    fi

    log "Storage de backup informado e validado: $BACKUP_STORAGE"
    return 0
  fi

  if ! status_output="$(pvesm status --content backup --enabled 1 2>&1)"; then
    die "Nao foi possivel consultar os storages de backup: $status_output"
  fi

  mapfile -t candidates < <(
    awk 'NR > 1 && $3 == "active" { print $1 }' <<< "$status_output"
  )

  case "${#candidates[@]}" in
    0)
      printf '%s\n' "$status_output" >&2
      die "Nenhum storage ativo e habilitado com suporte a backup foi encontrado."
      ;;
    1)
      BACKUP_STORAGE="${candidates[0]}"
      log "Storage de backup detectado automaticamente: $BACKUP_STORAGE"
      ;;
    *)
      printf '%s\n' "$status_output" >&2
      die "Mais de um storage de backup ativo foi encontrado (${candidates[*]}). Use --backup-storage <nome>."
      ;;
  esac
}

usage() {
  cat <<'USAGE'
Uso:
  safe_reduce_ct_v3_0.sh [opcoes] <CTID>

Opcoes:
  --target-gib <GiB>              Define um tamanho-alvo explicito.
                                  O valor ainda precisa passar nas regras de seguranca.
  --safety-gib <GiB>              Margem acima do minimo estimado pelo ext4 (padrao: 2).
  --min-free-gib <GiB>            Espaco livre minimo previsto apos a reducao (padrao: 4).
  --max-fs-usage-pct <0-100>      Uso maximo previsto apos a reducao (padrao: 90).
  --skip-bk, --skip-backup       Nao cria backup via vzdump.
  --backup-storage <nome>         Storage de destino do vzdump. Se omitido, detecta
                                  automaticamente quando houver apenas um storage
                                  ativo com suporte ao conteudo backup.
  --force-high-pool               Permite thin pool acima dos limites de data/metadata.
  --pool-abort-pct <0-100>        Limite de Data% do thin pool (padrao: 95).
  --pool-meta-abort-pct <0-100>   Limite de Meta% do thin pool (padrao: 90).
  --no-pre-fstrim                 Nao executa pct fstrim antes de parar o CT.
  --allow-no-tail-discard         Permite continuar se o descarte da cauda falhar.
                                  Nao recomendado em LVM-thin.
  --post-fstrim                   Executa pct fstrim depois de iniciar o CT.
  --fsck-auto-fix                 Permite e2fsck -y se o modo seguro nao resolver.
  --stop-timeout <segundos>       Timeout do shutdown gracioso (padrao: 60).
  --dry-run                       Faz auditoria e mostra as operacoes sem alterar o volume.
  -h, --help                      Mostra esta ajuda.

Regras:
  - Exclusivo para containers LXC do Proxmox.
  - Rootfs precisa ser ext4 diretamente em LV LVM/LVM-thin.
  - O CT precisa ficar parado durante e2fsck/resize2fs/lvreduce.
  - Volumes com snapshots sao recusados.
  - O alvo automatico e o maior entre:
      minimo ext4 + margem,
      dados usados + espaco livre minimo,
      tamanho necessario para respeitar o percentual maximo.
  - O tamanho final e arredondado para cima em GiB exatos.
  - Em LVM-thin, a area removida e descartada antes do lvreduce.
  - Em falha apos o inicio da reducao, o script para o CT e tenta restaurar o tamanho original.
  - VMs QEMU devem usar outro script; este arquivo recusa VMs explicitamente.
USAGE
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

ceil_div() {
  local n="$1" d="$2"
  printf '%s\n' $(((n + d - 1) / d))
}

run_or_log() {
  if (( DRY_RUN == 1 )); then
    printf '[safe_reduce] [dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
  else
    "$@"
  fi
}

write_rootfs_line() {
  local new_line="$1"
  local tmp

  if (( DRY_RUN == 1 )); then
    log "[dry-run] rootfs seria atualizado para: $new_line"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v replacement="$new_line" '
    BEGIN { replaced=0 }
    !replaced && /^rootfs:/ { print replacement; replaced=1; next }
    { print }
    END { if (!replaced) exit 2 }
  ' "$CONF" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }

  cat "$tmp" > "$CONF"
  rm -f "$tmp"
}

set_conf_size() {
  local size_str="$1"
  local current_line value part joined="" found=0
  local -a parts new_parts

  current_line="$(grep -E '^rootfs:' "$CONF" | head -n1 || true)"
  [[ -n "$current_line" ]] || die "Nao foi possivel reler rootfs em $CONF"

  value="${current_line#rootfs:}"
  value="${value# }"
  IFS=',' read -r -a parts <<< "$value"

  for part in "${parts[@]}"; do
    if [[ "$part" == size=* ]]; then
      new_parts+=("size=${size_str}")
      found=1
    else
      new_parts+=("$part")
    fi
  done

  if (( found == 0 )); then
    new_parts+=("size=${size_str}")
  fi

  joined="$(IFS=,; printf '%s' "${new_parts[*]}")"
  write_rootfs_line "rootfs: ${joined}"
  if (( DRY_RUN == 0 )); then
    CONF_CHANGED=1
  fi
}

trim_field() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

detect_storage_type() {
  local output

  STORAGE_ID="${ROOTVOL%%:*}"
  output="$(pvesm status --storage "$STORAGE_ID" 2>/dev/null || pvesm status 2>/dev/null || true)"
  STORAGE_TYPE="$(awk -v sid="$STORAGE_ID" 'NR > 1 && $1 == sid { print $2; exit }' <<< "$output")"

  [[ -n "$STORAGE_TYPE" ]] || die "Nao foi possivel determinar o tipo do storage '$STORAGE_ID'."

  case "$STORAGE_TYPE" in
    lvm|lvmthin)
      log "Storage detectado: ${STORAGE_ID} (${STORAGE_TYPE})"
      ;;
    *)
      die "CT nao redutivel por este script: storage '$STORAGE_ID' e do tipo '$STORAGE_TYPE'. Suportados: lvm e lvmthin."
      ;;
  esac
}

resolve_lvm_volume() {
  local rootvol="$1" row_vg row_lv row_path row_attr row_canonical
  local matches=0 selected_vg="" selected_lv="" selected_path="" selected_attr=""

  PVE_VOLPATH="$(pvesm path "$rootvol" 2>/dev/null || true)"
  [[ -n "$PVE_VOLPATH" ]] || die "pvesm nao conseguiu resolver $rootvol"

  CANON_VOLPATH="$(readlink -f "$PVE_VOLPATH" 2>/dev/null || printf '%s' "$PVE_VOLPATH")"

  if [[ ! -b "$CANON_VOLPATH" ]]; then
    lvchange -ay "$PVE_VOLPATH" >/dev/null 2>&1 || true
    sleep 1
    CANON_VOLPATH="$(readlink -f "$PVE_VOLPATH" 2>/dev/null || printf '%s' "$PVE_VOLPATH")"
  fi

  [[ -b "$CANON_VOLPATH" ]] || die "O rootfs nao e um dispositivo de bloco ativo: $PVE_VOLPATH"

  # Nao passe /dev/dm-N diretamente ao lvs. Compare o dispositivo canonico
  # com os lv_path informados pelo proprio LVM e preserve o caminho /dev/VG/LV.
  while IFS='|' read -r row_vg row_lv row_path row_attr; do
    row_vg="$(trim_field "$row_vg")"
    row_lv="$(trim_field "$row_lv")"
    row_path="$(trim_field "$row_path")"
    row_attr="$(trim_field "$row_attr")"
    [[ -n "$row_path" && -b "$row_path" ]] || continue

    row_canonical="$(readlink -f "$row_path" 2>/dev/null || printf '%s' "$row_path")"
    if [[ "$row_canonical" == "$CANON_VOLPATH" ]]; then
      matches=$((matches + 1))
      selected_vg="$row_vg"
      selected_lv="$row_lv"
      selected_path="$row_path"
      selected_attr="$row_attr"
    fi
  done < <(lvs -a --noheadings --separator '|' -o vg_name,lv_name,lv_path,lv_attr 2>/dev/null || true)

  if (( matches == 0 )); then
    die "O dispositivo $CANON_VOLPATH existe, mas nao corresponde a nenhum lv_path do LVM. O CT nao sera alterado."
  fi
  if (( matches > 1 )); then
    die "Mais de um LV corresponde ao dispositivo $CANON_VOLPATH. Identificacao ambigua; o CT nao sera alterado."
  fi

  VG_NAME="$selected_vg"
  LV_NAME="$selected_lv"
  VOLPATH="$selected_path"
  LV_ATTR="$selected_attr"

  [[ -n "$VG_NAME" && -n "$LV_NAME" && -b "$VOLPATH" ]] || die "Nao foi possivel determinar VG/LV de forma segura."
  [[ "${LV_ATTR:1:1}" == "w" ]] || die "O LV ${VG_NAME}/${LV_NAME} nao esta marcado como gravavel (attr=${LV_ATTR:-n/a})."
}

collect_current_lv_warning_output() {
  lvs -a -o vg_name,lv_name,lv_size,pool_lv,data_percent,metadata_percent \
    "${VG_NAME}/${LV_NAME}" 2>&1 || true
}

current_lv_has_maps_warning() {
  local output data_pct

  output="$(collect_current_lv_warning_output)"
  if grep -F "Thin volume ${VG_NAME}/${LV_NAME} maps " <<< "$output" >/dev/null 2>&1; then
    printf '%s\n' "$output" >&2
    return 0
  fi

  data_pct="$(lvs --noheadings -o data_percent "${VG_NAME}/${LV_NAME}" 2>/dev/null | tr -d ' %' | head -n1 || true)"
  if [[ -n "$data_pct" ]] && float_gt "$data_pct" 100; then
    warn "Data% do volume atual esta em ${data_pct}% (>100%)."
    return 0
  fi

  return 1
}

report_other_maps_warnings() {
  local output filtered

  output="$(lvs -a -o vg_name,lv_name,lv_size,pool_lv,data_percent,metadata_percent "$VG_NAME" 2>&1 || true)"
  filtered="$(grep -F "Thin volume ${VG_NAME}/" <<< "$output" | grep -v -F "Thin volume ${VG_NAME}/${LV_NAME} maps " || true)"

  if [[ -n "$filtered" ]]; then
    warn "Existem avisos maps>size em outros volumes do VG. Eles nao bloqueiam este CT, mas devem ser corrigidos:"
    printf '%s\n' "$filtered" >&2
  fi
}

get_pool_info() {
  POOL_LV="$(lvs --noheadings -o pool_lv "${VG_NAME}/${LV_NAME}" 2>/dev/null | xargs || true)"
  POOL_DATA_PCT=""
  POOL_META_PCT=""
  POOL_DISCARDS=""

  if [[ -n "$POOL_LV" ]]; then
    POOL_DATA_PCT="$(lvs --noheadings -o data_percent "${VG_NAME}/${POOL_LV}" 2>/dev/null | tr -d ' %' | head -n1 || true)"
    POOL_META_PCT="$(lvs --noheadings -o metadata_percent "${VG_NAME}/${POOL_LV}" 2>/dev/null | tr -d ' %' | head -n1 || true)"
    POOL_DISCARDS="$(lvs --noheadings -o discards "${VG_NAME}/${POOL_LV}" 2>/dev/null | xargs || true)"
  fi
}

check_pool_guard() {
  get_pool_info

  if [[ -z "$POOL_LV" ]]; then
    log "Volume LVM convencional detectado; nao e LVM-thin."
    return 0
  fi

  log "Thin pool ${VG_NAME}/${POOL_LV}: Data=${POOL_DATA_PCT:-n/a}% Meta=${POOL_META_PCT:-n/a}% Discards=${POOL_DISCARDS:-n/a}"

  if [[ -n "$POOL_DATA_PCT" ]] && float_ge "$POOL_DATA_PCT" "$POOL_ABORT_PCT"; then
    if (( FORCE_HIGH_POOL == 0 )); then
      die "Data% do thin pool esta em ${POOL_DATA_PCT}% e atingiu o limite de ${POOL_ABORT_PCT}%."
    fi
    warn "Continuando com Data% alto porque --force-high-pool foi usado."
  fi

  if [[ -n "$POOL_META_PCT" ]] && float_ge "$POOL_META_PCT" "$POOL_META_ABORT_PCT"; then
    if (( FORCE_HIGH_POOL == 0 )); then
      die "Meta% do thin pool esta em ${POOL_META_PCT}% e atingiu o limite de ${POOL_META_ABORT_PCT}%."
    fi
    warn "Continuando com Meta% alto porque --force-high-pool foi usado."
  fi

  if [[ "$POOL_DISCARDS" == "ignore" ]]; then
    warn "O thin pool esta com discards=ignore. O descarte da cauda pode nao liberar chunks."
  fi
}

check_snapshots() {
  local config_snaps lvm_snaps own_origin

  config_snaps="$(grep -E '^\[[^]]+\]$' "$CONF" | grep -v -E '^\[PENDING\]$' || true)"
  if [[ -n "$config_snaps" ]]; then
    printf '%s\n' "$config_snaps" >&2
    die "O CT possui snapshots registrados no arquivo de configuracao. Remova-os antes da reducao."
  fi

  lvm_snaps="$(
    lvs --noheadings --separator '|' -o lv_name,origin "$VG_NAME" 2>/dev/null |
      awk -F'|' -v origin="$LV_NAME" '
        {
          gsub(/^[ \t]+|[ \t]+$/, "", $1)
          gsub(/^[ \t]+|[ \t]+$/, "", $2)
          if ($2 == origin) print $1
        }
      '
  )"

  if [[ -n "$lvm_snaps" ]]; then
    printf '%s\n' "$lvm_snaps" >&2
    die "Existem snapshots LVM/thin originados de ${VG_NAME}/${LV_NAME}. Remova-os antes da reducao."
  fi

  own_origin="$(lvs --noheadings -o origin "${VG_NAME}/${LV_NAME}" 2>/dev/null | xargs || true)"
  if [[ -n "$own_origin" ]]; then
    die "O rootfs e um snapshot/clone LVM com origin '$own_origin'. Este script recusa volumes com origin."
  fi
}

stop_ct() {
  local status

  status="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$status" ]] || die "Nao foi possivel obter o status do CT $CTID"

  if [[ "$status" == "stopped" ]]; then
    if (( WAS_RUNNING == 1 && DRY_RUN == 0 )); then
      # O CT estava ativo no inicio, mas algum passo anterior o deixou parado.
      # Marque para que o estado original seja restaurado ao final.
      STOPPED_BY_SCRIPT=1
    fi
    return 0
  fi

  WAS_RUNNING=1

  if (( DRY_RUN == 1 )); then
    log "[dry-run] pct shutdown $CTID --timeout $STOP_TIMEOUT"
    log "[dry-run] pct stop $CTID, caso o shutdown falhasse"
    return 0
  fi

  log "Parando CT $CTID de forma graciosa..."
  if ! pct shutdown "$CTID" --timeout "$STOP_TIMEOUT"; then
    warn "Shutdown gracioso falhou; executando pct stop."
    pct stop "$CTID"
  fi

  STOPPED_BY_SCRIPT=1

  status="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
  [[ "$status" == "stopped" ]] || die "O CT $CTID nao ficou parado."
}

start_ct() {
  local status

  if (( WAS_RUNNING == 0 || CT_STARTED == 1 )); then
    return 0
  fi

  if (( DRY_RUN == 1 )); then
    log "[dry-run] pct start $CTID"
    CT_STARTED=1
    return 0
  fi

  status="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$status" == "running" ]]; then
    CT_STARTED=1
    return 0
  fi

  log "Iniciando CT $CTID..."
  pct start "$CTID"
  CT_STARTED=1
}

run_e2fsck() {
  local label="$1" rc
  local -a args=(-f -p -v)

  if (( FSCK_AUTO_FIX == 1 )); then
    args=(-f -y -v)
  fi

  log "Executando e2fsck (${label}, modo $([[ $FSCK_AUTO_FIX -eq 1 ]] && printf 'auto-fix' || printf 'seguro'))..."

  if (( DRY_RUN == 1 )); then
    log "[dry-run] e2fsck ${args[*]} $VOLPATH"
    return 0
  fi

  set +e
  e2fsck "${args[@]}" "$VOLPATH"
  rc=$?
  set -e

  case "$rc" in
    0) log "e2fsck: filesystem limpo." ;;
    1) log "e2fsck: erros corrigidos." ;;
    2) log "e2fsck: correcoes aplicadas; codigo de reinicializacao aceito para volume offline." ;;
    4)
      if (( FSCK_AUTO_FIX == 0 )); then
        die "e2fsck encontrou erros que exigem reparo adicional. Execute manualmente ou repita com --fsck-auto-fix."
      fi
      die "e2fsck deixou erros nao corrigidos mesmo com --fsck-auto-fix."
      ;;
    *) die "e2fsck falhou com codigo $rc" ;;
  esac
}

stop_ct_for_rollback() {
  local status

  status="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$status" == "running" ]]; then
    warn "O CT esta ativo durante o rollback; parando-o antes de tocar no volume."
    pct stop "$CTID" || return 1
  fi

  CT_STARTED=0
  STOPPED_BY_SCRIPT=1
  return 0
}

rollback_volume() {
  local ok=0 actual_bytes

  (( ROLLBACK_IN_PROGRESS == 0 )) || return 1
  ROLLBACK_IN_PROGRESS=1

  warn "Tentando rollback para o tamanho original de ${CUR_BYTES} bytes..."

  if ! stop_ct_for_rollback; then
    warn "Nao foi possivel parar o CT para executar o rollback."
    return 1
  fi

  set +e

  # Verifique o tamanho real mesmo que lvreduce tenha retornado erro.
  # Assim, uma reducao parcial tambem e recuperada.
  actual_bytes="$(blockdev --getsize64 "$VOLPATH" 2>/dev/null || printf '0')"
  if (( actual_bytes > 0 && actual_bytes < CUR_BYTES )); then
    lvextend -L "${CUR_BYTES}B" -y "$VOLPATH"
    ok=$?
    if (( ok != 0 )); then
      warn "Falha ao restaurar o tamanho original do LV."
      set -e
      return 1
    fi
  fi

  if (( FS_SHRUNK == 1 )); then
    e2fsck -f -p "$VOLPATH" >/dev/null 2>&1
    ok=$?
    if (( ok > 2 )); then
      warn "e2fsck falhou durante o rollback com codigo $ok."
      set -e
      return 1
    fi

    resize2fs "$VOLPATH"
    ok=$?
    if (( ok != 0 )); then
      warn "Falha ao expandir novamente o ext4 durante o rollback."
      set -e
      return 1
    fi
  fi

  if (( CONF_CHANGED == 1 )) && [[ -n "$ROOTFS_LINE_ORIGINAL" ]]; then
    write_rootfs_line "$ROOTFS_LINE_ORIGINAL"
    ok=$?
    if (( ok != 0 )); then
      warn "Falha ao restaurar a linha rootfs original."
      set -e
      return 1
    fi
  fi

  sync
  set -e
  log "Rollback concluido."
  return 0
}

cleanup() {
  local rc=$? rollback_ok=1

  trap - EXIT INT TERM
  set +e

  if (( rc != 0 && DRY_RUN == 0 )); then
    if (( FS_SHRUNK == 1 || LV_SHRUNK == 1 || CONF_CHANGED == 1 )); then
      rollback_volume || rollback_ok=0
    fi
  fi

  if (( WAS_RUNNING == 1 && STOPPED_BY_SCRIPT == 1 )); then
    if (( rollback_ok == 1 )); then
      local status
      status="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
      if [[ "$status" != "running" ]]; then
        log "Restaurando o estado anterior do CT..."
        pct start "$CTID" || warn "Nao foi possivel reiniciar o CT $CTID automaticamente."
      fi
    else
      warn "O CT permanecera parado porque o rollback nao foi concluido."
    fi
  fi

  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-gib)
      [[ $# -ge 2 ]] || die "Valor ausente para --target-gib"
      is_uint "$2" || die "--target-gib precisa ser inteiro"
      (( 10#$2 > 0 )) || die "--target-gib precisa ser maior que zero"
      TARGET_OVERRIDE_GIB="$2"
      shift 2
      ;;
    --safety-gib)
      [[ $# -ge 2 ]] || die "Valor ausente para --safety-gib"
      is_uint "$2" || die "--safety-gib precisa ser inteiro"
      SAFETY_GIB="$2"
      shift 2
      ;;
    --min-free-gib)
      [[ $# -ge 2 ]] || die "Valor ausente para --min-free-gib"
      is_uint "$2" || die "--min-free-gib precisa ser inteiro"
      MIN_FREE_GIB="$2"
      shift 2
      ;;
    --max-fs-usage-pct)
      [[ $# -ge 2 ]] || die "Valor ausente para --max-fs-usage-pct"
      is_number "$2" || die "--max-fs-usage-pct precisa ser numerico"
      float_gt "$2" 0 || die "--max-fs-usage-pct precisa ser maior que zero"
      float_gt 100 "$2" || die "--max-fs-usage-pct precisa ser menor que 100"
      MAX_FS_USAGE_PCT="$2"
      shift 2
      ;;
    --skip-bk|--skip-backup)
      SKIP_BACKUP=1
      shift
      ;;
    --backup-storage)
      [[ $# -ge 2 ]] || die "Valor ausente para --backup-storage"
      BACKUP_STORAGE="$2"
      shift 2
      ;;
    --force-high-pool)
      FORCE_HIGH_POOL=1
      shift
      ;;
    --pool-abort-pct)
      [[ $# -ge 2 ]] || die "Valor ausente para --pool-abort-pct"
      is_number "$2" || die "--pool-abort-pct precisa ser numerico"
      float_gt "$2" 0 || die "--pool-abort-pct precisa ser maior que zero"
      float_gt 100 "$2" || die "--pool-abort-pct precisa ser menor que 100"
      POOL_ABORT_PCT="$2"
      shift 2
      ;;
    --pool-meta-abort-pct)
      [[ $# -ge 2 ]] || die "Valor ausente para --pool-meta-abort-pct"
      is_number "$2" || die "--pool-meta-abort-pct precisa ser numerico"
      float_gt "$2" 0 || die "--pool-meta-abort-pct precisa ser maior que zero"
      float_gt 100 "$2" || die "--pool-meta-abort-pct precisa ser menor que 100"
      POOL_META_ABORT_PCT="$2"
      shift 2
      ;;
    --no-pre-fstrim)
      PRE_FSTRIM=0
      shift
      ;;
    --allow-no-tail-discard)
      REQUIRE_TAIL_DISCARD=0
      shift
      ;;
    --post-fstrim)
      POST_FSTRIM=1
      shift
      ;;
    --fsck-auto-fix)
      FSCK_AUTO_FIX=1
      shift
      ;;
    --stop-timeout)
      [[ $# -ge 2 ]] || die "Valor ausente para --stop-timeout"
      is_uint "$2" || die "--stop-timeout precisa ser inteiro"
      (( 10#$2 > 0 )) || die "--stop-timeout precisa ser maior que zero"
      STOP_TIMEOUT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      SUCCESS=1
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Opcao desconhecida: $1"
      ;;
    *)
      break
      ;;
  esac
done

CTID="${1:-}"
[[ -n "$CTID" ]] || die "Informe o CTID. Use --help para ajuda."
is_uint "$CTID" || die "CTID precisa ser numerico"
[[ $# -eq 1 ]] || die "Argumentos adicionais inesperados: ${*:2}"

for cmd in \
  pct pvesm vzdump e2fsck resize2fs lvreduce lvextend lvchange blkid dumpe2fs \
  awk sed grep findmnt blockdev lvs vgs xargs sleep tr readlink mktemp blkdiscard sync flock ha-manager; do
  if [[ "$cmd" == "vzdump" && "$SKIP_BACKUP" -eq 1 ]]; then
    continue
  fi
  require_cmd "$cmd"
done

if [[ -f "/etc/pve/qemu-server/${CTID}.conf" && ! -f "/etc/pve/lxc/${CTID}.conf" ]]; then
  die "O ID $CTID pertence a uma VM QEMU. Use um script separado para VMs."
fi

CONF="/etc/pve/lxc/${CTID}.conf"
[[ -f "$CONF" ]] || die "Configuracao LXC nao encontrada: $CONF"

exec 9>"/run/lock/safe-reduce-ct-${CTID}.lock"
flock -n 9 || die "Ja existe outra execucao deste script para o CT $CTID."

CURRENT_LOCK="$(awk -F': *' '/^\[/ {exit} $1 == "lock" {print $2; exit}' "$CONF" || true)"
[[ -z "$CURRENT_LOCK" ]] || die "O CT possui lock Proxmox ativo: $CURRENT_LOCK"

IS_TEMPLATE="$(awk -F': *' '/^\[/ {exit} $1 == "template" {print $2; exit}' "$CONF" || true)"
[[ "$IS_TEMPLATE" != "1" ]] || die "O CT $CTID e um template. Converta-o em CT normal antes da reducao."

HA_CONFIG="$(ha-manager config --type ct 2>/dev/null || true)"
if awk -v sid="ct:${CTID}" '$1 == sid { found=1 } END { exit !found }' <<< "$HA_CONFIG"; then
  die "O CT $CTID e gerenciado pelo HA (ct:${CTID}). Remova-o temporariamente do HA ou trate o estado HA manualmente antes da reducao."
fi

ROOTFS_LINE_ORIGINAL="$(grep -E '^rootfs:' "$CONF" | head -n1 || true)"
[[ -n "$ROOTFS_LINE_ORIGINAL" ]] || die "Linha rootfs nao encontrada em $CONF"

ROOTFS_VALUE="${ROOTFS_LINE_ORIGINAL#rootfs:}"
ROOTFS_VALUE="${ROOTFS_VALUE# }"
ROOTVOL="${ROOTFS_VALUE%%,*}"
ROOTVOL="${ROOTVOL#volume=}"
[[ "$ROOTVOL" == *:* ]] || die "Formato rootfs inesperado: $ROOTVOL"

detect_storage_type
resolve_lvm_volume "$ROOTVOL"
log "CTID=$CTID rootfs=$ROOTVOL"
log "Caminho retornado pelo Proxmox: $PVE_VOLPATH"
log "Dispositivo canonico:           $CANON_VOLPATH"
log "LV identificado:                ${VG_NAME}/${LV_NAME} ($VOLPATH, attr=${LV_ATTR:-n/a})"

CUR_BYTES="$(blockdev --getsize64 "$VOLPATH" 2>/dev/null || true)"
[[ -n "$CUR_BYTES" && "$CUR_BYTES" -gt 0 ]] || die "Nao foi possivel determinar o tamanho atual do LV"

STATUS="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
[[ -n "$STATUS" ]] || die "Nao foi possivel consultar o status do CT"
if [[ "$STATUS" != "stopped" ]]; then
  WAS_RUNNING=1
fi

if (( DRY_RUN == 1 )); then
  warn "Dry-run nao para o CT. A estimativa sera revalidada offline numa execucao real."
fi

check_pool_guard
check_snapshots

if current_lv_has_maps_warning; then
  die "O volume atual ja apresenta maps>size/Data%>100. Corrija essa inconsistencia antes de reduzir."
fi
report_other_maps_warnings

detect_backup_storage

if (( SKIP_BACKUP == 0 )); then
  log "Criando backup via vzdump antes de qualquer operacao destrutiva..."
  if (( WAS_RUNNING == 1 && DRY_RUN == 0 )); then
    # O modo stop pode deixar o CT parado em caso de falha do vzdump.
    STOPPED_BY_SCRIPT=1
  fi
  if [[ -n "$BACKUP_STORAGE" ]]; then
    run_or_log vzdump "$CTID" --mode "$BACKUP_MODE" --compress "$BACKUP_COMPRESS" --storage "$BACKUP_STORAGE"
  else
    run_or_log vzdump "$CTID" --mode "$BACKUP_MODE" --compress "$BACKUP_COMPRESS"
  fi
  log "Backup concluido."

  CURRENT_LOCK="$(awk -F': *' '/^\[/ {exit} $1 == "lock" {print $2; exit}' "$CONF" || true)"
  [[ -z "$CURRENT_LOCK" ]] || die "O backup terminou, mas o CT permaneceu com lock Proxmox ativo: $CURRENT_LOCK"
else
  warn "Backup ignorado por solicitacao explicita (--skip-bk)."
fi

CURRENT_STATUS="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || true)"
if (( PRE_FSTRIM == 1 )) && [[ -n "$POOL_LV" && "$CURRENT_STATUS" == "running" ]]; then
  log "Executando fstrim no CT antes da parada para liberar blocos livres do thin pool..."
  if (( DRY_RUN == 1 )); then
    log "[dry-run] pct fstrim $CTID"
  else
    pct fstrim "$CTID" || warn "pct fstrim falhou; a reducao continuara e o descarte da cauda ainda sera tentado."
  fi
fi

stop_ct

if (( DRY_RUN == 0 )); then
  MOUNT_INFO="$(
    findmnt -rn -S "$VOLPATH" 2>/dev/null || true
    if [[ "$CANON_VOLPATH" != "$VOLPATH" ]]; then
      findmnt -rn -S "$CANON_VOLPATH" 2>/dev/null || true
    fi
  )"
  if [[ -n "$MOUNT_INFO" ]]; then
    printf '%s\n' "$MOUNT_INFO" >&2
    die "O volume ainda esta montado no host apos a parada do CT."
  fi
fi

FSTYPE="$(blkid -o value -s TYPE "$VOLPATH" 2>/dev/null || true)"
[[ "$FSTYPE" == "ext4" ]] || die "Filesystem incompativel: esperado ext4, detectado ${FSTYPE:-desconhecido}"

run_e2fsck "pre-shrink"

BLKSZ="$(dumpe2fs -h "$VOLPATH" 2>/dev/null | awk -F': *' '/^Block size:/ {print $2; exit}' | tr -d '[:space:]')"
BLOCK_COUNT="$(dumpe2fs -h "$VOLPATH" 2>/dev/null | awk -F': *' '/^Block count:/ {print $2; exit}' | tr -d '[:space:]')"
FREE_BLOCKS="$(dumpe2fs -h "$VOLPATH" 2>/dev/null | awk -F': *' '/^Free blocks:/ {print $2; exit}' | tr -d '[:space:]')"
MINBLOCKS="$(resize2fs -P "$VOLPATH" 2>/dev/null | awk -F': *' '/Estimated minimum size/ {print $2; exit}' | tr -d '[:space:]')"

for value_name in BLKSZ BLOCK_COUNT FREE_BLOCKS MINBLOCKS; do
  value="${!value_name:-}"
  [[ -n "$value" && "$value" =~ ^[0-9]+$ ]] || die "Nao foi possivel obter $value_name do ext4"
done

PE_BYTES="$(vgs "$VG_NAME" --noheadings --units b --nosuffix -o vg_extent_size 2>/dev/null | awk '{printf "%.0f\n", $1; exit}')"
[[ -n "$PE_BYTES" && "$PE_BYTES" =~ ^[0-9]+$ && "$PE_BYTES" -gt 0 ]] || die "Nao foi possivel determinar o extent size do VG"

MIB_BYTES=$((1024 * 1024))
GIB_BYTES=$((1024 * 1024 * 1024))

if (( GIB_BYTES % PE_BYTES != 0 )); then
  die "Extent size do VG (${PE_BYTES} bytes) nao permite alinhamento exato de 1 GiB"
fi

MIN_BYTES=$((MINBLOCKS * BLKSZ))
USED_BYTES=$(((BLOCK_COUNT - FREE_BLOCKS) * BLKSZ))
SAFETY_BYTES=$((SAFETY_GIB * GIB_BYTES))
MIN_FREE_BYTES=$((MIN_FREE_GIB * GIB_BYTES))

FS_FLOOR_BYTES=$((MIN_BYTES + SAFETY_BYTES))
FREE_FLOOR_BYTES=$((USED_BYTES + MIN_FREE_BYTES))
USAGE_FLOOR_BYTES="$(
  awk -v used="$USED_BYTES" -v pct="$MAX_FS_USAGE_PCT" '
    BEGIN {
      x=(used*100)/pct
      if (x == int(x)) printf "%.0f\n", x
      else printf "%.0f\n", int(x)+1
    }
  '
)"

RAW_TARGET_BYTES="$FS_FLOOR_BYTES"
TARGET_REASON="minimo ext4 + margem"

if (( FREE_FLOOR_BYTES > RAW_TARGET_BYTES )); then
  RAW_TARGET_BYTES="$FREE_FLOOR_BYTES"
  TARGET_REASON="espaco livre minimo"
fi

if (( USAGE_FLOOR_BYTES > RAW_TARGET_BYTES )); then
  RAW_TARGET_BYTES="$USAGE_FLOOR_BYTES"
  TARGET_REASON="percentual maximo de uso"
fi

SAFE_TARGET_GIB="$(ceil_div "$RAW_TARGET_BYTES" "$GIB_BYTES")"
SAFE_TARGET_BYTES=$((SAFE_TARGET_GIB * GIB_BYTES))

if [[ -n "$TARGET_OVERRIDE_GIB" ]]; then
  TARGET_BYTES=$((TARGET_OVERRIDE_GIB * GIB_BYTES))
  if (( TARGET_BYTES < SAFE_TARGET_BYTES )); then
    die "Alvo solicitado (${TARGET_OVERRIDE_GIB} GiB) e menor que o minimo seguro calculado (${SAFE_TARGET_GIB} GiB)."
  fi
  TARGET_GIB="$TARGET_OVERRIDE_GIB"
  TARGET_REASON="alvo explicito aprovado"
else
  TARGET_BYTES="$SAFE_TARGET_BYTES"
  TARGET_GIB="$SAFE_TARGET_GIB"
fi

TARGET_STR="${TARGET_GIB}G"
CUR_GIB_CEIL="$(ceil_div "$CUR_BYTES" "$GIB_BYTES")"
MIN_MIB="$(ceil_div "$MIN_BYTES" "$MIB_BYTES")"
PRED_FREE_BYTES=$((TARGET_BYTES - USED_BYTES))
PRED_USAGE_PCT="$(awk -v used="$USED_BYTES" -v total="$TARGET_BYTES" 'BEGIN { printf "%.2f", (used/total)*100 }')"

log "Resumo da auditoria:"
log "  LV atual:                 ${CUR_BYTES} bytes (~${CUR_GIB_CEIL} GiB)"
log "  Dados/blocos usados:      $((USED_BYTES / MIB_BYTES)) MiB"
log "  Minimo estimado ext4:     ${MIN_MIB} MiB"
log "  Piso minimo + margem:     $(ceil_div "$FS_FLOOR_BYTES" "$GIB_BYTES") GiB"
log "  Piso por espaco livre:    $(ceil_div "$FREE_FLOOR_BYTES" "$GIB_BYTES") GiB"
log "  Piso por uso maximo:      $(ceil_div "$USAGE_FLOOR_BYTES" "$GIB_BYTES") GiB"
log "  Alvo escolhido:           ${TARGET_GIB} GiB (${TARGET_REASON})"
log "  Uso previsto:             ${PRED_USAGE_PCT}%"
log "  Livre fisico previsto:    $((PRED_FREE_BYTES / GIB_BYTES)) GiB"

if (( TARGET_BYTES >= CUR_BYTES )); then
  log "Nao ha reducao segura possivel com as regras atuais: alvo >= tamanho atual."
  start_ct
  SUCCESS=1
  exit 0
fi

if (( PRED_FREE_BYTES < MIN_FREE_BYTES )); then
  die "Erro interno de calculo: livre previsto abaixo de ${MIN_FREE_GIB} GiB"
fi

if float_gt "$PRED_USAGE_PCT" "$MAX_FS_USAGE_PCT"; then
  die "Erro interno de calculo: uso previsto acima de ${MAX_FS_USAGE_PCT}%"
fi

log "Reduzindo o ext4 para $TARGET_STR..."
run_or_log resize2fs -p "$VOLPATH" "$TARGET_STR"
if (( DRY_RUN == 0 )); then
  FS_SHRUNK=1
fi

TAIL_BYTES=$((CUR_BYTES - TARGET_BYTES))
if [[ -n "$POOL_LV" && "$TAIL_BYTES" -gt 0 ]]; then
  log "Descartando ${TAIL_BYTES} bytes da cauda que deixaram de pertencer ao ext4..."

  if (( DRY_RUN == 1 )); then
    log "[dry-run] blkdiscard --force --offset $TARGET_BYTES --length $TAIL_BYTES $VOLPATH"
  else
    if ! blkdiscard --force --offset "$TARGET_BYTES" --length "$TAIL_BYTES" "$VOLPATH"; then
      if (( REQUIRE_TAIL_DISCARD == 1 )); then
        die "O descarte da cauda falhou. A reducao foi interrompida antes do lvreduce."
      fi
      warn "O descarte da cauda falhou, mas --allow-no-tail-discard permite continuar."
    fi
  fi
fi

log "Reduzindo o LV para $TARGET_STR..."
run_or_log lvreduce -L "$TARGET_STR" -y "$VOLPATH"
if (( DRY_RUN == 0 )); then
  LV_SHRUNK=1
fi

run_e2fsck "post-shrink"

if (( DRY_RUN == 0 )); then
  ACTUAL_BYTES="$(blockdev --getsize64 "$VOLPATH")"
  [[ "$ACTUAL_BYTES" -eq "$TARGET_BYTES" ]] || die "Tamanho real do LV (${ACTUAL_BYTES}) difere do alvo (${TARGET_BYTES})"

  if current_lv_has_maps_warning; then
    die "O volume atual apresentou maps>size/Data%>100 apos o lvreduce."
  fi
fi

set_conf_size "$TARGET_STR"

if (( DRY_RUN == 0 )); then
  sync
fi

start_ct

if (( WAS_RUNNING == 1 )); then
  log "Validacao do filesystem dentro do CT:"
  if (( DRY_RUN == 1 )); then
    log "[dry-run] pct exec $CTID -- df -h /"
  elif ! pct exec "$CTID" -- df -h /; then
    die "O CT iniciou, mas a validacao interna falhou. O script tentara rollback com o CT parado."
  fi
fi

if (( POST_FSTRIM == 1 && WAS_RUNNING == 1 )); then
  log "Executando fstrim final..."
  if (( DRY_RUN == 1 )); then
    log "[dry-run] pct fstrim $CTID"
  else
    pct fstrim "$CTID" || warn "O fstrim final falhou."
  fi
fi

log "Tamanho final no host:"
run_or_log blockdev --getsize64 "$VOLPATH"
log "Reducao concluida com sucesso."

SUCCESS=1
exit 0
