#!/usr/bin/env bash
#
# pve-ct-io-limit.sh
# Limita leitura e escrita de CTs LXC no Proxmox usando cgroup v2 io.max.
#
# Uso rápido:
#   ./pve-ct-io-limit.sh 122 50
#
# Comandos:
#   ./pve-ct-io-limit.sh set CTID MBPS
#   ./pve-ct-io-limit.sh set CTID READ_MBPS WRITE_MBPS
#   ./pve-ct-io-limit.sh status CTID
#   ./pve-ct-io-limit.sh refresh CTID
#   ./pve-ct-io-limit.sh remove CTID
#
# MBPS é interpretado como MiB/s: 1 MiB = 1024 * 1024 bytes.
#
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
BEGIN_MARKER="# BEGIN managed by pve-ct-io-limit.sh"
END_MARKER="# END managed by pve-ct-io-limit.sh"

info() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'AVISO: %s\n' "$*" >&2
}

die() {
    printf 'ERRO: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Uso:
  $SCRIPT_NAME CTID MBPS
  $SCRIPT_NAME set CTID MBPS
  $SCRIPT_NAME set CTID READ_MBPS WRITE_MBPS
  $SCRIPT_NAME status CTID
  $SCRIPT_NAME refresh CTID
  $SCRIPT_NAME remove CTID

Exemplos:
  $SCRIPT_NAME 122 50
  $SCRIPT_NAME set 122 50
  $SCRIPT_NAME set 122 100 50
  $SCRIPT_NAME status 122
  $SCRIPT_NAME remove 122

Observações:
  - Execute no host Proxmox como root.
  - 50 significa 50 MiB/s para leitura e 50 MiB/s para escrita.
  - O limite é aplicado por dispositivo. Se o CT usar discos em dispositivos
    diferentes, cada dispositivo receberá o limite informado.
  - Volumes ZFS/Ceph que não aparecem como dispositivo de bloco podem não ser
    limitáveis por este método.
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "execute como root no host Proxmox."
}

require_commands() {
    local cmd
    for cmd in pct pvesm lxc-info findmnt lsblk readlink awk sed grep sort mktemp flock; do
        command -v "$cmd" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $cmd"
    done
}

validate_ctid() {
    local ctid="$1"
    [[ "$ctid" =~ ^[0-9]+$ ]] || die "CTID inválido: $ctid"
    [[ -f "/etc/pve/lxc/${ctid}.conf" ]] || die "CT $ctid não encontrado em /etc/pve/lxc."
}

validate_rate() {
    local value="$1"
    [[ "$value" =~ ^([0-9]+)([.][0-9]+)?$ ]] || die "taxa inválida: $value"
    awk -v value="$value" 'BEGIN { exit !(value > 0) }' ||
        die "a taxa deve ser maior que zero."
}

mib_to_bps() {
    local mib="$1"
    awk -v mib="$mib" 'BEGIN { printf "%.0f", mib * 1024 * 1024 }'
}

ct_is_running() {
    local ctid="$1"
    pct status "$ctid" 2>/dev/null | grep -q 'status: running'
}

get_ct_cgroup_dir() {
    local ctid="$1"
    local init_pid rel candidate

    init_pid="$(lxc-info -n "$ctid" -pH 2>/dev/null || true)"
    if [[ "$init_pid" =~ ^[0-9]+$ && -r "/proc/${init_pid}/cgroup" ]]; then
        rel="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/${init_pid}/cgroup")"
        if [[ -n "$rel" ]]; then
            candidate="/sys/fs/cgroup${rel}"
            while [[ "$candidate" != "/sys/fs/cgroup" && "$candidate" != "/" ]]; do
                if [[ -e "$candidate/io.max" ]]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                candidate="${candidate%/*}"
                [[ -n "$candidate" ]] || candidate="/"
            done
        fi
    fi

    for candidate in \
        "/sys/fs/cgroup/lxc/${ctid}/ns" \
        "/sys/fs/cgroup/lxc/${ctid}"
    do
        if [[ -e "$candidate/io.max" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

collect_volume_specs() {
    local ctid="$1"

    pct config "$ctid" |
        awk -F': ' '
            /^(rootfs|mp[0-9]+): / {
                label=$1
                value=$2
                split(value, parts, ",")
                volume=parts[1]
                sub(/^volume=/, "", volume)
                print label "|" volume
            }
        '
}

resolve_volume_device() {
    local label="$1"
    local volume="$2"
    local target source device majmin

    if [[ "$volume" == /* ]]; then
        target="$volume"
    else
        target="$(pvesm path "$volume" 2>/dev/null || true)"
    fi

    if [[ -z "$target" ]]; then
        warn "$label ($volume): não foi possível resolver o caminho."
        return 1
    fi

    if [[ -b "$target" ]]; then
        device="$(readlink -f "$target")"
    elif [[ -e "$target" ]]; then
        source="$(findmnt -T "$target" -n -o SOURCE 2>/dev/null | head -n 1 || true)"
        source="${source%%[*}"

        if [[ "$source" != /dev/* ]]; then
            warn "$label ($volume): origem '$source' não é um dispositivo de bloco; ignorado."
            return 1
        fi

        device="$(readlink -f "$source")"
    else
        warn "$label ($volume): caminho '$target' não existe; ignorado."
        return 1
    fi

    [[ -b "$device" ]] || {
        warn "$label ($volume): '$device' não é um dispositivo de bloco; ignorado."
        return 1
    }

    majmin="$(lsblk -dnro MAJ:MIN "$device" 2>/dev/null | head -n 1 || true)"
    [[ "$majmin" =~ ^[0-9]+:[0-9]+$ ]] || {
        warn "$label ($volume): não foi possível obter MAJ:MIN de '$device'."
        return 1
    }

    printf '%s|%s|%s|%s\n' "$majmin" "$device" "$label" "$volume"
}

discover_devices() {
    local ctid="$1"
    local entry label volume resolved majmin device
    declare -gA DEVICES=()
    declare -gA DEVICE_LABELS=()
    declare -gA DEVICE_VOLUMES=()

    while IFS='|' read -r label volume; do
        [[ -n "${label:-}" && -n "${volume:-}" ]] || continue

        resolved="$(resolve_volume_device "$label" "$volume" || true)"
        [[ -n "$resolved" ]] || continue

        IFS='|' read -r majmin device label volume <<<"$resolved"

        DEVICES["$majmin"]="$device"

        if [[ -n "${DEVICE_LABELS[$majmin]:-}" ]]; then
            DEVICE_LABELS["$majmin"]+=",${label}"
            DEVICE_VOLUMES["$majmin"]+=",${volume}"
        else
            DEVICE_LABELS["$majmin"]="$label"
            DEVICE_VOLUMES["$majmin"]="$volume"
        fi
    done < <(collect_volume_specs "$ctid")

    ((${#DEVICES[@]} > 0)) ||
        die "nenhum dispositivo de bloco compatível foi encontrado para o CT $ctid."
}

sorted_majmins() {
    printf '%s\n' "${!DEVICES[@]}" | sort -t: -k1,1n -k2,2n
}

show_devices() {
    local majmin

    printf '%-10s %-30s %-16s %s\n' "MAJ:MIN" "DISPOSITIVO" "MONTAGEM" "VOLUME"
    while IFS= read -r majmin; do
        printf '%-10s %-30s %-16s %s\n' \
            "$majmin" \
            "${DEVICES[$majmin]}" \
            "${DEVICE_LABELS[$majmin]}" \
            "${DEVICE_VOLUMES[$majmin]}"
    done < <(sorted_majmins)
}

make_config_block() {
    local read_mib="$1"
    local write_mib="$2"
    local read_bps="$3"
    local write_bps="$4"
    local majmin

    cat <<EOF
$BEGIN_MARKER
# read_mibps=$read_mib write_mibps=$write_mib
# Reexecute "$SCRIPT_NAME refresh CTID" após migração ou alteração de storage.
EOF

    while IFS= read -r majmin; do
        printf 'lxc.cgroup2.io.max: %s rbps=%s wbps=%s\n' \
            "$majmin" "$read_bps" "$write_bps"
    done

    printf '%s\n' "$END_MARKER"
}

strip_managed_block() {
    local input="$1"

    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { skip=1; next }
        $0 == end   { skip=0; next }
        !skip       { print }
    ' "$input"
}

write_config_block() {
    local ctid="$1"
    local block_file="$2"
    local conf="/etc/pve/lxc/${ctid}.conf"
    local stripped temp backup

    stripped="$(mktemp)"
    temp="$(mktemp)"
    backup="/root/${ctid}.conf.$(date +%Y%m%d-%H%M%S).bak"

    trap 'rm -f "${stripped:-}" "${temp:-}"' RETURN

    cp -- "$conf" "$backup"
    strip_managed_block "$conf" >"$stripped"

    awk -v block_file="$block_file" '
        function emit_block( line) {
            while ((getline line < block_file) > 0) {
                print line
            }
            close(block_file)
        }

        /^\[[^]]+\]$/ && !inserted {
            emit_block()
            inserted=1
        }

        { print }

        END {
            if (!inserted) {
                emit_block()
            }
        }
    ' "$stripped" >"$temp"

    cat "$temp" >"$conf"

    if ! pct config "$ctid" >/dev/null 2>&1; then
        cat "$backup" >"$conf"
        die "o Proxmox rejeitou a configuração; backup restaurado de $backup"
    fi

    info "configuração persistente gravada em $conf"
    info "backup criado em $backup"
}

remove_config_block() {
    local ctid="$1"
    local conf="/etc/pve/lxc/${ctid}.conf"
    local temp backup

    temp="$(mktemp)"
    backup="/root/${ctid}.conf.$(date +%Y%m%d-%H%M%S).bak"
    trap 'rm -f "${temp:-}"' RETURN

    cp -- "$conf" "$backup"
    strip_managed_block "$conf" >"$temp"
    cat "$temp" >"$conf"

    if ! pct config "$ctid" >/dev/null 2>&1; then
        cat "$backup" >"$conf"
        die "o Proxmox rejeitou a configuração; backup restaurado de $backup"
    fi

    info "limite persistente removido de $conf"
    info "backup criado em $backup"
}

apply_live_limit() {
    local ctid="$1"
    local read_bps="$2"
    local write_bps="$3"
    local cgroup_dir majmin

    if ! ct_is_running "$ctid"; then
        info "CT $ctid está parado; o limite será aplicado na próxima inicialização."
        return 0
    fi

    cgroup_dir="$(get_ct_cgroup_dir "$ctid" || true)"
    [[ -n "$cgroup_dir" ]] ||
        die "não foi possível localizar o cgroup do CT $ctid."

    [[ -w "$cgroup_dir/io.max" ]] ||
        die "io.max não está disponível ou não pode ser escrito em $cgroup_dir."

    while IFS= read -r majmin; do
        printf '%s rbps=%s wbps=%s\n' \
            "$majmin" "$read_bps" "$write_bps" >"$cgroup_dir/io.max"
    done < <(sorted_majmins)

    info "limite aplicado imediatamente em $cgroup_dir/io.max"
}

remove_live_limit() {
    local ctid="$1"
    local cgroup_dir majmin
    local -A all_majmins=()

    if ! ct_is_running "$ctid"; then
        info "CT $ctid está parado; não há limite ativo para remover."
        return 0
    fi

    cgroup_dir="$(get_ct_cgroup_dir "$ctid" || true)"
    [[ -n "$cgroup_dir" ]] ||
        die "não foi possível localizar o cgroup do CT $ctid."

    while IFS= read -r majmin; do
        [[ "$majmin" =~ ^[0-9]+:[0-9]+$ ]] && all_majmins["$majmin"]=1
    done < <(
        awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
            $0 == begin { inside=1; next }
            $0 == end   { inside=0; next }
            inside && $1 == "lxc.cgroup2.io.max:" { print $2 }
        ' "/etc/pve/lxc/${ctid}.conf"
    )

    discover_devices "$ctid"
    while IFS= read -r majmin; do
        all_majmins["$majmin"]=1
    done < <(sorted_majmins)

    for majmin in "${!all_majmins[@]}"; do
        printf '%s rbps=max wbps=max\n' "$majmin" >"$cgroup_dir/io.max"
    done

    info "limites ativos removidos de $cgroup_dir/io.max"
}

read_saved_rates() {
    local ctid="$1"
    local conf="/etc/pve/lxc/${ctid}.conf"
    local line read_mib write_mib

    line="$(
        awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
            $0 == begin { inside=1; next }
            $0 == end   { inside=0; next }
            inside && /^# read_mibps=/ { print; exit }
        ' "$conf"
    )"

    [[ "$line" =~ read_mibps=([^[:space:]]+)[[:space:]]+write_mibps=([^[:space:]]+) ]] ||
        die "o CT $ctid não possui taxas salvas por este script."

    read_mib="${BASH_REMATCH[1]}"
    write_mib="${BASH_REMATCH[2]}"
    printf '%s|%s\n' "$read_mib" "$write_mib"
}

set_limit() {
    local ctid="$1"
    local read_mib="$2"
    local write_mib="$3"
    local read_bps write_bps block_file lock_file

    validate_ctid "$ctid"
    validate_rate "$read_mib"
    validate_rate "$write_mib"

    lock_file="/run/lock/pve-ct-io-limit-${ctid}.lock"
    exec 9>"$lock_file"
    flock -x 9

    discover_devices "$ctid"
    read_bps="$(mib_to_bps "$read_mib")"
    write_bps="$(mib_to_bps "$write_mib")"

    info "CT: $ctid"
    info "leitura: ${read_mib} MiB/s (${read_bps} bytes/s)"
    info "escrita: ${write_mib} MiB/s (${write_bps} bytes/s)"
    show_devices

    block_file="$(mktemp)"
    trap 'rm -f "${block_file:-}"' RETURN
    sorted_majmins | make_config_block \
        "$read_mib" "$write_mib" "$read_bps" "$write_bps" >"$block_file"

    write_config_block "$ctid" "$block_file"
    apply_live_limit "$ctid" "$read_bps" "$write_bps"

    info "concluído."
}

status_limit() {
    local ctid="$1"
    local conf cgroup_dir

    validate_ctid "$ctid"
    conf="/etc/pve/lxc/${ctid}.conf"

    printf '\nConfiguração persistente:\n'
    if grep -Fq "$BEGIN_MARKER" "$conf"; then
        awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
            $0 == begin { inside=1 }
            inside { print }
            $0 == end { inside=0 }
        ' "$conf"
    else
        printf '  Nenhum limite gerenciado por este script.\n'
    fi

    printf '\nDispositivos detectados atualmente:\n'
    if discover_devices "$ctid"; then
        show_devices
    fi

    printf '\nEstado em execução:\n'
    if ct_is_running "$ctid"; then
        cgroup_dir="$(get_ct_cgroup_dir "$ctid" || true)"
        if [[ -n "$cgroup_dir" && -r "$cgroup_dir/io.max" ]]; then
            printf 'Cgroup: %s\n' "$cgroup_dir"
            cat "$cgroup_dir/io.max"
        else
            printf '  Não foi possível ler io.max.\n'
        fi
    else
        printf '  CT parado.\n'
    fi
}

refresh_limit() {
    local ctid="$1"
    local rates read_mib write_mib

    validate_ctid "$ctid"
    rates="$(read_saved_rates "$ctid")"
    IFS='|' read -r read_mib write_mib <<<"$rates"
    set_limit "$ctid" "$read_mib" "$write_mib"
}

remove_limit() {
    local ctid="$1"
    local lock_file

    validate_ctid "$ctid"

    lock_file="/run/lock/pve-ct-io-limit-${ctid}.lock"
    exec 9>"$lock_file"
    flock -x 9

    remove_live_limit "$ctid"
    remove_config_block "$ctid"
    info "concluído."
}

main() {
    require_root
    require_commands

    if [[ $# -eq 2 && "$1" =~ ^[0-9]+$ ]]; then
        set_limit "$1" "$2" "$2"
        exit 0
    fi

    [[ $# -ge 1 ]] || {
        usage
        exit 1
    }

    case "$1" in
        set)
            if [[ $# -eq 3 ]]; then
                set_limit "$2" "$3" "$3"
            elif [[ $# -eq 4 ]]; then
                set_limit "$2" "$3" "$4"
            else
                usage
                exit 1
            fi
            ;;
        status)
            [[ $# -eq 2 ]] || {
                usage
                exit 1
            }
            status_limit "$2"
            ;;
        refresh)
            [[ $# -eq 2 ]] || {
                usage
                exit 1
            }
            refresh_limit "$2"
            ;;
        remove)
            [[ $# -eq 2 ]] || {
                usage
                exit 1
            }
            remove_limit "$2"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
