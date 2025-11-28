#!/bin/bash
###############################################################################
# Script de Cleanup Sistemático - Audio Voice Service
# 
# Garante que não existam containers órfãos, imagens antigas ou volumes não utilizados
# do serviço audio-voice antes de rebuild.
#
# Uso: bash scripts/docker-cleanup-audio-voice.sh
###############################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_DIR="$PROJECT_ROOT/services/audio-voice"

echo "🧹 =========================================="
echo "🧹 Audio Voice Service - Cleanup Sistemático"
echo "🧹 =========================================="
echo ""

# Validação: Verificar se há containers desconhecidos rodando
echo "🔍 [1/6] Validando containers em execução..."
UNKNOWN_CONTAINERS=$(docker ps --filter "name=audio-voice" --format '{{.Names}}' | grep -v -E "^(audio-voice-api|audio-voice-celery)$" || true)

if [ -n "$UNKNOWN_CONTAINERS" ]; then
    echo "⚠️  AVISO: Containers desconhecidos detectados:"
    echo "$UNKNOWN_CONTAINERS"
    echo ""
    read -p "Deseja continuar mesmo assim? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Cleanup cancelado pelo usuário"
        exit 1
    fi
fi

echo "✅ Validação de containers passou"
echo ""

# Parar serviços
echo "🛑 [2/6] Parando serviços audio-voice..."
cd "$SERVICE_DIR"

if [ -f "docker-compose.yml" ]; then
    docker compose down --volumes --remove-orphans 2>/dev/null || true
    echo "✅ Serviços parados (docker compose)"
else
    echo "⚠️  docker-compose.yml não encontrado, pulando..."
fi
echo ""

# Remover containers parados do audio-voice
echo "🗑️  [3/6] Removendo containers parados do audio-voice..."
STOPPED_CONTAINERS=$(docker ps -a --filter "name=audio-voice" --format '{{.Names}}' || true)

if [ -n "$STOPPED_CONTAINERS" ]; then
    echo "$STOPPED_CONTAINERS" | xargs -r docker rm -f 2>/dev/null || true
    echo "✅ Containers removidos"
else
    echo "ℹ️  Nenhum container parado encontrado"
fi
echo ""

# Remover imagens antigas do audio-voice
echo "🖼️  [4/6] Removendo imagens antigas do audio-voice..."
OLD_IMAGES=$(docker images --filter "reference=*audio-voice*" --format '{{.ID}}' || true)

if [ -n "$OLD_IMAGES" ]; then
    echo "$OLD_IMAGES" | xargs -r docker rmi -f 2>/dev/null || true
    echo "✅ Imagens antigas removidas"
else
    echo "ℹ️  Nenhuma imagem antiga encontrada"
fi
echo ""

# Prune seletivo (apenas recursos do audio-voice)
echo "🧽 [5/6] Limpando recursos órfãos do audio-voice..."
docker system prune -f --filter "label=com.example.service=audio-voice" 2>/dev/null || true
echo "✅ Prune seletivo concluído"
echo ""

# Verificação final
echo "🔍 [6/6] Verificação final..."
REMAINING_CONTAINERS=$(docker ps -a --filter "name=audio-voice" --format '{{.Names}}' || true)
REMAINING_IMAGES=$(docker images --filter "reference=*audio-voice*" --format '{{.Repository}}:{{.Tag}}' || true)

if [ -z "$REMAINING_CONTAINERS" ]; then
    echo "✅ Nenhum container audio-voice restante"
else
    echo "⚠️  Containers restantes (pode ser normal se outros serviços):"
    echo "$REMAINING_CONTAINERS"
fi

if [ -z "$REMAINING_IMAGES" ]; then
    echo "✅ Nenhuma imagem audio-voice restante"
else
    echo "⚠️  Imagens restantes:"
    echo "$REMAINING_IMAGES"
fi
echo ""

echo "🎉 =========================================="
echo "🎉 Cleanup concluído com sucesso!"
echo "🎉 =========================================="
echo ""
echo "Próximo passo: bash scripts/rebuild-audio-voice.sh"
