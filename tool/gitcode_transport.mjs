// Presigned PUT only: no publisher token in argv, temporary config or logs.
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

export class GitCodeUploadError extends Error {
  constructor(message, details={}) {super(message);Object.assign(this,details);}
}
const requireThat=(ok,message)=>{if(!ok)throw new GitCodeUploadError(message,{retryable:false});};
export function validateUploadDescriptor(upload){
  let url;try{url=new URL(upload?.url);}catch{throw new GitCodeUploadError('GitCode 上传地址不可信');}
  requireThat(url.protocol==='https:'&&url.hostname==='file.gitcode.com'&&!url.username&&!url.password&&!url.port&&!url.hash&&
    !/[\u0000-\u0020\u007f]/.test(upload.url),'GitCode 上传地址不可信');
  requireThat(upload.headers&&Object.entries(upload.headers).length>0&&Object.entries(upload.headers).every(([key,value])=>
    /^(?:x-obs-[a-z0-9-]+|content-type)$/i.test(key)&&typeof value==='string'&&!/[\u0000-\u001f\u007f]/.test(value)),
    'GitCode 上传请求头不可信');
}
const quote=value=>'"'+value.replaceAll('\\','\\\\').replaceAll('"','\\"')+'"';
export function curlUploadConfiguration(upload,file,size,timeoutSeconds=300){
  validateUploadDescriptor(upload);
  requireThat(typeof file==='string'&&!/[\u0000-\u001f\u007f]/.test(file)&&Number.isSafeInteger(size)&&size>0&&size<=1073741824,
    'GitCode 上传文件无效');
  requireThat(Number.isInteger(timeoutSeconds)&&timeoutSeconds>=15&&timeoutSeconds<=900,'GitCode 上传超时配置无效');
  return [`url = ${quote(upload.url)}`,'request = "PUT"','proto = "=https"','http1.1','ipv4',
    `upload-file = ${quote(file)}`,'header = "Expect:"',`header = "Content-Length: ${size}"`,
    ...Object.entries(upload.headers).map(([key,value])=>`header = ${quote(`${key}: ${value}`)}`),
    'connect-timeout = 15',`max-time = ${timeoutSeconds}`,'speed-limit = 1024','speed-time = 30',
    'silent','show-error',`output = ${quote(process.platform==='win32'?'NUL':'/dev/null')}`,
    'write-out = "%{http_code} %{size_upload} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}"'].join('\n')+'\n';
}
function executeCurl({config,timeoutSeconds}){
  return new Promise((resolve,reject)=>{
    const env={...process.env};
    for(const key of Object.keys(env))if(/(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|SSLKEYLOGFILE)/i.test(key))delete env[key];
    const child=spawn(process.platform==='win32'?'curl.exe':'curl',['--disable','--config','-'],
      {stdio:['pipe','pipe','pipe'],env,windowsHide:true});
    let output='';const timer=setTimeout(()=>child.kill(),(timeoutSeconds+30)*1000);
    child.stdout.on('data',chunk=>{output+=chunk;if(output.length>2048)child.kill();});
    // curl may include a presigned URL in an error. Never log/return stderr.
    child.stderr.resume();child.stdin.on('error',()=>{});
    child.on('error',()=>{clearTimeout(timer);reject(new GitCodeUploadError('无法启动 cURL 上传工具',{retryable:false}));});
    child.on('close',exitCode=>{clearTimeout(timer);resolve({exitCode,output});});
    child.stdin.end(config);
  });
}
export async function uploadGitCodeFile(upload,content,{onProgress=()=>{},execute=executeCurl,timeoutSeconds=300}={}){
  validateUploadDescriptor(upload);
  requireThat(Buffer.isBuffer(content)&&content.length>0&&content.length<=1073741824,'GitCode 上传文件无效');
  const directory=await mkdtemp(join(tmpdir(),'qqm-gitcode-put-'));
  try{
    const file=join(directory,'payload.bin');await writeFile(file,content,{mode:0o600});
    const config=curlUploadConfiguration(upload,file,content.length,timeoutSeconds);
    const {exitCode,output}=await execute({config,timeoutSeconds});
    requireThat(typeof output==='string'&&/^\d{3}(?: [0-9.]+){5}$/.test(output.trim()),'GitCode 上传工具未返回有效诊断');
    const [httpStatus,bytesSent,connect,tls,firstResponse,total]=output.trim().split(' ').map(Number);
    requireThat([httpStatus,bytesSent,connect,tls,firstResponse,total].every(Number.isFinite),'GitCode 上传诊断无效');
    const stage=!connect?'connect':!tls?'tls':bytesSent<content.length?'send':!firstResponse?'response_wait':'response';
    onProgress(`GitCode 上传：HTTP ${httpStatus}，已发送 ${bytesSent}/${content.length} 字节，阶段 ${stage}，用时 ${total} 秒`);
    if(exitCode!==0||httpStatus<200||httpStatus>=300||bytesSent!==content.length){
      const retryable=[5,6,7,18,28,35,52,55,56].includes(exitCode)||[408,425,429,500,502,503,504].includes(httpStatus);
      throw new GitCodeUploadError(`GitCode 上传失败（cURL ${Number.isInteger(exitCode)?exitCode:'中断'}，HTTP ${httpStatus}，阶段 ${stage}，已发送 ${bytesSent} 字节）`,
        {retryable,httpStatus,bytesSent,stage,exitCode});
    }
  }finally{
    requireThat(directory.startsWith(join(tmpdir(),'qqm-gitcode-put-')),'临时上传目录无效');
    await rm(directory,{recursive:true,force:true});
  }
}
