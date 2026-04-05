#!/bin/bash

# Настройки
NEW_SSH_PORT=2222

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> Начинаю настройку безопасности (совместимость с autoXRAY и Amnezia)...${NC}"

# 1. Установка пакетов
sudo apt update && sudo apt install -y fail2ban ufw

# 2. РЕШЕНИЕ ПРОБЛЕМЫ UBUNTU 24.04 (ssh.socket)
echo "--- Отключение ssh.socket (фикс для Ubuntu 24.04) ---"
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl mask ssh.socket

# 3. Настройка SSH
echo "--- Смена порта SSH на $NEW_SSH_PORT ---"
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
# Удаляем ВСЕ упоминания Port
sudo sed -i '/^[#]*Port /d' /etc/ssh/sshd_config
# Создаем drop-in конфиг и добавляем порт в основной файл
echo "Port $NEW_SSH_PORT" | sudo tee /etc/ssh/sshd_config.d/port.conf
echo "Port $NEW_SSH_PORT" | sudo tee -a /etc/ssh/sshd_config

# 4. Настройка Fail2Ban
echo "--- Настройка Fail2Ban ---"
cat <<EOF | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = $NEW_SSH_PORT
maxretry = 5
bantime = 1h
findtime = 10m
EOF

# 5. Настройка Firewall (UFW)
echo "--- Настройка UFW ---"
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешаем новый SSH порт
sudo ufw allow $NEW_SSH_PORT/tcp comment 'SSH Custom Port'

# Разрешаем порты для XRAY и Amnezia
# 585 открываем без /tcp, чтобы работал и UDP (туннель AmneziaWG), и TCP (управление)
for p in 80/tcp 443 8443 10443 585 2408/udp; do
    sudo ufw allow $p
done

# Включаем автозапуск и активируем
sudo systemctl enable ufw
sudo sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
echo "y" | sudo ufw enable

# 6. Финальный перезапуск всех служб
echo "--- Перезапуск демонов и применение настроек ---"
sudo systemctl daemon-reload
sudo systemctl restart ssh
sudo systemctl restart fail2ban

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! SSH на порту: ${RED}$NEW_SSH_PORT${NC}"
echo -e "Порт 585 открыт для TCP и UDP (Amnezia).${NC}"
echo -e "-------------------------------------------------------${NC}"
echo -e "Команда входа: ${RED}ssh -p $NEW_SSH_PORT root@ваш_ip${NC}"
