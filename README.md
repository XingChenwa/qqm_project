<div align="center">

# QQ机器人管理器

基于 QQ 官方开放平台的跨平台中文机器人管理工具。<br>
在一个应用里管理会话、编辑 Markdown、运行插件，把想法变成机器人的新玩法。

[项目首页](https://xingchenwa.github.io/qqm_project/) · [下载客户端](https://github.com/XingChenwa/qqm_project/releases) · [插件开发](docs/plugin-development.md) · [反馈问题](https://github.com/XingChenwa/qqm_project/issues)

**Windows · macOS · Android · iOS**

如果喜欢这个项目，欢迎点个 **Star** ✦

</div>

## 它能做什么

- **会话管理**：收发单聊、群聊及平台已授权的消息事件；展示昵称、头像、引用和嵌套消息，支持图片预览、QQ 表情。
- **消息编辑**：文字、Markdown、媒体及平台允许的消息配置。Markdown 有独立编辑和预览区；桌面端 Enter 发送、Ctrl + Enter 换行，输入法选词不会误发。
- **不打断阅读**：收到消息保持当前位置，显示新消息入口；主动发送成功、切换会话或重新进入聊天时定位到最新。
- **插件工作台**：JSON / YAML 规则、HTTP 服务和内置 Dart SDK。带文件管理器、源码编辑、校验、规则试运行、导入导出及可恢复历史。
- **日常工具**：应用内浏览器默认手机版，日志一键复制或导出 TXT / LOG，中文弹窗提示与更新对话框。
- **桌面体验**：自定义标题栏、窗口拖拽、最小化 / 最大化，以及可选的关闭到托盘。
- **GitHub 更新**：同仓库 Releases 分发，Ed25519 签名清单与 SHA-256 包校验；不依赖自建 PHP、MySQL 或下载后台。

这里使用的是 **QQ 官方机器人接口**，不是个人 QQ 协议客户端。功能是否可用取决于机器人已获得的平台权限、消息场景及接口限制，程序不能绕过平台审核。

## 安装与开始使用

前往 [项目首页](https://xingchenwa.github.io/qqm_project/) 或 [Releases](https://github.com/XingChenwa/qqm_project/releases) 获取安装包。首页只展示完整签名版本；源码更新、Actions 测试包不等于已经发布正式安装包。

| 平台 | 安装方式 | 说明 |
| --- | --- | --- |
| Windows x64 | 运行 EXE 安装向导 | 更新下载校验后打开安装程序；内置网页需要 WebView2 |
| macOS Universal | 打开 DMG，拖入 Applications | Apple Silicon / Intel；当前构建未做 Developer ID 签名与公证，请核验来源后按系统提示处理 |
| Android | 下载 APK，按系统提示授权安装 | 正式包沿用固定签名；不一致的签名不能直接覆盖安装 |
| iOS arm64 | 下载未签名 IPA，自行签名安装 | 可导入全能签，需自备有效证书；不是免签包或 App Store 版本 |

1. 在 [QQ 开放平台](https://q.qq.com/) 准备你自己的机器人应用和对应权限。
2. 启动客户端，在设置中填写应用凭据并连接。不要把 ClientSecret 或 Token 发到 Issue、截图或聊天中。
3. 进入插件中心，填写需要的服务 Key，检查配置后启用插件，发送 `/帮助` 查看可用命令。

手机进入后台后，系统可能暂停应用和机器人连接；本项目不是全天在线的云托管服务。群内免 @ 需要平台已开通“接收所有消息”，不能只靠客户端设置实现。Markdown、键盘、部分群资料同样受平台授权限制。

## 内置插件

| 插件 | 可以试试 | 配置要求 |
| --- | --- | --- |
| 基础助手 | `/帮助`、`/ping`、`/时间`、`/复读 文本` | 无外部服务 Key |
| 天气与 IP | `天气 北京`、`天气预报 上海`、`城市编码 北京`、`/ip 114.114.114.114` | 高德 Web 服务 Key |
| 随机游乐场 | `/骰子 2d6+3`、`/硬币 3`、`/选择 茶 \| 咖啡`、`/转盘 A \| B`、`/猜拳 石头` | 无外部服务 Key |
| 翻译助手 | `/翻译 文本`、`/注释翻译` 后接带语言名的代码块 | DeepSeek Key；显式命令才联网，可能产生费用 |
| 每日小会馆 | `/签到`、`/积分`、`/排行`、`/今日运势`、`/抽签` | 本地会话数据 |
| 群互动 | `/猜数字 开始`、`/投票 创建 标题 \| A \| B`、`/投票 结果` | 按钮可选，默认使用文本命令 |

积分、抽签和运势仅供娱乐，没有现金价值。天气/IP 插件查询的是指定地址，不是获取 QQ 用户 IP。更多命令、边界和权限见 [插件开发指南](docs/plugin-development.md)。

## 写自己的插件

- **JSON / YAML 规则**：无需重新编译，适合命令、固定回复、Markdown、媒体和按钮。
- **HTTP 插件**：复杂玩法用自己的 Node.js、Python、Go 等服务实现，客户端调用经过授权的地址。
- **内置 Dart SDK**：需要深度集成时，审核后随客户端一起编译。

最小可用清单：

```json
{
  "schema_version": 2,
  "id": "my_hello",
  "name": "我的问候",
  "version": "1.0.0",
  "runtime": "rules",
  "permissions": ["message:read", "message:send"],
  "rules": [
    {
      "match": {"type": "command", "value": "myhello"},
      "message": {"format": "text", "content": "你好，{{sender_name}}！"}
    }
  ]
}
```

在“插件 → 写插件”中导入、校验并安装，确认权限后启用，发送 `/myhello`。文件管理器能编辑脚本，不代表客户端会执行它；应用不 eval JS、不运行 Shell，也不自动启动 HTTP 服务。

[完整协议与教程](docs/plugin-development.md) · [示例目录](plugins/examples/) · [Dart SDK](plugins/README.md)

## 数据与第三方服务

- 机器人凭据和会话保存在本地，请保护配置与备份。日志或报错截图请先脱敏。
- 缺少单聊昵称时，默认向第三方 OIAPI 提交 AppID 和 OpenID 查询；不提交机器人密钥、Token 或聊天正文。
- 天气、翻译、表情资源和你安装的 HTTP 插件可能访问相应服务；使用前检查其权限、费用和服务规则。翻译会提交明确请求翻译的内容。
- QQ 表情资源引用 QFace 索引，其资源权利归原权利人；分发或商用前请自行确认许可。

旧版 `management/` 和部署资料仅为迁移兼容保留，不属于现在 GitHub 托管方案的必要组件，也不会自动删除你曾部署的数据库。

## 一起完善

发现问题请到 [Issues](https://github.com/XingChenwa/qqm_project/issues) 提供软件版本、系统、复现步骤及脱敏日志。欢迎贡献修复、文档和插件示例；涉及 QQ 接口的改动请附官方文档依据和测试，勿提交任何凭据。

学习为目的编写的，非腾讯官方产品。请遵守平台规则与相关服务条款。

作者 QQ：**2377130783**<br>
问题建议可以反馈。如果这个工具对你有帮助，欢迎给项目点个 **Star**！
