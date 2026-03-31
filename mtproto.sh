#!/usr/bin/env bash
set -euo pipefail

# Парсинг параметров
TYPE=ee
while [[ $# -gt 0 ]]; do
    case $1 in
        --dd-mode)
            TYPE=dd
            shift
            ;;
        -*)
            echo "Неизвестная опция: $1"
            usage
            ;;
        *)
            break
            ;;
    esac
done

PORT="443"
WORKERS="1"

INSTALL_DIR="/opt/MTProxy"
CONF_DIR="/etc/mtproxy"
STATE_DIR="/var/lib/mtproxy"
BIN="/usr/local/bin/mtproto-proxy"
DEFAULTS_FILE="/etc/default/mtproxy"
SERVICE_FILE="/etc/systemd/system/mtproxy.service"
UPDATE_SCRIPT="/usr/local/sbin/mtproxy-update-config"
UPDATE_SERVICE="/etc/systemd/system/mtproxy-update.service"
UPDATE_TIMER="/etc/systemd/system/mtproxy-update.timer"

DOMAIN_EE=""
SECRET_EE=""
ExecStart_EE=""

# для ee режима выбираем случайный домен c поддержкой TLS v1.3
list="thunderbird.net
netlify.app
ckeditor.com
home.cern
mirror.debianforum.de
hub.docker.com
imdb.com
mediamarkt.de
xfinity.com
pinterest.com
max.ru
onlinetrade.ru
chipdip.ru
habr.com
auto.ru
kinopoisk.ru
rambler.ru"

echo "[1/10] Проверяю, что порт ${PORT} свободен"
if ss -ltn "( sport = :${PORT} )" | grep -q ":${PORT}"; then
echo "ОШИБКА: порт ${PORT} уже занят"
ss -ltnp | grep ":${PORT}" || true
exit 1
fi

echo "[2/10] Ставлю пакеты"
apt update
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y git curl xxd openssl ca-certificates build-essential libssl-dev zlib1g-dev

echo "[3/10] Создаю системного пользователя mtproxy"
if ! id mtproxy >/dev/null 2>&1; then
useradd --system --home "${STATE_DIR}" --create-home --shell /usr/sbin/nologin mtproxy
fi

echo "[4/10] Качаю исходники"
rm -rf "${INSTALL_DIR}"
git clone https://github.com/TelegramMessenger/MTProxy "${INSTALL_DIR}"

echo "[5/10] Собираю MTProxy"
make -C "${INSTALL_DIR}"
install -m 0755 "${INSTALL_DIR}/objs/bin/mtproto-proxy" "${BIN}"

echo "[6/10] Готовлю каталоги и конфиги"
install -d -m 0750 -o root -g mtproxy "${CONF_DIR}"
install -d -m 0750 -o mtproxy -g mtproxy "${STATE_DIR}"

if [ "$TYPE" = "ee" ]; then
	# Выбираем случайный домен c поддержкой TLS v1.3
	DOMAIN_EE=`echo "$list" | shuf -n1 | xargs`

	echo "Режим прокси: '${TYPE}' используем домен ${DOMAIN_EE}"
	
	SECRET_EE=`echo -n "${DOMAIN_EE}" | xxd -ps`
	ExecStart_EE="-D ${DOMAIN_EE}"
	printf '%s\n' "${SECRET_EE}" > "${CONF_DIR}/user-secret-ee"
	printf '%s\n' "${DOMAIN_EE}" > "${CONF_DIR}/domain-ee"
fi

curl -fsSL https://core.telegram.org/getProxySecret -o "${CONF_DIR}/proxy-secret"
curl -fsSL https://core.telegram.org/getProxyConfig -o "${CONF_DIR}/proxy-multi.conf"

SECRET="$(head -c 16 /dev/urandom | xxd -ps)"
printf '%s\n' "${SECRET}" > "${CONF_DIR}/user-secret"

chown root:mtproxy "${CONF_DIR}/proxy-secret" "${CONF_DIR}/proxy-multi.conf" "${CONF_DIR}/user-secret"
chmod 0640 "${CONF_DIR}/proxy-secret" "${CONF_DIR}/proxy-multi.conf" "${CONF_DIR}/user-secret"

echo "[7/10] Пишу настройки сервиса"
cat > "${DEFAULTS_FILE}" <<CFG
PORT=${PORT}
WORKERS=${WORKERS}
CFG

cat > "${SERVICE_FILE}" <<UNIT
[Unit]
Description=Telegram MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/mtproxy
ExecStart=/bin/sh -lc '/usr/local/bin/mtproto-proxy $ExecStart_EE -u mtproxy -p 8888 -H "$PORT" -S "$(cat /etc/mtproxy/user-secret)" --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M "$WORKERS"'
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

echo "[8/10] Добавляю ежедневное обновление proxy-multi.conf"
cat > "${UPDATE_SCRIPT}" <<'UPD'
#!/bin/sh
set -eu

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL https://core.telegram.org/getProxyConfig -o "$TMP"
install -o root -g mtproxy -m 0640 "$TMP" /etc/mtproxy/proxy-multi.conf
systemctl try-restart mtproxy.service
UPD

chmod 0755 "${UPDATE_SCRIPT}"

cat > "${UPDATE_SERVICE}" <<'USVC'
[Unit]
Description=Refresh Telegram MTProxy config

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mtproxy-update-config
USVC

cat > "${UPDATE_TIMER}" <<'UTMR'
[Unit]
Description=Daily refresh for Telegram MTProxy config

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UTMR

echo "[9/10] Включаю сервисы"
systemctl daemon-reload
systemctl enable --now mtproxy.service
systemctl enable --now mtproxy-update.timer

echo "[10/10] Готовлю ссылки подключения"
PUBLIC_IP="$(curl -4fsSL https://api.ipify.org || true)"
if [ -z "${PUBLIC_IP}" ]; then
PUBLIC_IP="$(hostname -I | awk '{print $1}')"
fi

if [ "$TYPE" = "ee" ]; then
CLIENT_SECRET="ee${SECRET}${SECRET_EE}"
echo "Режим прокси: '${TYPE}' используем домен ${DOMAIN_EE}"
else
CLIENT_SECRET="dd${SECRET}"
fi

echo
echo "========== ГОТОВО =========="
echo "Статус сервиса:"
systemctl --no-pager --full status mtproxy.service || true
echo
echo "Клиентский secret:"
echo "${SECRET}"
echo
echo "Ссылка tg://"
echo "tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
echo "tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}" > "${CONF_DIR}/tg-link"
echo
echo "Ссылка https://t.me/proxy"
echo "https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
echo
echo "Локальная статистика:"
echo "curl -s http://127.0.0.1:8888/stats"
