# x-ui / 3x-ui SSL Auto Check & Repair

这是一个用于 **x-ui / 3x-ui 面板 SSL 证书检测与自动修复** 的 Bash 脚本。

它适合在多台 VPS 上重复使用：你只需要输入域名，脚本会自动检测面板服务、面板端口、证书路径、acme.sh 续签配置，以及 Nginx 80 端口是否会影响证书续签。

> 说明：文档中的 `tim.google.com` 仅作格式示例，请替换成你自己的真实域名。

---

## 功能

脚本会自动完成以下检查和修复：

- 自动检测 `x-ui / 3x-ui` 服务名
- 自动检测面板端口
- 自动检测面板路径
- 自动检测 `x-ui.db`
- 自动检测 acme.sh 证书目录
- 自动判断证书是 ECC 还是 RSA
- 显示证书签发日期、到期日期、剩余天数
- 自动确保续签后的证书安装到：

```bash
/root/cert.crt
/root/private.key
```

- 自动确保续签成功后重启面板：

```bash
systemctl restart x-ui
```

或：

```bash
systemctl restart 3x-ui
```

- 检测 Nginx 是否占用 80 / 443 端口
- 判断 acme.sh 是否是 standalone / Webroot / DNS API 模式
- 如果检测到 `standalone + Nginx 占用 80`：
  - 优先尝试切换到 Webroot 模式
  - 如果 Webroot 不满足条件，则自动配置续签 hook：
    - 续签前停止 Nginx
    - 续签后启动 Nginx

---

## 文件说明

```bash
xui-ssl-auto-check.sh   # 主检测与修复脚本
install.sh              # 一键安装脚本模板
README.md               # 使用说明
```

---

## 一键部署方式

上传到 GitHub 后，假设你的仓库地址是：

```bash
https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME
```

那么你的脚本 Raw 地址一般是：

```bash
https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/xui-ssl-auto-check.sh
```

在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/xui-ssl-auto-check.sh -o /root/xui-ssl-auto-check.sh && chmod +x /root/xui-ssl-auto-check.sh
```

然后运行：

```bash
/root/xui-ssl-auto-check.sh
```

脚本会提示你输入域名：

```bash
请输入要检测的域名，例如 tim.google.com，仅作格式示例:
```

---

## 一键安装脚本方式

如果你把 `install.sh` 也上传到了 GitHub，可以这样安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/install.sh)
```

如果还没有改 `install.sh` 里的默认仓库地址，也可以用环境变量指定 Raw 地址：

```bash
RAW_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/xui-ssl-auto-check.sh" bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/install.sh)
```

安装完成后运行：

```bash
/root/xui-ssl-auto-check.sh
```

或者直接带域名运行：

```bash
/root/xui-ssl-auto-check.sh tim.google.com
```

---

## 直接运行方式

你也可以不安装，直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/xui-ssl-auto-check.sh)
```

或者带域名运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/xui-ssl-auto-check.sh) tim.google.com
```

---

## 运行要求

建议系统：

- Debian 10+
- Ubuntu 20.04+
- 已安装 x-ui 或 3x-ui
- 已安装 acme.sh
- 已经通过 acme.sh 签发过目标域名证书

脚本需要 root 权限：

```bash
sudo -i
```

---

## 输出说明

脚本会使用以下状态标记：

```bash
[PASS] 正常
[WARN] 风险提醒
[FAIL] 明确异常
[FIX]  已自动修复
```

最后会输出汇总，例如：

```bash
------------------------------------------------------------
检测与修复结果汇总
------------------------------------------------------------
域名              : tim.google.com
服务              : x-ui
面板端口          : 7777
面板路径          : /199F/
acme.sh 类型      : ECC
acme.sh 模式      : standalone
acme.sh 证书目录  : /root/.acme.sh/tim.google.com_ecc
证书签发日期      : May 23 20:29:35 2026 GMT
证书到期日期      : Aug 21 20:29:34 2026 GMT
证书剩余天数      : 88 天
x-ui 证书路径     : /root/cert.crt
x-ui 私钥路径     : /root/private.key
------------------------------------------------------------
PASS: 24
WARN: 2
FAIL: 0
FIX : 1
------------------------------------------------------------
整体状态：Warning
------------------------------------------------------------
```

如果出现 `WARN / FIX / FAIL`，脚本会在底部显示具体原因和建议。

---

## 自动修复逻辑

### 1. 证书安装路径

脚本会确保 acme.sh 续签后自动更新：

```bash
/root/cert.crt
/root/private.key
```

同时配置续签后自动重启面板服务。

最终应该看到：

```bash
[PASS] 续签后会更新 /root/cert.crt
[PASS] 续签后会更新 /root/private.key
[PASS] 续签后会重启 x-ui
```

或：

```bash
[PASS] 续签后会重启 3x-ui
```

---

### 2. x-ui 数据库证书路径

如果 x-ui 数据库中的证书路径不是：

```bash
/root/cert.crt
/root/private.key
```

脚本会先备份数据库，然后自动修正。

备份文件示例：

```bash
/etc/x-ui/x-ui.db.bak.20260525-123000
```

---

### 3. Nginx 占用 80 端口

脚本会判断 acme.sh 当前验证模式。

如果是 DNS API 或 Webroot 模式，通常无需处理。

如果是 standalone 模式，并且 80 端口被 Nginx 占用，脚本会：

1. 优先尝试检测 Nginx Webroot；
2. 测试 `/.well-known/acme-challenge/` 是否公网可访问；
3. 如果可用，尝试切换为 Webroot 模式；
4. 如果不可用，则配置 acme.sh hook：

```bash
Le_PreHook='systemctl stop nginx || true'
Le_PostHook='systemctl start nginx || true'
```

这样可以避免 standalone 续签时因为 80 端口被 Nginx 占用而失败。

---

## 常用命令

查看脚本：

```bash
cat /root/xui-ssl-auto-check.sh
```

运行脚本：

```bash
/root/xui-ssl-auto-check.sh
```

带域名运行：

```bash
/root/xui-ssl-auto-check.sh tim.google.com
```

查看帮助：

```bash
/root/xui-ssl-auto-check.sh --help
```

---

## 注意事项

- 脚本会修改 acme.sh 的 install-cert 配置。
- 脚本可能会修改 x-ui 数据库中的证书路径，但会先自动备份数据库。
- 如果需要从 standalone 切换到 Webroot，脚本可能会触发一次重新签发证书。
- 如果 Webroot 不满足条件，脚本会配置 Nginx stop/start hook 作为兜底。
- 建议第一次运行后，再运行第二次确认状态是否稳定。
