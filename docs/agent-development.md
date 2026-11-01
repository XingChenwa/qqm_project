# QQ Agent：接入、配置与扩展开发

QQ Agent 是应用内独立的 AI 工作区，支持 **QQBot 官方机器人** 与 **OneBot 11 协议端**。桌面侧边栏或手机顶部的 **QQ Agent** 按钮可以进入；左上角返回原机器人工作区。账号、聊天记录、预设、插件和日志各自独立。

## 完整数据迁移与源码编辑

在原工作区 **设置 → 数据迁移**，或 QQ Agent 顶部的 **数据迁移** 按钮，选择 **导出完整 ZIP**。ZIP 包括两个工作区的全部机器人账号和密钥、AI 模型和 API Key、预设、聊天、插件 / Skills 源文件与配置、虚拟文件数据、记忆、提醒、收藏、用量、原插件工作区与历史、自定义表情原图和应用偏好。不同 AppID 的资料仍分别保存。

在另一台设备安装新版，选择 **导入 ZIP 恢复**，先检查来源版本和数量，再确认。管理器先停止连接和插件、自动保存恢复前 ZIP；完全退出并重新打开后才替换数据。Linux 网页同样提供完整 ZIP 导入导出，确认后需重启服务；服务器管理密码和安全入口由该服务器保留。恢复失败或意外中断会尝试回滚，恢复前备份也能在迁移页面导出。恢复是完整替换，不是合并。

备份内含私有资料，请只在自己的设备保存和传输。压缩包上限128MB、解压后256MB、2048个文件；不复制安装程序、系统组件、浏览器缓存或外部部署的翻唱环境与模型。QQ 平台云端素材继续归原机器人所有；外部服务地址和文件路径迁移后需要按新环境检查。导出前请先保存编辑器中的草稿。

桌面端在 **AI 插件 / Skills → 打开源码文件夹** 直接打开 Windows 资源管理器、macOS Finder 或 Linux 系统文件管理器。首次点击会将原包释放为真实源文件，之后可以用 VS Code、记事本等编辑器修改 `plugin.json` / `skill.json`、`index.js` 及其他文件。JSON / HTTP / Hetu 扩展在单个清单中编辑全部逻辑；JavaScript 保留原包结构。源码目录位于应用私有数据目录的 `agent_sources/<扩展ID-标识>/`，与机器人工作台的插件目录分开。

外部保存文件不再经过应用内表单的格式或预览长度限制。QQ Agent 在文件稳定保存后自动尝试重新加载；代码或清单尚未写完时仍然保留磁盘草稿，继续使用上次有效的运行包，并显示具体加载错误。修改正确后会再次加载，也可点击 **重新加载源码**。应用关闭时修改的文件，会在下次打开 QQ Agent 后检查。仅在打开过源码目录的扩展上监听，不会反复扫描整个磁盘。

修改源码保留设置、密钥、启用状态和已保存的插件数据；执行中的旧任务会取消。内外两处同时修改时保留两份内容，手动 **重新加载源码** 明确采用磁盘版本。外部源码目录、同步记录和未通过语法检查的草稿都包含在完整 ZIP 备份中；不要把应用的数据目录设为公开网站目录。

手机和网页继续使用 **文件管理** 页面。支持新建目录与文件、重命名 / 移动、删除、导入替换和源码导出；桌面旧文件管理页也可点击 **打开文件所在位置** 在系统中定位文件。二进制文件可以导出、替换，应用内文本预览上限1MB。

点击 **保存并应用**（桌面快捷键 Ctrl+S / macOS ⌘S）时统一校验全部文件，再重新加载扩展，无需重新编译 App；正在执行的旧任务会取消。保存失败保留当前草稿和原有已保存文件；离开未保存页面会询问。源码存在并发修改时拒绝覆盖，可先导出草稿再重新打开。请保留扩展ID、类型和清单位置；修改源码不会清空独立设置、密钥、启用状态或已保存的插件数据。

## 快速开始

1. 在 **机器人连接** 选择机器人类型。OneBot 需要自行准备已登录的协议端；QQBot 使用官方开放平台的机器人。
2. OneBot 填写真实 QQ 号、连接方式和令牌；QQBot 填写 AppID / ClientSecret，也可点击 **QQBot 扫码**。保存后点击启动。
3. 在 **AI 模型** 填写兼容 Chat Completions 的根地址和 API Key，点击 **获取并选择模型**，可搜索后选中，也可手动填写模型 ID。无需先保存；测试与保存使用当前输入。根地址例如 `http://127.0.0.1:11434/v1`；不要附加 `/chat/completions`。本地免鉴权服务可不填 API Key。
4. 编辑 **预设**，选择刚添加的模型，填写人设。可选择图片转述模型、Bing 网页搜索、时间感知与思考内容显示；高级设置里调整图片尺寸、温度、最大输出长度和历史上下文条数。
5. 编辑机器人连接，选择默认预设并开启自动 AI 回复。保存连接配置后重新启动连接。
6. 默认群聊先通过 @ 当前机器人、`/ai 问题`、自定义 AI 命令或额外前缀唤醒，随后当前群的允许成员可以直接连续聊天；5 分钟没有新成员消息就休眠，再次唤醒后继续。私聊保留原来的自动处理开关。高级设置仍可选择处理全部群消息或关闭群聊，并配置白名单、冷却和插件。手机连接电脑的 OneBot 时，WS 地址里的 `127.0.0.1` 要换成电脑的局域网 IP；它不是自动登录个人 QQ 的服务。

仅接入 OneBot 就可以手动收发消息，不要求配置 AI。首次使用默认不自动连接、不自动 AI 回复，示例扩展默认关闭。模型测试、手动生成回复，以及开启自动回复后的触发消息，会调用你选定的服务，可能产生该服务的费用。

## 内置 Agent 能力

预设中的 **内置 Agent 能力** 默认开启，无需安装额外 Skill。主模型仍须支持工具调用；高级设置可以逐个停用工具、限制每轮工具次数，或单独开启跨会话转告。默认每轮最多12次，范围1–32次；工具和额外视觉请求会使用所选服务的额度。

**评价头像**：给预设配置支持图片的主模型，或选择一个图片转述模型。在群里 @ 机器人说“评价一下我的头像”，即使未发送图片附件，管理器也会按真实发送者ID取得个人头像并送给视觉模型。QQBot用本机器人AppID与用户OpenID，OneBot用真实QQ号；不读取QQ群头像。没有可用视觉模型时，预设卡片会提示，模型不能把“没看到”编成“头像是黑色”。

| 功能 | 内置工具 / 行为 |
| --- | --- |
| 发消息、@、引用、分条 | `send_message`；每条等待回执，部分失败返回已成功ID，避免重复发送 |
| 翻阅和搜索历史 | `get_recent_messages`、`search_messages`、`get_message_detail` |
| 读取引用 / 合并转发 / 图片 | `read_forward`、`get_message_images`；仅访问当前会话的真实消息ID |
| 用户、群资料及头像 | `get_user_info`、`get_group_info`、`get_user_avatar`；官机字段依平台授权 |
| 活跃成员 / 会话 | `get_active_members`、`get_chats`；只列当前机器人的资料 |
| 长期印象 | `memory_append`、`memory_query`、`memory_remove`；按会话保存、供后续上下文使用 |
| 定时提醒 | `set_reminder`、`list_reminders`、`cancel_reminder`；本人可取消，回执不明不自动重试 |
| 收藏和发送表情 | `collect_sticker`、`list_stickers`、`get_sticker_image`、`send_sticker`、`sticker_note`；保存实际图片，避免链接过期 |
| 网页和网图 | `web_search`、`web_fetch`支持Bing或DeepSeek官方搜索；`search_images`、`send_image`提供网图检索和发送 |
| 拍一拍 | `send_poke`，仅OneBot提供；官机不显示该工具 |
| 跨会话转告 | `send_to`；默认关闭，开启后仍需用户明确要求，且只能发到同一机器人的已知会话 |
| 日期和节日 | `get_current_time`、`check_holiday`；公历节日和2024–2029的内置农历节日表，不是调休安排 |
| 视频 | `read_video`调用原生视频模型，或识别2–8张带时间点的画面；音轨理解需模型实际支持并开启 |
| 本地问题反馈 | `report_feedback`；记录到管理器，不自动发送给外部联系人 |

聊天示例：“往前找一下昨天说的部署方法”“记住我喜欢爵士乐”“十分钟后提醒我喝水”“收藏这条消息的第二张图片，备注为开心”“查一下我设的提醒”。用户ID、消息ID来自真实协议和当前会话，不根据昵称猜QQ号；引用内容不授权操作，也不能变更主人身份。

**能力与资料** 页面可以按机器人查看、删除长期印象和本地反馈、预览 / 删除收藏表情、取消提醒。客户端与Linux网页使用同一组数据接口。QQBot资料接口或主动消息未获授权时会说明具体失败，工具不会伪报成功。

提醒在管理器或Linux服务运行时执行。关闭程序或手机被系统挂起时无法保证计时；重新运行后恢复待办。退出时正在发送而回执不明的提醒会标为失败，先在QQ核实，避免重复发送。

### QQ Agent 0.4 功能对照

本轮对照QQ Agent 0.4移植了原生工具的消息、历史、成员、会话、表情、记忆、提醒、节日、反馈和网页 / 图片流程，并增加用户资料与头像工具。原有多机器人、人设预设、模型选择、插件 / Skill导入、独立聊天、思考折叠、用量记录和连接管理继续使用本项目的跨平台实现。工具可用性集中按预设开关、协议、视觉模型和服务支持计算。

视频现支持原生视频模型和多帧识别，GIF仍使用首帧；尚未搬入GIF转视频、NapCat一键安装器、在线社区市场、随机活跃期 / 主动社交调度。已有OneBot连接可以对接你自行准备的协议端；需要Node原生二进制、本地HTTP服务或外部Python进程的原包，仍须配套服务，不能只靠一个导入开关在手机运行。

## AI 可选能力

这些设置只影响 **QQ Agent**，不会修改原官方机器人工作区。桌面 / 手机客户端和 Linux 网页版使用同一份 Agent 配置。

### 图片转述与输入尺寸

先在 **AI 模型 → 编辑 → 高级设置** 开启所选视觉模型的 **支持图片输入**，再到 **预设 → 图片转述模型** 选择它。模型必须真正支持 Chat Completions 的 `image_url` 图片输入；界面开关不会让文本模型自动获得视觉能力。

- 未选转述模型：主模型开启视觉能力时直接看图；否则只收到“[图片]”占位。
- 选择转述模型：图片先交给它，主模型只接收文字描述，因此也可使用纯文本主模型。转述单独消耗该模型的调用 / token；同一会话、同一模型和同一图片的描述短时缓存在内存，不写入共享图片库。
- **输入图片最大边长** 在预设的高级设置中配置，默认 **1536** 像素，可设 **256–4096**。图片先等比缩小，不放大小图；校正方向、移除元数据并转为 JPEG 后再传给模型。GIF / WebP 使用首帧，不会保留动画。
- 每张原图不超过 5 MB / 1600 万像素，每条消息最多 3 张，每轮最多 6 张，处理后的图片合计最多 8 MB。不可访问的地址、解码失败或超限会记录警告并给模型明确占位，不假装识别成功。
- 只读取公共 HTTPS 或消息内图片数据，不向图片站点发送模型 Key / 机器人 Token，不访问本地路径或内网。图片会传给所选视觉服务，请按实际需要开启。

### 视频内容理解

在 **预设 → 读取视频内容** 开启，选择 **视频理解模型**。机器人收到新视频并被触发时会先分析视频，再由主模型结合问题回复；也可调用 `read_video({"messageId":"真实消息ID","question":"这段视频讲了什么"})` 读取同会话旧视频。每次默认处理当前消息的第一个视频，`index` 可选1–3。QQBot与OneBot使用相同流程，主模型可以继续使用文本模型。

- **原生视频**：在 AI 模型的高级设置开启 **支持原生视频输入（video_url）**。应用把实际视频地址交给该模型，支持客户端及Linux服务。接口必须兼容Chat Completions的 `video_url`；例如Qwen-VL可理解画面，兼容的视频Omni模型可同时理解音轨。仅在模型实际支持时开启 **视频模型同时理解音轨**；只支持SSE的接口还需开启 **接口要求流式返回**。能力开关不能让普通文本模型获得视频能力。参数依据：[视频输入接口](https://www.alibabacloud.com/help/en/model-studio/qwen-api-via-openai-chat-completions)。
- **多帧识别**：客户端可复用支持图片的主模型、图片转述模型，或单独选择视觉模型。程序先下载不超过20MB的视频，在隔离WebView中按时间均匀提取2–8张真实画面（默认6张），一次交给视觉模型分析画面、动作与字幕，并保留时间点。支持10分钟以内、系统WebView可解码的视频；不提取音轨，不能把画面推断说成听到的对白。Linux网页没有本机抽帧器，请选择原生视频模型。
- 视频分析会额外调用所选模型并记录用量。相同会话、视频、问题和模型配置的分析短时缓存10分钟；不同会话不共用。地址失效、编码不支持、只取得单张封面或任务已取消时会明确失败，不生成“已经看完”的假结果。未配置视频或视觉模型时，主模型会收到未识别说明。

JavaScript扩展从宿主 **9** 起可用 `await ctx.video.analyze({messageId, question, index})`，返回 `summary`、`route`、`notice` 等结构化结果；仍受当前会话、预设开关和模型配置限制。

### 群聊唤醒、连续对话与额外前缀

默认的 **唤醒后连续聊天** 同时支持 @ 当前机器人、`/ai`、自定义 AI 命令及额外唤醒前缀。即使修改了自定义命令，`/ai` 仍可使用。唤醒后，同一群内允许的其他成员也可以不加 @ 或前缀直接聊。

每条通过权限检查的新成员消息都会将空闲期限重设为 5 分钟；机器人回复、重复推送、白名单外成员的消息不延长期限。超过 5 分钟没有有效的新消息就自动休眠，运行日志会显示状态；下一次 @、命令或额外前缀可重新唤醒。各机器人、各群分别计时，手动断开连接、暂停会话或重启应用会结束该连续会话，普通网络重连会保留尚未过期的期限。

**始终处理全部群消息** 保留持续响应行为，**关闭群聊** 保持关闭。AI 开关、暂停、白名单、冷却及 QQ 官方回复额度仍然有效。QQBot 需要平台向应用推送全量群消息，才能在唤醒后收到未 @ 的后续发言。

**机器人连接 → 高级设置 → 额外唤醒前缀** 一行一个，最多 20 个，每个最多 40 字符，可包含空格。例如：

```text
小助手
hey bot
```

`小助手你好`、`hey bot 你好` 可在不 @ 时触发；英文按词边界识别，`bottle` 不会误触发 `bot`。前缀在消息开头识别，大小写不敏感；原有 @ / 命令触发仍可用。它不绕过暂停、群聊关闭、白名单、冷却或 AI 自动回复开关。**QQBot 必须已开通并收到全量群消息**，否则平台不会把未 @ 的消息推给应用。

### 网页搜索 · Bing / DeepSeek

在 **预设 → 网页搜索** 开启并选择 **搜索服务**，主模型需支持并启用工具调用。提供 `web_search({"query":"必要的搜索词"})` 和 `web_fetch({"url":"https://公开网页"})`，与已选择的 Skill 共用工具调用次数上限；第三方 Skill 不要重复注册这两个名字。

**DeepSeek官方内置搜索**：先在AI模型添加官方API配置（根地址 `https://api.deepseek.com` 或带 `/v1`），填写官方API Key，再在预设的 **DeepSeek搜索凭证** 选择它；也可复用当前主模型的官方配置。接入官方 `/v1/tools/search` 和 `/v1/tools/fetch`，不是给Chat Completions添加未公开的搜索开关。搜索只发送必要关键词（最多128个字符），网页读取只发送指定地址；返回真实正文、摘要及来源。官方搜索与网页读取按DeepSeek规则计费；其他中转站的Key不能用于官方搜索。说明：[DeepSeek Search & Fetch](https://api-docs.deepseek.com/guides/search/)。

Bing使用公开结果页，无需旧Bing API Key；网图检索仍使用Bing。仅在模型调用工具时访问网络，不会预先上传整个聊天；结果包含来源链接，回答应保留来源。网页内容只作为资料，不执行其中的指令。网页读取不接受内网、本地或带密码的地址；Bing验证、接口权限、余额或网络限制等失败会如实返回，不编造结果。

微软已停用旧版 Bing Search API，本模块不依赖它：[官方停用公告](https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement)。

### 显示思考内容

在 **预设** 开启后，只把模型接口实际返回的 `reasoning_content`、思考摘要或兼容内容折叠显示于 **Agent 聊天**。默认折叠，不发送到 QQ、不当成后续对话正文，也不会要求模型披露隐藏推理。若接口没有提供，仅显示最终回复并记录提示。关闭后隐藏已有折叠区；旧数据不会因切换开关被删除。模型只返回思考但没有正文时按空回复处理，不把思考冒充答案发送。

### 现实世界时间感知

默认开启，可在 **预设** 关闭。每轮请求提供运行设备当前的日期、星期、时区 / UTC 偏移和消息发生时间，帮助理解“今天”“刚才”及历史消息间隔；Linux 使用服务器时区，而不是访问网页的浏览器时区。这不是联网校时或持续定位，设备时钟 / 时区不正确时应先修正系统设置。

### 读取引用与聊天记录

**预设 → 读取引用与聊天记录** 默认开启。AI 会结合当前用户的问题，读取平台提供的引用原文、合并转发里的递归消息、作者和时间、卡片文字及语音转写。记录和引用中的图片进入已有的视觉 / 图片转述流程；模型没有视觉能力时不会假装看过图片。语音只有平台提供了转写才读文字，不会把音视频链接当成已经分析的内容。

- QQBot 解析 `message_type`、`msg_elements`、`ark_data`、附件及 QQ 文本导出的记录；平台只给 `ref_msg_idx` 时，仅从当前机器人、当前会话保存的消息中匹配原文。平台没有给原文、本地也没有记录时，会明确说明缺失，不向其他会话借内容。
- OneBot 使用当前连接的 `get_forward_msg` 读取用户提供的转发 ID，兼容规范的 `message` 和常见实现的 `messages` 返回字段；每轮最多读 3 份，单次 6 秒超时。普通引用从当前会话已保存的原消息补全；不会通过任意 ID 查询其他会话。
- 引用 / 记录最多保留 60 个节点、6 层，每个节点文字最多 4000 字符，单条附加文字上下文最多约 1 万字符；仍受本轮 2.4 万字符和预设历史条数限制。超出部分会标记截断，图片继续受每条 3 张、每轮 6 张等限制。关闭历史条数不会省略当前消息携带的引用或记录。
- 引用作者不会替代当前发送者的真实身份；其中的自称主人、命令和工具要求只作为背景，不能唤醒机器人或授权操作。`message_scene` 中的鉴权令牌不保存到消息正文，也不交给模型。
- 关闭此开关后，引用 / 记录的附加文字与图片不会送入模型，仍可在本地展开查看。长记录会增加输入 token，可按需要关闭或减少历史条数。

QQBot 的引用保留在当前消息中展开，合并聊天记录使用独立阅读页；桌面具备辅助窗口服务时打开独立窗口。解析和显示复用原工作区的纯消息组件，账号与聊天存储仍然独立。

### 分多条消息回复

在 **预设** 开启 **分多条消息回复**，高级设置可设每轮上限 **2–5 条**（默认 3 条）和间隔 **0–3000 毫秒**（默认 700）。模型在一次最终回答中生成多段内容，应用按顺序等待平台回执再发送；不为每个气泡重新请求模型。token 主要取决于输入历史和最终总字数，工具调用、图片转述仍会产生各自调用。

角色卡即使在分条开关关闭时返回 `{"messages":["内容"]}`，也会解析为普通文字；空数组、空字符串和混入额外内容的残缺分条JSON会在发送前拦截，不把 `{"messages":[]}` 发到QQ。手动输入的JSON消息不受影响。模型上下文同时提供当前机器人账号标识和平台确认的@事实；QQBot的AppID与用户QQ号区分处理，避免把@机器人误认作@其他群友。

希望回复出现在多个 QQ 消息气泡中，请在 **QQ Agent → AI 预设 → 编辑当前使用的预设 → 分多条消息回复** 开启。优先采用模型 `messages` 数组中的分条；模型返回普通文字，或只返回一个含多个普通段落的元素时，也会按空行拆开发送。单个换行、句号不拆分；代码、列表、表格、引用块等复杂排版保留为完整消息。每轮仍受设置的 2–5 条上限及官机剩余被动回复次数限制，超出的段落合并到最后一条；全部分条由同一次模型结果产生，不为每条额外请求模型。分条关闭时，空行保持为一条消息内部的段落。

QQBot 会先检查触发消息的剩余被动回复次数，额度不足时合并段落，耗尽时不再调用模型。不会为连发绕过平台权限切换主动消息。只有平台明确返回去重错误 `40054005` 时才用新序号重试一次；网络超时等未确认结果不重试，避免重复发送。中途失败会保留已确认发送的消息，显示发送进度与原因；点击停止不再发送剩余段落。

## 两种 WebSocket 方式

以下正向 / 反向选项只用于 OneBot。切换后表单只显示对应字段，来回切换会保留未保存的输入；QQBot 会自动获取官方 WebSocket 网关，不需要手填 WS 地址。

### 正向 WS：应用连接协议端

协议端开启通用 WebSocket 服务，例如 `ws://127.0.0.1:3001/`，应用填写该地址和对应令牌。使用同时提供 API 和事件的通用接口，不使用单独的 `/api` 或 `/event` 地址。应用会通过 `get_login_info` 校验实际账号，断开后自动重连；未确认的发送不自动重试。

### 反向 WS：应用提供监听服务

应用默认监听 `127.0.0.1:23337/onebot/v11`。协议端在另一台设备时，监听 IP 改为 `0.0.0.0`，协议端填写运行应用设备的局域网 IP。`0.0.0.0` 只是监听地址，不是协议端应该连接的地址。

协议端配置示意：

```json
{
  "url": "ws://192.168.1.10:23337/onebot/v11",
  "access_token": "与应用里相同的至少16字符令牌"
}
```

支持 Universal，或分开的 API / Event 连接；分开连接可使用 `/onebot/v11/api` 与 `/onebot/v11/event`，也支持将监听路径设成 `/`。按 OneBot 11 规范传递 `Authorization: Bearer ...`、`X-Self-ID` 和 `X-Client-Role`。令牌与协议端保持一致；仅本机监听时可留空，对外监听必须填写。多个账号分别添加连接、使用不同监听端口。应用拒绝令牌不匹配、机器人 QQ 号不匹配和来自浏览器 Origin 的协议连接。

应用作为 WS 服务器接收协议端连接，在 OneBot 术语中叫“反向 WS”。它不是供其他机器人再次转发的通用 OneBot API 服务。

公网连接请在服务器端终止 TLS 后使用 `wss://`，只把指定协议路径转发到监听端口。手机后台运行受系统限制；持续在线建议用桌面端或 Linux 服务。本模块不会为 OneBot 冒用官方机器人的后台通知服务。

## 会话、记忆和收发

### QQBot 官方接入

- 客户端支持手动 AppID / ClientSecret 和扫码授权；扫码会重置机器人密钥，开始前会说明影响，新密钥仅保存到 Agent。Linux 网页版使用手动凭证。
- QQBot 使用群 / 用户 **OpenID**，不填写真实群号或 QQ 号。同一 AppID 可以在工作台和 Agent 同时运行，启动顺序不限；应用共用一条官方网关，分别接收消息，停止一边不影响另一边。聊天、插件、AI 预设与配置仍分别保存。不同 AppID、正式 / 沙箱环境和 OneBot 账号独立运行。
- 支持官方群 @ 事件、已开通的群全量事件、单聊事件；群聊默认唤醒后连续对话，空闲 5 分钟结束。AI、人设和 Skill 的使用方法相同。
- Agent 内的 QQBot 支持文本、Markdown @、本地图片和工具语音发送；GIF / WebP 上传前转换为首帧 PNG。官方语音上传接受 WAV / MP3 / SILK，音频需不超过 5 MB。引用需要事件提供的引用索引。
- 群消息被动回复 5 分钟 / 5 次，单聊 60 分钟 / 4 次；工作台与 Agent 统一分配、持久化回复序号，AI 回复固定对应触发消息。两边对同一条消息共同使用平台的回复额度；超时或次数用完会提示，不自动改成主动消息发送。手动发送无有效被动回复时受平台主动消息权限限制。
- 官方平台不提供 OneBot 式好友 / 群列表同步。收到消息后自动建立会话，也可手填正确 OpenID。
- 群名和成员昵称优先采用事件返回的字段，缺失时异步调用群资料 / 群成员资料接口；单聊缺失昵称时沿用原工作区的 OIAPI 方法，提交 AppID 和用户 `author.id` 对应的 OpenID，不附带机器人鉴权。配置位于 **机器人连接 → 高级设置**。资料查询不阻塞 AI 回复；命中缓存后可回填同会话已有的占位昵称，用户手动命名的会话保持原名。
- 群资料接口需要平台授权。`11253` / HTTP 403 会记录日志并停止重复查询该类资料，不能编造群名或昵称；会话菜单的 **刷新官机会话资料** 可在权限调整后重试。
- 同一消息的全量事件和 @ 事件按原消息 ID 合并，后到的 @ 可补充唤醒，避免先收到全量消息后漏回复，也不会重复写入记录或重复调用模型。Markdown @、`is_you` 和机器人 ID 别名一起判断，其他机器人不会被当成自己。

参考：[鉴权与 AppID 凭证](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/api-use.html)、[事件与 WebSocket](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html)、[群消息发送](https://bot.q.qq.com/wiki/develop/api-v2/autogen/api/v2_groups_group_openid_messages.post.html)。

### 查看回复阶段与运行日志

聊天页会显示排队、准备上下文、读取记录 / 图片、模型请求、工具调用、发送和完成状态。未唤醒、白名单限制、冷却、暂停及自动回复未开启都会给出具体原因；失败状态可点开查看全文，也可关闭。**运行日志** 包含连接名称和阶段，保留 HTTP 状态、平台错误码及有效追踪 ID，支持复制。日志不记录聊天正文、模型 Key、ClientSecret 或访问 Token；平台原始错误正文可能含敏感内容，因此只显示整理后的错误信息。昵称查询失败与发送失败会分别记录，不会把资料问题误报成 AI 未回复。

“本地候选”是本地保存的记录数，不是发给模型的数量；`context-ready` 显示按预设选取的聊天条数，`model` 显示扩展处理后的实际输入条数、文本字符数、图片数和工具数，`model-result` 显示耗时与接口报告的用量。正文历史仍按预设的 0–80 条及 24000 字符上限选取，系统提示、扩展附加资料和工具定义另计。

AI 模型请求持续等待到返回，不设客户端固定超时，旧配置中的 `timeoutSeconds` 自动按 0（不限制）读取，原来的整轮 3 分钟限制也已取消。在聊天中点击 **停止回复**、停止连接或关闭应用可取消当前请求；同一会话仍按顺序处理消息。模型服务、代理或网络自身仍可能断开连接，返回 502 / 503 / 504；取消本地等待时限不能消除服务端错误。附件下载、普通网页读取和插件工具保留各自的操作限制。

模型接口返回 HTTP 500 / 502 / 503 / 504 时，最多自动重试一次，并记录 `model-retry`，不会重新执行此前完成的工具。鉴权失败、请求参数错误、限流、连接失败或成功响应的解析错误不自动重发。持续 502 / 503 / 504 需要检查所用模型服务或中转网关。

图片在同一会话内短暂保存在内存：处理成功后缓存 10 分钟，HTTP 400 / 401 / 403 / 404 / 410 失败后暂停重复下载 5 分钟，其他读取失败暂停 30 秒。缓存最多 64 项、图片合计 16 MB，不写入磁盘；换一条有效图片 URL 可立即重试。失效图片不会阻断文字回复，也不会伪造图片内容；仅首次失败记录警告，后续模型上下文会继续标明未读取。手动停止 / 重连、开始新上下文及修改配置会清除相关缓存。

### OneBot 收发与通用 AI 配置

- 可以同步好友与群，也可用真实群号 / QQ 号新建会话。
- 文本、@、图片、语音、视频、引用和转发记录按 OneBot 消息段解析；媒体实际可用性取决于协议端返回的 URL。
- 手动发送文本和图片；长按 / 右键消息可复制、引用及 @ 发言人。Enter 发送，Ctrl+Enter 换行。
- 打开会话及自己发送后滚到底部；收到消息时保留阅读位置，显示新消息按钮。
- 会话设置可单独暂停自动回复、覆盖 AI 预设、编辑长期备注。开始新上下文不会删除聊天记录。
- 每个会话最多保留最近 500 条消息；AI 上下文数量由预设限制，附加总字符上限。启用视觉时，图片会先经过预设尺寸限制后提供给所选模型；选择转述模型时主模型只接收描述。
- 每个会话顺序执行任务，全局最多同时运行两个任务；工具调用有次数、参数和超时限制。停止任务、停用扩展或修改配置会作废旧回复。
- AI 输出作为文本消息段发送，不将其文本中的 CQ 码当作可执行消息段，不开放任意 QQ action、其他会话发送或系统命令。

## 插件与 Skill

二者均在 **QQ Agent** 自己的管理页导入、启停、编辑源码和导出；不放入原官方机器人的插件目录。

| 类型 | 触发方式 | 在哪里选用 |
| --- | --- | --- |
| `plugin` | 命令处理或 JavaScript 插件能力（如主人身份、人设规则） | 机器人连接高级设置的 AI 插件列表 |
| `skill` | 注入提示词，可向模型注册工具 | AI 预设的 Skill 列表 |

支持 JSON、YAML、纯提示词 `SKILL.md`，以及包含 `skill.json` / `plugin.json` 的 **QQ Agent apiVersion 1 ZIP 原包**。导入扩展总是关闭，需要手动启用并在连接 / 预设中选择；保存后立即生效，不用重编译 App。两种扩展格式共用管理页，但执行器分开，原官方机器人插件不受影响。

### 直接导入 JavaScript 原包（手机与桌面）

Android、iOS、Windows、macOS 使用内嵌 QuickJS，Linux 网页服务也使用同一执行核心。无需安装 Node.js、启动外部运行器，或把 JS 手工改写成 Hetu。代码在独立工作线程执行，注册工具、图片下载和文件操作不占用 UI 线程。

连接启动后，配置和源码使用按变更更新的只读快照；心跳、日志和运行状态检查不会反复解析包内素材。空闲运行时减少轮询，新任务、网络结果和 JavaScript 定时器会按需唤醒；日志合并刷新，聊天记录未变化时不重复读取消息列表。

1. 在 **Skills / AI 插件 → 导入** 选择 ZIP；支持包文件夹被多包一层的压缩结构。
2. 先看扩展卡片的 **兼容情况**，再点击 **插件设置**：界面按原包 `configSchema` 显示数字、滑块数值、开关、文本和枚举，保留选项中文标签，并检查数值上下限。保存后手动启用。
3. Skill 要在 AI 预设中选中，并选择支持工具调用的模型；AI 插件要在机器人连接的高级设置中选中。
4. **查看 / 编辑文件** 可编辑 256 KB 以内的 JS、JSON、Markdown 等文本；清单只读，包参数使用设置页。导出仍是 ZIP，保留原始源码和用户设置。若自己的 JS 包在 `settings` 中存放私密参数，分享 ZIP 前需清理这些设置。

已用提供的 `trendy-memes`、`reply-meme`、`owner-identity` 原包验证加载与执行。网络梗包保留查询、目录和用户梗库；配图包保留选图、缓存、去重及冷却，发送只限当前会话，拿到协议回执才算成功；主人插件按协议发送者识别，不把昵称或正文自报身份当作依据。**主人 QQ 号识别只适用于 OneBot，官方 OpenID 不是 QQ 号。** 图源、平台权限和第三方网络仍可能导致发送失败，不会伪装为已发送。

以下原包共用一套宿主接口，源码与素材保持原样。导入时检查依赖，升级后自动复检已有扩展；插件仍需手动启用，并在连接或预设中选中。配置、协议或远端服务不满足条件时，运行日志和工具结果会显示具体原因。

| 原包 | 当前情况 |
| --- | --- |
| `deai-flavor` | 原始自检工具可执行，无需联网 |
| `smart-image` | 原始搜索、下载、缓存、发图链路已用模拟图源和发送回执验证；实际图源受网络与接口变化影响 |
| `api-beggar` | 余额查询工具与关键词前置钩子；自填 Key 只发送给设置中的余额服务源 |
| `share-card` | 分享链接自动注入、手动读取、OneBot OCR、好友 / 入群申请处理；仅使用本包配置的站点 Cookie |
| `whale-voice` | 内嵌 WSS 语音合成、二进制音频接收和发送回执；原包的 PowerShell 备用路径不执行。服务连接失败时不会假报成功 |
| `voxcpm-voice` | 原包参考 WAV、multipart 上传、Gradio SSE 完成事件、下载和发送；需填写可用的合成服务地址 |
| `qq-self` | 当前 OneBot 账号的资料 / 空间查询、资料修改、公开图片 / 当前聊天图片设头像与发布动态；支持原包演练、限额与结果待确认记录 |
| `burst-merge` | 调度器调用原 `wake.burst-policy`，合并同一发送者的连续消息；普通记录分别保留，不把其他人的插话混进触发批 |
| `context-reuse` | 跨轮保留原模块状态，真实发送成功后记录回复。希望由本插件管理历史时，将预设的历史条数设为 0，避免与常规历史重复 |
| `hot-trend-tracker` | 启用连接后执行原定时器，抓取和持久保存热点、按关键词注入；其他扩展可调用 `knowledge.hot-trends` |
| `group-cost-report` | 读取本账号、本群的真实模型用量及自填价格，按原插件规则生成并发送报告，不重复补发正文 |

语音合成链路已用原包、模拟服务和发送回执验证；实际可用性还取决于服务地址、网络和协议端。QQ 自身资料、空间、OCR 是 OneBot 扩展能力，协议实现可能没有相应接口，QQBot 官方连接不提供这些个人 QQ 操作。`qq-self` 可用公开图片 URL 或当前聊天图片；原项目全局表情收藏库没有随 ZIP 附带，未收藏的 `stickerId` 不会凭空生成。

`voxcpm-voice` 出现“提交合成任务失败：HTTP 503”表示合成服务已返回不可用，工具本身已经执行；可以稍后重试，或在插件设置中把 `apiBase` 改为可用且兼容该包 Gradio 接口的服务。没有收到语音发送回执时不会记录为发送成功。“显示思考内容”只控制管理器中的思考展示，不会将思考发送到 QQ。

### 在线角色语音（YY TTS）

`agent_examples/yy-tts/` 是可修改的独立 Skill，支持 URL 和本机下载。`skills-yy-tts-v1.0.4.zip` 默认优先把 <https://yy.jujiang.js.cn/tts> 链接交给适配器 / 平台获取，按设置编码 `character`、实际正文 `text`、`speed`；旧客户端缺少 URL 接口时自动改为本机下载后上传，也可手动选择始终本机下载。真正 URL 转发需要宿主接口版本4，自动兼容不要求旧客户端先升级。两种方式都不访问旧 Gradio 排队接口。

点包的“插件设置”，搜索选择角色音色，修改语速后保存、启用；再到机器人使用的 **AI 预设** 中选中这个 Skill。群聊按原规则 @ 机器人说“读一下：你好”，单聊直接提出朗读要求即可。高级设置可修改接口模式、服务地址及超时；情感与语言仅 Gradio 模式生效。不需要安装 npm、Python 或本地模型。同 ID 旧包请先导出备份，删除后导入新版，并重新确认设置与预设选择。

源码中的 `requiresMediaAck: true` 表示朗读必须收到实际发送回执；查询工具声明 `false`。`ctx.sender.sendMediaUrl(ctx.chatKey, url)` 等同于发送 `record` URL：OneBot 下发消息段，QQBot 按 `file_type:3,url,srv_send_msg:false` 上传后发送，均等待消息 ID。URL 仅允许当前会话、公共 HTTPS 地址，远端格式 / 大小由协议处理。旧宿主没有方法时，Skill 在任何发送发生前改用 `ctx.sender.sendMedia` 的本地音频路径，保留真实音频校验与5 MB上限；网络 / 回执失败后不自动重复发送。本预设明确要求默认语音也可触发朗读，用户要求只发文字时优先遵守。默认甜妹、语速1，情感与语言仅 Gradio 模式有效。完整用法见 [YY TTS README](../agent_examples/yy-tts/README.md)。

### sing-cover 翻唱包：导入与运行条件

需要在 Windows 本机安装可调用的翻唱环境时，可使用 [本地 AI 翻唱 · RVC](../agent_examples/local-rvc-cover/README.md)。它将 Demucs / RVC / FFmpeg 放在独立 Python 服务里，配套 `local_rvc_cover` JSON Skill 提供按歌名搜索QQ音乐、多版本确认、导入、环境、音色、歌曲、开始、状态、取消和发送十个工具，不把系统进程权限交给内嵌脚本。多版本会在原会话发给提问者选择；宿主接口7传入固定的当前消息身份，不能由模型伪造选择或用引用内容确认。音色由用户导入 `.pth`；基础模型不是角色音色，没有音色时不会宣称可翻唱。CPU 耗时任务在子进程执行，同一时刻一个任务。

支持宿主接口6的 Windows 管理器会读取安装器留下的固定本地 Skill 队列，首次导入保持关闭；同 ID 的已有设置、启用状态和私有参数不覆盖。启用并选入 AI 预设后，使用“检查翻唱环境”“列出歌曲 / 音色”“用某音色翻唱某歌”“查看翻唱进度”“把成品发出来”。开始返回任务ID，生成完成后再发送；这不是自动在后台向 QQ 推送。点扩展卡片的“打开设置页”可以导入素材、试听和下载整首。

在 **QQ Agent → Skills → 导入文件** 中选择 `skills-sing-cover.zip`。支持这个包的双层目录，导入后可以查看工具、编辑源码和设置、导出备份；展开“缺少运行环境或配置”可查看具体缺项。包的 `enabledByDefault` 不会替你自动启用。导入成功不等于已经具备本地 GPU 翻唱环境。

这份原包只有 `skill.json` 和 `index.js`，在源码中固定使用 `D:\7\cover`，实际需要以下配套文件：

| 位置（相对于 `D:\7\cover`） | 用途 |
| --- | --- |
| `run_cover.py` | 下载歌曲、分离、换声、混音与任务状态的流水线；ZIP 中未附带 |
| `rvcenv\Scripts\python.exe` | 配套 Python 环境 |
| `rvcenv\Scripts\pymss.exe` | 人声与伴奏分离 |
| `rvc\infer\cli.py` | RVC 推理程序 |
| `models\<音色名>.pth` | 所选音色模型，例如原包默认的 `mt_miku.pth`；模型文件未附带 |

请先向包作者获取完整的配套工程、模型及其依赖版本说明；只安装 Python 或重命名目录不能补齐这些资源。当前脚本宿主的文件系统是隔离目录，`node:child_process` 的具名导入用于让原包正常完成自检，**不会执行电脑上的 Python、PowerShell 或其他进程**。因此，这个 Windows 专用原包目前能导入和展示缺失项，尚不能直接执行它的本地 RVC 流水线；即使另行安装配套文件，也仍需接入本地执行适配器，或由包作者提供通过服务接口调用的版本。安卓、iOS 无法直接运行这个写死 Windows EXE 路径的流水线。

完整流程接入后，使用方式是：启用 Skill → 在 AI 预设中选中它 → 给机器人连接选择该预设并开启 AI 回复 → 在群中 @ 机器人说“翻唱这首歌 + B站链接/BV号”。三个原工具分别是 `sing-cover__sing_cover`（开始）、`sing-cover__answer_dialog`（回答是否去除对白）和 `sing-cover__cancel_cover`（先询问、再次确认后取消）。`voice` 为实际安装的音色名，`pitch` 为移调半音，`autoSend` 控制完成后自动发送。缺少环境时不要让模型宣称已开始唱歌；RVC 推理本身不用大模型 token，但 AI 理解指令和对话仍会调用配置的模型。长时间后台发送还须满足对应协议的发送权限、时限和音频大小限制。

费用价格填写在 **AI 模型 → 高级设置**，单位为人民币 / 百万 token，支持输入、输出、缓存输入价。留空表示未知，明确填写 0 表示免费；没有价格时不会按 0 元编造金额。只记录模型真实返回的用量；服务不返回 usage 的调用不计入报告。本地账本最多保留最近 2000 条运行记录，报告以保留的数据为准。统计不会读取其他机器人或其他群的数据。

连发窗口在 **机器人连接 → 高级设置** 中设置，默认 2000 毫秒；仅在选中连发插件时生效，封顶由插件决定，宿主另设 12 秒上限。未唤醒的群仍须先满足唤醒规则，同一成员的后续消息可合并到其等待窗口；连续会话有效时，其他允许成员也可以免 @ 发言，使用独立的回复窗口，不与前一成员合为同一批。暂停、白名单、关闭群处理及停止任务仍生效。

原包检查仅调用 `setup` / `available` 收集工具与依赖，不启动 `activate` 后台任务，不联网，也不发送消息。JavaScript 插件注册的工具与 Skill 工具共用模型调用流程，只对当前连接选中的插件开放。

支持的宿主契约：

| 契约 | 用途 |
| --- | --- |
| ESM `import` / `export`、相对模块、`import.meta.url` | 直接加载包内 JS，不改写源文件 |
| `setup(api)`、`api.config()`、`api.registerTool()`、`api.log()` | 设置、工具注册和包运行日志 |
| `available()`、`prompt.sections`、`promptSections()` | 可用性检查、提示词片段 |
| `providers['message.owner-check']` | 身份检查及当轮人设 / 规则；接收真实发送者上下文 |
| `activate(ctx)` / `deactivate(ctx)`、定时器 | 按插件和机器人账号保持模块；连接停止、禁用和重新配置时关闭运行时及后台请求 |
| `hooks` | `before-context`、`before-llm-messages`、`before-tool`、`after-tool`、`after-response`；最后一个在实际发送完成后触发，`session.sent` 包含已确认的消息 |
| `wake.burst-policy`、`llm.request-params` | 延迟合并策略和当轮工具列表约束，不能提升模型、账号或会话权限 |
| `friend.request` / `group.request` | 仅处理实际收到的 OneBot 申请；校验开关 / 名单、匹配 flag、持久去重；结果未确认时不自动重试或通知已同意 |
| `api.capability(name)` | 在当前连接选中的扩展之间调用函数或对象能力；例如 `knowledge.hot-trends({action:'status'})` |
| `api.fetch()`，需清单声明 `web_fetch` | 公共 HTTPS 请求；手动重定向、状态 / headers / `arrayBuffer()` / `text()` / `json()` |
| 原包全局 `fetch` / `WebSocket` | 检查源码中的网络依赖并在兼容信息显示；使用相同的公共地址限制，WSS 不读取机器人凭证 |
| `Blob` / `File` / `FormData` / `AbortSignal.timeout` | 真正的二进制与 multipart 请求；单次请求最长 120 秒，单工具最长 160 秒 |
| 工具 `execute(ctx, args)` | 返回 `{content, isError?}`；`ctx.chatKey` 固定为当前会话 |
| `ctx.sender.sendImage(chatKey, {file})` / `sendText(chatKey, text)` | 向当前会话发送并等待结果，不能指定其他群或好友 |
| `ctx.sender.sendTextBatch` / `sendMedia` | 文字批量发送及 `record` 语音；从本包隔离文件读取真实音频字节，按实际格式发送，不把电脑路径交给协议端 |
| `ctx.tasks.watchCover` / `sendCover` / `coverStatus` / `cancelCover`（接口10） | CoverLink 异步翻唱发送；需声明 `cover_delivery`，使用包设置的 HTTPS API。传入 `{jobId, scope}`，scope 必须绑定当前机器人与会话；宿主持久检查、真实回执和发送去重。配置 `autoSend` 控制自动发送，`allowProactive` 控制官机无回复窗口时是否尝试已授权的主动发送。|
| `ctx.onebot` / `ctx.store` | 当前账号受限的 OneBot 接口、当前会话最近消息和图片元数据；不能操作其他账号或任意文件 |
| `node:fs` / `node:fs/promises`、`node:path`、`node:os`、`node:url`、`node:crypto`、`node:buffer` | 同步 / 异步文件、路径、缓存、URLSearchParams、随机 UUID、SHA-256 / SHA-1 / MD5 缓存哈希和 Buffer |
| `node:http` / `node:https` | 客户端 `get` / `request`、请求头、`write` / `end`、响应 `statusCode` / `headers`、`data` / `end` / `error`、取消与超时事件 |
| `node:events`、`node:stream` / `node:stream/promises` | EventEmitter、once、Readable / Writable / Transform / PassThrough、pipe、pipeline、finished、异步迭代 |
| `node:util`、`node:querystring`、`node:string_decoder`、`node:timers` / `node:timers/promises` | 常用 Promise / 回调转换、查询字符串、跨块 UTF-8 解码、定时器和可取消延迟 |

### Node HTTP 客户端与本地运行环境

接口10提供 `ctx.hostCapabilities`，包含 `cover-delivery-v1` 时才可安排翻唱完成后自动发送。`watchCover` 必须在真实当前消息中调用；后台任务不保存 API 密钥，恢复时读取仍启用、仍在当前预设中的 Skill 设置。暂停会话、关闭该 Skill、断开连接或迁移数据时均不发送。手动与自动共用回执记录；发送结果不明时保留 `uncertain` 并停止自动重发。导入同 ID、同类型的 JS ZIP 会原位升级并保留配置与扩展隔离数据；与 JSON 包类型冲突时仍拒绝覆盖。

宿主接口版本5起，以上模块支持 `node:` 前缀和无前缀的 ESM 具名 / 默认导入。`http/https` 使用宿主网络接口，`fs.createReadStream` / `createWriteStream` 使用扩展自己的虚拟文件；不会将电脑上的任意路径交给插件。

```javascript
import https from 'node:https';
import fs from 'node:fs';
import { pipeline } from 'node:stream/promises';

async function download(url) {
  const response = await new Promise((resolve, reject) => {
    const req = https.get(url, resolve);
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('下载超时')));
  });
  if (response.statusCode !== 200) {
    response.resume();
    throw new Error(`HTTP ${response.statusCode}`);
  }
  await pipeline(response, fs.createWriteStream('/tmp/audio.wav'));
  return '/tmp/audio.wav';
}
```

`http.request` / `https.request` 需要调用 `end()`，`get()` 自动调用。`setTimeout` 按 Node 的规则触发 `timeout` 事件，需要由插件调用 `destroy()` 取消；宿主另外保留最长120秒的硬限制。实现的是有界缓冲流：收到完整响应后触发响应和数据事件，不提供实时 SSE / 无限流、原始 socket、自定义连接器或 TLS 证书替换。请求正文最多8 MB、单次响应最多12 MB、写入文件流最多8 MB；全局 `fetch` 仍只支持 HTTPS。HTTP 不允许内网、重定向自动跟随或通过明文传递 Cookie / Authorization；鉴权使用已配置的 HTTPS 服务源。

这不包含本地 Node 服务器或 Python 执行环境。`http.createServer` / `Server` 和 `child_process` 可供依赖检查导入；检查时不监听端口、不执行外部命令，真实调用不会假装成功。需要这些能力的扩展保持关闭，兼容信息列出原因。

例如 `rvc-sing` 原包会注册 `sing` / `sing_status`，但同时需要本地设置网页、系统 Python、RVC / demucs 及音色模型。它使用的是电脑真实目录和外部进程，不能只靠安装 Node 模块在手机或内嵌引擎运行；实际翻唱还需独立的本地服务适配器及上述资源。原 ZIP 可以导入、编辑和导出，源码保持原样。

接口语义参考 [Node HTTP](https://nodejs.org/api/http.html)、[HTTPS](https://nodejs.org/api/https.html) 和 [Stream](https://nodejs.org/api/stream.html) 官方文档；只承诺上面列出的兼容范围。

文件 API 使用虚拟目录：源码在 `/packages/<id>/` 只读，`process.env.QQ_AGENT_DATA_DIR` 为 `/data`，`os.tmpdir()` 为 `/tmp`。可写文件存在 Agent 独立库，按插件和实际机器人账号隔离；重建引擎、重启 App 后保留。它不是电脑真实文件系统，不会暴露原工作区数据库、环境变量、机器人密钥或 AI Key。图片发送读取包的隔离文件，再交给宿主；不会把本地路径交给远端协议端。

这是明确范围的兼容层，**不等于完整 Node.js / npm**：不运行系统命令、原生 `.node` 模块、任意进程或任意 QQ action；不在线安装 `node_modules`。`child_process` 调用 `spawn` 明确失败。原项目配置、价格、工具注册表与图片校验模块使用隔离桥接；`getConfig()` 提供当前扩展设置、显示昵称和价格，不提供账号密钥。`/data/config.json` 只提供虚拟 OCR 入口；`/data/sessions/*.json` 与索引只读映射当前账号和会话的账本，没有真实配置文件路径或 Token。

ZIP 限制 16 MB、解压后 24 MB、300 文件；单图和语音 5 MB；每个执行器有内存、时间和请求数限制。网络不允许访问本机或内网，DNS 结果校验后固定连接，不透传宿主鉴权。包设置中自填的 `apiKey` 仅在请求源与该包自填 `baseOrigin` / 完整 `balanceUrl` 一致时作为 `Authorization`；B站、抖音、贴吧 Cookie 仅发送到相应站点。跳转不自动携带鉴权，不读取模型或机器人的 Key。仅导入你信任的包，资源限制不能替代操作系统级的恶意代码隔离。

包结构示例：

```text
my-skill/
  skill.json
  index.js
  kb/example.json
```

`skill.json`：

```json
{
  "id": "my-skill", "name": "我的 Skill", "apiVersion": 1,
  "entry": "index.js", "permissions": [],
  "settings": {"greeting": "你好"},
  "configSchema": {"greeting": {"type": "string", "label": "问候语"}},
  "prompt": {"sections": [{"id": "guide", "content": "需要问候时调用 my-skill__hello。"}]}
}
```

`index.js`：

```javascript
export function setup(api) {
  api.registerTool({
    id: 'hello', name: '问候', description: '返回配置的问候语',
    parameters: { type: 'object', properties: {} },
    async execute(ctx, args) {
      return { content: api.config().greeting };
    }
  });
}
```

模型侧工具名为 `<包 id>__<工具 id>`，例如 `my-skill__hello`。工具注册和设置表单来自原包，不按包名在应用内硬编码逻辑。

### 命令插件

```json
{
  "schema": 1,
  "id": "hello_world",
  "name": "你好",
  "kind": "plugin",
  "description": "/hello 问候用户",
  "commands": [{
    "prefix": "/hello",
    "handler": {"type": "template", "text": "你好，{{sender.name}}！{{args.text}}"}
  }]
}
```

命令仅匹配完整前缀或前缀后的空白分隔，`/hello2` 不会误触发 `/hello`。群内仍遵守连接设置的 @ / 命令规则、白名单和冷却。插件可独立于自动 AI 回复开启，不消耗模型调用。

### Skill：提示词与模型工具

```json
{
  "schema": 1,
  "id": "clock",
  "name": "当前时间",
  "kind": "skill",
  "description": "查询运行设备的当前时间",
  "prompt": "用户问现在的时间时，调用 current_time。",
  "tools": [{
    "name": "current_time",
    "description": "查询运行设备当前日期与时间",
    "parameters": {"type": "object", "properties": {}, "additionalProperties": false},
    "handler": {"type": "time"}
  }]
}
```

工具名称只使用英文字母、数字、下划线和连字符，同一预设中必须唯一。参数支持 `object`、`array`、`string`、`number`、`integer`、`boolean`、`required` 和 `enum`，嵌套最多六层；不支持 `$ref`。未知参数会被拒绝。

纯提示词文件 `SKILL.md`：

```markdown
---
id: friendly_style
name: 温和表达
description: 让回复更友善、易懂
---
用自然、温和的中文回答。先给出直接答案，再补充必要细节。
```

### HTTP 扩展：接任意自建服务

插件和 Skill 的 handler 都可以改为 HTTP。端点固定在清单中，模型只能填写参数；服务可以自行用 JavaScript、Python、PHP 等实现。示例见 `agent_examples/http-skill.json`。

```json
{
  "type": "http",
  "method": "GET",
  "url": "https://your-service.example/search",
  "headers": {"Authorization": "Bearer {{secret.API_KEY}}"},
  "query": {"q": "{{args.query}}"},
  "resultPath": "data.answer"
}
```

清单同时设置 `"allowedOrigins": ["https://your-service.example"]`。API Key 在扩展编辑器的私有参数里填写 `{"API_KEY":"你的密钥"}`。私有参数只注入 HTTP 请求头，不注入提示词、脚本输入或导出文件。支持 GET / POST、JSON body、query 和点路径 resultPath。请求不跟随重定向，响应有大小与超时限制。

完整占位符（如 `"args": "{{args}}"`）保留对象、数组、数字或布尔类型；嵌入字符串的 `{{args.query}}` 仍转换为文字。服务返回的错误可使用 `"errorPath": "isError"` 将实际失败传回模型。扩展还可声明同一 `allowedOrigins` 内的 `settingsUrl`，卡片会显示通用的“打开设置页”，无需在应用内硬编码插件名称。

宿主接口6支持 `handler.responseType: "audio"`，从 JSON 的 `audioDataPath`（默认 `audioBase64`）读取真实音频。使用现有 WAV / MP3 / SILK / OGG / M4A 校验、5 MB限制和当前会话发送回调，只有取得消息ID才返回成功；工具应声明 `requiresMediaAck: true`。服务错误、取消或无有效音频时不发送，也不把 base64 塞入模型上下文。本地翻唱的 `rvc_cover_send` 是完整示例。

`{{args.xxx}}` 是模型参数或命令参数。命令执行还提供 `sender.id/name`、`session.kind/peerId/name`。HTTP 输出作为资料返回模型，不作为新的系统指令。

### 脚本扩展

`handler.type = "script"`，源码放在 `handler.source`。独立 Hetu 沙箱每次执行最多三秒，不绑定文件系统、进程、官方机器人凭证或任意网络。网络需求使用 HTTP handler。示例源码：

```javascript
external fun json_decode(value)
external fun json_encode(value)
fun run(input) {
  final event = json_decode(input)
  return json_encode({text: event.args.text})
}
```

输入是 JSON 字符串；返回 JSON 对象或 JSON 字符串。插件返回 `text` / `reply` 作为回复，可以额外返回 `state` 保存当前插件、当前账号与会话的独立状态。Skill 返回 `text` / `result` 给模型。额外提供 `now_iso()`。输出最多 64 KB，不支持外部脚本 import / require。

## Linux 网页版

在已登录的管理首页点击 **QQ Agent**，打开独立的 `agent.html` 页面。仍使用管理员密码和安全入口；Agent API 位于安全入口下的 `api/agent/`。模型调用及 WS 监听在服务器执行，网页关闭不影响已启动的 Agent 连接。手动重启服务后，首次进入 Agent 页面才加载 Agent 配置并执行已选择的自动连接。

网页端提供连接、模型、预设、插件 / Skill 配置、文本收发和媒体消息展示；图片文件上传、引用 / @ 操作及合并转发展开目前使用客户端工作区。网页媒体链接还需符合浏览器的 HTTPS 安全限制。

官方 HTTP 管理端口默认 23336，Agent 的反向 WS 默认 23337。配置监听端口被占用时会显示错误，不会停止原网页服务。

## 存储与参考

### 宿主接口8：扩展复用内置服务

JavaScript原包可使用 `ctx.qq.getUserInfo(userId?)` / `getUserAvatar(userId?)` / `getGroupInfo()`；`ctx.store.activeMembers(chatKey, limit)`、`listChats()`、`getChatMeta(key)` 和带 `offset` 的 `recent()` 只返回当前机器人的已知资料。`ctx.sender.sendImage` 接受 `{file}`、`{dataUrl}`、`{url}` 或字符串；URL经公共地址校验后发送。`sendTextBatch` 支持真实 `atUserId` / `replyToMessageId`，`sender.poke` 仅OneBot可用。

`ctx.memory.query()` 读取当前会话印象；`append` / `remove` 是异步操作，需要 `await`。`ctx.reminders.pending` / `set` / `cancel` 也需要 `await`。VFS文件仍在扩展隔离目录中，不开放电脑任意路径。

可从旧项目的 `src/llm.js` 导入 `chatCompletion(options)`，或调用 `ctx.llm.complete(options)`。宿主代理当前预设模型；`mode: "vision"` 使用预设的视觉 / 转述模型，统计真实用量。扩展拿不到模型API Key，不能通过参数改用其他账号凭证。`src/web-search.js` 的 `webSearch` / `webFetch` / `searchImages` 走当前预设的Bing开关；`src/safe-fetch.js` 提供公共HTTPS下载、大小限制及写入扩展VFS的接口。只兼容这些明确接口，不读取原应用数据目录。

Agent 使用独立 `qqm_agent_v1` 数据文件，不读写官方聊天库。模型密钥与协议令牌只存于本地 / 服务器私有配置中，不进行云同步。扩展导出不包含私有参数。不要把含密钥的数据库当示例上传到仓库。

设计参考 [K0nd1us/QQ-agent](https://github.com/K0nd1us/QQ-agent)，上游为 MIT 许可；本模块以独立 Dart 实现适配现有 GPL-2.0 应用，保留参考项目署名与许可说明。协议依据 [OneBot 11](https://github.com/botuniverse/onebot-11)。
