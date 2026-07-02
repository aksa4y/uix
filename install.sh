#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# === ВАЖНО: Ссылки на ФОРК akса4y/ui ===
REPO_OWNER="aksa4y"
REPO_NAME="ui"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

# проверка root
[[ $EUID -ne 0 ]] && echo -e "${red}Критическая ошибка: ${plain} Запустите скрипт с правами root (sudo) \n " && exit 1

# Проверка ОС
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Не удалось определить ОС, свяжитесь с автором!" >&2
    exit 1
fi
echo "ОС: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Неподдерживаемая архитектура процессора! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Архитектура: $(arch)"

# Неинтерактивный режим
if [[ "${XUI_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    NONINTERACTIVE=1
else
    NONINTERACTIVE=0
fi
export NONINTERACTIVE

# Простые помощники
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# acme.sh по умолчанию привязывается к IPv4; --listen-v6 делает его
# только IPv6, что ломает HTTP-01 валидацию когда A запись домена указывает
# на IPv4 этого хоста (#4994). Принудительно используем IPv6 только когда
# у хоста вообще нет глобального IPv4 адреса.
acme_listen_flag() {
    if ip -4 addr show scope global 2> /dev/null | grep -q "inet "; then
        echo ""
    else
        echo "--listen-v6"
    fi
}

# Помощники для портов
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y cronie curl tar tzdata socat ca-certificates openssl
            else
                dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm cronie curl tar tzdata socat ca-certificates openssl
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y cron curl tar timezone socat ca-certificates openssl
            ;;
        alpine)
            apk update && apk add dcron curl tar tzdata socat ca-certificates openssl
            ;;
        *)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

# prompt_or_default VARNAME "текст запроса" "значение по умолчанию" [ENV_NAME]
# Интерактивный режим: читает в VARNAME. Неинтерактивный: VARNAME = ${ENV_NAME:-default}.
# ENV_NAME по умолчанию совпадает с VARNAME когда не указан.
prompt_or_default() {
    local __var="$1" __prompt="$2" __default="$3" __env="${4:-$1}"
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        printf -v "$__var" '%s' "${!__env:-$__default}"
    else
        # shellcheck disable=SC2229
        read -rp "$__prompt" "$__var"
    fi
}

# write_install_result <user> <pass> <port> <webpath> <scheme> <host> <token> <dbtype>
# Сохраняет разбираемый, доступный только root файл с учётными данными для cloud-init/MOTD.
write_install_result() {
    local u="$1" p="$2" port="$3" wbp="$4" scheme="$5" host="$6" token="$7" dbtype="$8"
    local result_file="/etc/x-ui/install-result.env"
    local url_host="${host:-SERVER_IP_UNKNOWN}"
    install -d -m 755 /etc/x-ui 2> /dev/null
    local prev_umask
    prev_umask=$(umask)
    umask 077
    if ! {
        printf 'XUI_USERNAME=%q\n' "$u"
        printf 'XUI_PASSWORD=%q\n' "$p"
        printf 'XUI_PANEL_PORT=%q\n' "$port"
        printf 'XUI_WEB_BASE_PATH=%q\n' "$wbp"
        printf 'XUI_ACCESS_URL=%q\n' "${scheme}://${url_host}:${port}/${wbp}"
        printf 'XUI_API_TOKEN=%q\n' "$token"
        printf 'XUI_DB_TYPE=%q\n' "$dbtype"
    } > "$result_file"; then
        umask "$prev_umask"
        echo -e "${yellow}Предупреждение: не удалось записать ${result_file}.${plain}" >&2
        return 1
    fi
    umask "$prev_umask"
    chmod 600 "$result_file" 2> /dev/null
    chown root:root "$result_file" 2> /dev/null || true
    echo -e "${green}Результаты установки записаны в ${result_file} (режим 600).${plain}"
}

install_postgres_local() {
    local pg_user pg_pass
    pg_pass=$(gen_random_string 24)
    local pg_db="xui"
    local pg_host="127.0.0.1"
    local pg_port="5432"

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib >&2 || return 1
            else
                dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            fi
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        arch | manjaro | parch)
            pacman -Syu --noconfirm postgresql >&2 || return 1
            if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
                sudo -u postgres initdb -D /var/lib/postgres/data >&2 || return 1
            fi
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql-server postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
                install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data >&2 || return 1
                su - postgres -c "initdb -D /var/lib/pgsql/data" >&2 || return 1
            fi
            ;;
        alpine)
            apk add --no-cache postgresql postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/postgresql/data/PG_VERSION ]]; then
                /etc/init.d/postgresql setup >&2 || return 1
            fi
            rc-update add postgresql default >&2 2> /dev/null || true
            rc-service postgresql start >&2 || return 1
            ;;
        *)
            echo -e "${red}Неподдерживаемый дистрибутив для автоматической установки PostgreSQL: ${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

    # Ждём кратковременно пока сервер примет соединения
    local i
    for i in 1 2 3 4 5; do
        sudo -u postgres psql -tAc 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
    done

    local existing_owner=""
    existing_owner=$(sudo -u postgres psql -tAc \
        "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | tr -d '[:space:]')
    if [[ -n "${existing_owner}" && "${existing_owner}" != "postgres" ]]; then
        pg_user="${existing_owner}"
    else
        pg_user=$(gen_random_string 8)
    fi

    # Идентификаторы в двойных кавычках потому что случайное имя пользователя может начинаться с цифры
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    if [[ -n "${PG_CRED_FILE:-}" ]]; then
        local prev_umask
        prev_umask=$(umask)
        umask 077
        if ! cat > "${PG_CRED_FILE}" << EOF; then
PG_USER=${pg_user}
PG_PASS=${pg_pass}
PG_HOST=${pg_host}
PG_PORT=${pg_port}
PG_DB=${pg_db}
EOF
            umask "${prev_umask}"
            echo -e "${red}Не удалось записать учётные данные PostgreSQL в ${PG_CRED_FILE}${plain}" >&2
            return 1
        fi
        umask "${prev_umask}"
    fi

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

ensure_pg_client() {
    if command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1; then
        return 0
    fi
    echo -e "${yellow}Установка клиентских инструментов PostgreSQL (pg_dump/pg_restore) для резервного копирования в панели...${plain}" >&2
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql-client >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql >&2 || return 1
            else
                dnf install -y -q postgresql >&2 || return 1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql >&2 || return 1
            ;;
        alpine)
            apk add --no-cache postgresql-client >&2 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1
}

install_acme() {
    echo -e "${green}Установка acme.sh для управления SSL сертификатами...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}Не удалось установить acme.sh${plain}"
        return 1
    else
        echo -e "${green}acme.sh успешно установлен${plain}"
    fi
    return 0
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"

    echo -e "${green}Настройка SSL сертификата...${plain}"

    # Проверка установки acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}Не удалось установить acme.sh, пропускаем настройку SSL${plain}"
            return 1
        fi
    fi

    # Создание директории для сертификата
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    # Выпуск сертификата
    echo -e "${green}Выпуск SSL сертификата для ${domain}...${plain}"
    echo -e "${yellow}Примечание: Порт 80 должен быть открыт и доступен из интернета${plain}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Не удалось выпустить сертификат для ${domain}${plain}"
        echo -e "${yellow}Убедитесь что порт 80 открыт и попробуйте позже через: x-ui${plain}"
        rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc 2> /dev/null
        rm -rf "$certPath" 2> /dev/null
        return 1
    fi

    # Установка сертификата
    ~/.acme.sh/acme.sh --installcert --force -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Не удалось установить сертификат${plain}"
        return 1
    fi

    # Включение автообновления
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    # Безопасные права доступа: приватный ключ читаем только владельцем
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Установка сертификата для панели
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" > /dev/null 2>&1
        echo -e "${green}SSL сертификат успешно установлен и настроен!${plain}"
        return 0
    else
        echo -e "${yellow}Файлы сертификата не найдены${plain}"
        return 1
    fi
}

# Выпуск Let's Encrypt IP сертификата с профилем shortlived (~6 дней валидности)
# Требует acme.sh и открытый порт 80 для HTTP-01 challenge
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2" # опционально

    echo -e "${green}Настройка Let's Encrypt IP сертификата (профиль shortlived)...${plain}"
    echo -e "${yellow}Примечание: IP сертификаты действительны ~6 дней и будут автоматически обновляться.${plain}"
    echo -e "${yellow}По умолчанию слушатель на порту 80. Если выберете другой порт, убедитесь что внешний порт 80 перенаправляется на него.${plain}"

    # Проверка acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}Не удалось установить acme.sh${plain}"
            return 1
        fi
    fi

    # Валидация IP адреса
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}Требуется IPv4 адрес${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}Неверный IPv4 адрес: $ipv4${plain}"
        return 1
    fi

    # Создание директории для сертификата
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # Сборка аргументов домена
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}Включая IPv6 адрес: ${ipv6}${plain}"
    fi

    # Установка команды перезагрузки для автообновления
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # Выбор порта для HTTP-01 слушателя (по умолчанию 80, запрос переопределения)
    local WebPort=""
    prompt_or_default WebPort "Порт для ACME HTTP-01 слушателя (по умолчанию 80): " "80" XUI_ACME_HTTP_PORT
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}Указан неверный порт. Возврат к 80.${plain}"
        WebPort=80
    fi
    echo -e "${green}Используется порт ${WebPort} для автономной валидации.${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}Напоминание: Let's Encrypt всё равно подключается на порт 80; перенаправьте внешний порт 80 на ${WebPort}.${plain}"
    fi

    # Убедиться что выбранный порт свободен
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}Порт ${WebPort} занят.${plain}"

            local alt_port=""
            if [[ "$NONINTERACTIVE" == "1" ]]; then
                echo -e "${red}Порт ${WebPort} занят; невозможно продолжить в неинтерактивном режиме.${plain}"
                return 1
            fi
            read -rp "Введите другой порт для автономного слушателя acme.sh (оставьте пустым для отмены): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}Порт ${WebPort} занят; невозможно продолжить.${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}Указан неверный порт.${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}Порт ${WebPort} свободен и готов для автономной валидации.${plain}"
            break
        fi
    done

    # Выпуск сертификата с профилем shortlived
    echo -e "${green}Выпуск IP сертификата для ${ipv4}...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    [[ -n "${XUI_ACME_EMAIL:-}" ]] && ~/.acme.sh/acme.sh --register-account -m "${XUI_ACME_EMAIL}" > /dev/null 2>&1

    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}Не удалось выпустить IP сертификат${plain}"
        echo -e "${yellow}Убедитесь что порт ${WebPort} доступен (или перенаправлен с внешнего порта 80)${plain}"
        # Очистка данных acme.sh для IPv4 и IPv6 если указаны
        rm -rf ~/.acme.sh/${ipv4} ~/.acme.sh/${ipv4}_ecc 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} ~/.acme.sh/${ipv6}_ecc 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}Сертификат успешно выпущен, установка...${plain}"

    # Установка сертификата
    # Примечание: acme.sh может сообщить "Reload error" и завершиться с ненулевым кодом если reloadcmd падает,
    # но файлы сертификата всё равно устанавливаются. Проверяем наличие файлов вместо кода выхода.
    ~/.acme.sh/acme.sh --installcert --force -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Проверка существования файлов сертификата (не полагаемся на код выхода)
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}Файлы сертификата не найдены после установки${plain}"
        # Очистка данных acme.sh для IPv4 и IPv6 если указаны
        rm -rf ~/.acme.sh/${ipv4} ~/.acme.sh/${ipv4}_ecc 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} ~/.acme.sh/${ipv6}_ecc 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}Файлы сертификата успешно установлены${plain}"

    # Включение автообновления для acme.sh (обеспечивает работу cron задачи)
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1

    # Безопасные права доступа: приватный ключ читаем только владельцем
    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    chmod 644 ${certDir}/fullchain.pem 2> /dev/null

    # Настройка панели для использования сертификата
    echo -e "${green}Настройка путей сертификата для панели...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Предупреждение: Не удалось автоматически настроить пути сертификата${plain}"
        echo -e "${yellow}Файлы сертификата находятся:${plain}"
        echo -e "  Сертификат: ${certDir}/fullchain.pem"
        echo -e "  Ключ:  ${certDir}/privkey.pem"
    else
        echo -e "${green}Пути сертификата успешно настроены${plain}"
    fi

    echo -e "${green}IP сертификат успешно установлен и настроен!${plain}"
    echo -e "${green}Сертификат действителен ~6 дней, автообновление через cron задачу acme.sh.${plain}"
    echo -e "${yellow}acme.sh автоматически обновит и перезагрузит x-ui до истечения срока действия.${plain}"
    return 0
}

# Комплексный ручной выпуск SSL сертификата через acme.sh
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    # сначала проверяем acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "acme.sh не найден. Устанавливаем сейчас..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}Не удалось установить acme.sh${plain}"
            return 1
        else
            echo -e "${green}acme.sh успешно установлен${plain}"
        fi
    fi

    # получаем домен и проверяем его
    local domain=""
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        domain="${XUI_DOMAIN// /}"
        if [[ -z "$domain" ]] || ! is_domain "$domain"; then
            echo -e "${red}XUI_SSL_MODE=domain требует действительный XUI_DOMAIN (получено: '${XUI_DOMAIN:-}').${plain}"
            return 1
        fi
    else
        while true; do
            read -rp "Введите имя домена: " domain
            domain="${domain// /}" # Убираем пробелы

            if [[ -z "$domain" ]]; then
                echo -e "${red}Имя домена не может быть пустым. Попробуйте снова.${plain}"
                continue
            fi

            if ! is_domain "$domain"; then
                echo -e "${red}Неверный формат домена: ${domain}. Введите действительное имя домена.${plain}"
                continue
            fi

            break
        done
    fi
    echo -e "${green}Ваш домен: ${domain}, проверяем...${plain}"
    SSL_ISSUED_DOMAIN="${domain}"

    # определяем существующий сертификат и переиспользуем его только если файлы
    # действительно существуют и не пустые. acme.sh хранит ECC сертификаты в ${domain}_ecc
    # и RSA в ${domain}; неудачный выпуск может оставить запись домена в --list
    # без пригодных файлов сертификата, что не должно переиспользоваться (даёт 0-байтный fullchain.pem).
    # Сломанное частичное состояние очищается чтобы выпуск мог продолжиться.
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        local acmeCertDir=""
        if [[ -s ~/.acme.sh/${domain}_ecc/fullchain.cer && -s ~/.acme.sh/${domain}_ecc/${domain}.key ]]; then
            acmeCertDir=~/.acme.sh/${domain}_ecc
        elif [[ -s ~/.acme.sh/${domain}/fullchain.cer && -s ~/.acme.sh/${domain}/${domain}.key ]]; then
            acmeCertDir=~/.acme.sh/${domain}
        fi
        if [[ -n "${acmeCertDir}" ]]; then
            cert_exists=1
            local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
            echo -e "${yellow}Найден существующий сертификат для ${domain}, будет переиспользован.${plain}"
            [[ -n "${certInfo}" ]] && echo "$certInfo"
        else
            echo -e "${yellow}Найдено неполное состояние acme.sh для ${domain} (нет действительных файлов сертификата); очищаем и перевыпускаем.${plain}"
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
    fi
    if [[ ${cert_exists} -eq 0 ]]; then
        echo -e "${green}Ваш домен готов для выпуска сертификатов...${plain}"
    fi

    # создание директории для сертификата
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # получение номера порта для автономного сервера
    local WebPort=80
    prompt_or_default WebPort "Выберите порт для использования (по умолчанию 80): " "80" XUI_ACME_HTTP_PORT
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo -e "${yellow}Ваш ввод ${WebPort} неверен, будет использован порт 80 по умолчанию.${plain}"
        WebPort=80
    fi
    echo -e "${green}Будет использован порт: ${WebPort} для выпуска сертификатов. Убедитесь что этот порт открыт.${plain}"

    # Временная остановка панели
    echo -e "${yellow}Временная остановка панели...${plain}"
    systemctl stop x-ui 2> /dev/null || rc-service x-ui stop 2> /dev/null

    if [[ ${cert_exists} -eq 0 ]]; then
        # выпуск сертификата
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        [[ -n "${XUI_ACME_EMAIL:-}" ]] && ~/.acme.sh/acme.sh --register-account -m "${XUI_ACME_EMAIL}" > /dev/null 2>&1
        ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            echo -e "${red}Не удалось выпустить сертификат, проверьте логи.${plain}"
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
            systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
            return 1
        else
            echo -e "${green}Сертификат успешно выпущен, установка сертификатов...${plain}"
        fi
    else
        echo -e "${green}Используется существующий сертификат, установка сертификатов...${plain}"
    fi

    # Настройка команды перезагрузки
    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}Команда --reloadcmd по умолчанию для ACME: ${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}Эта команда будет выполняться при каждом выпуске и обновлении сертификата.${plain}"
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        setReloadcmd="n"
    else
        read -rp "Хотите изменить --reloadcmd для ACME? (y/n): " setReloadcmd
    fi
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} Предустановка: systemctl reload nginx ; systemctl restart x-ui"
        echo -e "${green}\t2.${plain} Ввести свою команду"
        echo -e "${green}\t0.${plain} Оставить reloadcmd по умолчанию"
        read -rp "Выберите опцию: " choice
        case "$choice" in
            1)
                echo -e "${green}Reloadcmd: systemctl reload nginx ; systemctl restart x-ui${plain}"
                reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
                ;;
            2)
                echo -e "${yellow}Рекомендуется ставить перезапуск x-ui в конец${plain}"
                read -rp "Введите свою команду reloadcmd: " reloadCmd
                echo -e "${green}Reloadcmd: ${reloadCmd}${plain}"
                ;;
            *)
                echo -e "${green}Оставляется reloadcmd по умолчанию${plain}"
                ;;
        esac
    fi

    # установка сертификата
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert --force -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        echo -e "${green}Установка сертификата успешна, включение автообновления...${plain}"
    else
        echo -e "${red}Установка сертификата не удалась, выход.${plain}"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
        systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
        return 1
    fi

    # включение автообновления
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Настройка автообновления имела проблемы, детали сертификата:${plain}"
        ls -lah /root/cert/${domain}/
        # Безопасные права доступа: приватный ключ читаем только владельцем
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    else
        echo -e "${green}Автообновление успешно, детали сертификата:${plain}"
        ls -lah /root/cert/${domain}/
        # Безопасные права доступа: приватный ключ читаем только владельцем
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    fi

    # запуск панели
    systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null

    # Запрос пользователя настроить пути панели после успешной установки сертификата
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        setPanel="y"
    else
        read -rp "Хотите установить этот сертификат для панели? (y/n): " setPanel
    fi
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}Пути сертификата установлены для панели${plain}"
            echo -e "${green}Файл сертификата: $webCertFile${plain}"
            echo -e "${green}Файл приватного ключа: $webKeyFile${plain}"
            echo ""
            echo -e "${green}URL доступа: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}Панель будет перезапущена для применения SSL сертификата...${plain}"
            systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
        else
            echo -e "${red}Ошибка: Файл сертификата или приватного ключа не найден для домена: $domain.${plain}"
        fi
    else
        echo -e "${yellow}Пропуск настройки путей панели.${plain}"
    fi

    return 0
}

# Переиспользуемая интерактивная настройка SSL (домен или IP)
# Устанавливает глобальную `SSL_HOST` в выбранный домен/IP для использования в URL доступа
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"
    local server_ip="$3"

    local ssl_choice=""
    SSL_SCHEME="https"

    echo -e "${yellow}Выберите метод настройки SSL сертификата:${plain}"
    echo -e "${green}1.${plain} Let's Encrypt для домена (90 дней валидности, автообновление)"
    echo -e "${green}2.${plain} Let's Encrypt для IP адреса (6 дней валидности, автообновление)"
    echo -e "${green}3.${plain} Пользовательский SSL сертификат (путь к существующим файлам)"
    echo -e "${green}4.${plain} Пропустить SSL (продвинутый — только за обратным прокси / SSH туннелем)"
    echo -e "${blue}Примечание:${plain} Опции 1 и 2 требуют открытый порт 80. Опция 3 требует ручные пути."
    echo -e "${blue}Примечание:${plain} Опция 4 обслуживает панель по простому HTTP — безопасно только за nginx/Caddy или SSH туннелем."
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        case "${XUI_SSL_MODE:-none}" in
            domain) ssl_choice="1" ;;
            ip) ssl_choice="2" ;;
            none | "") ssl_choice="4" ;;
            *)
                echo -e "${yellow}Неизвестный XUI_SSL_MODE='${XUI_SSL_MODE}', по умолчанию none (HTTP).${plain}"
                ssl_choice="4"
                ;;
        esac
    else
        read -rp "Выберите опцию (по умолчанию 2 для IP): " ssl_choice
        ssl_choice="${ssl_choice// /}" # Убираем пробелы

        # По умолчанию 2 (IP сертификат) если ввод пустой или неверный (не 1, 3 или 4)
        if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" && "$ssl_choice" != "4" ]]; then
            ssl_choice="2"
        fi
    fi

    case "$ssl_choice" in
        1)
            # Пользователь выбрал опцию Let's Encrypt для домена
            echo -e "${green}Используется Let's Encrypt для сертификата домена...${plain}"
            if ssl_cert_issue; then
                local cert_domain="${SSL_ISSUED_DOMAIN}"
                if [[ -z "${cert_domain}" ]]; then
                    cert_domain=$(~/.acme.sh/acme.sh --list 2> /dev/null | tail -1 | awk '{print $1}')
                fi

                if [[ -n "${cert_domain}" ]]; then
                    SSL_HOST="${cert_domain}"
                    echo -e "${green}✓ SSL сертификат успешно настроен с доменом: ${cert_domain}${plain}"
                else
                    echo -e "${yellow}Настройка SSL возможно завершена, но извлечение домена не удалось${plain}"
                    SSL_HOST="${server_ip}"
                fi
            else
                echo -e "${red}Настройка SSL сертификата не удалась для режима домена.${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        2)
            # Пользователь выбрал опцию Let's Encrypt для IP сертификата
            echo -e "${green}Используется Let's Encrypt для IP сертификата (профиль shortlived)...${plain}"

            # Запрос опционального IPv6
            local ipv6_addr=""
            prompt_or_default ipv6_addr "Есть ли IPv6 адрес для включения? (оставьте пустым для пропуска): " "" XUI_SSL_IPV6
            ipv6_addr="${ipv6_addr// /}" # Убираем пробелы

            # Остановка панели если запущена (нужен порт 80)
            if [[ $release == "alpine" ]]; then
                rc-service x-ui stop > /dev/null 2>&1
            else
                systemctl stop x-ui > /dev/null 2>&1
            fi

            setup_ip_certificate "${server_ip}" "${ipv6_addr}"
            if [ $? -eq 0 ]; then
                SSL_HOST="${server_ip}"
                echo -e "${green}✓ Let's Encrypt IP сертификат успешно настроен${plain}"
            else
                echo -e "${red}✗ Настройка IP сертификата не удалась. Проверьте что порт 80 открыт.${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        3)
            # Пользователь выбрал опцию пользовательских путей (предоставленных пользователем)
            echo -e "${green}Используется пользовательский существующий сертификат...${plain}"
            local custom_cert=""
            local custom_key=""
            local custom_domain=""

            # 3.1 Запрос домена для составления URL панели позже
            read -rp "Введите имя домена для которого выпущен сертификат: " custom_domain
            custom_domain="${custom_domain// /}" # Убираем пробелы

            # 3.2 Цикл для пути сертификата
            while true; do
                read -rp "Введите путь к сертификату (ключевые слова: .crt / fullchain): " custom_cert
                # Убираем кавычки если есть
                custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                    break
                elif [[ ! -f "$custom_cert" ]]; then
                    echo -e "${red}Ошибка: Файл не существует! Попробуйте снова.${plain}"
                elif [[ ! -r "$custom_cert" ]]; then
                    echo -e "${red}Ошибка: Файл существует но не читается (проверьте права)!${plain}"
                else
                    echo -e "${red}Ошибка: Файл пустой!${plain}"
                fi
            done

            # 3.3 Цикл для пути приватного ключа
            while true; do
                read -rp "Введите путь к приватному ключу (ключевые слова: .key / privatekey): " custom_key
                # Убираем кавычки если есть
                custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                    break
                elif [[ ! -f "$custom_key" ]]; then
                    echo -e "${red}Ошибка: Файл не существует! Попробуйте снова.${plain}"
                elif [[ ! -r "$custom_key" ]]; then
                    echo -e "${red}Ошибка: Файл существует но не читается (проверьте права)!${plain}"
                else
                    echo -e "${red}Ошибка: Файл пустой!${plain}"
                fi
            done

            # 3.4 Применение настроек через бинарник x-ui
            ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" > /dev/null 2>&1

            # Установка SSL_HOST для составления URL панели
            if [[ -n "$custom_domain" ]]; then
                SSL_HOST="$custom_domain"
            else
                SSL_HOST="${server_ip}"
            fi

            echo -e "${green}✓ Пути пользовательского сертификата применены.${plain}"
            echo -e "${yellow}Примечание: Вы отвечаете за обновление этих файлов внешне.${plain}"

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            ;;
        4)
            echo ""
            echo -e "${red}⚠ Панель будет установлена БЕЗ SSL/TLS.${plain}"
            echo -e "${yellow}Учётные данные для входа и куки будут передаваться по простому HTTP.${plain}"
            echo -e "${yellow}Безопасно только когда:${plain}"
            echo -e "${yellow}  • Обратный прокси (nginx, Caddy, Traefik) завершает TLS за вас, или${plain}"
            echo -e "${yellow}  • Вы получаете доступ к панели исключительно через SSH туннель${plain}"
            echo ""

            SSL_SCHEME="http"
            SSL_HOST="${server_ip}"

            local bind_local=""
            if [[ "$NONINTERACTIVE" == "1" ]]; then
                # Облачные образы должны оставаться доступными на своём публичном интерфейсе.
                bind_local="n"
            else
                read -rp "Привязать панель только к 127.0.0.1? (рекомендуется — принудительный доступ через SSH туннель / обратный прокси) [y/N]: " bind_local
            fi
            if [[ "$bind_local" == "y" || "$bind_local" == "Y" ]]; then
                ${xui_folder}/x-ui setting -listenIP "127.0.0.1" > /dev/null 2>&1
                SSL_HOST="127.0.0.1"
                echo -e "${green}✓ Панель привязана только к 127.0.0.1. Теперь недоступна из публичного интернета.${plain}"
                echo ""
                echo -e "${green}SSH Port Forwarding — откройте панель с вашей локальной машины через:${plain}"
                echo -e "  Стандартная команда SSH:"
                echo -e "  ${yellow}ssh -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  Если используете SSH ключ:"
                echo -e "  ${yellow}ssh -i <путь_к_ключу> -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  Затем откройте в браузере:"
                echo -e "  ${yellow}http://localhost:2222/${web_base_path}${plain}"
                echo ""
                echo -e "${yellow}Альтернатива: направьте обратный прокси (nginx/Caddy) на 127.0.0.1:${panel_port} и пусть он завершает TLS.${plain}"
            else
                echo -e "${yellow}Панель будет слушать на всех интерфейсах по простому HTTP. Убедитесь что что-то другое завершает TLS перед ней.${plain}"
            fi

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            echo -e "${green}✓ Настройка SSL пропущена.${plain}"
            ;;
        *)
            echo -e "${red}Неверная опция. Пропуск настройки SSL.${plain}"
            SSL_HOST="${server_ip}"
            ;;
    esac
}

config_after_install() {
    local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # Правильное определение пустого сертификата проверкой существования строки cert: и наличия содержимого после неё
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        if [[ "$NONINTERACTIVE" == "1" ]]; then
            # Панель привязывается к 0.0.0.0 в любом случае; IP используется только для составления
            # отображаемого URL доступа. Возврат к XUI_SERVER_IP или оставление пустым.
            server_ip="${XUI_SERVER_IP:-}"
        else
            echo -e "${yellow}Не удалось автоматически определить IP сервера ни от одного провайдера.${plain}"
            while [[ -z "$server_ip" ]]; do
                read -rp "Введите публичный IPv4 адрес вашего сервера: " server_ip
                server_ip="${server_ip// /}"
                if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "${red}Неверный IPv4 адрес. Попробуйте снова.${plain}"
                    server_ip=""
                fi
            done
        fi
    fi

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath="${XUI_WEB_BASE_PATH:-$(gen_random_string 18)}"
            local config_username="${XUI_USERNAME:-$(gen_random_string 10)}"
            local config_password="${XUI_PASSWORD:-$(gen_random_string 10)}"
            local config_port=""

            local db_label="SQLite (/etc/x-ui/x-ui.db)"
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Выбор базы данных                     ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "  1) SQLite     (по умолчанию — рекомендуется для < 500 клиентов)"
            echo -e "  2) PostgreSQL (рекомендуется для большого количества клиентов / многих узлов)"
            if [[ "$NONINTERACTIVE" == "1" ]]; then
                if [[ "${XUI_DB_TYPE:-sqlite}" == "postgres" ]]; then
                    db_choice="2"
                else
                    db_choice="1"
                fi
            else
                read -rp "Выберите [1]: " db_choice
                db_choice="${db_choice:-1}"
            fi
            if [[ "$db_choice" == "2" ]]; then
                local xui_env_file
                case "${release}" in
                    ubuntu | debian | armbian)
                        xui_env_file="/etc/default/x-ui"
                        ;;
                    arch | manjaro | parch | alpine)
                        xui_env_file="/etc/conf.d/x-ui"
                        ;;
                    *)
                        xui_env_file="/etc/sysconfig/x-ui"
                        ;;
                esac

                local xui_dsn=""
                local pg_mode=""
                local pg_local_installed=0
                while [[ -z "$xui_dsn" ]]; do
                    if [[ "$NONINTERACTIVE" == "1" ]]; then
                        if [[ -n "${XUI_DB_DSN:-}" ]]; then
                            xui_dsn="${XUI_DB_DSN}"
                            db_label="PostgreSQL (внешний)"
                            break
                        fi
                        echo -e "${yellow}Установка PostgreSQL локально (неинтерактивный режим)...${plain}"
                        local pg_cred_file
                        pg_cred_file=$(mktemp 2> /dev/null) || pg_cred_file=$(mktemp -t x-ui-pg-creds.XXXXXXXX)
                        if [[ -n "${pg_cred_file}" ]] && xui_dsn=$(PG_CRED_FILE="${pg_cred_file}" install_postgres_local); then
                            pg_local_installed=1
                            if [[ -r "${pg_cred_file}" ]]; then
                                # shellcheck disable=SC1090
                                source "${pg_cred_file}"
                            fi
                            rm -f "${pg_cred_file}"
                            db_label="PostgreSQL (${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB})"
                            break
                        fi
                        rm -f "${pg_cred_file}"
                        echo -e "${red}Установка PostgreSQL не удалась в неинтерактивном режиме; прерывание.${plain}"
                        echo -e "${yellow}Установите XUI_DB_DSN для использования существующего сервера, или XUI_DB_TYPE=sqlite.${plain}"
                        exit 1
                    fi
                    echo ""
                    echo -e "  1) Установить PostgreSQL локально и создать выделенного пользователя/БД (рекомендуется)"
                    echo -e "  2) Использовать существующий сервер PostgreSQL (введите DSN)"
                    read -rp "Выберите [1]: " pg_mode
                    pg_mode="${pg_mode:-1}"
                    if [[ "$pg_mode" == "2" ]]; then
                        while [[ -z "$xui_dsn" ]]; do
                            read -rp "Введите PostgreSQL DSN (postgres://user:pass@host:port/dbname?sslmode=disable): " xui_dsn
                            xui_dsn="${xui_dsn// /}"
                        done
                        db_label="PostgreSQL (внешний)"
                    else
                        echo -e "${yellow}Установка PostgreSQL — это может занять некоторое время...${plain}"
                        local pg_cred_file
                        pg_cred_file=$(mktemp 2> /dev/null) || pg_cred_file=$(mktemp -t x-ui-pg-creds.XXXXXXXX)
                        if [[ -z "${pg_cred_file}" ]]; then
                            echo -e "${red}Не удалось создать временный файл учётных данных.${plain}"
                            xui_dsn=""
                            continue
                        fi
                        if xui_dsn=$(PG_CRED_FILE="${pg_cred_file}" install_postgres_local); then
                            pg_local_installed=1
                            if [[ -r "${pg_cred_file}" ]]; then
                                # shellcheck disable=SC1090
                                source "${pg_cred_file}"
                            fi
                            rm -f "${pg_cred_file}"
                            db_label="PostgreSQL (${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB})"
                        else
                            rm -f "${pg_cred_file}"
                            echo ""
                            echo -e "${red}Установка PostgreSQL не удалась.${plain}"
                            echo -e "  1) Повторить локальную установку"
                            echo -e "  2) Ввести внешний DSN вместо этого"
                            echo -e "  3) Прервать установку"
                            echo -e "  4) Вернуться к SQLite"
                            read -rp "Выберите [1]: " pg_fail
                            pg_fail="${pg_fail:-1}"
                            case "$pg_fail" in
                                2) pg_mode="2" ;;
                                3)
                                    echo -e "${red}Установка прервана.${plain}"
                                    exit 1
                                    ;;
                                4)
                                    db_choice="1"
                                    xui_dsn=""
                                    break
                                    ;;
                                *) xui_dsn="" ;;
                            esac
                        fi
                    fi
                done
                if [[ -n "$xui_dsn" ]]; then
                    install -d -m 755 "$(dirname "$xui_env_file")"
                    umask 077
                    cat > "$xui_env_file" << EOF
XUI_DB_TYPE=postgres
XUI_DB_DSN=${xui_dsn}
EOF
                    chmod 600 "$xui_env_file"
                    umask 022
                    export XUI_DB_TYPE=postgres
                    export XUI_DB_DSN="${xui_dsn}"
                    ensure_pg_client || echo -e "${yellow}⚠ Не удалось установить pg_dump/pg_restore. Резервное копирование/восстановление БД в панели будет недоступно пока вы не установите пакет postgresql-client.${plain}"
                fi
            fi

            if [[ "$NONINTERACTIVE" == "1" ]]; then
                if [[ -n "${XUI_PANEL_PORT:-}" ]]; then
                    config_port="${XUI_PANEL_PORT}"
                    echo -e "${yellow}Порт вашей панели: ${config_port}${plain}"
                else
                    config_port=$(shuf -i 1024-62000 -n 1)
                    echo -e "${yellow}Сгенерирован случайный порт: ${config_port}${plain}"
                fi
            else
                read -rp "Хотите настроить порт панели? (Если нет, будет применён случайный порт) [y/n]: " config_confirm
                if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                    read -rp "Установите порт панели: " config_port
                    echo -e "${yellow}Порт вашей панели: ${config_port}${plain}"
                else
                    config_port=$(shuf -i 1024-62000 -n 1)
                    echo -e "${yellow}Сгенерирован случайный порт: ${config_port}${plain}"
                fi
            fi

            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Настройка SSL сертификата (РЕКОМЕНДУЕТСЯ)   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}SSL настоятельно рекомендуется. Пропускайте только если обратный прокси${plain}"
            echo -e "${yellow}или SSH туннель обрабатывает TLS за вас.${plain}"
            echo -e "${yellow}Let's Encrypt теперь поддерживает как домены, так и IP адреса!${plain}"
            echo ""

            prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"

            # Получение API токена для отображения
            local config_apiToken=$(${xui_folder}/x-ui setting -getApiToken true | grep -Eo 'apiToken: .+' | awk '{print $2}')

            # Отображение финальных учётных данных и информации о доступе
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Установка панели завершена!         ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}Имя пользователя:    ${config_username}${plain}"
            echo -e "${green}Пароль:    ${config_password}${plain}"
            echo -e "${green}Порт:        ${config_port}${plain}"
            echo -e "${green}WebBasePath: ${config_webBasePath}${plain}"
            echo -e "${green}База данных:    ${db_label}${plain}"
            echo -e "${green}URL доступа:  ${SSL_SCHEME}://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
            echo -e "${green}API токен:   ${config_apiToken}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}⚠ ВАЖНО: Сохраните эти учётные данные в безопасном месте!${plain}"
            if [[ "$SSL_SCHEME" == "https" ]]; then
                echo -e "${yellow}⚠ SSL сертификат: Включён и настроен${plain}"
            else
                echo -e "${yellow}⚠ SSL сертификат: Пропущен — панель только HTTP. Используйте обратный прокси или SSH туннель.${plain}"
            fi

            if [[ "$db_choice" == "2" ]]; then
                echo ""
                echo -e "${green}Резервное копирование и восстановление PostgreSQL встроено в панель:${plain}"
                echo -e "  ${blue}${SSL_SCHEME}://${SSL_HOST}:${config_port}/${config_webBasePath}${plain} → Резервное копирование и восстановление"
                echo -e "${yellow}  Резервное копирование скачивает файл pg_dump .dump; Восстановление перезагружает его через pg_restore.${plain}"
            fi

            if [[ "$db_choice" == "2" && "$pg_local_installed" == "1" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     Учётные данные PostgreSQL               ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}Имя БД:    ${PG_DB}${plain}"
                echo -e "${green}Пользователь:   ${PG_USER}${plain}"
                echo -e "${green}Пароль:   ${PG_PASS}${plain}"
                echo -e "${green}Хост:       ${PG_HOST}${plain}"
                echo -e "${green}Порт:       ${PG_PORT}${plain}"
                echo -e "${green}DSN:        ${xui_dsn}${plain}"
                echo -e "${green}Файл окружения:   ${xui_env_file}${plain}"
                echo -e "${green}-------------------------------------------${plain}"
                echo -e "${green}Подключение с этого сервера:${plain}"
                echo -e "  ${blue}sudo -u postgres psql -d ${PG_DB}${plain}      (как суперпользователь postgres)"
                echo -e "  ${blue}PGPASSWORD='${PG_PASS}' psql -h ${PG_HOST} -p ${PG_PORT} -U ${PG_USER} -d ${PG_DB}${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}⚠ Панель читает эти учётные данные из ${xui_env_file}.${plain}"
                echo -e "${yellow}⚠ Сохраните пароль — он не хранится нигде в открытом виде.${plain}"
                unset PG_USER PG_PASS PG_HOST PG_PORT PG_DB
            fi

            # Сохранение машиночитаемого файла учётных данных для cloud-init / MOTD.
            : "${SSL_SCHEME:=https}"
            : "${SSL_HOST:=${server_ip}}"
            local db_type_out="sqlite"
            [[ "$db_choice" == "2" ]] && db_type_out="postgres"
            write_install_result "${config_username}" "${config_password}" "${config_port}" \
                "${config_webBasePath}" "${SSL_SCHEME}" "${SSL_HOST}" "${config_apiToken}" "${db_type_out}"
        else
            local config_webBasePath=$(gen_random_string 18)
            echo -e "${yellow}WebBasePath отсутствует или слишком короткий. Генерация нового...${plain}"
            ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}Новый WebBasePath: ${config_webBasePath}${plain}"

            # Если панель уже установлена но сертификат не настроен, запрашиваем SSL сейчас
            if [[ -z "${existing_cert}" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     Настройка SSL сертификата (РЕКОМЕНДУЕТСЯ)   ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}Let's Encrypt теперь поддерживает как домены, так и IP адреса!${plain}"
                echo ""
                prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
                echo -e "${green}URL доступа:  ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
            else
                # Если сертификат уже существует, просто показываем URL доступа
                echo -e "${green}URL доступа: https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username="${XUI_USERNAME:-$(gen_random_string 10)}"
            local config_password="${XUI_PASSWORD:-$(gen_random_string 10)}"

            echo -e "${yellow}Обнаружены учётные данные по умолчанию. Требуется обновление безопасности...${plain}"
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "Сгенерированы новые случайные учётные данные для входа:"
            echo -e "###############################################"
            echo -e "${green}Имя пользователя: ${config_username}${plain}"
            echo -e "${green}Пароль: ${config_password}${plain}"
            echo -e "###############################################"

            # Сохранение машиночитаемого файла учётных данных для cloud-init / MOTD.
            local config_apiToken
            config_apiToken=$(${xui_folder}/x-ui setting -getApiToken true | grep -Eo 'apiToken: .+' | awk '{print $2}')
            : "${SSL_SCHEME:=https}"
            : "${SSL_HOST:=${server_ip}}"
            write_install_result "${config_username}" "${config_password}" "${existing_port}" \
                "${existing_webBasePath}" "${SSL_SCHEME}" "${SSL_HOST}" "${config_apiToken}" "${XUI_DB_TYPE:-sqlite}"
        else
            echo -e "${green}Имя пользователя, пароль и WebBasePath правильно установлены.${plain}"
        fi

        # Существующая установка: если сертификат не настроен, запрашиваем настройку SSL
        # Правильное определение пустого сертификата проверкой существования строки cert: и наличия содержимого после неё
        existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        if [[ -z "$existing_cert" ]]; then
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Настройка SSL сертификата (РЕКОМЕНДУЕТСЯ)   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}Let's Encrypt теперь поддерживает как домены, так и IP адреса!${plain}"
            echo ""
            prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
            echo -e "${green}URL доступа:  ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}SSL сертификат уже настроен. Действий не требуется.${plain}"
        fi
    fi

    ${xui_folder}/x-ui migrate
}

# setup_fail2ban автоматически устанавливает и настраивает fail2ban для функции ограничения IP
# вызовом только что установленного CLI x-ui. Ограничение IP зависит от fail2ban
# (без него панель отключает поле limitIp и обнуляет существующие ограничения),
# поэтому свежая установка должна заставить это работать из коробки, как и Docker образ.
# Не фатально по дизайну: сбой fail2ban никогда не должен прерывать установку панели.
setup_fail2ban() {
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        echo -e "${yellow}XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}, пропуск автоматической настройки Fail2ban.${plain}"
        return 0
    fi

    if [[ ! -x /usr/bin/x-ui ]]; then
        echo -e "${yellow}CLI x-ui не найден; пропуск автоматической настройки Fail2ban.${plain}"
        return 0
    fi

    echo -e "${green}Настройка Fail2ban для функции ограничения IP...${plain}"
    if /usr/bin/x-ui setup-fail2ban; then
        echo -e "${green}Настройка Fail2ban завершена.${plain}"
    else
        echo -e "${yellow}Настройка Fail2ban не завершилась; ограничение IP остаётся отключённым пока вы не запустите 'x-ui' и не откроете меню ограничения IP. Продолжение.${plain}"
    fi
    return 0
}

# Размещает файл systemd unit в ${xui_service}/x-ui.service через временный файл +
# атомарный mv, чтобы сбойный cp/curl или прерванный mv никогда не оставили
# усечённый файл unit в живом пути -- systemd тогда не сможет разобрать
# его при следующем daemon-reload/start. Тот же паттерн уже используется для
# /usr/bin/x-ui в другом месте этого скрипта. source_is_url выбирает cp (из файла
# уже извлечённого из tarball релиза) vs curl (резервный GitHub).
_install_xui_service_unit() {
    local source="$1"
    local source_is_url="$2"
    local dest="${xui_service}/x-ui.service"
    local temp_file="${dest}.tmp.$$"

    rm -f "$temp_file"
    if [[ "$source_is_url" == "true" ]]; then
        curl -fLRo "$temp_file" "$source" > /dev/null 2>&1
    else
        cp -f "$source" "$temp_file" > /dev/null 2>&1
    fi
    if [[ $? -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        return 1
    fi
    mv -f "$temp_file" "$dest"
    if [[ $? -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    return 0
}

install_x-ui() {
    cd ${xui_folder%/x-ui}/

    # === ВАЖНО: Все ссылки на ФОРК akса4y/ui ===
    
    # Загрузка ресурсов
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 60 "${REPO_URL}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${red}Не удалось получить версию x-ui, возможно из-за ограничений GitHub API, попробуйте позже${plain}"
            exit 1
        fi
        echo -e "Получена последняя версия x-ui: ${tag_version}, начало установки..."
        curl -fLR --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 300 -o ${xui_folder}-linux-$(arch).tar.gz ${REPO_URL}/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Загрузка x-ui не удалась, убедитесь что ваш сервер может обращаться к GitHub ${plain}"
            exit 1
        fi
        if [[ ! -s ${xui_folder}-linux-$(arch).tar.gz ]]; then
            rm ${xui_folder}-linux-$(arch).tar.gz -f
            echo -e "${red}Загруженный архив релиза x-ui пустой${plain}"
            exit 1
        fi
    else
        tag_version=$1
        # Скользящий канал dev поставляется под фиксированным тегом не-semver который
        # принудительно перемещается к последнему коммиту main при каждом пуше. Принимаем `dev` как
        # удобный псевдоним и пропускаем проверку числового пола для него.
        if [[ "$tag_version" == "dev" || "$tag_version" == "dev-latest" ]]; then
            tag_version="dev-latest"
            echo -e "${yellow}Устанавливается скользящая dev сборка (тег: dev-latest). Это пре-релиз на коммит, не стабильная версия.${plain}"
        else
            tag_version_numeric=${tag_version#v}
            min_version="2.3.5"

            if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
                echo -e "${red}Используйте более новую версию (минимум v2.3.5). Выход из установки.${plain}"
                exit 1
            fi
        fi

        url="${REPO_URL}/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Начало установки x-ui ${tag_version}"
        curl -fLR --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 300 -o ${xui_folder}-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Загрузка x-ui ${tag_version} не удалась, проверьте существование версии ${plain}"
            exit 1
        fi
        if [[ ! -s ${xui_folder}-linux-$(arch).tar.gz ]]; then
            rm ${xui_folder}-linux-$(arch).tar.gz -f
            echo -e "${red}Загруженный архив релиза x-ui пустой${plain}"
            exit 1
        fi
    fi
    local xui_script_temp="/usr/bin/x-ui-temp.$$"
    rm -f "${xui_script_temp}"
    curl -fLRo "${xui_script_temp}" ${RAW_URL}/x-ui.sh
    if [[ $? -ne 0 ]]; then
        rm -f "${xui_script_temp}"
        echo -e "${red}Не удалось загрузить x-ui.sh${plain}"
        exit 1
    fi
    if [[ ! -s "${xui_script_temp}" ]]; then
        rm -f "${xui_script_temp}"
        echo -e "${red}Загруженный x-ui.sh пустой${plain}"
        exit 1
    fi

    # Остановка сервиса x-ui и удаление старых ресурсов
    if [[ -e ${xui_folder}/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        # Убиваем любые оставшиеся sidecar mtg (MTProto). x-ui запускает их вне своего
        # жизненного цикла, поэтому на Linux устаревший может пережить остановку и продолжать удерживать
        # порт входящего соединения с устаревшим секретом, молча ломая новых клиентов.
        # Только что установленная панель порождает чистый mtg на входящее соединение при запуске.
        pkill -f 'mtg-linux-[^ ]* run ' > /dev/null 2>&1 || true
        rm ${xui_folder}/ -rf
    fi

    # Извлечение ресурсов и установка прав
    tar zxvf x-ui-linux-$(arch).tar.gz
    if [[ $? -ne 0 ]]; then
        rm x-ui-linux-$(arch).tar.gz -f
        rm -f "${xui_script_temp}"
        echo -e "${red}Не удалось извлечь архив релиза x-ui -- предыдущая установка уже удалена, поэтому панель не запустится пока это не будет исправлено; попробуйте запустить установщик снова${plain}"
        exit 1
    fi
    rm x-ui-linux-$(arch).tar.gz -f

    cd x-ui
    if [[ $? -ne 0 || ! -s x-ui ]]; then
        rm -f "${xui_script_temp}"
        echo -e "${red}Извлечённый архив x-ui не содержит бинарник x-ui -- предыдущая установка уже удалена, поэтому панель не запустится пока это не будет исправлено; попробуйте запустить установщик снова${plain}"
        exit 1
    fi
    chmod +x x-ui
    chmod +x x-ui.sh

    # Проверка архитектуры системы и переименование файла соответственно
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
        if [[ -f bin/mtg-linux-$(arch) ]]; then
            mv bin/mtg-linux-$(arch) bin/mtg-linux-arm
            chmod +x bin/mtg-linux-arm
        fi
    fi
    chmod +x x-ui bin/xray-linux-$(arch)
    if [[ -f bin/mtg-linux-arm ]]; then
        chmod +x bin/mtg-linux-arm
    elif [[ -f bin/mtg-linux-$(arch) ]]; then
        chmod +x bin/mtg-linux-$(arch)
    fi

    # Обновление CLI x-ui и установка прав
    mv -f "${xui_script_temp}" /usr/bin/x-ui
    if [[ $? -ne 0 ]]; then
        rm -f "${xui_script_temp}"
        echo -e "${red}Не удалось установить x-ui.sh${plain}"
        exit 1
    fi
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    config_after_install

    # Совместимость с Etckeeper
    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}Добавлен x-ui.db в /etc/.gitignore для etckeeper${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}Создан /etc/.gitignore и добавлен x-ui.db для etckeeper${plain}"
        fi
    fi

    if [[ $release == "alpine" ]]; then
        xui_rc_temp="/etc/init.d/x-ui.tmp.$$"
        rm -f "${xui_rc_temp}"
        curl -fLRo "${xui_rc_temp}" ${RAW_URL}/x-ui.rc
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            echo -e "${red}Не удалось загрузить x-ui.rc${plain}"
            exit 1
        fi
        if [[ ! -s "${xui_rc_temp}" ]]; then
            rm -f "${xui_rc_temp}"
            echo -e "${red}Загруженный x-ui.rc пустой${plain}"
            exit 1
        fi
        mv -f "${xui_rc_temp}" /etc/init.d/x-ui
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            echo -e "${red}Не удалось установить x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        # Установка файла сервиса systemd
        service_installed=false

        if [ -f "x-ui.service" ]; then
            echo -e "${green}Найден x-ui.service в извлечённых файлах, установка...${plain}"
            if _install_xui_service_unit "x-ui.service" "false"; then
                service_installed=true
            fi
        fi

        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Найден x-ui.service.debian в извлечённых файлах, установка...${plain}"
                        if _install_xui_service_unit "x-ui.service.debian" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Найден x-ui.service.arch в извлечённых файлах, установка...${plain}"
                        if _install_xui_service_unit "x-ui.service.arch" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Найден x-ui.service.rhel в извлечённых файлах, установка...${plain}"
                        if _install_xui_service_unit "x-ui.service.rhel" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac
        fi

        # Если файл сервиса не найден в tar.gz, загрузка из GitHub
        if [ "$service_installed" = false ]; then
            echo -e "${yellow}Файлы сервиса не найдены в tar.gz, загрузка из GitHub...${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    service_unit_url="${RAW_URL}/x-ui.service.debian"
                    ;;
                arch | manjaro | parch)
                    service_unit_url="${RAW_URL}/x-ui.service.arch"
                    ;;
                *)
                    service_unit_url="${RAW_URL}/x-ui.service.rhel"
                    ;;
            esac

            if ! _install_xui_service_unit "$service_unit_url" "true"; then
                echo -e "${red}Не удалось установить x-ui.service из GitHub${plain}"
                exit 1
            fi
            service_installed=true
        fi

        if [ "$service_installed" = true ]; then
            echo -e "${green}Настройка systemd unit...${plain}"
            chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}Не удалось установить файл x-ui.service${plain}"
            exit 1
        fi
    fi

    # Ограничение IP зависит от fail2ban; установка + настройка сейчас чтобы функция
    # работала из коробки (бездействие когда XUI_ENABLE_FAIL2BAN=false). Никогда не фатально.
    setup_fail2ban

    echo -e "${green}x-ui ${tag_version}${plain} установка завершена, он запущен сейчас..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}Использование меню управления x-ui (подкоманды):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Скрипт управления администратором          │
│  ${blue}x-ui start${plain}        - Запустить                            │
│  ${blue}x-ui stop${plain}         - Остановить                             │
│  ${blue}x-ui restart${plain}      - Перезапустить                          │
│  ${blue}x-ui status${plain}       - Текущий статус                   │
│  ${blue}x-ui settings${plain}     - Текущие настройки                 │
│  ${blue}x-ui enable${plain}       - Включить автозапуск при загрузке ОС   │
│  ${blue}x-ui disable${plain}      - Отключить автозапуск при загрузке ОС  │
│  ${blue}x-ui log${plain}          - Проверить логи                       │
│  ${blue}x-ui banlog${plain}       - Проверить логи блокировок Fail2ban          │
│  ${blue}x-ui update${plain}       - Обновить                           │
│  ${blue}x-ui legacy${plain}       - Устаревшая версия                   │
│  ${blue}x-ui install${plain}      - Установить                          │
│  ${blue}x-ui uninstall${plain}    - Удалить                        │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Запуск...${plain}"
install_base
install_x-ui $1