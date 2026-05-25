#!/usr/bin/env bash
set -e

INSTALL_PATH="/root/xui-ssl-auto-check.sh"
RAW_URL="${RAW_URL:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] 请使用 root 权限运行，例如 sudo -i 后再执行"
    exit 1
fi

if [ -z "$RAW_URL" ]; then
    RAW_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/xui-ssl-auto-check.sh"
fi

echo "Installing x-ui / 3x-ui SSL Auto Check tool..."
echo "Source: $RAW_URL"
echo "Target: $INSTALL_PATH"

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_URL" -o "$INSTALL_PATH"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$INSTALL_PATH" "$RAW_URL"
else
    echo "[FAIL] curl 和 wget 都没有安装，无法下载脚本"
    exit 1
fi

chmod +x "$INSTALL_PATH"

echo
echo "[PASS] 安装完成：$INSTALL_PATH"
echo
echo "运行方式："
echo "  $INSTALL_PATH"
echo "  $INSTALL_PATH tim.google.com"
echo
echo "注意：tim.google.com 只是格式示例，请替换为你自己的域名。"
