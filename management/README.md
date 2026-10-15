# QQ机器人管理器 宝塔部署

这个 PHP 和 MySQL 后台为 `https://botmanager.uuze.cn` 提供软件下载首页、版本发布、签名更新接口和可关闭的设备使用统计。业务记录全部存入宝塔 MySQL，不会回退到 SQLite。`config.php` 保存数据库和账号中心连接参数；首次安装自动生成的 `data/config.json` 保存签名私钥和回源鉴权值，不是用 JSON 代替 MySQL。

后台仅使用杂鱼账号中心登录，只允许其服务端返回的绑定邮箱为 `2377130783@qq.com` 的账号进入。没有本地账号密码登录入口，也没有公开网页安装器。新安装只需填写 PHP 配置并运行一次 `install`，不需要手工创建 JSON、私钥或数据表。

## 一次性准备

1. 宝塔安装 Nginx、PHP 8.2 或以上和 MySQL。PHP 确保启用 `pdo_mysql`、`sodium`、`zip`、`curl`、`session`，只开 `mysqli` 不够。PHP 需要可用的系统 CA 证书，服务器允许访问 `https://zhapi.uuze.cn`。
2. 在宝塔“数据库 → MySQL → 添加数据库”创建独立数据库和专用账号，例如库名与账号均为 `botmanager`，字符集选择 `utf8mb4`，访问权限选本地服务器。密码只保存在自己的宝塔和服务器配置中，不用发到聊天；不要使用 MySQL root，也不需要对公网开放 3306。
3. 将新版宝塔部署 ZIP 的内容直接解压到 `/www/wwwroot/botmanager.uuze.cn`，确认该目录下直接有 `bin`、`src`、`public`、`database` 和 `config.example.php`。网站运行目录设为 `/public`，即 `/www/wwwroot/botmanager.uuze.cn/public`。无需 Composer 或 Node。若上传的是源码目录，取 `management` 内的内容；不要无意中再套一层同名目录。
4. 在网站的 Nginx 配置中合并 [配置示例](deploy/nginx.conf)，保留宝塔原有证书配置，核对 PHP socket。关闭 PHP `display_errors`；不要为了运行本站解除宝塔的 `system`、`exec` 禁用。
5. 让 PHP-FPM 用户 `www` 拥有 `data` 的读写权限。`config.php` 所有者设为 `www`，权限 `600`，其他代码只需可读，不要把整个站点设为 777。初始化与每日清理使用相同的 PHP 和用户。下面 `82` 对应 PHP 8.2；网站用 8.3 时改为 `83`，不要混用不同版本及扩展。

## 填写宝塔数据库并安装

新安装时，在宝塔文件管理把 `config.example.php` **复制为同级的 `config.php`**，不要只修改示例文件，也不要覆盖已有 `config.php`。打开 `config.php`，在已有的 `database` 数组内填写数据库信息：

```php
'database' => [
    'host' => '127.0.0.1',
    'port' => 3306,
    'name' => 'botmanager',        // 换成宝塔实际库名
    'username' => 'botmanager',    // 换成该库的专用账号
    'password' => '只在服务器填写实际密码',
    'socket' => '',
    'ssl_ca' => '',
],
```

这是 PHP 字段片段，不要替换整个文件或删除开头的 `<?php` 与 `return [...]`。单引号字符串里的 `'` 写成 `\'`、反斜线写成 `\\`。库名、账号以宝塔实际创建结果为准；`127.0.0.1` 明确使用 TCP。若使用本机 Unix socket，将 `socket` 填成实际路径，例如 `/tmp/mysql.sock`。远程数据库需限制允许连接的来源并配置 `ssl_ca`，不要通过公开网络裸连。

保存后在服务器终端执行：

```bash
cd /www/wwwroot/botmanager.uuze.cn
sudo -u www /www/server/php/82/bin/php bin/manage.php install
sudo -u www /www/server/php/82/bin/php bin/manage.php db-check
```

`install` 自动生成 `data/config.json` 中的签名私钥和随机回源鉴权值，连接已创建的数据库并建立五张 `qqm_` 前缀表。不创建或删除数据库，重复执行保留现有记录和有效密钥。`db-check` 成功时显示连接与数据表版本正常。之后网页请求只验证结构版本，不在每次访问时重新建表。

如果直接执行 `install` 时还没有任何配置，它会先创建 `config.php` 和私密 JSON，并提示填写 MySQL 后重新运行，不会把空配置视作安装成功。配置缺失、JSON/PHP 格式错误、扩展缺失、账号密码错误和数据库不存在分别给出中文提示；不要公开完整配置或私钥。示例文件只供复制参考，运行时不再依赖它。

若习惯使用 phpMyAdmin，也可先选中专用数据库，再导入 [建表 SQL](database/schema.sql)，然后运行 `install` 补齐密钥及验证。SQL 使用 InnoDB 和 utf8mb4，五张表分别为结构版本、发布记录、安装信息、每日活跃明细、限流。数据库访问通过 [PHP PDO_MYSQL](https://www.php.net/manual/en/ref.pdo-mysql.php) 的原生预处理语句，不把密码放进网页。

## 更新旧部署

`1.3.1+12` 的数据库结构升级为版本 2，增加设备名称、型号、系统版本和架构四个可空字段。先备份，上传新版代码后执行下面命令，`db-check` 应显示“数据表版本 2”：

```bash
cd /www/wwwroot/botmanager.uuze.cn
sudo -u www /www/server/php/82/bin/php bin/manage.php install
sudo -u www /www/server/php/82/bin/php bin/manage.php db-check
```

升级只补充缺少的字段并记录结构版本，不重建表、不删除记录，也不轮换任何密钥；可重复运行。升级期间动态接口可能短暂提示结构版本不匹配，安排在可接受的时间进行。只上传网页而不执行升级，不能显示新设备字段。

先备份 MySQL 和整个 `data`，覆盖上传代码，但**保留原有 `config.php` 和 `data/config.json`**；部署 ZIP 不包含这两个真实配置文件。旧版只用 JSON 填写数据库和 OAuth 的方式仍兼容，不必重建配置或更换密钥，上传后运行 `install` 和 `db-check` 即可。旧版 `init`、`db-init` 命令也继续保留。

配置读取顺序是内置默认值、旧版 `data/config.json`、`config.php`；数据库子字段按名称合并。两份配置同时存在时，手填 PHP 参数优先，但 JSON 内已有的非空签名私钥和回源鉴权值始终保留。新部署只在 PHP 文件改数据库和 OAuth，不用把它们再写一遍 JSON。`data` 保存私钥与安装包，必须位于公开目录外；不能上传 Git、分享或通过网站下载。

如果已经试用过旧 SQLite 版本，原文件不会被删除，也不会自动迁移进 MySQL。先备份旧数据，再另行迁移；本版不会把空的 MySQL 数据库当成旧数据已经迁移成功。

## 配置杂鱼账号登录

在 [杂鱼账号中心的 OAuth 应用](https://account.uuze.cn/developer) 创建网站应用并通过审核：

- 应用名称和网站名称：`QQ机器人管理器`。
- 站点：`https://botmanager.uuze.cn`。
- 完整回调地址：`https://botmanager.uuze.cn/api/admin/oauth/callback`，逐字一致，不要加末尾斜线。
- 权限：`public_profile user_email`。其中 `user_email` 必须审核获准，否则接口不会返回邮箱，后台会拒绝登录。无需申请 `user_id`。

在宝塔文件管理中编辑服务器的 `config.php`，填写以下字段，保留文件内的数据库配置：

```php
'app_url' => 'https://botmanager.uuze.cn',
'environment' => 'production',
'admin_email' => '2377130783@qq.com',
'uuze_client_id' => '在此填写你的 Client ID',
'uuze_client_secret' => '仅在服务器填写你的 Client Secret',
```

上面只是字段片段，不要用它覆盖完整配置。`Client Secret` 只显示一次，请自行保存；不需要发到聊天。修改后访问 `/admin`，点击“使用杂鱼账号登录”，在账号中心官网完成授权。未填凭据时入口会提示尚未配置，不会降级到无验证登录。

授权页使用 `account.uuze.cn/oauth/authorize`，后端使用 `zhapi.uuze.cn/oauth/token` 换取令牌，再通过 `zhapi.uuze.cn/v1/oauth/me` 读取账号中心的邮箱和 `open_id`；浏览器提交邮箱不能获得管理员权限。流程依据 [账号中心接入文档](https://account.uuze.cn/developer/docs)。

回调校验绑定浏览器会话的随机 `state`，有效期 10 分钟且单次使用。会话 Cookie 为 HttpOnly、生产 Secure、SameSite=Lax；所有后台写操作另外校验 CSRF。后台会话最多 1 小时，闲置 30 分钟失效，每 5 分钟按需重新验证上游资料。Access Token 只在服务器会话中暂存，退出会清理，不保存 Refresh Token；过期重新授权。不要将会话目录、授权码、Token、Secret 写入访问日志、错误调试页或浏览器存储。

## DNS 和 EdgeOne

完整操作见 [更新与 EdgeOne 配置](../docs/update-and-edgeone.md)，先完成域名接入、HTTPS 回源和回源头覆盖。免费版在已有 `config.php` 内设置 `'proxy_trust_mode' => 'edgeone_token'` 与 `'require_origin_token' => true`，`trusted_proxy_cidrs` 可为空；无需购买源站防护。默认 `cidr_and_token` 则继续要求真实回源网段和密钥同时匹配。不要提前启用强制鉴权导致自己无法访问，也不要用空模板覆盖数据库和 OAuth 设置。

后台“部署与安全 → 当前访问 IP 检测”显示中文诊断、解析出的 IP、当前模式、请求头是否有效和密钥是否匹配，不返回任何密钥。免费版密钥模式不能代替网络层防火墙，必须保护密钥并使用 HTTPS 回源；不要盲信任意 X-Forwarded-For。该检测只针对当前浏览器，不等于设备已经发来心跳。

## 启用客户端更新

在服务器执行：

```bash
sudo -u www /www/server/php/82/bin/php bin/manage.php public-key
```

输出的 `UPDATE_PUBLIC_KEY=...` 是可以公开的公钥。将其值内置到首次提供更新功能的客户端：

```powershell
flutter build windows --release --dart-define=UPDATE_BASE_URL=https://botmanager.uuze.cn --dart-define=UPDATE_PUBLIC_KEY=你的公开公钥
```

私钥不可放到客户端，也不可用客户端运行时下载的公钥替代内置公钥。未内置公钥的构建不会联系统计或更新服务。原来的 1.2.6 客户端没有这些更新代码，需先手动安装一次新客户端，之后才会检测发布。

Windows 可使用项目构建助手输出根目录正确的 ZIP 和中文安装 EXE。先用便携准备脚本校验并下载 Inno Setup 与中文语言文件，再构建：

```powershell
./tool/prepare_inno.ps1
./tool/build_windows_release.ps1 -UpdatePublicKey '公开公钥' -Installer -Iscc './build/tools/inno-6.7.3/ISCC.exe'
```

该命令显式构建 `lib/main.dart`，不运行机器人；已有同版本输出时拒绝覆盖。安装器默认安装到当前用户的独立程序目录，不强制关闭其他应用，不删除机器人设置。安装器源码在 `scripts/windows-installer.iss`。完整的本地构建与验证步骤见源码的 `docs/windows-release.md`；安装版对外只需分发 EXE，后台不要把同构建号的 ZIP 再重复上传一次。

## 上传和发布

`1.3.2+13` 的首页提供 Windows、macOS、Android、iOS 下载和 macOS 安装步骤，移除了首页后台入口及登录页公开邮箱；后台仍在 `/admin`，管理员权限检查没有改变。隐私说明独立位于 `/privacy`。

后台脚本和样式改用带版本号的文件名，避免 EdgeOne 缓存旧 JS 造成 11 列表头配 7 列数据。升级时同时上传 HTML 和完整 `public/assets`，不能只覆盖页面；发布后清理旧 HTML 缓存。浏览器开发者工具应看到 `/assets/admin-v1.3.2.js`，设备行有11列。没有名称的旧记录显示“未提供”，由新版客户端心跳补充，不能据错位文字推断设备名称。

打开 `/admin` 的“版本发布”，填写版本号、递增构建号、平台和更新说明，上传包保存草稿。核对后点击“发布”，首页和更新接口才可见。客户端启动及每 5 分钟检查一次；这不是即时推送长连接，也不会绕过用户的安装确认。

| 平台 | 架构 | 安装包 |
| --- | --- | --- |
| Windows | x64 | ZIP 根目录直接包含 `qq_bot_manager.exe`、`flutter_windows.dll`、`data/app.so`；或本项目 Inno Setup EXE |
| Android | universal | APK，包名 `cn.uuze.botmanager`；覆盖升级必须与已安装版本同签名 |
| iOS | arm64 | IPA，含 `Payload/Runner.app`；当前按需重签包提供下载和系统导出 |
| macOS | universal | DMG；当前为临时签名测试包，未经过 Developer ID 签名或 Apple 公证 |

一个平台、架构和构建号只能上传一次。修复包内容时使用新的构建号。后台验证基本结构、路径安全并计算 SHA-256，不会替你生成 Android 签名或 Apple 证书。Windows EXE 只应上传自己的 Inno Setup 安装器，不要上传任意来源的 EXE。

超过浏览器或 PHP 上传限制时，可先上传到服务器非公开目录，再本机导入草稿：

```bash
sudo -u www /www/server/php/82/bin/php bin/manage.php import windows x64 1.3.0 11 zip /绝对路径/windows.zip
```

后台不提供远程 URL 抓包功能。撤下版本后，源站立即不再提供该包，但还需手工清理 EdgeOne 中对应 `/packages/哈希/文件名` 缓存。已下载到客户端的包无法远程收回。

## 统计和数据保留

`1.3.1+12` 首次默认开启统计，启动时提示会发送的资料并提供关闭入口；原来明确关闭的用户保持关闭。启动即注册随机安装 ID，后续每分钟发送平台、软件版本、构建号、设备名称／型号、系统版本和架构；服务器记录来源 IP 与心跳。不会上报 QQ AppID、OpenID、机器人密钥、QQ Token、聊天、附件、硬件序列号、MAC 或广告标识。关闭统计不影响更新和机器人功能。

Windows 名称来自电脑主机名，Android 读取公开型号，iOS 名称可能受系统限制为通用名称。设备名称可能包含用户设置的姓名，因此应用内持续提供说明、停止和删除选项。后台仅展示客户端提供的设备资料，不据此认证身份；旧版无资料时显示“未提供”，不会伪造名称。

统计的是安装，不是去重的人数。在线表示最近 5 分钟有心跳；今日活跃按北京时间自然日去重。手机锁屏或后台进程被系统暂停会影响心跳。设备页显示最近 200 条，版本分布与总数基于保留期内的全部安装。

默认 IP 保留 7 天、失活安装 90 天、每日活跃明细 90 天。后台读取统计时会清理；另在宝塔“计划任务 → Shell脚本”每天运行一次：

```bash
sudo -u www /www/server/php/82/bin/php /www/wwwroot/botmanager.uuze.cn/bin/manage.php prune
```

用户关闭统计会停止上报、清除本机安装 ID 并请求删除服务端记录；离线时保留待删除令牌，联网后重试。后台也能删除单条记录。Nginx、EdgeOne 和备份文件的日志保留需单独管理，数据库清理不等于清理 CDN 日志或历史备份。

## 备份和验证

在宝塔设置专用 MySQL 数据库的定期备份，并备份 `config.php`、`data/config.json` 与需要保留的安装包。数据库备份、私钥和数据库密码都只能保存在受访问控制的位置，不能放进 `public` 或部署 ZIP。恢复时需要同时核对数据库记录与对应安装包文件。丢失更新私钥将使已安装客户端无法信任使用另一把密钥签署的更新。

数据库自测需要独立实例，不接受生产数据库。下面的测试入口会使用你指定的 MySQL/MariaDB 程序，在项目 `build` 下创建新数据目录、随机本地端口及专用账号，结束后只关闭它自己创建的实例，不修改已安装的数据库服务：

```bash
QQM_MYSQL_BIN=/你的数据库程序/bin node tests/mysql.mjs
```

测试需要 PHP、上述扩展与 Node 22 或以上；`QQM_PHP` 可指定 PHP 可执行文件。覆盖连接失败、结构初始化、重复建表、utf8mb4、唯一约束、级联删除、限流、签名清单和模拟 OAuth/HTTP 流程。本地已用 MariaDB 11.5 的 MySQL 协议验证，部署到你的宝塔 MySQL 后仍需执行 `db-check`。

浏览器测试可设置 `QQM_BROWSER_TEST=1`，另需 Playwright 与 Chrome。测试连接配置仅在随机测试目录中生成，不要复用真实数据库凭据。`tests/router.php` 仅接受 CLI 开发服务器、本机地址和测试临时目录，不得当作生产入口。正式网站入口始终为 `public/index.php`。
