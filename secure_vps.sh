#!/bin/bash

# Настройки - выбери порт, который НЕ занят xray (например, 2222)
NEW_SSH_PORT=2222

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> Начинаю настройку безопасности (совместимость с autoXRAY)...${NC}"

# 1. Установка пакетов
sudo apt update && sudo apt install -y fail2ban ufw

# 2. РЕШЕНИЕ ПРОБЛЕМЫ UBUNTU 24.04 (ssh.socket)
# Отключаем сокет, который мешает смене порта
echo "--- Отключение ssh.socket (фикс для Ubuntu 24.04) ---"
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl mask ssh.socket

# 3. Настройка SSH
echo "--- Смена порта SSH на $NEW_SSH_PORT ---"
sudo sed -i "s/^#Port 22/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^Port 22/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
# Убираем старые привязки к 10443, если они были
sudo sed -i "s/^Port 10443/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config

# 4. Настройка Fail2Ban
echo "--- Настройка Fail2Ban ---"
cat <<EOF | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = $NEW_SSH_PORT
maxretry = 5
bantime = 1h
EOF
sudo systemctl restart fail2ban

# 5. Настройка Firewall (UFW)
echo "--- Настройка UFW ---"
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешаем новый SSH
sudo ufw allow $NEW_SSH_PORT/tcp comment 'SSH Custom'

# Разрешаем порты для XRAY (TCP/UDP)
sudo ufw allow 80/tcp
sudo ufw allow 443
sudo ufw allow 8443
sudo ufw allow 10443
sudo ufw allow 585/tcp
sudo ufw allow 2408/udp

# Автозапуск UFW
sudo systemctl enable ufw
sudo sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
echo "y" | sudo ufw enable

# 6. Финальный перезапуск SSH
sudo systemctl restart ssh

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! Теперь SSH работает на порту: ${RED}$NEW_SSH_PORT${NC}"
echo -e "Порт 10443 ОСТАВЛЕН для работы XRAY."
echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "Заходи командой: ssh -p $NEW_SSH_PORT root@твой_ip"
