#!/bin/bash
# Цвета для вывода
GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color
[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ скрипту нужны root права ${NC}"; exit 1; }
DOMAIN=$1
if [ -z "$DOMAIN" ]; then
echo -e "${RED}❌ Ошибка: домен не задан.${NC}"
exit 1
fi

echo -e "${YEL}Обновление и установка необходимых пакетов...${NC}"
apt-get update && apt-get install curl jq dnsutils openssl nginx certbot -y

# 🔧 ФИКС: Ошибка IPv6 на VPS без поддержки IPv6
sed -i 's/listen \[::\]:80 default_server;/#listen [::]:80 default_server;/' /etc/nginx/sites-available/default 2>/dev/null || true
sed -i 's/listen \[::\]:80;/#listen [::]:80;/' /etc/nginx/conf.d/default.conf 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

systemctl enable --now nginx

LOCAL_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" | grep '^[0-9]')
if [ "$LOCAL_IP" != "$DNS_IP" ]; then
echo -e "${RED}❌ Внимание: IP-адрес ($LOCAL_IP) не совпадает с A-записью $DOMAIN ($DNS_IP).${NC}"
echo -e "${YEL}Правильно укажите одну A-запись для вашего домена в ДНС - $LOCAL_IP ${NC}"
read -p "Продолжить на ваш страх и риск? (y/N):" choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
echo -e "${RED}Выполнение скрипта прервано.${NC}"
exit 1
fi
echo -e "${YEL}Продолжение выполнения скрипта...${NC}"
fi

# Включаем BBR
bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
echo -e "${GRN}BBR уже запущен${NC}"
else
echo "net.core.default_qdisc=fq" > /etc/sysctl.d/999-autoXRAY.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/999-autoXRAY.conf
sysctl --system
echo -e "${GRN}BBR активирован${NC}"
fi

cat <<EOF > /etc/security/limits.d/99-autoXRAY.conf
*               soft    nofile          65535
*               hard    nofile          65535
root            soft    nofile          65535
root            hard    nofile          65535
EOF
ulimit -n 65535
echo -e "${GRN}Лимиты применены. Текущий ulimit -n: $(ulimit -n) ${NC}"

# Создание директории сайта
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH"
# Генерируем сайт маскировку
bash -c "$(curl -L https://github.com/xVRVx/autoXRAY/raw/refs/heads/main/test/gen_page2.sh)" -- $WEB_PATH

# Установка Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Блок CERTBOT - START
if [ -f /etc/nginx/sites-available/default ]; then
CONFIG_PATH="/etc/nginx/sites-available/default"
echo -e "${GRN}Обнаружена стандартная сборка nginx. ${NC}"
elif [ -f /etc/nginx/conf.d/default.conf ]; then
CONFIG_PATH="/etc/nginx/conf.d/default.conf"
echo -e "${YEL}Обнаружена нестандартная сборка nginx. Предварительная настройка NGINX для CERTBOT ${NC}"
mkdir -p /var/www/html
cat <<EOF > "$CONFIG_PATH"
server {
listen 80 default_server;
server_name _;
location /.well-known/acme-challenge/ {
root /var/www/html;
allow all;
}
location / {
return 301 https://\$host\$request_uri;
}
}
EOF
systemctl reload nginx
else
echo -e "${RED}Не найден ни один default конфиг nginx${NC}"
exit 1
fi

mkdir -p /var/lib/xray/cert/
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem 2>/dev/null || true
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem 2>/dev/null || true
chmod 744 /var/lib/xray/cert/privkey.pem 2>/dev/null || true
chmod 744 /var/lib/xray/cert/fullchain.pem 2>/dev/null || true

certbot certonly --webroot -w /var/www/html \
-d $DOMAIN \
-m mail@$DOMAIN \
--agree-tos --non-interactive \
--deploy-hook "systemctl reload nginx; cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem; cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem; chmod 744 /var/lib/xray/cert/privkey.pem; chmod 744 /var/lib/xray/cert/fullchain.pem; systemctl restart xray"
RET=$?
if [ $RET -eq 0 ]; then
echo -e "${GRN}========================================\n✅  Команда certbot успешно выполнена\n✅  Сертификат https от letsencrypt ПОЛУЧЕН\n========================================${NC}"
else
echo -e "${RED}========================================\n❌  CERTBOT ЗАВЕРШИЛСЯ С ОШИБКОЙ\n❌  Сертификат https от letsencrypt НЕ ПОЛУЧЕН!\n❌  Смотрите выше логи процесса получения сертификата\n❌  Код возврата: $RET\n========================================${NC}"
exit 1
fi
# Блок CERTBOT - END

path_xhttp=$(openssl rand -base64 15 | tr -dc 'a-z0-9' | head -c 6)
path_subpage=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

bash -c "cat > $CONFIG_PATH" <<EOF
server {
server_name $DOMAIN;
listen unix:/dev/shm/nginx.sock ssl http2 proxy_protocol;
listen unix:/dev/shm/nginxTLS.sock proxy_protocol;
listen unix:/dev/shm/nginx_h2.sock http2 proxy_protocol;
set_real_ip_from unix:;
real_ip_header proxy_protocol;
root /var/www/$DOMAIN;
index index.php index.html;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!MD5;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;
ssl_certificate "/etc/letsencrypt/live/$DOMAIN/fullchain.pem";
ssl_certificate_key "/etc/letsencrypt/live/$DOMAIN/privkey.pem";
location ~ /\.ht { deny all; }
}
server {
listen 80;
server_name $DOMAIN;
location /.well-known/acme-challenge/ { root /var/www/html; }
location / { return 301 https://\$host\$request_uri; }
}
EOF
systemctl restart nginx
echo -e "${GRN}✅ Конфигурация nginx обновлена.${NC}"

SCRIPT_DIR=/usr/local/etc/xray

# Генерируем переменные
xray_uuid_vrv=$(xray uuid)
key_output=$(xray x25519)
xray_privateKey_vrv=$(echo "$key_output" | awk -F': ' '/PrivateKey/ {print $2}')
xray_publicKey_vrv=$(echo "$key_output" | awk -F': ' '/Password/ {print $2}')
xray_shortIds_vrv=$(openssl rand -hex 8)

# Установка WARP-cli
if ss -tuln | grep -q ":40000 "; then
echo -e "${GRN}WARP-cli (Socks5 на порту 40000) уже работает. Пропускаем.${NC}"
else
echo -e "${GRN}Установка WARP-cli (автоматически)...${NC}"
echo -e "1\n1\n40000" | bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) w
fi

export xray_uuid_vrv xray_privateKey_vrv xray_publicKey_vrv xray_shortIds_vrv DOMAIN path_subpage path_xhttp WEB_PATH

# Создаем JSON конфигурацию сервера
cat << 'EOF' | envsubst > "$SCRIPT_DIR/config.json"
{
"log": { "dnsLog": false, "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "none" },
"dns": {
"servers": ["https+local://8.8.4.4/dns-query", "https+local://8.8.8.8/dns-query", "https+local://1.1.1.1/dns-query", "localhost"],
"queryStrategy": "UseIPv4"
},
"inbounds": [
{
"tag": "vsREALITY443",
"port": 443,
"listen": "0.0.0.0",
"protocol": "vless",
"settings": {
"clients": [{ "flow": "xtls-rprx-vision", "id": "${xray_uuid_vrv}" }],
"decryption": "none",
"fallbacks": [{ "dest": "3333", "xver": 2 }]
},
"sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
"streamSettings": {
"network": "raw",
"security": "reality",
"realitySettings": {
"show": false, "xver": 2, "target": "/dev/shm/nginx.sock", "spiderX": "/",
"shortIds": ["${xray_shortIds_vrv}"], "privateKey": "${xray_privateKey_vrv}", "serverNames": ["$DOMAIN"],
"limitFallbackUpload": { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 0 },
"limitFallbackDownload": { "afterBytes": 5242880, "bytesPerSec": 262144, "burstBytesPerSec": 2097152 }
}
}
},
{
"tag": "vsXHTTP3333",
"port": 3333,
"listen": "127.0.0.1",
"protocol": "vless",
"settings": {
"clients": [{ "id": "${xray_uuid_vrv}" }],
"decryption": "none"
},
"sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
"streamSettings": {
"network": "xhttp",
"xhttpSettings": { "mode": "stream-one", "path": "/${path_xhttp}" },
"security": "none",
"sockopt": { "acceptProxyProtocol": true }
}
}
],
"outbounds": [
{ "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIPv4" } },
{ "tag": "block", "protocol": "blackhole" },
{ "tag": "warp", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } }
],
"routing": {
"domainStrategy": "IPIfNonMatch",
"rules": [
{ "ip": ["geoip:private"], "outboundTag": "block" },
{ "port": "25", "outboundTag": "block" },
{ "protocol": ["bittorrent"], "outboundTag": "block" },
{ "domain": ["geosite:category-ads", "geosite:win-spy", "geosite:private"], "outboundTag": "block" },
{ "outboundTag": "warp", "domain": ["ifconfig.me","checkip.amazonaws.com","pify.org","2ip.io","habr.com","geosite:category-ip-geo-detect","geosite:google-gemini","geosite:canva","geosite:openai","geosite:whatsapp","geosite:category-ru"] }
]
}
}
EOF

systemctl restart xray
echo -e "Перезапуск XRAY"

# Формирование ссылок
linkRTY1="vless://${xray_uuid_vrv}@$DOMAIN:443?security=reality&type=tcp&headerType=&path=&host=&flow=xtls-rprx-vision&sni=$DOMAIN&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&spx=%2F#vlessRAWrealityVISION-autoXRAY"
linkRTY2="vless://${xray_uuid_vrv}@$DOMAIN:443?security=reality&type=xhttp&headerType=&path=%2F$path_xhttp&host=&mode=stream-one&extra=%7B%22xmux%22%3A%7B%22cMaxReuseTimes%22%3A%221000-3000%22%2C%22maxConcurrency%22%3A%223-5%22%2C%22maxConnections%22%3A0%2C%22hKeepAlivePeriod%22%3A0%2C%22hMaxRequestTimes%22%3A%22400-700%22%2C%22hMaxReusableSecs%22%3A%221200-1800%22%7D%2C%22headers%22%3A%7B%7D%2C%22noGRPCHeader%22%3Afalse%2C%22xPaddingBytes%22%3A%22400-800%22%2C%22scMaxEachPostBytes%22%3A1500000%2C%22scMinPostsIntervalMs%22%3A20%2C%22scStreamUpServerSecs%22%3A%2260-240%22%7D&sni=$DOMAIN&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&spx=%2F#vlessXHTTPrealityEXTRA-autoXRAY"
configListLink="https://$DOMAIN/$path_subpage.html"

CONFIGS_ARRAY=(
"VLESS XHTTP REALITY EXTRA (для моста)|$linkRTY2"
"VLESS RAW REALITY VISION|$linkRTY1"
)

# --- ЗАПИСЬ HEAD (СТАТИКА) ---
cat > "$WEB_PATH/$path_subpage.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow"><title>autoXRAY configs</title>
<link rel="icon" type="image/svg+xml" href='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBCRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTIxIDJsLTIgMm0tNy42MSA3LjYxYTUuNSA1LjUgMCAxIDEtNy43NzggNy43NzggNS41IDUuNSAwIDAgMSA3Ljc3Ny03Ljc3N3ptMCAwTDE1LjUgNy41bTAgMGwzIDNMMjIgN2wtMy0zbS0zLjUgMy41TDE5IDQiLz48L3N2Zz4='>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
body{font-family:monospace;background:#121212;color:#e0e0e0;padding:10px;max-width:900px;margin:0 auto}h2{color:#c3e88d;border-top:2px solid #333;padding-top:20px;margin:15px 0 10px;font-size:18px}.config-row{background:#1e1e1e;border:1px solid #333;border-radius:6px;padding:5px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px}.config-label{background:#2c2c2c;color:#82aaff;padding:6px 10px;border-radius:4px;font-weight:700;font-size:13px;white-space:nowrap;min-width:140px;text-align:center}.config-code{flex:1;white-space:nowrap;overflow-x:auto;padding:8px;background:#121212;border-radius:4px;color:#c3e88d;font-size:12px;scrollbar-width:none}.config-code::-webkit-scrollbar{display:none}.btn-action{border:1px solid #555;padding:6px 12px;border-radius:4px;cursor:pointer;font-weight:700;font-size:12px;transition:all .2s;height:32px;display:flex;align-items:center;justify-content:center}.copy-btn{background:#333;color:#e0e0e0;min-width:60px}.copy-btn:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}.qr-btn{background:#333;color:#82aaff;border-color:#82aaff;min-width:40px}.qr-btn:hover{background:#82aaff;color:#121212}@media(max-width:600px){.config-label{width:100%;margin-bottom:2px}.config-code{min-width:100%;order:3}.btn-action{flex:1;order:2}}
</style>
<script>
function copyText(e,t){navigator.clipboard.writeText(document.getElementById(e).innerText).then(()=>{let o=t.innerText;t.innerText="OK",t.style.cssText="background:#c3e88d;color:#121212",setTimeout(()=>{t.innerText=o,t.style.cssText=""},1500)}).catch(e=>console.error(e))}function showQR(e){let t=document.getElementById(e).innerText,o=document.getElementById("qrModal"),n=document.getElementById("qrcode");n.innerHTML="",new QRCode(n,{text:t,width:256,height:256,colorDark:"#000000",colorLight:"#ffffff",correctLevel:QRCode.CorrectLevel.L}),o.style.display="flex"}function closeModal(){document.getElementById("qrModal").style.display="none"}window.onclick=function(e){e.target==document.getElementById("qrModal")&&closeModal()};
</script>
</head><body>
EOF

# --- ЗАПИСЬ BODY (ДИНАМИЧЕСКИЕ ДАННЫЕ) ---
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<h2>➡️ Конфиги (Reality на порту 443)</h2>
EOF

idx=1
for item in "${CONFIGS_ARRAY[@]}"; do
title="${item%%|*}"
link="${item#*|}"
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
<div class="config-label">$title</div>
<div class="config-code" id="c$idx">$link</div>
<button class="btn-action copy-btn" onclick="copyText('c$idx', this)">Copy</button>
<button class="btn-action qr-btn" onclick="showQR('c$idx')">QR</button>
</div>
EOF
((idx++))
done

cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div><a style="color:white;margin:40px auto 20px;display:block;text-align:center;" href="https://github.com/xVRVx/autoXRAY">https://github.com/xVRVx/autoXRAY</a></div>
<div id="qrModal" class="modal-overlay"><div class="modal-content"><div id="qrcode"></div><button class="close-modal-btn" onclick="closeModal()">Close</button></div></div>
</body></html>
EOF

# --- ФИНАЛЬНАЯ ПРОВЕРКА ---
echo -e "\n${YEL}=== Финальная проверка статусов ===${NC}"
if ss -nlt | grep -q ":40000\b"; then echo -e "WARP-cli: ${GRN}LISTENING${NC}"; else echo -e "WARP-cli: ${RED}NOT LISTENING${NC}"; echo "Подробнее: https://github.com/xVRVx/autoXRAY/blob/main/test/warp-readme.md"; fi
if systemctl is-active --quiet nginx; then echo -e "Nginx: ${GRN}RUNNING${NC}"; else echo -e "Nginx: ${RED}STOPPED/ERROR${NC}"; fi
if systemctl is-active --quiet xray; then echo -e "XRAY: ${GRN}RUNNING${NC}"; else echo -e "XRAY: ${RED}STOPPED/ERROR${NC}"; fi

echo -e "\n${YEL}VLESS XHTTP REALITY EXTRA (для моста) ${NC}\n$linkRTY2\n${YEL}VLESS RAW REALITY VISION ${NC}\n$linkRTY1\n${YEL}Ссылка на сохраненные конфиги ${NC}\n${GRN}$configListLink ${NC}\nСкопируйте конфиги в специализированное приложение:\n- iOS: Happ или v2RayTun или v2rayN\n- Android: Happ или v2RayTun или v2rayNG\n- Windows: конфиги Happ или winLoadXRAY или v2rayN\nдля vless v2RayTun или Throne\n${GRN}Поддержать автора: https://github.com/xVRVx/autoXRAY ${NC}\n"
