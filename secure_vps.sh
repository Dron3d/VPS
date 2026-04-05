#!/bin/bash

# Настройки
NEW_SSH_PORT=2222

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> Начинаю настройку безопасности (совместимость с autoXRAY)...${NC}"

# 1. Установка пакетов
sudo apt update && sudo apt install -y fail2ban ufw

# 2. РЕШЕНИЕ ПРОБЛЕМЫ UBUNTU 24.04 (ssh.socket)
# В новых Ubuntu сокет перехватывает порт 22. Его нужно полностью нейтрализовать.
echo "--- Отключение ssh.socket (фикс для Ubuntu 24.04) ---"
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl mask ssh.socket

# 3. Настройка SSH
echo "--- Смена порта SSH на $NEW_SSH_PORT ---"
# Делаем бэкап на всякий случай
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Удаляем любые строки Port, чтобы не было дублей, и пишем одну чистую
sudo sed -i '/^Port /d' /etc/ssh/sshd_config
sudo sed -i '/^#Port /d' /etc/ssh/sshd_config
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
sudo ufw allow $NEW_SSH_PORT/tcp comment 'SSH Custom'

# Разрешаем порты для XRAY и Amnezia (TCP/UDP)
for port in 80/tcp 443 8443 10443 585/tcp 2408/udp; do
    sudo ufw allow $port
done

# Автозапуск UFW при старте системы
sudo systemctl enable ufw
sudo sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
echo "y" | sudo ufw enable

# 6. Финальный перезапуск всех служб
echo "--- Перезапуск демонов ---"
sudo systemctl daemon-reload
sudo systemctl restart ssh
sudo systemctl restart fail2ban

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! Теперь SSH работает на порту: ${RED}$NEW_SSH_PORT${NC}"
echo -e "Проверь статус: ${GREEN}sudo ss -tulpn | grep ssh${NC}"
echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "Заходи: ssh -p $NEW_SSH_PORT root@ваш_ip"
