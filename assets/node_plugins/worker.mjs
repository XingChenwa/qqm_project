import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { register } from 'node:module';
import { AsyncLocalStorage } from 'node:async_hooks';
import { createRedis } from './redis.mjs';
import { createRenderer } from './renderer.mjs';

const root = path.resolve(process.env.QQM_PLUGIN_DIRECTORY);
const renderer = createRenderer(root);
global.qqmPluginRenderer = renderer;
register(new URL('./loader.mjs', import.meta.url), { data: { fallback: new URL('./package.json', import.meta.url).href } });
const pending = new Map();
let context;
let instances = [];
let initialized = false;
let closing = false;
const users = new Map();
const messageScope = new AsyncLocalStorage();
const contexts = new Map();
const tasks = [];
class DeliveryError extends Error {}
class HostCapabilityError extends Error { constructor(name) { super(`原工作台尚未提供此原包接口：${name}`); this.qqmSafe = true; } }

// Never forward exception bodies: upstream HTTP errors may contain API tokens.
global.logger = Object.fromEntries(['debug', 'info', 'mark', 'warn', 'error', 'trace'].map(level => [level, (...args) => {
  const safe = args.find(arg => arg?.qqmSafe === true);
  if (safe && String(safe.message).length < 300) process.send?.({ kind: 'diagnostic', message: safe.message });
  if (level === 'error' || level === 'warn') process.send?.({ kind: 'log', level, message: '原版插件报告运行异常，请检查依赖、配置或网络。' });
}]));
global.logger.red = global.logger.green = global.logger.yellow = s => String(s);
global.logger.log = (level, ...args) => global.logger[level]?.(...args);
global.plugin = class {
  constructor(options = {}) { Object.assign(this, { priority: 100, rule: [], event: 'message', ...options }); }
  reply(message, quote, data) { const e = messageScope.getStore(); if (!e) throw new Error('当前没有可回复的消息。'); return e.reply(message, quote, data); }
  setContext(type, isGroup = false, timeout = 120) {
    const e = messageScope.getStore(); if (!e) throw new Error('当前没有会话。');
    contexts.set(`${isGroup ? 'group:' + e.group_id : 'user:' + (e.group_id || e.user_id) + ':' + e.user_id}`, { instance: this, type, until: Date.now() + timeout * 1000 });
    process.send?.({ kind: 'contexts', contexts: [...contexts.entries()].map(([key, item]) => ({ key, until: item.until })) });
  }
  finish(type) {
    for (const [key, item] of contexts) if (item.instance === this && (!type || item.type === type)) contexts.delete(key);
    process.send?.({ kind: 'contexts', contexts: [...contexts.entries()].map(([key, item]) => ({ key, until: item.until })) });
  }
};
global.segment = Object.fromEntries(['image', 'record', 'video', 'file'].map(type => [type, file => ({ type, file })]));
global.segment.text = text => ({ type: 'text', text: String(text) });
global.segment.at = qq => ({ type: 'at', qq: String(qq) });

function request(envelope) {
  if (closing) return Promise.reject(new Error('插件已停止。'));
  const id = randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new DeliveryError('管理器未确认发送结果，已停止等待。')); }, 120000).unref();
    pending.set(id, { resolve, reject, timer });
    process.send?.({ kind: 'outbox', envelope: { id, app_id: context.appId, ...envelope } });
  });
}

const avatar = uid => `https://q.qlogo.cn/qqapp/${encodeURIComponent(context.appId)}/${encodeURIComponent(uid)}/640`;
function sendTo(value, target) {
  const e = messageScope.getStore();
  if (e && e.isGroup === target.is_group && String(e.isGroup ? e.group_id : e.user_id) === target.target_id) return e.reply(value);
  return send(value, { ...target, proactive: true });
}
function friend(uid) {
  uid = String(uid);
  return { getInfo: async () => ({ user_id: uid, nickname: users.get(uid) || uid }), getAvatarUrl: () => avatar(uid), sendMsg: msg => sendTo(msg, { target_id: uid, is_group: false }), recallMsg: message_id => request({ action: 'recall', target_id: uid, is_group: false, message_id }) };
}
function group(gid) {
  gid = String(gid);
  return { pickMember: uid => friend(uid), getMemberMap: async () => {
    const result = await request({ action: 'members', target_id: gid, is_group: true });
    if (!result.ok) throw new Error('群成员列表不可用，请检查 QQ 平台接口权限。');
    for (const member of result.members) {
      const id = member.member_openid || member.user_openid || member.id;
      if (id && member.username) users.set(id, member.username);
    }
    return new Map(result.members.map(m => [m.member_openid || m.user_openid || m.id, m]));
  }, sendMsg: msg => sendTo(msg, { target_id: gid, is_group: true }), recallMsg: message_id => request({ action: 'recall', target_id: gid, is_group: true, message_id }) };
}

function imageMime(bytes) {
  if (bytes.subarray(0, 3).equals(Buffer.from([255, 216, 255]))) return 'image/jpeg';
  if (bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
  if (bytes.subarray(0, 6).toString().startsWith('GIF8')) return 'image/gif';
  if (bytes.subarray(0, 4).toString() === 'RIFF' && bytes.subarray(8, 12).toString() === 'WEBP') return 'image/webp';
  throw new Error('插件返回的图片格式无法识别。');
}

async function imageBytes(source) {
  if (Buffer.isBuffer(source) || source instanceof Uint8Array) return Buffer.from(source);
  if (typeof source !== 'string') throw new Error('图片内容无效。');
  if (source.length > 8 * 1024 * 1024) throw new Error('图片超过大小限制。');
  if (source.startsWith('base64://')) return Buffer.from(source.slice(9), 'base64');
  if (/^data:image\/[a-z+.-]+;base64,/.test(source)) return Buffer.from(source.split(',')[1], 'base64');
  if (/^https?:/.test(source)) {
    let url = new URL(source);
    for (let i = 0; i < 4; i++) {
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || /^(localhost|127\.|0\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$)/i.test(url.hostname)) throw new Error('插件图片地址无效或指向本地网络。');
      const response = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(20000) });
      if ([301, 302, 303, 307, 308].includes(response.status)) { await response.body?.cancel(); url = new URL(response.headers.get('location'), url); continue; }
      if (!response.ok) { await response.body?.cancel(); throw new Error('插件图片下载失败。'); }
      const chunks = []; let size = 0;
      for await (const chunk of response.body) { size += chunk.length; if (size > 5 * 1024 * 1024) { throw new Error('插件图片超过 5 MB。'); } chunks.push(chunk); }
      return Buffer.concat(chunks);
    }
    throw new Error('图片跳转次数过多。');
  }
  const file = source.startsWith('file:') ? new URL(source) : path.resolve(root, source);
  const absolute = await fs.realpath(file);
  const relative = path.relative(root, absolute);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('拒绝访问插件目录外的图片。');
  if ((await fs.stat(absolute)).size > 5 * 1024 * 1024) throw new Error('图片超过 5 MB。');
  return fs.readFile(absolute);
}

async function partsOf(value, result = [], depth = 0) {
  if (depth > 12 || result.length > 80) throw new Error('插件回复过长，请减少查询数量。');
  if (value == null || typeof value === 'boolean') return result;
  if (Array.isArray(value)) { for (const part of value) await partsOf(part, result, depth + 1); return result; }
  if (typeof value === 'string' || typeof value === 'number' || value.type === 'text') {
    const text = value.type === 'text' ? value.text : String(value);
    if (['text', 'markdown'].includes(result.at(-1)?.format)) result.at(-1).content += text;
    else result.push({ format: 'text', content: text });
  } else if (value.type === 'at') {
    const uid = String(value.qq);
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(uid)) throw new Error('用户 OpenID 无效。');
    const text = uid === 'all' ? '<qqbot-at-everyone />' : `<qqbot-at-user id="${uid}" />`;
    await partsOf(text, result, depth + 1);
    result.at(-1).format = 'markdown';
  } else if (value.type === 'image') {
    const bytes = await imageBytes(value.file ?? value.data?.file);
    if (!bytes.length || bytes.length > 5 * 1024 * 1024) throw new Error('图片超过 5 MB 或为空。');
    result.push({ format: 'media', content: '', media_type: 1, mime: imageMime(bytes), media_base64: bytes.toString('base64') });
  } else if (value.type === 'forward') {
    for (const part of value.messages) { await partsOf(part.message ?? part, result, depth + 1); await partsOf('\n', result, depth + 1); }
  } else throw new HostCapabilityError(`segment.${String(value.type).replace(/[^a-z_]/gi, '').slice(0, 30)}`);
  return result;
}

async function send(value, target) {
  if (target.proactive && context.config.allow_proactive !== true) throw new DeliveryError('未允许此插件主动发送消息。');
  let parts = (await partsOf(value)).filter(p => p.format !== 'text' || p.content.trim());
  if (parts.some(p => p.content.length > 16000) || parts.length > 4) parts = await partsOf(await renderer.renderForward(parts));
  let last = { ok: true };
  for (const part of parts) {
    if (target.budget && ++target.budget.count > 5) throw new Error('已达到这条 QQ 被动消息的回复条数限制。');
    last = await request({ action: 'send', ...target, budget: undefined, ...part });
    if (!last.ok) throw new DeliveryError('QQ 平台发送失败，请查看管理器运行日志。');
  }
  return { ...last, message_id: last.message_id || '' };
}

async function boot(payload) {
  context = payload;
  global.redis = await createRedis(path.join(process.cwd(), 'redis.json'));
  const adapter = { uin: payload.appId, nickname: 'QQ机器人管理器', adapter: {id:'QQ'}, pickGroup: group, pickFriend: friend, pickUser: friend,
    sendGroupMsg: (id, msg) => group(id).sendMsg(msg), sendPrivateMsg: (id, msg) => friend(id).sendMsg(msg),
    getGroupMemberList: id => group(id).getMemberMap() };
  global.Bot = { ...adapter, uin: [payload.appId], [payload.appId]: adapter, getBot: id => global.Bot[String(id)] };
  const found = new Set();
  const errors = [];
  function collect(value, id, depth = 0) {
    if (depth > 4 || value == null) return;
    if (typeof value === 'function' && value.prototype instanceof global.plugin && !found.has(value)) {
      found.add(value); instances.push({ id, instance: new value() });
    } else if (typeof value === 'object') {
      for (const [key, item] of Object.entries(value)) collect(item, `${id}/${key}`, depth + 1);
    }
  }
  for (const entry of payload.entries) {
    try { collect(await import(pathToFileURL(path.join(root, entry)).href), entry); }
    catch (error) { errors.push(loadError(error)); }
  }
  if (errors.length || !instances.length) throw new Error(errors[0] || '没有找到继承 plugin 的导出类。');
  instances.sort((a, b) => a.instance.priority - b.instance.priority);
  for (const { instance } of instances) {
    if (typeof instance.init === 'function') await instance.init();
    for (const item of Array.isArray(instance.task) ? instance.task : instance.task ? [instance.task] : []) {
      if (item.cron && typeof item.fnc === 'function') {
        const schedule = (await import('node-schedule')).default;
        tasks.push(schedule.scheduleJob(item.cron, () => Promise.resolve(item.fnc.call(instance)).catch(() => {})));
      }
    }
  }
  initialized = true;
  process.send?.({ kind: 'ready', modules: instances.length, rules: instances.flatMap(({ instance }) => (instance.rule || []).map(rule => {
    const reg = rule.reg instanceof RegExp ? rule.reg : new RegExp(rule.reg);
    return { source: reg.source, flags: reg.flags, event: instance.event || 'message' };
  })) });
}

function loadError(error) {
  const text = String(error.message || '');
  const missing = text.match(/(?:Cannot find (?:package|module)|Could not find) ['"]([^'"\r\n]{1,180})['"]/);
  if (missing) return `缺少模块：${missing[1].replaceAll(process.cwd(), '').replaceAll(root, '')}`;
  return error.name === 'SyntaxError' ? '原包 JavaScript 语法错误，请检查当前 Node 版本和源码。' : '原包加载失败，请检查其声明的依赖、配置及运行环境。';
}

async function handle({ message, job_id }) {
  process.send?.({ kind: 'diagnostic', message: '' });
  const target = { target_id: message.session_id, is_group: message.is_group, reply_to_message_id: message.message_id, proactive: false, job_id, budget: { count: 0 } };
  try {
    users.set(message.sender_id, message.sender_name || message.sender_id);
    while (users.size > 4096) users.delete(users.keys().next().value);
    const master = String(context.config.owner_openids || '').split(/[\s,，]+/).includes(message.sender_id);
    const selfId = message.bot_id || context.appId;
    const adapter = global.Bot[context.appId];
    global.Bot[selfId] = adapter;
    if (message.bot_name) adapter.nickname = message.bot_name;
    const at = [...(message.mentions || []).filter(m => !m.bot).map(m => m.member_openid || m.user_openid || m.id),
      ...message.content.matchAll(/<qqbot-at-user\s+id="([A-Za-z0-9_-]{1,128})"\s*\/>/g)].map(m => typeof m === 'string' ? m : m[1]).filter(id => id && id !== context.appId && id !== selfId).at(-1);
    const text = message.content.replace(/<qqbot-at-user\b[^>]*\/?>/g, '').trim();
    const e = {
      msg: text, raw_message: text, self_id: selfId, user_id: message.sender_id,
      group_id: message.is_group ? message.session_id : undefined, isGroup: message.is_group, isPrivate: !message.is_group,
      isMaster: master, atBot: message.is_mentioned, isGuild: false,
      isAdmin: ['owner', 'admin'].includes(message.sender_role), isOwner: message.sender_role === 'owner',
      message_type: message.is_group ? 'group' : 'private', time: Math.floor(new Date(message.timestamp || Date.now()).getTime()/1000),
      sender: { user_id: message.sender_id, nickname: message.sender_name, card: message.sender_name, role: message.sender_role },
      at, bot: global.Bot[context.appId], group: message.is_group ? group(message.session_id) : undefined,
      friend: !message.is_group ? friend(message.sender_id) : undefined,
      reply: value => send(value, target), message: [{ type: 'text', text }, ...(message.attachments || []).map(a => ({ type: a.content_type?.startsWith('image/') ? 'image' : 'file', url: a.url, file: a.url }))],
    };
    await messageScope.run(e, async () => {
      const scoped = [...contexts.entries()].find(([key, item]) => item.until > Date.now() && (key === `user:${e.group_id || e.user_id}:${e.user_id}` || key === `group:${e.group_id}`));
      if (scoped) {
        const { instance, type } = scoped[1];
        if (typeof instance[type] === 'function') { await instance[type](e); return; }
      }
      for (const { instance } of instances) {
        const event = String(instance.event || 'message');
        if (!event.startsWith('message') || event.includes('.group') && !e.isGroup || event.includes('.private') && e.isGroup) continue;
        if (typeof instance.accept === 'function' && await instance.accept(e) === true) return;
        for (const rule of instance.rule || []) {
          const reg = rule.reg instanceof RegExp ? rule.reg : new RegExp(rule.reg);
          reg.lastIndex = 0;
          const normalized = text.startsWith('/') && !reg.test(text) ? `#${text.slice(1)}` : text;
          reg.lastIndex = 0;
          if (!reg.test(normalized)) continue;
          const permission = rule.permission || instance.permission;
          if (permission === 'master' && !master || permission === 'owner' && !master && message.sender_role !== 'owner' || permission === 'admin' && !master && !['owner', 'admin'].includes(message.sender_role)) {
            await e.reply('当前用户没有执行这个插件命令的权限。'); return;
          }
          e.msg = normalized;
          const handler = typeof rule.fnc === 'function' ? rule.fnc : instance[rule.fnc];
          if (typeof handler !== 'function') throw new Error('规则处理函数不存在。');
          if (await handler.call(instance, e) !== false) return;
        }
      }
    });
  } catch (error) {
    // Never echo exception bodies that can carry URL/query/API credentials.
    if (!(error instanceof DeliveryError)) {
      const text = error.qqmSafe === true && String(error.message).length < 300 ? error.message : '原版插件执行失败，请检查插件配置和运行诊断。';
      process.send?.({ kind: 'diagnostic', message: text });
      await send(text, target).catch(() => {});
    }
  } finally { process.send?.({ kind: 'job_done', job_id }); }
}

function matches(message) {
  const key = `user:${message.session_id}:${message.sender_id}`;
  if ([...contexts.entries()].some(([name, c]) => c.until > Date.now() && (name === key || message.is_group && name === `group:${message.session_id}`))) return true;
  const text = message.content.replace(/<qqbot-at-user\b[^>]*\/?>/g, '').trim();
  const candidates = text.startsWith('/') ? [text, '#' + text.slice(1)] : [text];
  return instances.some(({ instance }) => {
    const event = String(instance.event || 'message');
    if (!event.startsWith('message') || event.includes('.group') && !message.is_group || event.includes('.private') && message.is_group) return false;
    return typeof instance.accept === 'function' || (instance.rule || []).some(rule => candidates.some(text => { const reg = rule.reg instanceof RegExp ? rule.reg : new RegExp(rule.reg); reg.lastIndex = 0; return reg.test(text); }));
  });
}
process.on('message', payload => {
  if (payload.kind === 'init') boot(payload).catch(error => {
    process.send?.({ kind: 'failed', message: /^缺少模块：|^没有找到继承|^原包/.test(error.message) ? error.message : loadError(error) });
    shutdown();
  });
  else if (payload.kind === 'message' && initialized) handle(payload).catch(() => {});
  else if (payload.kind === 'match' && initialized) process.send?.({ kind: 'matched', id: payload.id, matched: matches(payload.message) });
  else if (payload.kind === 'ack') {
    const item = pending.get(payload.id);
    if (item) { clearTimeout(item.timer); pending.delete(payload.id); item.resolve(payload.result); }
  } else if (payload.kind === 'stop') shutdown();
});

async function shutdown() {
  if (closing) return;
  closing = true;
  for (const { reject, timer } of pending.values()) { clearTimeout(timer); reject(new Error('插件服务停止。')); }
  for (const task of tasks) task?.cancel?.();
  await Promise.allSettled([renderer.close(), global.redis?.flush()]);
  process.exit(0);
}
process.on('disconnect', shutdown);
process.on('SIGTERM', shutdown);
