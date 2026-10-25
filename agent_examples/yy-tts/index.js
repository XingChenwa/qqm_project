import fs from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';

let readSettings = () => ({});
let cached;
let warn = () => {};
const fail = message => ({isError:true,content:message});
const langs = new Set(['auto','zh','en','ja','all_zh','all_ja']);

function settings() {
  const value = readSettings();
  const url = new URL(String(value.apiBase || 'https://yy.jujiang.js.cn').trim());
  if(url.protocol !== 'https:' || url.username || url.password || url.search || url.hash)
    throw new Error('服务地址须为不含账号、参数或片段的 HTTPS 地址。');
  const base = url.href.replace(/\/+$/, '').replace(/\/tts$/, '');
  const speed = Number(value.speed ?? 1);
  if(!Number.isFinite(speed) || speed < 0.5 || speed > 2) throw new Error('语速须在 0.5–2 之间。');
  const language = String(value.language || 'auto');
  if(!langs.has(language)) throw new Error('请选择有效的文本语言。');
  const timeout = Math.min(120, Math.max(10, Number(value.timeoutSec) || 120)) * 1000;
  const override=String(value.characterOverride || '').trim();
  const mode=String(value.mode || 'direct');
  if(!['direct','gradio'].includes(mode))throw new Error('请选择直连 TTS 或 Gradio 兼容模式。');
  const delivery=String(value.delivery || 'url');
  if(!['url','download'].includes(delivery))throw new Error('请选择适配器取音频或本机下载方式。');
  const character=override || String(value.character || '甜妹').trim();
  if(!character || character.length>128 || /[\x00-\x1f]/.test(character))throw new Error('角色音色名称无效，请在插件设置中重新选择。');
  return {base,origin:url.origin,mode,delivery,character,
    deadline:Date.now()+125000,
    emotion:String(value.emotion || 'default').trim(),speed,language,timeout};
}

async function snapshot() {
  const saved=JSON.parse(await fs.readFile(fileURLToPath(new URL('./service.json',import.meta.url)),'utf8'));
  if(!Array.isArray(saved.voices))throw new Error('随包音色列表损坏，请重新导入 Skill。');
  return saved;
}

function resultUrl(c, value) {
  const url=new URL(String(value),c.base+'/');
  if(url.protocol !== 'https:' || url.username || url.password || url.hash || /\/tts\/?$/.test(decodeURIComponent(url.pathname)))
    throw new Error('服务返回的音频下载地址无效，未重复请求合成。');
  return url.href;
}

function ttsUrl(c,text) {
  const url=`${c.base}/tts?character=${encodeURIComponent(c.character)}&text=${encodeURIComponent(text)}&speed=${encodeURIComponent(String(c.speed))}`;
  if(url.length>7500)throw new Error('朗读文字形成的请求地址过长，请缩短文字后再试。');
  return url;
}

async function direct(c,text) {
  // This GET generates audio. Submit ONCE, with only the documented parameters.
  // Do not query /config, join a queue, or fall back by generating it again.
  const url=ttsUrl(c,text);
  let response;
  try {
    response=await fetch(url,{headers:{Accept:'audio/wav, audio/mpeg, audio/*, application/json'},signal:AbortSignal.timeout(budget(c,120000))});
  } catch(error) {throw new Error(`直连 TTS 请求失败：${String(error?.message||'网络异常')}`);}
  if([301,302,303,307,308].includes(response.status)) {
    const target=response.headers.get('location');
    if(!target)throw new Error('语音服务重定向没有提供音频地址。');
    return download(c,resultUrl(c,target));
  }
  if(!response.ok)throw new Error(`直连 TTS 返回 HTTP ${response.status}，没有确认发送语音。`);
  const type=String(response.headers.get('content-type')||'').toLowerCase();
  if(type.includes('json')) {
    let value;
    try{value=await response.json();}catch{throw new Error('直连 TTS 返回了无效 JSON。');}
    const file=typeof value==='string'?value:value?.audio_url||value?.url||(typeof value?.data==='string'?value.data:null)||value?.data?.audio_url||value?.data?.url;
    if(typeof file!=='string'||!file)throw new Error('直连 TTS 没有返回音频或下载地址，请检查角色名称或稍后重试。');
    return download(c,resultUrl(c,file));
  }
  return new Uint8Array(await response.arrayBuffer());
}

function budget(c, cap) {
  const remaining=c.deadline-Date.now();
  if(remaining <= 0)throw new Error('语音操作已达到总等待时限，未确认发送成功；没有重复提交任务。');
  return Math.max(1,Math.min(c.timeout,cap,remaining));
}

async function request(c, path, data) {
  const phase = path.endsWith('/config') ? '读取角色配置' : data !== undefined ? '提交接口任务' : '等待接口结果';
  const sse = data === undefined && (path.includes('/queue/data?') || /\/call\/[^/]+\/[^/?]+$/.test(path));
  let response;
  try {response = await fetch(c.base + path, {
    method:data === undefined ? 'GET' : 'POST',
    headers:data === undefined ? (sse ? {'Accept':'text/event-stream','Cache-Control':'no-cache','Accept-Encoding':'identity'} : {}) : {'Content-Type':'application/json'},
    ...(data === undefined ? {} : {body:JSON.stringify(data)}),
    signal:AbortSignal.timeout(budget(c,path.endsWith('/config') ? 12000 : 120000)),
  });} catch(error) {throw new Error(`${phase}失败：${String(error?.message || '网络异常')}`);}
  if(!response.ok) throw new Error(`语音服务返回 HTTP ${response.status}，本次未确认发送语音。`);
  return response;
}

async function describe(c) {
  if(cached?.base === c.base && Date.now() - cached.at < 300000) return cached;
  let config, last;
  // Only a read-only metadata request is retried. Never repeat a synthesis POST.
  for(let i=0;i<2;i++) {
    try {config=await (await request(c, '/config')).json();break;}
    catch(error){last=error;}
  }
  if(!config) {
    if(c.base !== 'https://yy.jujiang.js.cn') throw last;
    const saved=await snapshot();
    if(saved.version !== '4.37.2' || saved.functions?.get_audio !== 4 || !Array.isArray(saved.voices))throw last;
    warn('站点配置暂不可达，使用随包保存的 Gradio 4.37.2 协议；如站点升级后无法使用，请更新 Skill。');
    cached={base:c.base,at:Date.now(),prefix:'',voices:saved.voices,functions:saved.functions,inputs:saved.inputs,queue:true,fallback:true};
    return cached;
  }
  const api = config.dependencies?.find(x => x.api_name === 'get_audio');
  if(!api || !Array.isArray(api.inputs) || api.inputs.length !== 17)
    throw new Error('服务的 get_audio 接口与此 Skill 的 17 参数协议不一致，请检查服务地址或更新 Skill。');
  const prefix = config.api_prefix || '';
  if(typeof prefix !== 'string' || !/^(?:\/[a-zA-Z0-9_-]+)*$/.test(prefix))
    throw new Error('语音服务的 API 前缀无效。');
  const character = config.components?.find(x => x.id === api.inputs[1]);
  const choices = character?.props?.choices;
  if(!Array.isArray(choices) || choices.length > 5000) throw new Error('服务未提供有效的角色音色列表。');
  const voices = [...new Set(choices.map(x => String(Array.isArray(x) ? x[1] : x)))];
  const functions = {};
  const inputs = {};
  for (const [index,item] of config.dependencies.entries()) {
    if(typeof item.api_name === 'string') {
      functions[item.api_name] = Number.isInteger(item.id) ? item.id : index;
      inputs[item.api_name] = item.inputs?.length;
    }
  }
  cached = {base:c.base,at:Date.now(),prefix,voices,functions,inputs,
    queue:String(config.version||'').startsWith('4.') && config.protocol === 'sse_v3'};
  return cached;
}

function completed(source, eventId) {
  const blocks = String(source).replace(/\r\n/g,'\n').split(/\n\n+/);
  for(const block of blocks) {
    const lines = block.split('\n');
    const event = lines.find(x => x.startsWith('event:'))?.slice(6).trim();
    const raw = lines.filter(x => x.startsWith('data:')).map(x => x.slice(5).trimStart()).join('\n');
    if(raw) {
      let message;
      try {message=JSON.parse(raw);} catch {}
      if(message?.msg && (!message.event_id || message.event_id === eventId)) {
        if(message.msg === 'queue_full') throw new Error('语音服务队列已满，请稍后再试；没有重复提交任务。');
        if(message.msg === 'unexpected_error') throw new Error('语音服务队列发生错误，未确认合成或发送成功。');
        if(message.msg === 'process_completed') {
          if(message.success !== true || message.output?.error) throw new Error('语音服务合成失败，请检查当前角色和情感设置或稍后重试。');
          if(!Array.isArray(message.output?.data)) throw new Error('语音服务完成结果格式无效。');
          return message.output.data;
        }
      }
    }
    if(event === 'error') throw new Error('语音服务合成失败，未取得音频；请稍后重试或检查音色和情感设置。');
    if(event === 'complete') {
      let value;
      try {value=JSON.parse(raw);} catch {throw new Error('语音服务完成事件格式无效。');}
      if(value?.error) throw new Error('语音服务报告合成失败，未取得音频。');
      return value;
    }
  }
  throw new Error('未收到语音服务的完成事件；未确认合成或发送成功。');
}

async function call(c, meta, api, data) {
  const session = randomUUID().replace(/-/g,'');
  const index = meta.functions[api];
  if(meta.queue && (!Number.isInteger(index) || index < 0 || index > 10000)) throw new Error('服务未提供此接口的函数编号。');
  // The second emotion input is Gradio's hidden State, omitted by /call but
  // required as a placeholder in the raw queue protocol.
  if(meta.queue && api === 'load_character_emotions' && meta.inputs?.[api] === 2) data=[...data,null];
  const result = await (await request(c, meta.queue ? `${meta.prefix}/queue/join` : `${meta.prefix}/call/${api}`,
    {data,session_hash:session,...(meta.queue ? {fn_index:index,event_data:null} : {})})).json();
  if(typeof result.event_id !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(result.event_id))
    throw new Error('语音服务没有返回有效任务编号，未确认合成成功。');
  // The native host bounds the SSE body, duration and cancellation as well.
  const stream = await request(c, meta.queue ? `${meta.prefix}/queue/data?session_hash=${encodeURIComponent(session)}` : `${meta.prefix}/call/${api}/${result.event_id}`);
  return completed(await stream.text(),result.event_id);
}

function audioUrl(c, meta, audio) {
  if(!audio || typeof audio !== 'object') throw new Error('服务未返回可下载的音频。');
  if(typeof audio.url === 'string' && audio.url) {
    const url = new URL(audio.url, c.base + '/');
    if(url.protocol === 'https:' && url.origin === c.origin && !url.username && !url.password && !url.hash)
      return url.href;
  }
  const file = audio.path;
  if(typeof file !== 'string' || file.length > 4096 || /[\r\n\0]/.test(file) ||
     !/^(?:\/|[A-Za-z]:[\\/])/.test(file) || file.split(/[\\/]/).includes('..'))
    throw new Error('服务返回的音频地址无效。');
  return `${c.base}${meta.prefix}/file=${encodeURIComponent(file)}`;
}

async function download(c,url) {
  let last;
  for(let i=0;i<2;i++) {
    try {
      let next=url;
      const seen=new Set();
      for(let hop=0;hop<4;hop++) {
        if(seen.has(next))throw new Error('音频下载发生循环重定向。');
        seen.add(next);
        const response=await fetch(next,{signal:AbortSignal.timeout(budget(c,30000))});
        if([301,302,303,307,308].includes(response.status)) {
          const location=response.headers.get('location');
          if(!location)throw new Error('音频下载重定向缺少目标地址。');
          next=resultUrl(c,new URL(location,next).href);
          continue;
        }
        if(!response.ok)throw new Error(`音频下载失败：HTTP ${response.status}。`);
        return new Uint8Array(await response.arrayBuffer());
      }
      throw new Error('音频下载重定向次数过多。');
    }catch(error){last=error;}
  }
  throw last;
}

export function setup(api) {
  readSettings = api.config;
  warn=message=>api.warn?.(message);
  api.registerTool({
    id:'read_aloud',name:'语音朗读',requiresMediaAck:true,
    description:'用插件设置的角色和语速朗读指定文字，并将真实语音发送到当前会话。默认直连 /tts，情感仅 Gradio 兼容模式生效。仅在用户要求朗读或语音回复时调用；这是 TTS，不是唱歌或翻唱。',
    parameters:{type:'object',properties:{text:{type:'string',description:'要朗读的文字，最多 1000 字。'}},required:['text'],additionalProperties:false},
    async execute(ctx, args) {
      let file;
      try {
        const text = String(args?.text || '').trim();
        if(!text || text.length > 1000) return fail('朗读文字须为 1–1000 字。');
        if(!ctx?.chatKey || typeof ctx.sender?.sendMedia !== 'function') return fail('请从聊天会话调用朗读工具，当前没有可用的语音发送通道。');
        const c = settings();
        if(c.mode==='direct' && c.delivery==='url') {
          if(typeof ctx.sender.sendMediaUrl!=='function')throw new Error('当前客户端尚未支持 URL 语音，请安装提供 URL 语音支持的新版管理器，或在高级设置选择本机下载方式。');
          const receipt=await ctx.sender.sendMediaUrl(ctx.chatKey,ttsUrl(c,text));
          if(receipt?.ok!==true || !Array.isArray(receipt.sent) || !receipt.sent.length)throw new Error('没有收到语音发送回执，未确认发送成功。');
          return {content:`语音已发送。角色：${c.character}；语速：${c.speed}。已通过适配器 / 平台按 URL 获取音频，无需重复发送相同正文。`};
        }
        let bytes;
        if(c.mode==='direct') {
          bytes=await direct(c,text);
        } else {
          const meta=await describe(c);
          if(!meta.voices.includes(c.character)) return fail('设置中的角色不在服务当前音色列表里，请修改角色音色或查询音色列表。');
          const value = await call(c, meta, 'get_audio', [
            text,c.character,c.emotion,null,'','auto',c.speed,c.language,
            'auto_cut',50,10,-1,true,5,0.8,0.8,1.35,
          ]);
          const output = Array.isArray(value) ? value[0] : value;
          bytes=await download(c,audioUrl(c,meta,output));
        }
        if(!bytes.length || bytes.length > 5*1024*1024) throw new Error('返回音频为空或超过 5 MB，未发送；请缩短朗读文字。');
        file = `/tmp/yy-tts-${randomUUID()}.wav`;
        await fs.writeFile(file,Buffer.from(bytes));
        // The host sniffs actual audio bytes and waits for the real protocol ACK.
        const receipt = await ctx.sender.sendMedia(ctx.chatKey,[{type:'record',data:{file}}]);
        if(receipt?.ok !== true || !Array.isArray(receipt.sent) || !receipt.sent.length)
          throw new Error('没有收到语音发送回执，未确认发送成功。');
        return {content:`语音已发送。角色：${c.character}；${c.mode==='gradio'?`情感：${c.emotion}；`:''}语速：${c.speed}。无需重复发送相同正文。`};
      } catch(error) {
        const message = String(error?.message || '语音操作失败').replace(/https?:\/\/\S+/g,'[服务地址]');
        api.warn?.(`YY TTS 未完成：${message.slice(0,300)}`);
        return fail(`语音未完成：${message}`);
      } finally {
        if(file) await fs.unlink(file).catch(()=>{});
      }
    },
  });
  api.registerTool({
    id:'list_voices',name:'查询角色音色',requiresMediaAck:false,description:'查询音色参考名单；Gradio 兼容模式读取服务当前名单。可按名称搜索，每页最多 25 个；设置中的角色音色用于实际朗读。',
    parameters:{type:'object',properties:{query:{type:'string'},page:{type:'integer'}},additionalProperties:false},
    async execute(_ctx,args) {
      try {
        const c=settings(),meta=c.mode==='direct'?{...(await snapshot()),reference:true}:await describe(c),q=String(args?.query||'').toLowerCase();
        const voices=meta.voices.filter(x=>x.toLowerCase().includes(q));
        const page=Math.max(1,Math.floor(Number(args?.page)||1));
        return {content:JSON.stringify({current:c.character,total:voices.length,page,source:meta.reference?'随包音色参考列表':meta.fallback?'随包快照（站点配置暂不可达）':'当前站点列表',voices:voices.slice((page-1)*25,page*25)})};
      }catch(error){return fail(String(error?.message||'音色查询失败'));}
    },
  });
  api.registerTool({
    id:'list_emotions',name:'查询当前音色情感',requiresMediaAck:false,description:'读取插件当前角色可用的情感名称，用于填写插件设置中的情感。',
    parameters:{type:'object',properties:{},additionalProperties:false},
    async execute() {
      try {
        const c=settings();
        if(c.mode==='direct')return {content:'当前使用直连 /tts 接口，仅发送角色、正文和语速三个已知参数。情感与语言设置仅在高级设置切换为 Gradio 兼容模式后生效。'};
        const meta=await describe(c);
        const value=await call(c,meta,'load_character_emotions',[c.character]);
        const item=Array.isArray(value)?value[0]:value;
        return {content:JSON.stringify({character:c.character,emotions:item?.choices||item})};
      }catch(error){return fail(String(error?.message||'情感查询失败'));}
    },
  });
}

export function available() {
  try {settings();return true;} catch(error){return {ok:false,reason:String(error?.message||error)};}
}
