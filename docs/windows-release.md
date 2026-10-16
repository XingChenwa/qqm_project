# Windows 安装包与更新

Windows 使用中文 EXE 安装向导，正式版由 [本仓库 Releases](https://github.com/XingChenwa/qqm_project/releases) 分发。首页和客户端更新清单位于 <https://xingchenwa.github.io/qqm_project/>，不再需要部署宝塔、PHP 或 MySQL。

首次配置与正式发布请先看 [GitHub 发布指南](github-release.md)。这里介绍安装体验及本地打包。

## 安装与升级

- Windows 10/11 x64，安装包名为 `qqbotmanager-windows-v<版本>-build<构建号>-setup.exe`。
- 默认安装到当前用户的 `%LOCALAPPDATA%\Programs\QQBotManager`，不要求管理员权限。
- 安装前从托盘菜单退出旧程序。更新不要求先卸载，不删除机器人配置、聊天记录或安装目录中的无关文件。
- 程序发现更高构建号后显示更新弹窗，默认下载并验证签名清单、文件大小和 SHA-256。安装仍需用户点击“重启并更新”，不会静默强制重启。
- 本次选择“稍后”不影响下次启动检查；也可从设置手动检查。不能把同一构建号重复发布当成升级。
- 旧客户端若仍绑定旧地址，需要手动安装一次迁移版本，不应放宽来源和签名校验。

运行所需的 x64 C++ Release 运行库随包放在应用目录，内置网页仍需系统 WebView2 Runtime。本包不捆绑完整浏览器运行时，缺少时应通过微软受支持渠道补齐，不从不明网站下载 DLL。

## 更新签名

构建中嵌入公开公钥和项目 Pages 地址：

```text
UPDATE_PUBLIC_KEY=EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=
UPDATE_BASE_URL=https://xingchenwa.github.io/qqm_project
```

更新私钥仅保存于你自己的安全存储和 Actions Secret `UPDATE_SIGNING_PRIVATE_KEY`，不打入客户端，不上传网站，不发到聊天。客户端不会从网页自行信任替代公钥。

更新清单的 Ed25519 签名不等于 Windows Authenticode 发布者签名。未另行提供有效发布者证书时，EXE 不具备 Authenticode 签名；请保留来源与校验信息，不要求用户关闭整机防护。

## 本地构建

需要 Flutter 3.44.3 和 Visual Studio C++ 桌面开发工具。先准备项目本地 Inno Setup 6.7.3，准备脚本会检查安装来源与固定版本资源。

```powershell
./tool/prepare_inno.ps1
./tool/build_windows_release.ps1 `
  -UpdatePublicKey 'EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=' `
  -UpdateBaseUrl 'https://xingchenwa.github.io/qqm_project' `
  -Installer `
  -Iscc './build/tools/inno-6.7.3/ISCC.exe'
```

`-Flutter` 可指定 Flutter 命令路径。脚本显式使用生产入口 `lib/main.dart`，拷贝运行清单与相应 Release CRT，在 `dist/` 生成 EXE、备用 ZIP 与 `build-info.json`；已有同版本输出时拒绝覆盖。构建信息只有版本、公开公钥、更新地址及校验值，不包含任何私钥。

本地生成不等于正式发布。要自动生成四端签名更新，请在版本递增、测试通过并提交后发布匹配标签的 Release，遵循 [发布指南](github-release.md)。

只读检查线上签名，不启动机器人、不下载安装包：

```powershell
dart run tool/check_update_server.dart https://xingchenwa.github.io/qqm_project EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=
```

## 测试隔离

```powershell
flutter test --no-pub
./tool/test_windows_updater.ps1
./tool/run_update_smoke.ps1 -Format both -Iscc './build/tools/inno-6.7.3/ISCC.exe'
```

原生自测编译 `tool/update_smoke.dart`，仅使用内存配置及新的 GUID 测试目录，不启动生产入口、Hive 或 QQ 连接。EXE 自测使用独立测试 AppID，不覆盖正式卸载记录或快捷方式。

自测会覆盖 `build/windows/.../Release` 临时构建结果，因此之后必须重新运行生产构建助手，不可直接分发自测目录。不要在真实机器人目录演练替换、卸载或回滚。
