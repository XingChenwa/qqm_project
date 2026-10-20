import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access,stat} from 'node:fs/promises';
import {uploadGitCodeFile,curlUploadConfiguration,validateUploadDescriptor} from '../gitcode_transport.mjs';

const upload={url:'https://file.gitcode.com/fixture?signature=private-fixture',
  headers:{'Content-Type':'application/octet-stream','x-obs-callback':'private-callback-fixture'}};
const payload=Buffer.from('offline upload fixture');
const uploadedPath=config=>JSON.parse('"'+/^upload-file = "(.*)"$/m.exec(config)[1]+'"');

test('配置强制 HTTPS、IPv4、HTTP/1.1、确定长度，不跟随重定向或启用调试输出',()=>{
  const config=curlUploadConfiguration(upload,'C:\\temporary dir\\payload.bin',payload.length);
  for(const text of ['proto = "=https"','http1.1','ipv4','header = "Expect:"',`Content-Length: ${payload.length}`,
    'connect-timeout = 15','speed-limit = 1024','speed-time = 30'])assert.ok(config.includes(text));
  assert.doesNotMatch(config,/\n(?:location|insecure|verbose|trace|netrc|user)\b/);
  assert.equal(uploadedPath(config),'C:\\temporary dir\\payload.bin');
});

for(const bad of [
  {...upload,url:'https://file.gitcode.com/path\nheader=evil'},
  {...upload,url:'http://file.gitcode.com/path'},
  {...upload,url:'https://other.invalid/path'},
  {...upload,url:'https://user:secret@file.gitcode.com/path'},
  {...upload,headers:{Authorization:'Bearer fixture'}},
  {...upload,headers:{'Content-Type':'one\r\nx-extra: two'}},
])test('拒绝不可信上传配置，不执行子进程：'+JSON.stringify({url:bad.url,headerNames:Object.keys(bad.headers)}),async()=>{
  let executions=0;
  assert.throws(()=>validateUploadDescriptor(bad));
  await assert.rejects(uploadGitCodeFile(bad,payload,{execute:async()=>{executions++;}}));
  assert.equal(executions,0);
});

test('上传内容使用私有临时文件，签名只经 stdin 配置，成功后清理且日志脱敏',async()=>{
  const logs=[];let file;
  await uploadGitCodeFile(upload,payload,{onProgress:text=>logs.push(text),execute:async({config})=>{
    file=uploadedPath(config);assert.deepEqual(await readFile(file),payload);
    if(process.platform!=='win32')assert.equal((await stat(file)).mode&0o777,0o600);
    return {exitCode:0,output:`200 ${payload.length} 0.1 0.2 0.5 0.8`};
  }});
  await assert.rejects(access(file),{code:'ENOENT'});
  assert.match(logs.join('\n'),/HTTP 200/);
  assert.doesNotMatch(logs.join('\n'),/signature|private-fixture|private-callback|https:/);
});

for(const [exitCode,http,bytes,stage,retryable] of [
  [28,0,payload.length,'response_wait',true],
  [55,0,3,'send',true],
  [0,503,payload.length,'response',true],
  [0,403,payload.length,'response',false],
])test(`错误包含安全阶段诊断，重试分类明确：curl=${exitCode}, HTTP=${http}`,async()=>{
  let file;const logs=[];
  await assert.rejects(uploadGitCodeFile(upload,payload,{onProgress:line=>logs.push(line),execute:async({config})=>{
    file=uploadedPath(config);return {exitCode,output:`${String(http).padStart(3,'0')} ${bytes} 0.1 0.2 ${http?'0.3':'0'} 30`};
  }}),error=>{
    assert.equal(error.retryable,retryable);assert.equal(error.stage,stage);
    assert.doesNotMatch(error.message,/signature|private-fixture|https:/);return true;
  });
  await assert.rejects(access(file),{code:'ENOENT'});
});

test('无法执行或输出异常时也清理临时文件，不把原始输出带入错误',async()=>{
  let file;
  await assert.rejects(uploadGitCodeFile(upload,payload,{execute:async({config})=>{
    file=uploadedPath(config);return {exitCode:1,output:'https://file.gitcode.com/private?signature=not-to-log'};
  }}),error=>{assert.doesNotMatch(error.message,/signature|not-to-log/);return true;});
  await assert.rejects(access(file),{code:'ENOENT'});
});
