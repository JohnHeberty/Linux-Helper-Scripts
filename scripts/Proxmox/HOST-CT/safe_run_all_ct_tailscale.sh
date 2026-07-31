#!/usr/bin/env bash

set -uo pipefail

LOG="/var/log/recuperar-tailscale-cts.log"
TIMEOUT_TAILSCALE=30

# Salva a saída na tela e no arquivo de log.
exec > >(tee -a "$LOG") 2>&1

if [[ $EUID -ne 0 ]]; then
    echo "Este script precisa ser executado como root no PVE."
    exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
    echo "Comando pct não encontrado. Execute este script no host Proxmox."
    exit 1
fi

# Quando IDs forem informados, processa somente esses CTs.
# Sem argumentos, processa todos os CTs em execução neste nó.
if [[ $# -gt 0 ]]; then
    CTS=("$@")
else
    mapfile -t CTS < <(
        pct list |
        awk 'NR > 1 && $2 == "running" {print $1}'
    )
fi

if [[ ${#CTS[@]} -eq 0 ]]; then
    echo "Nenhum container em execução encontrado."
    exit 0
fi

echo
echo "=================================================="
echo "Início: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Containers: ${CTS[*]}"
echo "=================================================="

SUCESSOS=0
FALHAS=0
IGNORADOS=0

for CTID in "${CTS[@]}"; do
    echo
    echo "--------------------------------------------------"
    echo "Verificando CT $CTID"

    if ! pct config "$CTID" >/dev/null 2>&1; then
        echo "[IGNORADO] CT $CTID não existe neste nó."
        ((IGNORADOS++))
        continue
    fi

    STATUS="$(pct status "$CTID" 2>/dev/null | awk '{print $2}')"

    if [[ "$STATUS" != "running" ]]; then
        echo "[IGNORADO] CT $CTID está $STATUS."
        ((IGNORADOS++))
        continue
    fi

    HOSTNAME="$(
        pct config "$CTID" |
        awk -F': ' '$1 == "hostname" {print $2}'
    )"

    echo "Container: ${HOSTNAME:-sem-hostname}"
    echo "Status: $STATUS"

    # Confere se o container utiliza systemd e possui Tailscale.
    if ! pct exec "$CTID" -- sh -c \
        'command -v systemctl >/dev/null 2>&1 &&
         command -v tailscale >/dev/null 2>&1'; then
        echo "[IGNORADO] systemctl ou tailscale não encontrado."
        ((IGNORADOS++))
        continue
    fi

    echo "Iniciando tailscaled..."

    if ! pct exec "$CTID" -- systemctl start tailscaled; then
        echo "[ERRO] Não foi possível iniciar tailscaled no CT $CTID."
        ((FALHAS++))
        continue
    fi

    if ! pct exec "$CTID" -- systemctl is-active --quiet tailscaled; then
        echo "[ERRO] tailscaled não ficou ativo no CT $CTID."
        pct exec "$CTID" -- systemctl status tailscaled --no-pager || true
        ((FALHAS++))
        continue
    fi

    echo "tailscaled está ativo."
    echo "Executando tailscale up..."

    if ! pct exec "$CTID" -- timeout "$TIMEOUT_TAILSCALE" tailscale up; then
        echo "[ERRO] tailscale up falhou ou excedeu ${TIMEOUT_TAILSCALE}s."
        ((FALHAS++))
        continue
    fi

    TAILSCALE_IP="$(
        pct exec "$CTID" -- sh -c \
            'tailscale ip -4 2>/dev/null | head -n 1' 2>/dev/null ||
        true
    )"

    if [[ -n "$TAILSCALE_IP" ]]; then
        echo "[OK] CT $CTID conectado. IP Tailscale: $TAILSCALE_IP"
        ((SUCESSOS++))
    else
        echo "[AVISO] Comandos executados, mas nenhum IP Tailscale foi retornado."
        ((FALHAS++))
    fi
done

echo
echo "=================================================="
echo "Fim: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Sucessos:  $SUCESSOS"
echo "Falhas:    $FALHAS"
echo "Ignorados: $IGNORADOS"
echo "Log:       $LOG"
echo "=================================================="

[[ $FALHAS -eq 0 ]]
