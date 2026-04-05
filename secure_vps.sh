#!/bin/bash

# Настройки
NEW_SSH_PORT=2222

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}>>> Начинаю настройку безопасности (Ubuntu 24.04 + autoXRAY + Amnezia)...${NC}"

# 1. Установка пакетов
sudo apt update && sudo apt install -y fail2ban ufw psmisc

# 2. РЕШЕНИЕ ПРОБЛЕМЫ UBUNTU 24.04 (ssh.socket)
echo "--- Отключение ssh.socket (фикс для Ubuntu 24.04) ---"
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl mask ssh.socket

# 2.1 ПРИНУДИТЕЛЬНОЕ ПЕРЕОПРЕДЕЛЕНИЕ СЛУЖБЫ (Fix Missing privilege separation directory)
# Гарантирует создание /run/sshd и запуск на нужном порту после ребута
echo "--- Создание override для ssh.service ---"
sudo mkdir -p /etc/systemd/system/ssh.service.d/
cat <<EOF | sudo tee /etc/systemd/system/ssh.service.d/override.conf
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStart=
ExecStart=/usr/sbin/sshd -D -p $NEW_SSH_PORT
EOF

# 3. Настройка SSH
echo "--- Смена порта SSH на $NEW_SSH_PORT ---"
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
# Удаляем ВСЕ упоминания Port и записываем один нужный
sudo sed -i '/^[#]*Port /d' /etc/ssh/sshd_config
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
for p in 80/tcp 443 8443 10443 585 2408/udp; do
    sudo ufw allow $p
done

# Включаем автозапуск и активируем
sudo systemctl enable ufw
sudo sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
echo "y" | sudo ufw enable

# 6. Финальный перезапуск всех служб с проверкой безопасности
echo "--- Проверка конфигурации перед перезапуском ---"

# ТЕСТ: Если в конфиге ошибка, мы НЕ пойдем дальше
if ! sudo /usr/sbin/sshd -t; then
    echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Ошибка в конфигурации SSH!${NC}"
    echo -e "${YELLOW}Изменения не применены. Исправьте ошибки, прежде чем выходить из текущей сессии.${NC}"
    exit 1
fi

echo "--- Применение настроек и перезапуск SSH ---"
# Очищаем порт от зависших процессов, чтобы избежать "Address already in use"
sudo fuser -k $NEW_SSH_PORT/tcp 2>/dev/null

sudo systemctl daemon-reload
sudo systemctl unmask ssh.service
sudo systemctl enable ssh.service

if sudo systemctl restart ssh; then
    echo -e "${GREEN}Служба SSH успешно перезапущена на порту $NEW_SSH_PORT${NC}"
else
    echo -e "${RED}ОШИБКА: Не удалось запустить службу SSH! ПРОВЕРЬТЕ СТАТУС!${NC}"
fi

sudo systemctl restart fail2ban

echo -e "\n${GREEN}-------------------------------------------------------${NC}"
echo -e "${GREEN}ПРОВЕРКА СТАТУСА СИСТЕМЫ:${NC}"

# Проверка порта SSH в реальности (ждем секунду для инициализации)
sleep 1
REAL_PORT=$(sudo ss -tulpn | grep sshd | awk '{print $5}' | sed 's/.*://' | head -n 1)
if [ "$REAL_PORT" == "$NEW_SSH_PORT" ]; then
    echo -e "SSH Порт: ${GREEN}$REAL_PORT (OK)${NC}"
else
    echo -e "SSH Порт: ${RED}$REAL_PORT (ОШИБКА, ожидалось $NEW_SSH_PORT)${NC}"
    sudo systemctl status ssh --no-pager
fi

# Проверка автозапуска UFW
UFW_BOOT=$(systemctl is-enabled ufw)
echo -e "Автозапуск Firewall: ${GREEN}$UFW_BOOT${NC}"

# Вывод правил фаервола
echo -e "\n${YELLOW}Активные правила UFW:${NC}"
sudo ufw status verbose

echo -e "${GREEN}-------------------------------------------------------${NC}"
echo -e "ГОТОВО! SSH на порту: ${RED}$NEW_SSH_PORT${NC}"
echo -e "ВАЖНО: Не закрывайте это окно, пока не проверите вход в НОВОМ окне:${NC}"
echo -e "${YELLOW}ssh -p $NEW_SSH_PORT root@$(curl -s https://ifconfig.me)${NC}"
