# x-ui / 3x-ui SSL Auto Install, Check & Repair

一个面向 **x-ui / 3x-ui** 的 SSL 证书一键安装、首次签发、检测、修复和自动续签工具。

适合在多台 VPS 上重复使用。对于全新 VPS，不需要手工安装 acme.sh，也不需要先手工签发证书：**执行一条命令，输入域名，剩余流程自动完成。**

> 文档中的 `sg1.example.com` 仅作格式示例，请替换成你自己的真实域名。

---

## 🚀 一条命令开始

请先切换到 root：

```bash
sudo -i
```

然后执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh)
```

脚本会提示：

```text
👉 请输入需要配置 SSL 的域名（例如 sg1.example.com）:
```

输入域名后，无需再执行其他命令。

也可以直接把域名作为参数传入：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh) sg1.example.com
```

---

## ✅ 一键流程会自动做什么

安装器会自动：

1. 下载或更新 `/root/xui-ssl-auto-check.sh`；
2. 自动设置执行权限，不需要手工 `chmod +x`；
3. 检查 `openssl`、`ss` 等基础工具；
4. 如果没有 acme.sh，自动安装官方 acme.sh；
5. 将新证书默认 CA 设置为 **Let's Encrypt**；
6. 确保 acme.sh cron 自动续签任务存在；
7. 自动判断目标域名是否已经存在 ECC / RSA 证书配置；
8. 如果是新域名，自动执行首次证书签发；
9. 自动进入现有 SSL 检测与修复流程；
10. 将生产证书统一安装到：

```text
/root/cert.crt
/root/private.key
```

11. 自动检查并修正 x-ui / 3x-ui 的证书路径；
12. 自动检查证书有效期、续签配置、Nginx、80/443 端口和面板 HTTPS；
13. 如果适合，会把后续续签从 standalone 自动修复为 **Webroot**，减少续签时对 Nginx 的影响。

---

## 🆕 全新 VPS / 新域名的首次签发

如果 acme.sh 尚未安装，安装器会自动安装。

如果该域名从未通过 acme.sh 签发过证书，安装器会自动使用：

```text
CA        : Let's Encrypt
Challenge : HTTP-01 standalone
Key       : ECC P-256
Port      : TCP 80
```

首次 HTTP-01 验证要求 CA 能通过公网访问：

```text
http://你的域名/.well-known/acme-challenge/...
```

### TCP 80 已被占用时

如果 TCP 80 被以下已识别的 systemd Web 服务占用：

```text
nginx
apache2
httpd
caddy
```

安装器会：

```text
临时停止 Web 服务
        ↓
确认 TCP 80 已释放
        ↓
完成 Let's Encrypt HTTP-01 验证
        ↓
恢复原 Web 服务
```

无论签发成功还是失败，脚本都会尽可能恢复之前临时停止的服务。

如果 TCP 80 仍被未知程序占用，脚本会显示占用信息并安全退出，**不会自动 kill 未识别进程**。

---

## 🔄 后续自动续签：Webroot-first

首次证书建立以后，主程序会继续检测 acme.sh 当前验证方式。

如果发现：

```text
standalone + Nginx 占用 TCP 80
```

会优先尝试把后续续签切换为 Webroot，而不是每次续签都停止 Nginx。

Webroot 修复流程包括：

1. 找到域名对应的 Nginx `server_name`；
2. 检测可用 Webroot；
3. 创建 `/.well-known/acme-challenge/`；
4. 做本机与公网 challenge 测试；
5. 必要时备份 Nginx 配置；
6. 自动加入 ACME challenge location；
7. 执行 `nginx -t`；
8. 只有配置检查通过才 reload Nginx；
9. 再次测试 challenge；
10. 成功后用 Webroot 重新签发并保存新的续签方式；
11. 清理旧版本遗留的 Nginx stop/start hooks。

目标是让日常自动续签尽量做到：

```text
不停 Nginx
只 reload
自动更新证书
自动重启 x-ui / 3x-ui
```

---

## 🔍 主程序会检查什么

`xui-ssl-auto-check.sh` 会自动检测和修复：

- `x-ui / 3x-ui / xui` systemd 服务；
- 面板端口；
- 面板路径；
- `x-ui.db`；
- acme.sh 证书目录；
- ECC / RSA 证书类型；
- 证书 SAN；
- 证书签发日期、到期日期和剩余天数；
- `/root/cert.crt` 和 `/root/private.key`；
- acme.sh `install-cert`；
- acme.sh `reloadcmd`；
- x-ui 数据库中的证书路径；
- Nginx 80 / 443 监听；
- standalone / Webroot / DNS API / nginx 验证模式；
- acme.sh cron 自动续签；
- 本机 HTTPS；
- 公网 HTTPS；
- 面板端口实际提供的 TLS 证书。

输出状态：

```text
[PASS] 正常
[WARN] 风险提醒
[FAIL] 明确异常
[FIX]  已自动修复
```

最后会输出完整汇总。

---

## 📁 证书路径

工具统一使用：

```text
/root/cert.crt
/root/private.key
```

主程序会确保 acme.sh 后续续签成功后，把最新证书复制到这两个生产路径，并重启检测到的 x-ui / 3x-ui 服务。

不建议让面板直接引用：

```text
/root/.acme.sh/<domain>/...
```

因为该目录属于 acme.sh 内部管理目录。

---

## ♻️ 已安装后的使用方式

再次检查 / 修复：

```bash
/root/xui-ssl-auto-check.sh
```

然后输入域名。

或者直接指定：

```bash
/root/xui-ssl-auto-check.sh sg1.example.com
```

查看帮助：

```bash
/root/xui-ssl-auto-check.sh --help
```

---

## ⬆️ 更新

直接重新执行同一条一键命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh)
```

安装器会自动覆盖更新 `/root/xui-ssl-auto-check.sh`、设置权限，并继续运行检测流程。

---

## 🗑️ 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/uninstall.sh)
```

卸载只删除本工具，不会主动删除：

- acme.sh；
- `/root/cert.crt`；
- `/root/private.key`；
- x-ui 数据库；
- 已有 acme.sh 证书配置；
- 已有 acme.sh 自动续签配置。

如果主程序曾自动修改 x-ui 数据库或 Nginx 配置，会保留 `.bak` 备份供手工恢复。

---

## 🖥️ 系统要求

推荐环境：

- Debian 10+
- Ubuntu 20.04+
- root 权限
- 已安装 x-ui 或 3x-ui
- 域名 DNS 已正确配置
- 首次签发时 TCP 80 可被公网访问
- VPS 可以访问 GitHub、Let's Encrypt 和 `get.acme.sh`

**不要求预先安装 acme.sh，也不要求目标域名已经签发过证书。**

---

## 🛠️ 常见问题

### 1. HTTP-01 返回 `502 Bad Gateway`

如果 ACME 验证时看到：

```text
502 Bad Gateway
nginx
```

通常表示 CA 的验证请求到达了 Nginx，而没有到达 acme.sh standalone 临时服务器，或者当前 Nginx challenge 配置不正确。

首次签发时，一键安装器会检查并释放 TCP 80；已有证书环境则由主程序继续尝试 Webroot 修复。

### 2. TCP 80 被未知程序占用

脚本会输出：

```bash
ss -lntp
```

对应的监听信息并停止操作。

它不会自动对未知服务执行 `kill` 或 `kill -9`。

### 3. Nginx 出现 `conflicting server name`

例如：

```text
conflicting server name "sg1.example.com" on 0.0.0.0:80, ignored
```

说明同一个域名在多个 Nginx `server` 块中重复声明。

工具不会擅自删除你的站点配置，应由管理员确认哪一个 `server` 块应该保留。

### 4. Cloudflare / CDN

如果开启 Cloudflare Proxy，域名解析到的公网 IP 可能是 Cloudflare 节点，而不是 VPS Origin IP。

因此安装器的 DNS IPv4 检查只作为提示，不会单纯因为解析 IP 与 VPS IP 不一致就强制退出。

HTTP-01 最终仍要求 CA 能通过域名访问到正确的 challenge 内容。

### 5. 证书签发失败后 Nginx 会不会一直停着？

安装器有恢复逻辑。只要是它自己临时停止的已识别 Web 服务，在正常失败路径和退出路径中都会尽可能恢复。

如果系统本身存在异常，仍建议执行：

```bash
systemctl status nginx --no-pager -l
ss -lntp | grep ':80 '
```

确认实际状态。

---

## 📦 文件说明

```text
xui-ssl-auto-check.sh   主检测与修复程序
install.sh              一键安装 / 更新 / 首次签发 / 自动运行
uninstall.sh            一键卸载工具
README.md               使用说明
```

---

## 🔐 安全策略

- 不自动 kill 未识别的 TCP 80 占用进程；
- 修改 x-ui 数据库前会创建备份；
- 修改 Nginx 配置前会创建备份；
- Nginx 自动修改后必须通过 `nginx -t` 才会 reload；
- 首次签发仅在必要时临时停止已识别的 Web 服务；
- 后续维护优先使用 Webroot，尽量避免停止 Nginx；
- 不建议频繁强制重新签发证书，以避免触发 CA rate limit。

---

## License

请根据仓库实际 License 文件使用本项目。
