# Linux 网页版安装与使用

无需图形桌面，在浏览器管理机器人、聊天、Markdown、七个插件、群通知、群成员和日志。机器人与插件运行在服务器，关闭网页不影响服务；电脑显示桌面布局，手机自动显示手机布局。

> 本文适用于 **1.3.9 及以上**的自动安装器与网页安全入口。1.3.8 系列旧包不包含这些功能，安装器会拒绝不支持的新安装方式，不会把旧版当新版安装。

## 系统要求

- Linux **x86_64 / amd64**，glibc **2.31 或以上**。不只支持 Ubuntu：Ubuntu 20.04／22.04／24.04、Debian 11／12、Rocky Linux 9／AlmaLinux 9，以及符合要求的 Fedora、Arch 等系统均可按环境检测安装。发布流程会在 Ubuntu 22.04、Debian 12、Rocky Linux 9 容器检查启动，实际兼容以对应 Release 的验证结果为准。
- 自动后台安装需要 **systemd**。其他 init 系统可手动运行 `start.sh`，自行配置守护进程。
- 当前原生包不适用于 ARM／aarch64、Alpine／musl。不建议安装到停止维护的旧系统；安装器不会替换系统 glibc。
- 服务本身不需要 Flutter、Dart、PHP、数据库或桌面浏览器，下载工具可由安装器按需安装。
- 服务器需能访问 QQ 开放平台，源 IP 白名单填写**服务器公网 IPv4**，不是浏览者的电脑／手机 IP。

## 推荐：自动下载安装

从可信的[项目仓库](https://github.com/XingChenwa/qqm_project)下载安装脚本，查看脚本后执行，不使用来路不明的命令：

```bash
curl -fL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/XingChenwa/qqm_project/main/server/install.sh \
  -o qqm-install.sh
sudo bash qqm-install.sh --channel stable --install-deps
```

默认选择正式版 `--channel stable`；需要测试版时手动选择 `--channel beta`，不会偷偷跨渠道升级。也可加 `--version v1.3.9` 安装指定 Release。请等对应版本的 Linux 附件上传齐备后安装。

没有 `curl` 时，Debian／Ubuntu 先执行 `sudo apt install curl ca-certificates`，Rocky／AlmaLinux／Fedora 执行 `sudo dnf install curl ca-certificates`。`--install-deps` 支持 apt、dnf、yum、zypper、pacman，不会自动修改防火墙或 SSH。

安装器会：

1. 检查架构、运行库和 systemd，从所选 GitHub Release 下载 Linux 包与校验文件。
2. **自动校验 SHA-256**，检查压缩包路径、链接和文件类型，通过后才安装。SHA-256 是文件的“指纹”，用于发现损坏或篡改，不需要用户手动计算；安装包和校验值仍应来自可信 HTTPS 来源。
3. 配置专用低权限账号和后台服务，程序位于 `/opt/qqbotmanager`，私有数据位于 `/var/lib/qqbotmanager`，端口默认 **23336**。
4. 保留密码、入口、机器人和聊天；升级前备份，启动检查失败恢复旧程序，不重置数据。备份位于 `/var/backups/qqbotmanager/时间编号`，包含敏感数据，请勿公开。
5. 在**当前终端**显示私有设置／访问链接。安装时不要求输入管理员密码，密码在第一次打开网页时设置。

只检查环境而不安装：`bash qqm-install.sh --check-only`。

## 第一次打开：设置密码和安全入口

安装器默认监听 `0.0.0.0:23336`，允许局域网或已放行的公网访问。浏览器打开：

```text
http://服务器局域网IP:23336
```

第一次显示设置页。**未设置完成，不能使用管理功能、自动连接机器人或运行插件定时任务。**

推荐直接打开安装终端显示的私有链接：

```text
http://服务器IP:23336/#setup=一次性初始化码
```

初始化码自动填入，网页立即从当前地址中清除它；`#` 后面的片段不发送到服务器 URL 或访问日志。该码用于验证服务器所有权，防止公网陌生人抢先设置管理员，**不是管理员密码**。不要分享或公开截图。HTTP 提交的密码和初始化码仍可能被窃听，公网请使用 HTTPS。

只打开根地址时，也可以在页面手动粘贴初始化码，在自己的服务器终端查看：

```bash
sudo cat /var/lib/qqbotmanager/setup-token.txt
```

在网页完成：

1. 设置至少 12 个字符的管理员密码，再次确认，不要填写 QQ 密码。
2. 设置 **8–64 位字母、数字、短横线或下划线**的安全入口，也可“随机生成”。例如 `mybot_7rK92p`；不要用容易猜的 `xxxx`。
3. 保存后进入 `http://服务器IP:23336/mybot_7rK92p/`，**收藏完整地址**。

设置后只保存加盐密码哈希，初始化码失效并删除。登录页、资源和管理 API 全部在入口内；根地址、错误入口返回 **404**，不会跳转或透露正确入口。进入正确入口仍须验证密码，安全入口不代替密码或 HTTPS。退出、重启和升级都会保留设置。

忘记入口或需要再次显示链接，在服务器执行：

```bash
sudo bash /opt/qqbotmanager/install.sh --print-link
# 只显示实际公网访问链接，不修改监听配置：
sudo bash /opt/qqbotmanager/install.sh --print-link --access-url http://你的公网IP:23336
```

不要删除 `admin-auth.json` 或清空数据目录。旧版已设置密码的安装升级后，用**原密码**登录根地址，补设入口后继续使用，不开放匿名初始化、不清空聊天。旧版 `admin-password.txt` 随机密码仅作为一次性初始化码，仍需在网页设置自己的密码与入口。

## 局域网和公网访问

局域网地址（如 `192.168.x.x`）只能在对应网络内访问，不是公网地址。公网应使用**公网 IP／域名**：

```text
http://服务器公网IP:23336/你的安全入口/
https://你的域名/你的安全入口/
```

- 云服务器：在云安全组和系统防火墙放行 TCP 23336，尽量限制允许访问的来源 IP。
- 家用／公司内网：需要路由器端口映射及可入站的公网地址或受信隧道；运营商 CGNAT 下仅放行端口通常仍不能访问。
- HTTP 直连可以访问，但**不加密密码、Cookie 和聊天**。公网长期使用推荐 HTTPS 反向代理或 VPN，不要只靠入口路径防护。
- 仅本机／SSH 隧道访问：安装加 `--host 127.0.0.1`；电脑使用 `ssh -L 23336:127.0.0.1:23336 用户@服务器IP`，再访问本机 23336。
- 电脑、手机浏览器自动采用相应布局，不需要额外 App。

安装器不代你开放端口。UFW 系统可按需执行 `sudo ufw allow 23336/tcp`；firewalld 系统可执行 `sudo firewall-cmd --permanent --add-port=23336/tcp` 后 `sudo firewall-cmd --reload`。不要同时照搬两套规则，也不要关闭整个防火墙。

### HTTPS 反向代理（推荐）

1. 域名指向服务器，配置有效 HTTPS 证书。
2. 编辑 `/etc/qqbotmanager.env`：`QQM_HOST=127.0.0.1`、`QQM_PORT=23336`、`QQM_PUBLIC_URL=https://你的域名`，这里不填写安全入口。
3. 反向代理整个站点到 `http://127.0.0.1:23336`，**保留原始 Host 和完整入口路径**，不要删除入口前缀。
4. 执行 `sudo systemctl restart qqbotmanager`，使用 HTTPS 域名和私有初始化链接／安全入口。此模式校验域名与 Origin，登录 Cookie 带 Secure。

```nginx
location / {
    proxy_pass http://127.0.0.1:23336;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 1m;
    proxy_read_timeout 90s;
}
```

仅公开 HTTPS 所需端口，无需暴露 23336。不要把私有数据目录设成网站根目录，也不要缓存管理页或 API。

## 管理、更新和离线安装

```bash
sudo systemctl status qqbotmanager --no-pager
sudo systemctl restart qqbotmanager
sudo systemctl stop qqbotmanager
sudo journalctl -u qqbotmanager -n 100 --no-pager
# 再次运行安装器更新；密码、入口与聊天保留：
sudo bash qqm-install.sh --channel stable
```

离线时，从 [Releases](https://github.com/XingChenwa/qqm_project/releases) 下载 Linux `.tar.gz` 和同名 `.sha256`，上传后自动校验安装：

```bash
sudo bash qqm-install.sh --archive /你的下载目录/完整Linux安装包文件名.tar.gz
```

已解压且来自可信来源的新服务包，可在包目录执行 `sudo bash install.sh --local`。不是由安装器管理的 `/opt/qqbotmanager` 会被拒绝覆盖，请先备份并迁移；旧程序目录的 `data` 与系统服务的 `/var/lib/qqbotmanager` 不会自动混合。

不使用 systemd 时，在已校验、解压的包目录手动运行：

```bash
./start.sh --host 0.0.0.0 --port 23336
# 另一个服务器终端显示私有链接，默认数据目录为包内的 data：
./qqm-server --data ./data --access-link http://服务器IP:23336
```

关闭终端会停止前台进程，需要自己配置守护程序。Linux 服务暂不使用四端客户端的自动替换更新流程。

## 常见问题

会话列表的搜索框可以搜索当前机器人的本地聊天记录，点击结果定位消息。聊天页右上角的“聊天记录”可独立查看、搜索和筛选消息。语音可直接播放，下载优先使用 QQ 官方提供的 WAV；未提供 WAV 时保留原文件，不转换格式，也无需安装 FFmpeg。

- **网页 404**：初始化后根地址返回 404 正常，使用包含安全入口的完整地址。忘记入口使用服务器上的 `--print-link`，不要重新初始化。
- **网页打不开**：先检查服务，再执行 `curl -f http://127.0.0.1:23336/health`；HTTPS 模式加 `-H 'Host:你的域名'`。本机通、外网不通时检查监听、安全组、防火墙和端口映射。
- **公网地址显示错了**：安装器检测到的本机 IP 不一定是路由器出口；用 `--print-link --access-url http://公网IP:23336` 显示实际地址。
- **找不到初始化码**：设置成功后会删除；未初始化时先确认数据目录。
- **SHA-256 不匹配**：重新从可信 Release 下载，不要跳过校验，也不要使用源码 ZIP 或其他平台的包。
- **23336 已占用**：安装器加 `--port 23337` 或修改环境文件并重启，同时调整反代／防火墙。手动启动的 `--port` 也能覆盖默认值。
- **QQ 源 IP 不在白名单**：将查询到的服务器出口 IPv4 加入对应 AppID 的开发设置。
- **权限或架构错误**：不要用 `chmod -R 777` 或手动升级 glibc，先检查 x86_64、运行库和私有目录权限。
- **反馈日志**：先去掉初始化链接、安全入口、密码、机器人密钥和 Token。
