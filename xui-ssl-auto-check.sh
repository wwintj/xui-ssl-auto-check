#!/usr/bin/env bash
# x-ui / 3x-ui SSL Auto Check & Repair
# Webroot-first edition: repairs acme.sh standalone + Nginx:80 without stopping Nginx.

set +e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[36m"; CYAN="\033[96m"; NC="\033[0m"
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; FIX_COUNT=0
WARN_MESSAGES=(); FAIL_MESSAGES=(); FIX_MESSAGES=()

DOMAIN=""; SERVICE_NAME=""; XUI_DB=""; PANEL_PORT=""; PANEL_PATH="/"
ACME_HOME="/root/.acme.sh"; ACME_BIN="${ACME_HOME}/acme.sh"; ACME_CONF=""; ACME_CERT_DIR=""; ACME_KEY_TYPE=""; ACME_MODE=""; ACME_WEBROOT=""
TARGET_CERT="/root/cert.crt"; TARGET_KEY="/root/private.key"
NGINX_80=0; FOUND_WEBROOT=""; NGINX_DOMAIN_CONF_FILE=""

pass(){ PASS_COUNT=$((PASS_COUNT+1)); echo -e "${GREEN}[PASS]${NC} $1"; }
warn(){ WARN_COUNT=$((WARN_COUNT+1)); WARN_MESSAGES+=("$1"); echo -e "${YELLOW}[WARN]${NC} $1"; }
fail(){ FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_MESSAGES+=("$1"); echo -e "${RED}[FAIL]${NC} $1"; }
fix(){ FIX_COUNT=$((FIX_COUNT+1)); FIX_MESSAGES+=("$1"); echo -e "${CYAN}[FIX]${NC} $1"; }
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
line(){ echo "------------------------------------------------------------"; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

show_help(){
cat <<'HELP'
x-ui / 3x-ui SSL 自动检测与修复工具

用法：
  bash xui-ssl-auto-check.sh
  bash xui-ssl-auto-check.sh tim.google.com
  bash xui-ssl-auto-check.sh --help

说明：
  - 示例域名 tim.google.com 仅用于格式说明。
  - 脚本会自动检测 x-ui / 3x-ui、面板端口、证书路径、acme.sh 续签配置、Nginx 80 端口占用。
  - 新版优先修复 Webroot，不会自动停止 Nginx。
HELP
}

need_root(){
    if [ "$(id -u)" -ne 0 ]; then
        fail "请使用 root 权限运行，例如 sudo -i 后再执行脚本"
        exit 1
    fi
}

ask_domain(){
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

install_sqlite3_if_needed(){
    if command_exists sqlite3; then pass "sqlite3 已安装"; return 0; fi
    warn "sqlite3 未安装，正在尝试自动安装，用于读取和修正 x-ui 数据库"
    if command_exists apt; then
        apt update -y >/dev/null 2>&1 && apt install sqlite3 -y
    elif command_exists dnf; then
        dnf install sqlite -y
    elif command_exists yum; then
        yum install sqlite -y
    else
        warn "无法自动安装 sqlite3，后续将跳过数据库读取和自动修正"
        return 1
    fi
    command_exists sqlite3 && fix "sqlite3 安装完成" || warn "sqlite3 安装失败，后续将跳过数据库读取和自动修正"
}

detect_service(){
    SERVICE_NAME=""
    for svc in x-ui 3x-ui xui; do
        if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
            if systemctl is-active --quiet "$svc"; then
                SERVICE_NAME="$svc"; pass "检测到正在运行的服务：$SERVICE_NAME"; return 0
            fi
        fi
    done
    for svc in x-ui 3x-ui xui; do
        if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
            SERVICE_NAME="$svc"; warn "检测到服务 $SERVICE_NAME，但当前未运行"; return 0
        fi
    done
    if pgrep -af "x-ui|3x-ui" >/dev/null 2>&1; then
        SERVICE_NAME="x-ui"; warn "通过进程检测到 x-ui，但未确认 systemd 服务名，暂用 x-ui"; return 0
    fi
    SERVICE_NAME="x-ui"; fail "未检测到 x-ui / 3x-ui 服务"; return 1
}

detect_db(){
    XUI_DB=""
    for db in "/etc/x-ui/x-ui.db" "/usr/local/x-ui/x-ui.db" "/usr/local/3x-ui/x-ui.db" "/etc/3x-ui/x-ui.db"; do
        [ -f "$db" ] && XUI_DB="$db" && pass "检测到 x-ui 数据库：$XUI_DB" && return 0
    done
    local found_db
    found_db="$(find /etc /usr/local /root -name "x-ui.db" 2>/dev/null | head -n 1)"
    if [ -n "$found_db" ] && [ -f "$found_db" ]; then
        XUI_DB="$found_db"; pass "检测到 x-ui 数据库：$XUI_DB"; return 0
    fi
    warn "未检测到 x-ui.db，后续将通过进程和端口推断"; return 1
}

sqlite_get_setting(){
    local key="$1"
    [ -n "$XUI_DB" ] && [ -f "$XUI_DB" ] && command_exists sqlite3 && sqlite3 "$XUI_DB" "select value from settings where key='$key' limit 1;" 2>/dev/null
}

sqlite_set_setting(){
    local key="$1" value="$2"
    if [ -z "$XUI_DB" ] || [ ! -f "$XUI_DB" ] || ! command_exists sqlite3; then
        warn "无法写入数据库设置：$key，因为 x-ui.db 或 sqlite3 不可用"; return 1
    fi
    local count
    count="$(sqlite3 "$XUI_DB" "select count(*) from settings where key='$key';" 2>/dev/null)"
    if [ "$count" -gt 0 ] 2>/dev/null; then
        sqlite3 "$XUI_DB" "update settings set value='$value' where key='$key';" 2>/dev/null
    else
        sqlite3 "$XUI_DB" "insert into settings(key,value) values('$key','$value');" 2>/dev/null
    fi
}

backup_file(){
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        echo "$backup"
    fi
}

detect_panel_port(){
    local db_port
    db_port="$(sqlite_get_setting "webPort")"
    if [[ "$db_port" =~ ^[0-9]+$ ]]; then PANEL_PORT="$db_port"; pass "从数据库检测到面板端口：$PANEL_PORT"; return 0; fi
    local port_line
    port_line="$(ss -ltnp 2>/dev/null | grep -Ei 'x-ui|3x-ui' | head -n 1)"
    if [ -n "$port_line" ]; then
        PANEL_PORT="$(echo "$port_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/')"
        [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && pass "从监听进程检测到面板端口：$PANEL_PORT" && return 0
    fi
    PANEL_PORT="7777"; warn "未能自动检测面板端口，使用默认端口：7777"; return 1
}

detect_panel_path(){
    PANEL_PATH=""
    for key in webBasePath webPath basePath panelPath; do
        local v; v="$(sqlite_get_setting "$key")"
        [ -n "$v" ] && PANEL_PATH="$v" && break
    done
    if [ -z "$PANEL_PATH" ]; then
        PANEL_PATH="/"; warn "未能从数据库检测到面板路径，暂用 / 进行检测"
    else
        [[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
        [[ "$PANEL_PATH" != */ ]] && PANEL_PATH="${PANEL_PATH}/"
        pass "检测到面板路径：$PANEL_PATH"
    fi
}

detect_acme(){
    if [ ! -x "$ACME_BIN" ]; then fail "未检测到 acme.sh：$ACME_BIN"; return 1; fi
    pass "检测到 acme.sh：$ACME_BIN"
    local ecc_conf="${ACME_HOME}/${DOMAIN}_ecc/${DOMAIN}.conf"
    local rsa_conf="${ACME_HOME}/${DOMAIN}/${DOMAIN}.conf"
    if [ -f "$ecc_conf" ]; then
        ACME_CONF="$ecc_conf"; ACME_CERT_DIR="${ACME_HOME}/${DOMAIN}_ecc"; ACME_KEY_TYPE="ECC"; ACME_INSTALL_FLAG=(--ecc)
        pass "检测到 ECC 证书配置：$ACME_CONF"
    elif [ -f "$rsa_conf" ]; then
        ACME_CONF="$rsa_conf"; ACME_CERT_DIR="${ACME_HOME}/${DOMAIN}"; ACME_KEY_TYPE="RSA"; ACME_INSTALL_FLAG=()
        pass "检测到 RSA 证书配置：$ACME_CONF"
    else
        fail "acme.sh 中未找到该域名证书配置"; return 1
    fi
    info "acme.sh 原始证书目录：$ACME_CERT_DIR"
}

get_acme_var(){
    local key="$1"
    [ -n "$ACME_CONF" ] && [ -f "$ACME_CONF" ] && grep "^${key}=" "$ACME_CONF" | tail -n 1 | cut -d"'" -f2
}

decode_acme_value(){
    local value="$1"
    if echo "$value" | grep -q "__ACME_BASE64__START_"; then
        local encoded
        encoded="$(echo "$value" | sed -E 's/.*__ACME_BASE64__START_([^_]+)__ACME_BASE64__END_.*/\1/')"
        if command_exists base64 && [ -n "$encoded" ]; then echo "$encoded" | base64 -d 2>/dev/null; else echo "$value"; fi
    else
        echo "$value"
    fi
}

ensure_acme_install_cert(){
    if [ -z "$ACME_CONF" ] || [ ! -f "$ACME_CONF" ]; then fail "无法配置 install-cert，因为 acme.sh 域名配置不存在"; return 1; fi
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
        fail "配置 acme.sh install-cert 失败"; return 1
    fi
    [ -f "$TARGET_CERT" ] && pass "续签后会更新 /root/cert.crt" || fail "/root/cert.crt 当前不存在"
    [ -f "$TARGET_KEY" ] && pass "续签后会更新 /root/private.key" || fail "/root/private.key 当前不存在"
    local reload_cmd decoded
    reload_cmd="$(get_acme_var "Le_ReloadCmd")"; decoded="$(decode_acme_value "$reload_cmd")"
    echo "$decoded" | grep -q "systemctl restart $SERVICE_NAME" && pass "续签后会重启 $SERVICE_NAME" || warn "未确认续签后会重启 $SERVICE_NAME"
}

ensure_xui_uses_root_cert(){
    if [ -z "$XUI_DB" ] || [ ! -f "$XUI_DB" ] || ! command_exists sqlite3; then warn "无法自动修正 x-ui 证书路径，因为数据库或 sqlite3 不可用"; return 1; fi
    local cert key changed=0
    cert="$(sqlite_get_setting "webCertFile")"; key="$(sqlite_get_setting "webKeyFile")"
    [ -n "$cert" ] && pass "数据库中的面板证书路径：$cert" || warn "数据库中未检测到 webCertFile"
    [ -n "$key" ] && pass "数据库中的面板私钥路径：$key" || warn "数据库中未检测到 webKeyFile"
    if [ "$cert" != "$TARGET_CERT" ] || [ "$key" != "$TARGET_KEY" ]; then
        local backup; backup="$(backup_file "$XUI_DB")"; [ -n "$backup" ] && info "已备份 x-ui 数据库：$backup"
    fi
    if [ "$cert" != "$TARGET_CERT" ]; then sqlite_set_setting "webCertFile" "$TARGET_CERT" && fix "已将 x-ui 证书路径设置为 /root/cert.crt" && changed=1; else pass "x-ui 当前使用证书路径：/root/cert.crt"; fi
    if [ "$key" != "$TARGET_KEY" ]; then sqlite_set_setting "webKeyFile" "$TARGET_KEY" && fix "已将 x-ui 私钥路径设置为 /root/private.key" && changed=1; else pass "x-ui 当前使用私钥路径：/root/private.key"; fi
    if [ "$changed" -eq 1 ]; then systemctl restart "$SERVICE_NAME" && fix "已重启 $SERVICE_NAME，使证书路径生效" || fail "重启 $SERVICE_NAME 失败"; fi
}

check_certificate_content(){
    if [ ! -f "$TARGET_CERT" ]; then fail "证书文件不存在：$TARGET_CERT"; return 1; fi
    info "当前 $TARGET_CERT 证书信息："
    openssl x509 -in "$TARGET_CERT" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null
    openssl x509 -in "$TARGET_CERT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${DOMAIN}" && pass "证书 SAN 包含域名：$DOMAIN" || fail "证书 SAN 未包含域名：$DOMAIN"
    local not_after end_ts now_ts days_left
    not_after="$(openssl x509 -in "$TARGET_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -n "$not_after" ]; then
        end_ts="$(date -d "$not_after" +%s 2>/dev/null)"; now_ts="$(date +%s)"
        if [ -n "$end_ts" ]; then
            days_left=$(( (end_ts - now_ts) / 86400 ))
            info "证书大约还有 $days_left 天过期"
            if [ "$days_left" -gt 30 ]; then pass "证书有效期健康"; elif [ "$days_left" -gt 7 ]; then warn "证书将在 30 天内过期，请关注续签"; else fail "证书已经非常接近过期或已经过期"; fi
        fi
    fi
}

detect_nginx_and_ports(){
    if command_exists nginx; then
        info "检测到 Nginx 已安装"
        systemctl is-active --quiet nginx && warn "Nginx 正在运行" || pass "Nginx 已安装，但当前未运行"
        nginx -t >/tmp/xui_ssl_nginx_test.log 2>&1 && pass "Nginx 配置测试通过" || { warn "Nginx 配置测试未通过"; cat /tmp/xui_ssl_nginx_test.log; }
    else
        pass "未检测到 Nginx"
    fi
    line; info "80 / 443 端口监听情况："
    ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /\]:80$/ || $4 ~ /:443$/ || $4 ~ /\]:443$/ {print}' || true
    if ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /\]:80$/ {print}' | grep -qi nginx; then NGINX_80=1; warn "80 端口当前由 Nginx 占用"; else pass "80 端口未检测到由 Nginx 占用"; fi
    ss -ltnp 2>/dev/null | awk '$4 ~ /:443$/ || $4 ~ /\]:443$/ {print}' | grep -q . && warn "443 端口当前有服务监听" || pass "443 端口当前未监听"
}

detect_acme_mode(){
    ACME_WEBROOT="$(get_acme_var "Le_Webroot")"
    if [ -z "$ACME_WEBROOT" ]; then ACME_MODE="unknown"; warn "无法识别 acme.sh 当前验证模式，Le_Webroot 为空"
    elif [[ "$ACME_WEBROOT" == dns_* ]]; then ACME_MODE="dns"; pass "当前 acme.sh 是 DNS API 模式：$ACME_WEBROOT"
    elif [ "$ACME_WEBROOT" = "no" ]; then ACME_MODE="standalone"; warn "当前 acme.sh 是 standalone 模式"
    elif [ "$ACME_WEBROOT" = "nginx" ]; then ACME_MODE="nginx"; warn "当前 acme.sh 是 nginx 模式"
    elif [[ "$ACME_WEBROOT" == /* ]]; then ACME_MODE="webroot"; pass "当前 acme.sh 是 Webroot 模式：$ACME_WEBROOT"
    else ACME_MODE="unknown"; warn "无法明确识别 acme.sh 模式：$ACME_WEBROOT"; fi
}

find_nginx_webroot_for_domain(){
    FOUND_WEBROOT=""; NGINX_DOMAIN_CONF_FILE=""
    command_exists nginx || return 1
    local files
    files="$(grep -RslE "server_name[[:space:]].*${DOMAIN}" /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx 2>/dev/null | sort -u)"
    if [ -z "$files" ]; then warn "未在 Nginx 配置中找到 server_name $DOMAIN"; return 1; fi
    local file root_path
    while read -r file; do
        [ -z "$file" ] && continue
        root_path="$(awk '/^[[:space:]]*#/ {next} /root[[:space:]]+/ {gsub(";","",$0); print $2; exit}' "$file")"
        if [ -n "$root_path" ] && [ -d "$root_path" ]; then
            FOUND_WEBROOT="$root_path"; NGINX_DOMAIN_CONF_FILE="$file"
            pass "检测到 Nginx Webroot：$FOUND_WEBROOT"; info "来源配置文件：$file"; return 0
        fi
    done <<< "$files"
    warn "找到了域名配置，但未能识别有效 root 目录"; return 1
}

test_webroot_challenge(){
    local webroot="$1" mode="${2:-public}"
    [ -z "$webroot" ] || [ ! -d "$webroot" ] && return 1
    local challenge_dir="${webroot}/.well-known/acme-challenge"
    local token="xui-ssl-check-$(date +%s)-$RANDOM"
    local content="ok-${token}"
    local body_file="/tmp/xui_ssl_challenge_body_${RANDOM}.txt"
    mkdir -p "$challenge_dir"
    echo "$content" > "${challenge_dir}/${token}"
    chmod 644 "${challenge_dir}/${token}" 2>/dev/null || true

    local url="http://${DOMAIN}/.well-known/acme-challenge/${token}"
    local code="000"
    if [ "$mode" = "local" ]; then
        code="$(curl -k -sL -o "$body_file" -w "%{http_code}" --max-time 15 --resolve "${DOMAIN}:80:127.0.0.1" --resolve "${DOMAIN}:443:127.0.0.1" "$url" || echo "000")"
    else
        code="$(curl -k -sL -o "$body_file" -w "%{http_code}" --max-time 15 "$url" || echo "000")"
    fi

    local result preview
    result="$(cat "$body_file" 2>/dev/null)"
    preview="$(head -c 120 "$body_file" 2>/dev/null | tr '\n' ' ')"
    rm -f "${challenge_dir:?}/${token}" "$body_file"

    if [ "$result" = "$content" ]; then
        if [ "$mode" = "local" ]; then pass "Webroot challenge 本机 Nginx 访问测试通过"; else pass "Webroot challenge 公网访问测试通过"; fi
        return 0
    else
        if [ "$mode" = "local" ]; then warn "Webroot challenge 本机 Nginx 访问测试失败，HTTP状态码：$code，响应预览：$preview"; else warn "Webroot challenge 公网访问测试失败，HTTP状态码：$code，响应预览：$preview"; fi
        return 1
    fi
}

remove_nginx_stop_start_hooks_if_present(){
    [ -n "$ACME_CONF" ] && [ -f "$ACME_CONF" ] || return 0
    if grep -Eq "^Le_PreHook=.*(nginx|c3lzdGVtY3RsIHN0b3Agbmdpbng)" "$ACME_CONF" || grep -Eq "^Le_PostHook=.*(nginx|c3lzdGVtY3RsIHN0YXJ0IG5naW54)" "$ACME_CONF"; then
        local backup; backup="$(backup_file "$ACME_CONF")"; [ -n "$backup" ] && info "已备份 acme.sh 配置：$backup"
        python3 - "$ACME_CONF" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1])
lines=p.read_text().splitlines(True)
out=[]
for line in lines:
    if line.startswith("Le_PreHook=") and ("nginx" in line or "c3lzdGVtY3RsIHN0b3Agbmdpbng" in line):
        continue
    if line.startswith("Le_PostHook=") and ("nginx" in line or "c3lzdGVtY3RsIHN0YXJ0IG5naW54" in line):
        continue
    out.append(line)
p.write_text("".join(out))
PY
        fix "已移除会停止/启动 Nginx 的 acme.sh hook"
    fi
}

repair_nginx_webroot_challenge(){
    local webroot="$1" conf_file="$2"
    [ -n "$webroot" ] && [ -d "$webroot" ] || { warn "无法修复 Webroot：Webroot 目录无效"; return 1; }
    [ -n "$conf_file" ] && [ -f "$conf_file" ] || { warn "无法修复 Webroot：未找到对应 Nginx 配置文件"; return 1; }

    mkdir -p "$webroot/.well-known/acme-challenge"
    chmod 755 "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge" 2>/dev/null || true

    if test_webroot_challenge "$webroot" public; then return 0; fi
    if test_webroot_challenge "$webroot" local; then
        warn "本机 Webroot 测试通过，但公网测试失败；可能是 DNS、CDN、外部防火墙或运营商回环问题。仍将尝试切换 Webroot。"
        return 0
    fi

    info "开始修复 Nginx Webroot challenge，不停止 Nginx，仅在测试通过后 reload"
    local backup; backup="$(backup_file "$conf_file")"; [ -n "$backup" ] && info "已备份 Nginx 配置：$backup"

    command_exists python3 || { warn "无法自动修复 Nginx 配置：系统未安装 python3"; return 1; }

    DOMAIN="$DOMAIN" WEBROOT="$webroot" NGINX_CONF_FILE="$conf_file" python3 <<'PY'
import os, re, sys
from pathlib import Path

domain=os.environ["DOMAIN"]
webroot=os.environ["WEBROOT"]
conf=Path(os.environ["NGINX_CONF_FILE"])
text=conf.read_text()
lines=text.splitlines(True)
out=[]
idx=0
changed=False
server_re=re.compile(r"\bserver\s*\{")

def depth_delta(s):
    return s.count("{")-s.count("}")

def block_has_listen80(block_text):
    # no listen means implicit port 80 in nginx
    if not re.search(r"listen\s+", block_text):
        return True
    return bool(re.search(r"listen\s+[^;]*(:)?80\b", block_text))

def block_has_domain(block_text):
    return bool(re.search(r"server_name\s+[^;]*\b"+re.escape(domain)+r"\b", block_text))

# First collect server blocks so we can know whether there is an exact domain:80 block.
blocks=[]
while idx < len(lines):
    line=lines[idx]
    if not server_re.search(line):
        blocks.append((False,[line],False,False))
        idx+=1
        continue
    block=[line]
    depth=depth_delta(line)
    idx+=1
    while idx < len(lines) and depth > 0:
        block.append(lines[idx])
        depth += depth_delta(lines[idx])
        idx+=1
    bt="".join(block)
    blocks.append((True,block,block_has_listen80(bt),block_has_domain(bt)))

has_exact_80_domain=any(is_server and listen80 and has_domain for is_server,block,listen80,has_domain in blocks)

def repair_block(block):
    global changed
    bt="".join(block)
    # Insert challenge location if missing in this block.
    location = (
        "\n"
        "    # Added by xui-ssl-auto-check for acme.sh Webroot renewal\n"
        "    location ^~ /.well-known/acme-challenge/ {\n"
        f"        root {webroot};\n"
        "        default_type \"text/plain\";\n"
        "        try_files $uri =404;\n"
        "    }\n"
    )

    new=[]
    inner_depth=0
    for n,line in enumerate(block):
        if n==0:
            new.append(line)
            inner_depth += depth_delta(line)
            continue
        stripped=line.strip()
        # Nginx server-level return/rewrite runs before location and can break HTTP-01.
        # Move top-level redirect into location / so challenge location can win.
        is_top_level = (inner_depth == 1)
        is_return_redirect = bool(re.match(r"return\s+30[1278]\s+", stripped))
        is_rewrite_redirect = bool(re.match(r"rewrite\s+.*\s+(permanent|redirect)\s*;", stripped))
        if is_top_level and (is_return_redirect or is_rewrite_redirect):
            indent=line[:len(line)-len(line.lstrip())]
            new.append(f"{indent}location / {{\n")
            new.append(f"{indent}    {stripped}\n")
            new.append(f"{indent}}}\n")
            changed=True
        else:
            new.append(line)
        inner_depth += depth_delta(line)

    bt2="".join(new)
    if ".well-known/acme-challenge" not in bt2:
        # Put it right after the opening server line, before other location/rewrite logic.
        new.insert(1, location)
        changed=True
    return new

for is_server,block,listen80,has_domain in blocks:
    if not is_server:
        out.extend(block)
        continue
    # Prefer exact server_name+80 blocks. If none exists, repair all 80 blocks in the same file
    # because the domain may be handled by default_server or a catch-all redirect block.
    if listen80 and ((has_exact_80_domain and has_domain) or (not has_exact_80_domain)):
        out.extend(repair_block(block))
    else:
        out.extend(block)

if not changed:
    # As a final fallback, append a dedicated HTTP server block. This may be ignored if a previous
    # duplicate server_name exists, but it helps when only HTTPS server blocks were present.
    out.append(
        "\n"
        "# Added by xui-ssl-auto-check for acme.sh Webroot renewal\n"
        "server {\n"
        "    listen 80;\n"
        "    listen [::]:80;\n"
        f"    server_name {domain};\n"
        "    location ^~ /.well-known/acme-challenge/ {\n"
        f"        root {webroot};\n"
        "        default_type \"text/plain\";\n"
        "        try_files $uri =404;\n"
        "    }\n"
        "}\n"
    )
    changed=True

conf.write_text("".join(out))
PY

    if [ $? -ne 0 ]; then
        warn "自动修复 Nginx challenge 配置失败"
        [ -n "$backup" ] && [ -f "$backup" ] && cp -a "$backup" "$conf_file" && warn "已恢复 Nginx 配置备份"
        return 1
    fi

    if nginx -t >/tmp/xui_ssl_nginx_test.log 2>&1; then
        pass "Nginx 配置测试通过"
        systemctl reload nginx && fix "已 reload Nginx，使 Webroot challenge 配置生效" || { warn "Nginx reload 失败"; return 1; }
    else
        warn "Nginx 配置测试失败，正在恢复备份"
        cat /tmp/xui_ssl_nginx_test.log
        [ -n "$backup" ] && [ -f "$backup" ] && cp -a "$backup" "$conf_file"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
        warn "已恢复 Nginx 配置备份"
        return 1
    fi

    if test_webroot_challenge "$webroot" public; then fix "已修复 Webroot challenge 公网访问"; return 0; fi
    if test_webroot_challenge "$webroot" local; then warn "本机 Webroot 测试通过，但公网测试失败；仍将尝试使用 Webroot 重新签发"; return 0; fi

    warn "修复后 Webroot challenge 仍无法访问"
    return 1
}

switch_standalone_to_webroot(){
    [ "$ACME_MODE" = "standalone" ] || return 0
    remove_nginx_stop_start_hooks_if_present

    if [ "$NGINX_80" -ne 1 ]; then
        pass "standalone 模式下 80 端口未被 Nginx 占用，暂不需要切换模式"; return 0
    fi

    warn "检测到 standalone + Nginx 占用 80，将尝试修复 Webroot 模式，避免停止 Nginx"

    find_nginx_webroot_for_domain
    if [ -z "$FOUND_WEBROOT" ]; then fail "无法自动找到安全的 Webroot；未配置 stop/start Nginx hook，避免影响网站运行"; return 1; fi

    repair_nginx_webroot_challenge "$FOUND_WEBROOT" "$NGINX_DOMAIN_CONF_FILE" || { fail "Webroot 自动修复失败；未配置 stop/start Nginx hook，避免影响网站运行"; return 1; }

    info "正在将 acme.sh 验证方式切换为 Webroot 模式"
    info "注意：此步骤会重新签发一次证书，以便保存新的 Webroot 验证方式"
    if [ "$ACME_KEY_TYPE" = "ECC" ]; then
        "$ACME_BIN" --issue -d "$DOMAIN" -w "$FOUND_WEBROOT" --keylength ec-256 --force
    else
        "$ACME_BIN" --issue -d "$DOMAIN" -w "$FOUND_WEBROOT" --force
    fi

    if [ $? -eq 0 ]; then
        fix "已成功切换为 Webroot 模式并重新签发证书"
        detect_acme; detect_acme_mode; remove_nginx_stop_start_hooks_if_present; ensure_acme_install_cert
    else
        fail "Webroot 模式重新签发失败；未配置 stop/start Nginx hook，避免影响网站运行"
        return 1
    fi
}

check_auto_renew(){
    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        pass "acme.sh cron 自动续签任务存在"; crontab -l 2>/dev/null | grep "acme.sh.*--cron"
    else
        warn "未发现 acme.sh cron 自动续签任务，正在尝试安装 cron 任务"
        "$ACME_BIN" --install-cronjob >/dev/null 2>&1
        crontab -l 2>/dev/null | grep -q "acme.sh.*--cron" && fix "已安装 acme.sh cron 自动续签任务" || fail "自动安装 acme.sh cron 任务失败"
    fi
}

check_https_access(){
    if [ -z "$PANEL_PORT" ]; then warn "未检测到面板端口，跳过 HTTPS 访问测试"; return 1; fi
    info "检测本机 HTTPS： https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
    local local_code; local_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 8 "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}" || true)"
    [[ "$local_code" =~ ^(200|301|302)$ ]] && pass "本机 HTTPS 正常，HTTP 状态码：$local_code" || warn "本机 HTTPS 未返回正常状态码：$local_code"

    info "检测公网 HTTPS： https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}"
    local public_code; public_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 12 "https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}" || true)"
    [[ "$public_code" =~ ^(200|301|302)$ ]] && pass "公网 HTTPS 正常，HTTP 状态码：$public_code" || warn "公网 HTTPS 未返回正常状态码，可能受防火墙、安全组、Cloudflare 或面板路径影响：$public_code"

    info "读取面板端口实际提供的证书"
    local served_cert
    served_cert="$(openssl s_client -connect "127.0.0.1:${PANEL_PORT}" -servername "$DOMAIN" -showcerts </dev/null 2>/dev/null | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true)"
    [ -n "$served_cert" ] && { pass "面板端口正在提供 TLS 证书"; echo "$served_cert"; } || warn "无法通过 openssl 读取面板端口证书；如果 curl HTTPS 正常，通常问题不大"
}

print_acme_paths(){
    line; echo "证书路径信息："; echo
    [ -n "$ACME_CERT_DIR" ] && { info "acme.sh 原始证书目录："; echo "       $ACME_CERT_DIR"; }
    [ -f "$TARGET_CERT" ] && pass "x-ui 面板证书路径：/root/cert.crt" || fail "x-ui 面板证书路径不存在：/root/cert.crt"
    [ -f "$TARGET_KEY" ] && pass "x-ui 面板私钥路径：/root/private.key" || fail "x-ui 面板私钥路径不存在：/root/private.key"
    if [ -n "$ACME_CONF" ] && [ -f "$ACME_CONF" ]; then
        info "acme.sh 关键安装配置："
        grep -E "Le_Webroot|Le_RealCertPath|Le_RealFullChainPath|Le_RealKeyPath|Le_ReloadCmd|Le_PreHook|Le_PostHook" "$ACME_CONF" || true
    fi
}

advice_for_message(){
    local level="$1" msg="$2"
    case "$msg" in
        *"Webroot challenge 公网访问测试失败"*) echo "建议：请看状态码和响应预览。新版会同时测试公网与本机 Nginx；如果本机失败，多半是 Nginx 80 server 块/顶层跳转/默认站点问题。";;
        *"本机 Webroot 测试通过，但公网测试失败"*) echo "建议：Nginx 本机配置已正常，公网失败多与 DNS、CDN、外部防火墙、回源规则有关。";;
        *"standalone 模式"*) echo "建议：standalone 续签可能需要 80 端口；新版会修复 Webroot，避免停止 Nginx。";;
        *"80 端口当前由 Nginx 占用"*) echo "建议：Nginx 占用 80 是正常网站状态；新版会使用 Webroot，不再停止 Nginx。";;
        *"已移除会停止/启动 Nginx"*) echo "说明：旧版 stop/start hook 已移除，未来续签不会主动停止 Nginx。";;
        *"已成功切换为 Webroot 模式"*) echo "说明：后续续签将走 Webroot，不需要抢占 80 端口，也不需要停止 Nginx。";;
        *"已 reload Nginx"*) echo "说明：Nginx 已平滑重载，不会像 stop/start 那样中断网站。";;
        *"已配置 acme.sh install-cert"*) echo "说明：续签后会复制到 /root/cert.crt 和 /root/private.key，并执行 reloadcmd。";;
        *) if [ "$level" = "FIX" ]; then echo "说明：该项目已由脚本自动处理。建议重新运行脚本复查。"; elif [ "$level" = "FAIL" ]; then echo "建议：这是明确异常，需要优先处理。"; else echo "建议：这是风险提醒，不一定是故障。"; fi;;
    esac
}

print_issue_details(){
    echo; line; echo "WARN / FIX / FAIL 详情与建议"; line
    if [ "$FAIL_COUNT" -gt 0 ]; then echo; echo "FAIL 详情："; local i=1 item; for item in "${FAIL_MESSAGES[@]}"; do echo "[$i] $item"; advice_for_message "FAIL" "$item"; echo; i=$((i+1)); done; fi
    if [ "$WARN_COUNT" -gt 0 ]; then echo; echo "WARN 详情："; local i=1 item; for item in "${WARN_MESSAGES[@]}"; do echo "[$i] $item"; advice_for_message "WARN" "$item"; echo; i=$((i+1)); done; fi
    if [ "$FIX_COUNT" -gt 0 ]; then echo; echo "FIX 详情："; local i=1 item; for item in "${FIX_MESSAGES[@]}"; do echo "[$i] $item"; advice_for_message "FIX" "$item"; echo; i=$((i+1)); done; fi
    [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ] && [ "$FIX_COUNT" -eq 0 ] && echo "没有 WARN / FIX / FAIL 详情。"
}

print_summary(){
    line; echo "检测与修复结果汇总"; line
    echo "域名              : $DOMAIN"
    echo "服务              : $SERVICE_NAME"
    echo "面板端口          : ${PANEL_PORT:-Unknown}"
    echo "面板路径          : ${PANEL_PATH:-Unknown}"
    echo "acme.sh 类型      : ${ACME_KEY_TYPE:-Unknown}"
    echo "acme.sh 模式      : ${ACME_MODE:-Unknown}"
    echo "acme.sh 证书目录  : ${ACME_CERT_DIR:-Unknown}"

    if [ -f "$TARGET_CERT" ]; then
        local start end end_ts now_ts days
        start="$(openssl x509 -in "$TARGET_CERT" -noout -startdate 2>/dev/null | cut -d= -f2)"
        end="$(openssl x509 -in "$TARGET_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
        end_ts="$(date -d "$end" +%s 2>/dev/null)"; now_ts="$(date +%s)"
        [ -n "$end_ts" ] && days=$(( (end_ts - now_ts) / 86400 )) || days="Unknown"
        echo "证书签发日期      : ${start:-Unknown}"
        echo "证书到期日期      : ${end:-Unknown}"
        echo "证书剩余天数      : ${days} 天"
    else
        echo "证书签发日期      : Unknown"; echo "证书到期日期      : Unknown"; echo "证书剩余天数      : Unknown"
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
    if [ "$FAIL_COUNT" -gt 0 ]; then echo -e "整体状态：${RED}Failed${NC}"; elif [ "$WARN_COUNT" -gt 0 ]; then echo -e "整体状态：${YELLOW}Warning${NC}"; else echo -e "整体状态：${GREEN}Healthy${NC}"; fi
    line
}

main(){
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then show_help; exit 0; fi
    need_root
    echo; line; echo "x-ui / 3x-ui SSL 自动检测与修复工具"; line; echo
    ask_domain "$1"

    line; info "开始检测系统基础信息"
    echo "Hostname : $(hostname)"; echo "User     : $(whoami)"; echo "Date     : $(date)"
    [ -f /etc/os-release ] && . /etc/os-release && echo "OS       : ${PRETTY_NAME:-Unknown}"
    line

    install_sqlite3_if_needed
    detect_service
    detect_db
    detect_panel_port
    detect_panel_path

    detect_acme
    if [ $? -ne 0 ]; then fail "没有 acme.sh 证书配置，无法继续自动配置续签链路"; print_summary; exit 1; fi

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
