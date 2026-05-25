#!/usr/bin/env bash
set -e

INSTALL_PATH="/root/xui-ssl-auto-check.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] 请使用 root 权限运行，例如 sudo -i 后再执行"
    exit 1
fi

echo "Uninstalling x-ui / 3x-ui SSL Auto Check tool..."

if [ -f "$INSTALL_PATH" ]; then
    rm -f "$INSTALL_PATH"
    echo "[PASS] 已删除：$INSTALL_PATH"
else
    echo "[INFO] 未找到：$INSTALL_PATH，无需删除"
fi

echo
cat <<'NOTE'
说明：
- 本卸载脚本只删除检测工具本身：/root/xui-ssl-auto-check.sh
- 不会删除 acme.sh
- 不会删除 /root/cert.crt 或 /root/private.key
- 不会还原 x-ui 数据库
- 不会删除已有的 acme.sh 续签配置

如果你需要回滚证书路径或 acme.sh hook，请使用脚本运行时自动生成的 .bak 备份文件手动恢复。
NOTE
