# 软件更新和 EdgeOne 配置

发布服务使用 `https://botmanager.uuze.cn`，宝塔 PHP 与 MySQL 部署、杂鱼账号管理员登录和上传入口见 [后台部署](../management/README.md)。先在宝塔建库，在 `config.php` 填写数据库连接信息并执行 `install`、`db-check`，再配置网站和客户端公钥；旧版客户端不会因为服务器上线就自动获得更新能力。

## EdgeOne 接入顺序

1. 在 EdgeOne 添加站点并接入 `botmanager.uuze.cn`，按控制台提供的目标添加 DNS CNAME。回源填写真实服务器地址，回源 Host 与 TLS SNI 使用 `botmanager.uuze.cn`，不要把源站地址又解析回同一个 CDN CNAME。
2. 配置边缘 HTTPS 证书与源站有效证书，客户端和回源都使用 HTTPS。源站时钟应准确，避免短时签名或 OAuth state 被误判为过期。
3. 建立站点的“修改回源请求头”规则，**设置/覆盖** `X-QQM-Origin-Token`。值从服务器本机 `php bin/manage.php origin-token` 查看，不能使用“追加”，不能从访问者请求中照抄，也不要把该值回传到浏览器。
4. 根据套餐选择下面的免费版密钥模式或严格模式。免费版无需寻找“源站防护”网段；有该能力的站点可配置实际当前的回源网段及源站防火墙。SSH、宝塔面板仍只允许你自己的管理来源，保留恢复通道。
5. 确认回源头规则已发布、HTTPS 回源正常后，再启用 `require_origin_token`。验证直接访问源站的动态接口被拒绝、经过 CDN 的接口正常。不要提前开启导致自己无法访问；需要恢复时在服务器本机编辑配置，不要删掉 `data/config.json`。

### EdgeOne 免费版

免费版不支持“源站防护”提供的指定回源网段能力。[官方套餐范围](https://edgeone.ai/document/48535) 本后台提供 `edgeone_token` 模式：仅在回源密钥匹配时，接受单个有效的 `EO-Connecting-IP`，不依赖节点网段。该模式依赖密钥保密，不能代替网络层防火墙；有正确密钥的请求可以通过应用层鉴权。

上传新版代码后，在服务器已有的 `config.php` 返回数组内修改或新增以下字段，**保留数据库、OAuth 和其他配置**：

```php
'proxy_trust_mode' => 'edgeone_token',
'require_origin_token' => true,
'trusted_proxy_cidrs' => [],
'client_ip_header' => 'EO-Connecting-IP',
```

只改 `config.example.php` 不会生效。旧部署若只有 `data/config.json`，也可在其顶层设置同名字段，使用 JSON 的双引号和冒号格式；无需重新安装、建库或生成软件更新密钥。两份配置同时存在时，以上手填字段以 `config.php` 为准。新版本不会自动把旧部署从严格模式改为密钥模式。

EdgeOne 规则保持：HOST 等于 `botmanager.uuze.cn` → 修改 HTTP 回源请求头 → 类型“设置” → 自定义名称 `X-QQM-Origin-Token` → 值为服务器本机 `origin-token` 命令的输出。保存并发布，不能选择“增加/追加”，也不要把密钥作为响应头返回。`EO-Connecting-IP` 是默认回源头，不用再创建自定义规则修改它。[请求头设置与限制](https://cloud.tencent.com/document/product/1552/71012)

密钥使用安装时生成的随机值，只保存在源站和 EdgeOne；源站 HTTPS 证书须有效并正确校验，不能明文 HTTP 回源。不要把密钥放在客户端、截图、日志或 Git。密钥曾被公开时，仅更换服务器 `data/config.json` 内的 `origin_token` 并同步覆盖 EdgeOne 的值；**保留 `signing_secret` 不变**。两端切换期间动态请求可能短暂返回 403，安排在可接受的时间操作。

### 网段和密钥严格模式

默认 `cidr_and_token` 保留双重校验，适用于能获得实际回源网段的部署。网段从本站控制台“安全防护 → 源站防护”获取，保持更新，不复制网上过期列表。[源站防护操作说明](https://cloud.tencent.com/document/product/1552/76086)

```php
'proxy_trust_mode' => 'cidr_and_token',
'require_origin_token' => true,
'trusted_proxy_cidrs' => [], // 必须替换为本站当前实际回源网段
'client_ip_header' => 'EO-Connecting-IP',
```

严格模式下空数组拒绝信任所有转发 IP，只显示实际 TCP 对端。源站 HTTP/HTTPS 防火墙仅允许当前回源网段；更新网段时同时更新应用配置和防火墙，保留恢复通道。不要填 `0.0.0.0/0` 或 `::/0`。`origin_token` 始终保存在私密 JSON 内，不需要复制进 PHP 配置。

## 来源 IP 的判断

EdgeOne 默认回源头 `EO-Connecting-IP` 表示连接到 EdgeOne 的客户端 IP；用户通过 VPN/代理访问时，它仍可能是代理出口，而不是设备的真实公网地址。无需额外开启某个“获取用户 IP” SDK。[官方回源头说明](https://intl.cloud.tencent.com/zh/document/product/1145/54211)

严格模式要求原始连接对端属于可信网段且回源 Token 匹配；免费版模式要求开启强制回源鉴权且密钥匹配。两者都只接受单个有效 IP，拒绝多地址列表，不会回退到浏览器自填的 `X-Forwarded-For` 或 `X-Real-IP`。未采信头部时来源显示 `direct-or-unconfigured-proxy`，地址是连接源站的对端，不一定是访问者。

Nginx 示例通过 FastCGI 的 `QQM_PROXY_ADDR` 传递原始 TCP 地址。若宝塔此前已用 real_ip 模块改写 `$remote_addr`，必须把示例中两处 `QQM_PROXY_ADDR $remote_addr` 改为 `QQM_PROXY_ADDR $realip_remote_addr`，并核对现有 `set_real_ip_from` 只信任实际回源网段。不需要为本站新增信任所有来源的 real_ip 配置。

在后台“部署与安全”点击“立即检测”，先看中文结果。成功时 `reason` 是 `accepted`、`detected.source` 是 `EO-Connecting-IP`、`origin_token_matches` 和 `client_ip_header_valid` 是 `true`。免费版 `trust_mode` 为 `edgeone_token` 时，`trusted_cidrs_count = 0`、`proxy_peer_trusted = false` 均属正常，不代表检测失败。检测只返回布尔结果，不返回密钥。

未成功时，根据 `reason` 排查：

- `proxy_not_in_trusted_cidrs`：密钥已匹配，但仍在严格模式且节点不在网段内。免费版按上方配置切换模式。
- `client_ip_header_missing` / `client_ip_header_invalid`：核对域名确实经过 EdgeOne、Nginx 没有清除默认请求头，且头部是单个地址。若已有 `fastcgi_pass_request_headers off`，应在本站 PHP location 恢复默认传递或显式传递需要的请求头。
- `origin_token_missing` / `origin_token_mismatch`：检查覆盖规则是否发布、匹配的 HOST 是否正确。启用强制鉴权后，这类请求会在进入管理接口前直接返回“回源鉴权失败”403，而不会返回诊断详情；在服务器本机核对密钥，不要公开配置。
- `invalid_peer`：检查 Nginx 的 `QQM_PROXY_ADDR` / `REMOTE_ADDR`，不要用客户端自带的头部填入该参数。

这里检测的是当前浏览器访问，不会补造设备记录。`1.3.1+12` 首次默认开启统计，启动即自动登记，后续每分钟更新；以前关闭的用户保持关闭。修正 IP 配置后，已有记录在下一次成功心跳更新。旧版客户端不会因更新网站而自动获得新功能。

## CDN 缓存和安全规则

- `/api/*`、`/admin*`、`/`、`/privacy`、`/index.php`：不缓存，不改写 JSON/HTML，不注入网页挑战。更新响应含随机 nonce 和到期时间；把它当静态内容缓存会使客户端校验失败。OAuth 登录和回调同样不可缓存。
- `/api/v1/telemetry/*`：允许 POST 和 DELETE；保留 `Authorization`、`Content-Type`。不要求客户端运行 JavaScript 或通过 Cookie 网页挑战；可在边缘按合理阈值限速。
- `/packages/*`：只缓存成功的下载响应，支持 GET、HEAD 和 Range。路径带 SHA-256，内容不可变，可长缓存；不要缓存 403、404、416、500 等错误。撤下版本后清理对应 CDN URL。
- `/assets/*`：可缓存；1.3.2 使用独立版本文件名，不依赖查询参数刷新。上传页面时必须同步上传完整 assets，发布后清理旧 HTML 缓存。不要在 EdgeOne 自动合并、改写后台脚本。
- PHP 接口不设置开放跨域；客户端直接使用 HTTPS，不需要 `Access-Control-Allow-Origin: *`。

PHP 已限制注册、心跳、登录频率；这不替代源站防火墙和边缘抗攻击。不要为了修复一个接口而关闭全站安全防护，按路径调整规则。Nginx、PHP 和 EdgeOne 日志不要保存 OAuth 授权码、Token、Secret，日志和备份保留时间需独立设置。

## 首次接入更新

服务器初始化后执行 `php bin/manage.php public-key`，复制输出中的公开公钥。后续每次构建都必须带相同公钥与域名：

```powershell
flutter build windows --release --dart-define=UPDATE_BASE_URL=https://botmanager.uuze.cn --dart-define=UPDATE_PUBLIC_KEY=公开公钥
flutter build apk --release --dart-define=UPDATE_BASE_URL=https://botmanager.uuze.cn --dart-define=UPDATE_PUBLIC_KEY=公开公钥
```

APK 正式构建前须先配置固定签名，不能用新 debug 证书覆盖旧应用。GitHub 工作流可使用仓库公开变量 `UPDATE_PUBLIC_KEY` 和 `UPDATE_BASE_URL`，私钥只留在服务器。iOS 脚本会读取同名环境变量并传给 Flutter。更新功能从源码 `1.3.0+11` 开始，实际分发前需带公钥重新构建。

更新清单使用 Ed25519 签名，并绑定本次随机 nonce、平台、架构与 15 分钟到期时间；客户端检查包的来源、包名、递增构建号、大小和 SHA-256。下载不接受跳到第三方站点的 HTTP 重定向。泄露服务器签名私钥相当于泄露软件发布权，应保护配置与备份；更换私钥需要为现有客户端制定单独迁移方案，不能让网站自行告诉客户端信任新钥匙。

## 各平台安装行为

Windows 默认自动下载，用户可关闭；下载好后点击“重启并更新”，先保存本地记录并正常断开机器人，再由隐藏的更新助手替换程序和重启，不会强制中断正在使用的机器人。ZIP 更新只覆盖包内文件，不删除安装目录里其他文件；覆盖前保存备份，失败尝试恢复。助手拒绝路径穿越、符号链接、危险目录和超大解压包。软件必须放在独立可写目录，多个同目录实例或杀毒软件锁定文件时可能失败。备份和日志位于应用自己的更新缓存，不在 QQ 配置目录；验证新版正常后再手动清理对应缓存。EXE 使用本项目 Inno Setup 安装器参数，安装器自身的失败处理不等同于 ZIP 文件回滚。

Windows 安装版的构建、公钥、首次手动安装与后台 EXE 发布步骤见 [Windows 安装包与自动更新](windows-release.md)。自动安装使用非常静默模式和错误码检查，不强制结束其他进程；安装详细日志位于更新缓存的 `installer.log`。

Android 下载校验后调用系统 APK 安装界面，用户需允许安装来源并确认；不会静默安装、自动卸载旧版或清除数据。原生端还检查 APK 包名、实际构建号和签名证书必须与已装应用一致。APK 签名有变时会明确拒绝，不会用卸载重装掩盖升级问题。[Android 官方分发说明](https://developer.android.com/distribute/marketing-tools/alternative-distribution)

正式安卓签名放在被 Git 忽略的 `android/key.properties`：

```properties
storeFile=C:/你自己安全保存的位置/botmanager.jks
storePassword=仅在本机填写
keyAlias=你的别名
keyPassword=仅在本机填写
```

保留同一份私钥与备份，不要上传聊天或仓库。缺少该文件的本地 release 仍是测试签名，云端 debug 证书也可能每次变化，不能作为持续升级渠道。

iOS 当前是未签名 IPA 下载和系统分享/导出，可交给全能签使用适用于设备的合法有效证书重签。iOS 不允许本应用直接安装未签名 IPA；导出不等于安装成功，也不会伪造“一键安装成功”。企业分发仅适用获准的企业内部使用场景，不能当成面向所有用户的签名替代方案。[Apple 部署说明](https://support.apple.com/guide/deployment/depce7cefc4d/web)

macOS 使用 Universal DMG。客户端校验签名和 SHA-256 后打开镜像，由用户退出旧版并拖入“应用程序”替换；不会静默安装。当前临时签名测试包未经过 Developer ID 签名或 Apple 公证，正式分发要求另行完成。[Flutter macOS 发布说明](https://docs.flutter.dev/deployment/macos)

## 统计含义和隐私

`1.3.1+12` 首次默认开启使用统计，首次弹窗说明后开始登记，不要求手工加入；旧设置中明确关闭的选择继续保留。客户端启动后自动登记，后续每分钟发送心跳。用户始终可以在“设置 → 更新 → 隐私与使用统计”关闭并请求删除；关闭后不读取新的设备资料、不再上报，离线删除会在联网后重试。

字段限于随机安装 ID、平台、软件版本／构建号、设备名称、设备型号、系统版本和架构；来源 IP 与心跳时间由服务器记录。Windows 设备名称来自本机主机名，可能包含用户设置的姓名；Android 发送公开型号，iOS 名称受系统限制，可能仅为“iPhone/iPad”。统计不读取 QQ AppID、OpenID、机器人凭据、聊天、附件、用户名列表、文件内容、硬件序列号、MAC、Android ID 或广告标识。

页面中的“已上报安装数”不是人数，“近 5 分钟在线”也不代表机器人连接成功。重装、多个设备、代理出口和系统后台暂停都会影响数字。设备资料是客户端提供的展示数据，不能用于身份认证。IP 默认保留 7 天，失活安装连同设备资料 90 天清理；请在宝塔设置每日 `prune` 任务并单独管理 Nginx、CDN、备份中的历史日志。

## 上线验收

先运行 `php bin/manage.php db-check` 确认实际连接的是你创建的 MySQL 专用数据库，网站 PHP 已启用 `pdo_mysql`。如果配置过旧域名，服务器 `config.php`（旧部署为 `data/config.json`）的 `app_url`、杂鱼 OAuth 回调与 GitHub 仓库变量 `UPDATE_BASE_URL` 也要改成 `botmanager.uuze.cn`，更改示例文件不会自动覆盖已保存的配置。

1. 未登录请求管理 API 返回 401；非指定邮箱、缺邮箱权限、错误或重复 state 都不能登录。指定账号成功后可上传草稿和发布，退出后管理 API 再次返回 401。
2. 不带密钥或带错误密钥直连源站动态接口返回 403。经过 CDN 的检测显示 `accepted` 和 `EO-Connecting-IP`；免费版确认 `edgeone_token` 模式，严格模式另确认实际节点网段匹配。不要用公开或弱密钥充当源站身份校验。
3. 新客户端首次手工安装后，发布更高构建号；检查清单通过签名、包校验后才进入就绪。篡改包、清单或重定向不得执行安装。先用专用测试目录，不在真实机器人目录试验覆盖。
4. 用同签名 APK 验证系统覆盖安装；iPhone 验证导出与合法重签，不把 Windows 编译结果当成 iOS 安装验证。
5. 首次默认统计的安装启动后自动出现设备记录，旧版关闭选择不被覆盖；关闭后记录删除且仍可更新。使用自己的授权测试设备，不用真实 QQ 凭据做自动测试。
