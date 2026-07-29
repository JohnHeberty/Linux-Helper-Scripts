# scripts/proxmox/ — scripts que rodam NO HOST PROXMOX

> ⚠️ **Diferente do resto de `scripts/`**: os scripts deste diretório **não rodam neste
> ambiente**. Eles rodam no **host Proxmox** (`pve1`), que é uma máquina separada — este
> ambiente (`/opt/jupyter`) é um container LXC *dentro* dele (LXC 142, `jupyternotebook`).

Ficam versionados aqui porque são infraestrutura deste projeto e o histórico/racional importa,
mas precisam ser copiados pro host antes de executar.

## Como copiar pro host

No host Proxmox, `pct pull` puxa um arquivo de dentro do container — sem precisar de SSH nem
copiar-colar:

```bash
pct pull 142 /opt/jupyter/scripts/proxmox/nvidia_lxc_gpu_passthrough.sh \
  /root/nvidia_lxc_gpu_passthrough.sh
chmod +x /root/nvidia_lxc_gpu_passthrough.sh
```

## Scripts

### `nvidia_lxc_gpu_passthrough.sh`

Configura GPU passthrough NVIDIA de ponta a ponta pra qualquer container LXC, **incluindo pra
containers Docker aninhados dentro dele** (é isso que o `exploration0/margem-train-p2` precisa
pra treinar XGBoost/CatBoost na GPU).

```bash
./nvidia_lxc_gpu_passthrough.sh <VMID> [--capabilities compute,utility] [--dry-run] [--yes]
                                       [--skip-docker-install] [--test-image <imagem>]
```

Faz tudo: descobre dinamicamente os arquivos do driver instalado **agora** (nada hardcoded —
sobrevive a upgrade de driver), reescreve o bloco gerenciado do `/etc/pve/lxc/<VMID>.conf`
(com backup automático, removendo configuração manual antiga), reinicia o container, instala
Docker + `nvidia-container-toolkit` dentro dele se faltarem, aplica as configurações
específicas de LXC (`no-cgroups`), e **testa de verdade** (`docker run --gpus all ... nvidia-smi`)
com relatório final PASS/FAIL — incluindo se todos os containers Docker que estavam rodando
antes voltaram.

Sempre rode com `--dry-run` primeiro pra revisar o diff proposto no `.conf`.

O cabeçalho do próprio script documenta os 4 problemas reais (e não-óbvios) que ele resolve,
descobertos na mão em 2026-07-29 — vale ler antes de mexer nele.
