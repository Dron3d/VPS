#!/bin/bash

# Настройки
NEW_SSH_PORT=2222
REPORT="/root/setup_report.txt"

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Направляем весь вывод и в консоль, и в файл отчета
exec > >(tee -a "$REPORT") 2>&1

echo -e "${GREEN}>>> Начинаю настройку безопасности (Ubuntu 24.04 + autoXRAY + Amnezia)...${NC}"

# 1. Установка пакетов
sudo apt update && sudo apt install -y fail2ban ufw psmisc curl

# 2. РЕШЕНИЕ ПРОБЛЕМЫ UBUNTU 24.04 (ssh.socket)
echo "--- Отключение ssh.socket ---"
sudo systemctl stop ssh.socket 2>/dev/null
sudo systemctl disable ssh.socket 2>/dev/null
sudo systemctl mask ssh.socket 2>/dev/null

# 2.1 Override для службы SSH
sudo mkdir -p /etc/systemd/system/ssh.service.d/
cat <<EOF | sudo tee /etc/systemd/system/ssh.service.d/override.conf
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStart=
ExecStart=/usr/sbin/sshd -D -p $NEW_SSH_PORT
EOF

# 3. Настройка SSH
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo sed -i '/^[#]*Port /d' /etc/ssh/sshd_config
echo "Port $NEW_SSH_PORT" | sudo tee -a /etc/ssh/sshd_config

# 4. Настройка Fail2Ban
cat <<EOF | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = $NEW_SSH_PORT
maxretry = 5
bantime = 1h
findtime = 10m
EOF

# 5. Настройка Firewall (UFW) - ТОЛЬКО ПРАВИЛА, НЕ ВКЛЮЧАЕМ
echo "--- Настройка правил UFW ---"
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow $NEW_SSH_PORT/tcp comment 'SSH Custom Port'
for p in 80/tcp 443 8443 10443 585 2408/udp; do
    sudo ufw allow $p
done

# 6. Безопасный перезапуск
if ! sudo /usr/sbin/sshd -t; then
    echo -e "${RED}ОШИБКА КОНФИГА! Выход.${NC}"
    exit 1
fi

sudo systemctl daemon-reload
sudo systemctl unmask ssh.service
sudo systemctl enable ssh.service

# Убиваем старые процессы на порту 2222 (если есть)
sudo fuser -k $NEW_SSH_PORT/tcp 2>/dev/null

echo "--- Перезапуск SSH ---"
sudo systemctl restart ssh

# ВКЛЮЧАЕМ UFW В САМОМ КОНЦЕ (это может оборвать связь)
echo "--- Включение Firewall ---"
echo "y" | sudo ufw enable
sudo systemctl restart fail2ban

echo -e "\n${GREEN}-------------------------------------------------------${NC}"
echo -e "${GREEN}ПРОВЕРКА СТАТУСА СИСТЕМЫ:${NC}"

sleep 1
REAL_PORT=$(sudo ss -tulpn | grep sshd | awk '{print $5}' | sed 's/.*://' | head -n 1)
if [ "$REAL_PORT" == "$NEW_SSH_PORT" ]; then
    echo -e "SSH Порт: ${GREEN}$REAL_PORT (OK)${NC}"
else
    echo -e "SSH Порт: ${RED}$REAL_PORT (ОШИБКА)${NC}"
fi

UFW_BOOT=$(systemctl is-enabled ufw)
echo -e "Автозапуск Firewall: ${GREEN}$UFW_BOOT${NC}"

echo -e "\n${YELLOW}Активные правила UFW:${NC}"
sudo ufw status verbose

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! Порт: ${RED}$NEW_SSH_PORT${NC}"
echo -e "Отчет сохранен в: $REPORT"
echo -e "${YELLOW}Скрипт завершен. Если связь оборвется, зайдите по порту $NEW_SSH_PORT${NC}"

# Пауза 10 секунд, чтобы ты успел прочитать вывод перед возможным разрывом
sleep 10
