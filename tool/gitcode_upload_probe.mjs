// Owner-dispatched, isolated upload diagnostic. Never writes a real version,
// updater manifest, bot configuration or secret. Upload descriptors stay in RAM.
import {spawn} from 'node:child_process';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {mkdtemp,writeFile,rm,appendFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {trustedMirrorUrl,gitCodeRepository} from './gitcode_release.mjs';

const check=(ok,message)=>{if(!ok)throw Error(message);};
const repo='XingChenwa/qqm_project',base=`https://api.gitcode.com/api/v5/repos/${gitCodeRepository}`;
const token=process.env.GITCODE_TOKEN;
const run=process.env.GITHUB_RUN_ID,attempt=process.env.GITHUB_RUN_ATTEMPT;
check(process.env.GITHUB_REPOSITORY===repo&&/^\d+$/.test(run??'')&&/^\d+$/.test(attempt??''),'Only the owner Actions workflow may run this probe');
check(token,'GITCODE_TOKEN is required');
const tag=`qqm-upload-test-${run}-${attempt}`,marker=`Temporary QQM upload probe ${randomUUID()}`;
const fixtureNames=new Set(),results=[];
const sha=b=>createHash('sha256').update(b).digest('hex');
let created=false,identity,tagIdentity,cleanupRelease=false,cleanupTag=false;
async function api(path,{method='GET',body,missing=false}={}){
  check(/^\/(?:releases|tags)(?:\/|\?|$)/.test(path),'Probe API path is out of scope');
  const url=new URL(base+path);url.searchParams.set('access_token',token);
  let response;try{response=await fetch(url,{method,headers:{'Content-Type':'application/json'},
    ...(body?{body:JSON.stringify(body)}:{}),redirect:'error',signal:AbortSignal.timeout(20000)});}
  catch{throw Error('Probe API transport failed');}
  const bytes=await response.arrayBuffer();check(bytes.byteLength<=1048576,'Probe API response too large');
  const text=Buffer.from(bytes).toString();let data;try{data=text?JSON.parse(text):null;}catch{throw Error(`Probe API HTTP ${response.status}, invalid JSON`);}
  if(missing&&(response.status===404||response.status===400&&/未找到 release|不存在|not found/i.test(data?.error_message??'')))return null;
  check(response.ok,`Probe API ${method} HTTP ${response.status}`);return data;
}
const recordIdentity=r=>JSON.stringify([r.tag_name,r.target_commitish,r.created_at]);
const tagRecordIdentity=r=>JSON.stringify([r.name,r.commit?.sha]);
async function findProbeTag(){
  for(let page=1;page<=10;page++){
    const list=await api(`/tags?per_page=100&page=${page}`);check(Array.isArray(list),'Unexpected tag list');
    const match=list.find(record=>record.name===tag);if(match)return match;
    if(list.length<100)return null;
  }throw Error('Too many tags to establish diagnostic ownership');
}
const quote=value=>{check(typeof value==='string'&&!/[\u0000-\u001f\u007f]/.test(value),'Invalid curl configuration');return '"'+value.replaceAll('\\','\\\\').replaceAll('"','\\"')+'"';};
function childRun(executable,args,input,{phaseLog=false}={}){
  return new Promise((resolve,reject)=>{
    const child=spawn(executable,args,{stdio:['pipe','pipe','pipe'],windowsHide:true});
    let output='',error='';
    child.stdout.on('data',b=>{output+=b;if(output.length>8192)child.kill();});
    child.stderr.on('data',b=>{error+=b;if(error.length>8192)child.kill();});
    child.on('error',()=>reject(Error('Probe transport executable unavailable')));
    child.stdin.on('error',()=>{});
    child.on('exit',code=>{
      if(phaseLog)for(const line of output.split(/\r?\n/))if(/^Upload phase=[a-z_]+ sent=\d+ elapsed_ms=\d+$/.test(line))console.log(line);
      resolve({code,output,error});
    });child.stdin.end(input);
  });
}
async function putPython(descriptor,content,timeout){
  const input=Buffer.concat([Buffer.from(JSON.stringify({...descriptor,size:content.length,timeout_seconds:timeout,diagnostic:true})+'\n'),content]);
  const result=await childRun(process.platform==='win32'?'python':'python3',[fileURLToPath(new URL('./gitcode_upload.py',import.meta.url))],input,{phaseLog:true});
  if(result.code!==0){const safe=result.error.match(/Upload (?:HTTP \d+|transport: [A-Za-z]+(?: phase=[a-z_]+ sent=\d+)?)/)?.[0]??'process failed';throw Error(`Python ${safe}`);}
}
async function putCurl(descriptor,content,timeout){
  const directory=await mkdtemp(join(tmpdir(),'qqm-upload-probe-'));
  try{
    const file=join(directory,'payload.bin');await writeFile(file,content,{mode:0o600});
    const config=[`url = ${quote(descriptor.url)}`,'request = "PUT"','http1.1','ipv4',
      `upload-file = ${quote(file)}`,'header = "Expect:"',`header = "Content-Length: ${content.length}"`,
      ...Object.entries(descriptor.headers).map(([key,value])=>`header = ${quote(`${key}: ${value}`)}`),
      'connect-timeout = 15',`max-time = ${timeout}`,'speed-limit = 1024','speed-time = 25',
      'silent','show-error',`output = ${quote(process.platform==='win32'?'NUL':'/dev/null')}`,
      'write-out = "%{http_code} %{size_upload} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}"'].join('\n')+'\n';
    const result=await childRun(process.platform==='win32'?'curl.exe':'curl',['--disable','--config','-'],config);
    const metrics=result.output.trim();check(/^\d{3}(?: [0-9.]+){5}$/.test(metrics),'Curl diagnostic format invalid');
    console.log(`Curl exit=${result.code} http/upload_bytes/connect/tls/first_response/total=${metrics}`);
    check(result.code===0&&/^2\d\d /.test(metrics),`Curl upload failed, exit=${result.code}, HTTP=${metrics.slice(0,3)}`);
  }finally{check(directory.startsWith(join(tmpdir(),'qqm-upload-probe-')),'Invalid temporary directory');await rm(directory,{recursive:true,force:true});}
}
async function publicFile(name,maximum){
  let url=new URL(`${base}/releases/${tag}/attach_files/${name}/download`);
  for(let hop=0;hop<6;hop++){
    check(trustedMirrorUrl(url),'Untrusted probe download');
    const response=await fetch(url,{redirect:'manual',signal:AbortSignal.timeout(90000)});
    if([301,302,303,307,308].includes(response.status)){
      const location=response.headers.get('location');await response.body?.cancel();check(location,'Missing probe redirect');url=new URL(location,url);continue;
    }
    check(response.ok,`Probe read-back HTTP ${response.status}`);
    const chunks=[];let size=0;for await(const chunk of response.body){size+=chunk.length;check(size<=maximum,'Probe read-back too large');chunks.push(chunk);}
    return Buffer.concat(chunks);
  }throw Error('Too many probe redirects');
}
async function probe(transport,size){
  const name=`probe-${transport}-${size}.bin`;fixtureNames.add(name);
  const content=randomBytes(size),start=Date.now();
  try{
    const descriptor=await api(`/releases/${tag}/upload_url?file_name=${name}`);
    check(trustedMirrorUrl(descriptor.url,{upload:true}),'Untrusted probe upload');
    check(descriptor.headers&&Object.entries(descriptor.headers).every(([key,value])=>
      /^(?:x-obs-[a-z0-9-]+|content-type)$/i.test(key)&&typeof value==='string'&&!/[\r\n]/.test(value)),'Untrusted probe headers');
    console.log(`Probe ${transport} bytes=${size} upload_host=${new URL(descriptor.url).hostname} header_names=${Object.keys(descriptor.headers).sort().join(',')}`);
    await (transport==='python'?putPython:putCurl)(descriptor,content,size<=131072?35:180);
    const remote=await publicFile(name,size);check(remote.length===size&&sha(remote)===sha(content),'Probe read-back hash mismatch');
    results.push({transport,size,ok:true,ms:Date.now()-start});console.log(`PASS probe ${transport} ${size} bytes, SHA-256 read-back matches`);return true;
  }catch(error){
    const message=(error instanceof Error?error.message:'probe failed').replaceAll(token,'[redacted]').replace(/https?:\/\/\S+/g,'[url]').split('\n')[0];
    results.push({transport,size,ok:false,ms:Date.now()-start,error:message});console.log(`FAIL probe ${transport} ${size} bytes: ${message}`);return false;
  }
}
let production;
const productionSummary=r=>JSON.stringify([r.tag_name,r.name,r.body,r.release_status,r.prerelease,r.target_commitish,r.created_at,
  r.assets.filter(a=>a.type==='attach').map(a=>a.name).sort()]);
try{
  production=productionSummary(await api('/releases/tags/v1.3.9'));
  check(!await api(`/releases/tags/${tag}`,{missing:true}),'Diagnostic release already exists; refusing to reuse');
  check(!await findProbeTag(),'Diagnostic tag already exists; refusing to reuse');
  const release=await api('/releases',{method:'POST',body:{tag_name:tag,name:'临时上传诊断测试（不是客户端版本）',
    body:marker+'\n\n仅用于维护者验证 GitCode 上传链路，不含更新清单，测试结束后清理。',release_status:'pre'}});
  check(release.tag_name===tag&&release.body?.startsWith(marker),'Unexpected diagnostic release');created=true;identity=recordIdentity(release);
  const ownTag=await findProbeTag();check(ownTag?.name===tag&&ownTag.commit?.sha,'Diagnostic tag identity unavailable');tagIdentity=tagRecordIdentity(ownTag);
  console.log('Created isolated diagnostic tag '+tag);
  const python=await probe('python',131072),curl=await probe('curl',131072);
  const maxMB=Number(process.env.PROBE_MB??16);check([16,80].includes(maxMB),'Unsupported probe size');
  if(python)await probe('python',maxMB*1024*1024);
  if(curl)await probe('curl',maxMB*1024*1024);
  check(results.some(r=>r.size===maxMB*1024*1024&&r.ok),'No large-file transport passed');
}catch(error){console.error((error instanceof Error?error.message:'Probe failed').replaceAll(token,'[redacted]').replace(/https?:\/\/\S+/g,'[url]').split('\n')[0]);process.exitCode=1;}
finally{
  if(created)try{
    const current=await api(`/releases/tags/${tag}`);
    check(current.tag_name===tag&&recordIdentity(current)===identity&&current.body?.startsWith(marker)&&
      current.assets.every(a=>a.type!=='attach'||fixtureNames.has(a.name)),'Diagnostic resource was edited; refusing cleanup');
    await api(`/releases/${tag}`,{method:'DELETE'});
    check(!await api(`/releases/tags/${tag}`,{missing:true}),'Diagnostic release still exists');cleanupRelease=true;
    const tagRecord=await findProbeTag();
    if(tagRecord){check(tagIdentity&&tagRecordIdentity(tagRecord)===tagIdentity,'Diagnostic tag changed; refusing cleanup');await api(`/tags/${tag}`,{method:'DELETE'});}
    check(!await findProbeTag(),'Diagnostic tag still exists');
    cleanupTag=true;
  }catch(error){console.log('Diagnostic cleanup incomplete: '+(error instanceof Error?error.message:'unknown'));process.exitCode=1;}
  if(production)try{check(productionSummary(await api('/releases/tags/v1.3.9'))===production,'Production release changed during probe');console.log('PASS production v1.3.9 metadata and file list unchanged');}catch{console.log('Production state could not be confirmed');process.exitCode=1;}
  const summary={diagnosticTag:tag,results,cleanupRelease,cleanupTag};console.log(JSON.stringify(summary));
  if(process.env.GITHUB_STEP_SUMMARY)await appendFile(process.env.GITHUB_STEP_SUMMARY,'## GitCode upload diagnostic\n\n```json\n'+JSON.stringify(summary,null,2)+'\n```\n');
}
