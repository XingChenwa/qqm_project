// Optional UI QA against tests/preview.php, never against the live admin site.
import {createRequire} from 'node:module';
import {mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.QQM_PLAYWRIGHT||'playwright');
export async function runBrowserQA(origin='http://127.0.0.1:8987',mockOAuth=false){
const output=resolve('build/management-previews');await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.QQM_CHROME?{executablePath:process.env.QQM_CHROME}:{})});
const page=await browser.newPage({viewport:{width:1280,height:900},deviceScaleFactor:1});
const errors=[];page.on('pageerror',error=>errors.push(error.message));
let deviceToken='';
try{
  for(const width of [1280,390,320]){
    await page.setViewportSize({width,height:900});await page.goto(origin,{waitUntil:'networkidle'});
    await page.getByRole('heading',{name:'选择你的平台'}).waitFor();
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Homepage horizontal overflow at ${width}`);
    assert.equal(await page.locator('.download-link.disabled').count(),4);
    assert.equal(await page.locator('a[href="/admin"]').count(),0);
    assert.equal(await page.locator('.privacy-banner').count(),0);
    assert.ok(await page.locator('#macos-install').isVisible());
    await page.screenshot({path:resolve(output,`home-${width}.png`),fullPage:true});
  }
  await page.setViewportSize({width:1280,height:900});await page.goto(origin+'/admin',{waitUntil:'networkidle'});
  assert.equal(await page.locator('input[type=password]').count(),0);
  assert.ok(await page.locator('#login').innerText().then(text=>!text.includes('2377130783@qq.com')));
  assert.ok(await page.locator('script[src="/assets/admin-v1.3.2.js"]').count());
  for(const width of [1280,390,320]){
    await page.setViewportSize({width,height:900});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    await page.screenshot({path:resolve(output,`login-${width}.png`),fullPage:true});
  }
  if(!mockOAuth){assert.ok(await page.locator('#oauth-login').isDisabled());console.log('Preview QA passed: responsive public pages, OAuth-only login and safe unconfigured state.');return;}
  await page.route('https://account.uuze.cn/oauth/authorize?**',async route=>{
    const authorization=new URL(route.request().url());assert.equal(authorization.searchParams.get('response_type'),'code');assert.equal(authorization.searchParams.has('client_secret'),false);
    const callback=new URL(authorization.searchParams.get('redirect_uri'));assert.equal(callback.origin,origin);
    callback.searchParams.set('state',authorization.searchParams.get('state'));callback.searchParams.set('code','test-admin-code');
    await route.fulfill({status:302,headers:{location:callback.href},body:''});
  });
  await page.getByRole('button',{name:'使用杂鱼账号登录'}).click();await page.locator('#console:not(.hidden)').waitFor();
  await page.setViewportSize({width:1280,height:900});
  await page.waitForFunction(()=>document.querySelector('#stat-total').textContent==='0');
  assert.ok((await page.locator('.sidebar-foot').innerText()).includes('botmanager.uuze.cn'));
  await page.screenshot({path:resolve(output,'admin-1280.png'),fullPage:true});
  const deviceName='测试电脑 <img src=x onerror=alert(1)>';
  const registration=await page.request.post(origin+'/api/v1/telemetry/register',{data:{installation_id:randomUUID(),consent_version:'2',platform:'windows',version:'1.3.1',build:12,device_name:deviceName,device_model:'测试型号',system_version:'Windows 11 测试系统',system_arch:'x64'}});
  assert.equal(registration.status(),201);deviceToken=(await registration.json()).token;
  await page.getByRole('button',{name:'刷新',exact:false}).click();
  await page.waitForFunction(()=>document.querySelector('#stat-total').textContent==='1');
  for(const view of ['releases','devices','settings']){
    await page.locator(`.sidebar [data-view="${view}"]`).click();
    assert.ok(await page.locator(`[data-section="${view}"]`).isVisible());
    if(view==='devices'){
      assert.ok((await page.locator('#device-rows').innerText()).includes(deviceName));
      assert.ok((await page.locator('#device-rows').innerText()).includes('Windows 11 测试系统'));
      assert.equal(await page.locator('#device-rows img').count(),0);
      assert.equal(await page.locator('#device-rows tr').first().locator('td').count(),11);
      assert.equal(await page.locator('#device-rows tr').first().locator('td').nth(1).innerText(),deviceName);
      assert.equal(await page.locator('#device-rows tr').first().locator('td').nth(3).innerText(),'Windows');
      assert.equal(await page.locator('#device-rows tr').first().locator('td').nth(6).innerText(),'1.3.1 (12)');
      await page.screenshot({path:resolve(output,'devices-1280.png'),fullPage:true});
    }
  }
  await page.getByRole('button',{name:'立即检测'}).click();await page.waitForFunction(()=>document.querySelector('#proxy-result').textContent.includes('127.0.0.1'));
  assert.ok((await page.locator('#proxy-summary').innerText()).includes('没有收到回源密钥'));
  await page.screenshot({path:resolve(output,'proxy-diagnostics-1280.png'),fullPage:true});
  for(const width of [390,320]){
    await page.setViewportSize({width,height:900});
    for(const view of ['overview','releases','devices','settings']){
      await page.locator(`.mobile-admin-nav [data-view="${view}"]`).click();
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Admin ${view} overflow at ${width}`);
      if(view==='devices')await page.screenshot({path:resolve(output,`devices-${width}.png`),fullPage:true});
    }
    await page.screenshot({path:resolve(output,`proxy-diagnostics-${width}.png`),fullPage:true});
    await page.locator('.mobile-admin-nav [data-view="overview"]').click();
    await page.screenshot({path:resolve(output,`admin-${width}.png`),fullPage:true});
  }
  await page.getByRole('button',{name:'退出登录'}).click();await page.locator('#login:not(.hidden)').waitFor();
  assert.deepEqual(errors,[]);console.log('Browser QA passed: desktop/mobile homepage, mocked OAuth, empty and populated device tables, safe device-name text rendering, proxy diagnostics and logout.');
}finally{if(deviceToken)await page.request.delete(origin+'/api/v1/telemetry/installation',{headers:{authorization:'Bearer '+deviceToken}}).catch(()=>{});await browser.close();}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await runBrowserQA();
