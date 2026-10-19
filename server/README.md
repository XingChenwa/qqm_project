# Linux 网页版（Ubuntu 22.04 x86_64）

无需图形桌面，通过浏览器访问 **23336** 端口。机器人与插件运行在 Linux 服务器，关闭网页不会停止连接。聊天、多机器人隔离、消息回复序号与七个插件均复用客户端内核；网页提供文字、Markdown 编辑与实时预览、HTTPS 图片链接发送、插件配置与源码文件编辑、日志复制/导出和主题设置。

网页版通过 AppID / 机器人密钥接入，密钥只在保存时发往你自己的服务，不在读取配置接口中回传；首次使用需要填写凭据。QQ 官方接口的权限、额度和白名单限制仍适用。公网出口查询显示的是 **服务器 IPv4**，不是浏览者的 IP。内嵌浏览页使用访问设备自己的浏览器标识，第三方站点可能禁止 iframe，此时可复制链接。

## 启动

在 GitHub 对应版本的 Release 下载 `qqbotmanager-linux-v版本-build构建号-web-x64.tar.gz` 及 `.sha256`，在同一目录验证、解压：

```bash
sha256sum -c qqbotmanager-linux-v1.3.8-beta.5-build24-web-x64.tar.gz.sha256
tar -xzf qqbotmanager-linux-v1.3.8-beta.5-build24-web-x64.tar.gz
cd qqbotmanager
./start.sh
```

默认仅监听 `127.0.0.1:23336`。服务器本机打开 `http://127.0.0.1:23336`；远程使用 SSH 隧道更安全：

```bash
ssh -L 23336:127.0.0.1:23336 你的服务器用户@服务器IP
```

然后在电脑浏览器访问 `http://127.0.0.1:23336`。首次启动生成 `data/admin-password.txt`，在服务器终端查看此文件中的管理密码；不要把密码、机器人密钥或 Token 发到反馈中。

受信局域网临时访问可使用 `./start.sh --host 0.0.0.0`，再访问 `http://服务器局域网IP:23336`。HTTP 不加密，不适合公网；公网请使用下面的 HTTPS 反向代理，不要直接开放此端口。

## 开机启动

将解压后的文件放到 `/opt/qqbotmanager`。以 root 在服务器执行：

```bash
useradd --system --home-dir /var/lib/qqbotmanager --shell /usr/sbin/nologin qqbotmanager
cp /opt/qqbotmanager/qqbotmanager.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now qqbotmanager
systemctl status qqbotmanager
cat /var/lib/qqbotmanager/admin-password.txt
```

已有同名系统用户时跳过 `useradd`。服务以专用低权限用户运行，数据保存在 `/var/lib/qqbotmanager`；不要将此目录作为静态网站根目录。服务日志：`journalctl -u qqbotmanager -n 100 --no-pager`。

## 宝塔 / Nginx HTTPS 反向代理

1. 创建自己的站点并申请 HTTPS 证书，反向代理到 `http://127.0.0.1:23336`。
2. 保留原始 Host：`proxy_set_header Host $http_host;`；不要把任意访客提供的请求头当作认证。
3. 在 systemd 的 `ExecStart` 尾部追加 `--public-url https://你的域名`，执行 `systemctl daemon-reload`、`systemctl restart qqbotmanager`。此模式校验域名与请求来源，并为登录 Cookie 设置 Secure。
4. 用 HTTPS 域名打开网页。云防火墙与系统防火墙只放行 HTTPS/SSH 所需端口，不必公开 23336。

```nginx
location / {
    proxy_pass http://127.0.0.1:23336;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 1m;
    proxy_read_timeout 90s;
}
```

应用自带管理密码、HttpOnly/SameSite Cookie、跨站请求检查、登录失败限速和插件工作区路径校验。外部用户不能直接读取数据、插件密钥或操作服务。插件本身可请求其授权的网络地址，只安装你信任的插件。

## 更新与备份

Linux 服务包属于同版附加下载，当前不在四端客户端的自动替换流程内；下载新版本后停止服务、备份私有数据目录、替换程序和随附资源，再启动服务。**保留原来的 data / /var/lib/qqbotmanager**，不要用空目录覆盖。已修改的插件定义与聊天存储在私有数据目录，不会随程序包丢失。

默认显示当前会话最近 500 条消息，完整记录仍在服务器本地。客户端与 Linux 服务各自保管聊天，不自动跨设备同步。当前包为 Ubuntu 22.04 x86_64 构建，不是 ARM 包。
