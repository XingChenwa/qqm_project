# GitHub 托管首页与自动更新

网站和安装包都由 GitHub 托管，不需要服务器、宝塔、PHP、MySQL、杂鱼账号登录或 EdgeOne。原 `management/` 仅保留为旧部署兼容源码，不参与新首页构建。

- 下载首页：<https://xingchenwa.github.io/qqm_project/>，源码在 `site/`，含四端下载、安装说明、更新记录、源码/反馈和 Star 入口。
- 安装包：<https://github.com/XingChenwa/qqm_project/releases>。
- 客户端更新清单：`https://xingchenwa.github.io/qqm_project/updates/stable.json`。

上述是配置后的目标地址，不代表当前已经部署成功。第一次迁移时，旧客户端仍连接原 PHP 网站，需要手动安装一次 GitHub 版；只修改网站无法改变已安装程序内置的地址或公钥。

## 一次性设置

1. 将包含本流程的源码推送到 `XingChenwa/qqm_project` 的默认分支。当前脚本和客户端固定信任此仓库；fork 需同步修改仓库、Pages 地址和下载 URL 校验，不能只改首页链接。
2. 仓库 **Settings → Pages → Build and deployment → Source** 选择 **GitHub Actions**。项目使用 Pages 免费地址，无须填写 DNS 或购买域名。GitHub Free 的 Pages 要求公开仓库；其他套餐以 GitHub 页面显示的权限为准。[官方 Pages 配置说明](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
3. 在 **Settings → Secrets and variables → Actions → Secrets** 配置：

   | Secret | 内容 |
   | --- | --- |
   | `UPDATE_SIGNING_PRIVATE_KEY` | 原更新签名私钥的 Base64 值；支持原 PHP/libsodium 的 64 字节私钥或 32 字节 Ed25519 种子 |
   | `ANDROID_KEYSTORE_BASE64` | 现有安卓上传证书文件的 Base64，必须沿用原签名 |
   | `ANDROID_KEYSTORE_PASSWORD` | 该证书的密码 |
   | `ANDROID_KEY_ALIAS` | 该证书的别名 |

4. 在同页 **Variables** 配置 `UPDATE_PUBLIC_KEY` 为对应的 **32 字节公开公钥 Base64**。原服务器的 `public-key` 命令只输出公钥，不能当成私钥填写。原公钥为 `EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=`；只有持有与它匹配的原私钥才可沿用，流程会校验两者。删除旧的 `UPDATE_BASE_URL` 变量或改为 `https://xingchenwa.github.io/qqm_project`，不能继续使用旧域名。
5. 若 `github-pages` 环境只允许 main，进入 **Settings → Environments → github-pages → Deployment branches and tags**，保留 main 并允许正式标签 `v*`，否则 Release 触发的部署会被环境策略阻止。按你的仓库保护规则审批，不要为此暴露密钥或开放其他分支权限。
6. 手动运行 **Actions → GitHub 下载首页 → Run workflow**。无完整签名版本时，首页显示“尚未发布”并提供 Releases 入口，不伪造下载文件。更新清单只有完整发布后才出现。

私钥只放在 Actions Secret，绝不能放入 Variables、源码、客户端、网站目录或聊天。不要上传原服务器的整个 `data/config.json`、数据库密码或 OAuth Secret。迁移时由你在可信设备上复制其中原 `signing_secret` 的值到 Secret；本流程不会读取生产服务器。

### 没有原私钥时

新建密钥会使旧公钥的客户端无法信任新签名，必须重新分发客户端。确认原私钥确实无法恢复后，才在本机 Node.js 22+ 中运行（路径必须在源码外）：

```powershell
node tool/generate_update_key.mjs 'E:\private-keys\botmanager.ed25519.key'
```

先自行创建并限制输出目录权限。命令只打印公开公钥，私钥以新文件保存且不覆盖已有文件；把文件内容存入 `UPDATE_SIGNING_PRIVATE_KEY`，打印的公钥存入 `UPDATE_PUBLIC_KEY`，随后妥善备份私钥。Windows 还需限制文件 ACL。本项目不会自动生成或更换线上信任密钥。

## 每次发布

1. 同步增加 `pubspec.yaml` 的版本和构建号、`lib/utils/constants.dart` 的 `appVersion/appBuild`。例如 `1.3.7+18` 对应 `v1.3.7`，构建号必须严格递增。先推送并通过测试，不移动或复用已经发布的标签。
2. GitHub **Releases → Draft a new release**，选择已推送的正确提交，标签填 `v1.3.7`，填写更新说明。发布为正式版，不勾选 pre-release。仅保存草稿、推送普通提交或仅推送标签都不会启动四端发布。
3. 点击 **Publish release** 后，`客户端安装包` 工作流校验标签/版本/密钥，再构建 Windows EXE、固定签名 Android APK、未签名 iOS IPA 和 macOS Universal DMG。云端使用 Windows、Linux、macOS runner，可能消耗 Actions 额度。
4. 四端均成功后，流程从**同一次运行**取得安装包，计算大小与 SHA-256，上传到该 Release，最后上传 Ed25519 签名的 `update-manifest.json`，再部署首页和 `updates/stable.json`。失败的平台不会让半成品进入更新清单；首页保留上个完整版本。
5. 打开 Actions 确认构建、Release 上传、Pages 部署均成功，再验证首页四端链接及应用更新弹窗。Windows 自动下载偏好默认开启；安装仍由用户确认。客户端每次启动和运行期间每五分钟检查，不是即时推送，Pages 缓存与网络可能延迟显示。

此“正式 Release 发布后追加构建产物”的流程不支持仓库已启用的 **Immutable releases（不可变版本）**，因为发布后附件会锁定；预检会明确拒绝，不尝试解除保护。若需要不可变版本，应另改为先构建、上传草稿附件、再发布的流程。[GitHub 不可变版本说明](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

通过 `GITHUB_TOKEN` 在另一个工作流创建 Release 通常不会再触发新的工作流；本流程以你在 GitHub 网页发布正式版本为标准入口，不要假设所有 API 发布都会触发。[事件触发说明](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow)

### 只构建测试包 / 只修改首页

- **客户端安装包 → Run workflow** 可选 `all` 或单个平台：只保留 Actions Artifacts，不发布 Release、不改线上更新清单；无需提供更新私钥，但仍需要正确公钥和安卓签名配置。
- 推送 main 中的 `site/`、首页构建脚本或首页工作流改动，会部署首页。也可手动运行“GitHub 下载首页”。它从最近 100 个 Release 中选择构建号最高、签名正确且四端附件齐全的正式版本，不会把正在构建的新 Release 当成空版本覆盖。
- 正式发布失败可重跑失败的任务。已上传的附件仅在内容完全相同时复用；不同内容不覆盖，必须用新版本和更高构建号。不要删除正在供用户下载的签名清单或安装包。编辑已签名版本的说明后重跑可能因清单变化被拒绝，请在下一版更新说明。
- 附件上传成功而 Pages 失败时，排查权限/环境设置，再运行“GitHub 下载首页”；不必重新构建四个平台。

## 校验与平台限制

客户端内置公钥验证签名，校验固定仓库、版本、构建号、平台、包名、大小、SHA-256 和下载地址，只允许当前仓库 Release 资源及指定 GitHub 下载 CDN 的 HTTPS 跳转。不会执行未通过校验的文件。静态清单无法为每次检查生成 nonce；客户端保存看过的最高有效构建号以防回退，但无法保证网络上的清单绝对最新。更新服务不可用不影响聊天。

| 平台 | 包与安装行为 |
| --- | --- |
| Windows x64 | EXE，默认后台下载，确认后退出并运行安装器，保留应用数据 |
| Android | APK，必须沿用原证书，校验后交给系统安装器，不能静默绕过安装授权 |
| iOS arm64 | 未签名 IPA，应用内导出后需有效证书和描述文件在全能签等工具重签；下载不等于可安装 |
| macOS Universal | DMG，Apple Silicon / Intel，打开后拖入“应用程序”；当前为临时签名、未公证测试包 |

## 设备统计已整套移除

客户端不再读取设备名称/型号或生成统计安装 ID，不发注册、心跳或统计删除请求。旧后台不再展示使用设备、在线数、版本分布，不再提供统计查询或设备删除；旧统计接口返回 410。新 MySQL 安装不创建统计表，已有两张历史统计表保持原样，清理任务也不修改它们。此源码修改不会自动更改你已经部署的旧服务器或已安装的旧客户端；停用旧站前先自行备份所需历史资料。

新方案没有自己的用户/设备追踪后台。GitHub 作为网站与下载托管方仍能收到正常网络请求和来源 IP，不能把“不上报设备资料”理解为网络访问没有服务日志。

## 本地验证（不发布）

```bash
flutter analyze --no-pub
flutter test --no-pub
node --test tool/tests/github_release.test.mjs
```

`tool/tests/site_browser.mjs` 可用 Playwright 对合成版本做 320/390/1280px 首页、空版本和恶意数据检查，不访问真实机器人。线上 Secrets、Pages 环境权限和原生四端构建仍需第一次真实运行验证；本地测试通过不等于已经线上发布。

首次上线后，可用下面的只读命令验证 Pages 清单的签名（替换为你使用的公开公钥，不要填私钥），不会启动机器人或下载安装包：

```bash
dart run tool/check_update_server.dart https://xingchenwa.github.io/qqm_project 你的公开公钥
```
