#!/usr/bin/env bash
# Automatiza GPU passthrough NVIDIA (host Proxmox -> container LXC -> Docker
# aninhado dentro do LXC) pra qualquer VMID. RODA NO HOST PROXMOX (ex: pve1),
# NAO dentro de um container LXC -- copie este arquivo pro host via
# scp/console/copiar-colar antes de executar.
#
# Uso:
#   ./nvidia_lxc_gpu_passthrough.sh <VMID> [opcoes]
#
# Opcoes:
#   --capabilities <lista>     Default: compute,utility (video/graphics/display/
#                               compat32/ngx soh se voce realmente precisar --
#                               transcodificacao de video tipo Plex/Jellyfin, etc).
#   --dry-run                  Mostra tudo que seria feito, sem aplicar nada.
#   --yes                      Pula a confirmacao interativa antes do restart.
#   --skip-docker-install      Nao tenta instalar Docker dentro do container
#                               (assume que ja existe).
#   --test-image <imagem>      Default: nvidia/cuda:12.0.0-base-ubuntu22.04
#
# Historico/motivacao (sessao 2026-07-29, ambiente Jupyter LXC 142 no pve1):
# 4 problemas foram descobertos e corrigidos NA MAO, nessa ordem, pra fazer
# `docker run --gpus all` funcionar de dentro de um LXC Proxmox:
#   1. nvidia-container-toolkit nao instalado dentro do LXC.
#   2. `docker run --gpus all` falhava com erro de BPF cgroup device
#      (`operation not permitted`) -- LXC nao tem permissao de gerenciar
#      cgroup device rules do jeito que o Docker moderno tenta por padrao.
#      Fix: `no-cgroups = true` em nvidia-container-runtime/config.toml.
#   3. Depois disso, faltava a versao EXATA dos arquivos de biblioteca
#      (ex: libcuda.so.590.48.01) -- o LXC so tinha os arquivos SEM sufixo de
#      versao (libcuda.so.1) bind-montados pelo host. O nvidia-container-
#      toolkit exige o nome de arquivo com a versao completa pra descobrir
#      cada biblioteca (nvc_info.c faz esse match exato).
#   4. Mesmo com os arquivos versionados presentes, a deteccao AINDA falhava
#      -- porque o .conf tambem bind-montava o MESMO arquivo fisico como uma
#      copia SEPARADA sob o nome antigo sem versao (libnvidia-ml.so.1). Com
#      dois arquivos fisicos distintos declarando o mesmo SONAME, o ldconfig
#      registrava o caminho ERRADO (sem versao) no cache, e a checagem de
#      versao do toolkit falhava silenciosamente.
#
# Este script evita a causa raiz do problema 4 por construcao: NUNCA monta o
# mesmo arquivo fisico sob dois nomes de destino diferentes. Monta cada
# biblioteca UMA VEZ, com seu proprio nome de arquivo completo/versionado, e
# deixa o `ldconfig` (rodado dentro do container, passo 4) criar os symlinks
# de SONAME (.so.1, .so) apontando pro arquivo real -- exatamente como uma
# instalacao de driver de verdade funciona.
#
# Idempotente/a-prova-de-upgrade-de-driver: a versao do driver NUNCA fica
# hardcoded neste script -- tudo vem de `nvidia-container-cli list` (roda no
# host, reflete o driver instalado AGORA) e de globs em /dev/nvidia*. Rodar
# de novo apos atualizar o driver do host regenera o bloco do zero.
set -euo pipefail

# ── Parsing de argumentos ────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  echo "Uso: $0 <VMID> [--capabilities compute,utility] [--dry-run] [--yes] [--skip-docker-install] [--test-image <imagem>]" >&2
  exit 1
fi

VMID="$1"; shift
CAPABILITIES="compute,utility"
DRY_RUN=0
ASSUME_YES=0
SKIP_DOCKER_INSTALL=0
TEST_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"

while [ $# -gt 0 ]; do
  case "$1" in
    --capabilities) CAPABILITIES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-docker-install) SKIP_DOCKER_INSTALL=1; shift ;;
    --test-image) TEST_IMAGE="$2"; shift 2 ;;
    *) echo "Opcao desconhecida: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[$(date -Iseconds)] $*"; }
die() { echo "[$(date -Iseconds)] ERRO: $*" >&2; exit 1; }

# ── Sanidade do ambiente (precisa rodar no host Proxmox, como root) ─────────
[ "$(id -u)" -eq 0 ] || die "rode como root (precisa editar /etc/pve/lxc/ e usar pct)."
command -v pct >/dev/null 2>&1 || die "'pct' nao encontrado -- este script roda NO HOST PROXMOX, nao dentro de um container LXC."
command -v nvidia-smi >/dev/null 2>&1 || die "'nvidia-smi' nao encontrado no host -- driver NVIDIA nao instalado aqui."
command -v nvidia-container-cli >/dev/null 2>&1 || die "'nvidia-container-cli' nao encontrado no host (pacote libnvidia-container-tools) -- precisa dele pra descobrir a lista de arquivos do driver."

CONF="/etc/pve/lxc/${VMID}.conf"
[ -f "$CONF" ] || die "container ${VMID} nao existe (${CONF} nao encontrado)."

CURRENT_STATUS="$(pct status "$VMID" 2>/dev/null | awk '{print $2}')"
[ "$CURRENT_STATUS" = "running" ] || die "container ${VMID} nao esta rodando (status: ${CURRENT_STATUS:-desconhecido}) -- inicie antes de rodar este script."

DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
log "Driver NVIDIA detectado no host: ${DRIVER_VERSION}"

# Aviso se o VMID alvo for o mesmo container onde este script/sessao esta
# rodando (deteccao best-effort via hostname configurado no .conf) -- reiniciar
# esse container derruba qualquer sessao ativa dentro dele (ex: uma sessao do
# Claude Code, um Jupyter aberto, etc).
TARGET_HOSTNAME="$(awk -F': ' '/^hostname:/{print $2}' "$CONF" | tr -d '\r')"
log "Alvo: container ${VMID} (hostname=${TARGET_HOSTNAME:-?}) -- capabilities=${CAPABILITIES}"

# ── Passo 1: descoberta dinamica no host (nada hardcoded) ───────────────────
log "Descobrindo binarios/bibliotecas do driver instalado agora..."
mapfile -t ALL_FILES < <(nvidia-container-cli list --binaries --libraries)
[ "${#ALL_FILES[@]}" -gt 0 ] || die "'nvidia-container-cli list' nao retornou nenhum arquivo -- driver incompleto no host?"

IFS=',' read -ra CAP_LIST <<< "$CAPABILITIES"
WANT_OPENGL=0
WANT_VIDEO=0
for c in "${CAP_LIST[@]}"; do
  case "$c" in
    graphics|display) WANT_OPENGL=1 ;;
    video) WANT_VIDEO=1 ;;
  esac
done

# Filtra a lista completa: sempre inclui compute/utility core; so inclui
# OpenGL/encode/decode se a capability correspondente foi pedida -- reduz a
# superficie (menos arquivos = menos chance de outro bug de versao/mount).
LIB_ENTRIES=()
BIN_ENTRIES=()
for f in "${ALL_FILES[@]}"; do
  base="$(basename "$f")"
  case "$base" in
    libGLX_nvidia.so*|libEGL_nvidia.so*|libGLESv*_nvidia.so*|libnvidia-glvkspirv.so*|libnvidia-eglcore.so*|libnvidia-glcore.so*|libnvidia-glsi.so*|libnvidia-tls.so*|libnvidia-cbl.so*)
      [ "$WANT_OPENGL" = 1 ] && LIB_ENTRIES+=("$f")
      ;;
    libnvidia-encode.so*|libnvidia-opticalflow.so*|libnvcuvid.so*|libnvidia-fbc.so*|libnvidia-ifr.so*|libnvidia-rtcore.so*|libnvoptix.so*)
      [ "$WANT_VIDEO" = 1 ] && LIB_ENTRIES+=("$f")
      ;;
    *.so*) LIB_ENTRIES+=("$f") ;;
    *) BIN_ENTRIES+=("$f") ;;
  esac
done
log "Selecionados ${#LIB_ENTRIES[@]} arquivos de biblioteca + ${#BIN_ENTRIES[@]} binarios pra capabilities=${CAPABILITIES}."

# Devices: tudo que bater /dev/nvidia* no host agora (cobre multi-GPU, MIG/
# nvidia-caps, etc -- nunca hardcoded).
DEVICE_ENTRIES=()
for d in /dev/nvidia*; do
  [ -e "$d" ] || continue
  DEVICE_ENTRIES+=("$d")
done
[ "${#DEVICE_ENTRIES[@]}" -gt 0 ] || die "nenhum /dev/nvidia* encontrado no host -- GPU passthrough pro host em si nao esta configurado."

# Majors de cgroup: calculado a partir dos devices de fato presentes (nunca
# hardcoded -- o proprio guia manual da comunidade avisa que isso varia por
# sistema/kernel).
declare -A MAJORS_SEEN=()
CGROUP_MAJORS=()
for d in "${DEVICE_ENTRIES[@]}"; do
  [ -c "$d" ] || continue  # ignora diretorios tipo /dev/nvidia-caps aqui
  major_hex="$(stat --format='%t' "$d")"
  major_dec=$((16#$major_hex))
  if [ -z "${MAJORS_SEEN[$major_dec]:-}" ]; then
    MAJORS_SEEN[$major_dec]=1
    CGROUP_MAJORS+=("$major_dec")
  fi
done
log "Majors de device cgroup detectados: ${CGROUP_MAJORS[*]}"

# ── Passo 2: gera o bloco novo de config ────────────────────────────────────
MARK_BEGIN="# === NVIDIA-LXC-GPU-PASSTHROUGH (gerenciado por nvidia_lxc_gpu_passthrough.sh -- nao editar a mao) BEGIN ==="
MARK_END="# === NVIDIA-LXC-GPU-PASSTHROUGH (gerenciado por nvidia_lxc_gpu_passthrough.sh -- nao editar a mao) END ==="

NEW_BLOCK_FILE="$(mktemp)"
trap 'rm -f "$NEW_BLOCK_FILE"' EXIT

{
  echo "$MARK_BEGIN"
  echo "# Gerado em $(date -Iseconds), driver ${DRIVER_VERSION}, capabilities=${CAPABILITIES}."
  echo "# Cada arquivo e montado com seu proprio nome completo/versionado -- NUNCA"
  echo "# renomeado/duplicado sob outro nome (isso e o que causava o bug de ldconfig"
  echo "# corrigido manualmente em 2026-07-29 -- ver comentario no topo do script)."
  for major in "${CGROUP_MAJORS[@]}"; do
    echo "lxc.cgroup2.devices.allow: c ${major}:* rwm"
  done
  for d in "${DEVICE_ENTRIES[@]}"; do
    rel="${d#/}"
    if [ -d "$d" ]; then
      echo "lxc.mount.entry: ${d} ${rel} none bind,optional,create=dir"
    else
      echo "lxc.mount.entry: ${d} ${rel} none bind,optional,create=file"
    fi
  done
  for f in "${BIN_ENTRIES[@]}" "${LIB_ENTRIES[@]}"; do
    rel="${f#/}"
    echo "lxc.mount.entry: ${f} ${rel} none bind,ro,optional,create=file"
  done
  echo "$MARK_END"
} > "$NEW_BLOCK_FILE"

# ── Passo 2b: limpeza idempotente do .conf ──────────────────────────────────
BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONF" "$BACKUP"
log "Backup salvo em ${BACKUP}"

CLEANED_FILE="$(mktemp)"
trap 'rm -f "$NEW_BLOCK_FILE" "$CLEANED_FILE"' EXIT

# Monta o padrao de majors detectados pra tambem remover cgroup2.devices.allow
# antigos que batam com eles (linhas soltas de uma config manual anterior).
MAJOR_PATTERN=""
for major in "${CGROUP_MAJORS[@]}"; do
  MAJOR_PATTERN="${MAJOR_PATTERN}${MAJOR_PATTERN:+|}${major}"
done

python3 - "$CONF" "$CLEANED_FILE" "$MAJOR_PATTERN" <<'PYEOF'
import re
import sys

src, dst, major_pattern = sys.argv[1], sys.argv[2], sys.argv[3]

managed_begin = "# === NVIDIA-LXC-GPU-PASSTHROUGH"
legacy_mount_re = re.compile(
    r"^lxc\.mount\.entry:\s+(/dev/nvidia|/usr/bin/nvidia-|/usr/sbin/nvidia-"
    r"|/usr/lib/x86_64-linux-gnu/(libnvidia-|libcuda))"
)
major_re = re.compile(r"^lxc\.cgroup2\.devices\.allow:\s+c\s+(\d+):") if major_pattern else None
wanted_majors = set(major_pattern.split("|")) if major_pattern else set()

with open(src) as fh:
    lines = fh.readlines()

out = []
skipping_managed_block = False
for line in lines:
    stripped = line.rstrip("\n")
    if stripped.startswith(managed_begin):
        skipping_managed_block = True
        continue
    if skipping_managed_block:
        if stripped.startswith("# === NVIDIA-LXC-GPU-PASSTHROUGH") and "END" in stripped:
            skipping_managed_block = False
        continue
    if legacy_mount_re.match(stripped):
        continue
    if major_re:
        m = major_re.match(stripped)
        if m and m.group(1) in wanted_majors:
            continue
    out.append(line)

with open(dst, "w") as fh:
    fh.writelines(out)
PYEOF

cat "$NEW_BLOCK_FILE" >> "$CLEANED_FILE"

log "Diff proposto pro ${CONF}:"
diff -u "$CONF" "$CLEANED_FILE" || true

if [ "$DRY_RUN" = 1 ]; then
  log "--dry-run: nada foi aplicado. Backup em ${BACKUP} pode ser removido (nao foi usado)."
  rm -f "$BACKUP"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Aplicar essa mudanca e reiniciar o container ${VMID} agora? [s/N] " ans
  case "$ans" in
    s|S|y|Y) ;;
    *) log "Cancelado pelo usuario. Nada foi alterado."; rm -f "$BACKUP"; exit 0 ;;
  esac
fi

mv "$CLEANED_FILE" "$CONF"
log "${CONF} atualizado."

# ── Passo 3: restart + espera ────────────────────────────────────────────────
log "Reiniciando container ${VMID}..."
pct restart "$VMID"

ok=0
for _ in $(seq 1 30); do
  st="$(pct status "$VMID" 2>/dev/null | awk '{print $2}')"
  if [ "$st" = "running" ]; then ok=1; break; fi
  sleep 2
done

if [ "$ok" != 1 ]; then
  log "Container nao voltou a rodar a tempo -- restaurando backup e tentando de novo."
  cp "$BACKUP" "$CONF"
  pct restart "$VMID" || true
  die "container ${VMID} nao voltou depois da mudanca. Config original restaurada de ${BACKUP}. Investigue manualmente antes de tentar de novo."
fi
log "Container ${VMID} rodando."

# Da um tempo extra pro Docker/systemd de dentro subir antes do pct exec.
sleep 5

# ── Passo 4: setup dentro do container ──────────────────────────────────────
pexec() { pct exec "$VMID" -- bash -c "$1"; }

log "Capturando containers Docker rodando ANTES do setup (pra comparar depois)..."
BEFORE_CONTAINERS="$(pexec 'docker ps --format "{{.Names}}"' 2>/dev/null || true)"

if [ "$SKIP_DOCKER_INSTALL" != 1 ] && ! pexec 'command -v docker >/dev/null 2>&1'; then
  log "Docker nao encontrado dentro do container -- instalando via get.docker.com (script oficial, baixado e executado dentro do container)."
  pexec 'curl -fsSL https://get.docker.com | sh'
  pexec 'systemctl enable --now docker'
fi

if ! pexec 'command -v nvidia-ctk >/dev/null 2>&1'; then
  log "nvidia-container-toolkit nao encontrado dentro do container -- instalando..."
  pexec '
    set -e
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
  '
fi

log "Configurando runtime Docker + nvidia-container-runtime..."
pexec 'nvidia-ctk runtime configure --runtime=docker'
# no-cgroups=true: obrigatorio dentro de LXC (sem isso, "bpf_prog_query
# (BPF_CGROUP_DEVICE) failed: operation not permitted"). Forma oficial via
# `nvidia-ctk config --set`, testada e confirmada nesta sessao.
pexec 'nvidia-ctk config --set nvidia-container-cli.no-cgroups=true --in-place'

# supported-driver-capabilities: NAO usar `nvidia-ctk config --set` aqui --
# achado real desta sessao: pra essa chave especifica (string simples, nao
# lista de verdade no schema interno do nvidia-ctk), o separador `:` do
# `--set` e gravado LITERAL na string ("compute:utility", com dois-pontos),
# o que o parser real de `libnvidia-container` NAO entende (ele espera
# virgula). Edicao direta da linha e a forma correta/testada.
log "Ajustando supported-driver-capabilities=${CAPABILITIES}..."
pexec "python3 -c \"
import re
path = '/etc/nvidia-container-runtime/config.toml'
with open(path) as fh:
    content = fh.read()
new_line = 'supported-driver-capabilities = \\\"${CAPABILITIES}\\\"'
if re.search(r'^#?supported-driver-capabilities\s*=.*\$', content, re.M):
    content = re.sub(r'^#?supported-driver-capabilities\s*=.*\$', new_line, content, flags=re.M)
else:
    content = new_line + '\n' + content
with open(path, 'w') as fh:
    fh.write(content)
\""

log "Rodando ldconfig (registra os arquivos versionados recem-montados sem ambiguidade)..."
pexec 'ldconfig'

log "Reiniciando Docker dentro do container..."
pexec 'systemctl restart docker'
sleep 3

# ── Passo 5: teste de verdade ────────────────────────────────────────────────
log "Testando GPU passthrough aninhado com ${TEST_IMAGE}..."
GPU_TEST_OUTPUT="$(pexec "docker run --rm --gpus all '${TEST_IMAGE}' nvidia-smi" 2>&1 || true)"
echo "$GPU_TEST_OUTPUT"

GPU_OK=0
if echo "$GPU_TEST_OUTPUT" | grep -q "NVIDIA-SMI" && ! echo "$GPU_TEST_OUTPUT" | grep -qiE "couldn't find|error response from daemon"; then
  GPU_OK=1
fi

DOCKER_ACTIVE=0
pexec 'systemctl is-active --quiet docker' 2>/dev/null && DOCKER_ACTIVE=1

AFTER_CONTAINERS="$(pexec 'docker ps --format "{{.Names}}"' 2>/dev/null || true)"
MISSING_CONTAINERS="$(comm -23 <(echo "$BEFORE_CONTAINERS" | sort) <(echo "$AFTER_CONTAINERS" | sort) 2>/dev/null || true)"

# ── Relatorio final ──────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo "RELATORIO FINAL -- container ${VMID}"
echo "======================================================================"
echo "[$([ "$ok" = 1 ] && echo PASS || echo FAIL)] Container voltou a rodar apos o restart"
echo "[$([ "$DOCKER_ACTIVE" = 1 ] && echo PASS || echo FAIL)] Docker daemon ativo dentro do container"
echo "[$([ "$GPU_OK" = 1 ] && echo PASS || echo FAIL)] GPU passthrough aninhado (docker run --gpus all) funcionando"
if [ -z "$MISSING_CONTAINERS" ]; then
  echo "[PASS] Todos os containers que estavam rodando antes voltaram"
else
  echo "[FAIL] Containers que NAO voltaram: $(echo "$MISSING_CONTAINERS" | tr '\n' ' ')"
fi
echo "Backup do .conf original: ${BACKUP}"
echo "======================================================================"

if [ "$GPU_OK" != 1 ] || [ "$DOCKER_ACTIVE" != 1 ] || [ -n "$MISSING_CONTAINERS" ]; then
  exit 1
fi
