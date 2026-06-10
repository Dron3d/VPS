#!/bin/bash
set -e

GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m'

CONFIG_FILE="/etc/telemt/telemt.toml"

# === РЕЖИМ УДАЛЕНИЯ (ОТКАТ) ===
if [[ "$1" == "remove" || "$1" == "uninstall" ]]; then
    echo -e "${YEL}🗑 Удаление настроек telemt-tune...${NC}"
    systemctl stop telemt-in-syn-limit.service 2>/dev/null || true
    systemctl disable telemt-in-syn-limit.service 2>/dev/null || true
    rm -f /etc/systemd/system/telemt-in-syn-limit.service
    rm -f /usr/local/sbin/telemt-in-syn-limit.sh
    systemctl daemon-reload
    nft delete table inet telemt_limit 2>/dev/null || true
    
    if [ -f "$CONFIG_FILE" ]; then
        sed -i '/^[[:space:]]*tg_connect[[:space:]]*=/d' "$CONFIG_FILE"
        sed -i '/^\[timeouts\]/,$d' "$CONFIG_FILE"
        systemctl restart telemt 2>/dev/null || true
    fi
    echo -e "${GRN}✅ Все изменения успешно откатаны!${NC}"
    exit 0
fi

# === РЕЖИМ УСТАНОВКИ ===
echo -e "${YEL}=== Telemt Bare-Metal Tuning & SYN Limiter Script ===${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ Этот скрипт нужно запускать с правами root (sudo).${NC}" 
   exit 1
fi

if ! command -v telemt &> /dev/null && [ ! -f /bin/telemt ] && [ ! -f /usr/bin/telemt ]; then
    echo -e "${RED}❌ telemt не найден в системе. Сначала установите telemt.${NC}"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Конфиг telemt не найден по пути $CONFIG_FILE.${NC}"
    exit 1
fi

PORT=$(awk -F'=' '/^[ \t]*port[ \t]*=/ {gsub(/[^0-9]/, "", $2); print $2; exit}' "$CONFIG_FILE")
if [ -z "$PORT" ]; then
    PORT="8443"
    echo -e "${YEL}⚠️ Порт не найден в конфиге, используем дефолтный: $PORT${NC}"
else
    echo -e "${GRN}✅ Обнаружен порт telemt: $PORT${NC}"
fi

echo -e "${YEL}📦 Проверка и установка зависимостей (nftables, curl)...${NC}"
if command -v apt-get &> /dev/null; then
    apt-get update -qq && apt-get install -y -qq nftables curl > /dev/null 2>&1
elif command -v dnf &> /dev/null; then
    dnf install -y -q nftables curl > /dev/null 2>&1
elif command -v yum &> /dev/null; then
    yum install -y -q nftables curl > /dev/null 2>&1
fi
echo -e "${GRN}✅ Зависимости готовы.${NC}"

echo -e "${YEL}🛡 Создание скрипта nftables лимитера...${NC}"
cat > /usr/local/sbin/telemt-in-syn-limit.sh <<EOF
#!/bin/sh
set -eu
PORT="$PORT"
IP=\$(curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null || echo "")

if [ -z "\$IP" ]; then
    echo "Failed to get IP" >&2
    exit 1
fi

nft delete table inet telemt_limit 2>/dev/null || true
nft add table inet telemt_limit
nft 'add chain inet telemt_limit input { type filter hook input priority 0; policy accept; }'
nft "add rule inet telemt_limit input \\
ip daddr \$IP tcp dport \$PORT \\
tcp flags & (syn | ack) == syn \\
meter telemt_in_syn_per_client { ip saddr timeout 60s limit rate over 1/second burst 1 packets } \\
counter drop comment \\"telemt_in_syn_per_client_1ps_burst1\\""

echo "Applied nftables rule for IP=\$IP PORT=\$PORT"
EOF
chmod +x /usr/local/sbin/telemt-in-syn-limit.sh

echo -e "${YEL}⚙️ Настройка автозагрузки (systemd)...${NC}"
cat > /etc/systemd/system/telemt-in-syn-limit.service <<EOF
[Unit]
Description=Apply nft inbound SYN per-client limiter for telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/telemt-in-syn-limit.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt-in-syn-limit.service > /dev/null 2>&1
systemctl restart telemt-in-syn-limit.service
echo -e "${GRN}✅ Автозагрузка настроена и правило применено.${NC}"

echo -e "${YEL}⏱ Тюнинг таймаутов telemt...${NC}"
if ! grep -q "^[[:space:]]*tg_connect[[:space:]]*=" "$CONFIG_FILE"; then
    sed -i '/^\[general\]/a tg_connect = 10' "$CONFIG_FILE"
    echo -e "${GRN}  -> Добавлен tg_connect = 10${NC}"
else
    echo -e "${YEL}  -> tg_connect уже настроен, пропускаем.${NC}"
fi

if ! grep -q "^\[timeouts\]" "$CONFIG_FILE"; then
    cat << 'EOF' >> "$CONFIG_FILE"

[timeouts]
client_handshake = 15
client_keepalive = 60
EOF
    echo -e "${GRN}  -> Добавлена секция [timeouts]${NC}"
else
    echo -e "${YEL}  -> Секция [timeouts] уже существует, пропускаем.${NC}"
fi

echo -e "${YEL}🔄 Перезапуск telemt для применения настроек...${NC}"
systemctl restart telemt
sleep 2

if systemctl is-active --quiet telemt; then
    echo -e "${GRN}✅ telemt успешно перезапущен и работает!${NC}"
else
    echo -e "${RED}❌ Ошибка: telemt не запустился. Проверьте логи: journalctl -u telemt -n 20${NC}"
    exit 1
fi

echo -e "\n${GRN}========================================${NC}"
echo -e "${GRN}🎉 НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo -e "${GRN}========================================${NC}"
echo -e "🛡 ${YEL}Защита nftables:${NC} Активна (inbound SYN limiter на порту $PORT)"
echo -e "⏱ ${YEL}Таймауты:${NC} Оптимизированы для мобильных сетей"
