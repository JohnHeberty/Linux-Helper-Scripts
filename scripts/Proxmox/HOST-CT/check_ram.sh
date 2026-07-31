#!/bin/bash

# Cores
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}--- Relatório de RAM Alocada (Apenas Instâncias LIGADAS) ---${NC}"
printf "%-10s | %-10s | %-20s | %-12s\n" "ID" "Tipo" "Nome" "RAM Alocada"
echo "----------------------------------------------------------------------"

total_ram_mb=0

# --- Processando VMs (QEMU) ---
# O comando 'qm list' retorna: VMID NAME STATUS MEM(bytes) ...
while read -r vmid name status mem rest; do
    if [ "$status" == "running" ]; then
        # Converte bytes para MB (o qm list mostra em bytes/MB dependendo da versão, 
        # mas vamos extrair direto da config para garantir precisão do 'pico')
        conf_mem=$(grep "^memory:" "/etc/pve/qemu-server/${vmid}.conf" | awk '{print $2}')
        
        printf "%-10s | %-10s | %-20s | %-10s MB\n" "$vmid" "VM" "$name" "$conf_mem"
        total_ram_mb=$((total_ram_mb + conf_mem))
    fi
done < <(qm list | awk 'NR>1')

# --- Processando Containers (LXC) ---
# O comando 'pct list' retorna: VMID STATUS NAME ...
while read -r vmid status name rest; do
    if [ "$status" == "status: running" ] || [ "$status" == "running" ]; then
        conf_mem=$(grep "^memory:" "/etc/pve/lxc/${vmid}.conf" | awk '{print $2}')
        
        printf "%-10s | %-10s | %-20s | %-10s MB\n" "$vmid" "CT" "$name" "$conf_mem"
        total_ram_mb=$((total_ram_mb + conf_mem))
    fi
done < <(pct list | awk 'NR>1')

# --- Cálculos de exibição ---
total_gb=$(echo "scale=2; $total_ram_mb / 1024" | bc)
host_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
host_ram_gb=$(echo "scale=2; $host_ram_kb / 1024 / 1024" | bc)

echo "----------------------------------------------------------------------"
echo -e "${GREEN}Total de RAM Alocada nas máquinas ligadas: ${total_ram_mb} MB (~${total_gb} GB)${NC}"
echo -e "Capacidade total do Host: ${host_ram_gb} GB"

# Cálculo de porcentagem de uso do total do host
percent=$(echo "scale=2; ($total_ram_mb * 100) / ($host_ram_kb / 1024)" | bc)
echo -e "Comprometimento atual: ${YELLOW}${percent}%${NC}"
