# GitHub 版本发布与网站

## 1. 一个仓库，三个位置

| 内容 | 位置 |
| --- | --- |
| 客户端源码、开发文档、Actions | [qqm_project / main](https://github.com/XingChenwa/qqm_project/tree/main) |
| 官网 HTML / CSS / JS | [qqm_project / docs](https://github.com/XingChenwa/qqm_project/tree/docs) 分支根目录 |
| 四端安装包与签名清单 | [qqm_project / Releases](https://github.com/XingChenwa/qqm_project/releases) |
| 首页 | <https://xingchenwa.github.io/qqm_project/> |
| 客户端更新入口 | `https://xingchenwa.github.io/qqm_project/updates/stable.json` |

不需要宝塔、PHP、MySQL 或额外下载仓库。设备统计已移除，现有历史数据库不会被流程删除。

**仓库可见性由所有者自己修改。** 迁移脚本和工作流不会把私有仓库自动公开。使用免费 GitHub Pages 时，应先公开仓库，再启用网站；在此之前，源码和分支准备好不代表网站已能公开访问。公开会暴露所有可访问的分支、标签与 Git 历史，请先检查历史凭据，必要时先轮换密钥，不要只删除当前文件。

## 2. 一次性配置

### 启用 Pages

在本仓库 Settings → Pages：

1. Source 选择 **Deploy from a branch**。
2. Branch 选择 **docs**，目录选择 **/ (root)**，保存。
3. 首次构建完成后访问上表首页地址；不要选 main，也不要把 docs 分支与 main 中的 docs/ 文档目录混淆。
4. 在 Actions 中手动运行“刷新网站下载与更新清单”，验证下载信息同步。

网站分支根目录有 `.nojekyll`，不需要安装构建工具。直接编辑并推送该分支的网站会触发 Pages；Actions 使用 GITHUB_TOKEN 推送的更新不会自动触发，因此同步脚本会额外请求 Pages 构建。参见 [GitHub 的发布源说明](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site) 和 [Pages 构建 API](https://docs.github.com/en/rest/pages/pages#request-a-github-pages-build)。

### Actions Secrets / Variables

在 Settings → Secrets and variables → Actions 配置：

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Secret | `UPDATE_SIGNING_PRIVATE_KEY` | 必填：原 Ed25519 私钥的标准 Base64，32 字节种子或 64 字节 libsodium 私钥 |
| Secret | `ANDROID_KEYSTORE_BASE64` | 固定 Android 签名文件的 Base64 |
| Secret | `ANDROID_KEYSTORE_PASSWORD` | Android 签名密码，当前流程用同一密码解锁 Key |
| Secret | `ANDROID_KEY_ALIAS` | Android Key 别名 |
| Variable | `UPDATE_PUBLIC_KEY` | 对应的 32 字节 Ed25519 公钥 Base64，嵌入安装包 |
| Variable | `UPDATE_BASE_URL` | `https://xingchenwa.github.io/qqm_project` |

沿用原公钥：`EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=`。这是公开验证材料，**不能当私钥填写**。现有私钥只留在你自己的安全存储和 Actions Secret 中，不要发送到聊天。公钥不匹配时流程会拒绝发布，客户端不会从网页自动信任新公钥。

同仓库发布直接使用 GitHub 自动提供的 `GITHUB_TOKEN`，不再需要跨仓库 PAT 或 SSH 部署密钥。不要将任何 token、私钥、证书上传到 docs 分支。

权限限制：

- 构建任务只读源码，发布前检查任务另有 Pages 只读权限。
- 发布任务有 Actions 读取、Contents 写入和 Pages 写入权限。
- 网站刷新任务只有 Contents / Pages 写入权限。
- 不修改仓库可见性、标签指向、既有安装包或历史数据库。
- 若组织策略限制 GITHUB_TOKEN 写入，应由管理员按需放行上述权限；不要把令牌直接写入 YAML。

### 关于 Release 不可变设置

当前流程监听正式 Release 的 `published` 事件，构建结束后才上传附件。因此用于此流程的 Release **不能在发布时立即启用不可变锁定**，否则 GitHub 不允许追加安装包。预检会在耗时构建前明确拒绝不可变版本。若需要不可变发布，应另行设计“先构建并上传草稿，再发布”的流程，不要通过关闭签名校验绕过。

## 3. 发布一个正式版本

1. 修改 `pubspec.yaml` 的版本与递增 build，例如 `1.3.7+18`，同时更新 `lib/utils/constants.dart` 中的版本常量。
2. 运行测试、审阅改动并提交到 main。构建号必须递增，不复用已正式发布的构建号。
3. 在本仓库创建匹配的正式 Release，例如标签 `v1.3.7`，写明更新内容，目标选已核验的提交，不勾选预发布。
4. “客户端安装包”自动预检标签、仓库公开状态、Pages 来源、签名密钥，然后构建 Windows、Android、iOS、macOS。
5. 四端全部成功后，同一任务下载这些构建产物，核对 Windows 更新配置，计算包大小及 SHA-256。
6. 上传四个安装包；**签名清单最后上传**。不覆盖同名附件，不创建另一个 Release、不移动标签。
7. 更新 docs 根目录 `releases.json`、`updates/stable.json`，提交后显式请求 Pages 构建。网页源文件保持原样。
8. Pages 完成后，客户端下次检查更新即可发现更高构建号。Windows 下载校验后打开安装程序；其他平台提供系统允许的安装或下载入口，不能绕过系统签名授权。

正式附件：

```text
qqbotmanager-windows-v<版本>-build<构建号>-setup.exe
app-release.apk
qq_bot_manager-unsigned.ipa
qqbotmanager-macos-universal.dmg
update-manifest.json
```

签名清单采用 schema 2：Ed25519 签名包含仓库、标签、构建号及四平台 URL、大小和 SHA-256。客户端同时限制仓库和下载跳转域名，并拒绝回退。首页 JSON 用于展示，客户端以签名清单为信任依据。

如果只需测试包，手动启动“客户端安装包”并选择平台；产物保存在 Actions Artifacts，**不发布正式版，不触发推送更新**。

## 4. 维护网站

请在独立 checkout 中编辑 docs，避免切换覆盖未提交的源码改动：

```sh
git worktree add ../qqm-website docs
```

若本地没有 docs，先 `git fetch origin docs`，再从 `origin/docs` 创建本地跟踪分支。网页文件位于该 checkout 根目录：

- `index.html`：首页内容。
- `assets/site.css`：样式与手机布局。
- `assets/site.js`：下载资料校验与显示。
- `assets/logo.png`：项目 Logo。
- `releases.json`、`updates/stable.json`：自动生成，不手写版本或假下载地址。

只有这两个 JSON 会被自动发布流程修改。首页暂未发布、读取失败和异常下载链接均有明确回退。SHA-256 不替代来源校验和客户端数字签名。

## 5. 检查与恢复

在 main checkout 中，指定网站 checkout 后运行：

```sh
WEBSITE_DIRECTORY=../qqm-website node --test tool/tests/github_release.test.mjs tool/tests/github_site_sync.test.mjs
WEBSITE_DIRECTORY=../qqm-website node tool/tests/site_browser.mjs
dart run tool/check_update_server.dart https://xingchenwa.github.io/qqm_project 你的公开公钥
```

以上环境变量写法适用于 Bash；PowerShell 使用 `$env:WEBSITE_DIRECTORY='../qqm-website'`。网页浏览器测试需要 Playwright / Chromium，可设置 `QQM_PLAYWRIGHT` 和 `QQM_CHROME` 指定本机依赖。

- 网站 404：确认仓库已公开、Pages 选 docs 根目录、Pages 构建完成。
- 签名错误：检查原私钥与客户端内置公钥，不要随意重新生成或换钥。
- 某端失败：不会更新签名入口，上一正式版仍可用；修复后重跑。已上传但未签名的部分附件不会作为新版推送。
- 同名附件不同：流程拒绝覆盖，请使用新版本和新构建号，不加 `--clobber`。
- 附件已上传但 Pages 失败：修复 Pages 后运行“刷新网站下载与更新清单”；它会验证已有签名再同步，不重新构建四端。
- docs 并发修改：推送遇到非快进会失败，不会强推；重新运行会基于最新 docs 重试。
- 旧客户端仍绑定旧下载地址：手动安装一次迁移后的客户端，不能依靠更换网页让旧客户端自动信任不同仓库。
