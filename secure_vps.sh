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

echo -e "${GREEN}>>> ЗАПУСК НАСТРОЙКИ (Ubuntu 24.04 FIX)...${NC}"

# 1. Подготовка и фикс Ubuntu 24.04
sudo apt update && sudo apt install -y fail2ban ufw psmisc
sudo systemctl stop ssh.socket 2>/dev/null
sudo systemctl disable ssh.socket 2>/dev/null
sudo systemctl mask ssh.socket 2>/dev/null

# 2. Системный override (чтобы не было ошибки Directory Missing)
sudo mkdir -p /etc/systemd/system/ssh.service.d/
cat <<EOF | sudo tee /etc/systemd/system/ssh.service.d/override.conf
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStart=
ExecStart=/usr/sbin/sshd -D -p $NEW_SSH_PORT
EOF

# 3. Конфиг SSH
sudo sed -i '/^[#]*Port /d' /etc/ssh/sshd_config
echo "Port $NEW_SSH_PORT" | sudo tee -a /etc/ssh/sshd_config

# 4. Настройка UFW (ТОЛЬКО правила, БЕЗ включения)
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow $NEW_SSH_PORT/tcp
for p in 80/tcp 443 8443 10443 585 2408/udp; do sudo ufw allow $p; done

# 5. Проверка конфига
if ! sudo /usr/sbin/sshd -t; then
    echo -e "${RED}ОШИБКА КОНФИГА! ПРЕРЫВАЮ.${NC}"
    exit 1
fi

# 6. Перезапуск службы
sudo systemctl daemon-reload
sudo systemctl unmask ssh.service
sudo systemctl enable ssh.service
sudo fuser -k $NEW_SSH_PORT/tcp 2>/dev/null
sudo systemctl restart ssh

# -------------------------------------------------------
# БЛОК ПРОВЕРОК (Выводим ДО того, как связь может оборваться)
# -------------------------------------------------------
echo -e "\n${YELLOW}=== ФИНАЛЬНАЯ ПРОВЕРКА (СМОТРИ СЕЙЧАС) ===${NC}"

# Проверка порта
REAL_PORT=$(sudo ss -tulpn | grep sshd | awk '{print $5}' | sed 's/.*://' | head -n 1)
if [ "$REAL_PORT" == "$NEW_SSH_PORT" ]; then
    echo -e "SSH Порт: ${GREEN}$REAL_PORT (OK)${NC}"
else
    echo -e "SSH Порт: ${RED}ОШИБКА (Служба не на том порту)${NC}"
fi

# Проверка правил UFW (пока он еще в режиме подготовки)
echo -e "Автозапуск UFW: ${GREEN}$(systemctl is-enabled ufw)${NC}"
echo -e "Будут применены правила:"
sudo ufw show added

echo -e "\n${YELLOW}ВНИМАНИЕ: Через 10 секунд включится Firewall.${NC}"
echo -e "${YELLOW}Если связь оборвется, перезайди по порту $NEW_SSH_PORT${NC}"
echo -e "${YELLOW}Полный лог доступен в: cat $LOG${NC}"

# Даем время прочитать
sleep 10

# 7. Финальный аккорд (может разорвать сессию)
echo "--- Включение UFW и перезапуск Fail2Ban ---"
echo "y" | sudo ufw enable
sudo systemctl restart fail2ban
echo -e "${GREEN}ВСЁ ГОТОВО!${NC}"
