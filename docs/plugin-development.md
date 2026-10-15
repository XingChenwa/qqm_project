# 插件开发指南（SDK / 清单协议 v1）

现有插件的真实源码和清单均在根目录 `plugins/`。主程序负责 QQ 连接、被动回复序号、Markdown 发送和持久化；插件返回回复正文即可，不需要机器人密钥。

支持三种扩展方式：JSON/YAML 规则插件可直接导入，HTTP 插件把消息发给你自己编写的服务，Dart 插件则需要随应用重新编译。插件不是操作系统沙箱，Dart 源码需要应用维护者审核。

## 1. 选择扩展方式

| 方式 | 适合 | 是否重新编译 |
| --- | --- | --- |
| `rules` JSON/YAML | 命令、关键词、固定回复、配置变量 | 不需要 |
| `http` JSON/YAML + 自有服务 | Python、Node.js、Go 等实现的复杂逻辑 | 不需要重编译客户端，服务自行部署 |
| Dart SDK | 深度逻辑、原生代码集成 | 需要，Dart 工厂随应用编译 |

规则引擎不执行 JavaScript、Python、shell 或任意 Dart 文件。Flutter 移动端正式应用采用预编译代码，不能把粘贴的 `.dart` 当热加载脚本。[Flutter 架构说明](https://docs.flutter.dev/resources/architectural-overview)

## 2. 两分钟跑通 JSON 插件

保存为 UTF-8 编码的 `plugin.json`：

```json
{
  "schema_version": 1,
  "id": "my_hello",
  "name": "我的问候插件",
  "version": "1.0.0",
  "description": "发送 /myhello 时回复问候。",
  "author": "你的名字",
  "runtime": "rules",
  "permissions": ["message:read", "message:send"],
  "rules": [
    {
      "match": {"type": "command", "value": "myhello"},
      "reply": "你好，{{sender_name}}！你输入了：{{args}}"
    }
  ]
}
```

1. 打开「插件 → 导入」，选择文件或粘贴清单，点击「检查清单」。
2. 阅读名称、权限和 HTTP 服务地址（若有），勾选授权后确认导入。
3. 新安装及替换的插件均默认停用；检查「配置」后手动启用。
4. 单聊发送 `/myhello 测试`，或群聊 **@ 机器人** 后发送该命令。

仅安装、复制清单和查看示例不会向 QQ 或插件服务发送消息。应用内「开发者文档与示例」提供 JSON、YAML 和 HTTP 三个可直接加载到导入窗口的示例。配置会持久化；第三方插件支持卸载，卸载只删除应用内定义和配置，不删除原始文件。内置 Dart 插件属于应用包，只能停用。

群聊保持此前的窄范围策略：未 @ 的全量消息默认只交给天气/IP 插件，第三方插件不会因此自动处理普通群聊。只有 QQ 平台已开通接收所有消息、本地接收开启，并由操作者另行开启广泛的“普通群消息也触发插件和自动回复”开关时，其他插件才可能收到未 @ 消息。不要为了测试插件无意扩大群消息处理范围。

## 3. 清单字段

JSON 与 YAML 完全同构。可使用 [JSON Schema](../plugins/schema/plugin.schema.json) 做编辑器提示与校验；内置 Dart 清单的 `runtime: builtin` 不适用于直接导入。

| 字段 | 说明 |
| --- | --- |
| `schema_version` | 必须是整数 `1` |
| `id` | 3–64 位小写字母、数字、下划线，必须以字母开头；不能占用内置 ID |
| `name` / `version` / `description` | 必填非空文本；名称与版本最多 80 字符，描述最多 1000 字符 |
| `author` | 可选作者文本 |
| `runtime` | 可导入值仅 `rules`、`http` |
| `permissions` | 规则插件声明 `message:read`、`message:send`；HTTP 另声明 `network:http` |
| `config_schema` | 最多 32 个配置项，用于自动生成界面表单 |
| `config` | 配置默认值；每个键必须在 `config_schema` 中声明 |
| `rules` | 1–64 条触发规则；从上到下只执行第一条命中的规则 |
| `http` | HTTP 插件的地址、超时和授权设置 |

不支持的权限、未知字段、无效类型及过大的清单会被拒绝。清单最大 256 KB；不支持任意正则表达式、动态代码、系统命令、定时任务或从清单导入本地路径。

### 触发规则

```json
{
  "match": {
    "type": "exact",
    "value": "打招呼",
    "scope": "group",
    "case_sensitive": false
  },
  "reply": "欢迎，{{sender_name}}！"
}
```

- `command`：匹配斜杠命令，如 `value: "hello"` 对应 `/hello 参数`。值不要带 `/` 或空格，命令名不区分大小写。
- `exact`：消息去除首尾空白后完整相等。
- `prefix`：消息以指定文本开头；`{{args}}` 为去掉前缀后的剩余文本。
- `contains`：消息包含指定文本；`{{args}}` 为完整消息。
- `scope`：`all`（默认）、`group` 或 `private`；只过滤宿主已交给插件的事件，不会扩大平台接收权限。
- `case_sensitive`：默认 `false`；作用于普通文本匹配。

规则插件的 `reply` 必填，最大 16000 字符。HTTP 插件只使用 `match`，服务响应决定回复；清单中的 `reply` 不参与 HTTP 执行。多个插件都命中时可各自回复，实际发送仍受 QQ 额度和被动回复限制。

### 回复变量

可使用 `{{content}}`、`{{args}}`、`{{sender_name}}`、`{{sender_id}}`、`{{session_id}}`、`{{now}}` 及 `{{config.配置键}}`。`now` 是运行程序所在地的本地时间。`exact` 的 `args` 为空。

变量只作一次纯文本替换，不递归解释表达式。未知变量为空；`secret` 配置不会注入回复模板。普通命令参数会规范化空白，Markdown 代码块保留多行内容；需要精确原文时使用 `content`。宿主根据正文自动识别文本/Markdown，沿用代码块补发和错误处理。平台仍可能限制 Markdown 权限或语法；插件返回正文不代表 QQ 一定接受。v1 不支持直接返回任意 QQ 请求体、键盘或富媒体对象。

### 配置表单

```json
{
  "config": {"salutation": "你好", "service_token": ""},
  "config_schema": [
    {"key": "salutation", "label": "问候语", "type": "string", "default": "你好", "required": true},
    {"key": "service_token", "label": "服务令牌", "type": "secret", "default": "", "required": true}
  ]
}
```

配置类型：`string`、`secret`、`boolean`、`integer`。`key` 为字母开头的 1–64 位字母、数字、下划线，标签为 1–80 字符。字符串最大 8192 字符。`required` 用于启用时检查非空文本；布尔值和整数按类型验证。未填默认值时分别采用空字符串、`false`、`0`。实际值只在操作者的应用内填写，不要把真实密钥写进可分享清单。

## 4. HTTP 插件协议

示例清单在 `plugins/examples/http_echo/plugin.json`，服务实现位于同目录 `server.py`，只使用 Python 标准库。

```json
{
  "http": {
    "url": "https://your-domain.example/qqbot",
    "timeout_ms": 8000,
    "token_config": "service_token",
    "send_config_keys": ["language"]
  }
}
```

- 地址固定为清单里的 `url`。生产及手机端使用 HTTPS；仅允许 `localhost`、`127.0.0.1`、`::1` 的 HTTP 作为本机调试地址。
- 不允许 URL 用户名/密码、查询参数、片段，不跟随 3xx 重定向。更换服务地址必须修改清单并重新导入、授权、启用。
- `timeout_ms` 为 1000–20000 毫秒，默认 8000；超时后关闭 HTTP 客户端，不重试。
- `token_config` 可省略，若填写须指向 `secret` 配置项；非空令牌作为 `Authorization: Bearer ...` 发送，只用于插件服务，不是机器人凭据。令牌使用可见 ASCII 字符，不含空白或换行。
- `send_config_keys` 默认空数组，只能指定已声明的非密钥配置。不会发送全部配置。
- 只有命中规则的消息会请求服务；输入输出正文均限 64 KB，回复文本限 16000 字符。错误信息只显示中文原因或状态码，不显示服务原始响应、URL 或令牌。

宿主向固定地址发送 `POST`，Content-Type 为 `application/json`：

```json
{
  "schema_version": 1,
  "plugin_id": "custom_http_echo",
  "event": "command",
  "command": "echo",
  "args": ["你好"],
  "text": "你好",
  "message": {
    "message_id": "来源消息 ID",
    "session_id": "群或用户 OpenID",
    "sender_id": "发送者 OpenID",
    "sender_name": "小明",
    "content": "/echo 你好",
    "message_type": 0,
    "is_group": true,
    "timestamp": "2026-10-15T00:00:00.000Z"
  },
  "config": {"language": "中文"}
}
```

普通文本事件的 `event` 为 `message`，`command` 为 `null`，`args` 为空数组。操作者在聊天框手动执行命令时，来源消息 ID、发送者 ID 可能为空，发送者名称为“操作员”；群聊标记和会话 ID 仍保留。`message.content` 是原始消息文本；`text` 是当前匹配规则提取的参数。

成功时必须返回 HTTP 200 和 JSON：

```json
{"reply": "这是回复正文，也可以包含 Markdown 代码块。"}
```

不需要回复时返回 `{"reply": null}`。不要返回 QQ access_token、目标会话覆盖字段或任意消息 API 请求体。响应只能回复来源会话；宿主负责有效回复上下文、消息序号和实际发送。停用或卸载期间完成的旧请求不会再产生 QQ 回复。

### 本机运行 Python 示例

Windows PowerShell：

```powershell
$env:QQM_PLUGIN_TOKEN = 'local-demo-token-change-me'
python plugins/examples/http_echo/server.py
```

macOS/Linux：

```bash
QQM_PLUGIN_TOKEN='local-demo-token-change-me' python3 plugins/examples/http_echo/server.py
```

导入 HTTP 示例，在配置中填写同一令牌，启用后发送 `/echo 测试`。示例只监听本机 `127.0.0.1:8787`，不会自动启动服务器、上传代码或修改防火墙。

手机上的 `127.0.0.1` 指手机本身，不是电脑。要在手机使用服务，开发者自行部署带有效 TLS 证书、授权校验和请求限流的 HTTPS 地址后修改清单；应用不会为此关闭 Android/iOS 的明文网络保护。不要直接把示例开发服务器暴露到公网。

## 5. Dart SDK 扩展

独立包名称为 `qqm_plugins`，源码在 `plugins/lib/`；宿主的 `lib/plugin_sdk.dart` 与旧模型导入路径保留兼容导出。可编译示例在 `plugins/lib/examples/developer_echo_plugin.dart`。

```dart
import 'package:qqm_plugins/sdk.dart';

class MyPlugin extends BotPlugin {
  MyPlugin(super.info);
  @override
  Future<void> onEnable() async {}
  @override
  Future<void> onDisable() async {}
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async {
    if (command != 'myplugin') return null;
    return '参数：${args.join(' ')}';
  }
}
```

接入步骤：

1. 把实现放到 `plugins/lib/<你的 ID>/plugin.dart`，导入 `package:qqm_plugins/sdk.dart`。
2. 在 `plugins/<你的 ID>/plugin.json` 添加 `runtime: "builtin"`、元数据、权限、配置项及 `entrypoint: "lib/<你的 ID>/plugin.dart"`。可参考现有四个内置清单。
3. 在 `plugins/lib/built_in_registry.dart` 导入类并注册 `'<你的 ID>': MyPlugin.new`。
4. 在 `plugins/index.json` 添加清单路径，并在根 `pubspec.yaml` 的 assets 中显式添加该 JSON 路径。
5. 执行 `flutter pub get`、`flutter analyze`、`flutter test` 并重新构建对应平台。

公开生命周期：`onEnable()`、`onDisable()`；事件入口 `handleMessage(PluginMessage)` 默认解析斜杠命令并调用 `onCommand`，普通消息调用 `onMessage`。需要完整命令上下文可自行重写 `handleMessage`。返回 `null` 表示不处理；默认执行超时为 10 秒，可重写 `executionTimeout`。`updateConfig` 运行时更新配置。`onTick()` 是保留接口，当前没有自动定时调度，不要假设它会每隔几秒调用。

`PluginMessage` 包含消息、会话、发送者、正文、类型、群聊标记和时间，`toMap()` 输出上述 HTTP 协议格式；不含机器人密钥或原始鉴权令牌。Dart 插件是受信任的应用代码，声明权限不等于 OS 沙箱；必须审核源码和依赖。增加原生 Flutter 插件、特殊权限或后台能力还需应用维护者接入相应平台工程。

## 6. 迁移、分发和安全

- 现有四个 ID 和配置保持不变：`example_plugin`、`weather_plugin`、`dice_plugin`、`translate_comment`。天气 Key、翻译 Key、默认城市和启用状态按原 ID 恢复。
- 实际逻辑在 `plugins/lib/`；原 `lib/core/plugins/*` 仅作兼容导出。`plugins/*/plugin.json` 为清单唯一运行来源，旧 `plugin.yaml` 仅作迁移参考。
- 第三方最多安装 32 个。替换同 ID 插件必须明确确认，保留类型兼容的配置并重新停用；类型冲突会拒绝替换。不能覆盖内置 ID。
- 分享时使用「查看和复制插件清单」：不带本机配置，且清空清单中的 secret 默认值。整套应用配置备份仍包含实际密钥与插件启用状态，请只信任自己的备份，不要随意导入陌生配置备份。
- HTTP 插件可见命中消息正文、昵称与 OpenID，安装页会显示权限和固定服务地址。开发者应告知用途、控制日志和数据保留，不要收集无关信息。
- 插件名称和作者是自述信息，不是平台认证；只安装可信来源的清单，密钥只填入本机配置。宿主不把 AppID、ClientSecret、QQ access_token 或历史会话传给 HTTP 插件。
- 规则匹配在宿主既有群聊/单聊策略内执行；机器人自己的消息、重复事件、撤回内容及回复时效限制沿用宿主校验。手机后台和锁屏仍可能断线，插件不能替代服务器常驻。

开发验证入口：`test/external_plugins_test.dart` 覆盖清单导入、运行、保存恢复、协议、安全限制和卸载中迟到请求；UI 测试覆盖手机与桌面导航、导入确认和配置。
