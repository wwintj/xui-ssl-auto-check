#!/usr/bin/env bash
set -u
set -o pipefail

INSTALL_PATH="/root/xui-ssl-auto-check.sh"
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/xui-ssl-auto-check.sh}"
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
DOMAIN="${1:-}"
STOPPED_SERVICE=""

fail() { echo "[FAIL] $*"; exit 1; }
info() { echo "[INFO] $*"; }
pass() { echo "[PASS] $*"; }
warn() { echo "[WARN] $*"; }

cleanup() {
    if [ -n "$STOPPED_SERVICE" ]; then
        if systemctl is-active --quiet "$STOPPED_SERVICE" 2>/dev/null; then
            STOPPED_SERVICE=""
            return 0
        fi
        echo
        info "正在恢复 $STOPPED_SERVICE ..."
        systemctl start "$STOPPED_SERVICE" 2>/dev/null || warn "无法自动恢复 $STOPPED_SERVICE，请手动检查"
        STOPPED_SERVICE=""
    fi
}
trap cleanup EXIT INT TERM

if [ "$(id -u)" -ne 0 ]; then
    fail "请使用 root 权限运行，例如 sudo -i 后再执行"
fi

if [ -z "$DOMAIN" ]; then
    echo
    read -r -p "👉 请输入需要配置 SSL 的域名（例如 sg1.example.com）: " DOMAIN
fi

[ -n "$DOMAIN" ] || fail "域名不能为空"
[[ "$DOMAIN" != \*.* ]] || fail "当前自动初始化流程不支持通配符域名"
[[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || fail "域名格式看起来不正确：$DOMAIN"

echo
echo "============================================================"
echo " x-ui / 3x-ui SSL 一键安装、签发、检测与修复"
echo "============================================================"
echo "域名: $DOMAIN"
echo

# ------------------------------------------------------------
# 1. Install/update main tool
# ------------------------------------------------------------
info "正在安装 / 更新主程序 ..."

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_URL" -o "${INSTALL_PATH}.tmp" || fail "下载主程序失败"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "${INSTALL_PATH}.tmp" "$RAW_URL" || fail "下载主程序失败"
else
    fail "curl 和 wget 都没有安装，无法下载主程序"
fi

mv "${INSTALL_PATH}.tmp" "$INSTALL_PATH" || fail "无法安装主程序到 $INSTALL_PATH"
chmod 700 "$INSTALL_PATH" || fail "无法设置主程序执行权限"
pass "主程序已安装：$INSTALL_PATH"

# ------------------------------------------------------------
# 2. Ensure basic packages
# ------------------------------------------------------------
ensure_package() {
    local command_name="$1"
    shift
    command -v "$command_name" >/dev/null 2>&1 && return 0

    info "缺少 $command_name，正在尝试自动安装 ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@" >/dev/null 2>&1 || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" >/dev/null 2>&1 || return 1
    else
        return 1
    fi

    command -v "$command_name" >/dev/null 2>&1
}

ensure_package openssl openssl || fail "无法安装 openssl"
if ! command -v ss >/dev/null 2>&1; then
    info "缺少 ss，正在尝试自动安装 ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 >/dev/null 2>&1 || fail "无法安装 iproute2/ss"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iproute >/dev/null 2>&1 || fail "无法安装 iproute/ss"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iproute >/dev/null 2>&1 || fail "无法安装 iproute/ss"
    else
        fail "系统缺少 ss，且无法自动安装 iproute/iproute2"
    fi
fi

# Main tool can install sqlite3 itself. Curl/wget is already present because install succeeded.

# ------------------------------------------------------------
# 3. Install acme.sh when missing
# ------------------------------------------------------------
if [ ! -x "$ACME_BIN" ]; then
    info "未检测到 acme.sh，正在自动安装官方 acme.sh ..."

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.acme.sh | sh >/tmp/xui_ssl_acme_install.log 2>&1 || {
            cat /tmp/xui_ssl_acme_install.log
            fail "acme.sh 安装失败"
        }
    else
        wget -qO- https://get.acme.sh | sh >/tmp/xui_ssl_acme_install.log 2>&1 || {
            cat /tmp/xui_ssl_acme_install.log
            fail "acme.sh 安装失败"
        }
    fi

    [ -x "$ACME_BIN" ] || fail "acme.sh 安装完成后仍未找到 $ACME_BIN"
    pass "acme.sh 安装完成"
else
    pass "已检测到 acme.sh"
fi

# Keep future new certificates on Let's Encrypt.
"$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || warn "无法设置默认 CA 为 Let's Encrypt"
"$ACME_BIN" --install-cronjob >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 4. Bootstrap the first certificate when this domain has none
# ------------------------------------------------------------
ECC_CONF="${ACME_HOME}/${DOMAIN}_ecc/${DOMAIN}.conf"
RSA_CONF="${ACME_HOME}/${DOMAIN}/${DOMAIN}.conf"

if [ ! -f "$ECC_CONF" ] && [ ! -f "$RSA_CONF" ]; then
    echo
    info "该域名尚无 acme.sh 证书配置，将执行首次签发"

    # DNS check is informative only: Cloudflare/CDN proxy may intentionally hide origin IP.
    if command -v getent >/dev/null 2>&1; then
        RESOLVED_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ',' -)"
        [ -n "$RESOLVED_IPS" ] && info "域名 IPv4 解析：$RESOLVED_IPS" || warn "当前未解析到域名 IPv4，请确认 DNS 已生效"
    fi

    # Standalone bootstrap needs TCP 80. Stop only known active systemd web servers.
    if ss -lntp 2>/dev/null | grep -qE '(:|\])80[[:space:]]'; then
        for svc in nginx apache2 httpd caddy; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                info "TCP 80 正在使用，临时停止 $svc 以完成首次 HTTP-01 验证"
                systemctl stop "$svc" || fail "无法停止 $svc"
                STOPPED_SERVICE="$svc"
                sleep 2
                break
            fi
        done
    fi

    if ss -lntp 2>/dev/null | grep -qE '(:|\])80[[:space:]]'; then
        echo
        warn "TCP 80 仍被以下进程占用："
        ss -lntp 2>/dev/null | grep -E '(:|\])80[[:space:]]' || true
        fail "为避免误杀未知进程，已停止首次签发。请先释放 TCP 80 后重试"
    fi

    pass "TCP 80 已可用于 standalone 验证"
    info "正在通过 Let's Encrypt 首次签发 ECC 证书 ..."

    "$ACME_BIN" \
        --issue \
        --server letsencrypt \
        -d "$DOMAIN" \
        --standalone \
        --keylength ec-256
    ISSUE_RC=$?

    cleanup

    [ "$ISSUE_RC" -eq 0 ] || fail "首次证书签发失败，请根据上方 acme.sh 输出检查 DNS、80 端口、防火墙或 CDN 设置"
    pass "首次证书签发成功"
else
    pass "该域名已有 acme.sh 证书配置，跳过首次签发"
fi

# ------------------------------------------------------------
# 5. Run the existing mature check/repair flow
# ------------------------------------------------------------
echo
info "启动 SSL 自动检测与修复主程序 ..."
trap - EXIT INT TERM
exec "$INSTALL_PATH" "$DOMAIN"
