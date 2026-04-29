#arquivo apagado dentro do LXC
#        ↓
#filesystem marca blocos como livres
#        ↓
#fstrim informa ao LVM-thin/SSD/NVMe: “esses blocos podem ser descartados”
#        ↓
#thin pool recupera espaço
#
#!/bin/bash

LOG="/var/log/fstrim-lxc.log"

echo "========================================" >> "$LOG"
echo "Inicio: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

for id in $(pct list | awk 'NR>1 {print $1}'); do
  name=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
  status=$(pct status "$id" 2>/dev/null | awk '{print $2}')

  echo "===== CT $id ${name:-sem-nome} status=$status =====" | tee -a "$LOG"

  if [ "$status" = "running" ]; then
    pct fstrim "$id" 2>&1 | tee -a "$LOG"
  else
    echo "Pulando CT $id porque nao esta rodando." | tee -a "$LOG"
  fi
done

echo "Fim: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
echo "" >> "$LOG"
