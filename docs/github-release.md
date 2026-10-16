# 双仓库 GitHub 首页与自动更新

主源码与公开下载分开管理，不需要宝塔、PHP、MySQL 或 EdgeOne。

| 用途 | 仓库或地址 | 可见范围 |
| --- | --- | --- |
| 源码、测试和四端构建 | `XingChenwa/qqm_project` | 保持私有，不复制 Git 历史 |
| 首页、安装包、更新清单与反馈 | [qqm-releases](https://github.com/XingChenwa/qqm-releases) | 公开 |
| 下载首页 | <https://xingchenwa.github.io/qqm-releases/> | 公开 |
| 客户端更新清单 | `https://xingchenwa.github.io/qqm-releases/updates/stable.json` | 首个完整签名版本发布后生成 |

公开首页已启用 GitHub Pages，包含四端下载、macOS 安装说明、更新记录、Star 与反馈入口。还没有完整签名安装包时，首页显示等待发布；页面可访问不表示新版安装包已经构建。旧客户端需要手动安装一次迁移版，才能更改内置的更新地址与下载仓库校验范围。

## 配置位置

所有私密配置都放在**私有源码仓库**的 [Actions Secrets](https://github.com/XingChenwa/qqm_project/settings/secrets/actions)。公开仓库不需要机器人凭据、安装包签名私钥或其他 Secrets。

| Secret | 状态及用途 |
| --- | --- |
| `DISTRIBUTION_DEPLOY_KEY` | 已配置，仅能写公开 `qqm-releases` 仓库的 SSH 部署密钥，用于首页同步 |
| `UPDATE_SIGNING_PRIVATE_KEY` | 需由你填写原更新签名私钥的 Base64 值；支持 PHP/libsodium 64 字节私钥或 32 字节 Ed25519 种子 |
| `PUBLIC_RELEASE_TOKEN` | 需由你创建并填写，仅授予公开 `qqm-releases` 仓库 Contents 读写权限的 fine-grained token，用于发布安装包 |
| `ANDROID_KEYSTORE_BASE64` | 现有安卓签名证书 Base64，保持原值 |
| `ANDROID_KEYSTORE_PASSWORD` | 现有安卓证书密码，保持原值 |
| `ANDROID_KEY_ALIAS` | 现有安卓证书别名，保持原值 |

仓库 Variables 已设置 `UPDATE_BASE_URL=https://xingchenwa.github.io/qqm-releases` 与原公开公钥 `UPDATE_PUBLIC_KEY=EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=`。更新签名私钥必须与该公钥匹配；公钥不能当成私钥填写，客户端也不会从网页下载新公钥自行信任。

### 填写更新签名私钥

在自己的可信设备上，从原服务器私密配置中取得原 `signing_secret` **值**，存入 `UPDATE_SIGNING_PRIVATE_KEY`。不要上传整个 `data/config.json`，不要提交源码、写入 Variables、放进公开仓库或发送到聊天。

如果原私钥丢失，必须先明确换钥与重新分发客户端。辅助命令只在本机生成新密钥，不覆盖旧文件；输出路径必须在源码外：

```powershell
node tool/generate_update_key.mjs 'E:\private-keys\botmanager.ed25519.key'
```

先创建并限制该目录权限。命令只打印公钥，私钥保存到指定文件；Windows 还需限制文件 ACL。使用新公钥后要同步修改私有仓库 Variables 并重新构建，旧公钥客户端不会接受新签名。

### 创建公开仓库发布令牌

在 GitHub **Settings → Developer settings → Personal access tokens → Fine-grained tokens** 新建令牌：

1. Resource owner 选择 `XingChenwa`。
2. Repository access 选 **Only select repositories**，仅选 `qqm-releases`，不要授权私有源码仓库。
3. Repository permissions 只给 **Contents: Read and write**，Metadata 保留默认读取。不需要管理账号、修改工作流或读取其他私有仓库。
4. 设置适当有效期，将令牌保存到私有源码仓库的 `PUBLIC_RELEASE_TOKEN` Secret；到期后需更新。

不要将电脑上的高权限登录凭据复制给 Actions。[GitHub 创建细粒度令牌说明](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)

SSH 部署密钥只能同步 Git 文件，不能代替 Release API 令牌。它与更新签名私钥是不同用途：撤销公开仓库 Deploy Key 后可重新配置，不要因此更换客户端信任的 Ed25519 更新公钥。[部署密钥说明](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)

## 每次发布安装包

1. 在私有源码中同步增加 `pubspec.yaml` 版本和构建号，以及 `lib/utils/constants.dart` 的 `appVersion/appBuild`。例如 `1.3.7+18` 对应标签 `v1.3.7`，构建号严格递增。推送通过测试的源码。
2. 在**私有源码仓库** Releases 创建该标签的正式 Release，选择正确提交，不勾选 pre-release。更新说明的前 2000 字符将公开到下载仓库，不能填写密钥、内网地址或其他私密内容。仅保存草稿或推送标签不会触发。
3. 点击 Publish release 后，私有 `客户端安装包` 工作流预检版本、公私钥与公开仓库令牌，再构建 Windows EXE、固定签名 Android APK、未签名 iOS IPA 和 macOS Universal DMG。
4. 四端均成功后，只从**同一次运行**取得四个明确的安装包文件，校验版本与公钥，计算大小和 SHA-256。公开仓库创建独立草稿 Release，标签指向公开仓库 main，而不是私有源码提交。
5. 所有附件及 Ed25519 签名清单上传成功后，才发布公开草稿。最后将静态首页与签名清单同步到公开仓库，由公开仓库的 Pages 工作流部署。支持公开仓库的不可变版本，因为发布前附件已经齐备。
6. 检查私有构建、公开 Release 与公开 Pages 均成功，再验证四端下载及客户端弹窗。Windows 默认自动下载，安装仍需确认；客户端启动及每五分钟检查，不是即时推送，缓存或网络可能延迟显示。

跨仓库令牌只用于公开 Release API；私有仓库的临时 `GITHUB_TOKEN` 用于读取本次构建产物。网页同步仅复制 `site/` 的允许文件，禁止应用源码、私密配置、符号链接和私有仓库路径。公开仓库不会获得私有源码或其 Git 历史。

云端构建可能消耗 Actions 额度。通过另一个工作流的 `GITHUB_TOKEN` 创建私有 Release 不一定触发新工作流，标准入口是在 GitHub 网页发布正式版。[工作流触发说明](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow)

## 首页与失败重试

- 私有 main 中的 `site/`、首页构建脚本或首页工作流变化会自动同步公开首页。也可手动运行私有 `GitHub 下载首页`。仅需部署密钥和公钥，不依赖安装包签名私钥或发布令牌。
- 公开仓库 Pages 设置为 **GitHub Actions**；环境只需允许 main。工作流模板在 `deploy/github-distribution/pages.yml`，仅上传公开 `site/`，没有私有仓库 Secrets。
- 首页选择最近 100 个公开 Release 中构建号最高、签名正确且四端附件齐全的正式版本。新版本未完成时保留上个完整版本，不发布半成品。
- 安装包上传失败后只重跑失败的发布任务，复用同一次运行产物。相同附件必须字节一致，绝不覆盖不同内容；重新构建产生不同文件时，使用新版本和更高构建号。
- 公开 Release 成功但首页同步失败，可单独运行私有 `GitHub 下载首页`，无需重新构建四端。
- 私有 `客户端安装包 → Run workflow` 仍可仅构建测试包，保存在私有 Actions Artifacts，不创建公开 Release。没有签名私钥时不要声称已完成自动更新发布。

## 平台与校验

客户端验证内置公钥签名、公开仓库、平台、包名、大小、SHA-256 和指定 GitHub HTTPS 下载跳转。不会执行未通过校验的文件。静态清单不能为每次请求生成 nonce；客户端记录已见过的最高有效构建号以防回退，但无法保证服务器上的版本绝对最新。

| 平台 | 安装方式 |
| --- | --- |
| Windows x64 | 下载校验后的 EXE，用户确认后退出并覆盖安装，保留应用数据 |
| Android | 同证书 APK，交给系统安装器，不绕过安装授权 |
| iOS arm64 | 导出未签名 IPA，需合法有效证书及描述文件在全能签等工具中重签，下载不等于安装 |
| macOS Universal | 打开 DMG，拖入应用程序；当前为临时签名、未公证测试包 |

设备统计已整套移除，客户端不再读取设备名称、型号或生成统计安装 ID，不发送统计注册和心跳。旧后台统计接口返回 410，历史数据库不自动删除。旧 `management/` 不参与部署。GitHub 托管仍会收到正常访问及来源 IP，设备统计移除不代表网络访问没有托管方日志。

## 验证

```bash
flutter analyze --no-pub
flutter test --no-pub
node --test tool/tests/github_release.test.mjs tool/tests/github_site_sync.test.mjs
dart run tool/check_update_server.dart https://xingchenwa.github.io/qqm-releases 你的公开公钥
```

最后一条只读取签名清单，不启动机器人或下载安装包；首个完整签名版本发布前会返回不存在。Playwright 可运行 `tool/tests/site_browser.mjs` 验证 320/390/1280px 页面、空版本、恶意文本和下载地址。原生四端安装与用户设备上的系统授权仍需实际验证。
