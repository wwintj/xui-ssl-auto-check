#!/usr/bin/env bash
# ============================================================
# x-ui / 3x-ui SSL Auto Check & Repair
# ============================================================
# What this script does:
#   1. Ask only for the domain, or accept it as the first argument.
#   2. Auto-detect x-ui / 3x-ui service, panel port, panel path, DB and cert paths.
#   3. Ensure acme.sh renewed cert is installed to:
#        /root/cert.crt
#        /root/private.key
#   4. Ensure renewed cert reloads x-ui / 3x-ui.
#   5. If Nginx occupies port 80 and acme.sh is standalone:
#        - Prefer switching to Webroot mode if safe.
#        - Fallback to pre/post hook: stop nginx before renewal, start nginx after renewal.
#   6. Show certificate issue date, expiry date and remaining days.
#   7. Show detailed WARN / FIX / FAIL reasons and suggestions.
#
# Recommended usage:
#   bash xui-ssl-auto-check.sh
#   bash xui-ssl-auto-check.sh tim.google.com
# ============================================================

set +e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
CYAN="\033[96m"
NC="\033[0m"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
FIX_COUNT=0

WARN_MESSAGES=()
FAIL_MESSAGES=()
FIX_MESSAGES=()

DOMAIN=""
SERVICE_NAME=""
XUI_DB=""
PANEL_PORT=""
PANEL_PATH="/"
XUI_CERT_FILE=""
XUI_KEY_FILE=""

ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
ACME_CONF=""
ACME_CERT_DIR=""
ACME_KEY_TYPE=""
ACME_MODE=""
ACME_WEBROOT=""
ACME_INSTALL_FLAG=()

TARGET_CERT="/root/cert.crt"
TARGET_KEY="/root/private.key"

NGINX_RUNNING=0
NGINX_80=0
PORT_443_OCCUPIED=0
FOUND_WEBROOT=""

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $1"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    WARN_MESSAGES+=("$1")
    echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAIL_MESSAGES+=("$1")
    echo -e "${RED}[FAIL]${NC} $1"
}

fix() {
    FIX_COUNT=$((FIX_COUNT + 1))
    FIX_MESSAGES+=("$1")
    echo -e "${CYAN}[FIX]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

line() {
    echo "------------------------------------------------------------"
}

show_help() {
    cat <<'HELP'
x-ui / 3x-ui SSL 自动检测与修复工具

用法：
  bash xui-ssl-auto-check.sh
  bash xui-ssl-auto-check.sh tim.google.com
  bash xui-ssl-auto-check.sh --help

说明：
  - 示例域名 tim.google.com 仅用于格式说明。
  - 脚本会自动检测 x-ui / 3x-ui、面板端口、证书路径、acme.sh 续签配置、Nginx 80 端口占用。
  - 脚本会自动确保续签后更新：
      /root/cert.crt
      /root/private.key
    并自动重启 x-ui / 3x-ui。
HELP
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "请使用 root 权限运行，例如 sudo -i 后再执行脚本"
        exit 1
    fi
}

ask_domain() {
    local input_domain="$1"

    if [ -z "$input_domain" ]; then
        read -rp "请输入要检测的域名，例如 tim.google.com，仅作格式示例: " input_domain
    fi

    if [ -z "$input_domain" ]; then
        fail "域名不能为空"
        exit 1
    fi

    DOMAIN="$input_domain"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_sqlite3_if_needed() {
    if command_exists sqlite3; then
        pass "sqlite3 已安装"
        return 0
    fi

    warn "sqlite3 未安装，正在尝试自动安装，用于读取和修正 x-ui 数据库"

    if command_exists apt; then
        apt update -y >/dev/null 2>&1
        apt install sqlite3 -y
    elif command_exists dnf; then
        dnf install sqlite -y
    elif command_exists yum; then
        yum install sqlite -y
    else
        warn "无法自动安装 sqlite3，后续将跳过数据库读取和自动修正"
        return 1
    fi

    if command_exists sqlite3; then
        fix "sqlite3 安装完成"
        return 0
    else
        warn "sqlite3 安装失败，后续将跳过数据库读取和自动修正"
        return 1
    fi
}

detect_service() {
    SERVICE_NAME=""

    for svc in x-ui 3x-ui xui; do
        if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
            if systemctl is-active --quiet "$svc"; then
                SERVICE_NAME="$svc"
                pass "检测到正在运行的服务：$SERVICE_NAME"
                return 0
            fi
        fi
    done

    for svc in x-ui 3x-ui xui; do
        if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
            SERVICE_NAME="$svc"
            warn "检测到服务 $SERVICE_NAME，但当前未运行"
            return 0
        fi
    done

    if pgrep -af "x-ui|3x-ui" >/dev/null 2>&1; then
        SERVICE_NAME="x-ui"
        warn "通过进程检测到 x-ui，但未确认 systemd 服务名，暂用 x-ui"
        return 0
    fi

    fail "未检测到 x-ui / 3x-ui 服务"
    SERVICE_NAME="x-ui"
    return 1
}

detect_db() {
    XUI_DB=""

    for db in \
        "/etc/x-ui/x-ui.db" \
        "/usr/local/x-ui/x-ui.db" \
        "/usr/local/3x-ui/x-ui.db" \
        "/etc/3x-ui/x-ui.db"
    do
        if [ -f "$db" ]; then
            XUI_DB="$db"
            pass "检测到 x-ui 数据库：$XUI_DB"
            return 0
        fi
    done

    local found_db
    found_db="$(find /etc /usr/local /root -name "x-ui.db" 2>/dev/null | head -n 1)"

    if [ -n "$found_db" ] && [ -f "$found_db" ]; then
        XUI_DB="$found_db"
        pass "检测到 x-ui 数据库：$XUI_DB"
        return 0
    fi

    warn "未检测到 x-ui.db，后续将通过进程和端口推断"
    return 1
}

sqlite_get_setting() {
    local key="$1"
    if [ -n "$XUI_DB" ] && [ -f "$XUI_DB" ] && command_exists sqlite3; then
        sqlite3 "$XUI_DB" "select value from settings where key='$key' limit 1;" 2>/dev/null
    fi
}

sqlite_setting_exists() {
    local key="$1"
    if [ -n "$XUI_DB" ] && [ -f "$XUI_DB" ] && command_exists sqlite3; then
        sqlite3 "$XUI_DB" "select count(*) from settings where key='$key';" 2>/dev/null
    else
        echo "0"
    fi
}

sqlite_set_setting() {
    local key="$1"
    local value="$2"

    if [ -z "$XUI_DB" ] || [ ! -f "$XUI_DB" ] || ! command_exists sqlite3; then
        warn "无法写入数据库设置：$key，因为 x-ui.db 或 sqlite3 不可用"
        return 1
    fi

    local count
    count="$(sqlite_setting_exists "$key")"

    if [ "$count" -gt 0 ] 2>/dev/null; then
        sqlite3 "$XUI_DB" "update settings set value='$value' where key='$key';" 2>/dev/null
    else
        sqlite3 "$XUI_DB" "insert into settings(key,value) values('$key','$value');" 2>/dev/null
    fi

    return $?
}

detect_panel_port() {
    PANEL_PORT=""

    local db_port
    db_port="$(sqlite_get_setting "webPort")"

    if [[ "$db_port" =~ ^[0-9]+$ ]]; then
        PANEL_PORT="$db_port"
        pass "从数据库检测到面板端口：$PANEL_PORT"
        return 0
    fi

    local port_line
    port_line="$(ss -ltnp 2>/dev/null | grep -Ei 'x-ui|3x-ui' | head -n 1)"

    if [ -n "$port_line" ]; then
        PANEL_PORT="$(echo "$port_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/')"
        if [[ "$PANEL_PORT" =~ ^[0-9]+$ ]]; then
            pass "从监听进程检测到面板端口：$PANEL_PORT"
            return 0
        fi
    fi

    PANEL_PORT="7777"
    warn "未能自动检测面板端口，使用默认端口：7777"
    return 1
}

detect_panel_path() {
    PANEL_PATH=""

    for key in webBasePath webPath basePath panelPath; do
        local value
        value="$(sqlite_get_setting "$key")"
        if [ -n "$value" ]; then
            PANEL_PATH="$value"
            break
        fi
    done

    if [ -z "$PANEL_PATH" ]; then
        PANEL_PATH="/"
        warn "未能从数据库检测到面板路径，暂用 / 进行检测"
    else
        if [[ "$PANEL_PATH" != /* ]]; then
            PANEL_PATH="/$PANEL_PATH"
        fi
        if [[ "$PANEL_PATH" != */ ]]; then
            PANEL_PATH="${PANEL_PATH}/"
        fi
        pass "检测到面板路径：$PANEL_PATH"
    fi
}

detect_current_xui_cert_paths() {
    XUI_CERT_FILE="$(sqlite_get_setting "webCertFile")"
    XUI_KEY_FILE="$(sqlite_get_setting "webKeyFile")"

    if [ -n "$XUI_CERT_FILE" ]; then
        pass "数据库中的面板证书路径：$XUI_CERT_FILE"
    else
        warn "数据库中未检测到 webCertFile"
    fi

    if [ -n "$XUI_KEY_FILE" ]; then
        pass "数据库中的面板私钥路径：$XUI_KEY_FILE"
    else
        warn "数据库中未检测到 webKeyFile"
    fi
}

detect_acme() {
    ACME_CONF=""
    ACME_CERT_DIR=""
    ACME_KEY_TYPE=""
    ACME_INSTALL_FLAG=()

    if [ ! -x "$ACME_BIN" ]; then
        fail "未检测到 acme.sh：$ACME_BIN"
        return 1
    fi

    pass "检测到 acme.sh：$ACME_BIN"

    local ecc_conf="${ACME_HOME}/${DOMAIN}_ecc/${DOMAIN}.conf"
    local rsa_conf="${ACME_HOME}/${DOMAIN}/${DOMAIN}.conf"

    if [ -f "$ecc_conf" ]; then
        ACME_CONF="$ecc_conf"
        ACME_CERT_DIR="${ACME_HOME}/${DOMAIN}_ecc"
        ACME_KEY_TYPE="ECC"
        ACME_INSTALL_FLAG=(--ecc)
        pass "检测到 ECC 证书配置：$ACME_CONF"
    elif [ -f "$rsa_conf" ]; then
        ACME_CONF="$rsa_conf"
        ACME_CERT_DIR="${ACME_HOME}/${DOMAIN}"
        ACME_KEY_TYPE="RSA"
        ACME_INSTALL_FLAG=()
        pass "检测到 RSA 证书配置：$ACME_CONF"
    else
        fail "acme.sh 中未找到该域名证书配置"
        return 1
    fi

    info "acme.sh 原始证书目录：$ACME_CERT_DIR"
}

get_acme_var() {
    local key="$1"
    if [ -n "$ACME_CONF" ] && [ -f "$ACME_CONF" ]; then
        grep "^${key}=" "$ACME_CONF" | tail -n 1 | cut -d"'" -f2
    fi
}

set_acme_var() {
    local key="$1"
    local value="$2"

    if [ -z "$ACME_CONF" ] || [ ! -f "$ACME_CONF" ]; then
        warn "无法写入 acme.sh 配置，因为配置文件不存在"
        return 1
    fi

    local escaped
    escaped="$(printf "%s" "$value" | sed "s/'/'\\\\''/g")"

    if grep -q "^${key}=" "$ACME_CONF"; then
        sed -i "s|^${key}=.*|${key}='${escaped}'|" "$ACME_CONF"
    else
        echo "${key}='${escaped}'" >> "$ACME_CONF"
    fi
}

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        echo "$backup"
    fi
}

ensure_acme_install_cert() {
    if [ -z "$ACME_CONF" ] || [ ! -f "$ACME_CONF" ]; then
        fail "无法配置 install-cert，因为 acme.sh 域名配置不存在"
        return 1
    fi

    info "正在配置 acme.sh：续签后安装证书到 $TARGET_CERT 和 $TARGET_KEY，并重启 $SERVICE_NAME"

    "$ACME_BIN" --install-cert -d "$DOMAIN" "${ACME_INSTALL_FLAG[@]}" \
        --fullchain-file "$TARGET_CERT" \
        --key-file "$TARGET_KEY" \
        --reloadcmd "systemctl restart $SERVICE_NAME"

    if [ $? -eq 0 ]; then
        chmod 644 "$TARGET_CERT" 2>/dev/null
        chmod 600 "$TARGET_KEY" 2>/dev/null
        fix "已配置 acme.sh install-cert 目标路径和 reloadcmd"
    else
        fail "配置 acme.sh install-cert 失败"
        return 1
    fi

    if [ -f "$TARGET_CERT" ]; then
        pass "续签后会更新 /root/cert.crt"
    else
        fail "/root/cert.crt 当前不存在"
    fi

    if [ -f "$TARGET_KEY" ]; then
        pass "续签后会更新 /root/private.key"
    else
        fail "/root/private.key 当前不存在"
    fi

    local reload_cmd
    reload_cmd="$(get_acme_var "Le_ReloadCmd")"

    if echo "$reload_cmd" | grep -q "systemctl restart $SERVICE_NAME"; then
        pass "续签后会重启 $SERVICE_NAME"
    else
        warn "未确认续签后会重启 $SERVICE_NAME"
    fi
}

ensure_xui_uses_root_cert() {
    if [ -z "$XUI_DB" ] || [ ! -f "$XUI_DB" ] || ! command_exists sqlite3; then
        warn "无法自动修正 x-ui 证书路径，因为数据库或 sqlite3 不可用"
        return 1
    fi

    local changed=0

    detect_current_xui_cert_paths

    if [ "$XUI_CERT_FILE" != "$TARGET_CERT" ] || [ "$XUI_KEY_FILE" != "$TARGET_KEY" ]; then
        local backup
        backup="$(backup_file "$XUI_DB")"
        if [ -n "$backup" ]; then
            info "已备份 x-ui 数据库：$backup"
        fi
    fi

    if [ "$XUI_CERT_FILE" != "$TARGET_CERT" ]; then
        sqlite_set_setting "webCertFile" "$TARGET_CERT"
        if [ $? -eq 0 ]; then
            fix "已将 x-ui 证书路径设置为 /root/cert.crt"
            changed=1
        else
            fail "设置 x-ui 证书路径失败"
        fi
    else
        pass "x-ui 当前使用证书路径：/root/cert.crt"
    fi

    if [ "$XUI_KEY_FILE" != "$TARGET_KEY" ]; then
        sqlite_set_setting "webKeyFile" "$TARGET_KEY"
        if [ $? -eq 0 ]; then
            fix "已将 x-ui 私钥路径设置为 /root/private.key"
            changed=1
        else
            fail "设置 x-ui 私钥路径失败"
        fi
    else
        pass "x-ui 当前使用私钥路径：/root/private.key"
    fi

    if [ "$changed" -eq 1 ]; then
        systemctl restart "$SERVICE_NAME"
        if [ $? -eq 0 ]; then
            fix "已重启 $SERVICE_NAME，使证书路径生效"
        else
            fail "重启 $SERVICE_NAME 失败"
        fi
    fi
}

check_certificate_content() {
    if [ ! -f "$TARGET_CERT" ]; then
        fail "证书文件不存在：$TARGET_CERT"
        return 1
    fi

    info "当前 $TARGET_CERT 证书信息："
    openssl x509 -in "$TARGET_CERT" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null

    if openssl x509 -in "$TARGET_CERT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${DOMAIN}"; then
        pass "证书 SAN 包含域名：$DOMAIN"
    else
        fail "证书 SAN 未包含域名：$DOMAIN"
    fi

    local not_after
    not_after="$(openssl x509 -in "$TARGET_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"

    if [ -n "$not_after" ]; then
        local end_ts now_ts days_left
        end_ts="$(date -d "$not_after" +%s 2>/dev/null)"
        now_ts="$(date +%s)"

        if [ -n "$end_ts" ]; then
            days_left=$(( (end_ts - now_ts) / 86400 ))
            info "证书大约还有 $days_left 天过期"

            if [ "$days_left" -gt 30 ]; then
                pass "证书有效期健康"
            elif [ "$days_left" -gt 7 ]; then
                warn "证书将在 30 天内过期，请关注续签"
            else
                fail "证书已经非常接近过期或已经过期"
            fi
        fi
    fi
}

detect_nginx_and_ports() {
    NGINX_RUNNING=0
    NGINX_80=0
    PORT_443_OCCUPIED=0

    if command_exists nginx; then
        info "检测到 Nginx 已安装"

        if systemctl is-active --quiet nginx; then
            NGINX_RUNNING=1
            warn "Nginx 正在运行"
        else
            pass "Nginx 已安装，但当前未运行"
        fi

        nginx -t >/tmp/xui_ssl_nginx_test.log 2>&1
        if [ $? -eq 0 ]; then
            pass "Nginx 配置测试通过"
        else
            warn "Nginx 配置测试未通过"
            cat /tmp/xui_ssl_nginx_test.log
        fi
    else
        pass "未检测到 Nginx"
    fi

    line
    info "80 / 443 端口监听情况："
    ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /\]:80$/ || $4 ~ /:443$/ || $4 ~ /\]:443$/ {print}' || true

    if ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /\]:80$/ {print}' | grep -qi nginx; then
        NGINX_80=1
        warn "80 端口当前由 Nginx 占用"
    else
        pass "80 端口未检测到由 Nginx 占用"
    fi

    if ss -ltnp 2>/dev/null | awk '$4 ~ /:443$/ || $4 ~ /\]:443$/ {print}' | grep -q .; then
        PORT_443_OCCUPIED=1
        warn "443 端口当前有服务监听"
    else
        pass "443 端口当前未监听"
    fi
}

detect_acme_mode() {
    ACME_WEBROOT="$(get_acme_var "Le_Webroot")"

    if [ -z "$ACME_WEBROOT" ]; then
        ACME_MODE="unknown"
        warn "无法识别 acme.sh 当前验证模式，Le_Webroot 为空"
    elif [[ "$ACME_WEBROOT" == dns_* ]]; then
        ACME_MODE="dns"
        pass "当前 acme.sh 是 DNS API 模式：$ACME_WEBROOT"
    elif [ "$ACME_WEBROOT" = "no" ]; then
        ACME_MODE="standalone"
        warn "当前 acme.sh 是 standalone 模式"
    elif [ "$ACME_WEBROOT" = "nginx" ]; then
        ACME_MODE="nginx"
        warn "当前 acme.sh 是 nginx 模式"
    elif [[ "$ACME_WEBROOT" == /* ]]; then
        ACME_MODE="webroot"
        pass "当前 acme.sh 是 Webroot 模式：$ACME_WEBROOT"
    else
        ACME_MODE="unknown"
        warn "无法明确识别 acme.sh 模式：$ACME_WEBROOT"
    fi
}

find_nginx_webroot_for_domain() {
    FOUND_WEBROOT=""

    if ! command_exists nginx; then
        return 1
    fi

    local files
    files="$(grep -RslE "server_name[[:space:]].*${DOMAIN}" \
        /etc/nginx/sites-enabled \
        /etc/nginx/conf.d \
        /etc/nginx/sites-available \
        /etc/nginx 2>/dev/null | sort -u)"

    if [ -z "$files" ]; then
        warn "未在 Nginx 配置中找到 server_name $DOMAIN"
        return 1
    fi

    local file
    while read -r file; do
        [ -z "$file" ] && continue

        local root_line
        root_line="$(awk '
            /^[[:space:]]*#/ {next}
            /root[[:space:]]+/ {
                gsub(";", "", $0)
                print $0
                exit
            }
        ' "$file")"

        local root_path
        root_path="$(echo "$root_line" | awk '{print $2}')"

        if [ -n "$root_path" ] && [ -d "$root_path" ]; then
            FOUND_WEBROOT="$root_path"
            pass "检测到 Nginx Webroot：$FOUND_WEBROOT"
            info "来源配置文件：$file"
            return 0
        fi
    done <<< "$files"

    warn "找到了域名配置，但未能识别有效 root 目录"
    return 1
}

test_webroot_challenge() {
    local webroot="$1"

    if [ -z "$webroot" ] || [ ! -d "$webroot" ]; then
        return 1
    fi

    local challenge_dir="${webroot}/.well-known/acme-challenge"
    local token="xui-ssl-check-$(date +%s)-$RANDOM"
    local content="ok-${token}"

    mkdir -p "$challenge_dir"
    echo "$content" > "${challenge_dir}/${token}"

    local result
    result="$(curl -s --max-time 10 "http://${DOMAIN}/.well-known/acme-challenge/${token}" || true)"

    rm -f "${challenge_dir:?}/${token}"

    if [ "$result" = "$content" ]; then
        pass "Webroot challenge 公网访问测试通过"
        return 0
    else
        warn "Webroot challenge 公网访问测试失败"
        return 1
    fi
}

configure_nginx_stop_start_hooks() {
    if [ -z "$ACME_CONF" ] || [ ! -f "$ACME_CONF" ]; then
        fail "无法配置 Nginx stop/start hook，因为 acme.sh 配置文件不存在"
        return 1
    fi

    local backup
    backup="$(backup_file "$ACME_CONF")"
    if [ -n "$backup" ]; then
        info "已备份 acme.sh 配置：$backup"
    fi

    set_acme_var "Le_PreHook" "systemctl stop nginx || true"
    set_acme_var "Le_PostHook" "systemctl start nginx || true"

    fix "已配置续签前自动停止 Nginx"
    fix "已配置续签后自动启动 Nginx"
    pass "已避免 standalone 续签时被 Nginx 占用 80 端口阻塞"
}

switch_standalone_to_webroot() {
    if [ "$ACME_MODE" != "standalone" ]; then
        return 0
    fi

    if [ "$NGINX_80" -ne 1 ]; then
        pass "standalone 模式下 80 端口未被 Nginx 占用，暂不需要切换模式"
        return 0
    fi

    warn "检测到 standalone + Nginx 占用 80，开始尝试优先切换到 Webroot 模式"

    find_nginx_webroot_for_domain
    if [ -z "$FOUND_WEBROOT" ]; then
        warn "无法自动找到安全的 Webroot，准备使用 hook 兜底方案"
        configure_nginx_stop_start_hooks
        return $?
    fi

    test_webroot_challenge "$FOUND_WEBROOT"
    if [ $? -ne 0 ]; then
        warn "Webroot 条件不满足，准备使用 hook 兜底方案"
        configure_nginx_stop_start_hooks
        return $?
    fi

    info "正在将 acme.sh 验证方式切换为 Webroot 模式"
    info "注意：此步骤会重新签发一次证书，以便保存新的 Webroot 验证方式"

    if [ "$ACME_KEY_TYPE" = "ECC" ]; then
        "$ACME_BIN" --issue -d "$DOMAIN" -w "$FOUND_WEBROOT" --keylength ec-256 --force
    else
        "$ACME_BIN" --issue -d "$DOMAIN" -w "$FOUND_WEBROOT" --force
    fi

    if [ $? -eq 0 ]; then
        fix "已成功切换为 Webroot 模式并重新签发证书"
        detect_acme
        ensure_acme_install_cert
        return 0
    else
        warn "Webroot 模式重新签发失败，准备使用 hook 兜底方案"
        configure_nginx_stop_start_hooks
        return $?
    fi
}

check_auto_renew() {
    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        pass "acme.sh cron 自动续签任务存在"
        crontab -l 2>/dev/null | grep "acme.sh.*--cron"
    else
        warn "未发现 acme.sh cron 自动续签任务，正在尝试安装 cron 任务"
        "$ACME_BIN" --install-cronjob >/dev/null 2>&1

        if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
            fix "已安装 acme.sh cron 自动续签任务"
            crontab -l 2>/dev/null | grep "acme.sh.*--cron"
        else
            fail "自动安装 acme.sh cron 任务失败"
        fi
    fi
}

check_https_access() {
    if [ -z "$PANEL_PORT" ]; then
        warn "未检测到面板端口，跳过 HTTPS 访问测试"
        return 1
    fi

    info "检测本机 HTTPS： https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
    local local_code
    local_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 8 "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}" || true)"

    if [ "$local_code" = "200" ] || [ "$local_code" = "301" ] || [ "$local_code" = "302" ]; then
        pass "本机 HTTPS 正常，HTTP 状态码：$local_code"
    else
        warn "本机 HTTPS 未返回正常状态码：$local_code"
    fi

    info "检测公网 HTTPS： https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}"
    local public_code
    public_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 12 "https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}" || true)"

    if [ "$public_code" = "200" ] || [ "$public_code" = "301" ] || [ "$public_code" = "302" ]; then
        pass "公网 HTTPS 正常，HTTP 状态码：$public_code"
    else
        warn "公网 HTTPS 未返回正常状态码，可能受防火墙、安全组、Cloudflare 或面板路径影响：$public_code"
    fi

    info "读取面板端口实际提供的证书"
    local served_cert
    served_cert="$(openssl s_client -connect "127.0.0.1:${PANEL_PORT}" -servername "$DOMAIN" -showcerts </dev/null 2>/dev/null \
        | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' \
        | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true)"

    if [ -n "$served_cert" ]; then
        pass "面板端口正在提供 TLS 证书"
        echo "$served_cert"
    else
        warn "无法通过 openssl 读取面板端口证书；如果 curl HTTPS 正常，通常问题不大"
    fi
}

print_acme_paths() {
    line
    echo "证书路径信息："
    echo

    if [ -n "$ACME_CERT_DIR" ]; then
        info "acme.sh 原始证书目录："
        echo "       $ACME_CERT_DIR"
    fi

    if [ -f "$TARGET_CERT" ]; then
        pass "x-ui 面板证书路径：/root/cert.crt"
    else
        fail "x-ui 面板证书路径不存在：/root/cert.crt"
    fi

    if [ -f "$TARGET_KEY" ]; then
        pass "x-ui 面板私钥路径：/root/private.key"
    else
        fail "x-ui 面板私钥路径不存在：/root/private.key"
    fi

    if [ -n "$ACME_CONF" ] && [ -f "$ACME_CONF" ]; then
        info "acme.sh 关键安装配置："
        grep -E "Le_Webroot|Le_RealCertPath|Le_RealFullChainPath|Le_RealKeyPath|Le_ReloadCmd|Le_PreHook|Le_PostHook" "$ACME_CONF" || true
    fi
}

advice_for_message() {
    local level="$1"
    local msg="$2"

    case "$msg" in
        *"sqlite3 未安装"*)
            echo "建议：sqlite3 用于读取和修正 x-ui 数据库。脚本会尝试自动安装；如果安装失败，可手动执行 apt update && apt install sqlite3 -y。"
            ;;
        *"未能从数据库检测到面板路径"*)
            echo "建议：这通常不影响证书续签，只会影响 HTTPS 页面测试。可登录面板确认真实路径，或检查 x-ui.db 中的 webBasePath / webPath 字段。"
            ;;
        *"Nginx 正在运行"*)
            echo "建议：Nginx 正在运行本身不是问题。只有 acme.sh 使用 standalone 模式且需要 80 端口时，才可能影响续签。"
            ;;
        *"80 端口当前由 Nginx 占用"*)
            echo "建议：需要结合 acme.sh 模式判断。如果是 DNS/Webroot 模式通常没问题；如果是 standalone 模式，脚本会优先尝试 Webroot，失败后配置停止/启动 Nginx 的 hook。"
            ;;
        *"443 端口当前有服务监听"*)
            echo "建议：443 被占用通常不影响 HTTP-01 续签；重点关注 80 端口。只要不和 x-ui 面板端口冲突，一般无需处理。"
            ;;
        *"standalone 模式"*)
            echo "建议：standalone 续签可能需要临时占用 80 端口。如果 80 被 Nginx 占用，建议改 Webroot 或 DNS API；脚本会尝试自动规避冲突。"
            ;;
        *"Webroot challenge 公网访问测试失败"*)
            echo "建议：检查 Nginx 的 server_name、root 目录、/.well-known/acme-challenge/ 是否能公网访问，以及 Cloudflare 是否代理了该域名。"
            ;;
        *"公网 HTTPS 未返回正常状态码"*)
            echo "建议：检查 VPS 防火墙、安全组、Cloudflare 代理状态、面板端口是否放行，以及面板路径是否正确。"
            ;;
        *"未发现 acme.sh cron 自动续签任务"*)
            echo "建议：脚本会尝试安装 cron。若仍失败，可手动执行 /root/.acme.sh/acme.sh --install-cronjob。"
            ;;
        *"已配置 acme.sh install-cert"*)
            echo "说明：acme.sh 续签成功后会把证书复制到 /root/cert.crt，把私钥复制到 /root/private.key，并执行 reloadcmd。"
            ;;
        *"已将 x-ui 证书路径设置为 /root/cert.crt"*)
            echo "说明：x-ui 数据库已被修正，后续面板会读取统一证书路径 /root/cert.crt。"
            ;;
        *"已将 x-ui 私钥路径设置为 /root/private.key"*)
            echo "说明：x-ui 数据库已被修正，后续面板会读取统一私钥路径 /root/private.key。"
            ;;
        *"已重启"*)
            echo "说明：服务已重启以加载新的证书路径或证书文件。建议再次运行脚本确认 HTTPS 状态。"
            ;;
        *"已配置续签前自动停止 Nginx"*)
            echo "说明：这是 standalone 模式的兜底保护，避免续签时 80 端口被 Nginx 占用。更优方案是未来改为 DNS API 或 Webroot。"
            ;;
        *"已配置续签后自动启动 Nginx"*)
            echo "说明：续签完成后会自动恢复 Nginx，降低服务中断时间。"
            ;;
        *)
            if [ "$level" = "FIX" ]; then
                echo "说明：该项目已由脚本自动处理。建议重新运行脚本复查是否变为 PASS。"
            elif [ "$level" = "FAIL" ]; then
                echo "建议：这是明确异常，需要优先处理。请查看上方对应日志，必要时手动修复后重新运行脚本。"
            else
                echo "建议：这是风险提醒，不一定是故障。如果 FAIL=0，通常可继续使用，但建议根据上方日志确认。"
            fi
            ;;
    esac
}

print_issue_details() {
    echo
    line
    echo "WARN / FIX / FAIL 详情与建议"
    line

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo
        echo "FAIL 详情："
        local i=1
        local item
        for item in "${FAIL_MESSAGES[@]}"; do
            echo "[$i] $item"
            advice_for_message "FAIL" "$item"
            echo
            i=$((i + 1))
        done
    fi

    if [ "$WARN_COUNT" -gt 0 ]; then
        echo
        echo "WARN 详情："
        local i=1
        local item
        for item in "${WARN_MESSAGES[@]}"; do
            echo "[$i] $item"
            advice_for_message "WARN" "$item"
            echo
            i=$((i + 1))
        done
    fi

    if [ "$FIX_COUNT" -gt 0 ]; then
        echo
        echo "FIX 详情："
        local i=1
        local item
        for item in "${FIX_MESSAGES[@]}"; do
            echo "[$i] $item"
            advice_for_message "FIX" "$item"
            echo
            i=$((i + 1))
        done
    fi

    if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ] && [ "$FIX_COUNT" -eq 0 ]; then
        echo "没有 WARN / FIX / FAIL 详情。"
    fi
}

print_summary() {
    line
    echo "检测与修复结果汇总"
    line
    echo "域名              : $DOMAIN"
    echo "服务              : $SERVICE_NAME"
    echo "面板端口          : ${PANEL_PORT:-Unknown}"
    echo "面板路径          : ${PANEL_PATH:-Unknown}"
    echo "acme.sh 类型      : ${ACME_KEY_TYPE:-Unknown}"
    echo "acme.sh 模式      : ${ACME_MODE:-Unknown}"
    echo "acme.sh 证书目录  : ${ACME_CERT_DIR:-Unknown}"

    if [ -f "$TARGET_CERT" ]; then
        SUMMARY_CERT_START="$(openssl x509 -in "$TARGET_CERT" -noout -startdate 2>/dev/null | cut -d= -f2)"
        SUMMARY_CERT_END="$(openssl x509 -in "$TARGET_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"

        if [ -n "$SUMMARY_CERT_END" ]; then
            SUMMARY_END_TS="$(date -d "$SUMMARY_CERT_END" +%s 2>/dev/null)"
            SUMMARY_NOW_TS="$(date +%s)"
            if [ -n "$SUMMARY_END_TS" ]; then
                SUMMARY_DAYS_LEFT=$(( (SUMMARY_END_TS - SUMMARY_NOW_TS) / 86400 ))
            else
                SUMMARY_DAYS_LEFT="Unknown"
            fi
        else
            SUMMARY_DAYS_LEFT="Unknown"
        fi

        echo "证书签发日期      : ${SUMMARY_CERT_START:-Unknown}"
        echo "证书到期日期      : ${SUMMARY_CERT_END:-Unknown}"
        echo "证书剩余天数      : ${SUMMARY_DAYS_LEFT} 天"
    else
        echo "证书签发日期      : Unknown"
        echo "证书到期日期      : Unknown"
        echo "证书剩余天数      : Unknown"
    fi

    echo "x-ui 证书路径     : /root/cert.crt"
    echo "x-ui 私钥路径     : /root/private.key"
    line
    echo -e "${GREEN}PASS${NC}: $PASS_COUNT"
    echo -e "${YELLOW}WARN${NC}: $WARN_COUNT"
    echo -e "${RED}FAIL${NC}: $FAIL_COUNT"
    echo -e "${CYAN}FIX ${NC}: $FIX_COUNT"

    print_issue_details

    line

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo -e "整体状态：${RED}Failed${NC}"
    elif [ "$WARN_COUNT" -gt 0 ]; then
        echo -e "整体状态：${YELLOW}Warning${NC}"
    else
        echo -e "整体状态：${GREEN}Healthy${NC}"
    fi

    line
}

main() {
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        show_help
        exit 0
    fi

    need_root

    echo
    line
    echo "x-ui / 3x-ui SSL 自动检测与修复工具"
    line
    echo

    ask_domain "$1"

    line
    info "开始检测系统基础信息"
    echo "Hostname : $(hostname)"
    echo "User     : $(whoami)"
    echo "Date     : $(date)"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "OS       : ${PRETTY_NAME:-Unknown}"
    fi
    line

    install_sqlite3_if_needed

    detect_service
    detect_db
    detect_panel_port
    detect_panel_path

    detect_acme
    if [ $? -ne 0 ]; then
        fail "没有 acme.sh 证书配置，无法继续自动配置续签链路"
        print_summary
        exit 1
    fi

    ensure_acme_install_cert
    ensure_xui_uses_root_cert
    check_certificate_content

    detect_nginx_and_ports
    detect_acme_mode
    switch_standalone_to_webroot

    check_auto_renew
    check_https_access
    print_acme_paths
    print_summary
}

main "$@"
