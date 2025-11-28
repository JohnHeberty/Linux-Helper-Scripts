#!/bin/bash

################################################################################
# NVIDIA Docker Setup Script - YTCaption
# 
# Instala e configura NVIDIA Container Toolkit para usar GPU no Docker
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  NVIDIA Docker Setup${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_step() {
    echo ""
    echo -e "${BLUE}[$1]${NC}"
    echo "----------------------------------------"
}

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    print_error "Este script precisa ser executado como root (sudo)"
    exit 1
fi

print_header

# 1. Verificar pré-requisitos
print_step "1. Verificando Pré-requisitos"

# Verificar nvidia-smi
if ! command -v nvidia-smi &> /dev/null; then
    print_error "nvidia-smi não encontrado"
    print_info "Instale o driver NVIDIA primeiro: sudo apt install nvidia-driver-535"
    exit 1
fi

# Testar nvidia-smi
if ! nvidia-smi &> /dev/null; then
    print_error "nvidia-smi não está funcionando"
    print_info "Execute: sudo modprobe nvidia"
    exit 1
fi

print_success "NVIDIA driver funcionando"

# Verificar Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker não está instalado"
    print_info "Instale Docker primeiro: https://docs.docker.com/engine/install/"
    exit 1
fi

print_success "Docker instalado: $(docker --version)"

# 2. Detectar distribuição
print_step "2. Detectando Distribuição"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID$VERSION_ID"
    print_success "Distribuição: $DISTRO"
else
    print_error "Não foi possível detectar a distribuição"
    exit 1
fi

# 3. Adicionar repositório NVIDIA Container Toolkit
print_step "3. Adicionando Repositório"

print_info "Baixando GPG key..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

if [ $? -eq 0 ]; then
    print_success "GPG key adicionada"
else
    print_error "Falha ao baixar GPG key"
    exit 1
fi

print_info "Adicionando repositório genérico (stable/deb)..."
cat > /etc/apt/sources.list.d/nvidia-container-toolkit.list <<EOF
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /
EOF

if [ $? -eq 0 ]; then
    print_success "Repositório adicionado"
else
    print_error "Falha ao adicionar repositório"
    exit 1
fi

# 4. Atualizar pacotes
print_step "4. Atualizando Lista de Pacotes"

apt update
if [ $? -eq 0 ]; then
    print_success "Pacotes atualizados"
else
    print_error "Falha ao atualizar pacotes"
    exit 1
fi

# 5. Instalar nvidia-container-toolkit
print_step "5. Instalando NVIDIA Container Toolkit"

apt install -y nvidia-container-toolkit
if [ $? -eq 0 ]; then
    print_success "NVIDIA Container Toolkit instalado"
else
    print_error "Falha ao instalar"
    exit 1
fi

# 6. Configurar Docker
print_step "6. Configurando Docker Runtime"

nvidia-ctk runtime configure --runtime=docker
if [ $? -eq 0 ]; then
    print_success "Docker runtime configurado"
else
    print_error "Falha ao configurar Docker"
    exit 1
fi

# 7. Reiniciar Docker
print_step "7. Reiniciando Docker"

systemctl restart docker
if [ $? -eq 0 ]; then
    print_success "Docker reiniciado"
else
    print_error "Falha ao reiniciar Docker"
    exit 1
fi

sleep 2

# 8. Testar acesso GPU
print_step "8. Testando Acesso à GPU"

print_info "Executando container de teste..."
echo ""

if docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
    print_success "TESTE PASSOU! Docker consegue acessar a GPU!"
    echo ""
    print_info "Executando nvidia-smi no container:"
    echo ""
    docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
else
    print_error "TESTE FALHOU! Docker não consegue acessar a GPU"
    echo ""
    print_info "Tente:"
    echo "  1. Reiniciar o Docker: sudo systemctl restart docker"
    echo "  2. Verificar logs: sudo journalctl -u docker -n 50"
    echo "  3. Verificar config: cat /etc/docker/daemon.json"
    exit 1
fi

# 9. Verificar daemon.json
print_step "9. Verificando Configuração Docker"

if [ -f /etc/docker/daemon.json ]; then
    print_success "Configuração Docker:"
    cat /etc/docker/daemon.json
else
    print_warning "Arquivo daemon.json não encontrado"
fi

# 10. Sucesso!
print_step "Instalação Concluída"

print_success "🎉 NVIDIA Docker configurado com sucesso!"
echo ""
echo "Próximos passos:"
echo "  1. Execute: ./start.sh --model base --memory 2048 --no-parallel"
echo "  2. Verifique os logs: docker-compose logs -f"
echo "  3. A GPU será usada automaticamente para transcrição"
echo ""
print_info "Para verificar GPU em uso:"
echo "  watch -n 1 nvidia-smi  # Atualiza a cada 1 segundo"
echo ""
