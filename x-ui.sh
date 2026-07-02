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

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[ОТЛ] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ОШБ] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[ИНФ] $* ${plain}"
}

# Помощники портов: определение слушателя и владеющего процесса (best effort)
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

# Простые помощники для валидации домена/IP
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

# проверка root
[[ $EUID -ne 0 ]] && LOGE "ОШИБКА: Вы должны быть root для запуска этого скрипта! \n" && exit 1

# Проверка ОС и установка переменной release
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

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

running_in_docker="false"
if [[ -f /.dockerenv ]] || [[ "${XUI_IN_DOCKER}" == "true" ]]; then
    running_in_docker="true"
fi

# Объявление переменных
if [[ "${running_in_docker}" == "true" ]]; then
    xui_folder="${XUI_MAIN_FOLDER:=/app}"
else
    xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
fi
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [По умолчанию $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "Перезапустить панель? Внимание: Перезапуск панели также перезапустит xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}Нажмите Enter для возврата в главное меню: ${plain}" && read -r temp
    show_menu
}

install() {
    # === Ссылка на ФОРК akса4y/ui ===
    bash <(curl -Ls ${RAW_URL}/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "Эта функция обновит все компоненты x-ui до последней версии, данные не будут потеряны. Продолжить?" "y"
    if [[ $? != 0 ]]; then
        LOGE "Отменено"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    # === Ссылка на ФОРК akса4y/ui ===
    bash <(curl -Ls ${RAW_URL}/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "Обновление завершено, панель автоматически перезапущена"
        before_show_menu
    fi
}

update_dev() {
    confirm "Это обновит x-ui до последнего DEV коммита (скользящая сборка 'dev-latest', не стабильный релиз). Ваши данные сохранятся. Продолжить?" "y"
    if [[ $? != 0 ]]; then
        LOGE "Отменено"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    # XUI_UPDATE_TAG указывает update.sh установить dev-latest пре-релиз
    # вместо последнего стабильного тега.
    # === Ссылка на ФОРК akса4y/ui ===
    XUI_UPDATE_TAG="dev-latest" bash <(curl -Ls ${RAW_URL}/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "Dev обновление завершено, панель автоматически перезапущена"
        before_show_menu
    fi
}

replace_xui_script() {
    local url="$1"
    local use_if_modified_since="$2"
    local temp_file="/usr/bin/x-ui-temp.$$"

    rm -f "$temp_file"
    if [[ "$use_if_modified_since" == "true" ]]; then
        curl -fLRo "$temp_file" -z /usr/bin/x-ui "$url"
    else
        curl -fLRo "$temp_file" "$url"
    fi
    if [[ $? != 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        # -z выше означает "не изменён с момента /usr/bin/x-ui" а не
        # реальную ошибку, так что пустая загрузка здесь — успех, а не ошибка.
        [[ "$use_if_modified_since" == "true" ]] && return 0
        return 1
    fi

    mv -f "$temp_file" /usr/bin/x-ui
    if [[ $? != 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    # Перемещение уже поместило новый скрипт; временный сбой chmod здесь
    # не должен заставить вызывающих думать что вся замена провалилась.
    chmod +x /usr/bin/x-ui
    return 0
}

update_menu() {
    echo -e "${yellow}Обновление меню${plain}"
    confirm "Эта функция обновит меню до последних изменений." "y"
    if [[ $? != 0 ]]; then
        LOGE "Отменено"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    # === Ссылка на ФОРК akса4y/ui ===
    if replace_xui_script "${RAW_URL}/x-ui.sh" "false"; then
        chmod +x ${xui_folder}/x-ui.sh
        echo -e "${green}Обновление успешно. Панель автоматически перезапущена.${plain}"
        exit 0
    else
        echo -e "${red}Не удалось обновить меню.${plain}"
        return 1
    fi
}

legacy_version() {
    echo -n "Введите версию панели (например 2.4.0):"
    read -r tag_version

    if [ -z "$tag_version" ]; then
        echo "Версия панели не может быть пустой. Выход."
        exit 1
    fi
    # === Ссылка на ФОРК akса4y/ui ===
    install_command="bash <(curl -Ls "${RAW_URL}/v$tag_version/install.sh") v$tag_version"

    echo "Загрузка и установка версии панели $tag_version..."
    eval $install_command
}

# Функция для обработки удаления файла скрипта
delete_script() {
    rm "$0" # Удалить сам файл скрипта
    exit 1
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

uninstall() {
    confirm "Вы уверены что хотите удалить панель? xray также будет удалён!" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    local panel_used_postgres="false"
    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        panel_used_postgres="true"
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf
    rm -f "$db_env_file"

    if [[ "$panel_used_postgres" == "true" ]] && postgresql_installed; then
        purge_postgresql
    fi

    echo ""
    echo -e "Удаление успешно завершено.\n"
    echo "Если вам нужно установить эту панель снова, используйте команду ниже:"
    # === Ссылка на ФОРК akса4y/ui ===
    echo -e "${green}bash <(curl -Ls ${RAW_URL}/install.sh)${plain}"
    echo ""
    # Перехват сигнала SIGTERM
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "Вы уверены что хотите сбросить имя пользователя и пароль панели?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    read -rp "Установите имя пользователя для входа [по умолчанию случайное]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "Установите пароль для входа [по умолчанию случайный]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "Хотите отключить текущую настроенную двухфакторную аутентификацию? (y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor=true > /dev/null 2>&1
        echo -e "Двухфакторная аутентификация отключена."
    fi

    echo -e "Имя пользователя панели сброшено на: ${green} ${config_account} ${plain}"
    echo -e "Пароль панели сброшен на: ${green} ${config_password} ${plain}"
    echo -e "${green} Используйте новые учётные данные для доступа к панели X-UI. Также запомните их! ${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    echo -e "${yellow}Сброс Web Base Path${plain}"

    read -rp "Вы уверены что хотите сбросить web base path? (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}Операция отменена.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    # Применение новой настройки web base path
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    echo -e "Web base path сброшен на: ${green}${config_webBasePath}${plain}"
    echo -e "${green}Используйте новый web base path для доступа к панели.${plain}"
    restart
}

reset_config() {
    confirm "Вы уверены что хотите сбросить все настройки панели? Данные аккаунтов не будут потеряны, имя пользователя и пароль не изменятся" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "Все настройки панели сброшены до значений по умолчанию."
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "ошибка получения текущих настроек, проверьте логи"
        show_menu
        return
    fi
    LOGI "${info}"

    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        local dsn
        dsn="$(grep -E '^XUI_DB_DSN=' "$db_env_file" | head -1 | cut -d= -f2-)"
        local dsn_safe
        dsn_safe="$(echo "$dsn" | sed -E 's|(://[^:/@]+:)[^@]+@|\1****@|')"
        echo -e "${green}База данных: PostgreSQL — ${dsn_safe}${plain}"
    else
        echo -e "${green}База данных: SQLite (/etc/x-ui/x-ui.db)${plain}"
    fi

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
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

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")
        # Имя папки сертификата — только первый домен сертификата. Мультидоменный
        # (SAN) сертификат может обслуживаться под любым именем которое он покрывает,
        # так что читаем реальные имена из самого сертификата (#5070).
        local cert_sans=""
        if [[ -f "$existing_cert" ]] && command -v openssl > /dev/null 2>&1; then
            cert_sans=$(openssl x509 -in "$existing_cert" -noout -ext subjectAltName 2> /dev/null \
                | grep -Eo 'DNS:[^,[:space:]]+' | cut -d: -f2)
            if [[ -n "$cert_sans" ]] && ! echo "$cert_sans" | grep -qx "$domain"; then
                domain=$(echo "$cert_sans" | head -n1)
            fi
        fi

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}URL доступа: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}URL доступа: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
        if [[ -n "$cert_sans" && $(echo "$cert_sans" | wc -l) -gt 1 ]]; then
            echo -e "${yellow}Сертификат также покрывает:${plain} $(echo "$cert_sans" | grep -vx "$domain" | tr '\n' ' ')"
        fi
    else
        echo -e "${red}⚠ ВНИМАНИЕ: SSL сертификат не настроен!${plain}"
        echo -e "${yellow}Вы можете получить сертификат Let's Encrypt для вашего IP адреса (действителен ~6 дней, автообновление).${plain}"
        read -rp "Сгенерировать SSL сертификат для IP сейчас? [y/N]: " gen_ssl
        if [[ "$gen_ssl" == "y" || "$gen_ssl" == "Y" ]]; then
            stop 0 > /dev/null 2>&1
            ssl_cert_issue_for_ip
            if [[ $? -eq 0 ]]; then
                echo -e "${green}URL доступа: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
                # ssl_cert_issue_for_ip уже перезапускает панель, но убедимся что она запущена
                start 0 > /dev/null 2>&1
            else
                LOGE "Настройка IP сертификата не удалась."
                echo -e "${yellow}Можете попробовать снова через опцию 19 (Управление SSL сертификатами).${plain}"
                start 0 > /dev/null 2>&1
            fi
        else
            echo -e "${yellow}URL доступа: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}Для безопасности настройте SSL сертификат через опцию 19 (Управление SSL сертификатами)${plain}"
        fi
    fi
}

set_port() {
    echo -n "Введите номер порта [1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "Отменено"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        echo -e "Порт установлен, перезапустите панель сейчас, и используйте новый порт ${green}${port}${plain} для доступа к веб-панели"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "Панель запущена, нет необходимости запускать снова. Если нужно перезапустить, выберите restart"
    else
        if [[ "${running_in_docker}" == "true" ]]; then
            LOGE "Процесс панели не запущен внутри этого контейнера."
            LOGI "В Docker панель — это главный процесс контейнера. Перезапустите контейнер чтобы вернуть её:"
            LOGI "  docker restart <имя_контейнера>"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui успешно запущен"
        else
            LOGE "Не удалось запустить панель, вероятно потому что запуск занимает больше двух секунд, проверьте информацию в логах позже"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "Панель остановлена, нет необходимости останавливать снова!"
    else
        if [[ "${running_in_docker}" == "true" ]]; then
            LOGI "В Docker панель работает как главный процесс контейнера."
            LOGI "Чтобы остановить, остановите контейнер с хоста:"
            LOGI "  docker stop <имя_контейнера>"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui и xray успешно остановлены"
        else
            LOGE "Не удалось остановить панель, вероятно потому что время остановки превышает две секунды, проверьте информацию в логах позже"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ "${running_in_docker}" == "true" ]]; then
        if signal_xui HUP; then
            sleep 1
            signal_xui USR1
            LOGI "Сигнал перезапуска отправлен панели и xray-core."
        else
            LOGE "Не удалось найти работающий процесс панели для отправки сигнала."
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui и xray успешно перезапущены"
        else
            LOGE "Не удалось перезапустить панель, проверьте информацию в логах позже"
        fi
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui и xray успешно перезапущены"
    else
        LOGE "Не удалось перезапустить панель, вероятно потому что запуск занимает больше двух секунд, проверьте информацию в логах позже"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    if [[ "${running_in_docker}" == "true" ]]; then
        if signal_xui USR1; then
            LOGI "Сигнал перезапуска xray-core успешно отправлен, проверьте информацию в логах для подтверждения успешного перезапуска xray"
        else
            LOGE "Не удалось найти работающий процесс панели для отправки сигнала."
        fi
        sleep 2
        show_xray_status
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui reload
    else
        systemctl reload x-ui
    fi
    LOGI "Сигнал перезапуска xray-core успешно отправлен, проверьте информацию в логах для подтверждения успешного перезапуска xray"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ "${running_in_docker}" == "true" ]]; then
        show_status
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ "${running_in_docker}" == "true" ]]; then
        LOGI "Автозапуск контролируется политикой перезапуска Docker (например 'restart: unless-stopped' в docker-compose.yml)."
        LOGI "Внутри контейнера нет сервиса для включения."
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui успешно настроен на автозапуск при загрузке ОС"
    else
        LOGE "x-ui не удалось настроить автозапуск"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ "${running_in_docker}" == "true" ]]; then
        LOGI "Автозапуск контролируется политикой перезапуска Docker (например 'restart: unless-stopped' в docker-compose.yml)."
        LOGI "Установите 'restart: no' для контейнера на хосте чтобы отключить автозапуск."
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui автозапуск успешно отменён"
    else
        LOGE "x-ui не удалось отменить автозапуск"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} Лог отладки"
        echo -e "${green}\t0.${plain} Назад в главное меню"
        read -rp "Выберите опцию: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} Лог отладки"
        echo -e "${green}\t2.${plain} Очистить все логи"
        echo -e "${green}\t0.${plain} Назад в главное меню"
        read -rp "Выберите опцию: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "Все логи очищены."
                restart
                ;;
            *)
                echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
                show_log
                ;;
        esac
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} Включить BBR"
    echo -e "${green}\t2.${plain} Отключить BBR"
    echo -e "${green}\t0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${yellow}BBR в данный момент не включён.${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        # sysctl -w уже восстанавливает живые значения, так что нет необходимости в `sysctl --system`
        # после — это бы пере-применило каждый sysctl файл на хосте и
        # выявило несвязанные ошибки из собственных настроек дистрибутива (см. issue #5160)
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
    else
        # Замена BBR на конфигурации CUBIC
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}BBR успешно заменён на CUBIC.${plain}"
    else
        echo -e "${red}Не удалось заменить BBR на CUBIC. Проверьте конфигурацию системы.${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR уже включён!${plain}"
        before_show_menu
    fi

    # Включение BBR
    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        if [ -f "/etc/sysctl.conf" ]; then
            # Резервное копирование старых настроек из sysctl.conf, если есть
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        # Применяем только наш конфигурационный файл; `sysctl --system` пере-применил бы каждый
        # sysctl файл на хосте и выявил несвязанные ошибки из собственных настроек дистрибутива
        # (см. issue #5160)
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
        sysctl -p
    fi

    # Проверка что BBR включён
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR успешно включён.${plain}"
    else
        echo -e "${red}Не удалось включить BBR. Проверьте конфигурацию системы.${plain}"
    fi
}

update_shell() {
    # === Ссылка на ФОРК akса4y/ui ===
    if replace_xui_script "${REPO_URL}/raw/main/x-ui.sh" "true"; then
        LOGI "Скрипт обновления успешен, перезапустите скрипт"
        before_show_menu
    else
        echo ""
        LOGE "Не удалось загрузить скрипт, проверьте может ли машина подключиться к Github"
        before_show_menu
    fi
}

xui_pid() {
    ps -ef 2> /dev/null | grep -F "${xui_folder}/x-ui" | grep -v grep | awk 'NR==1 {print $1}'
}

signal_xui() {
    local sig="$1" pid
    pid="$(xui_pid)"
    if [[ -z "${pid}" ]]; then
        return 1
    fi
    kill -"${sig}" "${pid}" 2> /dev/null
}

# 0: запущен, 1: не запущен, 2: не установлен
check_status() {
    if [[ "${running_in_docker}" == "true" ]]; then
        if [[ ! -x "${xui_folder}/x-ui" ]]; then
            return 2
        fi
        if [[ -n "$(xui_pid)" ]]; then
            return 0
        else
            return 1
        fi
    fi
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "Панель установлена, не устанавливайте повторно"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "Сначала установите панель"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "Состояние панели: ${green}Запущена${plain}"
            show_enable_status
            ;;
        1)
            echo -e "Состояние панели: ${yellow}Не запущена${plain}"
            show_enable_status
            ;;
        2)
            echo -e "Состояние панели: ${red}Не установлена${plain}"
            ;;
    esac
    show_xray_status
    show_mtproto_status
}

show_enable_status() {
    if [[ "${running_in_docker}" == "true" ]]; then
        echo -e "Автозапуск: ${green}Управляется Docker${plain}"
        return
    fi
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "Автозапуск: ${green}Да${plain}"
    else
        echo -e "Автозапуск: ${red}Нет${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "Состояние xray: ${green}Запущен${plain}"
    else
        echo -e "Состояние xray: ${red}Не запущен${plain}"
    fi
}

# show_mtproto_status сообщает о каждом mtproto входящем mtg sidecar (один процесс на
# входящий, запускается вне xray). Молчит когда нет настроенного mtproto входящего.
show_mtproto_status() {
    local cfg_dir="${xui_folder}/bin/mtproto"
    local cfgs=()
    if [[ -d "${cfg_dir}" ]]; then
        for f in "${cfg_dir}"/mtg-*.toml; do
            [[ -e "$f" ]] && cfgs+=("$f")
        done
    fi
    [[ ${#cfgs[@]} -eq 0 ]] && return

    local running
    running=$(ps -ef | grep "mtg-linux" | grep -v "grep" | grep -oE 'mtg-[0-9]+\.toml')
    for f in "${cfgs[@]}"; do
        local name id bind
        name=$(basename "$f")
        id=$(echo "${name}" | sed -E 's/mtg-([0-9]+)\.toml/\1/')
        bind=$(grep -E '^[[:space:]]*bind-to' "$f" | head -1 | cut -d'"' -f2)
        if echo "${running}" | grep -qx "${name}"; then
            echo -e "mtproto входящий ${id} (${bind}): ${green}Запущен${plain}"
        else
            echo -e "mtproto входящий ${id} (${bind}): ${red}Не запущен${plain}"
        fi
    done
}

firewall_menu() {
    echo -e "${green}\t1.${plain} ${green}Установить${plain} файрвол"
    echo -e "${green}\t2.${plain} Список портов [нумерованный]"
    echo -e "${green}\t3.${plain} ${green}Открыть${plain} порты"
    echo -e "${green}\t4.${plain} ${red}Удалить${plain} порты из списка"
    echo -e "${green}\t5.${plain} ${green}Включить${plain} файрвол"
    echo -e "${green}\t6.${plain} ${red}Отключить${plain} файрвол"
    echo -e "${green}\t7.${plain} Статус файрвола"
    echo -e "${green}\t0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            ufw status numbered
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            ufw enable
            firewall_menu
            ;;
        6)
            ufw disable
            firewall_menu
            ;;
        7)
            ufw status verbose
            firewall_menu
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo "Файрвол ufw не установлен. Устанавливаем сейчас..."
        apt-get update
        apt-get install -y ufw
    else
        echo "Файрвол ufw уже установлен"
    fi

    # Проверка неактивен ли файрвол
    if ufw status | grep -q "Status: active"; then
        echo "Файрвол уже активен"
    else
        echo "Активация файрвола..."
        # Открытие необходимых портов
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #webPort
        ufw allow 2096/tcp #subport

        # Включение файрвола
        ufw --force enable
    fi
}

open_ports() {
    # Запрос пользователя ввести порты которые он хочет открыть
    read -rp "Введите порты которые хотите открыть (например 80,443,2053 или диапазон 400-500): " ports

    # Проверка корректности ввода
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "Ошибка: Неверный ввод. Введите список портов через запятую или диапазон портов (например 80,443,2053 или 400-500)." >&2
        exit 1
    fi

    # Открытие указанных портов через ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Разделение диапазона на начальный и конечный порты
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Открытие диапазона портов
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Открытие одного порта
            ufw allow "$port"
        fi
    done

    # Подтверждение что порты открыты
    echo "Открыты указанные порты:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Проверка что диапазон портов успешно открыт
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Проверка что отдельный порт успешно открыт
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Отображение текущих правил с номерами
    echo "Текущие правила UFW:"
    ufw status numbered

    # Запрос пользователя как он хочет удалить правила
    echo "Хотите удалить правила по:"
    echo "1) Номерам правил"
    echo "2) Портам"
    read -rp "Введите ваш выбор (1 или 2): " choice

    if [[ $choice -eq 1 ]]; then
        # Удаление по номерам правил
        read -rp "Введите номера правил которые хотите удалить (1, 2, и т.д.): " rule_numbers

        # Валидация ввода
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "Ошибка: Неверный ввод. Введите список номеров правил через запятую." >&2
            exit 1
        fi

        # Разделение номеров на массив
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Удаление правила по номеру
            ufw delete "$rule_number" || echo "Не удалось удалить правило номер $rule_number"
        done

        echo "Выбранные правила удалены."

    elif [[ $choice -eq 2 ]]; then
        # Удаление по портам
        read -rp "Введите порты которые хотите удалить (например 80,443,2053 или диапазон 400-500): " ports

        # Валидация ввода
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "Ошибка: Неверный ввод. Введите список портов через запятую или диапазон портов (например 80,443,2053 или 400-500)." >&2
            exit 1
        fi

        # Разделение портов на массив
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Разделение диапазона портов
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Удаление диапазона портов
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Удаление одного порта
                ufw delete allow "$port"
            fi
        done

        # Подтверждение удаления
        echo "Удалены указанные порты:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Проверка что диапазон портов удалён
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Проверка что отдельный порт удалён
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}Ошибка:${plain} Неверный выбор. Введите 1 или 2." >&2
        exit 1
    fi
}

update_all_geofiles() {
    local failed=0
    update_geofiles "main" || failed=1
    update_geofiles "IR" || failed=1
    update_geofiles "RU" || failed=1
    return $failed
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
        *)
            echo -e "${red}update_geofiles: неизвестный набор данных '${1}'${plain}"
            return 1
            ;;
    esac
    local failed=0 http_code
    for dat in "${dat_files[@]}"; do
        # Удаление суффикса для удалённого имени файла (например, geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        local dest="${xui_folder}/bin/${dat}.dat"
        local temp_file="${dest}.tmp.$$"
        rm -f "$temp_file"
        # -z (против живого файла, не временного) пропускает загрузку
        # (сервер отвечает 304) когда локальная копия уже актуальна.
        http_code=$(curl -sSfLRo "$temp_file" -z "$dest" -w '%{http_code}' \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat)
        if [[ $? -ne 0 ]]; then
            echo -e "${red}${dat}.dat: загрузка не удалась${plain}"
            rm -f "$temp_file"
            failed=1
        elif [[ "$http_code" == "304" ]]; then
            echo -e "${dat}.dat: уже актуален"
            rm -f "$temp_file"
        elif [[ ! -s "$temp_file" ]]; then
            echo -e "${red}${dat}.dat: загруженный файл пустой${plain}"
            rm -f "$temp_file"
            failed=1
        else
            mv -f "$temp_file" "$dest"
            if [[ $? -ne 0 ]]; then
                echo -e "${red}${dat}.dat: не удалось установить${plain}"
                rm -f "$temp_file"
                failed=1
            else
                echo -e "${green}${dat}.dat: обновлён${plain}"
                geo_updated=1
            fi
        fi
    done
    return $failed
}

run_geo_update() {
    local name="$1"
    shift
    geo_updated=0
    "$@"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Некоторые ${name} не удалось обновить. Проверьте ошибки выше.${plain}"
    elif [[ $geo_updated -eq 1 ]]; then
        echo -e "${green}${name} успешно обновлены!${plain}"
        restart
    else
        echo -e "${green}${name} уже актуальны, перезапуск не нужен.${plain}"
    fi
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} Все"
    echo -e "${green}\t0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            run_geo_update "наборы данных Loyalsoldier" update_geofiles "main"
            ;;
        2)
            run_geo_update "наборы данных chocolate4u" update_geofiles "IR"
            ;;
        3)
            run_geo_update "наборы данных runetfreedom" update_geofiles "RU"
            ;;
        4)
            run_geo_update "geo файлы" update_all_geofiles
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}

install_acme() {
    # Проверка установлен ли уже acme.sh
    if command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh уже установлен."
        return 0
    fi

    LOGI "Установка acme.sh..."
    cd ~ || return 1 # Убедиться что можно перейти в домашнюю директорию

    curl -s https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "Установка acme.sh не удалась."
        return 1
    else
        LOGI "Установка acme.sh успешна."
    fi

    return 0
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} Получить SSL (Домен)"
    echo -e "${green}\t2.${plain} Отозвать и удалить"
    echo -e "${green}\t3.${plain} Принудительно обновить"
    echo -e "${green}\t4.${plain} Показать существующие домены"
    echo -e "${green}\t5.${plain} Установить пути сертификата для панели"
    echo -e "${green}\t6.${plain} Получить SSL для IP адреса (6-дневный сертификат, автообновление)"
    echo -e "${green}\t0.${plain} Назад в главное меню"

    read -rp "Выберите опцию: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            ssl_cert_issue
            ssl_cert_issue_main
            ;;
        2)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "Не найдено сертификатов для отзыва."
            else
                echo "Существующие домены:"
                echo "$domains"
                read -rp "Введите домен из списка для отзыва и удаления сертификата: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    # Поток IP-сертификата (опция 6) хранит файлы в /root/cert/ip, но acme.sh
                    # отслеживает сертификат под фактическим IP адресом(ами). Разрешаем их чтобы
                    # состояние обновления также было удалено; иначе cron acme.sh воссоздаст удалённый сертификат.
                    local acme_ids="${domain}"
                    if [[ "${domain}" == "ip" ]]; then
                        acme_ids=$(~/.acme.sh/acme.sh --list 2> /dev/null | awk 'NR>1 {print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:')
                    fi
                    for id in ${acme_ids}; do
                        # Попытка отзыва в CA, затем удаление отслеживания обновления acme.sh.
                        ~/.acme.sh/acme.sh --revoke -d "${id}" 2> /dev/null
                        ~/.acme.sh/acme.sh --remove -d "${id}" 2> /dev/null
                        # --remove оставляет файлы сертификата на диске, так что удаляем директории состояния (RSA + ECC).
                        rm -rf ~/.acme.sh/"${id}" ~/.acme.sh/"${id}_ecc"
                    done
                    # Удаление локальных файлов сертификата для этого домена.
                    rm -rf "/root/cert/${domain}"
                    LOGI "Сертификат отозван и удалён для домена: ${domain}"

                    # Если панель в данный момент обслуживает сертификат этого домена, очищаем сохранённые пути
                    # чтобы она перестала загружать теперь удалённые файлы, затем перезапускаем.
                    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
                    if [[ "${existing_cert}" == "/root/cert/${domain}/"* ]]; then
                        ${xui_folder}/x-ui cert -reset
                        LOGI "Очищены пути сертификата панели ссылающиеся на ${domain}; перезапуск панели."
                        restart
                    fi
                else
                    echo "Введён неверный домен."
                fi
            fi
            ssl_cert_issue_main
            ;;
        3)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "Не найдено сертификатов для обновления."
            else
                echo "Существующие домены:"
                echo "$domains"
                read -rp "Введите домен из списка для обновления SSL сертификата: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --renew -d ${domain} --force
                    LOGI "Сертификат принудительно обновлён для домена: $domain"
                else
                    echo "Введён неверный домен."
                fi
            fi
            ssl_cert_issue_main
            ;;
        4)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "Не найдено сертификатов в /root/cert."
            else
                echo "Существующие домены и их пути:"
                for domain in $domains; do
                    local cert_path="/root/cert/${domain}/fullchain.pem"
                    local key_path="/root/cert/${domain}/privkey.pem"
                    if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                        echo -e "Домен: ${domain}"
                        echo -e "\tПуть к сертификату: ${cert_path}"
                        echo -e "\tПуть к приватному ключу: ${key_path}"
                    else
                        echo -e "Домен: ${domain} - Сертификат или ключ отсутствует."
                    fi
                done
            fi
            # Настроенный сертификат панели может находиться вне /root/cert
            # (например certbot в /etc/letsencrypt) — показываем и его (#5070).
            local panel_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
            if [[ -n "${panel_cert}" && "${panel_cert}" != /root/cert/* ]]; then
                echo -e "Сертификат панели (пользовательский путь): ${panel_cert}"
                if [[ -f "${panel_cert}" ]] && command -v openssl > /dev/null 2>&1; then
                    local panel_sans=$(openssl x509 -in "${panel_cert}" -noout -ext subjectAltName 2> /dev/null \
                        | grep -Eo 'DNS:[^,[:space:]]+' | cut -d: -f2 | tr '\n' ' ')
                    [[ -n "${panel_sans}" ]] && echo -e "\tПокрывает: ${panel_sans}"
                fi
            fi
            ssl_cert_issue_main
            ;;
        5)
            echo -e "${green}\t1.${plain} Использовать сертификат из /root/cert"
            echo -e "${green}\t2.${plain} Ввести пользовательские пути к файлам сертификата (например certbot, /etc/letsencrypt/...)"
            read -rp "Выберите опцию: " pathChoice
            if [[ "$pathChoice" == "2" ]]; then
                read -rp "Путь к файлу сертификата (fullchain): " webCertFile
                read -rp "Путь к файлу приватного ключа: " webKeyFile
                if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                    ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                    echo "Пути сертификата панели установлены:"
                    echo "  - Файл сертификата: $webCertFile"
                    echo "  - Файл приватного ключа: $webKeyFile"
                    restart
                else
                    echo "Файл сертификата или приватного ключа не найден."
                fi
                ssl_cert_issue_main
                return
            fi
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "Не найдено сертификатов."
            else
                echo "Доступные домены:"
                echo "$domains"
                read -rp "Выберите домен для установки путей панели: " domain

                if echo "$domains" | grep -qw "$domain"; then
                    local webCertFile="/root/cert/${domain}/fullchain.pem"
                    local webKeyFile="/root/cert/${domain}/privkey.pem"

                    if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                        echo "Пути панели установлены для домена: $domain"
                        echo "  - Файл сертификата: $webCertFile"
                        echo "  - Файл приватного ключа: $webKeyFile"
                        # Регистрация хука install-cert acme.sh чтобы автообновление копировало
                        # обновлённый сертификат в эти пути и перезагружало панель. Без него acme.sh
                        # обновляет но никогда не обновляет /root/cert, молча обслуживая устаревший сертификат.
                        if command -v ~/.acme.sh/acme.sh &> /dev/null && ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
                            ~/.acme.sh/acme.sh --installcert --force -d "${domain}" \
                                --key-file "${webKeyFile}" \
                                --fullchain-file "${webCertFile}" \
                                --reloadcmd "x-ui restart" 2>&1 || true
                            echo "Зарегистрирован хук автообновления acme.sh для ${domain}."
                        fi
                        restart
                    else
                        echo "Сертификат или приватный ключ не найден для домена: $domain."
                    fi
                else
                    echo "Введён неверный домен."
                fi
            fi
            ssl_cert_issue_main
            ;;
        6)
            echo -e "${yellow}SSL сертификат Let's Encrypt для IP адреса${plain}"
            echo -e "Это получит сертификат для IP вашего сервера используя профиль shortlived."
            echo -e "${yellow}Сертификат действителен ~6 дней, автообновление через cron задачу acme.sh.${plain}"
            echo -e "${yellow}Порт 80 должен быть открыт и доступен из интернета.${plain}"
            confirm "Хотите продолжить?" "y"
            if [[ $? == 0 ]]; then
                ssl_cert_issue_for_ip
            fi
            ssl_cert_issue_main
            ;;

        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            ssl_cert_issue_main
            ;;
    esac
}

ssl_cert_issue_for_ip() {
    LOGI "Запуск автоматической генерации SSL сертификата для IP сервера..."
    LOGI "Используется профиль Let's Encrypt shortlived (~6 дней валидности, автообновление)"

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')

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
        LOGI "Не удалось автоматически определить IP сервера ни от одного провайдера."
        while [[ -z "$server_ip" ]]; do
            read -rp "Введите публичный IPv4 адрес вашего сервера: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                LOGE "Неверный IPv4 адрес. Попробуйте снова."
                server_ip=""
            fi
        done
    fi

    LOGI "Обнаружен IP сервера: ${server_ip}"

    # Запрос опционального IPv6
    local ipv6_addr=""
    read -rp "Есть ли IPv6 адрес для включения? (оставьте пустым для пропуска): " ipv6_addr
    ipv6_addr="${ipv6_addr// /}" # Убираем пробелы

    # сначала проверяем acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh не найден, устанавливаем..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "Не удалось установить acme.sh"
            return 1
        fi
    fi

    # установка socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Неподдерживаемая ОС для автоматической установки socat"
            ;;
    esac

    # Создание директории для сертификата
    certPath="/root/cert/ip"
    mkdir -p "$certPath"

    # Сборка аргументов домена
    local domain_args="-d ${server_ip}"
    if [[ -n "$ipv6_addr" ]] && is_ipv6 "$ipv6_addr"; then
        domain_args="${domain_args} -d ${ipv6_addr}"
        LOGI "Включая IPv6 адрес: ${ipv6_addr}"
    fi

    # Выбор порта для HTTP-01 слушателя (по умолчанию 80, разрешено переопределение)
    local WebPort=""
    read -rp "Порт для ACME HTTP-01 слушателя (по умолчанию 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        LOGE "Указан неверный порт. Возврат к 80."
        WebPort=80
    fi
    LOGI "Используется порт ${WebPort} для выпуска сертификата для IP: ${server_ip}"
    if [[ "${WebPort}" -ne 80 ]]; then
        LOGI "Напоминание: Let's Encrypt всё равно обращается к порту 80; перенаправьте внешний порт 80 на ${WebPort} для валидации."
    fi

    while true; do
        if is_port_in_use "${WebPort}"; then
            LOGI "Порт ${WebPort} в данный момент занят."

            local alt_port=""
            read -rp "Введите другой порт для автономного слушателя acme.sh (оставьте пустым для отмены): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                LOGE "Порт ${WebPort} занят; невозможно продолжить выпуск."
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                LOGE "Указан неверный порт."
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            LOGI "Порт ${WebPort} свободен и готов для автономной валидации."
            break
        fi
    done

    # Команда перезагрузки - перезапускает панель после обновления
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null"

    # выпуск сертификата для IP с профилем shortlived
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        LOGE "Не удалось выпустить сертификат для IP: ${server_ip}"
        LOGE "Убедитесь что порт ${WebPort} открыт и сервер доступен из интернета"
        # Очистка данных acme.sh для IPv4 и IPv6 если указаны
        rm -rf ~/.acme.sh/${server_ip} ~/.acme.sh/${server_ip}_ecc 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} ~/.acme.sh/${ipv6_addr}_ecc 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    else
        LOGI "Сертификат успешно выпущен для IP: ${server_ip}"
    fi

    # Установка сертификата
    # Примечание: acme.sh может сообщить "Reload error" и завершиться с ненулевым кодом если reloadcmd падает,
    # но файлы сертификата всё равно устанавливаются. Проверяем наличие файлов вместо кода выхода.
    ~/.acme.sh/acme.sh --installcert --force -d ${server_ip} \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Проверка существования файлов сертификата (не полагаемся на код выхода - сбой reloadcmd вызывает ненулевой)
    if [[ ! -f "${certPath}/fullchain.pem" || ! -f "${certPath}/privkey.pem" ]]; then
        LOGE "Файлы сертификата не найдены после установки"
        # Очистка данных acme.sh для IPv4 и IPv6 если указаны
        rm -rf ~/.acme.sh/${server_ip} ~/.acme.sh/${server_ip}_ecc 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} ~/.acme.sh/${ipv6_addr}_ecc 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    fi

    LOGI "Файлы сертификата успешно установлены"

    # включение автообновления
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Запрос пользователя настроить пути панели после успешной установки сертификата
    local webCertFile="${certPath}/fullchain.pem"
    local webKeyFile="${certPath}/privkey.pem"

    read -rp "Хотите установить этот сертификат для панели? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "Пути панели установлены для IP: $server_ip"
            LOGI "  - Файл сертификата: $webCertFile"
            LOGI "  - Файл приватного ключа: $webKeyFile"
            LOGI "  - Валидность: ~6 дней (автообновление через cron acme.sh)"
            echo -e "${green}URL доступа: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            LOGI "Панель будет перезапущена для применения SSL сертификата..."
            restart
        else
            LOGE "Ошибка: Файл сертификата или приватного ключа не найден для IP: $server_ip."
            return 1
        fi
    else
        LOGI "Пропуск настройки путей панели."
    fi

    return 0
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # сначала проверяем acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "acme.sh не найден. Установим его."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "установка acme не удалась, проверьте логи"
            exit 1
        fi
    fi

    # установка socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Неподдерживаемая ОС для автоматической установки socat"
            ;;
    esac
    if [ $? -ne 0 ]; then
        LOGE "установка socat не удалась, проверьте логи"
        exit 1
    else
        LOGI "установка socat успешна..."
    fi

    # получаем домен и проверяем его
    local domain=""
    while true; do
        read -rp "Введите имя домена: " domain
        domain="${domain// /}" # Убираем пробелы

        if [[ -z "$domain" ]]; then
            LOGE "Имя домена не может быть пустым. Попробуйте снова."
            continue
        fi

        if ! is_domain "$domain"; then
            LOGE "Неверный формат домена: ${domain}. Введите действительное имя домена."
            continue
        fi

        break
    done
    LOGD "Ваш домен: ${domain}, проверяем..."
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
            LOGI "Найден существующий сертификат для ${domain}, будет переиспользован."
            [[ -n "${certInfo}" ]] && LOGI "${certInfo}"
        else
            LOGW "Найдено неполное состояние acme.sh для ${domain} (нет действительных файлов сертификата); очищаем и перевыпускаем."
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
    fi
    if [[ ${cert_exists} -eq 0 ]]; then
        LOGI "Ваш домен готов для выпуска сертификатов..."
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
        LOGE "Ваш ввод ${WebPort} неверен, будет использован порт 80 по умолчанию."
        WebPort=80
    fi
    LOGI "Будет использован порт: ${WebPort} для выпуска сертификатов. Убедитесь что этот порт открыт."

    if [[ ${cert_exists} -eq 0 ]]; then
        # выпуск сертификата
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            LOGE "Не удалось выпустить сертификат, проверьте логи."
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
            exit 1
        else
            LOGE "Выпуск сертификата успешен, установка сертификатов..."
        fi
    else
        LOGI "Используется существующий сертификат, установка сертификатов..."
    fi

    reloadCmd="x-ui restart"

    LOGI "Команда --reloadcmd по умолчанию для ACME: ${yellow}x-ui restart"
    LOGI "Эта команда будет выполняться при каждом выпуске и обновлении сертификата."
    read -rp "Хотите изменить --reloadcmd для ACME? (y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} Предустановка: systemctl reload nginx ; x-ui restart"
        echo -e "${green}\t2.${plain} Ввести свою команду"
        echo -e "${green}\t0.${plain} Оставить reloadcmd по умолчанию"
        read -rp "Выберите опцию: " choice
        case "$choice" in
            1)
                LOGI "Reloadcmd: systemctl reload nginx ; x-ui restart"
                reloadCmd="systemctl reload nginx ; x-ui restart"
                ;;
            2)
                LOGD "Рекомендуется ставить перезапуск x-ui в конец, чтобы не было ошибки если другие сервисы падают"
                read -rp "Введите ваш reloadcmd (пример: systemctl reload nginx ; x-ui restart): " reloadCmd
                LOGI "Ваш reloadcmd: ${reloadCmd}"
                ;;
            *)
                LOGI "Оставляется reloadcmd по умолчанию"
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
        LOGI "Установка сертификата успешна, включение автообновления..."
    else
        LOGE "Установка сертификата не удалась, выход."
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
        exit 1
    fi

    # включение автообновления
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "Автообновление не удалось, детали сертификата:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
        exit 1
    else
        LOGI "Автообновление успешно, детали сертификата:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Запрос пользователя настроить пути панели после успешной установки сертификата
    read -rp "Хотите установить этот сертификат для панели? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "Пути панели установлены для домена: $domain"
            LOGI "  - Файл сертификата: $webCertFile"
            LOGI "  - Файл приватного ключа: $webKeyFile"
            echo -e "${green}URL доступа: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "Ошибка: Файл сертификата или приватного ключа не найден для домена: $domain."
        fi
    else
        LOGI "Пропуск настройки путей панели."
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    LOGI "****** Инструкция по использованию ******"
    LOGI "Выполните шаги ниже для завершения процесса:"
    LOGI "1. Cloudflare API Token (рекомендуется, область Zone:DNS:Edit) или Global API Key + зарегистрированный email."
    LOGI "2. Имя домена."
    LOGI "3. После выпуска сертификата вам будет предложено установить сертификат для панели (опционально)."
    LOGI "4. Скрипт также поддерживает автоматическое обновление SSL сертификата после установки."

    confirm "Подтверждаете информацию и хотите продолжить? [y/n]" "y"

    if [ $? -eq 0 ]; then
        # Сначала проверяем acme.sh
        if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
            echo "acme.sh не найден. Установим его."
            install_acme
            if [ $? -ne 0 ]; then
                LOGE "Установка acme не удалась, проверьте логи."
                exit 1
            fi
        fi

        CF_Domain=""

        LOGD "Установите имя домена:"
        read -rp "Введите ваш домен здесь: " CF_Domain
        LOGD "Ваше имя домена установлено на: ${CF_Domain}"

        # Учётные данные Cloudflare API: API Token (рекомендуется, ограничен одной зоной)
        # или Global API Key для всего аккаунта. acme.sh читает CF_Token для токенов,
        # или CF_Key + CF_Email для Global Key.
        CF_KeyType=""
        read -rp "Используете Cloudflare API Token или Global API Key? (t/g) [По умолчанию t]: " CF_KeyType
        CF_KeyType=${CF_KeyType:-t}

        if [[ "$CF_KeyType" == "g" || "$CF_KeyType" == "G" ]]; then
            CF_GlobalKey=""
            CF_AccountEmail=""
            LOGD "Установите Global API Key:"
            read -rp "Введите ваш ключ здесь: " CF_GlobalKey
            LOGD "Установите зарегистрированный email:"
            read -rp "Введите ваш email здесь: " CF_AccountEmail
            export CF_Key="${CF_GlobalKey}"
            export CF_Email="${CF_AccountEmail}"
        else
            CF_ApiToken=""
            LOGD "Установите API Token:"
            read -rp "Введите ваш токен здесь: " CF_ApiToken
            export CF_Token="${CF_ApiToken}"
        fi

        # Установка CA по умолчанию на Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        if [ $? -ne 0 ]; then
            LOGE "Default CA, Let'sEncrypt не удалось, скрипт завершается..."
            exit 1
        fi

        # Выпуск сертификата используя Cloudflare DNS
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
        if [ $? -ne 0 ]; then
            LOGE "Выпуск сертификата не удался, скрипт завершается..."
            exit 1
        else
            LOGI "Сертификат успешно выпущен, установка..."
        fi

        # Установка сертификата
        certPath="/root/cert/${CF_Domain}"
        if [ -d "$certPath" ]; then
            rm -rf ${certPath}
        fi

        mkdir -p ${certPath}
        if [ $? -ne 0 ]; then
            LOGE "Не удалось создать директорию: ${certPath}"
            exit 1
        fi

        reloadCmd="x-ui restart"

        LOGI "Команда --reloadcmd по умолчанию для ACME: ${yellow}x-ui restart"
        LOGI "Эта команда будет выполняться при каждом выпуске и обновлении сертификата."
        read -rp "Хотите изменить --reloadcmd для ACME? (y/n): " setReloadcmd
        if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
            echo -e "\n${green}\t1.${plain} Предустановка: systemctl reload nginx ; x-ui restart"
            echo -e "${green}\t2.${plain} Ввести свою команду"
            echo -e "${green}\t0.${plain} Оставить reloadcmd по умолчанию"
            read -rp "Выберите опцию: " choice
            case "$choice" in
                1)
                    LOGI "Reloadcmd: systemctl reload nginx ; x-ui restart"
                    reloadCmd="systemctl reload nginx ; x-ui restart"
                    ;;
                2)
                    LOGD "Рекомендуется ставить перезапуск x-ui в конец, чтобы не было ошибки если другие сервисы падают"
                    read -rp "Введите ваш reloadcmd (пример: systemctl reload nginx ; x-ui restart): " reloadCmd
                    LOGI "Ваш reloadcmd: ${reloadCmd}"
                    ;;
                *)
                    LOGI "Оставляется reloadcmd по умолчанию"
                    ;;
            esac
        fi
        ~/.acme.sh/acme.sh --installcert --force -d ${CF_Domain} -d *.${CF_Domain} \
            --key-file ${certPath}/privkey.pem \
            --fullchain-file ${certPath}/fullchain.pem --reloadcmd "${reloadCmd}"

        if [ $? -ne 0 ]; then
            LOGE "Установка сертификата не удалась, скрипт завершается..."
            exit 1
        else
            LOGI "Сертификат успешно установлен, включение автоматических обновлений..."
        fi

        # Включение автообновления
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "Настройка автообновления не удалась, скрипт завершается..."
            exit 1
        else
            LOGI "Сертификат установлен и автообновление включено. Конкретная информация ниже:"
            ls -lah ${certPath}/*
            chmod 600 ${certPath}/privkey.pem
            chmod 644 ${certPath}/fullchain.pem
        fi

        # Запрос пользователя настроить пути панели после успешной установки сертификата
        read -rp "Хотите установить этот сертификат для панели? (y/n): " setPanel
        if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
            local webCertFile="${certPath}/fullchain.pem"
            local webKeyFile="${certPath}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                LOGI "Пути панели установлены для домена: $CF_Domain"
                LOGI "  - Файл сертификата: $webCertFile"
                LOGI "  - Файл приватного ключа: $webKeyFile"
                echo -e "${green}URL доступа: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                restart
            else
                LOGE "Ошибка: Файл сертификата или приватного ключа не найден для домена: $CF_Domain."
            fi
        else
            LOGI "Пропуск настройки путей панели."
        fi
    else
        show_menu
    fi
}

run_speedtest() {
    # Проверка установлен ли уже Speedtest
    if ! command -v speedtest &> /dev/null; then
        # Если не установлен, определяем метод установки
        if command -v snap &> /dev/null; then
            # Используем snap для установки Speedtest
            echo "Установка Speedtest через snap..."
            snap install speedtest
        else
            # Резервный вариант через менеджеры пакетов
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "Ошибка: Менеджер пакетов не найден. Возможно вам нужно установить Speedtest вручную."
                return 1
            else
                echo "Установка Speedtest через $pkg_manager..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-zA-Z]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    echo -e "\n${green}\t1.${plain} Установить Fail2ban и настроить ограничение IP"
    echo -e "${green}\t2.${plain} Изменить длительность блокировки"
    echo -e "${green}\t3.${plain} Разблокировать всех"
    echo -e "${green}\t4.${plain} Логи блокировок"
    echo -e "${green}\t5.${plain} Заблокировать IP адрес"
    echo -e "${green}\t6.${plain} Разблокировать IP адрес"
    echo -e "${green}\t7.${plain} Логи в реальном времени"
    echo -e "${green}\t8.${plain} Статус сервиса"
    echo -e "${green}\t9.${plain} Перезапуск сервиса"
    echo -e "${green}\t10.${plain} Удалить Fail2ban и ограничение IP"
    echo -e "${green}\t0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            confirm "Продолжить установку Fail2ban и ограничения IP?" "y"
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            read -rp "Введите новую длительность блокировки в минутах [по умолчанию 30]: " NUM
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                echo -e "${red}${NUM} не число! Попробуйте снова.${plain}"
            fi
            iplimit_main
            ;;
        3)
            confirm "Продолжить разблокировку всех из jail ограничения IP?" "y"
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                echo -e "${green}Все пользователи успешно разблокированы.${plain}"
                iplimit_main
            else
                echo -e "${yellow}Отменено.${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            read -rp "Введите IP адрес который хотите заблокировать: " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                echo -e "${green}IP адрес ${ban_ip} успешно заблокирован.${plain}"
            else
                echo -e "${red}Неверный формат IP адреса! Попробуйте снова.${plain}"
            fi
            iplimit_main
            ;;
        6)
            read -rp "Введите IP адрес который хотите разблокировать: " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                echo -e "${green}IP адрес ${unban_ip} успешно разблокирован.${plain}"
            else
                echo -e "${red}Неверный формат IP адреса! Попробуйте снова.${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            iplimit_main
            ;;
    esac
}

setup_fail2ban_iplimit() {
    # Учитываем тот же переключатель что использует панель (isFail2BanEnabled): включён когда
    # переменная не установлена или точно "true"; любое другое явное значение означает что
    # оператор отказался, так что ничего не делаем вместо установки fail2ban который панель игнорирует.
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        echo -e "${yellow}XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}, пропуск настройки Fail2ban.${plain}\n"
        return 0
    fi

    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}Fail2ban не установлен. Устанавливаем сейчас...!${plain}\n"

        # Устанавливаем fail2ban вместе с nftables. Последние пакеты fail2ban
        # по умолчанию используют `banaction = nftables-multiport` в /etc/fail2ban/jail.conf,
        # но пакет `nftables` не подтягивается как зависимость на большинстве
        # минимальных серверных образов (Debian 12+, Ubuntu 24+, свежий RHEL-семейство).
        # Без `nft` в PATH jail sshd по умолчанию не может блокировать с
        #   stderr: '/bin/sh: 1: nft: not found'
        # хотя наш собственный jail 3x-ipl использует iptables. Включение бинарника
        # при установке предотвращает этот запутанный спам логов для новых установок.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 2400 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                dnf -y update && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum update -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf -y update && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Syu --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}Неподдерживаемая операционная система. Проверьте скрипт и установите необходимые пакеты вручную.${plain}\n"
                return 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Установка Fail2ban не удалась.${plain}\n"
            return 1
        fi

        echo -e "${green}Fail2ban успешно установлен!${plain}\n"
    else
        echo -e "${yellow}Fail2ban уже установлен.${plain}\n"
    fi

    echo -e "${green}Настройка ограничения IP...${plain}\n"

    # убедимся что нет конфликтов для файлов jail
    iplimit_remove_conflicts

    # Проверка существования файла лога
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Проверка существования файла лога сервиса чтобы fail2ban не возвращал ошибку
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Создание файлов jail iplimit
    # мы не передавали bantime здесь чтобы использовать значение по умолчанию
    create_iplimit_jails

    # Запуск fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}Ограничение IP успешно установлено и настроено!${plain}\n"
    return 0
}

# install_iplimit — интерактивная (меню) точка входа: запускает общую
# настройку и затем возвращается в меню. Неинтерактивный путь установщика использует
# setup_fail2ban_iplimit напрямую через `x-ui setup-fail2ban`.
install_iplimit() {
    setup_fail2ban_iplimit
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} Только удалить конфигурации ограничения IP"
    echo -e "${green}\t2.${plain} Удалить Fail2ban и ограничение IP"
    echo -e "${green}\t0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}Ограничение IP успешно удалено!${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}Неподдерживаемая операционная система. Удалите Fail2ban вручную.${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban и ограничение IP успешно удалены!${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}Проверка логов блокировок...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Сервис Fail2ban не запущен!${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Сервис Fail2ban не запущен!${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}Недавние системные активности блокировок из fail2ban.log:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}Недавних системных активностей блокировок не найдено${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}Записи лога блокировок 3X-IPL:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}Записей блокировок не найдено${plain}"
        else
            echo -e "${yellow}Файл лога блокировок пустой${plain}"
        fi
    else
        echo -e "${red}Файл лога блокировок не найден по адресу: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}Текущий статус jail:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Не удалось получить статус jail${plain}"
}

create_iplimit_jails() {
    # Использование bantime по умолчанию если не передан => 30 минут
    local bantime="${1:-30}"

    # Раскомментирование 'allowipv6 = auto' в fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # На Debian 12+ и Ubuntu 22.04+ бэкенд fail2ban по умолчанию должен быть изменён на systemd
    if [[ ( "${release}" == "debian" && ${os_version} -ge 12 ) || ( "${release}" == "ubuntu" && ${os_version} -ge 2200 ) ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=1
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # Порты для исключения из блокировки чтобы клиент прокси с превышением лимита никогда не заблокировал
    # администратору доступ к SSH или панели. Блокировка всё равно покрывает каждый другой
    # TCP и UDP порт (включая все входящие Xray, например UDP-based Hysteria2), так что
    # ограничение IP продолжает работать для входящих добавленных позже без регенерации этих файлов.
    local ssh_ports
    ssh_ports=$(grep -oP '^[[:space:]]*Port[[:space:]]+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | paste -sd, -)
    [[ -z "${ssh_ports}" ]] && ssh_ports="22"
    local panel_port
    panel_port=$(${xui_folder}/x-ui setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    local exempt_ports="${ssh_ports}"
    [[ -n "${panel_port}" ]] && exempt_ports="${exempt_ports},${panel_port}"

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> заблокирован на <bantime> секунд." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> разблокирован." >> ${iplimit_banned_log_path}

[Init]
name = default
chain = INPUT
exemptports = ${exempt_ports}
EOF

    echo -e "${green}Файлы jail ограничения IP созданы с bantime ${bantime} минут.${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Проверка конфигурации [3x-ipl] в файле jail и её удаление
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}Удаление конфликтов [3x-ipl] в jail (${file})!${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
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

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        echo -e "${green}Панель защищена SSL.${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        echo -e "\n${red}Предупреждение: Не найдено Cert и Key! Панель не защищена.${plain}"
        echo "Получите сертификат или настройте SSH port forwarding."
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        echo -e "\n${green}Текущая конфигурация SSH Port Forwarding:${plain}"
        echo -e "Стандартная команда SSH:"
        echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nЕсли используете SSH ключ:"
        echo -e "${yellow}ssh -i <путь_к_ключу> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nПосле подключения, доступ к панели по адресу:"
        echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
    fi

    echo -e "\nВыберите опцию:"
    echo -e "${green}1.${plain} Установить listen IP"
    echo -e "${green}2.${plain} Очистить listen IP"
    echo -e "${green}0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " num

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                echo -e "\nlistenIP не настроен. Выберите опцию:"
                echo -e "1. Использовать IP по умолчанию (127.0.0.1)"
                echo -e "2. Установить пользовательский IP"
                read -rp "Выберите опцию (1 или 2): " listen_choice

                config_listenIP="127.0.0.1"
                [[ "$listen_choice" == "2" ]] && read -rp "Введите пользовательский IP для прослушивания: " config_listenIP

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                echo -e "${green}listen IP установлен на ${config_listenIP}.${plain}"
                echo -e "\n${green}Конфигурация SSH Port Forwarding:${plain}"
                echo -e "Стандартная команда SSH:"
                echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\nЕсли используете SSH ключ:"
                echo -e "${yellow}ssh -i <путь_к_ключу> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\nПосле подключения, доступ к панели по адресу:"
                echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                restart
            else
                config_listenIP="${existing_listenIP}"
                echo -e "${green}Текущий listen IP уже установлен на ${config_listenIP}.${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            echo -e "${green}Listen IP очищен.${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

# Управление сервисом PostgreSQL (для панелей настроенных с XUI_DB_TYPE=postgres).

postgresql_installed() {
    command -v pg_lsclusters > /dev/null 2>&1 || command -v psql > /dev/null 2>&1 || command -v postgres > /dev/null 2>&1
}

# Выводит "ВЕРСИЯ КЛАСТЕР" первого настроенного кластера на установках Debian-стиля (например "16 main").
pg_cluster_info() {
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters 2> /dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $2; exit}'
    fi
}

# Разрешает systemd unit используемый для управления сервером PostgreSQL.
pg_systemd_unit() {
    local info ver cluster
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        echo "postgresql@${ver}-${cluster}"
    else
        echo "postgresql"
    fi
}

postgresql_status() {
    if ! postgresql_installed; then
        LOGE "PostgreSQL похоже не установлен на этой системе."
        return 1
    fi
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters
    else
        systemctl status "$(pg_systemd_unit)" --no-pager
    fi
    echo ""
    if command -v ss > /dev/null 2>&1; then
        local listening
        listening=$(ss -ltnp 2> /dev/null | grep ':5432')
        if [[ -n "$listening" ]]; then
            echo -e "${green}PostgreSQL слушает на порту 5432:${plain}"
            echo "$listening"
        else
            echo -e "${red}Ничего не слушает на порту 5432 - база данных не запущена.${plain}"
        fi
    fi
}

postgresql_start() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql start
    else
        systemctl start "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_stop() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop
    else
        systemctl stop "$(pg_systemd_unit)"
    fi
    LOGI "Сигнал остановки PostgreSQL отправлен."
}

postgresql_restart() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql restart
    else
        systemctl restart "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_enable() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-update add postgresql default
    else
        systemctl enable "$(pg_systemd_unit)"
    fi
    if [[ $? == 0 ]]; then
        LOGI "PostgreSQL настроен на автозапуск при загрузке."
    else
        LOGE "Не удалось включить автозапуск PostgreSQL."
    fi
}

postgresql_log() {
    pg_require_installed || return 1
    local info ver cluster logfile
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        logfile="/var/log/postgresql/postgresql-${ver}-${cluster}.log"
    fi
    if [[ -n "$logfile" && -f "$logfile" ]]; then
        tail -n 40 "$logfile"
    elif command -v journalctl > /dev/null 2>&1; then
        journalctl -u "$(pg_systemd_unit)" -n 40 --no-pager
    else
        LOGE "Лог PostgreSQL не найден."
    fi
}

pg_require_installed() {
    if ! postgresql_installed; then
        LOGE "PostgreSQL не установлен. Сначала используйте опцию 1 (Установить PostgreSQL) в этом меню."
        return 1
    fi
}

# Полностью удаляет сервер PostgreSQL и ВСЕ его базы данных из системы.
# Защищено явным подтверждением потому что это общесистемно и необратимо:
# любое другое приложение использующее этот экземпляр PostgreSQL также потеряет свои данные. Зеркалирует
# имена пакетов используемые pg_install_local() чтобы правильные пакеты удалялись для каждого дистрибутива.
purge_postgresql() {
    echo ""
    echo -e "${yellow}Эта панель использовала PostgreSQL.${plain}"
    echo -e "${red}ВНИМАНИЕ:${plain} полная очистка удаляет сервер PostgreSQL и ${red}ВСЕ${plain} его базы данных на"
    echo -e "этой машине, включая используемые другими приложениями. Это нельзя отменить."
    confirm "Также полностью очистить PostgreSQL и удалить все его данные?" "n"
    if [[ $? != 0 ]]; then
        LOGI "PostgreSQL оставлен установленным; его данные не были удалены."
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop 2> /dev/null
        rc-update del postgresql 2> /dev/null
    else
        systemctl stop "$(pg_systemd_unit)" 2> /dev/null
        systemctl disable "$(pg_systemd_unit)" 2> /dev/null
    fi

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get -y --purge remove 'postgresql*'
            apt-get -y autoremove --purge
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf remove -y postgresql postgresql-server postgresql-contrib
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum remove -y postgresql postgresql-server postgresql-contrib
            else
                dnf remove -y postgresql postgresql-server postgresql-contrib
            fi
            ;;
        arch | manjaro | parch)
            pacman -Rns --noconfirm postgresql
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q remove -y postgresql postgresql-server postgresql-contrib
            ;;
        alpine)
            apk del postgresql postgresql-contrib postgresql-client
            ;;
        *)
            LOGE "Неподдерживаемый дистрибутив для автоматической полной очистки PostgreSQL: ${release}. Удалите его вручную."
            return 1
            ;;
    esac

    rm -rf /var/lib/postgresql /var/lib/pgsql /var/lib/postgres /etc/postgresql
    LOGI "PostgreSQL полностью очищен."
}

# Устанавливает локальный сервер PostgreSQL и создаёт выделенного пользователя/базу данных xui.
# Прогресс идёт в stderr; при успехе DSN подключения выводится в stdout чтобы
# вызывающие могли его захватить. Зеркалирует install_postgres_local() из install.sh, так что
# панель может быть настроена без повторного запуска удалённого скрипта установки.
pg_install_local() {
    local pg_user pg_pass pg_db pg_host pg_port
    pg_pass=$(gen_random_string 24)
    pg_db="xui"
    pg_host="127.0.0.1"
    pg_port="5432"

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

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

# Устанавливает клиентские инструменты PostgreSQL (pg_dump/pg_restore) используемые резервным копированием в панели.
pg_ensure_client() {
    if command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1; then
        return 0
    fi
    echo -e "${yellow}Установка клиентских инструментов PostgreSQL (pg_dump/pg_restore)...${plain}" >&2
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

# Записывает XUI_DB_TYPE/XUI_DB_DSN в файл окружения сервиса, сохраняя другие записи.
pg_write_env() {
    local dsn="$1" envfile
    envfile="$(xui_env_file_path)"
    install -d -m 755 "$(dirname "$envfile")"
    touch "$envfile"
    sed -i '/^XUI_DB_TYPE=/d; /^XUI_DB_DSN=/d' "$envfile"
    {
        echo "XUI_DB_TYPE=postgres"
        echo "XUI_DB_DSN=${dsn}"
    } >> "$envfile"
    chmod 600 "$envfile"
}

pg_install_server_action() {
    if postgresql_installed; then
        LOGI "PostgreSQL уже кажется установлен на этой системе."
        confirm "Всё равно запустить настройку (гарантирует существование базы данных/пользователя xui)?" "n" || return 0
    fi
    LOGI "Установка сервера PostgreSQL и создание выделенного пользователя/базы данных..."
    local dsn
    dsn=$(pg_install_local)
    if [[ $? -ne 0 || -z "$dsn" ]]; then
        LOGE "Установка PostgreSQL не удалась."
        return 1
    fi
    PG_LAST_DSN="$dsn"
    pg_ensure_client || LOGE "Не удалось установить pg_dump/pg_restore (резервное копирование БД панели может быть недоступно)."
    echo ""
    LOGI "PostgreSQL установлен и готов."
    echo -e "${green}DSN подключения:${plain} ${dsn}"
    echo -e "${yellow}Используйте опцию 2 для миграции ваших данных SQLite и переключения панели на PostgreSQL.${plain}"
}

# Копирует текущие данные SQLite в PostgreSQL, затем переключает панель.
migrate_to_postgres() {
    if [[ ! -x "${xui_folder}/x-ui" ]]; then
        LOGE "x-ui не установлен."
        return 1
    fi
    echo ""
    echo -e "${yellow}Это копирует ваши текущие данные SQLite в базу данных PostgreSQL,${plain}"
    echo -e "${yellow}затем переключает панель на PostgreSQL и перезапускает её.${plain}"
    echo -e "${red}Любые существующие таблицы панели в назначении будут очищены и перезаписаны.${plain}"
    confirm "Продолжить?" "n" || return 0

    local dsn="" pg_mode
    if [[ -n "$PG_LAST_DSN" ]]; then
        echo -e "База данных PostgreSQL была создана в этой сессии:"
        echo -e "  ${green}${PG_LAST_DSN}${plain}"
        confirm "Мигрировать в эту базу данных?" "y" && dsn="$PG_LAST_DSN"
    fi

    if [[ -z "$dsn" ]]; then
        echo ""
        echo -e "${green}\t1.${plain} Установить PostgreSQL локально и создать выделенного пользователя/БД (рекомендуется)"
        echo -e "${green}\t2.${plain} Использовать существующий сервер PostgreSQL (введите DSN)"
        read -rp "Выберите [1]: " pg_mode
        pg_mode="${pg_mode:-1}"
        if [[ "$pg_mode" == "2" ]]; then
            while [[ -z "$dsn" ]]; do
                read -rp "Введите PostgreSQL DSN (postgres://user:pass@host:port/dbname?sslmode=disable): " dsn
                dsn="${dsn// /}"
            done
        else
            LOGI "Установка PostgreSQL локально (это может занять некоторое время)..."
            dsn=$(pg_install_local)
            if [[ $? -ne 0 || -z "$dsn" ]]; then
                LOGE "Установка PostgreSQL не удалась. Прерывание миграции."
                return 1
            fi
            PG_LAST_DSN="$dsn"
        fi
    fi

    pg_ensure_client || LOGE "Не удалось установить pg_dump/pg_restore (резервное копирование/восстановление БД в панели может быть недоступно)."

    LOGI "Остановка панели для получения согласованного снимка..."
    stop 0 > /dev/null 2>&1

    echo ""
    LOGI "Миграция данных в PostgreSQL..."
    if ! ${xui_folder}/x-ui migrate-db --dsn "$dsn"; then
        LOGE "Миграция не удалась. Панель НЕ была переключена на PostgreSQL."
        start 0 > /dev/null 2>&1
        return 1
    fi

    pg_write_env "$dsn"
    LOGI "Записаны настройки базы данных в $(xui_env_file_path) (XUI_DB_TYPE=postgres)."
    LOGI "Перезапуск панели на PostgreSQL..."
    restart 0
    sleep 1
    if check_status; then
        LOGI "Миграция завершена. Панель теперь работает на PostgreSQL."
    else
        LOGE "Панель не запустилась. Проверьте логи (опция 16). Ваши данные SQLite остались нетронутыми."
    fi
}

postgresql_menu() {
    echo -e "${green}\t1.${plain} ${green}Установить${plain} PostgreSQL (сервер + клиент + БД xui)"
    echo -e "${green}\t2.${plain} Мигрировать SQLite ${green}->${plain} PostgreSQL"
    echo -e "${green}\t3.${plain} Статус (кластеры и порт 5432)"
    echo -e "${green}\t4.${plain} ${green}Запустить${plain} PostgreSQL"
    echo -e "${green}\t5.${plain} ${red}Остановить${plain} PostgreSQL"
    echo -e "${green}\t6.${plain} Перезапустить PostgreSQL"
    echo -e "${green}\t7.${plain} ${green}Включить${plain} автозапуск при загрузке"
    echo -e "${green}\t8.${plain} Просмотр лога PostgreSQL"
    echo -e "${green}\t9.${plain} Конвертировать SQLite ${green}.db <-> .dump${plain}"
    echo -e "${green}\t0.${plain} Назад в главное меню"
    read -rp "Выберите опцию: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            pg_install_server_action
            postgresql_menu
            ;;
        2)
            migrate_to_postgres
            postgresql_menu
            ;;
        3)
            postgresql_status
            postgresql_menu
            ;;
        4)
            postgresql_start
            postgresql_menu
            ;;
        5)
            postgresql_stop
            postgresql_menu
            ;;
        6)
            postgresql_restart
            postgresql_menu
            ;;
        7)
            postgresql_enable
            postgresql_menu
            ;;
        8)
            postgresql_log
            postgresql_menu
            ;;
        9)
            migrate_db_prompt
            postgresql_menu
            ;;
        *)
            echo -e "${red}Неверная опция. Выберите корректный номер.${plain}\n"
            postgresql_menu
            ;;
    esac
}

# Конвертация между базой данных SQLite панели и переносимым файлом .dump (SQL текст)
# используя поставляемый бинарник x-ui. Без аргументов выгружает установленную
# базу данных панели; опциональный второй аргумент переопределяет путь вывода.
#   x-ui migrateDB [file.db|file.dump] [output]
migrate_db() {
    local input="$1" output="$2"
    local default_db="/etc/x-ui/x-ui.db"
    local bin="${xui_folder}/x-ui"

    [[ -z "$input" ]] && input="$default_db"

    if [[ ! -x "$bin" ]]; then
        LOGE "Бинарник x-ui не найден по адресу ${bin}. Панель установлена?"
        return 1
    fi

    if ! "$bin" migrate-db -h 2>&1 | grep -q -- '-dump'; then
        LOGE "Эта сборка x-ui пока не поддерживает конвертацию .db <-> .dump."
        LOGE "Сначала обновите панель (x-ui update) до версии с 'migrate-db --dump/--restore'."
        return 1
    fi

    if [[ ! -f "$input" ]]; then
        LOGE "Входной файл не найден: ${input}"
        echo -e "Использование: ${green}x-ui migrateDB [file.db|file.dump] [output]${plain}"
        return 1
    fi

    local mode
    case "$input" in
        *.db | *.sqlite | *.sqlite3)
            mode="dump"
            ;;
        *.dump | *.sql)
            mode="restore"
            ;;
        *)
            if head -c 16 "$input" | grep -q "SQLite format 3"; then
                mode="dump"
            else
                mode="restore"
            fi
            ;;
    esac

    if [[ "$mode" == "dump" ]]; then
        [[ -z "$output" ]] && output="${input%.*}.dump"
        if [[ -f "$output" ]]; then
            confirm "Выход ${output} уже существует и будет перезаписан. Продолжить?" "n" || return 0
        fi
        LOGI "Выгрузка базы данных SQLite в SQL текст:"
        echo -e "  ${green}${input}${plain} -> ${green}${output}${plain}"
        if "$bin" migrate-db --src "$input" --dump "$output"; then
            LOGI "Готово. Записан ${output}."
        else
            LOGE "Выгрузка не удалась."
            return 1
        fi
    else
        [[ -z "$output" ]] && output="${input%.*}.db"
        if [[ "$output" == "$default_db" ]] && check_status > /dev/null 2>&1; then
            LOGE "Отказ восстанавливать в живую базу данных (${default_db}) пока x-ui запущен."
            LOGE "Сначала остановите панель (x-ui stop) или выберите другой путь вывода."
            return 1
        fi
        if [[ -f "$output" ]]; then
            confirm "Выход ${output} уже существует и будет перезаписан. Продолжить?" "n" || return 0
            rm -f "$output"
        fi
        LOGI "Пересборка базы данных SQLite из SQL текста:"
        echo -e "  ${green}${input}${plain} -> ${green}${output}${plain}"
        if "$bin" migrate-db --restore "$input" --out "$output"; then
            LOGI "Готово. Создан ${output}."
        else
            LOGE "Восстановление не удалось."
            rm -f "$output"
            return 1
        fi
    fi
}

# Интерактивная обёртка вокруг migrate_db для меню: запрашивает пути и
# позволяет migrate_db автоматически определить направление.
migrate_db_prompt() {
    local default_db="/etc/x-ui/x-ui.db"
    local input output
    echo -e "Конвертация между SQLite ${green}.db${plain} и переносимым ${green}.dump${plain} (направление определяется автоматически)."
    read -rp "Входной файл [${default_db}]: " input
    input="${input:-$default_db}"
    read -rp "Выходной файл (оставьте пустым для автоименования рядом с входным): " output
    migrate_db "$input" "$output"
}

show_usage() {
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}Использование меню управления x-ui (подкоманды):${plain}                       │
│                                                                │
│  ${blue}x-ui${plain}                       - Скрипт управления администратором          │
│  ${blue}x-ui start${plain}                 - Запустить                            │
│  ${blue}x-ui stop${plain}                  - Остановить                             │
│  ${blue}x-ui restart${plain}               - Перезапустить                          │
|  ${blue}x-ui restart-xray${plain}          - Перезапустить Xray                     │
│  ${blue}x-ui status${plain}                - Текущий статус                   │
│  ${blue}x-ui settings${plain}              - Текущие настройки                 │
│  ${blue}x-ui enable${plain}                - Включить автозапуск при загрузке ОС   │
│  ${blue}x-ui disable${plain}               - Отключить автозапуск при загрузке ОС  │
│  ${blue}x-ui log${plain}                   - Проверить логи                       │
│  ${blue}x-ui banlog${plain}                - Проверить логи блокировок Fail2ban          │
│  ${blue}x-ui update${plain}                - Обновить                           │
│  ${blue}x-ui update-dev${plain}            - Обновить до Dev канала (последний)   │
│  ${blue}x-ui update-all-geofiles${plain}   - Обновить все geo файлы             │
│  ${blue}x-ui migrateDB [file]${plain}      - Конвертировать .db <-> .dump (SQLite)   │
│  ${blue}x-ui legacy${plain}                - Устаревшая версия                   │
│  ${blue}x-ui install${plain}               - Установить                          │
│  ${blue}x-ui uninstall${plain}             - Удалить                        │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│  ${green}Скрипт управления панелью 3X-UI${plain}                │
│  ${green}0.${plain} Выход из скрипта                               │
│────────────────────────────────────────────────│
│  ${green}1.${plain} Установить                                   │
│  ${green}2.${plain} Обновить                                    │
│  ${green}3.${plain} Обновить до Dev канала (последний коммит)     │
│  ${green}4.${plain} Обновить меню                               │
│  ${green}5.${plain} Устаревшая версия                            │
│  ${green}6.${plain} Удалить                                 │
│────────────────────────────────────────────────│
│  ${green}7.${plain} Сбросить имя пользователя и пароль                 │
│  ${green}8.${plain} Сбросить Web Base Path                       │
│  ${green}9.${plain} Сбросить настройки                            │
│  ${green}10.${plain} Изменить порт                              │
│  ${green}11.${plain} Просмотр текущих настроек                    │
│────────────────────────────────────────────────│
│  ${green}12.${plain} Запустить                                    │
│  ${green}13.${plain} Остановить                                     │
│  ${green}14.${plain} Перезапустить                                  │
|  ${green}15.${plain} Перезапустить Xray                             │
│  ${green}16.${plain} Проверить статус                             │
│  ${green}17.${plain} Управление логами                          │
│────────────────────────────────────────────────│
│  ${green}18.${plain} Включить автозапуск                         │
│  ${green}19.${plain} Отключить автозапуск                        │
│────────────────────────────────────────────────│
│  ${green}20.${plain} Управление SSL сертификатами               │
│  ${green}21.${plain} SSL сертификат Cloudflare               │
│  ${green}22.${plain} Управление ограничением IP                      │
│  ${green}23.${plain} Управление файрволом                       │
│  ${green}24.${plain} Управление SSH Port Forwarding           │
│  ${green}25.${plain} Управление PostgreSQL                    │
│────────────────────────────────────────────────│
│  ${green}26.${plain} Включить BBR                               │
│  ${green}27.${plain} Обновить Geo файлы                         │
│  ${green}28.${plain} Speedtest от Ookla                       │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "Введите ваш выбор [0-28]: " num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_dev
            ;;
        4)
            check_install && update_menu
            ;;
        5)
            check_install && legacy_version
            ;;
        6)
            check_install && uninstall
            ;;
        7)
            check_install && reset_user
            ;;
        8)
            check_install && reset_webbasepath
            ;;
        9)
            check_install && reset_config
            ;;
        10)
            check_install && set_port
            ;;
        11)
            check_install && check_config
            ;;
        12)
            check_install && start
            ;;
        13)
            check_install && stop
            ;;
        14)
            check_install && restart
            ;;
        15)
            check_install && restart_xray
            ;;
        16)
            check_install && status
            ;;
        17)
            check_install && show_log
            ;;
        18)
            check_install && enable
            ;;
        19)
            check_install && disable
            ;;
        20)
            ssl_cert_issue_main
            ;;
        21)
            ssl_cert_issue_CF
            ;;
        22)
            iplimit_main
            ;;
        23)
            firewall_menu
            ;;
        24)
            SSH_port_forwarding
            ;;
        25)
            postgresql_menu
            ;;
        26)
            bbr_menu
            ;;
        27)
            update_geo
            ;;
        28)
            run_speedtest
            ;;
        *)
            LOGE "Введите корректный номер [0-28]"
            ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "setup-fail2ban")
            setup_fail2ban_iplimit
            ;;
        "update")
            check_install 0 && update 0
            ;;
        "update-dev")
            check_install 0 && update_dev 0
            ;;
        "legacy")
            check_install 0 && legacy_version 0
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            check_install 0 && uninstall 0
            ;;
        "update-all-geofiles")
            geo_updated=0
            if check_install 0 && update_all_geofiles 0; then
                [[ $geo_updated -eq 0 ]] || restart 0
            fi
            ;;
        "migrateDB")
            migrate_db "$2" "$3"
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi