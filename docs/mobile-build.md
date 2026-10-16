# 手机端和 macOS 安装包

## 当前能力与限制

已添加 Android/iOS 工程和手机单栏布局。手机端有会话列表、聊天、插件配置、日志和机器人设置；桌面端窗口管理只在 Windows/Linux/macOS 执行。移动端导出配置使用系统文件保存器，选图用途声明已配置。

手机后台/锁屏后，系统可能暂停进程或断开 WebSocket，**不能把手机端当成 24 小时在线的机器人服务器**。长期值守请继续使用桌面/服务器版本。本次没有添加虚假的后台音频或无限后台保活权限。

- Android：模板最低 Android 7.0（API 24）。GitHub 构建使用仓库密钥里的同一把上传证书，并同时启用 V1、V2、V3 签名，后续正式包可以互相覆盖安装。
- 安卓构建固定使用 AGP 8.13.2、Gradle 8.13、Kotlin 2.3.20 和 JDK 17，以兼容现有 `file_picker 11.x`。不要单独升级 AGP 9：该插件会跳过传统 Kotlin 插件，而当前 Flutter 工程禁用内置 Kotlin，会导致 `FilePickerPlugin` 未编译。
- Android、iOS 和 macOS 包名均为 `cn.uuze.botmanager`，使用 `assets/branding/logo.png` 生成的应用图标。当前源码版本为 1.3.6+17；现有下载产物不会因改源码自动更新。
- iOS：最低 iOS 13；实际重签时 Bundle ID 须与证书/描述文件匹配。更换包名会视为新应用，不会自动迁移旧包名下的数据。
- Windows 本机未配置 Android SDK 时不能编译 APK，也不能直接编译需要 Xcode 的 IPA。原生安装包应在下述云端或相应 SDK 环境构建，是否成功以具体运行记录和产物为准。

## 没有 Mac：用 Windows 操作 GitHub 云端构建

仓库提供 `.github/workflows/mobile-build.yml`：手动运行只构建测试包；发布正式 Release 则自动构建四端、上传安装包及签名清单，并部署 GitHub Pages。不会上传 App Store，也不会把机器人密钥、高德 Key、安卓私钥或更新私钥打进源码。云端运行可能消耗 Actions 额度。首次配置见 [GitHub 发布指南](github-release.md)。

1. 将本次源码改动提交并推送到自己的 GitHub 仓库，确保工作流已在默认分支。
2. 在仓库的 **Actions → 客户端安装包 → Run workflow** 中选择 `all`、`android`、`ios` 或 `macos`。
3. 等待对应任务成功。在运行页面下方的 **Artifacts** 下载产物 ZIP，并解压：
   - `android-release-apk`：里面是 `app-release.apk`。云端每次使用同一把上传证书。以前用 debug 证书安装的版本签名不同，不能直接覆盖，需先导出配置再卸载旧版。
   - `ios-unsigned-ipa`：里面是 `qq_bot_manager-unsigned.ipa`。云端先实际编译 iPhone 真机 arm64 应用，再打包为 IPA；不是模拟器包，也不是直接把源码改后缀。

`macos-universal-packages` 包含 DMG 安装镜像和 ZIP 备用包。构建须通过 Apple Silicon、Intel 双架构和签名完整性检查；当前为临时签名、未公证测试包。

GitHub 返回的外层 ZIP 是下载容器，不是安装包。一定要先解压取出 `.apk` 或 `.ipa` 文件。仅提交源码不会触发构建，必须手动启动工作流并等待成功；任务报错时请提供对应步骤的日志，不要提供密钥。

## 内置浏览器与手机版网页

聊天正文、Markdown、卡片和附件的网页链接保持在应用内浏览页，默认请求手机版，右上角可切换电脑版。桌面窗口里手机版网页居中显示为手机宽度；在手机端直接适应屏幕宽度。不会篡改链接的域名、签名参数或片段，也不会为了打不开的网页自动启动系统浏览器。网站没有手机版或要求特定客户端时，仍可能不提供移动布局。

实现依据：[InAppWebView 设置](https://inappwebview.dev/docs/webview/in-app-weview-settings/)中的 `preferredContentMode` 和 `userAgent`；Windows WebView2 不实现移动内容模式，因此额外提供手机标识和窄视口。

## 版本更新服务

`1.3.0+11` 开始提供更新服务。`1.3.1+12` 每次启动发现更高构建号都会弹出提醒，“稍后”只影响本次运行；没有新版时不反复弹窗。移动工作流默认内置已核对的服务器公开更新公钥，可用仓库变量 `UPDATE_PUBLIC_KEY` 覆盖；客户端不会从网站下载新公钥自行信任。未内置公钥的其他构建安全关闭自动更新。

设备统计已整套移除，客户端不再读取设备名称/型号，也不发送统计注册或心跳。更新默认读取 GitHub Pages 的签名静态清单，安装包来自 GitHub Releases；旧版需要手动安装一次迁移版。设置与限制见 [GitHub 发布指南](github-release.md)。更新签名私钥只存 Actions Secret，不能打入安装包。

## 全能签安装

未签名 IPA 必须使用合法有效、适用于目标设备的 Apple 签名证书和描述文件重新签名，才能安装。全能签只能处理签名，不能替代 macOS/Xcode 编译。

将解压得到的 `qq_bot_manager-unsigned.ipa` 导入你的签名工具，使用你已有的有效证书/描述文件签名安装。签名时的 Bundle ID、设备授权和描述文件能力必须一致；工具具体界面以你使用的版本为准。不要使用来路不明的共享证书，也不要把证书、私钥、密码或描述文件发到聊天或提交仓库。

本工作流不需要 Apple 证书 Secret，因为只编译未签名包；**产出 IPA 不代表签名成功、安装成功或获得 Apple 分发许可**。

## macOS 构建和安装

Windows 使用上述 macOS 云端任务；有 Mac 时运行 `flutter pub get` 和 `bash scripts/build_macos_package.sh`。脚本真实编译 `QQBotManager.app`、验证双架构与签名完整性，再生成 DMG 和 ZIP，不会以源码替代应用。需要 macOS 11 或更新版本；实际系统要求也受 Flutter 与插件支持范围约束。

打开 DMG，将 QQBotManager 拖入“应用程序”，推出镜像后再启动；覆盖更新前先退出旧版。后台发布选择 macOS / universal / DMG，客户端校验更新后打开镜像，手动完成替换。

当前仅使用 ad-hoc 临时签名，未提供 Developer ID 证书和 Apple 公证，因此不能保证所有 Mac 都可直接启动。不要关闭 Gatekeeper 或运行未知绕过命令，核验来源后参考 [Apple 安全打开说明](https://support.apple.com/zh-cn/102445)。面向公众正式分发应使用自己的有效 Developer ID 签名并公证。[Flutter macOS 发布说明](https://docs.flutter.dev/deployment/macos)

## 自己有构建环境时

Windows 配置好 Android SDK/JDK 17 后：

```powershell
flutter doctor -v
flutter pub get
flutter build apk --debug
```

Mac 配置好 Flutter/Xcode 后：

```bash
flutter pub get
bash scripts/build_unsigned_ipa.sh
```

有 Apple 正式签名环境时，也可在 Xcode 中选择自己的 Team，再使用 Flutter 官方 `flutter build ipa` 导出签名包。

依据：[Flutter iOS 构建说明](https://docs.flutter.dev/deployment/ios)、[Android 开发环境](https://docs.flutter.dev/platform-integration/android/setup)。
