// Authenticated browser ZIP export/preview/confirmation using isolated fixtures.
import assert from "node:assert/strict";
import {mkdtemp, readFile, mkdir, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join, resolve} from "node:path";
import {spawn} from "node:child_process";
import {createRequire} from "node:module";
const require=createRequire(import.meta.url), {chromium}=require(process.env.QQM_PLAYWRIGHT||"playwright");
const data=await mkdtemp(join(tmpdir(),"qqm-server-browser-migration-")), shots=resolve("build/server-previews");
await mkdir(shots,{recursive:true});
const child=spawn(process.env.QQM_DART||"dart",["run","tool/server_preview.dart",data],{cwd:process.cwd(),stdio:["pipe","pipe","pipe"],windowsHide:true});
let browser;
try {
  const origin=await new Promise((resolve,reject)=>{
    let output="";const timer=setTimeout(()=>reject(Error("Preview start timeout")),45000);
    child.stdout.on("data",chunk=>{output+=chunk;const found=/QQM_PREVIEW_URI=(http:\/\/\S+)/.exec(output);if(found){clearTimeout(timer);resolve(found[1]);}});
    child.stderr.on("data",()=>{});child.on("exit",code=>{clearTimeout(timer);reject(Error("Preview exited "+code));});
  });
  browser=await chromium.launch({headless:true,...(process.env.QQM_BROWSER_EXECUTABLE?{executablePath:process.env.QQM_BROWSER_EXECUTABLE}:{})});
  const page=await browser.newPage({viewport:{width:1360,height:900},acceptDownloads:true}), errors=[];
  page.on("pageerror",e=>errors.push(e.message));
  await page.route("**/*",r=>r.request().url().startsWith(origin)?r.continue():r.abort());
  const token=(await readFile(join(data,"setup-token.txt"),"utf8")).trim();
  const setup=await page.request.post(origin+"/api/setup",{headers:{"X-QQM-Request":"1"},data:{token,password:"local-migration-test-password",confirmation:"local-migration-test-password",entrance:"offline-migration-entrance"}});
  assert.equal(setup.status(),200);
  await page.goto(origin+"/offline-migration-entrance/",{waitUntil:"networkidle"});
  await page.locator('#app').waitFor({state:'visible'});
  await page.locator('[data-page="settings"]').click();
  await page.locator('[data-migration]').click();
  const dialog=page.locator('.migration-dialog');await dialog.getByRole('heading',{name:'完整数据迁移',exact:true}).waitFor();
  const downloaded=page.waitForEvent('download');await dialog.getByRole('button',{name:'导出完整 ZIP',exact:true}).click();
  const file=await downloaded;assert.match(file.suggestedFilename(),/^qqbotmanager-backup-v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?-build\d+-\d+\.zip$/);
  const destination=join(data,'test-backup.zip');await file.saveAs(destination);
  assert.ok((await readFile(destination)).length>100);
  await dialog.getByText('完整ZIP已下载。',{exact:true}).waitFor();
  await dialog.locator('input[type=file]').setInputFiles({name:'bad.zip',mimeType:'application/zip',buffer:Buffer.from('not a backup')});
  await dialog.locator('[role=alert]').filter({hasText:/ZIP|备份/}).waitFor();
  assert.equal(await dialog.getByRole('button',{name:'备份当前数据并恢复',exact:true}).count(),0);
  await dialog.locator('input[type=file]').setInputFiles(destination);
  await dialog.getByRole('button',{name:'备份当前数据并恢复',exact:true}).waitFor();
  assert.match(await dialog.innerText(),/聊天消息 106 条/);
  await page.screenshot({path:join(shots,'data-migration-desktop.png')});
  await page.setViewportSize({width:390,height:844});
  assert.ok(await dialog.evaluate(n=>n.scrollWidth<=n.clientWidth+1));
  await page.screenshot({path:join(shots,'data-migration-mobile.png')});
  await dialog.getByRole('button',{name:'备份当前数据并恢复',exact:true}).click();
  await dialog.getByRole('heading',{name:'重启后恢复完整数据',exact:true}).waitFor();
  assert.equal(await page.locator('html').getAttribute('data-migration-pending'),'true');
  const blocked=await page.evaluate(async()=>{const r=await fetch('./api/config',{method:'POST',headers:{'X-QQM-Request':'1','Content-Type':'application/json'},body:'{}'});return r.status;});
  assert.equal(blocked,409);
  assert.deepEqual(errors,[]);
  console.log('PASS: 浏览器完整ZIP真实下载、损坏ZIP拒绝、导入预览与确认、待重启屏障、手机/桌面布局；全部使用合成离线资料。');
} finally {
  await browser?.close();child.stdin.end('stop\n');
  await new Promise(resolve=>{if(child.exitCode!==null)return resolve();child.once('exit',resolve);setTimeout(()=>{child.kill();resolve();},5000).unref();});
  assert.ok(data.startsWith(join(tmpdir(),'qqm-server-browser-migration-')));
  await rm(data,{recursive:true,force:true,maxRetries:5,retryDelay:200});
}
