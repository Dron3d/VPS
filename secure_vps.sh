#!/bin/bash

# Настройки
NEW_SSH_PORT=2222
LOG="/root/debug_ssh.log"

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Пишем всё в лог параллельно с экраном
exec > >(tee -a "$LOG") 2>&1

echo -e "${GREEN}>>> ЗАПУСК ПОЛНОЙ НАСТРОЙКИ (Ubuntu 24.04 FIX)...${NC}"

# 1. Подготовка и установка
sudo apt update && sudo apt install -y fail2ban ufw psmisc curl

# 2. РЕШЕНИЕ ПРОБЛЕМЫ UBUNTU 24.04 (ssh.socket)
echo "--- Полное отключение ssh.socket (фикс для Ubuntu 24.04) ---"
sudo systemctl stop ssh.socket 2>/dev/null
sudo systemctl disable ssh.socket 2>/dev/null
sudo systemctl mask ssh.socket 2>/dev/null

# 2.1 Системный override (решает Missing privilege separation directory)
sudo mkdir -p /etc/systemd/system/ssh.service.d/
cat <<EOF | sudo tee /etc/systemd/system/ssh.service.d/override.conf
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStart=
ExecStart=/usr/sbin/sshd -D -p $NEW_SSH_PORT
EOF

# 3. Настройка SSH (drop-in + основной конфиг)
echo "--- Настройка порта SSH на $NEW_SSH_PORT ---"
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo sed -i '/^[#]*Port /d' /etc/ssh/sshd_config
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
echo "--- Настройка правил UFW ---"
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow $NEW_SSH_PORT/tcp comment 'SSH Custom Port'

# Разрешаем порты для XRAY и Amnezia
for p in 80/tcp 443 8443 10443 585 2408/udp; do
    sudo ufw allow $p
done

# Принудительная активация UFW в конфиге
sudo sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf

# 6. Проверка конфига и перезапуск
echo "--- Проверка конфигурации SSH ---"

# ФИКС: Создаем директорию вручную, чтобы sshd -t не выдавал ошибку на чистой системе
sudo mkdir -p /run/sshd
sudo chmod 755 /run/sshd

if ! sudo /usr/sbin/sshd -t; then
    echo -e "${RED}ОШИБКА КОНФИГА SSH! ПРЕРЫВАЮ.${NC}"
    # Выводим конкретную ошибку из системы для диагностики
    sudo /usr/sbin/sshd -t
    exit 1
fi

echo "--- Применение настроек и активация АВТОЗАГРУЗКИ ---"
sudo systemctl daemon-reload

# Включаем автозапуск служб
sudo systemctl unmask ssh.service
sudo systemctl enable ssh.service
sudo systemctl unmask ufw.service
sudo systemctl enable ufw.service

# Очистка порта перед запуском (убиваем старые процессы sshd)
sudo fuser -k $NEW_SSH_PORT/tcp 2>/dev/null

# Финальный запуск
sudo systemctl restart ssh
sudo systemctl restart fail2ban
echo "y" | sudo ufw enable

# -------------------------------------------------------
# БЛОК ПРОВЕРОК
# -------------------------------------------------------
echo -e "\n${GREEN}-------------------------------------------------------${NC}"
echo -e "${GREEN}ПРОВЕРКА СТАТУСА СИСТЕМЫ:${NC}"

# Реальный порт через ss
sleep 1
REAL_PORT=$(sudo ss -tulpn | grep sshd | awk '{print $5}' | sed 's/.*://' | head -n 1)
if [ "$REAL_PORT" == "$NEW_SSH_PORT" ]; then
    echo -e "SSH Порт: ${GREEN}$REAL_PORT (OK)${NC}"
else
    echo -e "SSH Порт: ${RED}$REAL_PORT (ОШИБКА, ожидалось $NEW_SSH_PORT)${NC}"
    sudo systemctl status ssh --no-pager
fi

# Проверка автозагрузки (UFW и SSH)
UFW_BOOT=$(systemctl is-enabled ufw)
SSH_BOOT=$(systemctl is-enabled ssh)
echo -e "Автозапуск Firewall: ${GREEN}$UFW_BOOT${NC}"
echo -e "Автозапуск SSH: ${GREEN}$SSH_BOOT${NC}"

# Статус UFW
echo -e "\n${YELLOW}Активные правила UFW:${NC}"
sudo ufw status verbose

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! SSH на порту: ${RED}$NEW_SSH_PORT${NC}"
echo -e "Лог сохранен: $LOG${NC}"
echo -e "Для входа: ssh -p $NEW_SSH_PORT root@$(curl -s https://ifconfig.me)${NC}"
