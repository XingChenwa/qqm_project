# Windows 安装包与自动更新

Windows 使用一个中文 `Setup.exe` 完成首次安装，之后由应用下载经过签名与 SHA-256 校验的安装包，用户确认后退出、覆盖安装并重启。安装器默认只安装到当前用户的程序目录，不要求管理员权限，不强制关闭其他应用。更新不会删除机器人配置、聊天记录或安装目录中与程序包无关的文件。

## 首次安装

安装包名为 `qqbotmanager-windows-v1.3.0-build11-setup.exe`，适用于 Windows 10/11 x64。安装前从旧程序的托盘菜单退出；双击安装包，按中文向导选择安装位置，可选创建桌面快捷方式。默认位置为当前用户的 `%LOCALAPPDATA%\Programs\QQBotManager`。

旧版 `1.2.6` 不含更新服务，必须先手动安装一次 `1.3.0+11`。新版本使用原有的 Windows 应用数据标识，不因安装目录变化而切换机器人数据目录；安装器不负责跨 Windows 用户搬运数据。不要为更新先卸载旧版或删除个人数据。

运行所需的 x64 C++ Release 运行库随包放在应用目录，不修改 Windows 系统运行库。内置网页功能仍使用系统的 WebView2 Runtime；本包不捆绑完整浏览器运行时。如果系统缺少 WebView2，应使用微软的受支持安装方式补齐，不要从不明网站下载 DLL。C++ 本地部署方式依据 [Flutter 打包说明](https://docs.flutter.dev/platform-integration/windows/building) 与 [微软部署说明](https://learn.microsoft.com/en-us/cpp/windows/deployment-in-visual-cpp)。本地运行库的安全更新需随之后的应用版本一起发布。

## 发布到宝塔后台

打开 `https://botmanager.uuze.cn/admin`，在“版本发布”上传 EXE 并保存草稿：

| 字段 | 本次值 |
| --- | --- |
| 平台 | Windows |
| 架构 | x64 |
| 安装包类型 | Inno Setup EXE |
| 版本号 | 1.3.0 |
| 构建号 | 11 |

核对后点击“发布”，首页才会提供下载。**后台只上传 EXE，ZIP 留作备用。** 同一平台、架构、构建号只能上传一次，不要把两个包以相同构建号重复上传；如果已占用该构建号，应重新递增构建并打包，不能只在后台伪填更高数字。

客户端启动后及每 5 分钟检查更新。Windows 默认自动下载，用户可关闭；安装始终需要点击“重启并更新”。此时先保存记录并正常断开机器人，再由隐藏助手执行安装，安装日志保存在该次更新缓存的 `installer.log`。不向用户隐藏强制重启操作，也不通过 PHP 长连接模拟即时推送。

已经安装 `1.3.0+11` 时，发布同一个构建号不会再次提示升级。下一个版本必须使用大于 `11` 的真实构建号，并在 `pubspec.yaml` 与 `lib/utils/constants.dart` 同步修改后重新构建。

## 更新公钥与代码签名

当前服务器提供的公开更新公钥为：

```text
UPDATE_PUBLIC_KEY=EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=
```

构建时将该公钥与 `https://botmanager.uuze.cn` 一起内置。私钥只保存在宝塔服务器；不要把 `signing_secret` 放进源码、客户端、构建参数或聊天。不要删除服务器配置重新生成私钥，否则已安装的客户端会拒绝另一把密钥签署的更新。

软件更新签名不等于 Windows 的 Authenticode 发布者证书。本项目的安装包在没有另行提供有效代码签名证书时属于未做 Authenticode 签名的程序。发布时保留 SHA-256 校验信息，不要要求用户关闭整机安全防护。

## 本地构建

先准备项目本地的 Inno Setup 6.7.3 便携编译器；脚本校验下载文件的 SHA-256、官方发布者签名及固定版本中文语言文件，不注册系统文件关联或创建快捷方式：

```powershell
./tool/prepare_inno.ps1
./tool/build_windows_release.ps1 `
  -UpdatePublicKey 'EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=' `
  -UpdateBaseUrl 'https://botmanager.uuze.cn' `
  -Installer `
  -Iscc './build/tools/inno-6.7.3/ISCC.exe'
```

需要 Flutter 和 Visual Studio C++ 桌面开发工具。`-Flutter` 可指定 Flutter 命令路径。构建助手显式使用生产入口 `lib/main.dart`，按安装清单拷贝到新的暂存目录，加入同一 Visual Studio 的签名 Release CRT，再分别生成 EXE、备用 ZIP 和 `build-info.json`。构建信息只含公开公钥、版本、更新地址与文件校验值，不含机器人账号或服务器私钥。已有同版本产物时拒绝覆盖。

更新域名或其他自部署实例必须使用其自己的可信公钥，不要让客户端运行时从未经验证的网站下载替代公钥。检查线上签名而不启动机器人、注册统计或下载安装包：

```powershell
dart run tool/check_update_server.dart https://botmanager.uuze.cn EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=
```

## 验证与测试隔离

```powershell
flutter test --no-pub
./tool/test_windows_updater.ps1
./tool/run_update_smoke.ps1 -Format both -Iscc './build/tools/inno-6.7.3/ISCC.exe'
```

原生自测会先显式编译 `tool/update_smoke.dart`，只使用内存配置和新建的 GUID 临时目录，不启动生产入口、Hive 或 QQ 网络。EXE 测试使用独立且短于注册表名称截断限制的测试 AppID，不覆盖正式卸载记录或快捷方式；验证首次安装、覆盖升级、原目录保留、重启及卸载不删除无关测试文件。结束后清理测试安装注册，日志与剩余测试文件留在 `build/update-smoke-*` 中。

自测编译会覆盖 `build/windows/.../Release` 的临时构建结果，因此自测后必须重新运行生产构建助手，不可直接把自测目录打包分发。不要在真实机器人目录演练替换、卸载或回滚。
