# Linux 网页版（Ubuntu 22.04 x86_64）

无需图形桌面，通过浏览器访问 **23336** 端口。机器人与插件运行在 Linux 服务器，关闭网页不会停止连接。聊天、多机器人隔离、消息回复序号与七个插件均复用客户端内核；网页提供文字、Markdown 编辑与实时预览、HTTPS 图片链接发送、插件配置与源码文件编辑、日志复制/导出和主题设置。

设置左侧的铃铛打开独立的群通知中心，支持筛选加入／退出、未读、待审核与已处理申请，支持分页同步和手动审批。会话内的齿轮打开群聊／用户设置，可查看群人数、机器人身份与消息权限、分页成员、成员资料、群禁言状态并管理普通成员禁言。长按／右击会话也能屏蔽消息提醒，消息与插件仍正常收发。群管理接口受 QQ 平台权限约束，审核与禁言要求机器人为群管理员；成员查询部分能力仍为内邀／白名单。网页不申请系统通知权限，系统通知仅 Android／iOS 客户端提供。

长按／右击聊天消息中普通成员的头像，可设置禁言、解除禁言或将该成员移出群聊。移出需再次确认，不加入群黑名单；提交前重新核实官方角色，不能管理群主、管理员或机器人。移除接口同样需要 QQ 平台内邀／白名单权限。

网页版通过 AppID / 机器人密钥接入，密钥只在保存时发往你自己的服务，不在读取配置接口中回传；首次使用需要填写凭据。QQ 官方接口的权限、额度和白名单限制仍适用。公网出口查询显示的是 **服务器 IPv4**，不是浏览者的 IP。内嵌浏览页使用访问设备自己的浏览器标识，第三方站点可能禁止 iframe，此时可复制链接。

## 1. 安装前确认

- 系统：**Ubuntu 22.04，x86_64 / amd64**。运行 `uname -m` 应显示 `x86_64`；当前安装包不适用于 ARM / aarch64。
- 不需要安装图形桌面、Flutter、Dart、PHP 或数据库，安装包已经包含可执行程序。
- 服务器需要能访问 QQ 开放平台；机器人接口的源 IP 白名单填写服务器的公网 IPv4。
- 默认仅本机访问，不会自动对公网开放 23336 端口。

安装下载和解压工具：

```bash
sudo apt update
sudo apt install -y ca-certificates curl tar libstdc++6 libgcc-s1
```

## 2. 下载并启动（普通用户）

从 [GitHub Releases](https://github.com/XingChenwa/qqm_project/releases) 选择要安装的版本，下载 Linux 的 `.tar.gz` 和同名 `.sha256`。不要下载源码 ZIP，也不要下载 Windows / Android 安装包。

下面以 `1.3.8-beta.7.1+27` 为例。**已有安装请看后面的“更新与备份”，不要重新初始化数据目录。** 等该版本的安装包上传后执行：

```bash
mkdir -p "$HOME/qqm-downloads"
cd "$HOME/qqm-downloads"
curl -fL --retry 3 -O https://github.com/XingChenwa/qqm_project/releases/download/v1.3.8-beta.7.1/qqbotmanager-linux-v1.3.8-beta.7.1-build27-web-x64.tar.gz
curl -fL --retry 3 -O https://github.com/XingChenwa/qqm_project/releases/download/v1.3.8-beta.7.1/qqbotmanager-linux-v1.3.8-beta.7.1-build27-web-x64.tar.gz.sha256
sha256sum -c qqbotmanager-linux-v1.3.8-beta.7.1-build27-web-x64.tar.gz.sha256
# 只有出现 OK / 成功，才继续解压。
tar -xzf qqbotmanager-linux-v1.3.8-beta.7.1-build27-web-x64.tar.gz
cd qqbotmanager
./start.sh
```

这个终端需要保持运行；停止时按 `Ctrl+C`。如需关闭 SSH 后仍运行，请使用后面的 systemd 服务。

## 3. 电脑或手机打开网页

服务器本机浏览器打开 `http://127.0.0.1:23336`。默认监听本机，所以直接访问 `http://服务器公网IP:23336` 不会通，这是正常的安全设置。

远程电脑推荐使用 SSH 隧道，在**你的电脑终端**执行（不是服务器终端）：

```bash
ssh -L 23336:127.0.0.1:23336 你的服务器用户@服务器IP
```

保持隧道终端打开，然后在电脑浏览器访问 `http://127.0.0.1:23336`。手机或多人访问推荐使用后面的 HTTPS 反向代理，让手机浏览器打开你的 HTTPS 域名；网页会自动使用手机版布局。

## 4. 首次设置管理密码

**首次使用必须先设置自己的管理密码，不能跳过。** 普通用户启动时，在服务器另开一个终端查看初始化码：

```bash
cd "$HOME/qqm-downloads/qqbotmanager"
cat data/setup-token.txt
```

1. 在服务器本地执行 `cat data/setup-token.txt`，复制一次性初始化码。该文件位于 `--data` 指定的私有数据目录，网页不会提供下载。
2. 在首次设置页粘贴初始化码，输入并确认至少 12 个字符的管理密码，然后进入工作台。初始化码用于防止未授权访客抢先设置密码，不是日后的登录密码。
3. 之后使用你设置的管理密码登录。服务只保存加盐密码哈希；初始化码完成设置后失效并移除。不要把初始化码、密码、机器人密钥或 Token 发到反馈中。

未完成密码设置时，所有管理接口、机器人自动连接和插件定时任务都不可用。升级旧版 Linux 服务时，已有机器人与聊天数据保留；旧版 `admin-password.txt` 的随机密码会作为初始化码迁移到 `setup-token.txt`，仍需先设置自己的管理密码。已经设置过的密码在后续升级与重启时保留。

受信局域网临时访问可使用 `./start.sh --host 0.0.0.0`，再访问 `http://服务器局域网IP:23336`。HTTP 不加密，不适合公网；公网请使用下面的 HTTPS 反向代理，不要直接开放此端口。

## 5. 后台运行和开机启动（systemd）

下面按**新安装**举例。先用 `Ctrl+C` 停止普通用户模式，进入刚才解压的 `qqbotmanager` 目录，把程序文件放到 `/opt/qqbotmanager`，不复制或覆盖用户数据：

```bash
sudo mkdir -p /opt/qqbotmanager
sudo cp -a qqm-server start.sh qqbotmanager.service server assets plugins LICENSE README.md /opt/qqbotmanager/
id qqbotmanager >/dev/null 2>&1 || sudo useradd --system --user-group --home-dir /var/lib/qqbotmanager --shell /usr/sbin/nologin qqbotmanager
sudo install -m 644 /opt/qqbotmanager/qqbotmanager.service /etc/systemd/system/qqbotmanager.service
sudo systemctl daemon-reload
sudo systemctl enable --now qqbotmanager
sudo systemctl status qqbotmanager --no-pager
sudo cat /var/lib/qqbotmanager/setup-token.txt
```

服务以专用低权限用户运行，数据保存在 `/var/lib/qqbotmanager`。这与普通用户模式的 `data` 是两个目录，**不要以为切换运行方式会自动迁移原有机器人和聊天记录**。已有数据时，先停止服务、备份原数据，再完整迁移到服务数据目录并交给 `qqbotmanager` 用户读写；不要混合两个数据目录中的文件。

新服务启动后，使用上述初始化码在网页设置密码；已初始化的服务不再生成此文件。不要将数据目录作为静态网站根目录。

常用管理命令：

```bash
sudo systemctl restart qqbotmanager                  # 重启
sudo systemctl stop qqbotmanager                     # 停止
sudo journalctl -u qqbotmanager -n 100 --no-pager      # 查看日志
```

## 6. 宝塔 / Nginx HTTPS 反向代理

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

## 7. 更新与备份

Linux 服务包属于同版附加下载，当前不在四端客户端的自动替换流程内；下载新版本后停止服务、备份私有数据目录、替换程序和随附资源，再启动服务。**保留原来的 data / /var/lib/qqbotmanager**，不要用空目录覆盖。已修改的插件定义与聊天存储在私有数据目录，不会随程序包丢失。

默认显示当前会话最近 500 条消息，完整记录仍在服务器本地。客户端与 Linux 服务各自保管聊天，不自动跨设备同步。当前包为 Ubuntu 22.04 x86_64 构建，不是 ARM 包。

## 常见问题

- **下载 404**：确认该 Release 的 Linux 附件已经上传，并且 URL 的版本号、构建号与附件名完全一致。
- **`Permission denied`**：进入程序目录执行 `chmod +x qqm-server start.sh` 后重试，不要使用 `chmod -R 777`。
- **`Exec format error`**：通常是 CPU 架构不匹配；本包只支持 x86_64。
- **网页打不开**：确认进程在运行，服务器执行 `curl -f http://127.0.0.1:23336/health`；远程访问使用 SSH 隧道或已配置好的 HTTPS 域名。
- **23336 已占用**：检查是否已经启动过一个服务。普通用户可用 `./start.sh --port 23337` 临时更换端口，同时相应修改隧道／反向代理配置。
- **初始化码文件找不到**：先确认正在使用哪个数据目录；普通用户默认 `程序目录/data`，systemd 默认 `/var/lib/qqbotmanager`。已完成密码设置时该文件会被移除，不代表安装失败。
- **QQ 接口提示源 IP 不在白名单**：将服务器实际公网 IPv4 加到对应 AppID 的 QQ 机器人开发设置，而不是填写电脑或手机的 IP。
