# QQ Agent 模块边界

本目录是独立的 QQBot / OneBot 11 AI 工作区。原工作区的 BotClient、聊天、插件和存储不作为本模块的依赖；QQBot 使用单独实例的底层网关服务。

- `models.dart`：连接、模型服务、预设、会话和 OneBot 消息段。
- `store.dart`：专用 `qqm_agent_v1` Hive 文件；不注册已有适配器、不迁移旧数据。
- `onebot.dart`：正向通用 WS 客户端及反向 WS 监听器，独立账号校验和请求回执。
- `qqbot.dart`：官方凭证、独立网关连接、OpenID 事件转换、被动回复与序号；不读取原工作区的密钥或会话。
- `ai.dart` / `extensions.dart` / `script.dart`：模型调用、命令插件和 Skill 工具。
- `js_packages.dart` / `js_bootstrap.dart` / `package_compatibility.dart`：独立 QuickJS 工作线程、受限 Node API 桥接和原包兼容情况。
- `message_context.dart`：复用纯 QQ 消息正文解析，读取引用与转发内容；只匹配本账号、本会话的本地引用。
- `controller.dart`：连接生命周期、消息入库、会话级 AI 调度和取消。
- `ui/`：独立导航、配置和聊天视图；复用纯消息正文 / 附件组件，不共用原工作区的会话状态或发送器。
- Linux 的 `/api/agent/` 和 `agent.html` 只在现有管理密码与安全入口验证后使用。

每个会话键都包含连接 ID、QQ 号或 AppID、会话类型及对端标识；QQBot 还使用明确的协议前缀，与旧 OneBot 会话不冲突。AI 上下文、长期备注、插件状态和停止标记按此键隔离。切换界面不修改原工作区的选中账号。

模型接口由用户配置；接入令牌和模型 API Key 不进入模型上下文、日志或扩展导出。包自行填写的私密设置保存在本地，分享 ZIP 前需要清理。模型只能使用当前预设选中的 Skill 和当前连接选中的 JavaScript 插件工具，不能自行选择 OneBot action 或其他会话。编辑连接、停止连接、停用自动回复和清除上下文会作废进行中的旧回复。

设计参考 [K0nd1us/QQ-agent](https://github.com/K0nd1us/QQ-agent) 的人设、确定性插件和 LLM Skill 分层。本模块使用 Flutter / Dart 和内嵌 QuickJS，支持明确范围的 apiVersion 1 JS 原包，不载入上游 Node.js 进程或真实数据目录；原内核服务和钩子以导入后的兼容情况为准。上游 MIT 许可及署名见 `docs/licenses/QQ-agent-MIT.txt`。
