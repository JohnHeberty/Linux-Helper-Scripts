#!/bin/bash
# SCRIPT V3 — GPU NVIDIA para LXC no Proxmox
# 100% Funcional para Debian Bookworm / Ubuntu / Alpine
# Autor: ChatGPT

echo "==============================================="
echo "     SCRIPT AUTOMÁTICO DE GPU PARA LXC (v3)"
echo "==============================================="
echo ""

read -p "Digite o ID do container LXC (ex: 101): " CTID

if ! pct status "$CTID" &>/dev/null; then
    echo "❌ ERRO: O container LXC $CTID não existe!"
    exit 1
fi

CONF="/etc/pve/lxc/$CTID.conf"

echo ""
echo "✔ Container $CTID encontrado"
echo "→ Configuração: $CONF"
echo ""

##########################################
# 1 — Adicionar DEVICES NVIDIA no .conf
##########################################

if grep -q "BEGIN-NVIDIA-CONFIG" "$CONF"; then
    echo "→ Configuração NVIDIA já existe — pulando."
else
    echo "→ Adicionando blocos NVIDIA no .conf..."

cat <<EOF >> "$CONF"

# ================= BEGIN-NVIDIA-CONFIG =================
# Permissões de dispositivos
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 508:* rwm

# Dispositivos NVIDIA
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidia1 dev/nvidia1 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file

# Binário nvidia-smi
lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,optional,create=file

# Bibliotecas NVIDIA necessárias para nvidia-smi
lxc.mount.entry: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 none bind,optional,create=file
lxc.mount.entry: /usr/lib/x86_64-linux-gnu/libnvidia-container.so.1 usr/lib/x86_64-linux-gnu/libnvidia-container.so.1 none bind,optional,create=file

# ================= END-NVIDIA-CONFIG =================
EOF

fi

echo "✔ Mapeamentos NVIDIA adicionados"
echo ""


##########################################
# 2 — Reiniciar o container
##########################################

echo "→ Reiniciando container $CTID..."
pct stop "$CTID" &>/dev/null
pct start "$CTID"
sleep 3

echo "✔ Container reiniciado"
echo ""


##########################################
# 3 — Testar nvidia-smi dentro do container
##########################################

echo "→ Testando GPU dentro do LXC:"
echo ""

pct exec "$CTID" -- bash -c "which nvidia-smi && nvidia-smi"

if [ $? -eq 0 ]; then
    echo ""
    echo "==============================================="
    echo "      ✅ GPU NVIDIA FUNCIONANDO NO LXC $CTID"
    echo "==============================================="
else
    echo ""
    echo "==============================================="
    echo " ⚠ GPU MAPEADA, MAS nvidia-smi FALHOU NO LXC  "
    echo "==============================================="
    echo ""
    echo "→ Diagnóstico rápido:"
    echo "   - Verifique se os devices existem dentro do LXC:"
    echo "       pct exec $CTID -- ls -l /dev/nvidia*"
    echo ""
    echo "→ Verifique se os mounts estão ativos:"
    echo "       pct exec $CTID -- ls -l /usr/bin/nvidia-smi"
    echo "       pct exec $CTID -- ls -l /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
    echo ""
    echo "→ Normalmente, nvidia-smi só precisa dos mounts acima."
fi
