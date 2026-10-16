# 插件目录

`plugins/` 现在是独立本地 Dart 包 `qqm_plugins`，不再只有占位清单。

- `index.json`：应用随包加载的内置清单索引。
- `example_plugin/`、`weather_plugin/`、`dice_plugin/`、`translate_comment/`：内置 JSON 清单。`plugin.dart` 为兼容导出，`plugin.yaml` 为旧清单参考，实际运行读取 `plugin.json`。
- `lib/sdk.dart`、`lib/src/`：公共 Dart SDK 和消息、配置模型。
- `lib/built_in_registry.dart`：随应用编译的 Dart 工厂注册入口。
- `lib/<插件 ID>/`：六个内置插件的真实实现；增加每日会馆、群游戏，原四个保留 ID 并扩展。
- `examples/`：JSON/YAML、Markdown 按钮/媒体清单及可运行的 Node.js/Python HTTP 服务。
- `lib/examples/developer_echo_plugin.dart`：可编译的 Dart SDK 扩展示例，不默认注册。
- `schema/plugin.schema.json`：v2 JSON Schema，兼容 v1 文本规则。

应用内「写插件」提供插件专用文件管理器、未保存保护、本地历史、导入导出与规则试运行。Dart/JS/Python 文件仅可编辑，不会在客户端动态执行；复杂逻辑通过 HTTP 接入，Dart 插件仍需编译。

第三方 JSON/YAML 请从应用的「插件 → 导入」安装。已安装的定义与配置保存到应用自己的本机存储，支持重启恢复；仅复制一个文件进源码目录不会自动执行。手机也使用同一套导入流程。

详见 [中文插件开发文档](../docs/plugin-development.md)。
