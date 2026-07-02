#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

# === ВАЖНО: Ссылки на ФОРК akса4y/ui ===
REPO_OWNER="aksa4y"
REPO_NAME="ui"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# Не редактируйте эту конфигурацию
b_source="${BASH_SOURCE[0]}"
while [ -h "$b_source" ]; do
    b_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
    b_source="$(readlink "$b_source")"
    [[ $b_source != /* ]] && b_source="$b_dir/$b_source"
done
cur_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
script_name=$(basename "$0")

# Функция проверки существования команды
_command_exists() {
    type "$1" &> /dev/null
}

# Функция ошибки, логирования и выхода из скрипта
_fail() {
    local msg=${1}
    echo -e "${red}${msg}${plain}"
    exit 2
}

# Записывает результат этого запуска для веб-обновлятора панели, так как он
# запускает этот скрипт отсоединённым и не имеет другого способа узнать завершился ли он.
# Записывается в фиксированный путь вне XUI_MAIN_FOLDER чтобы пережил обновление
# независимо от того что произойдёт с этой папкой. EXIT trap ниже покрывает
# каждый путь выхода в этом файле, включая голые `exit 1`/`exit 2`
# вызовы которые не проходят через _fail.
xui_update_run_id="${XUI_UPDATE_RUN_ID:-0}"
[[ "${xui_update_run_id}" =~ ^[0-9]+$ ]] || xui_update_run_id="0"
xui_update_status_file="${XUI_UPDATE_STATUS_FILE:-/etc/x-ui/update-status.json}"

_write_update_status() {
    local state="$1"
    local exit_code="$2"
    local status_dir
    status_dir="$(dirname "${xui_update_status_file}")"
    mkdir -p "${status_dir}" > /dev/null 2>&1
    local tmp_file="${xui_update_status_file}.tmp.$$"
    printf '{"runId":"%s","state":"%s","exitCode":%s,"finishedAt":%s}\n' \
        "${xui_update_run_id}" "${state}" "${exit_code}" "$(date +%s)" > "${tmp_file}" 2> /dev/null
    mv -f "${tmp_file}" "${xui_update_status_file}" > /dev/null 2>&1
}

_report_update_exit() {
    local code=$?
    if [[ "${code}" -eq 0 ]]; then
        _write_update_status "success" "0"
    else
        _write_update_status "failed" "${code}"
    fi
}
trap _report_update_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# проверка root
[[ $EUID -ne 0 ]] && _fail "КРИТИЧЕСКАЯ ОШИБКА: Запустите этот скрипт с правами root."

if _command_exists curl; then
    curl_bin=$(which curl)
else
    _fail "ОШИБКА: Команда 'curl' не найдена."
fi

# Проверка ОС и установка переменной release
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    _fail "Не удалось определить ОС, свяжитесь с автором!"
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
        *) echo -e "${red}Неподдерживаемая архитектура процессора!${plain}" && rm -f "${cur_dir}/${script_name}" > /dev/null 2>&1 && exit 2 ;;
    esac
}

echo "Архитектура: $(arch)"

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

# Помощники портов
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

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

xui_env_file_path() {
    case "${release}" in
        ubuntu | debian | armbian)
            echo "/etc/default/x-ui"
            ;;
        arch | manjaro | parch | alpine)
            echo "/etc/conf.d/x-ui"
            ;;
        *)
            echo "/etc/sysconfig/x-ui"
            ;;
    esac
}

load_xui_env() {
    local env_file
    env_file="$(xui_env_file_path)"
    if [[ -r "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi
}

install_base() {
    echo -e "${green}Обновление и установка пакетов зависимостей...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf makecache -y > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            else
                dnf makecache -y > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu > /dev/null 2>&1 && pacman -Syu --noconfirm cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y cron curl tar timezone socat openssl > /dev/null 2>&1
            ;;
        alpine)
            apk update > /dev/null 2>&1 && apk add dcron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        *)
            apt-get update > /dev/null 2>&1 && apt install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
    esac
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
            echo -e "${yellow}Не удалось установить acme.sh, пропуск настройки SSL${plain}"
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
        rm -rf ~/.acme.sh/${domain} 2> /dev/null
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

    # Установка команды перезагрузки для автообновления (добавление || true чтобы не падал если сервис остановлен)
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # Выбор порта для HTTP-01 слушателя (по умолчанию 80, запрос переопределения)
    local WebPort=""
    read -rp "Порт для ACME HTTP-01 слушателя (по умолчанию 80): " WebPort
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
            echo -e "${yellow}Порт ${WebPort} в данный момент занят.${plain}"

            local alt_port=""
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
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
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

    # Проверка существования файлов сертификата (не полагаемся на код выхода - сбой reloadcmd вызывает ненулевой)
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}Файлы сертификата не найдены после установки${plain}"
        # Очистка данных acme.sh для IPv4 и IPv6 если указаны
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}Файлы сертификата успешно установлены${plain}"

    # Включение автообновления для acme.sh (обеспечивает работу cron задачи)
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1

    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    chmod 644 ${certDir}/fullchain.pem 2> /dev/null

    # Настройка панели для использования сертификата
    echo -e "${green}Настройка путей сертификата для панели...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Предупреждение: Не удалось автоматически настроить пути сертификата.${plain}"
        echo -e "${yellow}Возможно вам потребуется установить их вручную в настройках панели.${plain}"
        echo -e "${yellow}Путь сертификата: ${certDir}/fullchain.pem${plain}"
        echo -e "${yellow}Путь ключа: ${certDir}/privkey.pem${plain}"
    else
        echo -e "${green}Пути сертификата успешно настроены!${plain}"
    fi

    echo -e "${green}IP сертификат успешно установлен и настроен!${plain}"
    echo -e "${green}Сертификат действителен ~6 дней, автообновление через cron задачу acme.sh.${plain}"
    echo -e "${yellow}Панель будет автоматически перезапускаться после каждого обновления.${plain}"
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
    echo -e "${green}Ваш домен: ${domain}, проверяем...${plain}"
    SSL_ISSUED_DOMAIN="${domain}"

    # определяем существующий сертификат и переиспользуем его если присутствует
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        echo -e "${yellow}Найден существующий сертификат для ${domain}, будет переиспользован.${plain}"
        [[ -n "${certInfo}" ]] && echo "$certInfo"
    else
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
    read -rp "Выберите порт для использования (по умолчанию 80): " WebPort
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
        ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            echo -e "${red}Не удалось выпустить сертификат, проверьте логи.${plain}"
            rm -rf ~/.acme.sh/${domain}
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
    read -rp "Хотите изменить --reloadcmd для ACME? (y/n): " setReloadcmd
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
            rm -rf ~/.acme.sh/${domain}
        fi
        systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
        return 1
    fi

    # включение автообновления
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Настройка автообновления имела проблемы, детали сертификата:${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    else
        echo -e "${green}Автообновление успешно, детали сертификата:${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Перезапуск панели
    systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null

    # Запрос пользователя настроить пути панели после успешной установки сертификата
    read -rp "Хотите установить этот сертификат для панели? (y/n): " setPanel
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
# Единая интерактивная настройка SSL (домен или IP)
# Устанавливает глобальную `SSL_HOST` в выбранный домен/IP
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2" # ожидается без ведущего слэша
    local server_ip="$3"

    local ssl_choice=""

    echo -e "${yellow}Выберите метод настройки SSL сертификата:${plain}"
    echo -e "${green}1.${plain} Let's Encrypt для домена (90 дней валидности, автообновление)"
    echo -e "${green}2.${plain} Let's Encrypt для IP адреса (6 дней валидности, автообновление)"
    echo -e "${green}3.${plain} Пользовательский SSL сертификат (путь к существующим файлам)"
    echo -e "${green}4.${plain} Пропустить SSL (продвинутый — только за обратным прокси / SSH туннелем)"
    echo -e "${blue}Примечание:${plain} Опции 1 и 2 требуют открытый порт 80. Опция 3 требует ручные пути."
    echo -e "${blue}Примечание:${plain} Опция 4 обслуживает панель по простому HTTP — безопасно только за nginx/Caddy или SSH туннелем."
    read -rp "Выберите опцию (по умолчанию 2 для IP): " ssl_choice
    ssl_choice="${ssl_choice// /}" # Убираем пробелы

    # По умолчанию 2 (IP сертификат) если ввод пустой или неверный (не 1, 3 или 4)
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" && "$ssl_choice" != "4" ]]; then
        ssl_choice="2"
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
            read -rp "Есть ли IPv6 адрес для включения? (оставьте пустым для пропуска): " ipv6_addr
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

            # Перезапуск панели после настройки SSL (перезапуск применяет новые настройки сертификата)
            if [[ $release == "alpine" ]]; then
                rc-service x-ui restart > /dev/null 2>&1
            else
                systemctl restart x-ui > /dev/null 2>&1
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
            read -rp "Привязать панель только к 127.0.0.1? (рекомендуется — принудительный доступ через SSH туннель / обратный прокси) [y/N]: " bind_local
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

config_after_update() {
    local panel_needs_restart=0

    echo -e "${yellow}Настройки x-ui:${plain}"
    ${xui_folder}/x-ui setting -show true
    ${xui_folder}/x-ui migrate

    # Правильное определение пустого сертификата проверкой существования строки cert: и наличия содержимого после неё
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true 2> /dev/null | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')

    # Получение IP сервера
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

    # Обработка отсутствующего/короткого webBasePath
    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        echo -e "${yellow}WebBasePath отсутствует или слишком короткий. Генерация нового...${plain}"
        local config_webBasePath=$(gen_random_string 18)
        ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
        existing_webBasePath="${config_webBasePath}"
        panel_needs_restart=1
        echo -e "${green}Новый WebBasePath: ${config_webBasePath}${plain}"
    fi

    # Проверка и запрос SSL если отсутствует
    if [[ -z "$existing_cert" ]]; then
        echo ""
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${red}      ⚠ SSL СЕРТИФИКАТ НЕ ОБНАРУЖЕН ⚠     ${plain}"
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}Для безопасности SSL сертификат ОБЯЗАТЕЛЕН для всех панелей.${plain}"
        echo -e "${yellow}Let's Encrypt теперь поддерживает как домены, так и IP адреса!${plain}"
        echo ""

        # Запрос и настройка SSL (домен или IP)
        prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"

        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     Информация о доступе к панели              ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}URL доступа: https://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}⚠ SSL сертификат: Включён и настроен${plain}"
    else
        echo -e "${green}SSL сертификат уже настроен${plain}"
        # Показать URL доступа с существующим сертификатом
        local cert_domain=$(basename "$(dirname "$existing_cert")")
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     Информация о доступе к панели              ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}URL доступа: https://${cert_domain}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
    fi

    if [[ "$panel_needs_restart" -eq 1 ]]; then
        echo -e "${yellow}Перезапуск панели для применения нового web base path...${plain}"
        systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
    fi
}

# setup_fail2ban автоматически устанавливает и настраивает fail2ban для функции ограничения IP
# вызовом только что загруженного CLI x-ui. Ограничение IP зависит от fail2ban
# (без него панель отключает поле limitIp и обнуляет существующие ограничения),
# поэтому обновление старой установки должно заставить это работать без ручного
# прохода через меню ограничения IP. Не фатально: сбой fail2ban никогда не должен прерывать
# обновление. XUI_ENABLE_FAIL2BAN учитывается (load_xui_env экспортирует его из
# сохранённого файла окружения, так что явный отказ переживает обновления).
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
        ${curl_bin} -fLRo "$temp_file" "$source" > /dev/null 2>&1
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

update_x-ui() {
    cd ${xui_folder%/x-ui}/

    load_xui_env

    if [ -f "${xui_folder}/x-ui" ]; then
        current_xui_version=$(${xui_folder}/x-ui -v)
        echo -e "${green}Текущая версия x-ui: ${current_xui_version}${plain}"
    else
        _fail "ОШИБКА: Текущая версия x-ui: неизвестна"
    fi

    echo -e "${green}Загрузка новой версии x-ui...${plain}"

    # === ВАЖНО: Все ссылки на ФОРК akса4y/ui ===
    
    # XUI_UPDATE_TAG позволяет панели нацелиться на конкретный тег релиза (например
    # скользящий dev-latest пре-релиз). Пустое сохраняет стандартный поток latest-stable.
    if [[ -n "${XUI_UPDATE_TAG}" ]]; then
        tag_version="${XUI_UPDATE_TAG}"
        echo -e "${green}Используется тег обновления: ${tag_version}${plain}"
    else
        tag_version=$(${curl_bin} -Ls "${REPO_URL}/releases/latest" 2> /dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            _fail "ОШИБКА: Не удалось получить версию x-ui, возможно из-за ограничений GitHub API, попробуйте позже"
        fi
    fi
    echo -e "Получена последняя версия x-ui: ${tag_version}, начало установки..."
    ${curl_bin} -fLRo ${xui_folder}-linux-$(arch).tar.gz ${REPO_URL}/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2> /dev/null
    if [[ $? -ne 0 ]]; then
        _fail "ОШИБКА: Не удалось загрузить x-ui, убедитесь что ваш сервер может обращаться к GitHub"
    fi
    if [[ ! -s ${xui_folder}-linux-$(arch).tar.gz ]]; then
        rm ${xui_folder}-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "ОШИБКА: Загруженный архив релиза x-ui пустой, убедитесь что ваш сервер может обращаться к GitHub"
    fi

    if [[ -e ${xui_folder}/ ]]; then
        echo -e "${green}Остановка x-ui...${plain}"
        if [[ $release == "alpine" ]]; then
            if [ -f "/etc/init.d/x-ui" ]; then
                rc-service x-ui stop > /dev/null 2>&1
                rc-update del x-ui > /dev/null 2>&1
                echo -e "${green}Удаление старой версии service unit...${plain}"
                rm -f /etc/init.d/x-ui > /dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "ОШИБКА: Service unit x-ui не установлен."
            fi
        else
            if [ -f "${xui_service}/x-ui.service" ]; then
                systemctl stop x-ui > /dev/null 2>&1
                systemctl disable x-ui > /dev/null 2>&1
                echo -e "${green}Удаление старой версии systemd unit...${plain}"
                rm ${xui_service}/x-ui.service -f > /dev/null 2>&1
                systemctl daemon-reload > /dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "ОШИБКА: Systemd unit x-ui не установлен."
            fi
        fi
        # Убиваем любые оставшиеся sidecar mtg (MTProto). x-ui запускает их вне своего
        # жизненного цикла, поэтому на Linux устаревший может пережить остановку и продолжать удерживать
        # порт входящего соединения с устаревшим секретом, молча ломая новых клиентов.
        # Новая панель порождает чистый mtg на входящее соединение при следующем запуске.
        pkill -f 'mtg-linux-[^ ]* run ' > /dev/null 2>&1 || true
        echo -e "${green}Удаление старой версии x-ui...${plain}"
        rm ${xui_folder} -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.debian -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.arch -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.rhel -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.sh -f > /dev/null 2>&1
        echo -e "${green}Удаление старой версии xray...${plain}"
        rm ${xui_folder}/bin/xray-linux-amd64 -f > /dev/null 2>&1
        echo -e "${green}Удаление старых файлов README и LICENSE...${plain}"
        rm ${xui_folder}/bin/README.md -f > /dev/null 2>&1
        rm ${xui_folder}/bin/LICENSE -f > /dev/null 2>&1
    else
        rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "ОШИБКА: x-ui не установлен."
    fi

    echo -e "${green}Установка новой версии x-ui...${plain}"
    tar zxvf x-ui-linux-$(arch).tar.gz > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "ОШИБКА: Не удалось извлечь архив релиза x-ui -- предыдущая установка уже удалена, поэтому панель не запустится пока это не будет исправлено; попробуйте запустить обновление снова"
    fi
    rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
    cd x-ui > /dev/null 2>&1
    if [[ $? -ne 0 || ! -s x-ui ]]; then
        _fail "ОШИБКА: Извлечённый архив x-ui не содержит бинарник x-ui -- предыдущая установка уже удалена, поэтому панель не запустится пока это не будет исправлено; попробуйте запустить обновление снова"
    fi
    chmod +x x-ui > /dev/null 2>&1

    # Проверка архитектуры системы и переименование файла соответственно
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm > /dev/null 2>&1
        chmod +x bin/xray-linux-arm > /dev/null 2>&1
    fi

    chmod +x x-ui bin/xray-linux-$(arch) > /dev/null 2>&1

    echo -e "${green}Загрузка и установка скрипта x-ui.sh...${plain}"
    local xui_script_temp="/usr/bin/x-ui-temp.$$"
    rm -f "${xui_script_temp}"
    # === Ссылка на ФОРК akса4y/ui ===
    ${curl_bin} -fLRo "${xui_script_temp}" ${RAW_URL}/x-ui.sh > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        rm -f "${xui_script_temp}"
        _fail "ОШИБКА: Не удалось загрузить скрипт x-ui.sh, убедитесь что ваш сервер может обращаться к GitHub"
    fi
    if [[ ! -s "${xui_script_temp}" ]]; then
        rm -f "${xui_script_temp}"
        _fail "ОШИБКА: Загруженный скрипт x-ui.sh пустой, убедитесь что ваш сервер может обращаться к GitHub"
    fi
    mv -f "${xui_script_temp}" /usr/bin/x-ui
    if [[ $? -ne 0 ]]; then
        rm -f "${xui_script_temp}"
        _fail "ОШИБКА: Не удалось установить скрипт x-ui.sh"
    fi

    chmod +x ${xui_folder}/x-ui.sh > /dev/null 2>&1
    chmod +x /usr/bin/x-ui > /dev/null 2>&1
    mkdir -p /var/log/x-ui > /dev/null 2>&1

    echo -e "${green}Изменение владельца...${plain}"
    chown -R root:root ${xui_folder} > /dev/null 2>&1

    if [ -f "${xui_folder}/bin/config.json" ]; then
        echo -e "${green}Изменение прав доступа к файлу конфигурации...${plain}"
        chmod 640 ${xui_folder}/bin/config.json > /dev/null 2>&1
    fi

    if [[ $release == "alpine" ]]; then
        echo -e "${green}Загрузка и установка startup unit x-ui.rc...${plain}"
        xui_rc_temp="/etc/init.d/x-ui.tmp.$$"
        rm -f "${xui_rc_temp}"
        # === Ссылка на ФОРК akса4y/ui ===
        ${curl_bin} -fLRo "${xui_rc_temp}" ${RAW_URL}/x-ui.rc > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            _fail "ОШИБКА: Не удалось загрузить startup unit x-ui.rc, убедитесь что ваш сервер может обращаться к GitHub"
        fi
        if [[ ! -s "${xui_rc_temp}" ]]; then
            rm -f "${xui_rc_temp}"
            _fail "ОШИБКА: Загруженный startup unit x-ui.rc пустой, убедитесь что ваш сервер может обращаться к GitHub"
        fi
        mv -f "${xui_rc_temp}" /etc/init.d/x-ui
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            _fail "ОШИБКА: Не удалось установить startup unit x-ui.rc"
        fi
        chmod +x /etc/init.d/x-ui > /dev/null 2>&1
        chown root:root /etc/init.d/x-ui > /dev/null 2>&1
        rc-update add x-ui > /dev/null 2>&1
        rc-service x-ui start > /dev/null 2>&1
    else
        if [ -f "x-ui.service" ]; then
            echo -e "${green}Установка systemd unit...${plain}"
            if ! _install_xui_service_unit "x-ui.service" "false"; then
                echo -e "${red}Не удалось скопировать x-ui.service${plain}"
                exit 1
            fi
        else
            service_installed=false
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Установка debian-like systemd unit...${plain}"
                        if _install_xui_service_unit "x-ui.service.debian" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Установка arch-like systemd unit...${plain}"
                        if _install_xui_service_unit "x-ui.service.arch" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Установка rhel-like systemd unit...${plain}"
                        if _install_xui_service_unit "x-ui.service.rhel" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac

            # Если файл сервиса не найден в tar.gz, загрузка из GitHub
            if [ "$service_installed" = false ]; then
                echo -e "${yellow}Файлы сервиса не найдены в tar.gz, загрузка из GitHub...${plain}"
                # === Ссылки на ФОРК akса4y/ui ===
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
            fi
        fi
        chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
        chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable x-ui > /dev/null 2>&1
        systemctl start x-ui > /dev/null 2>&1
    fi

    config_after_update

    # Ограничение IP зависит от fail2ban; установка + настройка сейчас чтобы функция
    # работала из коробки при обновлении тоже (бездействие когда XUI_ENABLE_FAIL2BAN=false).
    # Никогда не фатально.
    setup_fail2ban

    echo -e "${green}x-ui ${tag_version}${plain} обновление завершено, он запущен сейчас..."
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
update_x-ui $1