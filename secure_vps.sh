#!/bin/bash

# Настройки
NEW_SSH_PORT=49152

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> Начинаю полную настройку безопасности и автозапуска UFW...${NC}"

# 1. Установка и подготовка
echo "--- Установка Fail2Ban и UFW ---"
sudo apt update
sudo apt install -y fail2ban ufw

# 2. Настройка SSH
echo "--- Смена порта SSH на $NEW_SSH_PORT ---"
sudo sed -i "s/^#Port 22/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^Port 22/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
sudo systemctl restart ssh

# 3. Настройка Fail2Ban
echo "--- Настройка Fail2Ban ---"
cat <<EOF | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = $NEW_SSH_PORT
maxretry = 5
bantime = 1h
EOF
sudo systemctl restart fail2ban

# 4. РЕШЕНИЕ ПРОБЛЕМЫ АВТОЗАПУСКА UFW
echo "--- Настройка автозапуска UFW ---"

# Включаем службу в systemd, чтобы она стартовала при загрузке ядра
sudo systemctl enable ufw

# Правим конфиг самого UFW, чтобы он знал, что должен быть активен
sudo sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf

# 5. Правила Firewall
echo "--- Применение правил портов ---"
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешаем SSH и прокси-порты
sudo ufw allow $NEW_SSH_PORT/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443
sudo ufw allow 8443
sudo ufw allow 10443
sudo ufw allow 585/tcp
sudo ufw allow 2408/udp

# Финальное включение
echo "y" | sudo ufw enable

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "UFW настроен на АВТОЗАПУСК при старте системы."
echo -e "Проверить статус после перезагрузки: ${RED}sudo ufw status${NC}"
echo -e "Новый порт SSH: ${RED}$NEW_SSH_PORT${NC}"
echo -e "${GREEN}-------------------------------------------------------${NC}"
