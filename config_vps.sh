#!/bin/bash
# ==========================================================
# VPS Setup & Optimization (Ubuntu 22.04/24.04)
# Target: 1 CPU / 1GB RAM | VPN/Proxy (Xray, telemt, Amnezia)
# ==========================================================

if [[ $EUID -ne 0 ]]; then
   echo "❌ Скрипт необходимо запускать от имени root (sudo -i)"
   exit 1
fi

# Переменные
NEW_SSH_PORT=2222
LOG="/root/vps_setup.log"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

exec > >(tee -a "$LOG") 2>&1
echo -e "${GREEN}>>> ЗАПУСК ПОЛНОЙ НАСТРОЙКИ И ОПТИМИЗАЦИИ VPS...${NC}"
echo -e "${YELLOW}⚠️ Перезагрузка отключена. Все изменения применяются на лету.${NC}\n"

# Надёжная проверка шага
check_step() {
    local cmd="$1"
    local msg="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $msg${NC}"
    else
        echo -e "${RED}❌ $msg${NC}"
    fi
}

# ==========================================================
# 1. ПАКЕТЫ И ОБНОВЛЕНИЕ ЯДРА
# ==========================================================
echo -e "${YELLOW}--- 1. Установка пакетов и обновление системы ---${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Убраны iptables-persistent и netfilter-persistent (конфликт с UFW в 24.04)
apt-get install -y -qq fail2ban ufw psmisc curl chrony sysstat lsof grub-pc binutils iptables
apt-get upgrade -y -qq

KERNEL_UPDATED=false
if [[ -f /var/run/reboot-required ]]; then
    echo -e "${YELLOW}⚠️ Ядро обновлено. Перезагрузка потребуется ПОСЛЕ завершения всех проверок.${NC}"
    KERNEL_UPDATED=true
fi
check_step "dpkg -l fail2ban chrony ufw | grep -q '^ii'" "Критичные пакеты установлены"

# ==========================================================
# 2. SWAP (2GB)
# ==========================================================
echo -e "\n${YELLOW}--- 2. Настройка Swap (2GB) ---${NC}"
if ! swapon --show | grep -q '/swapfile'; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
check_step "swapon --show | grep -q '/swapfile'" "Swap активен"
check_step "sysctl vm.swappiness | grep -q '10'" "Swappiness оптимизирован (10)"

# ==========================================================
# 3. СЕТЬ И TCP (BBR + Буферы)
# ==========================================================
echo -e "\n${YELLOW}--- 3. Оптимизация сети (BBR, буферы, TCP) ---${NC}"
cat <<EOF > /etc/sysctl.d/99-vpn-optimizations.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.ipv4.tcp_fastopen=3
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
EOF
sysctl -p /etc/sysctl.d/99-vpn-optimizations.conf >/dev/null
check_step "sysctl net.ipv4.tcp_congestion_control | grep -q 'bbr'" "BBR включен"
check_step "sysctl net.ipv4.tcp_fastopen | grep -q '3'" "TCP FastOpen активен"

# ==========================================================
# 4. ЛИМИТЫ ФАЙЛОВ И СОЕДИНЕНИЙ
# ==========================================================
echo -e "\n${YELLOW}--- 4. Лимиты соединений (nofile) ---${NC}"
cat <<EOF > /etc/security/limits.d/99-nofile.conf
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF
mkdir -p /etc/systemd/system.conf.d
echo -e "[Manager]\nDefaultLimitNOFILE=51200" > /etc/systemd/system.conf.d/99-nofile.conf
systemctl daemon-reload
check_step "grep -q 'DefaultLimitNOFILE=51200' /etc/systemd/system.conf.d/99-nofile.conf" "Systemd лимиты применены"

# ==========================================================
# 5. ПОЛНОЕ ОТКЛЮЧЕНИЕ IPv6
# ==========================================================
echo -e "\n${YELLOW}--- 5. Отключение IPv6 (ядро + GRUB) ---${NC}"
cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null
if ! grep -q "ipv6.disable=1" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
    update-grub >/dev/null 2>&1
fi
check_step "cat /proc/sys/net/ipv6/conf/all/disable_ipv6 | grep -q '1'" "IPv6 отключен в ядре"
check_step "grep -q 'ipv6.disable=1' /etc/default/grub" "IPv6 отключен в GRUB"

# ==========================================================
# 6. СИНХРОНИЗАЦИЯ ВРЕМЕНИ (CHRONY)
# ==========================================================
echo -e "\n${YELLOW}--- 6. Настройка Chrony (плавная синхронизация) ---${NC}"
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true
mkdir -p /etc/chrony
cat <<EOF > /etc/chrony/chrony.conf
pool time.google.com iburst maxsources 4
pool time.cloudflare.com iburst maxsources 4
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chrony >/dev/null 2>&1
chronyc makestep 2>/dev/null || true
check_step "systemctl is-active --quiet chrony" "Chrony запущен"
check_step "chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'" "Время синхронизировано"

# ==========================================================
# 7. MSS CLAMPING (SYSTEMD SERVICE)
# ==========================================================
echo -e "\n${YELLOW}--- 7. MSS Clamping (фикс MTU для VPN) ---${NC}"
cat <<EOF > /etc/systemd/system/mss-clamp.service
[Unit]
Description=Apply MSS Clamping for VPN
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mss-clamp.service >/dev/null 2>&1
check_step "iptables-save | grep -q 'clamp-mss-to-pmtu'" "MSS Clamping активен и сохраняется при загрузке"

# ==========================================================
# 8. SSH, FAIL2BAN, UFW
# ==========================================================
echo -e "\n${YELLOW}--- 8. Безопасность: SSH, Fail2Ban, UFW ---${NC}"
# Фикс ssh.socket для Ubuntu 24.04
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl mask ssh.socket 2>/dev/null || true
mkdir -p /etc/systemd/system/ssh.service.d/
cat <<EOF > /etc/systemd/system/ssh.service.d/override.conf
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStart=
ExecStart=/usr/sbin/sshd -D -p $NEW_SSH_PORT
EOF

# Конфиг SSH
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i '/^[#]*Port /d' /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d/
echo "Port $NEW_SSH_PORT" > /etc/ssh/sshd_config.d/port.conf
echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config

# Fail2Ban
mkdir -p /etc/fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = $NEW_SSH_PORT
maxretry = 5
bantime = 1h
findtime = 10m
EOF

# UFW: Сброс и правила (строго под ваш стек + ACME)
sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed
ufw allow in on lo
ufw allow out on lo

ufw allow $NEW_SSH_PORT/tcp comment 'SSH Custom Port'
ufw allow 80/tcp comment 'HTTP/ACME & Redirect'
ufw allow 443/tcp comment 'REALITY/VLESS/telemt'
ufw allow 443/udp comment 'REALITY/VLESS UDP'
ufw allow 8443/tcp comment 'Protomt/TLS-Alt'
ufw allow 8443/udp comment 'Protomt/TLS-Alt UDP'
ufw allow 585/tcp comment 'AmneziaVPN Control'
ufw allow 585/udp comment 'AmneziaVPN/WG'
ufw allow 2408/udp comment 'AmneziaWG Data'

sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf

mkdir -p /run/sshd
chmod 755 /run/sshd
if ! /usr/sbin/sshd -t; then
    echo -e "${RED}❌ ОШИБКА КОНФИГА SSH! ПРЕРЫВАЮ.${NC}"
    /usr/sbin/sshd -t
    exit 1
fi

systemctl daemon-reload
systemctl unmask ssh.service ufw.service fail2ban.service
systemctl enable ssh.service fail2ban.service ufw.service
fuser -k $NEW_SSH_PORT/tcp 2>/dev/null || true
systemctl restart ssh
systemctl restart fail2ban
echo "y" | ufw enable >/dev/null 2>&1
ufw reload >/dev/null 2>&1

check_step "ss -tulpn | grep sshd | grep -q ':$NEW_SSH_PORT'" "SSH слушает порт $NEW_SSH_PORT"
check_step "systemctl is-active --quiet fail2ban" "Fail2Ban активен"
check_step "ufw status | grep -q 'Status: active'" "UFW активен"

# ==========================================================
# 9. ОЧИСТКА КЭШЕЙ И ЛОГОВ
# ==========================================================
echo -e "\n${YELLOW}--- 9. Очистка системы ---${NC}"
apt-get autoremove -y -qq >/dev/null 2>&1
apt-get clean
journalctl --vacuum-size=50M >/dev/null 2>&1
find /var/log -type f -regex '.*\.[0-9]$' -delete 2>/dev/null
find /var/log -type f -name '*.gz' -delete 2>/dev/null
check_step "test \$(df / | awk 'NR==2{print \$5}' | tr -d '%') -lt 90" "Диск очищен (<90% занято)"

# ==========================================================
# 10. ФИНАЛЬНАЯ ПРОВЕРКА
# ==========================================================
echo -e "\n${GREEN}=======================================================${NC}"
echo -e "${GREEN}📊 ИТОГОВАЯ ПРОВЕРКА КОНФИГУРАЦИИ:${NC}"
sleep 1

SSH_REAL=$(ss -tulpn | grep sshd | awk '{print $5}' | sed 's/.*://' | head -n 1)
[[ "$SSH_REAL" == "$NEW_SSH_PORT" ]] && echo -e "SSH Порт:        ${GREEN}$SSH_REAL (OK)${NC}" || echo -e "SSH Порт:        ${RED}$SSH_REAL (ОШИБКА)${NC}"

systemctl is-active --quiet ufw && echo -e "UFW Status:      ${GREEN}Active${NC}" || echo -e "UFW Status:      ${RED}Inactive${NC}"
systemctl is-active --quiet fail2ban && echo -e "Fail2Ban:        ${GREEN}Running${NC}" || echo -e "Fail2Ban:        ${RED}Stopped${NC}"
swapon --show | grep -q '/swapfile' && echo -e "Swap:            ${GREEN}Active (2GB)${NC}" || echo -e "Swap:            ${YELLOW}Check manually${NC}"
sysctl net.ipv4.tcp_congestion_control | grep -q 'bbr' && echo -e "BBR:             ${GREEN}Enabled${NC}" || echo -e "BBR:             ${RED}Disabled${NC}"
[[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "1" ]] && echo -e "IPv6:            ${GREEN}Disabled${NC}" || echo -e "IPv6:            ${RED}Enabled${NC}"
command -v chronyc >/dev/null 2>&1 && chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && echo -e "Chrony Sync:     ${GREEN}Synced${NC}" || echo -e "Chrony Sync:     ${YELLOW}Syncing...${NC}"
iptables-save | grep -q 'clamp-mss-to-pmtu' && echo -e "MSS Clamping:    ${GREEN}Active${NC}" || echo -e "MSS Clamping:    ${RED}Missing${NC}"
echo -e "Disk Usage:      $(df -h / | awk 'NR==2{print $5}')"

echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}✅ НАСТРОЙКА ЗАВЕРШЕНА БЕЗ ПЕРЕЗАГРУЗКИ!${NC}"
echo -e "Для входа: ${YELLOW}ssh -p $NEW_SSH_PORT root@$(curl -s https://ifconfig.me)${NC}"
if [[ "$KERNEL_UPDATED" == true ]]; then
    echo -e "\n${YELLOW}⚠️ ВНИМАНИЕ: Ядро Linux обновлено.${NC}"
    echo -e "Выполните ${YELLOW}reboot${NC} вручную, когда убедитесь, что все проверки выше ✅."
fi
echo -e "Лог установки: $LOG"
