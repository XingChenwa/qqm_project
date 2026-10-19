// Browser E2E against the real headless HTTP service with synthetic local data.
import { mkdtemp, readFile, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import assert from "node:assert/strict";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.QQM_PLAYWRIGHT || "playwright");
const data = await mkdtemp(join(tmpdir(), "qqm-server-browser-"));
const shots = resolve("build/server-previews");
await mkdir(shots, { recursive: true });
const dart = process.env.QQM_DART || "dart";
// On Windows QQM_DART must point to dart.exe, not the Flutter .bat wrapper.
const child = spawn(dart, ["run", "tool/server_preview.dart", data], {
  cwd: process.cwd(),
  stdio: ["pipe", "pipe", "pipe"],
  windowsHide: true,
});
let browser;
try {
  const origin = await new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(
      () => reject(Error("Preview start timeout")),
      45000,
    );
    child.stdout.on("data", (chunk) => {
      output += chunk;
      const match = /QQM_PREVIEW_URI=(http:\/\/\S+)/.exec(output);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    child.stderr.on("data", () => {});
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(Error("Preview exited " + code));
    });
  });
  const setupToken = (
    await readFile(join(data, "setup-token.txt"), "utf8")
  ).trim();
  const password = "offline-browser-admin-password-2026";
  const avatarImage = await readFile(resolve("assets/branding/logo.png"));
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1360, height: 900 },
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const avatarRequests = [];
  await page.route("**/*", (route) => {
    const url = route.request().url();
    if (url.startsWith(origin)) return route.continue();
    avatarRequests.push(url);
    if (
      url === "https://example.invalid/private-avatar.png" ||
      url === "https://example.invalid/sender-avatar.png"
    )
      return route.fulfill({ contentType: "image/png", body: avatarImage });
    return route.abort();
  });
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.locator("#setup-view").waitFor({ state: "visible" });
  assert.equal(await page.locator("#login-view").isVisible(), false);
  assert.equal(await page.locator("#app").isVisible(), false);
  const lockedStatus = await page.evaluate(
    async () =>
      (
        await fetch("/api/state", {
          headers: { "X-QQM-Request": "1" },
        })
      ).status,
  );
  assert.equal(lockedStatus, 401);
  for (const width of [1360, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      `setup overflow ${width}`,
    );
    await page.screenshot({
      path: join(shots, `setup-${width}.png`),
      fullPage: true,
    });
  }
  await page.setViewportSize({ width: 1360, height: 900 });
  await page.locator("#setup-token").fill("wrong-initialization-code");
  await page.locator("#setup-password").fill(password);
  await page.locator("#setup-confirm").fill(password + "-different");
  await page.locator("#setup-form button").click();
  await page.getByText("两次输入的管理密码不一致", { exact: true }).waitFor();
  await page.getByRole("button", { name: "知道了", exact: true }).click();
  await page.locator("#setup-confirm").fill(password);
  await page.locator("#setup-form button").click();
  await page
    .getByText("初始化码不正确，请在服务器本地查看 setup-token.txt", {
      exact: true,
    })
    .waitFor();
  assert.equal(await page.locator("#app").isVisible(), false);
  await page.getByRole("button", { name: "知道了", exact: true }).click();
  await page.locator("#setup-token").fill(setupToken);
  await page.locator("#setup-form button").click();
  await page.locator("#app").waitFor({ state: "visible" });
  await assert.rejects(readFile(join(data, "setup-token.txt")), {
    code: "ENOENT",
  });
  const authRecord = await readFile(join(data, "admin-auth.json"), "utf8");
  assert.ok(!authRecord.includes(password) && !authRecord.includes(setupToken));
  await page.locator("#logout").click();
  await page.locator("#login-view").waitFor({ state: "visible" });
  await page.screenshot({ path: join(shots, "login-desktop.png") });
  await page.locator("#password").fill(password);
  await page.locator("#login-form button").click();
  await page.locator("#app").waitFor({ state: "visible" });
  await page.locator(".session-item").filter({ hasText: "薯条同学" }).click();
  await page.locator("#messages .message").waitFor();
  assert.equal(
    await page
      .locator(
        '#messages .avatar img[src="https://example.invalid/private-avatar.png"]',
      )
      .count(),
    1,
  );
  assert.equal(
    await page
      .locator(
        '#chat-avatar img[src="https://example.invalid/private-avatar.png"]',
      )
      .count(),
    1,
  );
  await page
    .locator(".session-item")
    .filter({ hasText: "机器人开发交流群" })
    .click();
  await page.waitForFunction(
    () => document.querySelectorAll(".message").length === 30,
  );
  assert.equal(await page.locator("#sessions .avatar.group img").count(), 0);
  assert.equal(
    await page
      .locator(
        '#messages .avatar img[src="https://example.invalid/sender-avatar.png"]',
      )
      .count(),
    30,
  );
  assert.ok(!avatarRequests.some((url) => url.includes("old-group-avatar")));
  await page.waitForFunction(() => {
    const m = document.querySelector("#messages");
    return m.scrollHeight - m.scrollTop - m.clientHeight < 3;
  });
  await page.screenshot({ path: join(shots, "chat-desktop.png") });
  // Group settings and notifications use the real server routes and offline
  // QQ API fixture, rather than intercepting any management action.
  await page.locator("#chat-settings").click();
  await page.getByText("123 人", { exact: true }).waitFor();
  await page.screenshot({ path: join(shots, "group-settings-desktop.png") });
  await page.setViewportSize({ width: 390, height: 900 });
  assert.ok(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  );
  await page.screenshot({ path: join(shots, "group-settings-mobile.png") });
  await page.getByRole("checkbox", { name: "屏蔽消息提醒" }).check();
  await page.waitForFunction(
    () => S.state.sessions.find((s) => s.id === "group-a").isMuted,
  );
  await page.getByRole("button", { name: "查看群成员", exact: true }).click();
  await page
    .getByRole("button", { name: "加载更多成员", exact: true })
    .waitFor();
  await page.getByRole("button", { name: "加载更多成员", exact: true }).click();
  await page.getByText("测试群主", { exact: true }).waitFor();
  await page
    .locator(".group-member")
    .filter({ hasText: "薯条同学" })
    .getByRole("button", { name: "资料", exact: true })
    .click();
  await page.getByRole("button", { name: "设置禁言", exact: true }).click();
  await page.getByRole("button", { name: "确认禁言", exact: true }).click();
  await page.getByRole("button", { name: "解除禁言", exact: true }).waitFor();
  await page.getByRole("button", { name: "解除禁言", exact: true }).click();
  await page.getByRole("button", { name: "确认解除", exact: true }).click();
  await page.getByText("123 人", { exact: true }).waitFor();
  assert.equal(
    await page.getByRole("button", { name: "解除禁言", exact: true }).count(),
    0,
  );
  await page.getByRole("checkbox", { name: "屏蔽消息提醒" }).uncheck();
  await page.waitForFunction(
    () => !S.state.sessions.find((s) => s.id === "group-a").isMuted,
  );
  await page.locator("#modal-close").click();
  await page.setViewportSize({ width: 1360, height: 900 });
  await page.locator("#notifications").click();
  await page.locator(".group-notice-list .group-card").first().waitFor();
  assert.equal(await page.locator(".group-notice-list .group-card").count(), 3);
  await page.getByRole("button", { name: "待审核", exact: true }).click();
  assert.equal(await page.locator(".group-notice-list .group-card").count(), 1);
  await page.screenshot({ path: join(shots, "notifications-desktop.png") });
  await page.setViewportSize({ width: 320, height: 850 });
  assert.ok(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  );
  await page.screenshot({ path: join(shots, "notifications-mobile.png") });
  await page.getByRole("button", { name: "同意", exact: true }).click();
  await page.getByRole("button", { name: "取消", exact: true }).click();
  await page.getByRole("button", { name: "同意", exact: true }).waitFor();
  await page.getByRole("button", { name: "同意", exact: true }).click();
  await page.getByRole("button", { name: "确认同意", exact: true }).click();
  await page.getByText("入群申请 · 已同意", { exact: true }).waitFor();
  await page
    .getByRole("combobox", { name: "群通知筛选" })
    .selectOption("group-a");
  await page.getByRole("button", { name: "同步入群申请", exact: true }).click();
  await page.getByRole("button", { name: "下一页申请", exact: true }).click();
  await page.getByRole("button", { name: "拒绝", exact: true }).click();
  assert.equal(
    await page.locator("#modal input[type=checkbox]").isChecked(),
    false,
  );
  await page.getByRole("textbox", { name: "拒绝理由" }).fill("离线测试拒绝");
  await page.getByRole("button", { name: "确认拒绝", exact: true }).click();
  await page.getByText("入群申请 · 已拒绝", { exact: true }).waitFor();
  await page.getByRole("button", { name: "全部已读", exact: true }).click();
  await page.locator("#notice-count").waitFor({ state: "hidden" });
  await page.locator("#modal-close").click();
  await page.setViewportSize({ width: 1360, height: 900 });
  assert.equal(await page.locator("#messages .message").count(), 30);
  await page.locator("#draft").fill("第一行");
  await page.locator("#draft").press("Control+Enter");
  await page.locator("#draft").press("End");
  await page.locator("#draft").pressSequentially("第二行");
  assert.equal(await page.locator("#draft").inputValue(), "第一行\n第二行");
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  await page
    .locator("#draft")
    .fill(
      '# 实时预览\n**文字和代码**\n<qqbot-at-user id="member-a" />\n<script>window.untrustedExecuted=true</script>',
    );
  assert.ok(
    (await page.locator("#preview").innerText()).includes(
      "@薯条同学（member-a）",
    ),
  );
  assert.equal(await page.evaluate(() => window.untrustedExecuted), undefined);
  await page.screenshot({ path: join(shots, "markdown-desktop.png") });
  await page.getByRole("button", { name: "文字", exact: true }).click();
  let extra = [];
  await page.route("**/api/messages?*", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    body.messages[28].body = {
      text: "引用消息",
      elements: [{ text: "可重复展开的内容", elements: [] }],
    };
    body.messages.push(...extra);
    await route.fulfill({ response, json: body });
  });
  await page.locator("#messages").evaluate((node) => {
    node.scrollTop = 0;
  });
  extra.push({
    id: "new-inbound",
    senderId: "member-a",
    senderName: "薯条同学",
    content: "新消息不自动向下",
    isFromBot: false,
    time: new Date().toISOString(),
  });
  // The core revision is independent of this local-only response fixture.
  await page.evaluate(async () => {
    await fetch("/api/read", {
      method: "POST",
      headers: { "X-QQM-Request": "1", "Content-Type": "application/json" },
      body: JSON.stringify({ appId: "10000001", session: "group-a" }),
    });
  });
  await page.locator("#new-messages").waitFor({ state: "visible" });
  assert.equal(
    await page.locator("#messages").evaluate((node) => node.scrollTop),
    0,
  );
  await page.locator("#messages details").evaluate((node) => {
    node.open = true;
  });
  extra.push({
    id: "another-inbound",
    senderId: "member-a",
    senderName: "薯条同学",
    content: "保留引用展开状态",
    isFromBot: false,
    time: new Date().toISOString(),
  });
  await page.evaluate(async () => {
    await fetch("/api/read", {
      method: "POST",
      headers: { "X-QQM-Request": "1", "Content-Type": "application/json" },
      body: JSON.stringify({ appId: "10000001", session: "group-a" }),
    });
  });
  await page.waitForFunction(
    () => document.querySelectorAll(".message").length === 32,
  );
  assert.equal(
    await page.locator("#messages details").evaluate((node) => node.open),
    true,
  );
  let sendIndex = 0,
    holdNext = false,
    releaseSend;
  await page.route("**/api/send", async (route) => {
    const body = route.request().postDataJSON();
    extra.push({
      id: "new-outbound-" + ++sendIndex,
      senderId: "bot",
      senderName: "小助手",
      content: body.content,
      isFromBot: true,
      time: new Date().toISOString(),
    });
    if (holdNext) {
      holdNext = false;
      await new Promise((resolve) => {
        releaseSend = resolve;
      });
    }
    await route.fulfill({ json: { ok: true } });
  });
  await page.locator("#draft").fill("回车发送的消息");
  await page.locator("#draft").press("Enter");
  await page.waitForFunction(
    () => document.querySelector("#draft").value === "",
  );
  await page.waitForFunction(() => {
    const m = document.querySelector("#messages");
    return m.scrollHeight - m.scrollTop - m.clientHeight < 3;
  });
  holdNext = true;
  const pendingSend = page.waitForRequest("**/api/send");
  await page.locator("#draft").fill("较慢的发送");
  await page.locator("#draft").press("Enter");
  await pendingSend;
  await page.locator("#draft").fill("发送期间写的新草稿");
  assert.equal(typeof releaseSend, "function");
  releaseSend();
  await page.waitForFunction(() => !document.querySelector("#send").disabled);
  assert.equal(await page.locator("#draft").inputValue(), "发送期间写的新草稿");
  for (const width of [1360, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const name of ["plugins", "logs", "settings"]) {
      await page.locator(`[data-page=${name}]`).click();
      assert.ok(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        `horizontal overflow ${name}/${width}`,
      );
      if (name === "plugins")
        assert.equal(await page.locator(".plugin-card").count(), 7);
      if (width === 390 || width === 1360)
        await page.screenshot({ path: join(shots, `${name}-${width}.png`) });
    }
    await page.locator("[data-page=chat]").click();
    if (width < 760) {
      await page.locator("#back-sessions").click();
      await page.screenshot({ path: join(shots, `sessions-${width}.png`) });
      await page
        .locator(".session-item")
        .filter({ hasText: "机器人开发交流群" })
        .click();
    }
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      `chat overflow ${width}`,
    );
    if (width < 760)
      await page.screenshot({ path: join(shots, `chat-${width}.png`) });
  }
  await page.setViewportSize({ width: 1360, height: 900 });
  await page.locator("[data-page=plugins]").click();
  const card = page.locator(".plugin-card").filter({ hasText: "基础助手" });
  await card.getByRole("button", { name: "编辑源码" }).click();
  await page.getByRole("textbox", { name: "插件源码" }).waitFor();
  assert.ok(
    (await page.getByRole("textbox", { name: "插件源码" }).inputValue())
      .length > 20,
  );
  await page.getByRole("button", { name: "保存文件", exact: true }).click();
  await page
    .getByRole("button", { name: "安装 / 替换插件", exact: true })
    .click();
  await page.getByRole("button", { name: "知道了", exact: true }).click();
  assert.equal(await card.locator("input[type=checkbox]").isChecked(), false);
  await page.locator("[data-page=settings]").click();
  await page.locator("#theme").selectOption("dark");
  assert.equal(await page.locator("html").getAttribute("data-theme"), "dark");
  await page.reload({ waitUntil: "networkidle" });
  await page.locator("#app").waitFor({ state: "visible" });
  assert.equal(await page.locator("html").getAttribute("data-theme"), "dark");
  await page.locator("[data-page=settings]").click();
  await page.locator("#settings-logout").click();
  await page.locator("#login-view").waitFor({ state: "visible" });
  assert.deepEqual(errors, []);
  console.log(
    "PASS: mandatory first-install password setup, desktop/mobile layouts, personal avatars preserved without group avatar requests, Markdown/@ preview/XSS protection, Enter/Ctrl+Enter, scroll policy, plugin editor, persisted theme and logout.",
  );
} finally {
  await browser?.close();
  child.stdin.end("stop\n");
  await new Promise((resolve) => {
    if (child.exitCode !== null) return resolve();
    child.once("exit", resolve);
    setTimeout(() => {
      child.kill();
      resolve();
    }, 5000).unref();
  });
  assert.ok(data.startsWith(join(tmpdir(), "qqm-server-browser-")));
  await rm(data, {
    recursive: true,
    force: true,
    maxRetries: 5,
    retryDelay: 200,
  });
}
