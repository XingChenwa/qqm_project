import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const cache = path.resolve(process.argv[2]);
const root = await fs.mkdtemp(path.join(process.env.TEMP || os.tmpdir(), 'qqm-original-node-'));
const hostDir = path.join(root, 'host');
await fs.mkdir(hostDir);
for (const file of await fs.readdir('assets/node_plugins')) if (/\.(mjs|json)$/.test(file)) await fs.copyFile(path.join('assets/node_plugins', file), path.join(hostDir, file));
await fs.symlink(path.join(cache, 'node_modules'), path.join(hostDir, 'node_modules'), process.platform === 'win32' ? 'junction' : 'dir');
const { createHost } = await import(pathToFileURL(path.join(hostDir, 'server.mjs')).href);
const token = randomBytes(32).toString('hex');
const service = await createHost({ root, token, port: 0 });
const base = `http://127.0.0.1:${service.server.address().port}`;
async function api(route, data = {}, auth = token) {
  const r = await fetch(base + route, { method: 'POST', headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  return { status: r.status, value: await r.json() };
}
const config = { owner_openids: '', allow_proactive: false };
let id;
const args = (app = 'app-A') => ({ package_id: id, app_id: app, config });
async function until(action) {
  const end = Date.now() + 90000;
  while (Date.now() < end) { const result = await action(); if (result) return result; await new Promise(r => setTimeout(r, 100)); }
  throw new Error('等待原版插件超时。');
}
async function output(app = 'app-A') {
  return until(async () => {
    const { value } = await api('/v1/poll', args(app));
    assert.equal(value.ok, true, value.error);
    return value.messages?.[0];
  });
}
async function ack(item, app = 'app-A') {
  assert.equal((await api('/v1/ack', { ...args(app), id: item.id, result: { ok: true, message_id: 'real-test-platform-id' } })).value.ok, true);
  await new Promise(r => setTimeout(r, 60));
}
let serial = 0;
async function message(content, app = 'app-A') {
  const source = `source-${++serial}`;
  const r = await api('/v1/message', { ...args(app), job_id: source, message: { message_id: source, session_id: 'group', sender_id: 'user', sender_name: '测试用户', is_group: true, content, timestamp: new Date().toISOString() } });
  assert.ok(r.status < 300, JSON.stringify(r.value));
  return r.value;
}
try {
  assert.equal((await api('/packages/list', {}, 'invalid')).status, 403);
  assert.equal((await api('/packages/repository', { url: 'http://127.0.0.1/source.zip' })).status, 400);
  const upload = await fetch(base + '/packages/inspect?kind=js&filename=generic-demo.js', { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: createReadStream('test/fixtures/node_original/demo.js'), duplex: 'half' });
  const preview = await upload.json();
  assert.equal(upload.status, 200, JSON.stringify(preview));
  assert.match(preview.id, /^node_generic_demo_/); id = preview.id;
  assert.deepEqual((await api('/packages/list')).value.packages, [], '检查时不安装、不运行原包');
  assert.equal((await api('/packages/install', { stage_id: preview.stage_id })).status, 400, '必须确认信任后才可安装');
  const job = (await api('/packages/install', { stage_id: preview.stage_id, approved: true })).value;
  await until(async () => { const { value } = await api('/packages/job', { id: job.id }); assert.notEqual(value.status, 'failed', value.error); return value.status === 'done'; });
  assert.equal(service.workers.size, 0, '安装后默认不运行');
  assert.equal((await message('普通聊天')).matched, false);
  assert.equal((await message('/原包测试')).matched, true);
  const first = await output(); assert.equal(first.content, '原包测试：默认配置 / 1'); await ack(first);
  await message('/原生发送'); const native = await output(); assert.equal(native.content, '原生接口回复'); assert.equal(native.proactive, false); await ack(native);
  const source = await api('/packages/file', { id, app_id: 'app-A', scope: 'source', file: 'apps/main.js' });
  assert.equal(source.value.content, await fs.readFile('test/fixtures/node_original/demo.js', 'utf8'), '运行原 JS，无生成或覆盖插件逻辑');
  assert.equal((await api('/packages/file', { id, app_id: 'app-A', scope: 'account', file: 'config/label.txt', content: '独立配置' })).value.ok, true);
  await message('/原包测试'); const second = await output(); assert.equal(second.content, '原包测试：独立配置 / 2'); await ack(second);
  await message('/原包测试', 'app-B'); const other = await output('app-B'); assert.equal(other.content, '原包测试：默认配置 / 1'); await ack(other, 'app-B');
  await message('/图片测试'); const image = await output(); assert.equal(image.format, 'media'); assert.equal(image.mime, 'image/png'); await ack(image);
  await message('/上下文测试'); await ack(await output());
  assert.equal((await message('下一条文字')).matched, true); const context = await output(); assert.equal(context.content, '上下文：下一条文字'); await ack(context);
  assert.equal((await api('/packages/file', { id, app_id: 'app-A', scope: 'source', file: '../outside.txt', content: 'bad' })).status, 400);
  await api('/packages/file', { id, app_id: 'app-A', scope: 'source', file: 'apps/main.js', content: source.value.content.replace('原包测试：', '重载成功：') });
  await api('/packages/reload', { id });
  await message('/原包测试'); const reload = await output(); assert.equal(reload.content, '重载成功：独立配置 / 3'); await ack(reload);
  await api('/v1/deactivate', args());
  assert.equal(service.workers.has(`${id}:app-A`), false);
  console.log(JSON.stringify({ ok: true, checks: ['auth', 'repository-policy', 'inspect-without-execution', 'trust-before-npm', 'original-js', 'slash-alias', 'node-http', 'native-send-passive', 'raw-config', 'appid-isolation', 'real-image', 'context', 'safe-path', 'external-source-reload', 'data-preserved', 'deactivate'] }));
} finally {
  await service.close();
  // This freshly-created test directory is the only cleanup target.
  const resolved = path.resolve(root), parent = path.resolve(process.env.TEMP || os.tmpdir());
  assert.ok(path.dirname(resolved) === parent && path.basename(resolved).startsWith('qqm-original-node-'));
  await fs.rm(resolved, { recursive: true, force: true });
}
