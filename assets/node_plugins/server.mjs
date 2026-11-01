import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import { fork } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { Packages, digest, packageIdPattern, appIdPattern, cleanEnvironment } from './packages.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const sleep = ms => new Promise(r => setTimeout(r, ms));
export async function createHost({ root, token, port = 0, host = '127.0.0.1', npmPath, idleMs = 90000 }) {
  if (typeof token !== 'string' || token.length < 32) throw new Error('运行环境连接令牌无效。');
  const authHash = Buffer.from(digest(token), 'hex');
  const packages = new Packages(root, npmPath); await packages.init();
  const workers = new Map(); let closed = false;
  const send = (res, status, value) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(JSON.stringify(value)); };
  const authenticated = req => { const header = req.headers.authorization || ''; return header.startsWith('Bearer ') && timingSafeEqual(authHash, Buffer.from(digest(header.slice(7)), 'hex')); };
  const keyOf = (id, appId) => `${id}:${appId}`;
  function stop(item) {
    if (item.stopping) return item.stopping;
    item.stopped = true;
    for (const pending of item.matching.values()) { clearTimeout(pending.timer); pending.resolve(false); }
    item.matching.clear();
    item.stopping = (async () => {
      const child = item.child;
      if (child && child.exitCode == null && child.signalCode == null) {
        const exited = new Promise(resolve => child.once('exit', resolve));
        if (child.connected) child.send({ kind: 'stop' });
        const timer = setTimeout(() => child.kill(), 2000).unref();
        await exited; clearTimeout(timer);
      }
      await item.boot;
      if (workers.get(item.key) === item) workers.delete(item.key);
    })();
    return item.stopping;
  }
  const stopPackage = id => Promise.all([...workers.values()].filter(w => w.id === id).map(stop));
  async function worker(id, appId, config) {
    const key = keyOf(id, appId), revision = digest(JSON.stringify(config));
    let item = workers.get(key);
    while (item && (item.revision !== revision || item.stopped)) { await stop(item); item = workers.get(key); }
    if (item) { item.seen = Date.now(); return item; }
    if (workers.size >= 8) throw new Error('同时运行的原版插件已达 8 个，请先停用部分插件。');
    if (packages.active.has(id)) throw new Error('此插件正在安装依赖，请稍后启用。');
    item = { key, id, appId, revision, seen: Date.now(), ready: false, stopped: false, error: '', diagnostic: '', rules: [], contexts: [], matching: new Map(), jobs: new Set(), recent: new Map(), outbox: new Map() };
    workers.set(key, item);
    item.boot = (async () => {
      const prepared = await packages.prepare(id, appId);
      for (const [folder, file, source] of [
        ['plugins', 'plugin.js', `export {default} from ${JSON.stringify(new URL('./shim-plugin.mjs', import.meta.url).href)};`],
        ['common', 'common.js', `export {default} from ${JSON.stringify(new URL('./common.mjs', import.meta.url).href)};`],
        ['puppeteer', 'puppeteer.js', 'export default global.qqmPluginRenderer;'],
      ]) { const dir = path.join(prepared.account, 'lib', folder); await fs.mkdir(dir, { recursive: true }); await fs.writeFile(path.join(dir, file), source); }
      if (item.stopped || closed) return;
      const env = { ...cleanEnvironment(), NODE_PATH: path.join(here, 'node_modules'), QQM_PLUGIN_DIRECTORY: prepared.plugin };
      const child = fork(path.join(here, 'worker.mjs'), [], { cwd: prepared.account, env, execArgv: [], windowsHide: true, stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
      item.child = child;
      child.on('message', payload => {
        if (item.stopped) return;
        if (payload.kind === 'ready') { item.ready = true; item.modules = payload.modules; item.rules = payload.rules || []; }
        else if (payload.kind === 'failed') item.error = payload.message;
        else if (payload.kind === 'contexts') item.contexts = payload.contexts || [];
        else if (payload.kind === 'diagnostic') item.diagnostic = String(payload.message || '').slice(0, 300);
        else if (payload.kind === 'matched') { const pending = item.matching.get(payload.id); if (pending) { clearTimeout(pending.timer); item.matching.delete(payload.id); pending.resolve(payload.matched === true); } }
        else if (payload.kind === 'job_done') item.jobs.delete(payload.job_id);
        else if (payload.kind === 'outbox') {
          const envelope = payload.envelope;
          if (envelope.app_id !== appId || typeof envelope.id !== 'string' || item.outbox.size >= 64 || JSON.stringify(envelope).length > 8 * 1024 * 1024) {
            if (child.connected) child.send({ kind: 'ack', id: envelope.id, result: { ok: false, error: '插件回复超过队列或图片大小限制。' } }); return;
          }
          item.outbox.set(envelope.id, { envelope, created: Date.now(), leased: 0 });
        }
      });
      child.on('error', () => { item.error = 'Node 子进程启动失败。'; });
      child.on('exit', () => { if (!item.stopped) { item.ready = false; item.error ||= '原版插件进程已退出，请检查配置后重新加载。'; } });
      child.send({ kind: 'init', appId, config, entries: prepared.metadata.entries });
      const deadline = Date.now() + 40000;
      while (!item.ready && !item.error && !item.stopped && Date.now() < deadline) await sleep(100);
      if (!item.ready && !item.stopped) item.error ||= '原版插件初始化超时。';
    })().catch(error => { item.error = error.message?.startsWith('插件依赖') ? error.message : error.code === 'ENOENT' ? '原包文件或依赖不存在，请重新安装依赖。' : '原包启动失败，请检查配置及文件权限。'; });
    return item;
  }
  function matches(item, message) {
    const id = randomUUID();
    return new Promise(resolve => {
      const timer = setTimeout(() => { item.matching.delete(id); item.error = '原包规则匹配超过 5 秒，已停止该插件进程，请检查正则表达式。'; item.child?.kill(); resolve(false); }, 5000).unref();
      item.matching.set(id, { resolve, timer });
      if (item.child?.connected) item.child.send({ kind: 'match', id, message });
      else { clearTimeout(timer); item.matching.delete(id); resolve(false); }
    });
  }
  async function body(req, limit = 8 * 1024 * 1024) {
    const chunks = []; let size = 0;
    for await (const chunk of req) { size += chunk.length; if (size > limit) throw new Error('请求内容过大。'); chunks.push(chunk); }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }
  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/health') { send(res, 200, { ok: true, service: 'qqm-node-plugin-host', protocol: 'qqm-node-v1', node: process.versions.node }); return; }
    if (req.method !== 'POST' || req.headers.origin || !authenticated(req)) { send(res, 403, { error: '运行环境访问被拒绝。' }); return; }
    try {
      const url = new URL(req.url, 'http://localhost');
      if (url.pathname === '/packages/inspect') {
        const result = await packages.upload(req, url.searchParams.get('filename') || 'plugin.zip', url.searchParams.get('kind') || 'zip');
        send(res, 200, result); return;
      }
      const value = await body(req);
      if (url.pathname === '/packages/repository') { send(res, 200, await packages.repository(value.url)); return; }
      if (url.pathname === '/packages/list') { send(res, 200, { packages: await packages.list() }); return; }
      if (url.pathname === '/packages/stage') {
        const item = packages.stages.get(value.stage_id);
        if (!item) throw new Error('导入预览不存在，请重新选择原包。');
        send(res, 200, item.metadata); return;
      }
      if (url.pathname === '/packages/activity') { send(res, 200, { busy: packages.active.size > 0 }); return; }
      if (url.pathname === '/packages/dependencies') { send(res, 202, await packages.dependencies(value.id, stopPackage)); return; }
      if (url.pathname === '/packages/install') {
        if (value.approved !== true) throw new Error('请先确认信任这个插件原包。');
        send(res, 202, await packages.install(value.stage_id, value.replace === true, stopPackage)); return;
      }
      if (url.pathname === '/packages/job') {
        const job = packages.jobs.get(value.id); if (!job) throw new Error('找不到安装任务。'); send(res, 200, job); return;
      }
      if (url.pathname === '/packages/files') { send(res, 200, await packages.files(value.id, value.app_id, value.scope)); return; }
      if (url.pathname === '/packages/file') { send(res, 200, await packages.file(value.id, value.app_id, value.scope, value.file, value.content)); return; }
      if (url.pathname === '/packages/reload') { await stopPackage(value.id); send(res, 200, { ok: true }); return; }
      if (url.pathname === '/packages/remove') {
        await stopPackage(value.id);
        const source = packages.directory(value.id);
        await fs.rename(source, path.join(root, 'removed', `${value.id}-${Date.now()}`));
        send(res, 200, { ok: true }); return;
      }
      if (url.pathname === '/shutdown') {
        if (packages.active.size) throw new Error('依赖安装尚未完成，请稍后再执行迁移或关闭运行环境。');
        await Promise.all([...workers.values()].map(stop)); send(res, 200, { ok: true });
        setTimeout(() => close(), 50).unref(); return;
      }
      const id = value.package_id, appId = value.app_id;
      if (!packageIdPattern.test(id || '') || !appIdPattern.test(appId || '')) throw new Error('插件或 AppID 无效。');
      if (url.pathname === '/v1/deactivate') { const item = workers.get(keyOf(id, appId)); if (item) await stop(item); send(res, 200, { ok: true }); return; }
      const config = value.config || {};
      if (typeof config.owner_openids !== 'string' || config.owner_openids.length > 8192 || typeof config.allow_proactive !== 'boolean') throw new Error('插件宿主设置无效。');
      const item = await worker(id, appId, config);
      if (url.pathname === '/v1/poll') {
        const now = Date.now();
        for (const [key, entry] of item.outbox) if (now - entry.created > 120000) item.outbox.delete(key);
        const entry = [...item.outbox.values()].find(v => v.leased < now);
        if (entry) entry.leased = now + 90000;
        send(res, 200, { ok: !item.error, ready: item.ready, error: item.error || undefined, diagnostic: item.diagnostic, modules: item.modules, rules: item.rules, messages: entry ? [entry.envelope] : [] }); return;
      }
      if (url.pathname === '/v1/ack') {
        if (typeof value.id !== 'string' || typeof value.result?.ok !== 'boolean') throw new Error('消息确认格式无效。');
        if (item.outbox.has(value.id)) { if (item.child?.connected) item.child.send({ kind: 'ack', id: value.id, result: value.result }); item.outbox.delete(value.id); }
        send(res, 200, { ok: true }); return;
      }
      if (url.pathname !== '/v1/message') { send(res, 404, { error: '接口不存在。' }); return; }
      const message = value.message;
      if (!message || typeof message.content !== 'string' || message.content.length > 16000 || !appIdPattern.test(message.session_id || '') || !appIdPattern.test(message.sender_id || '') || typeof message.is_group !== 'boolean' || typeof message.message_id !== 'string' || !message.message_id || message.message_id.length > 512 || typeof value.job_id !== 'string' || value.job_id.length > 512) throw new Error('原消息格式无效。');
      await item.boot;
      if (!item.ready || item.error) throw new Error(item.error || '原版插件尚未就绪。');
      const matched = await matches(item, message);
      if (!matched) { send(res, 200, { ok: true, matched: false }); return; }
      for (const [key, time] of item.recent) if (Date.now() - time > 600000) item.recent.delete(key);
      if (item.recent.has(value.job_id)) { send(res, 200, { ok: true, matched: true }); return; }
      if (item.jobs.size >= 4) { send(res, 429, { error: '此插件正在处理其他消息，请稍后重试。' }); return; }
      item.jobs.add(value.job_id); item.recent.set(value.job_id, Date.now());
      while (item.recent.size > 512) item.recent.delete(item.recent.keys().next().value);
      item.child.send({ kind: 'message', message, job_id: value.job_id });
      send(res, 202, { ok: true, matched: true });
    } catch (error) {
      // Local path / upstream error objects and install script output can carry
      // credentials. Only our explicit short operational errors are returned.
      const safe = String(error.message || '').replace(/[\r\n]/g, ' ');
      const message = /^(插件|原|ZIP|GitHub|没有|未|请|运行|此|当前|同时|文件|依赖|npm|导入|package\.json|Node|不允许|找不到|请求)/.test(safe) && safe.length < 300 ? safe : '插件操作失败，请检查运行环境、原包格式或文件权限。';
      send(res, 400, { error: message });
    }
  });
  server.requestTimeout = 180000; server.headersTimeout = 15000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  const timer = setInterval(() => { for (const item of workers.values()) if (Date.now() - item.seen > idleMs) stop(item); }, Math.min(idleMs, 15000)).unref();
  async function close() { if (closed) return; closed = true; clearInterval(timer); packages.cancel(); await Promise.all([...workers.values()].map(stop)); await new Promise(r => server.close(r)); }
  return { server, packages, workers, close };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argument = name => { const i = process.argv.indexOf(name); return i >= 0 ? process.argv[i + 1] : undefined; };
  const root = path.resolve(argument('--root') || path.join(here, '../data'));
  await fs.mkdir(root, { recursive: true });
  let token = process.env.QQM_NODE_HOST_TOKEN;
  if (!token) {
    const auth = path.join(root, 'connection.json');
    try { token = JSON.parse(await fs.readFile(auth, 'utf8')).token; }
    catch (error) { if (error.code !== 'ENOENT') throw error; token = randomBytes(32).toString('hex'); await fs.writeFile(auth, JSON.stringify({ token }), { mode: 0o600, flag: 'wx' }); }
  }
  const service = await createHost({ root, token, port: Number(argument('--port') || 0), host: argument('--listen') || '127.0.0.1', npmPath: argument('--npm') });
  console.log(JSON.stringify({ type: 'ready', service: 'qqm-node-plugin-host', port: service.server.address().port, node: process.versions.node }));
  process.on('SIGTERM', () => service.close().then(() => process.exit(0)));
  process.on('SIGINT', () => service.close().then(() => process.exit(0)));
  if (process.argv.includes('--managed-stdio')) {
    process.stdin.resume();
    process.stdin.on('end', () => service.close().then(() => process.exit(0)));
  }
  if (process.send) process.on('disconnect', () => service.close().then(() => process.exit(0)));
}
