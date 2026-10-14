# 手机端与安装包

## 当前能力与限制

已添加 Android/iOS 工程和手机单栏布局。手机端有会话列表、聊天、插件配置、日志和机器人设置；桌面端窗口管理只在 Windows/Linux/macOS 执行。移动端导出配置使用系统文件保存器，选图用途声明已配置。

手机后台/锁屏后，系统可能暂停进程或断开 WebSocket，**不能把手机端当成 24 小时在线的机器人服务器**。长期值守请继续使用桌面/服务器版本。本次没有添加虚假的后台音频或无限后台保活权限。

- Android：模板最低 Android 7.0（API 24），当前提供 debug 签名测试 APK。正式分发需配置自己的签名密钥。
- iOS：最低 iOS 13，标识继承现有工程组织为 `com.qqbot.qqBotManager`。实际签名时须与证书/描述文件匹配；应用仍使用 Flutter 模板图标。
- Windows 本机未配置 Android SDK 时不能编译 APK，也不能直接编译需要 Xcode 的 IPA。原生安装包应在下述云端或相应 SDK 环境构建，是否成功以具体运行记录和产物为准。

## 没有 Mac：用 Windows 操作 GitHub 云端构建

仓库内已提供 `.github/workflows/mobile-build.yml`，**只允许手动触发**，不会在每次推送时自动花费运行额度。没有添加上传到 App Store、发布 Release 或上传证书的步骤，也不会把机器人密钥/高德 Key 打进包里。运行可能消耗 GitHub Actions 额度，按你账号的权限与计费规则执行。

1. 将本次源码改动提交并推送到自己的 GitHub 仓库，确保工作流已在默认分支。
2. 在仓库的 **Actions → 移动端安装包 → Run workflow** 中选择 `all`、`android` 或 `ios`。
3. 等待对应任务成功。在运行页面下方的 **Artifacts** 下载产物 ZIP，并解压：
   - `android-debug-apk`：里面是 `app-debug.apk`，用于安卓测试安装。每次云端 debug 证书可能不同，可能无法直接覆盖上次安装；卸载会删除本机记录，请先导出配置。
   - `ios-unsigned-ipa`：里面是 `qq_bot_manager-unsigned.ipa`。云端先实际编译 iPhone 真机 arm64 应用，再打包为 IPA；不是模拟器包，也不是直接把源码改后缀。

GitHub 返回的外层 ZIP 是下载容器，不是安装包。一定要先解压取出 `.apk` 或 `.ipa` 文件。仅提交源码不会触发构建，必须手动启动工作流并等待成功；任务报错时请提供对应步骤的日志，不要提供密钥。

## 全能签安装

未签名 IPA 必须使用合法有效、适用于目标设备的 Apple 签名证书和描述文件重新签名，才能安装。全能签只能处理签名，不能替代 macOS/Xcode 编译。

将解压得到的 `qq_bot_manager-unsigned.ipa` 导入你的签名工具，使用你已有的有效证书/描述文件签名安装。签名时的 Bundle ID、设备授权和描述文件能力必须一致；工具具体界面以你使用的版本为准。不要使用来路不明的共享证书，也不要把证书、私钥、密码或描述文件发到聊天或提交仓库。

本工作流不需要 Apple 证书 Secret，因为只编译未签名包；**产出 IPA 不代表签名成功、安装成功或获得 Apple 分发许可**。

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
