// The supported Node client APIs share the package's existing network and VFS
// boundaries. Server/process imports are available for dependency inspection;
// they are not advertised as an installed desktop Node/Python environment.
const agentNodeExports = <String, List<String>>{
  'http': [
    'request',
    'get',
    'Agent',
    'globalAgent',
    'ClientRequest',
    'IncomingMessage',
    'Server',
    'createServer',
    'METHODS',
    'STATUS_CODES',
  ],
  'https': ['request', 'get', 'Agent', 'globalAgent', 'Server', 'createServer'],
  'events': [
    'EventEmitter',
    'once',
    'on',
    'getEventListeners',
    'listenerCount',
  ],
  'stream': [
    'Stream',
    'Readable',
    'Writable',
    'Duplex',
    'Transform',
    'PassThrough',
    'pipeline',
    'finished',
  ],
  'stream/promises': ['pipeline', 'finished'],
  'util': [
    'promisify',
    'callbackify',
    'inherits',
    'format',
    'inspect',
    'types',
    'TextEncoder',
    'TextDecoder',
  ],
  'querystring': [
    'parse',
    'stringify',
    'encode',
    'decode',
    'escape',
    'unescape',
  ],
  'string_decoder': ['StringDecoder'],
  'timers': [
    'setTimeout',
    'clearTimeout',
    'setInterval',
    'clearInterval',
    'setImmediate',
    'clearImmediate',
  ],
  'timers/promises': ['setTimeout', 'setImmediate'],
  'process': ['nextTick', 'cwd', 'platform', 'env', 'versions'],
};

const agentNodeCompat = r'''
  const defer = fn => Promise.resolve().then(fn);
  const nodeError = (message, code) => Object.assign(new Error(message), {code});
  class EventEmitter {
    constructor(){this._events=new Map();this._maxListeners=10;}
    on(name,fn){if(typeof fn!=='function')throw new TypeError('listener must be a function');const list=this._events.get(name)||[];list.push(fn);this._events.set(name,list);return this;}
    addListener(name,fn){return this.on(name,fn);}
    once(name,fn){const once=(...args)=>{this.off(name,once);return fn.apply(this,args);};once.listener=fn;return this.on(name,once);}
    prependListener(name,fn){this.on(name,fn);const list=this._events.get(name);list.unshift(list.pop());return this;}
    prependOnceListener(name,fn){this.once(name,fn);const list=this._events.get(name);list.unshift(list.pop());return this;}
    off(name,fn){const list=this._events.get(name)||[];for(let i=list.length-1;i>=0;i--)if(list[i]===fn||list[i].listener===fn){list.splice(i,1);break;}if(!list.length)this._events.delete(name);return this;}
    removeListener(name,fn){return this.off(name,fn);}
    removeAllListeners(name){if(arguments.length)this._events.delete(name);else this._events.clear();return this;}
    emit(name,...args){const list=this._events.get(name)||[];if(name==='error'&&!list.length)throw args[0] instanceof Error?args[0]:new Error(String(args[0]));for(const fn of [...list])fn.apply(this,args);return list.length>0;}
    listeners(name){return (this._events.get(name)||[]).map(fn=>fn.listener||fn);}
    rawListeners(name){return [...(this._events.get(name)||[])];}
    listenerCount(name){return (this._events.get(name)||[]).length;}
    eventNames(){return [...this._events.keys()];}
    setMaxListeners(n){this._maxListeners=n;return this;}
    getMaxListeners(){return this._maxListeners;}
  }
  const eventOnce=(emitter,name,options={})=>new Promise((resolve,reject)=>{
    const done=(...args)=>{clean();resolve(args);},fail=e=>{clean();reject(e);},abort=()=>fail(nodeError('The operation was aborted','ABORT_ERR'));
    const clean=()=>{emitter.off(name,done);if(name!=='error')emitter.off('error',fail);options.signal?.removeEventListener('abort',abort);};
    emitter.once(name,done);if(name!=='error')emitter.once('error',fail);
    if(options.signal?.aborted)abort();else options.signal?.addEventListener('abort',abort);
  });
  async function* eventOn(emitter,name,options={}){
    const queue=[];let failure,closed=false,wake;
    const data=(...args)=>{queue.push(args);wake?.();},error=e=>{failure=e;wake?.();},close=()=>{closed=true;wake?.();},abort=()=>error(nodeError('The operation was aborted','ABORT_ERR'));
    emitter.on(name,data);emitter.on('error',error);for(const n of options.close||[])emitter.on(n,close);options.signal?.addEventListener('abort',abort);
    try{if(options.signal?.aborted)abort();for(;;){if(queue.length){yield queue.shift();continue;}if(failure)throw failure;if(closed)return;await new Promise(r=>wake=r);wake=null;}}
    finally{emitter.off(name,data);emitter.off('error',error);for(const n of options.close||[])emitter.off(n,close);options.signal?.removeEventListener('abort',abort);}
  }
  class StringDecoder {
    constructor(encoding='utf8'){this.encoding=encoding.toLowerCase();this.pending=NodeBuffer.alloc(0);}
    write(value){const bytes=NodeBuffer.concat([this.pending,NodeBuffer.from(value)]);let end=bytes.length;
      if(this.encoding==='utf8'||this.encoding==='utf-8'){
        let lead=end-1;while(lead>=0&&end-lead<=4&&(bytes[lead]&0xc0)===0x80)lead--;
        if(lead>=0){const b=bytes[lead],need=(b&0xf8)===0xf0?4:(b&0xf0)===0xe0?3:(b&0xe0)===0xc0?2:1;if(end-lead<need)end=lead;}
      }else if(this.encoding==='base64')end-=end%3;
      this.pending=bytes.slice(end);return bytes.toString(this.encoding,0,end);
    }
    end(value){const text=value==null?'':this.write(value),tail=this.pending.toString(this.encoding);this.pending=NodeBuffer.alloc(0);return text+tail;}
  }
  class Stream extends EventEmitter {
    destroy(error){if(this.destroyed)return this;this.destroyed=true;this.errored=error||null;defer(()=>{if(error)this.emit('error',error);this.closed=true;this.emit('close');});return this;}
  }
  class Readable extends Stream {
    constructor(options={}){super();this.readable=true;this.readableEnded=false;this.destroyed=false;this.closed=false;this._queue=[];this._queueBytes=0;this._eof=false;this._flow=false;this._scheduled=false;this._decoder=null;this._objectMode=!!options.objectMode;if(options.read)this._read=options.read;if(options.encoding)this.setEncoding(options.encoding);}
    _read(){}
    on(name,fn){super.on(name,fn);if(name==='data')this.resume();else if(name==='readable')this._schedule();return this;}
    push(value,encoding){if(this.destroyed)return false;if(value===null){this._eof=true;this._schedule();return false;}if(this._eof)throw nodeError('stream.push() after EOF','ERR_STREAM_PUSH_AFTER_EOF');const chunk=this._objectMode?value:NodeBuffer.from(value,encoding);const size=this._objectMode?1:chunk.length;if(this._queueBytes+size>12*1024*1024)throw new Error('流缓冲超过 12 MB');this._queue.push(chunk);this._queueBytes+=size;this.emit('readable');this._schedule();return this._queueBytes<65536;}
    read(){if(!this._queue.length){this._schedule();return null;}const chunk=this._queue.shift();this._queueBytes-=this._objectMode?1:chunk.length;this._schedule();return this._decoder?this._decoder.write(chunk):chunk;}
    setEncoding(encoding){this._decoder=new StringDecoder(encoding);this.readableEncoding=encoding;return this;}
    pause(){this._flow=false;this.emit('pause');return this;}
    resume(){this._flow=true;this.emit('resume');this._schedule();return this;}
    isPaused(){return !this._flow;}
    _schedule(){if(this._scheduled||this.destroyed)return;this._scheduled=true;defer(()=>{this._scheduled=false;try{if(!this._eof&&!this._queue.length)this._read(65536);while(this._flow&&this._queue.length&&!this.destroyed){const chunk=this.read();if(chunk!==''&&chunk!==null)this.emit('data',chunk);}if(this._eof&&!this._queue.length&&!this.readableEnded&&!this.destroyed){const tail=this._decoder?.end();if(tail&&this._flow)this.emit('data',tail);this.readableEnded=true;this.readable=false;this.emit('end');}}catch(error){this.destroy(error);}});}
    pipe(destination,options={}){const data=chunk=>{if(destination.write(chunk)===false){this.pause();destination.once('drain',()=>this.resume());}},end=()=>{if(options.end!==false)destination.end();cleanup();},failure=e=>{cleanup();destination.destroy(e);},cleanup=()=>{this.off('data',data);this.off('end',end);this.off('error',failure);};this.on('data',data);this.once('end',end);this.once('error',failure);destination.once('close',cleanup);destination.emit('pipe',this);return destination;}
    async *[Symbol.asyncIterator](){this.pause();try{for(;;){if(this._queue.length){const chunk=this.read();if(chunk!==''&&chunk!==null)yield chunk;continue;}if(this.errored)throw this.errored;if(this.readableEnded||this.destroyed)return;await new Promise((resolve,reject)=>{const ready=()=>{clean();resolve();},fail=e=>{clean();reject(e);},clean=()=>{this.off('readable',ready);this.off('end',ready);this.off('close',ready);this.off('error',fail);};this.once('readable',ready);this.once('end',ready);this.once('close',ready);this.once('error',fail);this._schedule();});}}finally{if(!this.readableEnded&&!this.destroyed)this.destroy();}}
    static from(iterable,options={}){const stream=new Readable({objectMode:true,...options});if(typeof iterable==='string'||NodeBuffer.isBuffer(iterable))iterable=[iterable];let started=false;stream._read=()=>{if(started)return;started=true;(async()=>{try{for await(const item of iterable){if(stream.destroyed)return;if(item===null)throw new TypeError('Readable.from cannot yield null');stream.push(item);}stream.push(null);}catch(e){stream.destroy(e);}})();};return stream;}
  }
  class Writable extends Stream {
    constructor(options={}){super();this.writable=true;this.writableEnded=false;this.writableFinished=false;this.destroyed=false;this.closed=false;this._writes=[];this._writing=false;this._writeBytes=0;this._objectMode=!!options.objectMode;this._defaultEncoding=options.defaultEncoding||'utf8';if(options.write)this._write=options.write;if(options.final)this._final=options.final;}
    _write(_chunk,_encoding,callback){callback(nodeError('_write is not implemented','ERR_METHOD_NOT_IMPLEMENTED'));}
    _final(callback){callback();}
    setDefaultEncoding(encoding){this._defaultEncoding=encoding;return this;}
    write(chunk,encoding,callback){if(typeof encoding==='function'){callback=encoding;encoding=undefined;}if(this.writableEnded||this.destroyed){const e=nodeError('write after end','ERR_STREAM_WRITE_AFTER_END');defer(()=>{callback?.(e);if(!this.destroyed)this.destroy(e);});return false;}const value=this._objectMode?chunk:NodeBuffer.from(chunk,encoding||this._defaultEncoding),size=this._objectMode?1:value.length;if(this._writeBytes+size>8*1024*1024)throw new Error('写入缓冲超过 8 MB');this._writeBytes+=size;this._writes.push({value,encoding:encoding||'buffer',callback,size});this._pump();return this._writeBytes<65536;}
    _pump(){if(this._writing||this.destroyed)return;const job=this._writes.shift();if(!job){if(this.writableEnded&&!this._finalStarted){this._finalStarted=true;try{this._final(error=>{if(error){this.destroy(error);return;}this.writableFinished=true;this.writable=false;this.emit('finish');});}catch(e){this.destroy(e);}}return;}this._writing=true;let called=false;const done=error=>{if(called)return;called=true;this._writing=false;this._writeBytes-=job.size;job.callback?.(error);if(error){this.destroy(error);return;}if(!this._writeBytes)this.emit('drain');defer(()=>this._pump());};try{this._write(job.value,job.encoding,done);}catch(error){done(error);}}
    end(chunk,encoding,callback){if(typeof chunk==='function'){callback=chunk;chunk=undefined;}if(typeof encoding==='function'){callback=encoding;encoding=undefined;}if(callback){if(this.writableFinished)defer(()=>callback());else this.once('finish',callback);}if(this.writableEnded)return this;if(chunk!=null)this.write(chunk,encoding);this.writableEnded=true;this._pump();return this;}
  }
  class Duplex extends Readable {
    constructor(options={}){super(options);this._writer=new Writable({...options,write:(chunk,encoding,done)=>this._write(chunk,encoding,done),final:done=>this._final(done)});for(const name of ['finish','drain'])this._writer.on(name,(...args)=>this.emit(name,...args));this._writer.on('error',e=>this.destroy(e));}
    _write(_chunk,_encoding,done){done(nodeError('_write is not implemented','ERR_METHOD_NOT_IMPLEMENTED'));}
    _final(done){done();}
    write(...args){return this._writer.write(...args);}
    end(...args){this._writer.end(...args);return this;}
    get writableEnded(){return this._writer?.writableEnded||false;}
    get writableFinished(){return this._writer?.writableFinished||false;}
  }
  class Transform extends Duplex {
    constructor(options={}){super(options);if(options.transform)this._transform=options.transform;if(options.flush)this._flush=options.flush;}
    _transform(_chunk,_encoding,done){done(nodeError('_transform is not implemented','ERR_METHOD_NOT_IMPLEMENTED'));}
    _write(chunk,encoding,done){this._transform(chunk,encoding,(error,data)=>{if(!error&&data!=null)this.push(data);done(error);});}
    _final(done){const end=(error,data)=>{if(!error){if(data!=null)this.push(data);this.push(null);}done(error);};if(this._flush)this._flush(end);else end();}
  }
  class PassThrough extends Transform {_transform(chunk,_encoding,done){done(null,chunk);}}
  const streamFinished=(stream,callback)=>{
    let completed=false;const clean=()=>{for(const [name,fn]of listeners)stream.off(name,fn);},end=error=>{if(completed)return;completed=true;clean();callback(error);},check=()=>{if((!stream.readable||stream.readableEnded)&&(!stream.writable||stream.writableFinished))end();},close=()=>{check();if(!completed)end(nodeError('Premature close','ERR_STREAM_PREMATURE_CLOSE'));};
    const listeners=[['end',check],['finish',check],['error',end],['close',close]];for(const [name,fn]of listeners)stream.on(name,fn);defer(check);return clean;
  };
  const pipeline=(...args)=>{const callback=typeof args[args.length-1]==='function'?args.pop():null;if(Array.isArray(args[0]))args=args[0];if(!callback)throw new TypeError('pipeline callback required; use stream/promises for a Promise');if(args.length<2)throw new TypeError('pipeline needs a source and destination');let done=false;const finish=error=>{if(done)return;done=true;if(error)for(const s of args)s.destroy?.();for(const s of args)s.off('error',finish);callback(error);};for(const s of args)s.on('error',finish);streamFinished(args[args.length-1],finish);for(let i=0;i<args.length-1;i++)args[i].pipe(args[i+1]);return args[args.length-1];};
  const streamPromises={pipeline:(...args)=>new Promise((resolve,reject)=>pipeline(...args,error=>error?reject(error):resolve())),finished:stream=>new Promise((resolve,reject)=>streamFinished(stream,error=>error?reject(error):resolve()))};
  Stream.Readable=Readable;Stream.Writable=Writable;Stream.Duplex=Duplex;Stream.Transform=Transform;Stream.PassThrough=PassThrough;Stream.pipeline=pipeline;Stream.finished=streamFinished;
  fs.createReadStream=(file,options={})=>{if(typeof options==='string')options={encoding:options};const stream=new Readable(options);let read=false;stream.path=String(file);stream._read=()=>{if(read)return;read=true;try{const bytes=fs.readFileSync(file),start=options.start??0,end=options.end==null?bytes.length:Math.min(bytes.length,options.end+1),chunk=Math.min(65536,Math.max(1,options.highWaterMark||65536));if(start<0||end<start)throw new RangeError('file stream range invalid');stream.emit('open',null);for(let i=start;i<end;i+=chunk)stream.push(bytes.subarray(i,Math.min(end,i+chunk)));stream.push(null);}catch(error){stream.destroy(error);}};return stream;};
  fs.createWriteStream=(file,options={})=>{if(typeof options==='string')options={encoding:options};if(options.flags&&!['w','a'].includes(options.flags))throw new Error('文件流仅支持 w / a');const chunks=[];let length=0;const stream=new Writable({defaultEncoding:options.encoding,write(chunk,_encoding,done){length+=chunk.length;if(length>8*1024*1024)return done(new Error('文件流超过 8 MB'));chunks.push(chunk);done();},final(done){try{const prefix=options.flags==='a'&&fs.existsSync(file)?fs.readFileSync(file):NodeBuffer.alloc(0);fs.writeFileSync(file,NodeBuffer.concat([prefix,...chunks]));done();stream.emit('close');}catch(error){done(error);}}});stream.path=String(file);return stream;};
  const STATUS_CODES={200:'OK',201:'Created',202:'Accepted',204:'No Content',206:'Partial Content',301:'Moved Permanently',302:'Found',303:'See Other',304:'Not Modified',307:'Temporary Redirect',308:'Permanent Redirect',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',405:'Method Not Allowed',408:'Request Timeout',409:'Conflict',413:'Payload Too Large',429:'Too Many Requests',500:'Internal Server Error',502:'Bad Gateway',503:'Service Unavailable',504:'Gateway Timeout'};
  class IncomingMessage extends Readable {
    constructor(response){super();this.statusCode=response.status;this.statusMessage=STATUS_CODES[response.status]||'';this.headers={...response.headers};this.rawHeaders=Object.entries(this.headers).flat();this.httpVersion='1.1';this.complete=true;this.aborted=false;}
  }
  class HttpAgent {constructor(options={}){this.options={...options};this.keepAlive=!!options.keepAlive;}destroy(){}}
  const httpOptions=(protocol,input,options,callback)=>{
    if(typeof options==='function'){callback=options;options={};}let parsed,config;
    if(typeof input==='string'||input instanceof HostURL){parsed=new HostURL(input);config={...options};}else config={...(input||{}),...options};
    const scheme=config.protocol||parsed?.protocol||protocol;if(!['http:','https:'].includes(scheme))throw nodeError('Unsupported protocol','ERR_INVALID_PROTOCOL');
    if(scheme!==protocol)throw nodeError(`Protocol ${scheme} not supported by ${protocol}`,'ERR_INVALID_PROTOCOL');
    const hostName=config.hostname||config.host||parsed?.hostname||'localhost';const hostString=String(hostName);const hostname=hostString.includes(':')&&!hostString.startsWith('[')?`[${hostString}]`:hostString;
    const port=config.port||parsed?.port;const targetPath=config.path||((parsed?.pathname||'/')+(parsed?.search||''));if(!targetPath.startsWith('/')||/[\r\n]/.test(targetPath))throw new Error('HTTP path invalid');
    const target=new HostURL(`${scheme}//${hostname}${port?':'+port:''}${targetPath}`);if(config.auth||parsed?.username||parsed?.password)throw new Error('请使用插件设置中的 API Key；URL 不支持嵌入账号密码');
    for(const key of ['createConnection','lookup','socketPath','ca','cert','key','pfx','checkServerIdentity'])if(config[key]!=null)throw new Error(`当前 HTTP 兼容接口不支持 ${key}`);
    if(config.rejectUnauthorized===false||config.agent?.options?.rejectUnauthorized===false)throw new Error('不能关闭 TLS 证书校验');
    return {url:target.href,options:config,callback};
  };
  class ClientRequest extends Writable {
    constructor(target){const chunks=[];let length=0;super({write(chunk,_encoding,done){length+=chunk.length;if(length>8*1024*1024)return done(new Error('请求正文超过 8 MB'));chunks.push(chunk);done();}});this._chunks=chunks;this._target=target;this.method=String(target.options.method||'GET').toUpperCase();this.path=new HostURL(target.url).pathname+new HostURL(target.url).search;this.protocol=new HostURL(target.url).protocol;this.host=new HostURL(target.url).host;this._headers=new Map();this._controller=new globalThis.AbortController();this._sent=false;this._requestClosed=false;this.aborted=false;for(const [key,value]of Object.entries(target.options.headers||{}))this.setHeader(key,value);if(target.callback)this.once('response',target.callback);if(target.options.timeout)this.setTimeout(target.options.timeout);const signal=target.options.signal;if(signal){this._externalSignal=signal;this._externalAbort=()=>this.destroy(nodeError('The operation was aborted','ABORT_ERR'));if(signal.aborted)defer(this._externalAbort);else signal.addEventListener('abort',this._externalAbort);}}
    setHeader(name,value){if(this._sent)throw nodeError('Headers already sent','ERR_HTTP_HEADERS_SENT');const key=String(name);if(!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key))throw new TypeError('Invalid HTTP header name');const values=Array.isArray(value)?value.map(String):[String(value)];if(values.some(v=>/[\r\n]/.test(v)))throw new TypeError('Invalid HTTP header value');this._headers.set(key.toLowerCase(),{name:key,value:Array.isArray(value)?values:values[0]});return this;}
    getHeader(name){return this._headers.get(String(name).toLowerCase())?.value;}
    getHeaderNames(){return [...this._headers.keys()];}
    getRawHeaderNames(){return [...this._headers.values()].map(v=>v.name);}
    getHeaders(){return Object.fromEntries([...this._headers].map(([k,v])=>[k,v.value]));}
    hasHeader(name){return this._headers.has(String(name).toLowerCase());}
    removeHeader(name){if(this._sent)throw nodeError('Headers already sent','ERR_HTTP_HEADERS_SENT');this._headers.delete(String(name).toLowerCase());}
    setTimeout(ms,callback){if(!Number.isFinite(Number(ms))||ms<0)throw new RangeError('timeout invalid');if(callback)this.once('timeout',callback);this._timeoutMs=Number(ms);clearTimeout(this._timeout);if(this._sent)this._armTimeout();return this;}
    _armTimeout(){if(this._timeoutMs>0)this._timeout=setTimeout(()=>{if(!this.destroyed&&!this._requestClosed)this.emit('timeout');},this._timeoutMs);}
    _cleanup(){clearTimeout(this._timeout);this._externalSignal?.removeEventListener('abort',this._externalAbort);}
    _final(callback){callback();defer(()=>this._dispatch());}
    async _dispatch(){if(this.destroyed||this._sent)return;this._sent=true;this._armTimeout();try{const headers={};for(const [name,value]of this._headers)headers[name]=Array.isArray(value.value)?value.value.join(', '):value.value;const body=NodeBuffer.concat(this._chunks);this._chunks.length=0;const response=await request('nodeHttp',{url:this._target.url,method:this.method,headers,body:body.length?{__qqmBinary:true,data:body.toString('base64')}:undefined},this._controller.signal);if(this.destroyed)return;this._cleanup();const message=new IncomingMessage(response);this._response=message;message.once('end',()=>this._closeRequest());this.emit('response',message);const bytes=NodeBuffer.from(response.data,'base64');for(let i=0;i<bytes.length;i+=32768){if(message.destroyed)break;message.push(bytes.subarray(i,Math.min(bytes.length,i+32768)));}if(!message.destroyed)message.push(null);else this._closeRequest();}catch(error){if(!this.destroyed)this.destroy(error);} }
    _closeRequest(){if(this._requestClosed)return;this._requestClosed=true;this._cleanup();this.emit('close');}
    destroy(error){if(this.destroyed)return this;this._cleanup();this._controller.abort();this._response?.destroy(error);return super.destroy(error);}
    abort(){if(this.aborted)return;this.aborted=true;this.destroy();defer(()=>this.emit('abort'));}
    get finished(){return this.writableEnded;}
  }
  // Dependency inspection collects declarations without opening a listening
  // socket. Actual local servers require a desktop Node service adapter.
  class InspectionServer extends EventEmitter {
    listening=false;
    listen(){if(!host('packageInfo').inspecting)throw new Error('本地 HTTP 服务需要独立 Node.js 运行环境；当前内嵌引擎支持 HTTP 客户端请求');return this;}
    close(callback){this.listening=false;callback?.();return this;}
    address(){return null;}
    unref(){return this;}
    ref(){return this;}
  }
  const makeHttp=protocol=>{const agent=new HttpAgent();const request=(input,options,callback)=>new ClientRequest(httpOptions(protocol,input,options,callback));return {request,get:(input,options,callback)=>{const req=request(input,options,callback);req.method='GET';req.end();return req;},Agent:HttpAgent,globalAgent:agent,ClientRequest,IncomingMessage,Server:InspectionServer,createServer:()=>new InspectionServer(),METHODS:['GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS'],STATUS_CODES};};
  const promisifySymbol=Symbol.for('nodejs.util.promisify.custom');
  const promisify=fn=>{if(fn[promisifySymbol])return fn[promisifySymbol];return function(...args){return new Promise((resolve,reject)=>fn.call(this,...args,(error,value)=>error?reject(error):resolve(value)));};};promisify.custom=promisifySymbol;
  const format=(value,...args)=>{if(typeof value!=='string')return [value,...args].map(v=>typeof v==='string'?v:JSON.stringify(v)).join(' ');let i=0;const text=value.replace(/%[%sdjifoO]/g,token=>{if(token==='%%')return '%';if(i>=args.length)return token;const arg=args[i++];if(token==='%j'||token==='%o'||token==='%O'){try{return JSON.stringify(arg);}catch{return '[Circular]';}}return token==='%d'||token==='%i'?String(parseInt(arg)):token==='%f'?String(parseFloat(arg)):String(arg);});return text+(i<args.length?' '+args.slice(i).map(String).join(' '):'');};
  const queryParse=(value,separator='&',equal='=',options={})=>{const out=Object.create(null),decode=options.decodeURIComponent||((v)=>decodeURIComponent(v.replace(/\+/g,' ')));const entries=String(value||'').split(separator).slice(0,options.maxKeys===0?undefined:options.maxKeys||1000);for(const entry of entries){if(!entry)continue;const at=entry.indexOf(equal),key=decode(at<0?entry:entry.slice(0,at)),v=decode(at<0?'':entry.slice(at+equal.length));if(Object.prototype.hasOwnProperty.call(out,key))out[key]=Array.isArray(out[key])?[...out[key],v]:[out[key],v];else out[key]=v;}return out;};
  const queryStringify=(value,separator='&',equal='=',options={})=>{const encode=options.encodeURIComponent||encodeURIComponent;return Object.entries(value||{}).flatMap(([key,v])=>(Array.isArray(v)?v:[v]).map(item=>encode(key)+equal+encode(['string','number','boolean','bigint'].includes(typeof item)?String(item):''))).join(separator);};
  const timerPromise=(ms=0,value,options={})=>new Promise((resolve,reject)=>{let id;const abort=()=>{clearTimeout(id);options.signal?.removeEventListener('abort',abort);reject(nodeError('The operation was aborted','ABORT_ERR'));};if(options.signal?.aborted){abort();return;}id=setTimeout(()=>{options.signal?.removeEventListener('abort',abort);resolve(value);},ms);options.signal?.addEventListener('abort',abort);});
  globalThis.setImmediate=(fn,...args)=>setTimeout(fn,0,...args);globalThis.clearImmediate=clearTimeout;globalThis.queueMicrotask=fn=>defer(fn);
  globalThis.process=Object.freeze({...globalThis.process,nextTick:(fn,...args)=>defer(()=>fn(...args))});
  const nodeModules={
    http:makeHttp('http:'),https:makeHttp('https:'),
    events:Object.assign(EventEmitter,{EventEmitter,once:eventOnce,on:eventOn,getEventListeners:(e,n)=>e.listeners(n),listenerCount:(e,n)=>e.listenerCount(n)}),
    stream:Object.assign(Stream,{Stream,Readable,Writable,Duplex,Transform,PassThrough,pipeline,finished:streamFinished}),'stream/promises':streamPromises,
    util:{promisify,callbackify:fn=>function(...args){const callback=args.pop();Promise.resolve().then(()=>fn.apply(this,args)).then(value=>callback(null,value),error=>callback(error));},inherits:(child,parent)=>{child.super_=parent;Object.setPrototypeOf(child.prototype,parent.prototype);},format,inspect:value=>{try{return typeof value==='string'?value:JSON.stringify(value);}catch{return '[Circular]';}},types:{isUint8Array:v=>v instanceof Uint8Array,isTypedArray:ArrayBuffer.isView,isAnyArrayBuffer:v=>v instanceof ArrayBuffer,isPromise:v=>v instanceof Promise},TextEncoder:globalThis.TextEncoder,TextDecoder:globalThis.TextDecoder},
    querystring:{parse:queryParse,decode:queryParse,stringify:queryStringify,encode:queryStringify,escape:encodeURIComponent,unescape:decodeURIComponent},string_decoder:{StringDecoder},
    timers:{setTimeout,clearTimeout,setInterval,clearInterval,setImmediate,clearImmediate},'timers/promises':{setTimeout:timerPromise,setImmediate:(value,options)=>timerPromise(0,value,options)},process:globalThis.process,
  };
''';
