import fs from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {tools} from './tools.js';

let readSettings = () => ({});
let warn = () => {};
let accountNamespace;
const stateFile = '/data/coverlink-account-v1.json';
const labelsFile = '/data/coverlink-song-labels-v1.json';
const maxAudioBytes = 5 * 1024 * 1024;
const fail = content => ({isError: true, content});

function settings(requireKey = true) {
  const value = readSettings();
  let url;
  try { url = new URL(String(value.baseOrigin || '').trim()); }
  catch { throw new Error('请在「插件设置」填写翻唱服务器的 HTTPS 地址，例如 https://gqu.uuze.cn。'); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password ||
      url.search || url.hash || (url.pathname !== '/' && url.pathname !== ''))
    throw new Error('服务器地址只填 HTTPS 域名和可选端口，不含账号、路径、参数或 /api/tool。');
  const path = String(value.apiPath || '/api/tool');
  if (!/^\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]+\/?$/.test(path))
    throw new Error('API 路径须类似 /api/tool，不含域名、参数或上级目录。');
  const apiKey = String(value.apiKey || '');
  if (apiKey && (apiKey !== apiKey.trim() || /^Bearer\s/i.test(apiKey) || /[\x00-\x20\x7f]/.test(apiKey) || apiKey.length > 512))
    throw new Error('API 密钥只填服务器生成的 Skill 密钥，不要包含 Bearer、空格或换行。');
  if (requireKey && !apiKey)
    throw new Error('尚未配置 API 密钥：在翻唱服务器「机器人接入」复制 Skill API 密钥，填入本 Skill 的「插件设置」。不是管理员密码或执行端配对码。');
  const timeout = Number(value.timeoutSec ?? 60);
  if (!Number.isInteger(timeout) || timeout < 10 || timeout > 120)
    throw new Error('接口请求超时请设置为 10–120 秒；此设置不限制翻唱任务时长。');
  return {url: url.origin + path, apiKey, timeout};
}

function redact(value) {
  let message = String(value);
  const key = String(readSettings().apiKey || '');
  if (key) {
    message = message.split(key).join('[密钥已隐藏]');
    message = message.split(JSON.stringify(key).slice(1, -1)).join('[密钥已隐藏]');
  }
  return message;
}

function safeMessage(value) {
  return redact(value || '操作失败').replace(/Bearer\s+[^\s"<>]+/gi, 'Bearer [已隐藏]')
    .replace(/https?:\/\/[^\s"<>]+/g, '[服务地址]').slice(0, 1800);
}

// This volume is isolated by the manager's protocol + connection + bot identity.
// It stays stable across calls/restarts and never shares tasks between accounts.
async function namespace() {
  if (accountNamespace) return accountNamespace;
  if (existsSync(stateFile)) {
    let saved;
    try { saved = JSON.parse(await fs.readFile(stateFile, 'utf8')); } catch {}
    if (!/^[a-zA-Z0-9-]{20,64}$/.test(saved?.id || ''))
      throw new Error('Skill 的会话隔离资料损坏，请先备份 Skill 数据后重新导入；未切换到其他任务空间。');
    accountNamespace = saved.id;
  } else {
    const id = randomUUID();
    await fs.writeFile(stateFile, JSON.stringify({id}), 'utf8');
    accountNamespace = id;
  }
  return accountNamespace;
}

function caller(ctx) {
  // Read only the current host-supplied trigger, never tool args or quoted history.
  const triggers = ctx?.session?.trigger || ctx?.triggerEntries;
  const entry = Array.isArray(triggers) ? triggers[triggers.length - 1] : null;
  if (!entry || entry.self !== false || !String(entry.senderId || '') ||
      !String(entry.id || entry.mid || '') || String(entry.senderId) === String(ctx.selfId))
    throw new Error('缺少本条消息的真实提问者资料，请在 QQ 会话中使用支持接口 7 的新版管理器触发。');
  const segments = Array.isArray(entry.segments) ? entry.segments : [];
  const direct = segments.filter(x => x?.type === 'text').map(x => String(x.data?.text || '')).join('');
  const body = segments.filter(x => x?.type === 'qq_body').map(x => String(x.data?.body?.content || '')).join('');
  if (!segments.length)
    throw new Error('当前宿主没有提供原消息片段，无法核对选歌；请更新管理器后重试。');
  return {id: String(entry.senderId).slice(0, 512), name: String(entry.senderName || '').slice(0, 128),
    messageId: String(entry.id || entry.mid).slice(0, 512), text: (direct || body).slice(0, 16000)};
}

async function requestContext(ctx) {
  if (!ctx?.chatKey || !ctx.selfId || !ctx.protocol ||
      [ctx.chatKey, ctx.selfId, ctx.protocol].some(x => /[|\x00-\x1f]/.test(String(x))))
    throw new Error('没有可用的当前机器人会话，不能提交或发送翻唱。');
  const identity = caller(ctx);
  const scope = `qqm-zip:${await namespace()}|${ctx.protocol}:${ctx.selfId}|${ctx.chatKey}`;
  if (scope.length > 1400) throw new Error('当前会话标识过长。');
  return {scope, caller: identity};
}

function parameters(tool, args) {
  if (!args || Array.isArray(args) || typeof args !== 'object') throw new Error('工具参数必须为对象。');
  const schema = tool.parameters;
  for (const name of Object.keys(args)) {
    if (!Object.prototype.hasOwnProperty.call(schema.properties, name))
      throw new Error(`工具不接受参数 ${name}；提问者和会话由管理器提供。`);
    const def = schema.properties[name];
    const value = args[name];
    if ((def.type === 'string' && (typeof value !== 'string' || value.length > 2000)) ||
        (def.type === 'integer' && !Number.isInteger(value)) ||
        (def.type === 'number' && (typeof value !== 'number' || !Number.isFinite(value))) ||
        (def.enum && !def.enum.includes(value))) throw new Error(`参数 ${name} 格式无效。`);
  }
  for (const name of schema.required || [])
    if (args[name] === undefined || args[name] === '') throw new Error(`缺少参数 ${name}。`);
  return args;
}

async function call(c, identity, action, args) {
  let response;
  try {
    response = await fetch(c.url, {
      method: 'POST', redirect: 'error',
      headers: {'Content-Type': 'application/json', Authorization: `Bearer ${c.apiKey}`},
      body: JSON.stringify({action, ...identity, args}),
      signal: AbortSignal.timeout(c.timeout * 1000),
    });
  } catch (error) {
    throw new Error(`接口请求失败或超时：${safeMessage(error?.message)}。任务可能仍在执行；请查询状态，不要重复提交。`);
  }
  if (response.status === 401 || response.status === 403)
    throw new Error(`HTTP ${response.status}：Skill API 密钥无效或接口被拦截，请检查「插件设置」和服务器的「机器人接入」。`);
  if (response.status >= 300 && response.status < 400)
    throw new Error('接口返回了跳转，未转发密钥；请填写最终 HTTPS 地址，并检查 CDN 配置。');
  let value;
  try { value = JSON.parse(await response.text()); }
  catch { throw new Error(`HTTP ${response.status}：接口未返回 JSON，请检查服务器地址、API 路径及 CDN 缓存或验证页面。`); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('服务器返回的 JSON 结构无效。');
  if (!response.ok || value.isError === true || value.ok === false)
    throw new Error(`HTTP ${response.status}：${safeMessage(value.message || value.error || '翻唱服务未完成请求')}`);
  return value;
}

function songMid(row) {
  const mid = String(row?.mid || '');
  if (/^netease:[1-9][0-9]{0,19}$/.test(mid)) return mid;
  if (row?.source === 'netease' && /^[1-9][0-9]{0,19}$/.test(String(row.source_id || '')))
    return 'netease:' + row.source_id;
  const netease = /^网易云-([1-9][0-9]{0,19})\.mp3$/i.exec(String(row?.file_name || row?.name || ''));
  if (netease) return 'netease:' + netease[1];
  if (/^[a-zA-Z0-9]{10,20}$/.test(mid)) return mid;
  return /^QQ音乐-([a-zA-Z0-9]{10,20})\.(?:mp3|wav|flac|m4a|ogg|aac)$/i
    .exec(String(row?.file_name || row?.name || ''))?.[1] || '';
}

async function readLabels() {
  if (!existsSync(labelsFile)) return {};
  try {
    const saved = JSON.parse(await fs.readFile(labelsFile, 'utf8'));
    if (saved && typeof saved === 'object' && !Array.isArray(saved)) return saved;
  } catch {}
  // This cache is only descriptive; a missing label never grants consent to import.
  return {};
}

async function rememberSongs(value) {
  const rows = [...(Array.isArray(value.candidates) ? value.candidates : []), value.selected].filter(Boolean);
  if (!rows.length) return;
  const labels = await readLabels();
  for (const row of rows.slice(0, 30)) {
    const mid = songMid(row);
    if (!mid || !row.name || !row.singer || ![row.name, row.singer].every(
      x => typeof x === 'string' && x.length <= 160 && !/[\x00-\x1f]/.test(x))) continue;
    delete labels[mid];
    labels[mid] = {title: row.name, singer: row.singer};
  }
  const keys = Object.keys(labels);
  for (const key of keys.slice(0, Math.max(0, keys.length - 512))) delete labels[key];
  await fs.writeFile(labelsFile, JSON.stringify(labels), 'utf8');
}

async function describeSongs(value, field) {
  const labels = await readLabels();
  if (!Array.isArray(value[field])) return value;
  value[field] = value[field].map(row => {
    const mid = songMid(row);
    const known = labels[mid];
    if (row.title && row.singer) return {...row, metadata_status: 'known'};
    if (known?.title && known?.singer) return {...row, file_name: row.file_name || row.name,
      mid, title: known.title, singer: known.singer, name: `${known.title} — ${known.singer}`, metadata_status: 'known'};
    return {...row, ...(mid ? {mid} : {}), metadata_status: 'unknown'};
  });
  if (value[field].some(row => row.metadata_status === 'unknown'))
    value.title_lookup_hint = '部分旧文件缺少歌名资料，文件名或ID不是歌名。用户已有歌名时，请调用 remote_rvc_cover__remote_cover_songs 的 query 或 remote_rvc_cover__remote_cover_search_qq 按服务端所选QQ/网易云来源查询；用真实ID精确匹配本地歌曲。不要让用户判断哪个文件名是那首歌，也不要猜测未知WAV的内容。多个版本仍须原提问者选择。';
  return value;
}

async function sendAudio(ctx, value) {
  if (!value.selection || !Number.isFinite(Number(value.selection.duration)) || Number(value.selection.duration) <= 0)
    throw new Error('该任务没有新版翻唱范围资料，未将旧版短试听当作完整成品发送；请重新选择整首、高潮或时间段。');
  const data = value.audioBase64;
  if (typeof data !== 'string' || data.length > Math.ceil(maxAudioBytes / 3) * 4 ||
      !data.length || data.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(data))
    throw new Error('成品音频无效或超过 5 MB，请在服务器任务列表下载完整成品。');
  const bytes = Buffer.from(data, 'base64');
  if (bytes.length <= 100 || bytes.length > maxAudioBytes || bytes.toString('base64') !== data)
    throw new Error('成品音频为空、编码无效或超过 5 MB，未发送。');
  let file;
  try {
    file = `/tmp/coverlink-${randomUUID()}.mp3`;
    await fs.writeFile(file, bytes);
    const receipt = await ctx.sender.sendMedia(ctx.chatKey, [{type: 'record', data: {file}}]);
    if (receipt?.ok !== true || !Array.isArray(receipt.sent) || !receipt.sent.length ||
        receipt.sent.some(x => x?.ok !== true || !String(x.message_id || x.messageId || '')))
      throw new Error('没有取得真实语音消息回执；未确认发送成功，请先查看会话，避免重复补发。');
    return {content: `所选范围的完整翻唱成品已发送，长度约 ${Math.round(Number(value.selection.duration))} 秒，已取得语音消息回执。不要重复发送。`};
  } finally {
    if (file) await fs.unlink(file).catch(() => {});
  }
}

function backgroundAvailable(ctx) {
  return ctx?.hostCapabilities?.includes('cover-delivery-v1') && typeof ctx.tasks?.watchCover === 'function';
}

async function jobId(c, identity, args) {
  if (args.job_id) return args.job_id;
  const value = await call(c, identity, 'status', {});
  if (!/^[a-f0-9]{32}$/.test(value.job?.id || '')) throw new Error('没有可用的当前任务编号。');
  return value.job.id;
}

async function delivery(ctx, value, identity) {
  if (value.job?.type !== 'cover') return value;
  value.auto_send = false;
  if (!backgroundAvailable(ctx)) {
    value.delivery_hint = '当前客户端不支持后台翻唱发送。任务已提交，但不会完成后自动发；请安装支持后台任务的新版管理器。现阶段需在完成后发新消息查询并调用发送工具。';
    return value;
  }
  try {
    const options = {jobId: value.job.id, scope: identity.scope};
    let status = await ctx.tasks.coverStatus(options);
    if (!status.registered && readSettings().autoSend === true)
      status = await ctx.tasks.watchCover(options);
    value.delivery = status;
    value.auto_send = status.registered === true && ['watching', 'waiting_message'].includes(status.state);
    value.delivery_hint = status.message || (value.auto_send ? '已登记；管理器保持运行与连接时，完成后自动发回本会话。' : '没有登记自动发送，不要承诺完成后自动发。');
  } catch (error) {
    value.delivery_error = safeMessage(error?.message);
    value.delivery_hint = '任务已提交，但自动发送登记失败。请按delivery_error检查客户端；不要重复提交翻唱，也不要承诺自动发送。';
  }
  return value;
}

export function setup(api) {
  readSettings = () => api.config();
  warn = message => api.warn?.(message);
  for (const tool of tools) api.registerTool({
    ...tool, requiresMediaAck: tool.action === 'audio',
    async execute(ctx, args) {
      try {
        const c = settings(), input = parameters(tool, args);
        if (tool.action === 'audio' && typeof ctx?.sender?.sendMedia !== 'function')
          throw new Error('当前会话没有语音发送接口，请更新管理器或检查机器人连接。');
        const identity = await requestContext(ctx);
        if (tool.action === 'audio' && backgroundAvailable(ctx)) {
          const receipt = await ctx.tasks.sendCover({jobId: await jobId(c, identity, input), scope: identity.scope});
          if (receipt.alreadySent) return fail('此任务已有语音发送回执，无需重复发送。');
          if (receipt.sent !== true || receipt.receipt?.ok !== true || !receipt.receipt.message_id)
            throw new Error('没有取得语音发送回执，未确认发送成功。');
          return {content: '完整翻唱已发送，已取得QQ语音消息回执；后台不会再次发送。'};
        }
        if (tool.action === 'cancel' && backgroundAvailable(ctx))
          await ctx.tasks.cancelCover({jobId: await jobId(c, identity, input), scope: identity.scope});
        if (tool.action === 'start_selected') {
          const health = await call(c, identity, 'health', {});
          if (!Array.isArray(health.features) || !health.features.includes('cover-selection-v1'))
            throw new Error('服务器需升级至 CoverLink 0.1.2 或更高版本；未退回旧版固定 30 秒接口。');
        }
        let lookup;
        if (tool.action === 'songs' && input.query?.trim()) {
          lookup = await call(c, identity, 'search_qq', {query: input.query.trim()});
          await rememberSongs(lookup);
        }
        let value = await call(c, identity, tool.action, tool.action === 'songs' ? {} : input);
        await rememberSongs(value);
        if (tool.action === 'songs') {
          value = await describeSongs(value, 'items');
          if (lookup) value.lookup = lookup;
        }
        if (tool.action === 'health') value = await describeSongs(value, 'songs');
        if (['start_selected', 'status'].includes(tool.action)) value = await delivery(ctx, value, identity);
        if (tool.action === 'audio') return await sendAudio(ctx, value);
        // Audio bytes belong only in the sender, never the LLM context or logs.
        delete value.audioBase64;
        return {content: redact(JSON.stringify(value))};
      } catch (error) {
        const message = safeMessage(error?.message || error);
        warn(`远程翻唱未完成：${message}`);
        return fail(message);
      }
    },
  });
}

// Empty keys are allowed while importing; the first call explains how to fill it.
export function available() {
  try { settings(false); return true; }
  catch (error) { return {ok: false, reason: safeMessage(error?.message)}; }
}
