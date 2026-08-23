# x-ui / 3x-ui SSL Auto Install, Check & Repair

这是一个用于 **x-ui / 3x-ui 面板 SSL 证书首次签发、检测、自动修复与续签配置** 的 Bash 工具。

它面向多台 VPS 重复部署：推荐只执行 **一条命令**，然后输入域名。安装器会自动下载最新版主程序、设置执行权限、安装缺失的 acme.sh、首次签发证书，并继续运行原有的检测与修复流程。

> 文档中的 `sg1.example.com` 仅作格式示例，请替换成你自己的真实域名。

---

## 一条命令完成安装、首次签发和检查

以 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh)
```

随后会提示：

```text
👉 请输入需要配置 SSL 的域名（例如 sg1.example.com）:
```

输入域名后，剩余流程自动完成。

也可以直接把域名放在命令后面：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh) sg1.example.com
```

### 一键安装器会自动完成

1. 下载或更新 `/root/xui-ssl-auto-check.sh`；
2. 自动执行 `chmod`，不需要用户手工设置执行权限；
3. 检查基础命令，例如 `openssl`、`ss`；
4. 如果没有 acme.sh，自动通过官方 `get.acme.sh` 安装；
5. 将新证书默认 CA 设置为 **Let's Encrypt**；
6. 确保 acme.sh cron 自动续签任务存在；
7. 如果目标域名从未签发过证书：
   - 检查域名 IPv4 解析；
   - 检查 TCP 80；
   - 如果 80 被已识别的 `nginx / apache2 / httpd / caddy` systemd 服务占用，会在首次 HTTP-01 验证期间临时停止该服务；
   - 如果 80 仍被未知程序占用，会停止操作并显示占用者，不会暴力 kill；
   - 使用 Let's Encrypt + standalone + ECC P-256 完成首次签发；
   - 无论成功或失败，尽可能恢复之前临时停止的 Web 服务；
8. 自动进入主检测与修复程序；
9. 把证书安装到：

```text
/root/cert.crt
/root/private.key
```

10. 自动检查并修正 x-ui / 3x-ui 的证书路径；
11. 检测续签方式、Nginx、80/443、面板 HTTPS 和证书有效期；
12. 如果是 `standalone + Nginx:80`，继续使用现有 **Webroot-first** 修复逻辑，尽量让后续续签无需停止 Nginx。

---

## 设计原则

### 首次签发：安全 Bootstrap

新 VPS 或新域名可能完全没有 acme.sh 证书配置。安装器会先把证书签出来，再交给主程序维护。

首次签发使用 HTTP-01 standalone，因此必须让 CA 能访问：

```text
http://你的域名/.well-known/acme-challenge/...
```

如果 TCP 80 被已识别的 Web 服务占用，安装器只会临时停止已确认的 systemd 服务。它不会对未知 PID 使用 `kill -9`。

### 后续维护：Webroot-first

主程序原有策略继续保留：当检测到 `standalone + Nginx 占用 80` 时，优先尝试 Webroot challenge。

它会：

1. 找到域名对应的 Nginx `server_name` 和 Webroot；
2. 创建 `/.well-known/acme-challenge/`；
3. 先做本机和公网 challenge 测试；
4. 必要时备份 Nginx 配置；
5. 插入 challenge location；
6. 只有 `nginx -t` 成功才 reload；
7. 再次测试 challenge；
8. 测试成功后把 acme.sh 切到 Webroot 并重新签发；
9. 移除旧版遗留的 Nginx stop/start hooks。

目标是让正常续签尽量不造成网站中断。

---

## 主程序功能

`xui-ssl-auto-check.sh` 会自动检测和修复：

- `x-ui / 3x-ui / xui` systemd 服务；
- 面板端口；
- 面板路径；
- `x-ui.db`；
- acme.sh 证书目录；
- ECC / RSA 证书类型；
- 证书签发日期、到期日期和剩余天数；
- `/root/cert.crt` 与 `/root/private.key` 安装路径；
- acme.sh `install-cert` / `reloadcmd`；
- x-ui 数据库中的证书和私钥路径；
- Nginx 80 / 443 监听；
- acme.sh standalone / Webroot / DNS API / nginx 模式；
- acme.sh cron 自动续签；
- 本机和公网面板 HTTPS；
- 面板端口实际提供的 TLS 证书。

脚本会使用：

```text
[PASS] 正常
[WARN] 风险提醒
[FAIL] 明确异常
[FIX]  已自动修复
```

并在最后输出汇总。

---

## 已有 VPS 直接运行主程序

如果服务器已经安装过此工具，可以直接运行：

```bash
/root/xui-ssl-auto-check.sh
```

然后输入域名。

也可以：

```bash
/root/xui-ssl-auto-check.sh sg1.example.com
```

> 对于完全没有 acme.sh 或从未给该域名签发过证书的新 VPS，推荐重新使用上面的 `install.sh` 一键命令，因为安装器包含首次初始化能力。

---

## 只运行主程序，不安装

适合已经完成 acme.sh / 证书初始化的 VPS：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/xui-ssl-auto-check.sh)
```

或：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/xui-ssl-auto-check.sh) sg1.example.com
```

---

## 更新

直接重新执行一键命令即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh)
```

它会覆盖更新 `/root/xui-ssl-auto-check.sh`，自动设置执行权限，然后立即进入检测流程。

---

## 一键卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/uninstall.sh)
```

卸载脚本只删除检测工具本身，不会主动删除：

- acme.sh；
- `/root/cert.crt`；
- `/root/private.key`；
- x-ui 数据库；
- 已有 acme.sh 续签配置。

如果主程序此前自动修改过 x-ui 数据库或 Nginx 配置，会保留 `.bak` 备份供手工恢复。

---

## 系统要求

推荐：

- Debian 10+
- Ubuntu 20.04+
- root 权限
- 已安装 x-ui 或 3x-ui
- 域名 DNS 已正确配置
- VPS 的 TCP 80 能被公网访问，用于首次 HTTP-01 验证
- VPS 能访问 Let's Encrypt / GitHub / get.acme.sh

**不再要求预先安装 acme.sh，也不再要求目标域名已经签发过证书。**

---

## 证书路径

工具统一使用：

```text
/root/cert.crt
/root/private.key
```

主程序会确保 acme.sh 后续续签成功后，把最新证书复制到这些生产路径，并重启检测到的 x-ui / 3x-ui 服务。

不要让面板直接引用 `~/.acme.sh/<domain>/` 内部证书文件；这些目录属于 acme.sh 自身管理。

---

## 常见问题

### 1. HTTP-01 返回 502 Bad Gateway

如果 CA 验证时看到：

```text
502 Bad Gateway
nginx
```

通常说明验证请求到达了 Nginx，而没有到达 acme.sh standalone 临时服务器，或者 Nginx challenge 配置不正确。

一键安装器首次签发时会检查并释放 TCP 80；已有证书环境则由主程序尝试修复 Webroot。

### 2. TCP 80 被未知程序占用

脚本会显示 `ss -lntp` 的占用信息并停止，不会自动杀进程。请先确认占用者，再决定如何处理。

### 3. Nginx 出现 conflicting server name

例如：

```text
conflicting server name "sg1.example.com" on 0.0.0.0:80, ignored
```

说明同一个域名在多个 Nginx `server` 块中重复声明。工具不会擅自删除你的站点配置，应由管理员确认哪一份配置需要保留。

### 4. Cloudflare / CDN

DNS 查询结果不一定等于 VPS Origin IP，例如开启 Cloudflare Proxy 时会返回 Cloudflare IP。因此安装器的 DNS 检查只做提示，不会仅因为 IP 不一致就强制退出。

HTTP-01 最终仍要求 CA 能通过域名访问到正确 challenge 内容。

---

## 文件说明

```text
xui-ssl-auto-check.sh   主检测与修复程序
install.sh              一键安装 / 更新 / 首次签发 / 自动运行
uninstall.sh            一键卸载工具
README.md               使用说明
```

---

## 常用命令

一键安装 / 更新 / 自动运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh)
```

直接指定域名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh) sg1.example.com
```

运行已安装的主程序：

```bash
/root/xui-ssl-auto-check.sh
```

帮助：

```bash
/root/xui-ssl-auto-check.sh --help
```

卸载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/uninstall.sh)
```

---

## 安全说明

- 工具会修改 acme.sh 的证书安装配置；
- 主程序可能修改 x-ui 数据库中的证书路径，修改前会备份；
- 主程序可能修改目标域名的 Nginx Webroot challenge 配置，修改前会备份，并要求 `nginx -t` 通过；
- 首次签发时，为给 standalone HTTP-01 释放 TCP 80，可能短暂停止已识别的 Web 服务；
- 未识别的 TCP 80 占用者不会被自动终止；
- 不建议频繁强制重新签发证书，以避免触发 CA rate limit。
