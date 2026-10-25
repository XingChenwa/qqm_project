// Fast Agent-only browser regression using the same isolated server fixture.
import { mkdtemp, readFile, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import assert from "node:assert/strict";
import { verifyAgent } from "./agent_browser.mjs";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.QQM_PLAYWRIGHT || "playwright");
const data = await mkdtemp(join(tmpdir(), "qqm-server-browser-"));
const shots = resolve("build/server-previews");
await mkdir(shots, { recursive: true });
const child = spawn(
  process.env.QQM_DART || "dart",
  ["run", "tool/server_preview.dart", data],
  { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"], windowsHide: true },
);
let browser, page;
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
  const token = (await readFile(join(data, "setup-token.txt"), "utf8")).trim();
  browser = await chromium.launch({ headless: true });
  page = await browser.newPage({ viewport: { width: 1360, height: 900 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.route("**/*", (route) =>
    route.request().url().startsWith(origin) ? route.continue() : route.abort(),
  );
  const response = await page.request.post(origin + "/api/setup", {
    headers: { "X-QQM-Request": "1" },
    data: {
      token,
      password: "local-agent-test-password",
      confirmation: "local-agent-test-password",
      entrance: "offline-agent-entrance",
    },
  });
  assert.equal(response.status(), 200);
  await page.goto(origin + "/offline-agent-entrance/", {
    waitUntil: "networkidle",
  });
  await page.locator("#app").waitFor({ state: "visible" });
  try {
    await verifyAgent(page, shots);
  } catch (error) {
    // Only synthetic fixture data is present in this isolated page.
    console.error("Fixture page errors:", errors);
    console.error("Fixture view:", await page.locator("body").innerText());
    throw error;
  }
  assert.deepEqual(errors, []);
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
