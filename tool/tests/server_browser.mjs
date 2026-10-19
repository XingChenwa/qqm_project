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
  const password = (
    await readFile(join(data, "admin-password.txt"), "utf8")
  ).trim();
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1360, height: 900 },
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.route("**/*", (route) =>
    route.request().url().startsWith(origin) ? route.continue() : route.abort(),
  );
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.locator("#login-view").waitFor({ state: "visible" });
  await page.screenshot({ path: join(shots, "login-desktop.png") });
  await page.locator("#password").fill(password);
  await page.locator("#login-form button").click();
  await page.locator("#app").waitFor({ state: "visible" });
  await page
    .locator(".session-item")
    .filter({ hasText: "机器人开发交流群" })
    .click();
  await page.waitForFunction(
    () => document.querySelectorAll(".message").length === 30,
  );
  assert.equal(await page.locator("#sessions .avatar.group img").count(), 0);
  await page.waitForFunction(() => {
    const m = document.querySelector("#messages");
    return m.scrollHeight - m.scrollTop - m.clientHeight < 3;
  });
  await page.screenshot({ path: join(shots, "chat-desktop.png") });
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
    "PASS: real web console desktop/mobile layouts, no group avatar requests, Markdown/@ preview/XSS protection, Enter/Ctrl+Enter, scroll policy, plugin editor, persisted theme and logout.",
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
