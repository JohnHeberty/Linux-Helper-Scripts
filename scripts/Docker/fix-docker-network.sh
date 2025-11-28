#!/bin/bash
# Script para diagnosticar e corrigir problemas de rede no Docker

echo "================================================================================"
echo "DIAGNÓSTICO DE REDE DO DOCKER"
echo "================================================================================"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Verificar DNS do host
echo -e "\n${YELLOW}1. DNS do Host:${NC}"
cat /etc/resolv.conf 2>/dev/null || echo "Arquivo não encontrado (Windows?)"

# 2. Verificar configuração do Docker
echo -e "\n${YELLOW}2. Docker daemon.json:${NC}"
if [ -f /etc/docker/daemon.json ]; then
    cat /etc/docker/daemon.json
else
    echo "Arquivo não encontrado"
fi

# 3. Testar DNS no container
echo -e "\n${YELLOW}3. Testando DNS no container:${NC}"
docker exec whisper-transcription-api cat /etc/resolv.conf 2>/dev/null

# 4. Testar conectividade
echo -e "\n${YELLOW}4. Testando conectividade:${NC}"
echo "Ping 8.8.8.8:"
docker exec whisper-transcription-api ping -c 2 8.8.8.8 2>/dev/null || echo -e "${RED}FALHOU${NC}"

echo "Ping 1.1.1.1:"
docker exec whisper-transcription-api ping -c 2 1.1.1.1 2>/dev/null || echo -e "${RED}FALHOU${NC}"

echo "DNS lookup youtube.com:"
docker exec whisper-transcription-api nslookup youtube.com 2>/dev/null || echo -e "${RED}FALHOU${NC}"

# 5. Verificar rotas
echo -e "\n${YELLOW}5. Rotas do container:${NC}"
docker exec whisper-transcription-api ip route 2>/dev/null || echo "Comando não disponível"

# 6. Sugestões de correção
echo -e "\n================================================================================"
echo -e "${GREEN}SUGESTÕES DE CORREÇÃO:${NC}"
echo "================================================================================"
echo ""
echo "OPÇÃO 1: Usar DNS público no Docker daemon"
echo "  Crie/edite /etc/docker/daemon.json:"
echo '  {
    "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"]
  }'
echo "  Depois: sudo systemctl restart docker"
echo ""
echo "OPÇÃO 2: Configurar DNS no docker-compose.yml"
echo "  Adicione na seção do serviço:"
echo "  dns:
    - 8.8.8.8
    - 8.8.4.4
    - 1.1.1.1"
echo ""
echo "OPÇÃO 3: Usar rede host (menos seguro)"
echo "  network_mode: host"
echo ""
echo "OPÇÃO 4: Verificar firewall/iptables"
echo "  sudo iptables -L -n | grep -i docker"
echo "  sudo iptables -t nat -L -n | grep -i docker"
echo ""
echo "================================================================================"
