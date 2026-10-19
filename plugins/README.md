# 插件项目与 SDK

七个随附插件的完整可运行逻辑在各自目录的 `main.ht`。随附与第三方使用同一个脚本加载器，没有按插件 ID 调用固定应用功能；可以编辑、替换或复制开发新项目，无需重新编译客户端。

- `<插件ID>/plugin.json`：名称、命令、配置、权限与入口。
- `<插件ID>/main.ht`：独立 Hetu 脚本，包含完整命令与玩法实现。
- `examples/hello_script/plugin.json`：可直接导入的完整脚本示例（源码内嵌）。
- `examples/`：JSON/YAML 规则、Markdown/按钮/媒体，以及 Node.js/Python HTTP 服务示例。
- `schema/plugin.schema.json`：编辑器自动提示与格式校验。
- `lib/src/`：宿主共用的消息、回复和状态存储模型。
- `lib/translate_comment/comment_spans.dart`：公开 SDK 的纯文本注释解析工具。
- `lib/<插件ID>/` 与旧 `plugin.dart/yaml`：此前 Dart 实现的兼容参考与回归测试，不是当前客户端加载入口；开发新插件请使用 `main.ht`、规则或 HTTP 示例。

在「插件 → 写插件」中新建脚本项目；保存后应用到插件中心，检查配置并启用。插件中心的七个随附插件同样提供编辑入口。保存本地历史、保护未保存草稿，应用更新不会覆盖用户明确安装的自定义版本。

完整项目分享：在插件中心导出清单（包含 `script.source`），对方导入该 JSON/YAML 即可。单独导出的源码文件仍需配套清单。插件全部默认关闭，安装不会执行源码或请求网络；手动启用后才运行。已保存的启停选择继续保留。

详见 [中文插件开发文档](../docs/plugin-development.md)。
