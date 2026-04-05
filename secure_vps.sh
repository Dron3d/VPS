#!/bin/bash

# Настройки
NEW_SSH_PORT=2222

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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
sudo mkdir -p /etc/ssh/sshd_config.d/
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

echo -e "\n${GREEN}-------------------------------------------------------${NC}"
echo -e "${GREEN}ПРОВЕРКА СТАТУСА СИСТЕМЫ:${NC}"

# Проверка порта SSH в реальности
REAL_PORT=$(sudo ss -tulpn | grep sshd | awk '{print $5}' | sed 's/.*://' | head -n 1)
if [ "$REAL_PORT" == "$NEW_SSH_PORT" ]; then
    echo -e "SSH Порт: ${GREEN}$REAL_PORT (OK)${NC}"
else
    echo -e "SSH Порт: ${RED}$REAL_PORT (ОШИБКА, ожидалось $NEW_SSH_PORT)${NC}"
fi

# Проверка автозапуска UFW
UFW_BOOT=$(systemctl is-enabled ufw)
echo -e "Автозапуск Firewall: ${GREEN}$UFW_BOOT${NC}"

# Вывод правил фаервола
echo -e "\n${YELLOW}Активные правила UFW:${NC}"
sudo ufw status verbose

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! SSH на порту: ${RED}$NEW_SSH_PORT${NC}"
echo -e "Команда входа: ${RED}ssh -p $NEW_SSH_PORT root@ваша_ip${NC}"
