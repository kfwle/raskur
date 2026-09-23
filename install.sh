#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#   SING-BOX MINI INSTALLER
#   Только: AnyTLS, TUIC v5, Mieru (TCP+UDP), Juicity + Certbot (Let's Encrypt)
#   В конце — диплинки и всё.
#
#   Интерактивно:
#     curl -fsSL https://raw.githubusercontent.com/kfwle/raskur/main/install.sh | sudo bash
#   Без вопросов:
#     curl -fsSL .../install.sh | sudo bash -s -- --non-interactive --domain vpn.example.com --email admin@example.com
#     curl -fsSL .../install.sh | sudo DOMAIN=vpn.example.com EMAIL=admin@example.com bash
# ══════════════════════════════════════════════════════════════════════════════
set -e

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SINGBOX_VER="1.12.14"
MIERU_VER="3.12.0"
JUICY_VER="0.5.0"
INSTALL_DIR="/opt/singbox-mini"
CONFIG_DIR="/etc/singbox-mini"
LOG_FILE="/var/log/singbox-mini-install.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

[[ $EUID -ne 0 ]] && error "Запусти от root: sudo bash install.sh"
[ -f /etc/os-release ] && source /etc/os-release || error "Не найден /etc/os-release"
[[ ! "$ID" =~ ^(ubuntu|debian)$ ]] && error "Поддерживаются только Ubuntu/Debian. У тебя: $ID"

NON_INTERACTIVE=0
SKIP_UFW="${SKIP_UFW:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --domain=*) DOMAIN="${1#*=}"; shift ;;
        --email) EMAIL="${2:-}"; shift 2 ;;
        --email=*) EMAIL="${1#*=}"; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --no-ufw|--skip-firewall) SKIP_UFW=1; shift ;;
        -h|--help)
            echo "Использование: sudo bash install.sh [--domain d] [--email e] [--non-interactive] [--no-ufw]"; exit 0 ;;
        *) error "Неизвестный аргумент: $1" ;;
    esac
done

normalize_domain() { local d="$1"; d="$(echo "$d" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"; d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; echo "$d"; }
normalize_email() { echo "$1" | tr -d '[:space:]'; }
valid_domain() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; }
valid_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

prompt_read() {
    local prompt_text="$1" __var="$2" __input=""
    if [[ -t 0 ]]; then printf '%s' "$prompt_text" >&2; read -r __input || true
    elif [[ -e /dev/tty ]]; then printf '%s' "$prompt_text" > /dev/tty; read -r __input </dev/tty || true
    else error "Нет терминала. Передай DOMAIN=... EMAIL=... bash install.sh"; fi
    printf -v "$__var" '%s' "$__input"
}

ask_domain() {
    local input
    while true; do
        prompt_read "Введи домен для сертификата (например vpn.example.com): " input
        input="$(normalize_domain "$input")"
        [[ -z "$input" ]] && { echo "Домен не может быть пустым."; continue; }
        valid_domain "$input" || { echo "Не похоже на домен: $input"; continue; }
        DOMAIN="$input"; break
    done
}
ask_email() {
    local input
    while true; do
        prompt_read "Введи email для Let's Encrypt (например admin@gmail.com): " input
        input="$(normalize_email "$input")"
        [[ -z "$input" ]] && { echo "Email не может быть пустым."; continue; }
        valid_email "$input" || { echo "Не похоже на email: $input"; continue; }
        EMAIL="$input"; break
    done
}

DOMAIN="$(normalize_domain "$DOMAIN")"
EMAIL="$(normalize_email "$EMAIL")"
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    valid_domain "$DOMAIN" || error "Нужен валидный --domain (получено: '$DOMAIN')"
    valid_email "$EMAIL" || error "Нужен валидный --email (получено: '$EMAIL')"
else
    [[ -n "$DOMAIN" && ! "$(valid_domain "$DOMAIN"; echo $?)" == "0" ]] && DOMAIN=""
    [[ -n "$EMAIL" && ! "$(valid_email "$EMAIL"; echo $?)" == "0" ]] && EMAIL=""
    [[ -z "$DOMAIN" ]] && ask_domain
    [[ -z "$EMAIL" ]] && ask_email
fi

echo -e "${GREEN}"
cat << 'EOF'
  ____  _             ____
 / ___|(_)_ __   __ _| __ )  ___  _ __ ___
 \___ \| | '_ \ / _` |  _ \ / _ \| '__/ _ \
  ___) | | | | | (_| | |_) | (_) | | | (_) |
 |____/|_|_| |_|\__, |____/ \___/|_|  \___/
                  |_|           MINI: AnyTLS+TUIC+Mieru+Juicity
EOF
echo -e "${NC}"
log "🚀 Установка на ${PRETTY_NAME} | домен: ${DOMAIN} | email: ${EMAIL}"

PUBLIC_IP="$(curl -s4 --max-time 10 ifconfig.me 2>/dev/null || curl -s4 --max-time 10 icanhazip.com 2>/dev/null || echo "")"
PUBLIC_IP="$(echo "$PUBLIC_IP" | tr -d '[:space:]')"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Не удалось определить внешний IPv4."

declare -a USED_PORTS=()
port_taken() {
    local p="$1" x
    for x in "${USED_PORTS[@]}"; do [[ "$x" == "$p" ]] && return 0; done
    ss -tuln 2>/dev/null | grep -qE ":${p}([^0-9]|$)" && return 0
    return 1
}
find_free_port() {
    local port tries=0
    while (( tries++ < 300 )); do
        port=$(( (RANDOM % 10000) + 49000 ))
        port_taken "$port" || { echo "$port"; return; }
    done
    echo "ERROR_NO_FREE_PORT"; return 1
}
find_free_range() {
    local base tries=0
    while (( tries++ < 300 )); do
        base=$(( (RANDOM % 9000) + 49000 ))
        if ! port_taken "$base" && ! port_taken "$((base+1))"; then
            echo "${base}-$((base+1))"; return
        fi
    done
    echo "ERROR_NO_FREE_RANGE"; return 1
}
resolve_domain_ipv4() {
    local d="$1" ip=""
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short A "$d" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    elif command -v getent >/dev/null 2>&1; then
        ip=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    echo "$ip" | tr -d '[:space:]'
}
gen_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 24; echo; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }

try_dl() {
    local url="$1" out="$2"
    [[ -n "$url" && -n "$out" ]] || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$out" "$url" 2>/dev/null && [[ -s "$out" ]] && return 0
        rm -f "$out"
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=15 -O "$out" "$url" >>"$LOG_FILE" 2>&1 && [[ -s "$out" ]] && return 0
        rm -f "$out"
    fi
    return 1
}
dl() { try_dl "$1" "$2" || error "Не удалось скачать $1"; }

# ── Зависимости ──
log "📦 Ставим зависимости..."
apt-get update -y >> "$LOG_FILE" 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget jq openssl unzip iptables \
    ufw dnsutils certbot iproute2 >> "$LOG_FILE" 2>&1 || error "Не удалось установить пакеты"

DOMAIN_IP="$(resolve_domain_ipv4 "$DOMAIN")"
[[ -n "$DOMAIN_IP" ]] || error "Домен $DOMAIN не резолвится. Настрой A-запись на $PUBLIC_IP."
[[ "$DOMAIN_IP" == "$PUBLIC_IP" ]] || error "Домен $DOMAIN → $DOMAIN_IP, а сервер $PUBLIC_IP. Поправь DNS."
log "✅ DNS ок: $DOMAIN → $PUBLIC_IP"

# ── Порты ──
log "🔍 Ищем свободные порты..."
ANYTLS_PORT=$(find_free_port) || error "Нет свободного порта (anytls)"
USED_PORTS+=("$ANYTLS_PORT")
TUIC_PORT=$(find_free_port) || error "Нет свободного порта (tuic)"
USED_PORTS+=("$TUIC_PORT")
JUICITY_PORT=$(find_free_port) || error "Нет свободного порта (juicity)"
USED_PORTS+=("$JUICITY_PORT")
MIERU_RANGE=$(find_free_range) || error "Нет свободного диапазона (mieru)"
MIERU_PORT_START=${MIERU_RANGE%-*}
USED_PORTS+=("$MIERU_PORT_START" "$((MIERU_PORT_START+1))" "80" "443")

ANYTLS_PASS=$(gen_password)
TUIC_UUID=$(gen_uuid); TUIC_PASS=$(gen_password)
JUICITY_UUID=$(gen_uuid); JUICITY_PASS=$(gen_password)
MIERU_PASS=$(gen_password)

# ── Certbot ──
log "🔒 Получаем сертификат Let's Encrypt для $DOMAIN..."
NGINX_WAS=0; APACHE_WAS=0
systemctl is-active --quiet nginx 2>/dev/null && NGINX_WAS=1
systemctl is-active --quiet apache2 2>/dev/null && APACHE_WAS=1
systemctl stop nginx apache2 2>/dev/null || true
certbot certonly --standalone --domain "$DOMAIN" --email "$EMAIL" \
    --agree-tos --no-eff-email --non-interactive --keep-until-expiring \
    --preferred-challenges http >> "$LOG_FILE" 2>&1 || error "Certbot не получил сертификат. Порт 80 свободен? DNS ок?"
CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
[[ "$NGINX_WAS" == "1" ]] && systemctl restart nginx 2>/dev/null || true
[[ "$APACHE_WAS" == "1" ]] && systemctl restart apache2 2>/dev/null || true
log "✅ Сертификат: $CERT_PATH"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/singbox-mini-restart.sh << EOF
#!/bin/bash
systemctl restart sing-box mita juicity 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/singbox-mini-restart.sh
cat > /etc/letsencrypt/renewal-hooks/pre/stop-web.sh << 'HOOK'
#!/bin/bash
systemctl stop nginx apache2 2>/dev/null || true
HOOK
cat > /etc/letsencrypt/renewal-hooks/post/start-web.sh << 'HOOK'
#!/bin/bash
systemctl start nginx 2>/dev/null || true
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-web.sh /etc/letsencrypt/renewal-hooks/post/start-web.sh

# ── sing-box (AnyTLS + TUIC) ──
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" /var/log/sing-box
for s in sing-box mita juicity; do systemctl stop "$s" 2>/dev/null || true; done

ARCH=$(uname -m)
SB_ARCH=""
[[ "$ARCH" == "x86_64" ]] && SB_ARCH="amd64"
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && SB_ARCH="arm64"
[[ -n "$SB_ARCH" ]] || error "Архитектура $ARCH не поддерживается"

log "⬇️  sing-box v${SINGBOX_VER}..."
dl "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-${SB_ARCH}.tar.gz" /tmp/singbox.tar.gz
tar -xzf /tmp/singbox.tar.gz -C /tmp
cp "/tmp/sing-box-${SINGBOX_VER}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*

cat > "$CONFIG_DIR/sing-box.json" << EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "cloudflare", "type": "https", "server": "1.1.1.1" },
      { "tag": "local", "type": "local" }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [{ "name": "user", "password": "${ANYTLS_PASS}" }],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_PATH/fullchain.pem",
        "key_path": "$CERT_PATH/privkey.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [{ "uuid": "${TUIC_UUID}", "password": "${TUIC_PASS}" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_PATH/fullchain.pem",
        "key_path": "$CERT_PATH/privkey.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
    ],
    "final": "direct"
  }
}
EOF

cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-Box Mini (AnyTLS + TUIC)
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_DIR/sing-box.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# ── Mita (Mieru server) ──
log "📦 Mita v${MIERU_VER}..."
if [[ "$SB_ARCH" == "amd64" ]]; then MITA_PKG="mita_${MIERU_VER}_amd64.deb"; else MITA_PKG="mita_${MIERU_VER}_arm64.deb"; fi
dl "https://github.com/enfein/mieru/releases/download/v${MIERU_VER}/${MITA_PKG}" /tmp/mita.deb
DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/mita.deb >> "$LOG_FILE" 2>&1 || error "mita.deb не установился"
rm -f /tmp/mita.deb
rm -f /etc/systemd/system/mieru.service

mkdir -p /etc/mieru
cat > /etc/mieru/server_config.json << EOF
{
  "portBindings": [
    { "port": ${MIERU_PORT_START}, "protocol": "TCP" },
    { "port": ${MIERU_PORT_START}, "protocol": "UDP" },
    { "port": $((${MIERU_PORT_START}+1)), "protocol": "TCP" },
    { "port": $((${MIERU_PORT_START}+1)), "protocol": "UDP" }
  ],
  "users": [{ "name": "user", "password": "${MIERU_PASS}" }],
  "loggingLevel": "INFO",
  "mtu": 1400
}
EOF

# ── Juicity ──
log "⚡ Juicity v${JUICY_VER}..."
if [[ "$SB_ARCH" == "amd64" ]]; then JUICY_ARCH="x86_64"; else JUICY_ARCH="arm64"; fi
dl "https://github.com/juicity/juicity/releases/download/v${JUICY_VER}/juicity-linux-${JUICY_ARCH}.zip" /tmp/juicity.zip
rm -rf /tmp/juicity-extract && mkdir -p /tmp/juicity-extract
unzip -o -q /tmp/juicity.zip -d /tmp/juicity-extract >> "$LOG_FILE" 2>&1 || error "juicity.zip не распаковался"
JUICY_BIN="$(find /tmp/juicity-extract -type f -name 'juicity-server' | head -1)"
[[ -n "$JUICY_BIN" ]] || error "juicity-server не найден в архиве"
cp "$JUICY_BIN" /usr/local/bin/juicity-server && chmod +x /usr/local/bin/juicity-server
rm -rf /tmp/juicity.zip /tmp/juicity-extract

mkdir -p /etc/juicity
cat > /etc/juicity/server.json << EOF
{
  "listen": "0.0.0.0:${JUICITY_PORT}",
  "users": { "${JUICITY_UUID}": "${JUICITY_PASS}" },
  "certificate": "$CERT_PATH/fullchain.pem",
  "private_key": "$CERT_PATH/privkey.pem",
  "congestion_control": "bbr",
  "log_level": "info"
}
EOF

cat > /etc/systemd/system/juicity.service << EOF
[Unit]
Description=Juicity Server
After=network.target

[Service]
ExecStart=/usr/local/bin/juicity-server run -c /etc/juicity/server.json --disable-timestamp
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# ── Запуск ──
log "🔍 Валидируем конфиг sing-box..."
sing-box check -c "$CONFIG_DIR/sing-box.json" 2>&1 | tee -a "$LOG_FILE" || error "sing-box.json невалиден"
jq . /etc/juicity/server.json >/dev/null || error "server.json Juicity невалиден"

systemctl daemon-reload
systemctl enable --now sing-box juicity >> "$LOG_FILE" 2>&1 || error "sing-box/juicity не стартовали"
systemctl enable --now mita >> "$LOG_FILE" 2>&1 || true
for i in $(seq 1 15); do
    [[ -S /var/run/mita.sock ]] && break
    sleep 1
done
[[ -S /var/run/mita.sock ]] || error "mita socket не появился — смотри journalctl -u mita"
mita apply config /etc/mieru/server_config.json 2>&1 | tee -a "$LOG_FILE" || error "mita не принял конфиг"
mita stop >> "$LOG_FILE" 2>&1 || true
mita start 2>&1 | tee -a "$LOG_FILE" || error "mita не стартует"

# ── UFW ──
if [[ "$SKIP_UFW" == "1" ]]; then
    log "⏭️  UFW пропущен. Открой вручную: TCP ${ANYTLS_PORT} ${MIERU_RANGE} / UDP ${TUIC_PORT} ${JUICITY_PORT} ${MIERU_RANGE}"
else
    log "🔥 Настраиваем UFW..."
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
    ufw --force reset >> "$LOG_FILE" 2>&1
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1
    ufw allow "$SSH_PORT"/tcp comment "SSH" >> "$LOG_FILE" 2>&1
    ufw allow 80/tcp comment "Certbot" >> "$LOG_FILE" 2>&1
    ufw allow ${ANYTLS_PORT}/tcp comment "AnyTLS" >> "$LOG_FILE" 2>&1
    ufw allow ${TUIC_PORT}/udp comment "TUIC" >> "$LOG_FILE" 2>&1
    ufw allow ${JUICITY_PORT}/udp comment "Juicity" >> "$LOG_FILE" 2>&1
    ufw allow ${MIERU_PORT_START}:$((${MIERU_PORT_START}+1))/tcp comment "Mieru TCP" >> "$LOG_FILE" 2>&1
    ufw allow ${MIERU_PORT_START}:$((${MIERU_PORT_START}+1))/udp comment "Mieru UDP" >> "$LOG_FILE" 2>&1
    ufw --force enable >> "$LOG_FILE" 2>&1
fi

# ── Проверка ──
sleep 2
FAILED=()
for s in sing-box mita juicity; do
    if systemctl is-active --quiet "$s"; then log "   ✅ $s"; else
        log "   ❌ $s"; FAILED+=("$s")
        journalctl -u "$s" -n 10 --no-pager 2>&1 | tee -a "$LOG_FILE"
    fi
done

# ── Диплинки ──
ANYTLS_LINK="anytls://${ANYTLS_PASS}@${DOMAIN}:${ANYTLS_PORT}?sni=${DOMAIN}#mini-anytls"
TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASS}@${DOMAIN}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}#mini-tuic"
MIERU_LINK="mierus://user:${MIERU_PASS}@${DOMAIN}:${MIERU_PORT_START}?profile=default&port=${MIERU_PORT_START}&protocol=TCP#mini-mieru"
JUICITY_LINK="juicity://${JUICITY_UUID}:${JUICITY_PASS}@${DOMAIN}:${JUICITY_PORT}?sni=${DOMAIN}#mini-juicity"

cat > "$INSTALL_DIR/credentials.txt" << EOF
🌐 Домен: ${DOMAIN}
🌍 IP: ${PUBLIC_IP}

ДИПЛИНКИ:
${ANYTLS_LINK}
${TUIC_LINK}
${MIERU_LINK}
${JUICITY_LINK}

Порты: AnyTLS=${ANYTLS_PORT}/tcp  TUIC=${TUIC_PORT}/udp  Juicity=${JUICITY_PORT}/udp  Mieru=${MIERU_RANGE}/tcp+udp
Сертификат: ${CERT_PATH} (автообновление настроено)
EOF
chmod 600 "$INSTALL_DIR/credentials.txt"

echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "${RED}⚠️  Не стартовали: ${FAILED[*]} — смотри лог $LOG_FILE${NC}"
else
    echo -e "${GREEN}✅ ГОТОВО${NC}"
fi
echo ""
echo -e "${CYAN}🔗 AnyTLS:${NC}  ${ANYTLS_LINK}"
echo -e "${CYAN}🔗 TUIC:${NC}    ${TUIC_LINK}"
echo -e "${CYAN}🔗 Mieru:${NC}   ${MIERU_LINK}"
echo -e "${CYAN}🔗 Juicity:${NC} ${JUICITY_LINK}"
echo ""
echo -e "${YELLOW}📄 Креды:${NC} $INSTALL_DIR/credentials.txt"
