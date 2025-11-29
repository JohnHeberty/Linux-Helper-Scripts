#!/bin/bash
# =============================================================================
# SCRIPT V4 — GPU NVIDIA → LXC AUTO-CONFIGURATOR
# Compatível: Debian, Ubuntu, Alpine, Arch, Fedora (LXC)
# Autor: ChatGPT — versão inteligente e resiliente
# =============================================================================

echo "====================================================="
echo "      SCRIPT AUTOMÁTICO DE GPU PARA LXC (V4)"
echo "====================================================="
echo ""

# ==================== INPUT DO CTID ====================
read -p "Digite o ID do container LXC (ex: 101): " CTID

# Container existe?
if ! pct status "$CTID" &>/dev/null; then
    echo "❌ ERRO: O container LXC '$CTID' não existe!"
    exit 1
fi

CONF="/etc/pve/lxc/$CTID.conf"
echo "✔ Container $CTID encontrado."
echo "→ Usando configuração: $CONF"
echo ""

# ===================== VALIDAR HOST =====================
echo "→ Validando ambiente NVIDIA no host..."
HOST_SMI=$(readlink -f /usr/bin/nvidia-smi 2>/dev/null)

if [[ ! -f "$HOST_SMI" ]]; then
    echo "❌ ERRO: nvidia-smi NÃO encontrado no host!"
    echo "→ Caminho esperado: /usr/bin/nvidia-smi → symlink → caminho real"
    exit 1
fi

echo "✔ nvidia-smi real: $HOST_SMI"

# Checar se GPU está funcional no host
echo "→ Testando nvidia-smi no host..."
if ! nvidia-smi &>/dev/null; then
    echo "❌ ERRO: NVIDIA-SMI FALHOU NO HOST!"
    echo "→ GPU não inicializada, driver quebrado ou kernel errado."
    exit 1
fi

echo "✔ Host GPU OK"
echo ""

# ===================== LOCALIZAR LIBS =====================
echo "→ Localizando bibliotecas NVIDIA essenciais..."

LIB_ML=$(readlink -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1)
LIB_CONTAINER=$(readlink -f /usr/lib/x86_64-linux-gnu/libnvidia-container.so.1)

ERROR=0

if [[ ! -f "$LIB_ML" ]]; then
    echo "❌ ERRO: libnvidia-ml.so.1 NÃO encontrada!"
    ERROR=1
else
    echo "✔ libnvidia-ml.so.1 real: $LIB_ML"
fi

if [[ ! -f "$LIB_CONTAINER" ]]; then
    echo "❌ ERRO: libnvidia-container.so.1 NÃO encontrada!"
    ERROR=1
else
    echo "✔ libnvidia-container.so.1 real: $LIB_CONTAINER"
fi

if [[ $ERROR -eq 1 ]]; then
    echo "❌ ABORTANDO: Arquivos essenciais não encontrados."
    exit 1
fi

echo ""

# ==================== ADICIONAR CONFIG ====================
if grep -q "BEGIN-NVIDIA-CONFIG-V4" "$CONF"; then
    echo "→ Config NVIDIA já existe no .conf — pulando."
else
echo "→ Aplicando configuração NVIDIA no container..."

cat <<EOF >> "$CONF"

# ================= BEGIN-NVIDIA-CONFIG-V4 =================
# Permissões para NVidia
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 508:* rwm

# Devices
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidia1 dev/nvidia1 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file

# Binário real do nvidia-smi
lxc.mount.entry: $HOST_SMI usr/bin/nvidia-smi none bind,optional,create=file

# Bibliotecas essenciais
lxc.mount.entry: $LIB_ML usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 none bind,optional,create=file
lxc.mount.entry: $LIB_CONTAINER usr/lib/x86_64-linux-gnu/libnvidia-container.so.1 none bind,optional,create=file

# ================= END-NVIDIA-CONFIG-V4 =================
EOF

echo "✔ Configuração NVIDIA aplicada."
fi

echo ""

# ===================== REINICIAR CT =====================
echo "→ Reiniciando container $CTID..."
pct stop "$CTID" &>/dev/null
pct start "$CTID"
sleep 3
echo "✔ Container reiniciado."
echo ""

# ===================== TESTE DENTRO DO CT =====================
echo "→ Testando GPU dentro do container..."

pct exec "$CTID" -- nvidia-smi

if [[ $? -eq 0 ]]; then
    echo ""
    echo "====================================================="
    echo "    🎉 SUCESSO TOTAL! GPU NVIDIA ATIVA NO LXC $CTID"
    echo "====================================================="
else
    echo ""
    echo "====================================================="
    echo "⚠ GPU MAPEADA, MAS nvidia-smi FALHOU NO LXC $CTID"
    echo "====================================================="
    echo ""
    echo "→ Diagnóstico rápido:"
    echo "   - Confirme se devices existem:"
    echo "       pct exec $CTID -- ls -l /dev/nvidia*"
    echo ""
    echo "   - Confirme se mounts das libs estão presentes:"
    echo "       pct exec $CTID -- ls -l /usr/bin/nvidia-smi"
    echo "       pct exec $CTID -- ls -l /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
    echo ""
    echo "→ Possíveis causas:"
    echo "   - Rootfs diferente (Alpine precisa /usr/lib)."
    echo "   - Sistema LXC sem bash (usa sh)."
    echo "   - Permissões cgroups do LXC bloqueadas."
fi

echo ""
exit 0
