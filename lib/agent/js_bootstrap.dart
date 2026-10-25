// Host compatibility API for QQ Agent apiVersion 1 packages. This is not a
// general Node installation: every native operation is checked again in Dart.
const agentJsBootstrap = r'''
(() => {
  'use strict';
  const native = globalThis.__agentNative;
  const host = (op, args = {}) => {
    const result = JSON.parse(native(JSON.stringify([op, args])));
    if (!result.ok) throw new Error(result.error || '宿主操作失败');
    return result.value;
  };
  class NodeBuffer extends Uint8Array {
    static from(value, encoding = 'utf8') {
      if (value instanceof ArrayBuffer) return new NodeBuffer(value.slice(0));
      if (ArrayBuffer.isView(value) || Array.isArray(value)) return new NodeBuffer(value);
      if (typeof value === 'string') {
        const b = native(JSON.stringify(['bufferFrom',{value,encoding}]));
        return new NodeBuffer(b.buffer,b.byteOffset,b.byteLength);
      }
      throw new TypeError('Buffer.from 参数无效');
    }
    static isBuffer(v) { return v instanceof NodeBuffer; }
    static alloc(size, fill = 0) { if (size > 16*1024*1024 || size < 0) throw new Error('Buffer 大小超限'); return new NodeBuffer(size).fill(fill); }
    static concat(parts, total = parts.reduce((n,b) => n+b.length, 0)) {
      const out = NodeBuffer.alloc(total); let at = 0;
      for (const b of parts) { const n = Math.min(b.length, total-at); out.set(b.subarray(0,n), at); at += n; }
      return out;
    }
    static byteLength(v, enc) { return NodeBuffer.from(v, enc).length; }
    toString(enc = 'utf8', start = 0, end = this.length) {
      // The native bulk-buffer API identifies standard TypedArray constructors.
      // Do not pass a NodeBuffer subclass (including its species subarrays).
      const b = new Uint8Array(this.buffer,this.byteOffset,this.byteLength).subarray(start,end);
      if (!b.length) return '';
      return native(JSON.stringify(['bufferString',{encoding:enc}]),b);
    }
    equals(b) { return this.length === b.length && this.every((v,i) => v === b[i]); }
    indexOf(value,offset=0,encoding='utf8') {
      if(typeof value==='number')return super.indexOf(value,offset);
      const needle=NodeBuffer.from(value,encoding),start=offset<0?Math.max(0,this.length+offset):Math.min(this.length,offset);
      outer:for(let i=start;i+needle.length<=this.length;i++){for(let j=0;j<needle.length;j++)if(this[i+j]!==needle[j])continue outer;return i;}return -1;
    }
    readUIntLE(at, length) { let v=0; for (let i=length-1; i>=0; i--) v = v*256 + this[at+i]; return v; }
    readUIntBE(at, length) { let v=0; for (let i=0; i<length; i++) v = v*256 + this[at+i]; return v; }
    readUInt32LE(at) { return this.readUIntLE(at,4); }
    readUInt32BE(at) { return this.readUIntBE(at,4); }
    readUInt16LE(at) { return this.readUIntLE(at,2); }
    readUInt16BE(at) { return this.readUIntBE(at,2); }
    toJSON() { return {type:'Buffer', data:Array.from(this)}; }
  }
  globalThis.Buffer = NodeBuffer;
  globalThis.TextEncoder = class { encode(v='') { return NodeBuffer.from(String(v)); } };
  globalThis.TextDecoder = class { decode(v=new Uint8Array()) { return NodeBuffer.from(v).toString(); } };
  globalThis.atob = s => NodeBuffer.from(s,'base64').toString('latin1');
  globalThis.btoa = s => NodeBuffer.from(s,'latin1').toString('base64');
  const path = {
    sep: '/', delimiter: ':',
    normalize: value => host('path', {method:'normalize', paths:[String(value)]}),
    join: (...paths) => host('path', {method:'join', paths}),
    resolve: (...paths) => host('path', {method:'resolve', paths}),
    dirname: p => host('path', {method:'dirname', paths:[String(p)]}),
    basename: (p, suffix) => { const n = host('path', {method:'basename', paths:[String(p)]}); return suffix && n.endsWith(suffix) ? n.slice(0,-suffix.length) : n; },
    extname: p => host('path', {method:'extension', paths:[String(p)]}),
    isAbsolute: p => String(p).startsWith('/'),
  };
  path.posix = path;
  const fs = {
    readFileSync(file, options) { const b = NodeBuffer.from(host('fs', {method:'read', file:String(file)}),'base64'); return typeof options === 'string' || options?.encoding ? b.toString(typeof options === 'string' ? options : options.encoding) : b; },
    writeFileSync(file, data, options) { host('fs', {method:'write', file:String(file), data:NodeBuffer.from(data, typeof options === 'string' ? options : options?.encoding).toString('base64')}); },
    mkdirSync(file, options) { host('fs', {method:'mkdir', file:String(file), recursive:!!options?.recursive}); },
    readdirSync(file) { return host('fs', {method:'list', file:String(file)}); },
    existsSync(file) { try { return !!host('fs', {method:'exists', file:String(file)}); } catch { return false; } },
    statSync(file) { const s = host('fs', {method:'stat', file:String(file)}); return {...s, mtime:new Date(s.mtimeMs), isFile:()=>!s.directory, isDirectory:()=>s.directory}; },
    unlinkSync(file) { host('fs', {method:'unlink', file:String(file)}); },
    renameSync(file, dest) { host('fs', {method:'rename', file:String(file), dest:String(dest)}); },
  };
  fs.promises = Object.fromEntries(['readFile','writeFile','mkdir','readdir','stat','unlink','rename'].map(k => [k, async(...a)=>fs[k+'Sync'](...a)]));
  fs.promises.open=async(file,flags='r')=>{
    if(flags!=='r')throw new Error('文件句柄仅支持只读模式');const bytes=fs.readFileSync(file);let closed=false,position=0;
    return {async read(buffer,offset=0,length=buffer.length,at=null){if(closed)throw new Error('文件句柄已关闭');const start=at==null?position:Math.max(0,at),count=Math.max(0,Math.min(length,bytes.length-start,buffer.length-offset));buffer.set(bytes.subarray(start,start+count),offset);position=start+count;return {bytesRead:count,buffer};},async close(){closed=true;}};
  };
  const crypto = {randomUUID:()=>host('uuid'),createHash(algorithm) {
    const chunks = [];
    return { update(v, enc) { chunks.push(NodeBuffer.from(v, enc)); return this; }, digest(enc) { const b = NodeBuffer.from(host('hash',{algorithm,data:NodeBuffer.concat(chunks).toString('base64')}),'base64'); return enc ? b.toString(enc) : b; } };
  }};
  globalThis.process = Object.freeze({pid:1, platform:'qqm', versions:{node:'18.0.0',quickjs:'embedded'}, env:Object.freeze({QQ_AGENT_DATA_DIR:'/data'}), cwd:()=>'/data'});
  class HostSearchParams {
    constructor(value='') {
      const decode = s => decodeURIComponent(String(s).replace(/\+/g,' '));
      this.items = typeof value === 'string' ? value.replace(/^\?/,'').split('&').filter(Boolean).map(s=>{const at=s.indexOf('=');return at<0?[decode(s),'']:[decode(s.slice(0,at)),decode(s.slice(at+1))];})
        : value && typeof value[Symbol.iterator] === 'function' ? Array.from(value,p=>[String(p[0]),String(p[1])])
        : Object.entries(value||{}).map(([k,v])=>[String(k),String(v)]);
    }
    append(k,v) {this.items.push([String(k),String(v)]);}
    get(k) {return this.items.find(p=>p[0]===String(k))?.[1]??null;}
    getAll(k) {return this.items.filter(p=>p[0]===String(k)).map(p=>p[1]);}
    has(k) {return this.items.some(p=>p[0]===String(k));}
    set(k,v) {const at=this.items.findIndex(p=>p[0]===String(k));this.delete(k);this.items.splice(at<0?this.items.length:at,0,[String(k),String(v)]);}
    delete(k) {this.items=this.items.filter(p=>p[0]!==String(k));}
    sort() {this.items.sort((a,b)=>a[0]<b[0]?-1:a[0]>b[0]?1:0);}
    entries() {return this.items[Symbol.iterator]();}
    keys() {return this.items.map(p=>p[0])[Symbol.iterator]();}
    values() {return this.items.map(p=>p[1])[Symbol.iterator]();}
    forEach(fn) {for(const [k,v] of this.items)fn(v,k,this);}
    [Symbol.iterator]() {return this.entries();}
    toString() {const encode=s=>encodeURIComponent(s).replace(/[!'()~]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase()).replace(/%20/g,'+');return this.items.map(([k,v])=>encode(k)+'='+encode(v)).join('&');}
  }
  globalThis.URLSearchParams = HostSearchParams;
  class HostURL {
    constructor(value, base) { Object.assign(this, host('url',{value:String(value), base:base ? String(base) : ''})); }
    toString() { return this.href; }
    toJSON() { return this.href; }
  }
  globalThis.URL = HostURL;
  class HostBlob {
    constructor(parts=[], options={}) {
      this.bytes=NodeBuffer.concat(Array.from(parts,p=>p instanceof HostBlob?p.bytes:typeof p==='string'?NodeBuffer.from(p):NodeBuffer.from(p)));
      if(this.bytes.length>8*1024*1024)throw new Error('上传数据超过 8 MB');
      this.size=this.bytes.length;this.type=String(options.type||'').toLowerCase();
      if(/[\r\n]/.test(this.type))throw new Error('内容类型无效');
    }
    async arrayBuffer(){return this.bytes.buffer.slice(this.bytes.byteOffset,this.bytes.byteOffset+this.bytes.byteLength);}
    async text(){return this.bytes.toString();}
    slice(start=0,end=this.size,type=''){return new HostBlob([this.bytes.slice(start,end)],{type});}
  }
  class HostFile extends HostBlob {
    constructor(parts,name,options={}){super(parts,options);this.name=String(name);this.lastModified=options.lastModified??Date.now();}
  }
  class HostFormData {
    constructor(){this.items=[];}
    append(name,value,filename){if(this.items.length>=64)throw new Error('表单字段超过 64 个');this.items.push([String(name),value instanceof HostBlob?value:String(value),filename??value?.name??'blob']);}
    get(name){return this.items.find(p=>p[0]===String(name))?.[1]??null;}
    getAll(name){return this.items.filter(p=>p[0]===String(name)).map(p=>p[1]);}
    has(name){return this.items.some(p=>p[0]===String(name));}
    delete(name){this.items=this.items.filter(p=>p[0]!==String(name));}
    set(name,value,filename){this.delete(name);this.append(name,value,filename);}
    *entries(){for(const [name,value]of this.items)yield[name,value];}
    [Symbol.iterator](){return this.entries();}
    encode(){
      const boundary='----qqm'+host('uuid').replace(/-/g,''),parts=[];
      for(const [name,value,filename]of this.items){
        if(/[\r\n"\\]/.test(name)||/[\r\n"\\]/.test(filename))throw new Error('表单名称或文件名无效');
        const blob=value instanceof HostBlob;
        parts.push(NodeBuffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"${blob?`; filename="${filename}"`:''}\r\n${blob?`Content-Type: ${value.type||'application/octet-stream'}\r\n`:''}\r\n`),blob?value.bytes:NodeBuffer.from(value),NodeBuffer.from('\r\n'));
      }
      parts.push(NodeBuffer.from(`--${boundary}--\r\n`));
      const bytes=NodeBuffer.concat(parts);if(bytes.length>8*1024*1024)throw new Error('表单上传超过 8 MB');
      return {bytes,type:`multipart/form-data; boundary=${boundary}`};
    }
  }
  globalThis.Blob=HostBlob;globalThis.File=HostFile;globalThis.FormData=HostFormData;
  class AbortSignal {
    aborted=false; reason; listeners=new Set();
    addEventListener(_type, cb) { this.listeners.add(cb); }
    removeEventListener(_type, cb) { this.listeners.delete(cb); }
    throwIfAborted() { if (this.aborted) throw new Error('请求已取消'); }
    static timeout(ms){const controller=new globalThis.AbortController();setTimeout(()=>controller.abort(new Error('请求超时')),Math.max(0,Number(ms)||0));return controller.signal;}
  }
  globalThis.AbortSignal=AbortSignal;
  globalThis.AbortController = class {
    signal = new AbortSignal();
    abort(reason) { if (this.signal.aborted) return; this.signal.aborted=true; this.signal.reason=reason; for(const f of this.signal.listeners) f(); }
  };
  let next=0;
  const pending = new Map(), timers = new Map();
  globalThis.setTimeout = (fn, ms=0, ...args) => { const id=++next; timers.set(id,{fn,args,at:Date.now()+Math.max(0,Number(ms)||0)}); return id; };
  globalThis.clearTimeout = id => timers.delete(id);
  globalThis.setInterval=(fn,ms=1000,...args)=>{const id=++next;timers.set(id,{fn,args,at:Date.now()+Math.max(50,Number(ms)||1000),repeat:Math.max(50,Number(ms)||1000)});return id;};
  globalThis.clearInterval=globalThis.clearTimeout;
  const request = (operation, args, signal) => new Promise((resolve,reject) => {
    signal?.throwIfAborted?.();
    const id = host('request', {operation, args});
    const abort = () => { host('abort',{id}); pending.delete(id); reject(new Error('请求已取消')); };
    pending.set(id,{resolve,reject,signal,abort}); signal?.addEventListener?.('abort',abort);
  });
  const sockets=new Set();
  class HostWebSocket {
    static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
    CONNECTING=0;OPEN=1;CLOSING=2;CLOSED=3;readyState=0;binaryType='blob';listeners=new Map();
    constructor(url,protocols,options={}){
      if(protocols!=null&&(!Array.isArray(protocols)||protocols.length))throw new Error('此语音连接暂不使用子协议');
      this.url=String(url);sockets.add(this);
      this.done=(async()=>{
        try{
          const value=await request('socketOpen',{url:this.url,headers:options.headers||{}});this.id=value.id;
          if(this.readyState===2){await request('socketClose',{id:this.id});return;}
          this.readyState=1;this.emit('open',{});
          while(this.readyState===1){
            const events=await request('socketNext',{id:this.id});
            for(const event of events){
              if(this.readyState!==1)break;
              if(event.type==='message'){
                const bytes=event.binary?NodeBuffer.from(event.data,'base64'):null;
                const data=bytes?(this.binaryType==='arraybuffer'?bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength):new HostBlob([bytes])):event.data;
                this.emit('message',{data});
              }else if(event.type==='error'){throw new Error(event.message||'语音连接失败');}
              else if(event.type==='close'){this.readyState=3;}
            }
          }
        }catch(error){if(this.readyState!==2)this.emit('error',{message:String(error?.message||error)});}
        finally{
          const wasClean=this.readyState===2||this.readyState===3;this.readyState=3;
          if(this.id)try{await request('socketClose',{id:this.id});}catch{}
          this.emit('close',{wasClean,code:wasClean?1000:1006,reason:''});sockets.delete(this);
        }
      })();
    }
    emit(type,event){const full={type,target:this,...event};try{this['on'+type]?.(full);for(const cb of this.listeners.get(type)||[])cb(full);}catch(e){log('语音回调失败',String(e?.message||e));}}
    addEventListener(type,callback){if(!this.listeners.has(type))this.listeners.set(type,new Set());this.listeners.get(type).add(callback);}
    removeEventListener(type,callback){this.listeners.get(type)?.delete(callback);}
    send(value){if(this.readyState!==1)throw new Error('语音连接尚未打开');const binary=typeof value!=='string';request('socketSend',{id:this.id,binary,data:binary?NodeBuffer.from(value).toString('base64'):value}).catch(e=>{this.emit('error',{message:String(e.message)});this.close();});}
    close(){if(this.readyState>=2)return;this.readyState=2;if(this.id)request('socketClose',{id:this.id}).catch(()=>{});}
  }
  globalThis.WebSocket=HostWebSocket;
  const fetch = async(url, options={}) => {
    let body=options.body;const headers={...(options.headers||{})};
    const contentType=type=>{if(type&&!Object.keys(headers).some(k=>k.toLowerCase()==='content-type'))headers['Content-Type']=type;};
    if(body instanceof HostFormData){const encoded=body.encode();body=encoded.bytes;for(const key of Object.keys(headers))if(key.toLowerCase()==='content-type')delete headers[key];contentType(encoded.type);}
    if(body instanceof HostBlob){contentType(body.type);body=body.bytes;}
    if(body instanceof ArrayBuffer || ArrayBuffer.isView(body)){const b=NodeBuffer.from(body);if(b.length>8*1024*1024)throw new Error('上传超过 8 MB');body={__qqmBinary:true,data:b.toString('base64')};}
    const r = await request('fetch',{url:String(url), method:options.method || 'GET', headers, body, redirect:options.redirect || 'manual'},options.signal);
    const data = NodeBuffer.from(r.data,'base64');
    return {status:r.status, ok:r.status>=200&&r.status<300, url:r.url,
      headers:{get:name=>r.headers[String(name).toLowerCase()] ?? null},
      arrayBuffer:async()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),
      text:async()=>data.toString(), json:async()=>JSON.parse(data.toString()),
      body:{cancel:async()=>{}},
    };
  };
  globalThis.fetch=fetch;
  const writeLog=(level,args)=>host('log',{level,text:args.map(a=>typeof a==='string'?a:JSON.stringify(a)).join(' ')});
  const log = (...args) => writeLog('info',args),warn=(...args)=>writeLog('warning',args),error=(...args)=>writeLog('error',args);
  globalThis.console = {log,info:log,warn,error,debug:log};
  const unavailable = what => {throw new Error(`${what}尚未由当前跨平台宿主开放；请查看扩展兼容情况。`);};
  const packageInfo = host('packageInfo');
  globalThis.__qqAgentRoot = '/qqm-compat';
  globalThis.__agentModules = {'fs':fs,'path':path,'os':{tmpdir:()=>'/tmp',platform:()=> 'qqm'},
    'fs/promises':fs.promises,
    'url':{URL:HostURL,URLSearchParams:HostSearchParams,fileURLToPath:value=>host('fileURL',{value:String(value)}),pathToFileURL:value=>new HostURL('file://'+path.resolve(value))},'crypto':crypto,'buffer':{Buffer:NodeBuffer},
    // Imports are supported so setup/available can report missing dependencies.
    // These are explicit failures, not fake processes or shell execution.
    'child_process':Object.fromEntries(['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork'].map(name=>[name,()=>unavailable(`外部程序调用 child_process.${name}`)])),
    'qqm-config':{DATA_DIR:'/data',getConfig:()=>({...globalThis.__agent?.input?.hostConfig,skills:{...globalThis.__agent?.input?.hostConfig?.skills,[packageInfo.id]:{...globalThis.__agent?.config,settings:globalThis.__agent?.config || {}}}}),updateConfig:value=>request('host',{operation:'updateConfig',args:{value}})},
    'qqm-logger':{logger:{info:log,warn,error,debug:log}},
    'qqm-safe-fetch':{validateImageUrl:async url=>{const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password)throw new Error('图片需要公共 HTTPS 地址');await request('host',{operation:'validateImageUrl',args:{url:u.href}});return u.href;}},
    'qqm-stickers':{localStickerPath:()=>null},
    'qqm-model-prices':{resolveModelPrice:(model,cfg)=>{const p=(cfg||globalThis.__agent?.input?.hostConfig)?.modelPrices?.[model];if(!p)throw new Error('请先填写模型输入 / 输出价格；未配置的价格不能计算费用。');return p;},priceAt:price=>price,modelLabel:(vendor,model)=>`${vendor}/${model}`},
    'qqm-tool-registry':{getToolAvailability:id=>{const enabled=globalThis.__agent?.input?.availableTools?.includes(id)===true;return {enabled,reason:enabled?'':'工具未在本连接启用，或缺少模型价格配置'};}},
  };
  globalThis.__agent = {
    tools:new Map(), module:null, sent:[], input:{}, finished:false, result:null, failure:null,
    async load(module, config, mode) {
      this.module=module;
      this.config={...config,...(typeof config.tempDir==='string'?{tempDir:'/tmp'}:{})};
      const api={config:()=>this.config,log,warn,error,logger:{info:log,warn,error},
        isSkillActive:id=>id===packageInfo.id,
        capability:name=>{
          if(this.module.providers?.[name])return this.module.providers[name];
          if(!this.input.capabilities?.includes(name))return null;
          const call=(...args)=>request('host',{operation:'capability',args:{name,args}});
          return new Proxy(call, {get:(_,method)=>method==='then'?undefined:(...args)=>request('host',{operation:'capability',args:{name,method,args}})});
        },
        registerTool:tool=> {
        if (!tool || typeof tool.id!=='string' || !/^[a-zA-Z][a-zA-Z0-9_-]{0,39}$/.test(tool.id) || typeof tool.execute!=='function' || this.tools.has(tool.id) || this.tools.size>=12) throw new Error('工具定义无效或重复');
        this.tools.set(tool.id,tool);
        return `${packageInfo.id}__${tool.id}`;
      },fetch};
      await module.setup?.(api);
      if(mode==='inspect') {
        const availability=await module.available?.();
        return {tools:[...this.tools.values()].map(t=>({id:t.id,name:t.name||t.id,description:t.description||t.name||t.id,parameters:t.parameters,...(typeof t.requiresMediaAck==='boolean'?{requiresMediaAck:t.requiresMediaAck}:{})})),
          available:typeof availability==='boolean'?{ok:availability}:availability??{ok:true},
          hooks:Object.keys(module.hooks||{}),providers:Object.keys(module.providers||{})};
      }
    },
    context(input){
      this.input=input;this.sent=Array.isArray(input.session?.sent)?input.session.sent:[];
      const onebot={selfId:input.protocol==='onebot'?input.selfId:'',connected:input.protocol==='onebot',selfInfo:input.selfInfo||{},
        call:(action,params={})=>request('host',{operation:'onebot',args:{action,params}}),
        sendText:(kind,peer,text)=>request('host',{operation:'notify',args:{kind,peer,text:String(text)}})};
      const sender={
        sendImage:async(chatKey,image,options={})=>{if(chatKey!==input.chatKey)throw new Error('只允许发送到当前会话');const r=await request('sendImage',{file:image?.file,chatKey,note:options.note});this.sent.push({type:'image',...r});return r;},
        sendText:async(chatKey,text)=>{if(chatKey!==input.chatKey)throw new Error('只允许发送到当前会话');const r=await request('sendText',{text:String(text),chatKey});const sent={type:'text',text:String(text),at:Date.now(),...r};this.sent.push(sent);return sent;},
        sendTextBatch:async(chatKey,texts)=>{if(!Array.isArray(texts)||texts.length>5)throw new Error('每次最多发送 5 条文字');const sent=[];for(const text of texts)sent.push(await sender.sendText(chatKey,text));return {ok:true,sent};},
        sendMedia:async(chatKey,segments)=>{if(chatKey!==input.chatKey)throw new Error('只允许发送到当前会话');if(!Array.isArray(segments)||segments.length<1||segments.length>3)throw new Error('每次仅支持 1–3 条语音');const receipts=[];for(const segment of segments){if(segment?.type!=='record')throw new Error('当前媒体接口支持 record 语音');const r=await request('sendMedia',{type:'record',file:String(segment.data?.file||''),chatKey});this.sent.push({type:'record',...r});receipts.push(r);}return {ok:true,sent:receipts};},
        sendMediaUrl:async(chatKey,url)=>sender.sendMedia(chatKey,[{type:'record',data:{file:String(url)}}]),
      };
      const recent=(key,{limit=40}={})=>key===input.chatKey?(input.recentEntries||[]).slice(-Math.min(100,Math.max(0,Number(limit)||0))):[];
      const findByMid=(key,id)=>recent(key,{limit:100}).find(e=>String(e.id||e.mid)===String(id))||null;
      return {...input,onebot,sender,store:{recent,get:findByMid,findByMid},
        session:{...(input.session||{}),sent:this.sent},emit:(event,data)=>log(event,data)};
    },
    async effects(){await new Promise(resolve=>setTimeout(resolve,20));while(pending.size||sockets.size){await new Promise(resolve=>setTimeout(resolve,20));}},
    async run(operation,args,input) {
      if(operation==='inspect') return args;
      if(operation==='session'){
        for(;;){const job=await request('nextJob');
          try{const value=await this.run(job.operation,job.args||{},job.input||{});if(job.operation!=='activate')await this.effects();await request('jobDone',{id:job.id,result:value});}
          catch(error){await request('jobDone',{id:job.id,error:String(error?.message||error)});}
        }
      }
      const ctx=this.context(input);
      if(operation==='activate'){if(!this.activated){this.activated=true;await this.module.activate?.(ctx);}return {ok:true};}
      if(operation==='deactivate'){await this.module.deactivate?.(ctx);return {ok:true};}
      if(operation==='hook'){const hook=this.module.hooks?.[args.name];const result=typeof hook==='function'?await hook(ctx):null;return {messages:ctx.messages,response:ctx.response,result};}
      if(operation==='provider'||operation==='capability'){
        const provider=this.module.providers?.[args.name];if(provider==null)return {provided:false};
        let result;
        if(args.method){const fn=provider[args.method];if(typeof fn!=='function')throw new Error('插件能力没有此方法');result=await fn(...(args.values||[]));}
        else result=typeof provider==='function'?await provider(ctx):provider;
        return {provided:true,value:result};
      }
      if(operation==='plugin') {
        const available=await this.module.available?.() ?? {ok:true};
        if(available===false || available?.ok===false) throw new Error(available?.reason || '插件配置不完整');
        const provider=this.module.providers?.['message.owner-check'];
        const result=provider ? await provider(input) : {};
        const owners=[];
        if(provider) for(const userId of input.trustedSenders || []) if((await provider({userId}))?.isOwner===true) owners.push(userId);
        return {...result,owners,sections:await this.module.promptSections?.() ?? []};
      }
      if(operation==='tool') {
        const available=await this.module.available?.() ?? {ok:true};
        if(available===false || available?.ok===false) throw new Error(available?.reason || 'Skill 配置不完整');
        const tool=this.tools.get(args.id);
        if(!tool) throw new Error('工具不存在');
        const result=await tool.execute(ctx,args.args||{});await this.effects();return result;
      }
      throw new Error('未知包操作');
    },
    start(job) { Promise.resolve(job).then(value=>{this.result=value??null;this.finished=true;},error=>{this.failure=String(error?.message||error);this.finished=true;}); },
    tick() { for(const [id,t] of timers) if(t.at<=Date.now()){if(t.repeat)t.at=Date.now()+t.repeat;else timers.delete(id);try{Promise.resolve(t.fn(...t.args)).catch(e=>log('插件定时任务失败',String(e)));}catch(e){log('插件定时任务失败',String(e));}} },
    settle(id,value,error) { const p=pending.get(id); if(!p)return;pending.delete(id);p.signal?.removeEventListener?.('abort',p.abort);error?p.reject(new Error(error)):p.resolve(value); },
    poll() { const now=Date.now();let waitMs=1000;for(const timer of timers.values())waitMs=Math.min(waitMs,Math.max(0,timer.at-now));return {finished:this.finished,result:this.result,failure:this.failure,waitMs}; },
  };
})();
''';
