"use strict";
// This page owns its state and API routes; it never loads the official app.js.
const $ = (id) => document.getElementById(id);
const labels = [
  "聊天",
  "机器人连接",
  "AI 模型",
  "预设",
  "AI 插件",
  "Skills",
  "运行日志",
];
let state,
  tab = 0,
  account = "",
  session = "",
  busy = false,
  loading = false,
  forceBottom = false,
  lastMessages = "",
  chatDraft = "";
function el(tag, value, className) {
  const n = document.createElement(tag);
  if (value != null) n.textContent = value;
  if (className) n.className = className;
  return n;
}
function button(label, fn, primary = false) {
  const n = el("button", label, primary ? "primary" : "");
  n.type = "button";
  n.addEventListener("click", () => run(fn, n));
  return n;
}
function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(b, (v) => v.toString(16).padStart(2, "0")).join("");
}
async function api(route, value) {
  const res = await fetch(`./api/agent/${route}`, {
    method: value === undefined ? "GET" : "POST",
    credentials: "same-origin",
    cache: "no-store",
    headers: {
      "X-QQM-Request": "1",
      ...(value === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(value === undefined ? {} : { body: JSON.stringify(value) }),
  });
  const result = await res.json();
  if (!res.ok) {
    if (res.status === 401 || res.status === 428)
      $("status").textContent = "请返回官方机器人首页完成管理员登录。";
    throw new Error(result.error || "Agent 请求失败");
  }
  return result;
}
function notify(message) {
  $("notice-text").textContent = String(message);
  if (!$("notice").open) $("notice").showModal();
}
async function copyText(value) {
  if (navigator.clipboard && isSecureContext)
    return navigator.clipboard.writeText(value);
  const input = el("textarea");
  input.value = value;
  input.readOnly = true;
  document.body.append(input);
  input.select();
  const copied = document.execCommand("copy");
  input.remove();
  if (!copied) throw new Error("浏览器不允许自动复制，请手动选择日志。");
}
async function run(fn, node) {
  if (node) node.disabled = true;
  try {
    await fn();
  } catch (e) {
    notify(e.message || "操作失败");
  } finally {
    if (node?.isConnected) node.disabled = false;
  }
}
$("notice-close").onclick = () => $("notice").close();
$("refresh").onclick = () => run(() => refresh(true));
$("cancel").onclick = () => {
  if (!busy) $("editor").close();
};
$("editor").addEventListener("cancel", (e) => {
  if (busy) e.preventDefault();
});
for (let i = 0; i < labels.length; i++)
  $("tabs").append(
    button(labels[i], () => {
      tab = i;
      render();
    }),
  );

async function refresh(full = false) {
  if (loading) return;
  loading = true;
  try {
    const value = await api("state"),
      changed = !state || value.revision !== state.revision;
    state = value;
    $("status").textContent =
      `Agent 机器人 ${state.connections.length} 个 · AI 请求 ${state.usage.calls || 0} 次`;
    if (!$("editor").open && (full || changed)) {
      if (
        tab === 0 &&
        $("messages") &&
        !full &&
        state.sessions.some((s) => s.key === session)
      ) {
        refreshSidebar();
        await refreshMessages();
      } else render();
    }
  } finally {
    loading = false;
  }
}
function heading(title, subtitle, actions = []) {
  const wrap = el("div", null, "heading");
  wrap.append(el("h2", title), ...actions);
  $("page").append(wrap, el("p", subtitle, "muted"));
}
function card(title, subtitle, actions, extra) {
  const node = el("article", null, "card");
  node.append(el("h3", title), el("p", subtitle));
  if (extra) node.append(extra);
  const bar = el("div", null, "actions");
  bar.append(...actions);
  node.append(bar);
  return node;
}
function options(list) {
  return Object.fromEntries(list.map((x) => [x.id, x.name]));
}
function field(key, label, type = "text", choices = {}, hint = "", when = {}) {
  return { key, label, type, choices, hint, when };
}
async function save(route, value) {
  await api(route, value);
  await refresh(true);
}
function edit(title, value, fields, submit, help = "") {
  $("editor-title").textContent = title;
  $("editor-help").textContent = help;
  $("form-error").textContent = "";
  $("fields").replaceChildren();
  const inputs = new Map(),
    containers = new Map();
  const advanced = el("details", null, "advanced");
  advanced.append(el("summary", "高级设置"));
  for (const f of fields) {
    const label = el("label", null, "field");
    label.append(el("span", f.label));
    const node = el(
      f.type === "code" || f.type === "multiline" || f.type === "list"
        ? "textarea"
        : f.type === "select" || f.type === "multi"
          ? "select"
          : "input",
    );
    node.setAttribute("aria-label", f.label);
    if (f.type === "select" || f.type === "multi") {
      for (const [k, v] of Object.entries(f.choices)) {
        const o = el("option", v);
        o.value = k;
        if (f.type === "multi") o.selected = (value[f.key] || []).includes(k);
        node.append(o);
      }
      if (f.type === "multi") node.multiple = true;
      else node.value = value[f.key] ?? Object.keys(f.choices)[0];
    } else if (f.type === "bool") {
      node.type = "checkbox";
      node.checked = value[f.key] === true;
    } else {
      if (node.tagName === "INPUT")
        node.type =
          f.type === "secret"
            ? "password"
            : f.type === "number"
              ? "number"
              : "text";
      if (f.type === "number") node.step = "any";
      node.value =
        f.type === "ids" || f.type === "list"
          ? (value[f.key] || []).join(f.type === "list" ? "\n" : ", ")
          : (value[f.key] ?? "");
    }
    if (f.type === "code") {
      node.className = "code";
      node.spellcheck = false;
    }
    if (f.type === "multiline" || f.type === "list")
      node.rows = f.type === "list" ? 3 : 5;
    if (f.type === "secret") node.autocomplete = "off";
    label.append(node);
    if (f.hint) {
      const hint = el("small", f.hint);
      hint.id = `hint-${f.key}`;
      node.setAttribute("aria-describedby", hint.id);
      label.append(hint);
    }
    (f.advanced ? advanced : $("fields")).append(label);
    inputs.set(f.key, node);
    containers.set(f.key, label);
  }
  if (fields.some((f) => f.advanced)) $("fields").append(advanced);
  const collect = () => {
    const result = { ...value };
    for (const f of fields) {
      const n = inputs.get(f.key);
      if (containers.get(f.key).hidden) continue;
      result[f.key] =
        f.type === "bool"
          ? n.checked
          : f.type === "number"
            ? f.nullable && !n.value.trim()
              ? null
              : Number(n.value)
            : f.type === "multi"
              ? Array.from(n.selectedOptions, (o) => o.value)
              : f.type === "ids"
                ? n.value.split(/[,，\s]+/).filter(Boolean)
                : f.type === "list"
                  ? [
                      ...new Set(
                        n.value
                          .split(/[,，\r\n]+/)
                          .map((v) => v.trim())
                          .filter(Boolean),
                      ),
                    ]
                  : n.value;
    }
    return result;
  };
  for (const f of fields.filter((f) => f.type === "model")) {
    const fetchButton = button("获取并选择模型", async () => {
      if (busy) return;
      busy = true;
      fetchButton.disabled = true;
      $("save").disabled = true;
      $("form-error").textContent = "";
      try {
        const models = (await api("provider/models", { value: collect() }))
          .result;
        if (!models.length)
          throw new Error("服务未提供模型列表，可手动填写模型 ID。");
        const old = containers.get(f.key).querySelector(".model-options");
        old?.remove();
        const list = el("div", null, "model-options"),
          search = el("input"),
          select = el("select");
        search.placeholder = "搜索模型";
        search.setAttribute("aria-label", "搜索模型");
        select.size = 6;
        select.setAttribute("aria-label", "可用模型");
        const filter = () => {
          select.replaceChildren();
          for (const model of models.filter((v) =>
            v.toLowerCase().includes(search.value.toLowerCase()),
          )) {
            const o = el("option", model);
            o.value = model;
            select.append(o);
          }
        };
        search.oninput = filter;
        filter();
        const choose = () => {
          if (select.value) {
            inputs.get(f.key).value = select.value;
            list.remove();
          }
        };
        select.ondblclick = choose;
        list.append(search, select, button("使用所选模型", choose));
        containers.get(f.key).append(list);
      } catch (e) {
        $("form-error").textContent = e.message;
      } finally {
        busy = false;
        fetchButton.disabled = false;
        $("save").disabled = false;
      }
    });
    containers.get(f.key).append(fetchButton);
  }
  const visibility = () => {
    const values = { ...value };
    for (const f of fields)
      values[f.key] =
        f.type === "bool" ? inputs.get(f.key).checked : inputs.get(f.key).value;
    for (const f of fields)
      containers.get(f.key).hidden = !Object.entries(f.when || {}).every(
        ([key, expected]) => values[key] === expected,
      );
  };
  for (const node of inputs.values())
    node.addEventListener("change", visibility);
  visibility();
  $("form").onsubmit = async (e) => {
    e.preventDefault();
    if (busy) return;
    busy = true;
    $("save").disabled = true;
    $("form-error").textContent = "";
    try {
      await submit(collect());
      $("editor").close();
      await refresh(true);
    } catch (error) {
      $("form-error").textContent = error.message;
    } finally {
      busy = false;
      $("save").disabled = false;
    }
  };
  $("editor").showModal();
}
function connectionEditor(c) {
  edit(
    "机器人连接",
    c
      ? { protocol: "onebot", ...c }
      : {
          id: uuid(),
          protocol: "onebot",
          name: "我的 QQ Agent",
          selfId: "",
          mode: "forward",
          url: "ws://127.0.0.1:3001/",
          host: "127.0.0.1",
          port: 23337,
          path: "/onebot/v11",
          token: uuid() + uuid(),
          presetId: "assistant",
          privateReply: true,
          resolveOfficialProfiles: true,
          useOiapiNickname: true,
          groupTrigger: "mention",
          commandPrefix: "/ai",
          cooldownSeconds: 3,
          batchWindowMs: 2000,
        },
    [
      field("name", "名称"),
      field("protocol", "机器人类型", "select", {
        onebot: "OneBot 11 · QQ 协议端",
        qqbot: "QQBot · 官方机器人",
      }),
      field("selfId", "机器人真实 QQ 号", "text", {}, "", {
        protocol: "onebot",
      }),
      field("appId", "QQBot AppID", "text", {}, "", { protocol: "qqbot" }),
      field(
        "clientSecret",
        "QQBot ClientSecret",
        "secret",
        {},
        c?.hasClientSecret ? "留空保留原密钥" : "填写官方开放平台的机器人密钥",
        { protocol: "qqbot" },
      ),
      field("clearClientSecret", "清除原机器人密钥", "bool", {}, "", {
        protocol: "qqbot",
      }),
      field("sandbox", "使用官方沙箱环境", "bool", {}, "", {
        protocol: "qqbot",
      }),
      field(
        "mode",
        "方式",
        "select",
        {
          forward: "正向 WS · 连接协议端",
          reverse: "反向 WS · 服务器监听",
        },
        "",
        { protocol: "onebot" },
      ),
      field("url", "正向 WS 通用地址", "text", {}, "", {
        protocol: "onebot",
        mode: "forward",
      }),
      field("host", "反向监听 IP", "text", {}, "", {
        protocol: "onebot",
        mode: "reverse",
      }),
      field("port", "反向监听端口", "number", {}, "", {
        protocol: "onebot",
        mode: "reverse",
      }),
      field("path", "反向 WS 路径", "text", {}, "支持 /onebot/v11 或 /", {
        protocol: "onebot",
        mode: "reverse",
      }),
      field(
        "token",
        "访问令牌",
        "secret",
        {},
        c?.hasToken ? "留空保留原令牌" : "与协议端一致；仅本机监听可留空",
        { protocol: "onebot" },
      ),
      field("clearToken", "清除原令牌（仅本机或正向可用）", "bool", {}, "", {
        protocol: "onebot",
      }),
      field("autoConnect", "打开 Agent 时自动连接", "bool"),
      field("aiEnabled", "自动 AI 回复", "bool"),
      field("presetId", "默认预设", "select", options(state.presets)),
      field("privateReply", "允许私聊自动处理", "bool"),
      field(
        "resolveOfficialProfiles",
        "自动同步官机会话资料",
        "bool",
        {},
        "群名 / 成员资料异步查询，不阻止 AI 回复；需平台开放查询权限。",
        { protocol: "qqbot" },
      ),
      field(
        "useOiapiNickname",
        "补全官机单聊昵称",
        "bool",
        {},
        "事件未返回昵称时使用 OIAPI，仅提交 AppID 和 OpenID。",
        { protocol: "qqbot" },
      ),
      field("groupTrigger", "群聊触发", "select", {
        mention: "被 @ 或额外唤醒前缀",
        command: "命令或额外唤醒前缀",
        all: "全部消息",
        off: "关闭",
      }),
      field("commandPrefix", "AI 命令"),
      field(
        "extraWakePrefixes",
        "额外唤醒前缀",
        "list",
        {},
        "一行一个，如小助手或 hey bot，最多20个；不绕过群聊关闭和白名单。QQBot 需开通接收全量消息才能收到未 @ 消息。",
      ),
      field("cooldownSeconds", "冷却秒数", "number"),
      field(
        "batchWindowMs",
        "连发等待窗口（毫秒，50–5000）",
        "number",
        {},
        "仅启用并选中连发策略插件后生效，默认2000；封顶由插件设置决定。",
      ),
      field("groupAllowlist", "允许的群号 / 群 OpenID（空为不限）", "ids"),
      field("userAllowlist", "允许的 QQ 号 / 用户 OpenID（空为不限）", "ids"),
      field(
        "pluginIds",
        "启用的命令插件",
        "multi",
        options(
          state.extensions
            .filter((x) => x.manifest.kind === "plugin")
            .map((x) => x.manifest),
        ),
      ),
    ].map((f) => ({
      ...f,
      advanced: [
        "privateReply",
        "resolveOfficialProfiles",
        "useOiapiNickname",
        "groupTrigger",
        "commandPrefix",
        "extraWakePrefixes",
        "cooldownSeconds",
        "batchWindowMs",
        "groupAllowlist",
        "userAllowlist",
        "pluginIds",
        "clearToken",
        "clearClientSecret",
      ].includes(f.key),
    })),
    (value) => api("connection/save", { value }),
    "Agent 独立保存连接与聊天。QQBot 填写 AppID 和密钥；OneBot 选择 WS 方式后仅填写对应参数。保存后需重新启动连接。",
  );
}
function providerEditor(p) {
  edit(
    "AI 模型",
    p || {
      id: uuid(),
      name: "我的模型",
      baseUrl: "http://127.0.0.1:11434/v1",
      model: "",
      tools: true,
      timeoutSeconds: 60,
    },
    [
      field("name", "配置名称"),
      field(
        "baseUrl",
        "接口根地址",
        "text",
        {},
        "包含服务要求的 /v1，不附加 /chat/completions",
      ),
      field(
        "apiKey",
        "API Key",
        "secret",
        {},
        p?.hasApiKey ? "留空保留原密钥" : "本地免鉴权模型可以留空",
      ),
      field("clearKey", "清除原密钥", "bool"),
      field("model", "模型 ID", "model"),
      field("tools", "模型支持工具调用", "bool"),
      field(
        "vision",
        "支持图片输入（视觉模型）",
        "bool",
        {},
        "模型需确实支持图片。可直接看图，也可供预设选择为图片转述模型。",
      ),
      field("timeoutSeconds", "超时秒数", "number"),
      ...[
        ["inputPrice", "输入价格（元 / 百万 token）"],
        ["outputPrice", "输出价格（元 / 百万 token）"],
        ["cachedPrice", "缓存命中价格（元 / 百万 token）"],
      ].map(([key, label]) => ({
        ...field(
          key,
          label,
          "number",
          {},
          "费用统计使用；留空为未配置，0 表示免费。",
        ),
        nullable: true,
      })),
    ].map((f) => ({
      ...f,
      advanced: [
        "tools",
        "vision",
        "timeoutSeconds",
        "clearKey",
        "inputPrice",
        "outputPrice",
        "cachedPrice",
      ].includes(f.key),
    })),
    (value) => api("provider/save", { value }),
  );
}
function presetEditor(p) {
  edit(
    "AI 预设",
    {
      imageDescriptionProviderId: "",
      imageMaxEdge: 1536,
      webSearchEnabled: false,
      timeAwareness: true,
      showReasoning: false,
      multiMessageReply: false,
      readMessageContext: true,
      maxReplyMessages: 3,
      replyIntervalMs: 700,
      ...(p || {
        id: uuid(),
        name: "新预设",
        prompt: "",
        temperature: 0.7,
        maxTokens: 2048,
        historyMessages: 16,
      }),
    },
    [
      field("name", "预设名称"),
      field("providerId", "模型", "select", {
        "": "请选择",
        ...options(state.providers),
      }),
      field(
        "imageDescriptionProviderId",
        "图片转述模型",
        "select",
        {
          "": "不转述 · 主模型支持视觉时直接看图",
          ...options(state.providers.filter((p) => p.vision)),
        },
        "转述模型先看图，再把描述交给主模型。请先开启模型的图片输入能力；转述会额外调用模型。",
      ),
      field("prompt", "人设 / 提示词", "multiline"),
      field(
        "readMessageContext",
        "读取引用与聊天记录",
        "bool",
        {},
        "仅读取平台提供的内容，或同会话已保存的本地引用；长记录会增加输入 token，超出预算会截断。",
      ),
      field(
        "multiMessageReply",
        "分多条消息回复",
        "bool",
        {},
        "一次模型请求生成多条，不为每条重新请求模型；总 token 开销取决于总字数和历史上下文。默认关闭。",
      ),
      field(
        "maxReplyMessages",
        "每轮最多发送几条",
        "number",
        {},
        "2–5，默认3；官机额度不足会合并内容。",
        { multiMessageReply: true },
      ),
      field(
        "replyIntervalMs",
        "分条发送间隔（毫秒）",
        "number",
        {},
        "0–3000，默认700；等待平台回执后发送下一条。",
        { multiMessageReply: true },
      ),
      field(
        "webSearchEnabled",
        "网页搜索 · Bing",
        "bool",
        {},
        "提供 web_search / web_fetch，需模型支持工具调用。公开网页解析可能受网络、验证或改版影响。",
      ),
      field(
        "timeAwareness",
        "现实世界时间感知",
        "bool",
        {},
        "提供服务器的日期、时区和消息时间，不是联网校时。",
      ),
      field(
        "showReasoning",
        "显示思考内容",
        "bool",
        {},
        "仅折叠显示模型接口实际返回的内容，不发送到 QQ，不要求披露隐藏思考；接口未提供时不显示。",
      ),
      field(
        "imageMaxEdge",
        "输入图片最大边长（像素）",
        "number",
        {},
        "256–4096，默认1536；等比缩小，不放大小图。GIF / WebP 读取首帧。",
      ),
      field("temperature", "温度", "number"),
      field("maxTokens", "最大输出 tokens", "number"),
      field("historyMessages", "历史条数", "number"),
      field(
        "skillIds",
        "使用的 Skill",
        "multi",
        options(
          state.extensions
            .filter((x) => x.manifest.kind === "skill")
            .map((x) => x.manifest),
        ),
      ),
    ].map((f) => ({
      ...f,
      advanced: [
        "temperature",
        "maxTokens",
        "historyMessages",
        "imageMaxEdge",
        "maxReplyMessages",
        "replyIntervalMs",
      ].includes(f.key),
    })),
    (value) => api("preset/save", { value }),
  );
}
function extensionEditor(e, kind) {
  const manifest = e?.manifest || {
    schema: 1,
    id: `my_${kind}_${Date.now()}`,
    name: "我的扩展",
    kind,
    description: "功能说明",
    ...(kind === "skill"
      ? { prompt: "请简洁回答", tools: [] }
      : {
          commands: [
            {
              prefix: "/hello",
              handler: { type: "template", text: "你好，{{sender.name}}！" },
            },
          ],
        }),
  };
  edit(
    "Agent 扩展源码",
    {
      source: JSON.stringify(manifest, null, 2),
      enabled: e?.enabled || false,
      secrets: "",
    },
    [
      field("source", "JSON / YAML 清单", "code"),
      field(
        "secrets",
        "私有参数 JSON",
        "secret",
        {},
        "留空保留；{} 清空。仅供 HTTP 请求头的 {{secret.KEY}} 使用。",
      ),
      field("enabled", "启用", "bool"),
    ],
    (value) =>
      api("extension/save", {
        ...value,
        ...(value.secrets.trim()
          ? { secrets: JSON.parse(value.secrets) }
          : { secrets: undefined }),
      }),
    "命令插件用于连接；Skill 用于 AI 预设。源码独立于官方机器人插件。",
  );
}
async function remove(route, id) {
  if (confirm("确定移除此 Agent 配置？")) await save(route, { id });
}
function render() {
  if (!state) return;
  Array.from($("tabs").children).forEach((n, i) =>
    n.classList.toggle("active", i === tab),
  );
  $("page").replaceChildren();
  if (tab === 0) {
    renderChat();
    return;
  }
  if (tab === 6) {
    heading(
      "运行日志",
      "记录收信、触发判定、模型请求及平台回执；不记录密钥或聊天正文",
      [
        button("复制日志", () =>
          copyText(
            state.logs
              .map(
                (x) =>
                  `${x.time} [${x.level}] [${x.connectionName || "Agent"}] [${x.stage || ""}] ${x.message}`,
              )
              .join("\n"),
          ),
        ),
      ],
    );
    for (const l of [...state.logs].reverse())
      $("page").append(
        el(
          "div",
          `${l.time} [${l.connectionName || "Agent"}] [${l.stage || l.level}] ${l.message}`,
          `log ${l.level}`,
        ),
      );
    return;
  }
  const add =
    tab === 1
      ? () => connectionEditor()
      : tab === 2
        ? () => providerEditor()
        : tab === 3
          ? () => presetEditor()
          : () => extensionEditor(null, tab === 4 ? "plugin" : "skill");
  heading(
    labels[tab],
    tab === 1
      ? "QQBot 官方 / OneBot 11 接入，Agent 数据独立保存"
      : tab === 4 || tab === 5
        ? "导入后默认关闭；启用后在连接或预设中选择"
        : "配置你的 AI 工作方式",
    [
      button("＋ 新建", add, true),
      ...(tab === 4 || tab === 5 ? [button("导入文件", importExtension)] : []),
    ],
  );
  const grid = el("div", null, "grid");
  $("page").append(grid);
  if (tab === 1)
    for (const c of state.connections)
      grid.append(
        card(
          c.name,
          `${c.nickname || ""} · ${c.protocol === "qqbot" ? "QQBot AppID" : "OneBot QQ"} ${c.selfId}\n${c.status}\n${c.protocol === "qqbot" ? "官方 WebSocket 网关" : c.mode === "reverse" ? `监听 ${c.host}:${c.port}${c.path}` : c.url}`,
          [
            button(
              c.started ? "停止" : "启动",
              () => save(c.started ? "disconnect" : "connect", { id: c.id }),
              true,
            ),
            button("配置", () => connectionEditor(c)),
            ...(c.protocol === "qqbot"
              ? []
              : [button("同步好友与群", () => save("contacts", { id: c.id }))]),
            button("移除", () => remove("connection/delete", c.id)),
          ],
        ),
      );
  if (tab === 2)
    for (const p of state.providers)
      grid.append(
        card(p.name, `${p.model}\n${p.baseUrl}`, [
          button("编辑", () => providerEditor(p)),
          button("测试", async () =>
            notify((await api("provider/test", { id: p.id })).result),
          ),
          button("模型列表", async () =>
            notify(
              JSON.stringify(
                (await api("provider/models", { id: p.id })).result,
                null,
                2,
              ),
            ),
          ),
          button("删除", () => remove("provider/delete", p.id)),
        ]),
      );
  if (tab === 3)
    for (const p of state.presets)
      grid.append(
        card(p.name, p.prompt, [
          button("编辑", () => presetEditor(p)),
          button("复制", () =>
            presetEditor({ ...p, id: uuid(), name: p.name + " 副本" }),
          ),
          button("删除", () => remove("preset/delete", p.id)),
        ]),
      );
  if (tab === 4 || tab === 5)
    for (const e of state.extensions.filter(
      (e) => e.manifest.kind === (tab === 4 ? "plugin" : "skill"),
    )) {
      const m = e.manifest;
      grid.append(
        card(
          m.name,
          `${m.description || ""}\n${e.enabled ? "已启用" : "已关闭"}\n${m.runtime === "qq-agent-js" ? { ready: "导入检查通过", partial: "部分能力可用", blocked: "需要宿主适配" }[m.compatibility?.state] || "尚未检查兼容情况" : ""}\n网络访问：${extensionNetwork(m)}`,
          [
            button(e.enabled ? "关闭" : "启用", () =>
              m.runtime === "qq-agent-js"
                ? save("extension/configure", { id: m.id, enabled: !e.enabled })
                : save("extension/save", {
                    source: JSON.stringify(m),
                    enabled: !e.enabled,
                  }),
            ),
            button(m.runtime === "qq-agent-js" ? "插件设置" : "编辑源码", () =>
              m.runtime === "qq-agent-js"
                ? packageSettings(e)
                : extensionEditor(e, m.kind),
            ),
            ...(m.runtime === "qq-agent-js"
              ? [
                  button("查看 / 编辑文件", () => packageFiles(e)),
                  button("兼容情况", () =>
                    notify(
                      [
                        ...(m.compatibility?.blockers || []),
                        ...(m.compatibility?.warnings || []),
                      ].join("\n") ||
                        "导入检查通过；实际外部服务仍以执行结果为准。",
                    ),
                  ),
                ]
              : []),
            button("导出", () =>
              m.runtime === "qq-agent-js" ? exportPackage(e) : download(m),
            ),
            button("删除", () => remove("extension/delete", m.id)),
          ],
        ),
      );
    }
}
function download(manifest) {
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(manifest, null, 2)], { type: "application/json" }),
  );
  const a = el("a");
  a.href = url;
  a.download = `${manifest.id}.json`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function importExtension() {
  const input = el("input");
  input.type = "file";
  input.accept = ".zip,.json,.yaml,.yml,.md";
  input.onchange = () =>
    run(async () => {
      const f = input.files[0];
      if (!f) return;
      const zip = f.name.toLowerCase().endsWith(".zip");
      if (f.size > (zip ? 16 * 1024 * 1024 : 262144))
        throw new Error("ZIP 不能超过 16 MB；文本扩展不能超过 256 KB");
      await save("extension/import", {
        ...(zip ? { data: await blobBase64(f) } : { source: await f.text() }),
        filename: f.name,
      });
    });
  input.click();
}
async function blobBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1]);
    reader.onerror = () => reject(new Error("读取失败"));
    reader.readAsDataURL(blob);
  });
}
function packageSettings(e) {
  const m = e.manifest,
    p = m.packageManifest || {},
    schema = p.configSchema || {};
  edit(
    `${m.name} · 设置`,
    { ...(p.settings || {}), ...(e.settings || {}), _enabled: e.enabled },
    [
      ...Object.entries(schema).map(([key, s]) =>
        field(
          key,
          s.label || key,
          s.type === "boolean"
            ? "bool"
            : ["number", "slider"].includes(s.type)
              ? "number"
              : s.type === "enum"
                ? "select"
                : s.type === "string" && (s.multiline || /Text|Rules/.test(key))
                  ? "multiline"
                  : "text",
          Object.fromEntries(
            (s.values || []).map((v) => [
              v,
              (s.options || []).find((o) => String(o.value) === String(v))
                ?.label || v,
            ]),
          ),
          s.description || "",
        ),
      ),
      field("_enabled", "启用扩展", "bool"),
    ],
    async (value) => {
      const { _enabled, ...settings } = value;
      await api("extension/configure", {
        id: m.id,
        settings,
        enabled: _enabled,
      });
    },
    "原包由内嵌 JavaScript 引擎运行。只读写扩展独立数据；网络权限由包清单声明。主人 QQ 号识别仅适用于 OneBot，不会将官方 OpenID 当作 QQ 号。",
  );
}
async function packageFiles(e) {
  edit(
    `${e.manifest.name} · 文件`,
    { file: e.fileNames?.[0] || "" },
    [
      field(
        "file",
        "包内文件",
        "select",
        Object.fromEntries((e.fileNames || []).map((n) => [n, n])),
      ),
    ],
    async (value) => {
      const { source } = await api(
        `extension/file?${new URLSearchParams({ id: e.manifest.id, file: value.file })}`,
      );
      // The outer editor is closed by edit(); open the next one on a new task.
      setTimeout(
        () =>
          edit(
            value.file,
            { source },
            [field("source", "文件内容", "code")],
            async (draft) =>
              api("extension/file/save", {
                id: e.manifest.id,
                file: value.file,
                source: draft.source,
              }),
            "保存后立即生效，包清单只读。",
          ),
        0,
      );
    },
  );
}
async function exportPackage(e) {
  const result = await api(
    `extension/export?${new URLSearchParams({ id: e.manifest.id })}`,
  );
  const bytes = Uint8Array.from(atob(result.data), (c) => c.charCodeAt(0));
  const url = URL.createObjectURL(
    new Blob([bytes], { type: "application/zip" }),
  );
  const a = el("a");
  a.href = url;
  a.download = result.filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function renderChat() {
  const c =
    state.connections.find((x) => x.id === account) || state.connections[0];
  if (!c) {
    $("page").append(
      el("p", "请先添加机器人连接。", "empty"),
      button("添加连接", () => {
        tab = 1;
        render();
      }),
    );
    return;
  }
  account = c.id;
  const chats = state.sessions.filter((s) => s.connectionId === account),
    current = chats.find((s) => s.key === session);
  if (!current) session = "";
  const layout = el("div", null, `chat-layout ${current ? "open" : ""}`),
    sidebar = el("aside", null, "sessions"),
    panel = el("section", null, "chat");
  const select = el("select");
  select.id = "agent-account";
  select.setAttribute("aria-label", "Agent 机器人账号");
  for (const p of state.connections) {
    const o = el("option", `${p.nickname || p.name} · ${p.selfId}`);
    o.value = p.id;
    select.append(o);
  }
  select.value = account;
  select.onchange = () => {
    account = select.value;
    session = "";
    chatDraft = "";
    render();
  };
  const status = el("p", c.status, "muted");
  status.id = "agent-connection-status";
  sidebar.append(
    select,
    status,
    button("＋ 新建会话", () =>
      edit(
        "新建 Agent 会话",
        { kind: "group", peerId: "", name: "" },
        [
          field("kind", "类型", "select", { group: "群聊", private: "私聊" }),
          field(
            "peerId",
            c.protocol === "qqbot" ? "群 / 用户 OpenID" : "群号 / QQ 号",
          ),
          field("name", "名称（可选）"),
        ],
        async (value) => {
          session = (await api("session/open", { id: account, ...value }))
            .session.key;
          forceBottom = true;
        },
      ),
    ),
  );
  const list = el("div", null, "sessions-list");
  list.id = "agent-session-list";
  for (const s of chats) {
    const b = button(s.name, async () => {
      session = s.key;
      chatDraft = "";
      forceBottom = true;
      await api("session/read", { session });
      render();
    });
    b.className = `session ${s.key === session ? "active" : ""}`;
    b.append(
      el(
        "small",
        `${s.kind === "group" ? "群" : "QQ"} ${s.peerId}${s.unread ? ` · ${s.unread} 未读` : ""}`,
      ),
    );
    list.append(b);
  }
  sidebar.append(list);
  layout.append(sidebar, panel);
  $("page").append(layout);
  if (!current) {
    panel.append(el("p", "选择一个 Agent 会话", "empty"));
    return;
  }
  const h = el("div", null, "chat-header");
  h.append(
    button("←", () => {
      session = "";
      render();
    }),
    el("strong", current.name),
    button("设置", () =>
      edit(
        "Agent 会话设置",
        current,
        [
          field("name", "会话名称"),
          field("paused", "暂停自动回复", "bool"),
          field("presetId", "预设", "select", {
            "": "连接默认",
            ...options(state.presets),
          }),
          field("memory", "长期备注 / 记忆", "multiline"),
        ],
        (value) => api("session/save", { value }),
      ),
    ),
    button("新上下文", () => save("session/context", { session })),
  );
  if (c.protocol === "qqbot")
    h.append(button("刷新资料", () => save("session/profile", { session })));
  const messages = el("div", null, "messages");
  messages.id = "messages";
  const notice = el("div", null, "notice-row");
  notice.id = "chat-notice";
  const replyStatus = el("div", null, "reply-status");
  replyStatus.id = "reply-status";
  replyStatus.setAttribute("role", "status");
  const composer = el("form", null, "composer"),
    input = el("textarea");
  input.placeholder = "输入 Agent 消息…";
  input.setAttribute("aria-label", "Agent 消息");
  input.rows = 1;
  input.value = chatDraft;
  input.oninput = () => {
    chatDraft = input.value;
  };
  const send = el("button", "发送", "primary");
  send.type = "submit";
  const submit = async () => {
    if (send.disabled || !input.value.trim()) return;
    const draft = input.value,
      target = session;
    send.disabled = true;
    try {
      await api("send", { session: target, text: draft });
      if (target === session) {
        if (input.value === draft) {
          input.value = "";
          chatDraft = "";
        }
        forceBottom = true;
        await refreshMessages();
      }
    } finally {
      send.disabled = false;
    }
  };
  composer.onsubmit = (e) => {
    e.preventDefault();
    run(submit);
  };
  input.onkeydown = (e) => {
    if (e.key !== "Enter" || e.isComposing) return;
    e.preventDefault();
    if (e.ctrlKey) {
      input.setRangeText("\n", input.selectionStart, input.selectionEnd, "end");
      chatDraft = input.value;
    } else run(submit);
  };
  composer.append(input, send);
  panel.append(h, messages, notice, replyStatus, composer);
  lastMessages = "";
  forceBottom = true;
  run(refreshMessages);
}
function refreshSidebar() {
  const list = $("agent-session-list"),
    selector = $("agent-account");
  if (!list || !selector) return;
  const oldTop = list.scrollTop;
  selector.replaceChildren();
  for (const c of state.connections) {
    const o = el("option", `${c.nickname || c.name} · ${c.selfId}`);
    o.value = c.id;
    selector.append(o);
  }
  selector.value = account;
  $("agent-connection-status").textContent =
    state.connections.find((c) => c.id === account)?.status || "未连接";
  const title = document.querySelector(".chat-header strong"),
    current = state.sessions.find((s) => s.key === session);
  if (title && current) title.textContent = current.name;
  list.replaceChildren();
  for (const s of state.sessions.filter((s) => s.connectionId === account)) {
    const b = button(s.name, async () => {
      session = s.key;
      chatDraft = "";
      forceBottom = true;
      await api("session/read", { session });
      render();
    });
    b.className = `session ${s.key === session ? "active" : ""}`;
    b.append(
      el(
        "small",
        `${s.kind === "group" ? "群" : "QQ"} ${s.peerId}${s.unread ? ` · ${s.unread} 未读` : ""}`,
      ),
    );
    list.append(b);
  }
  list.scrollTop = oldTop;
}
function safeUrl(value) {
  try {
    const u = new URL(value);
    return ["http:", "https:"].includes(u.protocol) &&
      !u.username &&
      !u.password
      ? u.href
      : null;
  } catch {
    return null;
  }
}
const voiceBlobs = new Set();
function extensionNetwork(m) {
  if (m.runtime !== "qq-agent-js")
    return (m.allowedOrigins || []).join("、") || "无";
  const requirements = m.compatibility?.requirements || [];
  return (
    [
      (m.packageManifest?.permissions || []).includes("web_fetch") ||
      requirements.includes("publicFetch")
        ? "公共 HTTPS"
        : "",
      requirements.includes("websocket") ? "公共 WSS" : "",
    ]
      .filter(Boolean)
      .join("、") || "无"
  );
}
new MutationObserver((changes) => {
  for (const change of changes)
    for (const node of change.removedNodes) {
      if (!(node instanceof Element) || node.isConnected) continue;
      const nodes = [node, ...node.querySelectorAll("[data-voice-blob]")];
      for (const element of nodes) {
        const url = element.dataset.voiceBlob;
        if (url) {
          URL.revokeObjectURL(url);
          voiceBlobs.delete(url);
        }
      }
    }
}).observe(document, { childList: true, subtree: true });
addEventListener("beforeunload", () => {
  for (const url of voiceBlobs) URL.revokeObjectURL(url);
});
function renderSegment(bubble, segment) {
  const d = segment.data || {},
    t = segment.type;
  if (t === "qq_body") {
    renderOfficialBody(bubble, d.body || {}, 0);
    return;
  }
  if (t === "text") {
    bubble.append(el("span", d.text || ""));
    return;
  }
  if (t === "at") {
    bubble.append(
      el("strong", d.qq === "all" ? "@全体成员 " : `@${d.name || d.qq} `),
    );
    return;
  }
  const url = safeUrl(d.url || (t === "image" ? d.file : ""));
  if (
    t === "record" &&
    typeof d.file === "string" &&
    d.file.startsWith("base64://") &&
    d.file.length < 7 * 1024 * 1024 &&
    [
      "audio/wav",
      "audio/mpeg",
      "audio/silk",
      "audio/ogg",
      "audio/mp4",
    ].includes(d.mime)
  ) {
    let source;
    try {
      const bytes = Uint8Array.from(atob(d.file.slice(9)), (c) =>
        c.charCodeAt(0),
      );
      source = URL.createObjectURL(new Blob([bytes], { type: d.mime }));
      voiceBlobs.add(source);
    } catch {
      bubble.append(el("span", "[语音数据无效]"));
      return;
    }
    const media = el("audio"),
      link = el("a", "下载语音");
    media.dataset.voiceBlob = source;
    media.src = source;
    media.controls = true;
    media.preload = "none";
    link.href = source;
    link.download = (d.name || "voice.wav").replace(/[\\/\r\n]/g, "_");
    bubble.append(media, link);
    return;
  }
  if (t === "image" && url) {
    const image = el("img");
    image.src = url;
    image.alt = "OneBot 图片";
    image.loading = "lazy";
    image.referrerPolicy = "no-referrer";
    bubble.append(image);
    return;
  }
  if (["record", "video"].includes(t) && url) {
    const media = el(t === "record" ? "audio" : "video");
    media.src = url;
    media.controls = true;
    media.preload = "none";
    bubble.append(media);
    return;
  }
  bubble.append(
    el(
      "span",
      {
        image: "[图片]",
        reply: `[引用 ${d.id}]`,
        forward: "[合并转发记录]",
        face: `[表情 ${d.id}]`,
        video: "[视频]",
        record: "[语音]",
      }[t] || `[${t}]`,
    ),
  );
}
function renderOfficialBody(parent, body, depth) {
  if (depth > 6) {
    parent.append(el("small", "嵌套内容过多，剩余部分未显示。"));
    return;
  }
  const nodes = Array.isArray(body.msg_elements) ? body.msg_elements : [];
  if (body.message_type === 102 && depth === 0) {
    parent.append(
      button(`查看聊天记录 · ${nodes.length} 条`, () => {
        const dialog = el("dialog", null, "record-reader"),
          header = el("div", null, "dialog-heading");
        header.append(
          el("h2", body.record_title || "聊天记录"),
          button("关闭", () => dialog.close()),
        );
        dialog.append(header);
        for (const node of nodes) renderOfficialBody(dialog, node, 1);
        dialog.addEventListener("close", () => dialog.remove());
        document.body.append(dialog);
        dialog.showModal();
      }),
    );
    return;
  }
  const card = el(
    "div",
    null,
    body.message_type === 103 ? "quoted-body" : "official-body",
  );
  if (depth > 0)
    card.append(
      el(
        "small",
        body.author?.username || body.author?.id || "平台未提供发送者",
      ),
    );
  if (body.content) card.append(el("p", body.content));
  for (const a of (body.attachments || []).slice(0, 6)) {
    const mime = a.content_type || "",
      type = mime.startsWith("image/")
        ? "image"
        : mime.startsWith("video/")
          ? "video"
          : mime === "voice" || mime.startsWith("audio/")
            ? "record"
            : "file";
    renderSegment(card, {
      type,
      data: { url: a.voice_wav_url || a.url, name: a.filename },
    });
    if (a.asr_refer_text)
      card.append(el("small", `语音转写：${a.asr_refer_text}`));
  }
  if (body.ark_data) {
    const fields = body.ark_data.fields || {};
    card.append(
      el("strong", fields.title || body.ark_data.ark_name || "卡片"),
      el("p", fields.desc || ""),
    );
  }
  if (nodes.length) {
    const details = el("details"),
      summary = el(
        "summary",
        `${body.message_type === 103 ? "引用消息" : body.message_type === 102 ? "聊天记录" : "消息内容"} · ${nodes.length} 条`,
      );
    details.open = body.message_type === 103;
    details.append(summary);
    for (const node of nodes) renderOfficialBody(details, node, depth + 1);
    card.append(details);
  } else if (body.message_type === 103)
    card.append(el("small", "平台未返回引用原文，且本地没有匹配记录。"));
  parent.append(card);
}
async function refreshMessages() {
  const target = session,
    box = $("messages");
  if (!target || !box) return;
  const result = await api(`messages?session=${encodeURIComponent(target)}`);
  if (target !== session || box !== $("messages")) return;
  const current = state.sessions.find((s) => s.key === target),
    connection = state.connections.find((c) => c.id === current?.connectionId),
    preset = state.presets.find(
      (p) => p.id === (current?.presetId || connection?.presetId),
    );
  const ids = result.messages.map((m) => m.id),
    oldIds = lastMessages ? JSON.parse(lastMessages).ids : [],
    signature = JSON.stringify({
      ids,
      names: result.messages.map((m) => m.senderName),
      addressed: result.messages.map((m) => m.addressed === true),
      contexts: result.messages.map((m) =>
        (m.segments || [])
          .filter((s) => s.type === "qq_body")
          .map((s) => s.data?.context || ""),
      ),
      showReasoning: preset?.showReasoning === true,
    });
  if (signature !== lastMessages) {
    const oldTop = box.scrollTop,
      first = !lastMessages;
    if (ids.at(-1) !== oldIds.at(-1) && result.messages.at(-1)?.outgoing)
      forceBottom = true;
    box.replaceChildren();
    for (const m of result.messages) {
      const item = el(
          "article",
          null,
          `message ${m.outgoing ? "outgoing" : ""}`,
        ),
        bubble = el("div", null, "bubble");
      item.append(
        el(
          "small",
          `${m.senderName} · ${new Date(m.time).toLocaleTimeString()}${m.source === "ai" ? " · AI" : ""}`,
        ),
      );
      for (const s of m.segments) renderSegment(bubble, s);
      item.append(bubble);
      if (preset?.showReasoning && m.source === "ai" && m.reasoning) {
        const reasoning = el("details", null, "reasoning");
        reasoning.append(
          el("summary", "思考内容 · 模型接口返回 · 不发送到 QQ"),
          el("pre", m.reasoning),
        );
        item.append(reasoning);
      }
      box.append(item);
    }
    if (forceBottom || first) box.scrollTop = box.scrollHeight;
    else box.scrollTop = oldTop;
    const notice = $("chat-notice");
    notice.replaceChildren();
    if (!forceBottom && !first)
      notice.append(
        button("有新消息 ↓", () => {
          box.scrollTop = box.scrollHeight;
          notice.replaceChildren();
          return api("session/read", { session: target });
        }),
      );
    lastMessages = signature;
    forceBottom = false;
  }
  const reply = state.replyStates?.[target],
    status = $("reply-status");
  if (status) {
    status.replaceChildren();
    status.classList.toggle("error", reply?.error === true);
    status.hidden =
      !reply || (reply.phase === "done" && !state.busy.includes(target));
    if (!status.hidden)
      status.append(
        el("span", reply.message),
        button("×", () => save("session/dismiss-status", { session: target })),
      );
  }
  const notice = $("chat-notice");
  if (state.busy.includes(target) && !notice.querySelector(".stop")) {
    const b = button("AI 处理中 · 停止", () =>
      save("session/stop", { session: target }),
    );
    b.classList.add("stop");
    notice.append(b);
  }
  if (!state.busy.includes(target)) notice.querySelector(".stop")?.remove();
}
run(() => refresh(true));
setInterval(() => {
  if (!document.hidden)
    refresh().catch(() => {
      $("status").textContent =
        "暂时无法刷新 Agent，请检查网络或返回首页重新登录。";
    });
}, 3000);
