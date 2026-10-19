# 插件开发指南：SDK / 清单协议 v2

这套插件系统让开发者在四端共享命令与玩法。宿主负责 QQ 连接、凭据、回复上下文、序号和发送；插件只返回结果。可使用 JSON/YAML 规则、HTTP 服务或随应用编译的 Dart SDK 开发插件。

内置七个插件，覆盖基础助手、天气与 IP、随机游乐场、翻译、每日小会馆、群互动和主动消息权限。新安装的插件默认关闭，需在插件中心手动启用；已经手动保存的启停选择会保留。需要固定回复时，也可以编写可独立启停的规则插件。

## 1. 先选运行方式

| 方式 | 用途 | 执行位置 |
| --- | --- | --- |
| `rules` JSON / YAML | 命令、关键词、Markdown、按钮、固定媒体 | 应用内直接安装，无需编译 |
| `http` 清单 + 自有服务 | Node.js / Python / Go 等复杂玩法 | 开发者的服务；应用只调用已授权地址 |
| `builtin` Dart SDK | 深度逻辑、原生集成、离线玩法 | 源码审核后随应用重新编译 |

文件管理器可以编辑 `.json/.yaml/.yml/.md/.txt/.js/.mjs/.py/.dart`。**能编辑不等于能执行**：应用不 eval 脚本、不运行 shell、不自动启动服务，也不内置 Node/Redis。手机上的本地 HTTP 地址指手机自己，不是电脑。

## 2. 两分钟安装第一个插件

进入「插件 → 写插件 → 新建插件项目」，填写唯一 ID，生成 `plugin.json`。也可将下列 UTF-8 清单粘贴到「导入」：

```json
{
  "schema_version": 2,
  "id": "my_hello",
  "name": "我的问候",
  "version": "1.0.0",
  "description": "问候命令示例",
  "runtime": "rules",
  "permissions": ["message:read", "message:send"],
  "rules": [
    {
      "match": {"type": "command", "value": "myhello"},
      "message": {"format": "text", "content": "你好，{{sender_name}}！参数：{{args}}"}
    }
  ]
}
```

1. 校验或本地试运行；预览不会调用 HTTP 或发送 QQ。
2. 点击「安装到插件中心」，检查权限；替换现有 ID 还要确认替换。
3. 安装和替换后均停用，检查配置后再启用。
4. 发送 `/myhello 测试` 或 `#myhello 测试`。

已有 v1 清单继续可用。v2 推荐显式 `message.format`，避免正文里的 Markdown 符号被误判。不要占用内置 ID。

## 3. 内置玩法命令

| 插件 / ID | 命令与行为 | 配置 / 数据 |
| --- | --- | --- |
| 基础助手 `example_plugin` | `/帮助`、`/help`、`/菜单` 动态菜单；`/ping`；`/时间`；`/复读 文本` | 复读最多 1000 字，不包含式触发普通聊天 |
| 天气与 IP `weather_plugin` | `天气 北京`、`查询天气 上海`、`/weather 110105`；`天气预报 北京`、`/forecast 北京`；`城市编码 北京`；`查ip地址 114.114.114.114`、`/ip IPv4` | 高德 Web 服务 Key、默认城市；同名地区需用编码确认；不查询 QQ 用户 IP |
| 随机游乐场 `dice_plugin` | `/骰子 2d6+3`、`/roll 1d20`、裸 `2d6`；`/硬币 3`；`/选择 火锅 \| 烧烤`；`/转盘 A \| B`；`/打乱 小明 \| 小红`；`/随机数 1 100`；`/猜拳 石头` | 数量 1–100、面数 2–1000；选择 2–20 项；不是博彩或密码生成器 |
| 翻译 `translate_comment` | `/注释翻译`、`/translate`、`/fanyi` 后接带语言名的代码块；`/翻译 文本` | DeepSeek Key、目标语言、模型名；仅明确命令会联网，可能产生费用 |
| 每日小会馆 `daily_club` | `/签到`、`/积分`、`/排行`、`/今日运势`、`/抽签` | 每日积分 1–100；北京时间按日签到，重复签到不加分，排行榜前十，单会话最多 1000 人 |
| 群互动 `group_games` | `/猜数字 开始`、`/猜数字 50`、`/猜数字 结束`；`/投票 创建 标题 \| A \| B`、`/投票 选择 1`、`/投票 结果`、`/投票 结束` | 猜数字 15 分钟 / 50 次；投票 24 小时、2–6 项、1000 人；发起人或官方角色为群主/管理员可结束 |

投票每人一票，可改票；旧投票按钮不能作用于新投票。按钮默认关闭，机器人拥有 Markdown/键盘权限后可在群互动配置启用；不开按钮也能用文本命令完整操作。积分是本地娱乐数据，无现金价值。运势与抽签仅供娱乐，不用于现实决策。

翻译最多 12000 字、4 个代码块、120 段注释；请求 35 秒、响应 128 KB 上限。代码模式仅提交识别出的注释列表，再按原位置替换，不让模型重写整个代码。支持常见 Python、C/C++、Java、Dart、Go、C#、Rust 与基础 JS/TS；复杂原始字符串、JS 正则/模板等保守拒绝。字符串、Python 文档字符串不翻译。结果仍应人工审核，注释可能影响工具或编译配置；不保证语义级解析所有语言。普通文本翻译会把命令参数发给 DeepSeek。

### 主动消息权限插件

在「插件 → 主动消息权限 → 配置」填写机器人资料 JSON，手动启用插件。按 **AppID** 分别配置，切换机器人不会取用另一 AppID 的资料：

```json
{
  "当前机器人的AppID": {
    "bot_qq": "987654321",
    "bot_uid": "u_替换为机器人的实际UID"
  }
}
```

这是格式示例，请替换真实机器人资料；AppID 不是机器人 QQ 号，机器人 UID 也不是群 OpenID。

1. 群内 **@机器人 /主动消息**，收到「填写群号(群主)」指令按钮。
2. 群主点击按钮，在预填的 `/主动消息 ` 后补上本群真实群号发送，例如 `/主动消息 123456789`。也可直接发送完整命令，不需要预先在插件里配置群号。
3. 本次 QQ 事件的 `author.member_role` 必须为 `owner`；普通成员、管理员、未知角色均不能生成授权链接。填写按钮本身只是指令入口，不是授权操作；未知群主时其他人也能打开该输入入口，但提交后仍会严格校验身份。
4. 返回 Markdown **主动权限(群主使用)** 跳转按钮，使用指定用户权限 `permission.type=0`，仅允许本次群主 OpenID 点击。
5. 群主在 QQ 页面核对群号并完成授权。每次命令使用当前消息所在群、机器人 AppID 和发送者，不保存跨群或跨机器人的待填写状态。

不能将群 OpenID 或普通文字作为群号。链接仅在点击时打开你指定的 QQ 页面，不代替授权、不预先访问链接、不将这些资料上传第三方。是否支持开通、真实群号与群主关系、最终身份校验及授权结果由 QQ 决定；输入数字不表示客户端已验证群号归属。机器人仍需平台 Markdown 和自定义键盘权限；按钮发出不表示已经获得主动发送能力。[官方按钮说明](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/trans/msg-btn.html)

## 4. 群消息、优先级与权限

群内免 @ 的前提是 QQ 平台已开通「接收所有消息」，且应用允许接收全量群消息；代码不能绕过平台权限。[全量群事件文档](https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/group_message_create.html)

- 全量群事件中，内置插件只响应明确 `/`、`#` 命令；天气/IP 的明确自然指令、骰子表达式也可触发。普通聊天不兜底回复。
- 第三方 `command` 规则可免 @；`exact/prefix/contains` 默认仅处理单聊或 @ 消息。需要普通全量消息时同时声明 `"listen_all":true` 和权限 `events:group-all`，安装时由操作者确认。
- 插件按 `priority` 从小到大运行，范围 0–1000，默认 100；同优先级按加载顺序。首个返回有效回复的插件结束本轮，避免多个插件消耗被动回复额度。
- `cooldown_ms`：0–60000，默认 0，同插件、会话、发送者的回复冷却；每插件最多 4 个并发任务。
- `permission` 放在规则上：`all`（默认）、`admin`、`owner`。依据平台 `author.member_role`；未知角色拒绝，不把昵称/OpenID 自述当权限。管理器本机手动命令标记为 `operator`；签到与群游戏拒绝没有真实发送者的手动身份。

支持 `match.type`：`command`、`exact`、`prefix`、`contains`、`callback`。`scope` 为 `all/group/private`，`case_sensitive` 作用于普通文本；命令名不区分大小写。`command.value` 不带 `/`、`#` 或空白。`callback.value` 是命名空间后的动作名，例如 `qqm:my_buttons:hello:参数` 对应 `hello`。

模板变量：`{{content}}`、`{{args}}`、`{{sender_name}}`、`{{sender_id}}`、`{{session_id}}`、`{{sender_role}}`、`{{now}}`、`{{config.键}}`。`now` 为北京时间；未知变量为空，secret 不插值，只替换一次。命令参数规范化空白，但多行代码块保留。需要原文用 `content`。富文本模板中的用户参数不会自动转义，开发者应使用纯文本或在 HTTP 服务转义。

### @ 群成员

文本或 Markdown 正文使用 `<qqbot-at-user id="成员OpenID" />`，不要继续使用将弃用的 `<@userid>`。群聊不支持 @ 全体；`<qqbot-at-everyone />` 仅文字子频道可用，本客户端不会在 QQ 群提供该入口。[官方文本交互说明](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/trans/text-chain.html)

例如规则回复 `{"format":"text","content":"<qqbot-at-user id=\"{{sender_id}}\" /> 收到你的指令了。"}`，配合 `"scope":"group"` 即可 @ 触发命令的成员。完整示例见 [群成员 @ 插件](../plugins/examples/group_mentions/plugin.json)。成员 OpenID 必须来自**当前 AppID**，不能用 QQ 号或另一机器人的 OpenID；HTTP 服务也应校验返回的 ID，不能将用户输入直接拼成标签。

切换机器人后，会话、头像／昵称缓存、回复序号和玩法数据按 AppID 隔离。尚未完成的旧机器人插件结果不会发到新机器人；Dart 插件内 `host.store` 固定使用本次执行开始时的 AppID，不会因异步等待后切换而写错归属。

## 5. 清单与结构化回复

[JSON Schema](../plugins/schema/plugin.schema.json) 提供编辑器提示；应用还会交叉检查权限、配置、URL 和域名。清单不执行代码。最大 256 KB、16 层、10000 节点，最多 64 条规则、32 个配置项、32 个第三方插件；未知字段直接拒绝。

必填字段：`schema_version`（1 或 2）、`id`、`name`、`version`、`description`、`runtime`、`permissions`、`rules`。ID 3–64 位小写字母、数字、下划线，以字母开头。名称/版本最多 80 字，描述最多 1000 字。`author` 可选。每条规则使用 `reply` 或 `message`，不能同时使用；HTTP 规则可以都省略，由服务决定结果。

```json
{
  "match": {"type": "command", "value": "菜单", "scope": "group"},
  "permission": "all",
  "message": {
    "format": "markdown",
    "content": "# 插件菜单\n选择一个操作：",
    "buttons": [[
      {"label": "查看积分", "data": "/积分"},
      {"label": "打招呼", "data": "qqm:my_buttons:hello", "callback": true}
    ]]
  }
}
```

`format` 为 `text/markdown/media`。正文最多 16000 字符；文本/Markdown 必须非空。按钮只用于 Markdown，最多 5 行、每行 5 个；文字 1–10 字、data 最多 512 字符。普通按钮填命令；跳转按钮额外设置 `\"url\":true`，data 必须是无凭据 HTTPS URL；可选 `user_ids:[\"当前AppID的用户OpenID\"]` 限定点击用户（不填则不限用户）。回调按钮须声明 `interaction:read`，data 必须以 `qqm:<本插件ID>:` 开头，再写一条 `callback` 规则处理。群按钮不设置仅 C2C 支持的自动发送参数。

媒体格式例：`{"format":"media","content":"图片说明","media_url":"https://cdn.example.com/pic.png","media_type":1}`。需声明 `message:media` 和 `media_hosts:["cdn.example.com"]`，类型 1 图片 / 2 视频 / 3 语音 / 4 文件。URL 仅 HTTPS、无凭据和片段；域名严格匹配，不允许通过模板换到其他主机。QQ 服务器还需能够访问该媒体。不是本地任意文件上传接口。

权限基础为 `message:read`、`message:send`；HTTP 增加 `network:http`。可选 `message:media`、`interaction:read`、`events:group-all`。`network:amap/deepseek` 仅可信内置插件使用；清单不是原生代码的 OS 沙箱。

配置项由 `config_schema` 定义，类型 `string/multiline/secret/boolean/integer`（`multiline` 使用多行文本编辑器），支持 `key/label/type/default/required`。key 字母开头，最多 64 字符；字符串最多 8192 字符。`config` 仅存声明过的默认值。分享清单会清除 secret 默认值，不带本机密钥；不要把密钥写进规则正文或普通配置。

## 6. 用 JavaScript / Python 编写 HTTP 插件

完整示例：

- [JSON 问候](../plugins/examples/hello_json/plugin.json)、[YAML 问候](../plugins/examples/hello_yaml/plugin.yaml)
- [Markdown 按钮与回调](../plugins/examples/buttons/plugin.json)
- [媒体回复](../plugins/examples/media/plugin.json)
- [HTTP 清单](../plugins/examples/http_echo/plugin.json)、[Python 服务](../plugins/examples/http_echo/server.py)
- [Node.js 服务](../plugins/examples/http_echo/server.mjs)

HTTP 清单设置 `http.url`、`timeout_ms`（1000–20000，默认 8000）、可选 `token_config` 和 `send_config_keys`。URL 生产环境只允许 HTTPS；HTTP 仅回环本机调试。禁止 URL 凭据、查询和片段，不跟随重定向、不重试。`token_config` 指向 secret，以 Bearer 请求头授权，不进入 JSON；`send_config_keys` 只能选择非 secret 配置。

POST 请求示意（HTTP 封装版本保留 `1`，新增字段为可选）：

```json
{
  "schema_version": 1,
  "plugin_id": "custom_http_echo",
  "event": "command",
  "command": "echo",
  "args": ["你好"],
  "text": "你好",
  "message": {
    "message_id": "来源消息ID",
    "session_id": "群或用户OpenID",
    "sender_id": "发送者OpenID",
    "sender_name": "小明",
    "sender_role": "member",
    "content": "/echo 你好",
    "message_type": 0,
    "is_group": true,
    "is_full_group_message": false,
    "event_type": "message",
    "timestamp": "2026-10-16T00:00:00.000Z"
  },
  "config": {"language": "中文"}
}
```

`event` 为 `message/command/interaction`；回调时 `message.callback_data` 包含命名空间参数，message_id 为交互事件 ID。附件存在时传 `attachments`（URL、文件名、类型、尺寸），服务不要盲目信任或下载任意 URL。**不传机器人密钥、access_token、message_scene 鉴权令牌或历史聊天**。操作者手动执行的 message_id/sender_id 可能为空。

服务返回 HTTP 200：`{"reply":"文本"}`、`{"reply":null}`，或 `{"message":{"format":"markdown","content":"# 你好"}}`。结构化格式同上，权限和媒体域名仍由宿主检查。请求与响应各 64 KB。服务不能指定其他目标会话、传任意 QQ API 请求、修改 msg_seq 或请求机器人 Token。停用/卸载时迟到的结果不会继续发送。

本机试运行（示例令牌仅供本地测试，请自行替换）：

```powershell
$env:QQM_PLUGIN_TOKEN = 'local-demo-token-change-me'
node plugins/examples/http_echo/server.mjs
# 或 python plugins/examples/http_echo/server.py
```

示例监听 `127.0.0.1:8787`；在插件配置填写同一令牌，启用后 `/echo 测试`。服务不会由应用启动。部署公网需自行增加 TLS、访问令牌、限流、幂等、数据备份；不要把开发服务器直接暴露公网。服务收到 OpenID/消息内容，请明确用途、最小化日志和保留时间。Node/Redis 玩法可以写在此服务。

## 7. Dart SDK v2

导入 `package:qqm_plugins/sdk.dart`。原 `onEnable/onDisable/onMessage/onCommand/handleMessage` 接口保持兼容，返回 String 的旧插件继续自动判断 Markdown。新插件推荐重写 `execute(PluginMessage)` 返回 `PluginReply?`，完整保留身份与会话上下文；返回 null 表示不处理。

```dart
class CounterPlugin extends BotPlugin {
  CounterPlugin(super.info);
  @override
  Future<void> onEnable() async {}
  @override
  Future<void> onDisable() async {}
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async => null;
  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    if (parseSlashCommand(message.content)?.command != 'count') return null;
    final key = '${message.isGroup}:${message.sessionId}';
    final count = await host!.store.update<int>(key, (data) {
      final next = (data['count'] as int? ?? 0) + 1;
      data['count'] = next;
      return next;
    });
    return PluginReply('本会话计数：$count', format: 'text');
  }
}
```

- `commands` 返回 `PluginCommand` 列表，动态帮助和插件卡片自动显示。`acceptsUnmentioned` 决定是否接收未 @ 全量消息，默认仅 `/`、`#` 命令；不能突破平台接收权限。
- `PluginMessage` 还提供 senderRole、isFullGroupMessage、eventType、callbackData、attachments；回调通过 `execute` 或默认 `onInteraction` 处理。
- `host.store.update` 串行原子读改写；按当前 AppID + 插件 ID 隔离，开发者再用会话/发送者组成键。必须使用 JSON 数据；整个插件最多 256 个数据键、512 KB。不放密钥，不在 action 内启动异步工作。
- `host.store.read`、`snapshot` 读取；`clear` 清空。宿主在插件菜单提供数据导出/清理，清理需先停用。卸载不自动擦除玩法数据；应用“清除全部数据”会清除。
- `executionTimeout` 默认 10 秒，启停 5 秒；异步操作自己取消和限时。超时不代表任意 Dart 工作能被强行中止。`onTick` 仅保留接口，目前无自动调度，不承诺定时推送。

新 Dart 插件需加入 `plugins/lib/built_in_registry.dart`、`plugins/index.json`、根 pubspec 的清单 assets，再重新编译。参考新内置 `daily_club` / `group_games`；源码是受信任应用代码，必须审核依赖，不能视为安全沙箱。

## 8. 文件管理、数据与测试

工作区位于应用支持目录 `plugin_workspace/<项目ID>/`，不提供系统全盘浏览。最多 6 层、128 个文本文件、单文件 256 KB；不跟随符号链接/目录联接，不接受 `..`、绝对路径或系统保留名。原生源码只是编辑文本，不能通过清单执行。

切换/关闭会提示未保存草稿；保存用原内容检查防止覆盖其他窗口的修改。旧版本和移除的文件进入 `plugin_workspace/_history`，可恢复为新文件，不覆盖现有文件。最多保留 500 份，达到上限会停止保存并提示手动备份整理，不自动删除。文件操作无法防御同一用户恶意并发替换文件系统路径，不把工作区暴露给不受信任的本地进程。

玩法数据独立于配置备份，普通导出清单不带签到/投票；整套配置备份仍可能含实际密钥，切勿公开。插件卡片「… → 导出本地玩法数据」提供 JSON，含参与者 OpenID，应妥善保管；目前不支持数据导入恢复，清理前请确认用途。

开发验证：`flutter analyze --no-pub lib plugins test`；`flutter test`。测试使用空机器人凭据、录制发送接口与回环服务，不连接真实 QQ、不使用真实付费 Key。需要在开发者测试机器人上验证的项目：Markdown/键盘权限、真实按钮回调、媒体外链可达、全量群事件开通。自动化通过不代表已取得平台权限。

## 9. QQ 官方能力边界与参考

平台的被动回复有时限/次数限制，群消息不支持流式参数；相同源消息的回复序号由宿主统一递增，不让插件自己维护。Markdown 与普通 content 分开构造，媒体先上传再引用；平台权限或审核失败需在 QQ 控制台处理。不要通过随机序号绕过平台去重，不承诺任意主动群推送。

- [QQ 消息概览](https://bot.q.qq.com/wiki/develop/api-v2/server-inter/message/overview.html)
- [发送群消息与键盘](https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_groups_group_openid_messages.post.html)
- [交互事件](https://bot.q.qq.com/wiki/develop/api-v2/autogen/event/interaction_create.html)（仅需应答的按钮/菜单类型由宿主 ACK；群用户使用 group_member_openid，不冒用频道 user_id）
- [高德天气接口](https://lbs.amap.com/api/webservice/guide/api/weatherinfo)
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)（模型可在配置中调整，服务可能收费）

建议下一批扩展：个人/群订阅与定时提醒（先设计授权和后台保活）、知识库问答（按群隔离、明确 AI 服务数据流向）、词库问答插件、管理员命令审计、插件依赖与版本兼容检查、可审核的签名插件仓库。不推荐为“玩法多”开放任意系统命令、远程源码自动执行或无权限群管理 API。
