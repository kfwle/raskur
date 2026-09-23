#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#   SING-BOX MINI UNINSTALLER
#   Удаляет то, что ставит install.sh: sing-box (AnyTLS+TUIC), Mita, Juicity.
#
#   sudo bash uninstall.sh [--yes] [--delete-certs] [--keep-ufw]
#   curl -fsSL .../uninstall.sh | sudo bash -s -- --yes
#
#   Флаги:
#     --yes / -y        не спрашивать подтверждений
#     --delete-certs    УДАЛИТЬ сертификат Let's Encrypt (по умолчанию сохраняется)
#     --keep-ufw        фаервол вообще не трогать
# ══════════════════════════════════════════════════════════════════════════════
set -e

YES=0
DELETE_CERTS=0
SKIP_UFW="${SKIP_UFW:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) YES=1; shift ;;
        --delete-certs) DELETE_CERTS=1; shift ;;
        --keep-ufw|--no-ufw) SKIP_UFW=1; shift ;;
        -h|--help) echo "sudo bash uninstall.sh [--yes] [--delete-certs] [--keep-ufw]"; exit 0 ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo "[ERROR] Запусти от root: sudo bash uninstall.sh"; exit 1; }

INSTALL_DIR="/opt/singbox-mini"
CONFIG_DIR="/etc/singbox-mini"

prompt_read() {
    local prompt_text="$1" __var="$2" __input=""
    if [[ -t 0 ]]; then printf '%s' "$prompt_text" >&2; read -r __input || true
    elif [[ -e /dev/tty ]]; then printf '%s' "$prompt_text" > /dev/tty; read -r __input </dev/tty || true
    else echo "[ERROR] Нет терминала. Добавь --yes." >&2; exit 1; fi
    printf -v "$__var" '%s' "$__input"
}

SERVICES=(sing-box mita juicity)
BINARIES=(/usr/local/bin/sing-box /usr/bin/mita /usr/local/bin/juicity-server)
DIRS=("$INSTALL_DIR" "$CONFIG_DIR" /etc/mieru /etc/juicity /var/log/sing-box)
HOOK=/etc/letsencrypt/renewal-hooks/deploy/singbox-mini-restart.sh

echo "Будет удалено:"
echo "  • сервисы: ${SERVICES[*]}"
echo "  • бинарники: ${BINARIES[*]}"
echo "  • каталоги: ${DIRS[*]}"
if [[ "$SKIP_UFW" == "1" ]]; then echo "  • UFW: НЕ ТРОГАЕМ (флаг --keep-ufw)"
else echo "  • UFW-правила портов сервисов (SSH и 80 не трогаем)"; fi
[[ "$DELETE_CERTS" -eq 1 ]] && echo "  • сертификат Let's Encrypt (по флагу)"

if [[ "$YES" -eq 0 ]]; then
    prompt_read "Удалить всё перечисленное? [y/N]: " _confirm
    [[ "$_confirm" =~ ^[yYдД] ]] || { echo "Отменено."; exit 0; }
fi

# ── Определяем домен и порты ДО удаления конфигов ──
DOMAIN_DETECTED=""
PORTS_DETECTED=""
if command -v python3 >/dev/null 2>&1; then
    read -r DOMAIN_DETECTED PORTS_DETECTED <<< "$(python3 - <<'PYEOF' 2>/dev/null || echo ' '
import json, re
domain = ''
ports = set()
try:
    for ib in json.load(open('/etc/singbox-mini/sing-box.json')).get('inbounds', []):
        p = ib.get('listen_port')
        if p: ports.add(int(p))
except Exception:
    pass
try:
    for b in json.load(open('/etc/mieru/server_config.json')).get('portBindings', []):
        p = b.get('port')
        if p: ports.add(int(p))
except Exception:
    pass
try:
    j = json.load(open('/etc/juicity/server.json'))
    p = str(j.get('listen', '')).split(':')[-1]
    if p.isdigit(): ports.add(int(p))
except Exception:
    pass
try:
    m = re.search(r'certificate":\s*"[^"]*live/([^/"]+)/', open('/etc/juicity/server.json').read())
    if m: domain = m.group(1)
except Exception:
    pass
print(domain, ' '.join(str(p) for p in sorted(ports)))
PYEOF
)"
fi
echo "  Домен: ${DOMAIN_DETECTED:-не определён}"
[[ "$SKIP_UFW" != "1" ]] && echo "  Порты (чистим в UFW): ${PORTS_DETECTED:-?}"

# ── Сервисы ──
echo "⏹  Останавливаю сервисы..."
for s in "${SERVICES[@]}"; do systemctl disable --now "$s" 2>/dev/null || true; done

echo "🗑  Удаляю systemd-юниты..."
for s in "${SERVICES[@]}"; do rm -f "/etc/systemd/system/$s.service"; done
rm -f /etc/systemd/system/mieru.service
systemctl daemon-reload 2>/dev/null || true

echo "🗑  Удаляю бинарники..."
for b in "${BINARIES[@]}"; do rm -f "$b"; done
if dpkg -s mita >/dev/null 2>&1; then
    apt-get purge -y mita >>/dev/null 2>&1 || dpkg --purge mita >>/dev/null 2>&1 || true
fi

echo "🗑  Удаляю конфиги..."
for d in "${DIRS[@]}"; do rm -rf "$d"; done
rm -f "$HOOK" /etc/letsencrypt/renewal-hooks/pre/stop-web.sh /etc/letsencrypt/renewal-hooks/post/start-web.sh
rm -f /var/log/singbox-mini-install.log

# ── UFW ──
if [[ "$SKIP_UFW" == "1" ]]; then
    echo "⏭️  UFW пропущен (флаг --keep-ufw)."
elif command -v ufw >/dev/null 2>&1; then
    echo "🔥 Чищу UFW-правила..."
    for p in $PORTS_DETECTED; do
        ufw delete allow "$p"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$p"/udp >/dev/null 2>&1 || true
    done
    set -- $PORTS_DETECTED
    if [[ $# -ge 2 ]]; then
        prev=""
        for p in "$@"; do
            if [[ -n "$prev" && "$p" -eq "$((prev+1))" ]]; then
                ufw delete allow "$prev:$p"/tcp >/dev/null 2>&1 || true
                ufw delete allow "$prev:$p"/udp >/dev/null 2>&1 || true
            fi
            prev="$p"
        done
    fi
fi

# ── Сертификат ──
if [[ "$DELETE_CERTS" -eq 1 ]]; then
    if [[ -n "$DOMAIN_DETECTED" && -d "/etc/letsencrypt/live/$DOMAIN_DETECTED" ]]; then
        echo "🔒 Удаляю сертификат $DOMAIN_DETECTED..."
        certbot delete --cert-name "$DOMAIN_DETECTED" --non-interactive 2>/dev/null \
            || rm -rf "/etc/letsencrypt/live/$DOMAIN_DETECTED" "/etc/letsencrypt/archive/$DOMAIN_DETECTED" "/etc/letsencrypt/renewal/$DOMAIN_DETECTED.conf"
    else
        echo "  Сертификат не найден. Проверь: certbot certificates"
    fi
else
    echo "  Сертификаты в /etc/letsencrypt оставлены (флаг --delete-certs удалит)."
fi

echo ""
echo "✅ Готово. Удалены сервисы, бинарники, конфиги$([[ "$SKIP_UFW" == "1" ]] && echo " (UFW не тронут)" || echo " и UFW-правила портов")."
echo "   Правила SSH и порта 80 не тронуты. Проверь: ufw status"
