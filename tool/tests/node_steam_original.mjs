import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const cache = path.resolve(process.argv[2]);
const archive = path.resolve(process.argv[3]);
const root = await fs.mkdtemp(path.join(process.env.TEMP || os.tmpdir(), 'qqm-steam-original-'));
const hostDir = path.join(root, 'host'); await fs.mkdir(hostDir);
for (const file of await fs.readdir('assets/node_plugins')) if (/\.(mjs|json)$/.test(file)) await fs.copyFile(path.join('assets/node_plugins', file), path.join(hostDir, file));
await fs.symlink(path.join(cache, 'node_modules'), path.join(hostDir, 'node_modules'), process.platform === 'win32' ? 'junction' : 'dir');
const { createHost } = await import(pathToFileURL(path.join(hostDir, 'server.mjs')).href);
const token = randomBytes(32).toString('hex');
const host = await createHost({ root, token });
const url = `http://127.0.0.1:${host.server.address().port}`;
async function api(route, value) {
  const response = await fetch(url + route, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
  const data = await response.json(); if (!response.ok) throw new Error(JSON.stringify(data)); return data;
}
try {
  const response = await fetch(url + '/packages/inspect?filename=steam-plugin.zip', { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: createReadStream(archive), duplex: 'half' });
  const inspected = await response.json(); assert.equal(response.ok, true, JSON.stringify(inspected));
  assert.equal(inspected.name, 'steam-plugin'); assert.deepEqual(inspected.entries, ['index.js']);
  const job = await api('/packages/install', { stage_id: inspected.stage_id, approved: true });
  const deadline = Date.now() + 600000;
  let installed;
  while (Date.now() < deadline) {
    const state = await api('/packages/job', { id: job.id });
    assert.notEqual(state.status, 'failed', state.error);
    if (state.status === 'done') { installed = state.package; break; }
    await new Promise(r => setTimeout(r, 500));
  }
  assert.ok(installed, '原包依赖安装超时');
  const args = { package_id: inspected.id, app_id: 'synthetic-steam-app', config: { owner_openids: '', allow_proactive: false } };
  const result = await api('/v1/message', { ...args, job_id: 'original-menu', message: { message_id: 'original-menu', session_id: 'synthetic-user', sender_id: 'synthetic-user', sender_name: '测试用户', is_group: false, content: '/steam帮助', timestamp: new Date().toISOString() } });
  assert.equal(result.matched, true);
  let image, modules;
  for (let n = 0; n < 300; n++) {
    const state = await api('/v1/poll', args); assert.equal(state.ok, true, state.error);
    modules = state.modules;
    if (state.messages.length) { image = state.messages[0]; break; }
    await new Promise(r => setTimeout(r, 200));
  }
  assert.equal(modules, 22); assert.equal(image?.format, 'media'); assert.equal(image?.mime, 'image/jpeg');
  const bytes = Buffer.from(image.media_base64, 'base64'); assert.ok(bytes.length > 10000);
  await api('/v1/ack', { ...args, id: image.id, result: { ok: true, message_id: 'synthetic-platform-ack' } });
  const config = await api('/packages/file', { id: inspected.id, app_id: args.app_id, scope: 'account', file: 'config/config/steam.yaml' });
  assert.match(config.content, /apiKey/);
  console.log(JSON.stringify({ ok: true, originalPackage: inspected.name, files: inspected.files, dependencyCount: inspected.dependencies.length, modules, originalEntry: inspected.entries, menuImageBytes: bytes.length, rawYamlConfig: true, adapterJson: false }));
} finally {
  await host.close();
  const actual = path.resolve(root), parent = path.resolve(process.env.TEMP || os.tmpdir());
  assert.ok(path.dirname(actual) === parent && path.basename(actual).startsWith('qqm-steam-original-'));
  await fs.rm(actual, { recursive: true, force: true });
}
