#!/bin/bash

# Verifica se o ID do CT foi passado no comando
if [ -z "$1" ]; then
    echo "Uso: $0 <ID_DO_CT>"
    echo "Exemplo: $0 100"
    exit 1
fi

CTID=$1

# Verifica se o CT existe e está rodando
if ! pct status $CTID > /dev/null 2>&1; then
    echo "Erro: CT $CTID não encontrado no Proxmox."
    exit 1
fi

STATUS=$(pct status $CTID | awk '{print $2}')
if [ "$STATUS" != "running" ]; then
    echo "Erro: O CT $CTID está desligado. Inicie-o primeiro."
    exit 1
fi

echo "=================================================="
echo " Iniciando diagnóstico e faxina no CT $CTID"
echo "=================================================="

echo -e "\n[1/4] Testando velocidade de gravação do disco..."
# Executa o dd na raiz (/) do contêiner
pct exec $CTID -- bash -c "dd if=/dev/zero of=/teste_disco.img bs=1M count=1024 oflag=direct 2>&1"

echo -e "\n[2/4] Removendo o arquivo de teste..."
pct exec $CTID -- rm -f /teste_disco.img
echo "Arquivo /teste_disco.img apagado com sucesso."

echo -e "\n[3/4] Limpando logs de sistema e pacotes residuais..."
pct exec $CTID -- journalctl --vacuum-size=50M
pct exec $CTID -- bash -c "rm -f /var/log/*.gz /var/log/*.[0-9]*"
# Usamos apt-get em scripts para evitar alertas visuais do apt no terminal
pct exec $CTID -- bash -c "apt-get clean && apt-get autoremove -y"
echo "Limpeza concluída."

echo -e "\n[4/4] Relatório de armazenamento (Diretórios mais pesados na raiz):"
echo "--------------------------------------------------"
pct exec $CTID -- bash -c "du -hxd 1 / | sort -hr"

echo -e "\n=================================================="
echo " Processo finalizado com sucesso para o CT $CTID!"
echo "=================================================="
