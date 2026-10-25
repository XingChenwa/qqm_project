import assert from "node:assert/strict";
import { join } from "node:path";

function packageZip(files) {
  const locals = [],
    central = [];
  let offset = 0;
  for (const [filename, source] of Object.entries(files)) {
    const name = Buffer.from(filename),
      data = Buffer.from(source);
    let crc = 0xffffffff;
    for (const byte of data) {
      crc ^= byte;
      for (let j = 0; j < 8; j++)
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    crc = (crc ^ 0xffffffff) >>> 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50);
    local.writeUInt16LE(20, 4);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt32LE(crc, 16);
    header.writeUInt32LE(data.length, 20);
    header.writeUInt32LE(data.length, 24);
    header.writeUInt16LE(name.length, 28);
    header.writeUInt32LE(offset, 42);
    locals.push(local, name, data);
    central.push(header, name);
    offset += local.length + name.length + data.length;
  }
  const directory = Buffer.concat(central),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(Object.keys(files).length, 8);
  end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

// Runs inside the existing authenticated local Linux-server fixture.
export async function verifyAgent(page, shots) {
  const home = page.url().split("#")[0];
  await page.setViewportSize({ width: 1360, height: 900 });
  const official = await page.evaluate(async () =>
    (
      await fetch("api/state", {
        headers: { "X-QQM-Request": "1" },
      })
    ).json(),
  );
  await page.getByRole("link", { name: "QQ Agent", exact: true }).click();
  await page.getByText("请先添加机器人连接。", { exact: true }).waitFor();
  assert.ok(page.url().endsWith("agent.html"));
  assert.equal(await page.locator('script[src="app.js"]').count(), 0);
  const tab = async (name) => {
    await page
      .locator("#tabs")
      .getByRole("button", { name, exact: true })
      .click();
  };
  await tab("机器人连接");
  await page.getByRole("button", { name: "＋ 新建", exact: true }).click();
  await page.getByLabel("名称", { exact: true }).fill("隔离测试助手");
  await page.getByLabel("机器人真实 QQ 号", { exact: true }).fill("12345678");
  assert.equal(
    await page.getByLabel("正向 WS 通用地址", { exact: true }).isVisible(),
    true,
  );
  assert.equal(
    await page.getByLabel("反向监听 IP", { exact: true }).isVisible(),
    false,
  );
  await page.getByLabel("方式", { exact: true }).selectOption("reverse");
  assert.equal(
    await page.getByLabel("正向 WS 通用地址", { exact: true }).isVisible(),
    false,
  );
  await page.getByLabel("反向 WS 路径", { exact: true }).fill("/");
  await page.getByLabel("方式", { exact: true }).selectOption("forward");
  await page.getByLabel("方式", { exact: true }).selectOption("reverse");
  assert.equal(
    await page.getByLabel("反向 WS 路径", { exact: true }).inputValue(),
    "/",
  );
  await page
    .getByLabel("访问令牌", { exact: true })
    .fill("local-fixture-token-not-a-real-secret");
  await page.locator("#save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  await page
    .getByRole("heading", { name: "隔离测试助手", exact: true })
    .waitFor();
  const agentState = () =>
    page.evaluate(async () =>
      (
        await fetch("api/agent/state", {
          headers: { "X-QQM-Request": "1" },
        })
      ).json(),
    );
  let state = await agentState();
  assert.equal(state.connections.length, 1);
  assert.equal(state.connections[0].aiEnabled, false);
  assert.equal(state.connections[0].started, false);
  assert.equal(state.connections[0].hasToken, true);
  assert.equal(state.connections[0].mode, "reverse");
  assert.equal(state.connections[0].path, "/");
  assert.ok(!JSON.stringify(state).includes("local-fixture-token"));
  assert.ok(state.extensions.every((x) => x.enabled === false));
  await page.getByRole("button", { name: "配置", exact: true }).click();
  assert.equal(
    await page.getByLabel("访问令牌", { exact: true }).inputValue(),
    "",
  );
  await page.getByLabel("名称", { exact: true }).fill("隔离测试助手 · 已编辑");
  await page.locator("#fields .advanced > summary").click();
  await page
    .getByLabel("额外唤醒前缀", { exact: true })
    .fill("小助手\nhey bot");
  const savingPrefixes = page.waitForRequest(
    (r) =>
      r.url().endsWith("/api/agent/connection/save") && r.method() === "POST",
  );
  await page.locator("#save").click();
  assert.deepEqual(
    (await savingPrefixes).postDataJSON().value.extraWakePrefixes,
    ["小助手", "hey bot"],
  );
  await page.locator("#editor").waitFor({ state: "hidden" });
  assert.equal((await agentState()).connections[0].hasToken, true);
  assert.deepEqual((await agentState()).connections[0].extraWakePrefixes, [
    "小助手",
    "hey bot",
  ]);

  await tab("AI 模型");
  await page.getByRole("button", { name: "＋ 新建", exact: true }).click();
  await page.getByLabel("配置名称", { exact: true }).fill("本地测试模型");
  await page
    .getByLabel("API Key", { exact: true })
    .fill("local-fixture-model-key");
  await page.route("**/api/agent/provider/models", async (route) => {
    const body = route.request().postDataJSON();
    assert.equal(body.value.apiKey, "local-fixture-model-key");
    assert.equal(body.value.model, "");
    await route.fulfill({
      json: { result: ["fixture-model", "another-model"] },
    });
  });
  await page
    .getByRole("button", { name: "获取并选择模型", exact: true })
    .click();
  await page.getByLabel("搜索模型", { exact: true }).fill("fixture");
  await page
    .getByLabel("可用模型", { exact: true })
    .selectOption("fixture-model");
  await page.getByRole("button", { name: "使用所选模型", exact: true }).click();
  assert.equal(
    await page.getByLabel("模型 ID", { exact: true }).inputValue(),
    "fixture-model",
  );
  await page.unroute("**/api/agent/provider/models");
  await page.locator("#fields .advanced > summary").click();
  await page.getByLabel("支持图片输入（视觉模型）", { exact: true }).check();
  await page.locator("#save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  state = await agentState();
  assert.equal(state.providers.length, 1);
  assert.ok(!JSON.stringify(state).includes("local-fixture-model-key"));
  await tab("预设");
  await page.getByRole("button", { name: "编辑", exact: true }).first().click();
  await page
    .getByLabel("模型", { exact: true })
    .selectOption(state.providers[0].id);
  await page
    .getByLabel("人设 / 提示词", { exact: true })
    .fill("你是独立的 Agent 测试助手。");
  await page
    .getByLabel("图片转述模型", { exact: true })
    .selectOption(state.providers[0].id);
  await page.getByLabel("网页搜索 · Bing", { exact: true }).check();
  await page.getByLabel("显示思考内容", { exact: true }).check();
  await page.getByLabel("分多条消息回复", { exact: true }).check();
  assert.equal(
    await page.getByLabel("读取引用与聊天记录", { exact: true }).isChecked(),
    true,
  );
  assert.equal(
    await page.getByLabel("现实世界时间感知", { exact: true }).isChecked(),
    true,
  );
  await page.locator("#fields .advanced > summary").click();
  await page
    .getByLabel("输入图片最大边长（像素）", { exact: true })
    .fill("768");
  await page.getByLabel("每轮最多发送几条", { exact: true }).fill("4");
  await page.getByLabel("分条发送间隔（毫秒）", { exact: true }).fill("800");
  for (const width of [1360, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await page
      .getByLabel("图片转述模型", { exact: true })
      .scrollIntoViewIfNeeded();
    await page.screenshot({
      path: join(shots, `agent-ai-settings-${width}.png`),
    });
  }
  await page.setViewportSize({ width: 1360, height: 900 });
  await page.locator("#save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });

  const settings = (await agentState()).presets[0];
  assert.equal(settings.imageDescriptionProviderId, state.providers[0].id);
  assert.equal(settings.imageMaxEdge, 768);
  assert.equal(settings.webSearchEnabled, true);
  assert.equal(settings.showReasoning, true);
  assert.equal(settings.multiMessageReply, true);
  assert.equal(settings.readMessageContext, true);
  assert.equal(settings.maxReplyMessages, 4);
  assert.equal(settings.replyIntervalMs, 800);

  await tab("Skills");
  const chooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "导入文件", exact: true }).click();
  await (
    await chooser
  ).setFiles({
    name: "browser-skill.json",
    mimeType: "application/json",
    buffer: Buffer.from(
      JSON.stringify({
        schema: 1,
        id: "browser_skill",
        name: "网页导入 Skill",
        kind: "skill",
        prompt: "请用中文回答",
        tools: [],
        enabled: true,
      }),
    ),
  });
  const imported = page
    .locator("article")
    .filter({ hasText: "网页导入 Skill" });
  await imported.waitFor();
  await imported.getByText(/已关闭/).waitFor();
  await imported.getByRole("button", { name: "启用", exact: true }).click();
  await imported.getByRole("button", { name: "关闭", exact: true }).waitFor();
  await imported.getByRole("button", { name: "编辑源码", exact: true }).click();
  const source = JSON.parse(
    await page.getByLabel("JSON / YAML 清单", { exact: true }).inputValue(),
  );
  assert.equal(source.id, "browser_skill");
  await page.locator("#cancel").click();
  if (process.env.FLUTTER_QJS_NEXT_LIBRARY) {
    const chooser = page.waitForEvent("filechooser");
    await page.getByRole("button", { name: "导入文件", exact: true }).click();
    const source =
      "export function setup(api){api.registerTool({id:'hello',name:'问候',description:'问候',parameters:{type:'object',properties:{}},execute(){return {content:api.config().greeting}}});}";
    await (
      await chooser
    ).setFiles({
      name: "original-skill.zip",
      mimeType: "application/zip",
      buffer: packageZip({
        "outer/pkg/skill.json": JSON.stringify({
          id: "browser_zip_skill",
          name: "网页原包 Skill",
          apiVersion: 1,
          enabledByDefault: true,
          settings: { greeting: "默认问候" },
          configSchema: { greeting: { type: "string", label: "自定义问候" } },
        }),
        "outer/pkg/index.js": source,
      }),
    });
    const card = page.locator("article").filter({ hasText: "网页原包 Skill" });
    await card.waitFor();
    await card.getByText(/已关闭/).waitFor();
    await card.getByRole("button", { name: "插件设置", exact: true }).click();
    await page.getByLabel("自定义问候", { exact: true }).fill("网页配置生效");
    await page.getByLabel("启用扩展", { exact: true }).check();
    await page.locator("#save").click();
    await page.locator("#editor").waitFor({ state: "hidden" });
    let value = (await agentState()).extensions.find(
      (e) => e.manifest.id === "browser_zip_skill",
    );
    assert.equal(value.settings.greeting, "网页配置生效");
    assert.equal(value.enabled, true);
    assert.equal(value.manifest.files, undefined);
    await card
      .getByRole("button", { name: "查看 / 编辑文件", exact: true })
      .click();
    await page.getByLabel("包内文件", { exact: true }).selectOption("index.js");
    await page.locator("#save").click();
    await page.getByLabel("文件内容", { exact: true }).waitFor();
    assert.equal(
      await page.getByLabel("文件内容", { exact: true }).inputValue(),
      source,
    );
    await page
      .getByLabel("文件内容", { exact: true })
      .fill(source + "\n// edited in browser");
    await page.locator("#save").click();
    await page.locator("#editor").waitFor({ state: "hidden" });
    const download = page.waitForEvent("download");
    await card.getByRole("button", { name: "导出", exact: true }).click();
    assert.equal((await download).suggestedFilename(), "browser_zip_skill.zip");
  }
  if (
    process.env.QQM_AGENT_EXTRA_PACKAGE_DIR &&
    process.env.FLUTTER_QJS_NEXT_LIBRARY
  ) {
    for (const name of [
      "plugins-share-card",
      "plugins-whale-voice",
      "skills-api-beggar",
      "skills-deai-flavor",
      "skills-qq-self",
      "skills-smart-image",
      "skills-voxcpm-voice",
      "plugins-burst-merge",
      "plugins-context-reuse",
      "plugins-group-cost-report",
      "plugins-hot-trend-tracker",
    ]) {
      const chooser = page.waitForEvent("filechooser");
      await page.getByRole("button", { name: "导入文件", exact: true }).click();
      await (
        await chooser
      ).setFiles(join(process.env.QQM_AGENT_EXTRA_PACKAGE_DIR, name + ".zip"));
      const id = name.replace(/^(plugins|skills)-/, "");
      await page.waitForFunction(async (id) => {
        const r = await fetch("api/agent/state", {
          headers: { "X-QQM-Request": "1" },
        });
        return (await r.json()).extensions.some((e) => e.manifest.id === id);
      }, id);
    }
    await tab("AI 插件");
    const whale = page.locator("article").filter({
      has: page.getByRole("heading", { name: "鲸鱼语音", exact: true }),
    });
    await whale.getByText(/导入检查通过/).waitFor();
    await whale.getByRole("button", { name: "兼容情况", exact: true }).click();
    await page
      .locator("#notice-text")
      .getByText(/内嵌 WSS 接口/)
      .waitFor();
    await page.locator("#notice-close").click();
    await whale.getByRole("button", { name: "插件设置", exact: true }).click();
    await page.getByLabel("语速", { exact: true }).fill("25");
    await page.locator("#save").click();
    await page.locator("#editor").waitFor({ state: "hidden" });
    const settings = (await agentState()).extensions.find(
      (e) => e.manifest.id === "whale-voice",
    );
    assert.equal(settings.settings.rate, 25);
    assert.equal(settings.enabled, false);
  }
  for (const width of [1360, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const name of [
      "机器人连接",
      "AI 模型",
      "预设",
      "AI 插件",
      "Skills",
      "运行日志",
    ]) {
      await tab(name);
      assert.ok(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        `Agent ${name}/${width} overflow`,
      );
    }
    await tab("Skills");
    await page.screenshot({ path: join(shots, `agent-skills-${width}.png`) });
  }
  await page.setViewportSize({ width: 1360, height: 900 });
  await tab("聊天");
  await page.getByRole("button", { name: "＋ 新建会话", exact: true }).click();
  await page.getByLabel("群号 / QQ 号", { exact: true }).fill("87654321");
  await page.getByLabel("名称（可选）", { exact: true }).fill("Agent 独立会话");
  await page.locator("#save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  await page
    .locator(".chat-header")
    .getByText("Agent 独立会话", { exact: true })
    .waitFor();
  const draft = page.getByRole("textbox", { name: "Agent 消息", exact: true });
  await draft.fill("第一行");
  await draft.press("Control+Enter");
  assert.equal(await draft.inputValue(), "第一行\n");
  await draft.press("Enter");
  await page.locator("#notice").waitFor({ state: "visible" });
  await page
    .locator("#notice-text")
    .getByText(/请先连接此机器人账号/)
    .waitFor();
  assert.equal(await draft.inputValue(), "第一行\n");
  await page.locator("#notice-close").click();
  // Polling must not recreate the composer or erase the draft.
  await page.waitForTimeout(3200);
  assert.equal(await draft.inputValue(), "第一行\n");
  for (const width of [1360, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      `Agent chat/${width} overflow`,
    );
    await page.screenshot({ path: join(shots, `agent-chat-${width}.png`) });
  }
  state = await agentState();
  assert.equal(state.sessions.length, 1);
  assert.equal(state.sessions[0].peerId, "87654321");
  // Synthetic provider reasoning is rendered as plain text in a collapsed area,
  // never HTML. Toggling the preset must hide it without a new message ID.
  const activeSession = state.sessions[0],
    activeConnection = state.connections.find(
      (c) => c.id === activeSession.connectionId,
    ),
    activePreset = state.presets.find(
      (p) => p.id === (activeSession.presetId || activeConnection.presetId),
    );
  const voiceFixture = Buffer.alloc(44 + 4400);
  voiceFixture.write("RIFF");
  voiceFixture.writeUInt32LE(voiceFixture.length - 8, 4);
  voiceFixture.write("WAVEfmt ", 8);
  voiceFixture.writeUInt32LE(16, 16);
  voiceFixture.writeUInt16LE(1, 20);
  voiceFixture.writeUInt16LE(1, 22);
  voiceFixture.writeUInt32LE(22000, 24);
  voiceFixture.writeUInt32LE(44000, 28);
  voiceFixture.writeUInt16LE(2, 32);
  voiceFixture.writeUInt16LE(16, 34);
  voiceFixture.write("data", 36);
  voiceFixture.writeUInt32LE(4400, 40);
  await page.route("**/api/agent/messages?*", (route) =>
    route.fulfill({
      json: {
        messages: [
          {
            id: "synthetic-ai",
            senderName: "测试 AI",
            outgoing: true,
            source: "ai",
            time: new Date().toISOString(),
            reasoning: "<img src=x onerror=alert(1)> 模型返回摘要",
            segments: [{ type: "text", data: { text: "最终回复" } }],
          },
          {
            id: "synthetic-voice",
            senderName: "测试 AI",
            outgoing: true,
            source: "plugin",
            time: new Date().toISOString(),
            segments: [
              {
                type: "record",
                data: {
                  file: "base64://" + voiceFixture.toString("base64"),
                  mime: "audio/wav",
                  name: "voice.wav",
                },
              },
            ],
          },
          {
            id: "synthetic-quote",
            senderName: "当前提问者",
            time: new Date().toISOString(),
            segments: [
              {
                type: "qq_body",
                data: {
                  context: "引用原文",
                  body: {
                    message_type: 103,
                    content: "请解释引用",
                    msg_elements: [
                      {
                        content: "<img src=x onerror=alert(1)> 引用原文",
                        author: { username: "引用作者" },
                      },
                    ],
                  },
                },
              },
            ],
          },
          {
            id: "synthetic-record",
            senderName: "当前提问者",
            time: new Date().toISOString(),
            segments: [
              {
                type: "qq_body",
                data: {
                  context: "记录原文",
                  body: {
                    message_type: 102,
                    record_title: "合并聊天记录阅读",
                    msg_elements: [
                      {
                        content: "第一条记录内容",
                        author: { username: "记录作者" },
                      },
                    ],
                  },
                },
              },
            ],
          },
        ],
      },
    }),
  );
  await page.locator("#refresh").click();
  const voice = page.locator("audio").first();
  assert.ok((await voice.getAttribute("src")).startsWith("blob:"));
  await voice.evaluate((audio) => audio.load());
  await page.waitForFunction(
    () => document.querySelector("audio")?.readyState >= 1,
  );
  assert.equal(await voice.evaluate((audio) => audio.error), null);
  const voiceDownload = page.waitForEvent("download");
  await page.getByRole("link", { name: "下载语音", exact: true }).click();
  assert.equal((await voiceDownload).suggestedFilename(), "voice.wav");
  const reasoning = page.locator(".reasoning");
  await reasoning.waitFor();
  assert.equal(await reasoning.getAttribute("open"), null);
  await reasoning.locator("summary").click();
  assert.ok(
    (await reasoning.locator("pre").innerText()).includes(
      "<img src=x onerror=alert(1)>",
    ),
  );
  assert.equal(await reasoning.locator("img").count(), 0);
  const quote = page.locator(".quoted-body");
  await quote.getByText("引用作者", { exact: true }).waitFor();
  assert.equal(await quote.locator("img").count(), 0);
  assert.ok((await quote.innerText()).includes("<img src=x onerror=alert(1)>"));
  await page
    .getByRole("button", { name: "查看聊天记录 · 1 条", exact: true })
    .click();
  const record = page.locator("dialog.record-reader");
  await record.getByText("第一条记录内容", { exact: true }).waitFor();
  await record.getByText("记录作者", { exact: true }).waitFor();
  await record.getByRole("button", { name: "关闭", exact: true }).click();
  await record.waitFor({ state: "hidden" });
  assert.equal(await draft.inputValue(), "第一行\n");
  await page.screenshot({ path: join(shots, "agent-reasoning-320.png") });
  await page.evaluate(async (p) => {
    await fetch("api/agent/preset/save", {
      method: "POST",
      headers: { "X-QQM-Request": "1", "Content-Type": "application/json" },
      body: JSON.stringify({ value: { ...p, showReasoning: false } }),
    });
  }, activePreset);
  await page.waitForFunction(() => !document.querySelector(".reasoning"));
  assert.equal(await draft.inputValue(), "第一行\n");
  await page.unroute("**/api/agent/messages?*");
  await page.setViewportSize({ width: 1360, height: 900 });
  await tab("机器人连接");
  await page.getByRole("button", { name: "＋ 新建", exact: true }).click();
  await page.getByLabel("机器人类型", { exact: true }).selectOption("qqbot");
  assert.equal(
    await page.getByLabel("方式", { exact: true }).isVisible(),
    false,
  );
  assert.equal(
    await page.getByLabel("访问令牌", { exact: true }).isVisible(),
    false,
  );
  await page.getByLabel("名称", { exact: true }).fill("QQBot 测试配置");
  await page.getByLabel("QQBot AppID", { exact: true }).fill("10000002");
  await page
    .getByLabel("QQBot ClientSecret", { exact: true })
    .fill("fixture-qqbot-client-secret");
  await page.locator("#save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  let qqCard = page.locator("article").filter({ hasText: "QQBot 测试配置" });
  assert.equal(
    await qqCard
      .getByRole("button", { name: "同步好友与群", exact: true })
      .count(),
    0,
  );
  state = await agentState();
  assert.equal(
    state.connections.find((c) => c.protocol === "qqbot").hasClientSecret,
    true,
  );
  assert.equal(
    state.connections.find((c) => c.protocol === "qqbot")
      .resolveOfficialProfiles,
    true,
  );
  assert.equal(
    state.connections.find((c) => c.protocol === "qqbot").useOiapiNickname,
    true,
  );
  assert.ok(!JSON.stringify(state).includes("fixture-qqbot-client-secret"));
  await qqCard.getByRole("button", { name: "配置", exact: true }).click();
  assert.equal(
    await page.getByLabel("QQBot ClientSecret", { exact: true }).inputValue(),
    "",
  );
  await page.getByLabel("名称", { exact: true }).fill("QQBot 测试配置 2");
  await page.locator("#save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  state = await agentState();
  assert.equal(
    state.connections.find((c) => c.protocol === "qqbot").hasClientSecret,
    true,
  );
  await page.goto(home, { waitUntil: "networkidle" });
  await page.locator("#app").waitFor({ state: "visible" });
  const after = await page.evaluate(async () =>
    (
      await fetch("api/state", {
        headers: { "X-QQM-Request": "1" },
      })
    ).json(),
  );
  assert.deepEqual(after.config, official.config);
  assert.deepEqual(after.bots, official.bots);
  assert.ok(!JSON.stringify(after).includes("隔离测试助手"));
  console.log(
    "PASS: isolated Agent Linux UI, model/preset/extension editing, import defaults, redacted secrets, chat drafts, narrow layouts and official-module isolation.",
  );
}
