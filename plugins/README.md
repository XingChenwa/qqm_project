# 插件目录

`plugins/` 现在是独立本地 Dart 包 `qqm_plugins`，不再只有占位清单。

- `index.json`：应用随包加载的内置清单索引。
- `example_plugin/`、`weather_plugin/`、`dice_plugin/`、`translate_comment/`：内置 JSON 清单。`plugin.dart` 为兼容导出，`plugin.yaml` 为旧清单参考，实际运行读取 `plugin.json`。
- `lib/sdk.dart`、`lib/src/`：公共 Dart SDK 和消息、配置模型。
- `lib/built_in_registry.dart`：随应用编译的 Dart 工厂注册入口。
- `lib/<插件 ID>/`：四个现有插件的真实实现；天气服务也在天气插件目录内。
- `examples/`：可直接导入的 JSON/YAML/HTTP 清单与可运行 Python HTTP 服务。
- `lib/examples/developer_echo_plugin.dart`：可编译的 Dart SDK 扩展示例，不默认注册。
- `schema/plugin.schema.json`：导入插件的 v1 JSON Schema。

第三方 JSON/YAML 请从应用的「插件 → 导入」安装。已安装的定义与配置保存到应用自己的本机存储，支持重启恢复；仅复制一个文件进源码目录不会自动执行。手机也使用同一套导入流程。

详见 [中文插件开发文档](../docs/plugin-development.md)。
