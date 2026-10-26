# x-ui / 3x-ui SSL 一键证书

为 x-ui / 3x-ui 面板自动签发、安装、检测并续签 SSL 证书。证书过期或续签失败时会自动修复，全程不停止 Nginx。

请使用 root 运行（`sudo -i`），把 `sg1.example.com` 换成你的域名。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh)
```

运行后按提示输入域名即可，也可以直接带上域名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh) sg1.example.com
```

## 一键升级

重新运行安装命令即可。它会更新到最新版，并重新检测、修复证书：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/install.sh) sg1.example.com
```

## 一键卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/xui-ssl-auto-check/main/uninstall.sh)
```

卸载只删除本工具，不会删除 acme.sh、已安装的证书和自动续签任务。

## 说明

- 证书安装位置：`/root/cert.crt`、`/root/private.key`，面板会自动指向这两个文件。
- 续签由 acme.sh 每天自动执行，续签后自动重启 x-ui。
- 结果显示 `Healthy` 即一切正常；显示 `Failed` 时，按输出末尾的建议处理。
