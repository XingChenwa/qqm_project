# 原版 Node / Yunzai 插件

适用于包含原包加载器的 1.4.1-beta.5+39 及后续客户端。此前版本请先更新客户端。

原机器人工作台支持直接导入作者提供的 ZIP、单个 `.js/.mjs/.cjs` 文件，或公开 GitHub 仓库。原版入口、源码、依赖和配置保存在磁盘上，由通用 Node 运行器加载。它与 QQ Agent 的插件 / Skill 区域独立。

## 安装与使用

1. 打开 **插件中心 → 导入原包**。
2. 选择原版 ZIP / JS，或填写 `https://github.com/作者/仓库`，点击下载并检查。仓库方式读取当前默认分支；需要固定版本时请导入对应版本 ZIP。
3. 检查插件名称、版本、入口、许可及 npm 依赖。预览不会执行原包。
4. 确认信任源码后安装。原版 Node 代码和 npm 安装脚本拥有当前系统用户的文件、网络和进程权限，不能作为手机脚本沙箱看待。
5. 安装完成默认关闭。选择机器人，在卡片的 **配置 → 原插件配置文件** 中修改作者的原生 YAML / JSON；文件内容按原样保存，不强制转换成应用专用格式。
6. 在 **主人与发送权限** 中填写当前 AppID 的主人 OpenID（如需要），然后手动启用。使用原插件的帮助命令。`#命令` 在官方 QQ 聊天中也可尝试 `/命令`。

桌面端点击 **打开源码文件夹**，可使用自己的编辑器修改源文件；完成后点击 **重新加载源码**。卡片菜单也提供 **安装依赖**，用于恢复备份、切换系统或修改 package.json 后重新安装依赖。网页和手机可通过内置文件列表编辑原文件；内部编辑器只打开不超过 2 MB 的 UTF-8 文本，桌面外部编辑不受此大小限制。

## 以 Steam 插件为例

在原包导入框填写 [XasYer/steam-plugin](https://github.com/XasYer/steam-plugin)，或导入作者的源码 ZIP。进入配置文件后，按照原仓库 README 填写 Steam Web API Key 等原生参数，使用原版帮助命令查看功能。Key 填在本机配置文件中，不要写进分享包或反馈日志。

这不是专用 Steam 适配器。运行器不包含 Steam 命令、业务代码或 Key 字段；其他符合接口范围的 Node 插件使用同一流程。回归测试使用原版 Steam 包 1.13.2，验证了 22 个模块加载、原生 YAML 配置和帮助菜单图片生成。需要真实账号或 Web API Key 的在线查询仍取决于原插件配置和上游服务。

## 运行环境与手机

- **Windows / macOS / Linux**：优先使用已安装的 Node.js 22 及更新版本；没有时下载官方 Node 22 LTS，校验官方 SHA256 后使用。首次使用会下载通用 npm 依赖。需要联网，系统或杀毒软件阻止子进程时会显示运行环境错误。
- **原生 npm 模块**：由插件自己的 package.json 安装。SQLite、Canvas 等依赖可能需要对应系统的预编译包或编译工具；失败时安装卡片会保留具体阶段提示，不会伪装成安装成功。
- **图片模板渲染**：使用系统 Chrome、Edge 或 Chromium；服务器请安装 Chromium。也可设置 `QQM_CHROME` 为浏览器可执行文件路径。找不到浏览器会显示明确错误。
- **Android / iOS**：此 Node 运行器需要外部进程环境。点击 **导入原包 → Node 运行环境**，填写远程运行器的 HTTPS 地址及它生成的令牌。原包、npm 依赖和数据保存在那台运行器主机，手机仍可安装、编辑和启停。不声称在手机内模拟完整 Node/npm。

开发者可将仓库 `assets/node_plugins/` 复制到有 Node.js 22+ 的主机，进入目录运行 `npm ci --omit=dev`，再启动：

```sh
node server.mjs --root /opt/qqm-node-data --port 23342 --listen 127.0.0.1
```

首次启动在数据目录生成 `connection.json`。在主机上读取其中的令牌，保留私密；不要发到聊天或提交 Git。使用反向代理提供 HTTPS，并将代理入口指向回环地址 `127.0.0.1:23342`。在客户端填写该 HTTPS 根地址及令牌。此接口只供应用连接，不是公开网页。

## 当前提供的原版接口

| 接口 | 支持范围 |
| --- | --- |
| 入口 | package.json 的 main，或 index.js / index.mjs / main.js，再或 apps 下的 JS；保留原包文件结构 |
| JavaScript | 真实 Node.js，原生 `node:fs`、`node:http`、`node:child_process` 等；npm 依赖由原包声明 |
| 常见导入 | `lib/plugins/plugin.js`、`lib/common/common.js`、`lib/puppeteer/puppeteer.js`、`#yunzai`；缺少 icqq/oicq 模块时提供 segment 适配，不提供个人 QQ 登录 |
| plugin 类 | name、event、priority、rule、init、task、setContext、finish；原包函数与类保持原样 |
| 消息事件 | e.msg/raw_message、群/单聊、发送者 OpenID/昵称/角色、@ 列表、附件、self_id、isMaster；仅适配宿主收到的消息事件 |
| 回复 | e.reply、Bot.pickGroup/pickFriend/pickUser 的 sendMsg；文字、图片、@、Markdown；合并转发渲染为图片 |
| 群成员 / 撤回 | 已授权的官方群成员查询；仅机器人自己发送、仍在平台时限内的消息撤回 |
| 配置 / 数据 | 插件文件读写、按 AppID 隔离；提供持久化的 Redis 常用键值/集合/哈希接口，并非完整 Redis 服务器 |
| 图片模板 | art-template、Puppeteer 适配；使用实际浏览器生成图片并上传真实字节 |

官方 QQ 的 OpenID 不能直接当普通 QQ 号使用。依赖个人 QQ 协议、任意 icqq API、其他 Yunzai 插件内部代码或额外私有服务的功能，需要相应适配，原包导入不会凭空提供这些能力。不支持的消息段或宿主接口会显示具体缺项，不伪造发送成功。

群回复、Markdown、成员资料、主动推送仍受 QQ 官方机器人权限、配额及回复时限约束。主动消息需同时在插件权限中打开并获得 QQ 平台授权。主人权限使用当前 AppID 的 OpenID；不要填另一个机器人的 OpenID。

## 开发最小示例

可直接导入 [original-example.js](../plugins/examples/original_node/original-example.js)。它使用原版 plugin 类和真实 Node 文件 API：

```js
import fs from 'node:fs/promises'

export class Example extends plugin {
  constructor() {
    super({ name: '原版示例', event: 'message', rule: [
      { reg: '^#原包计数$', fnc: 'count' }
    ] })
  }
  async count(e) {
    await fs.mkdir('data', { recursive: true })
    const file = 'data/example-count.txt'
    const value = Number(await fs.readFile(file, 'utf8').catch(() => '0')) + 1
    await fs.writeFile(file, String(value))
    await e.reply(`本机器人已调用 ${value} 次`)
    return true
  }
}
```

有多个文件或额外 npm 依赖时，提供 ZIP，保留 package.json、入口、apps、config、resources 等作者目录。不携带 node_modules、.git、个人配置密钥或登录状态；依赖在目标机器安装。对外分享原包 ZIP / 源码，卡片中的安装元数据 JSON 不能代替源码导入。

## 数据隔离和迁移

本机应用数据目录下的 `node_plugins/packages/<插件 ID>/source/` 保存原包；`accounts/<AppID 哈希>/plugins/<原包目录>/` 保存该机器人的独立配置与运行数据。共用源码目录修改后重新加载，会保留每个账户的配置和数据。

**设置 → 数据迁移** 的完整 ZIP 包含本机原包、账户配置、运行数据及运行器连接设置，不包含 node_modules、Node 可执行文件、浏览器和缓存。恢复后在卡片上 **安装依赖** 再启用。ZIP 可能含插件 API Key 和远程运行器令牌，请私密保管。

使用远程运行器时，本地 ZIP 只备份连接设置；远程原包和数据需在运行器主机另行备份。停用和切换 AppID 会停止旧进程；卸载原包移入本机运行器的 `removed/` 目录，保留可恢复副本。
