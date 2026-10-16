// Optional UI QA against tests/preview.php, never against the live admin site.
import {createRequire} from 'node:module';
import {mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.QQM_PLAYWRIGHT||'playwright');
export async function runBrowserQA(origin='http://127.0.0.1:8987',mockOAuth=false){
const output=resolve('build/management-previews');await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.QQM_CHROME?{executablePath:process.env.QQM_CHROME}:{})});
const page=await browser.newPage({viewport:{width:1280,height:900},deviceScaleFactor:1});
const errors=[];page.on('pageerror',error=>errors.push(error.message));
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
  assert.ok(await page.locator('script[src="/assets/admin-releases.js"]').count());
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
  assert.equal(await page.locator('[data-view="devices"],#device-rows,#stat-total').count(),0);
  for(const view of ['releases','settings']) {
    await page.locator(`.sidebar [data-view="${view}"]`).click();
    assert.ok(await page.locator(`[data-section="${view}"]`).isVisible());
  }
  await page.getByRole('button',{name:'立即检测'}).click();await page.waitForFunction(()=>document.querySelector('#proxy-result').textContent.includes('127.0.0.1'));
  assert.ok((await page.locator('#proxy-summary').innerText()).includes('没有收到回源密钥'));
  await page.screenshot({path:resolve(output,'proxy-diagnostics-1280.png'),fullPage:true});
  for(const width of [390,320]){
    await page.setViewportSize({width,height:900});
    for(const view of ['releases','settings']){
      await page.locator(`.mobile-admin-nav [data-view="${view}"]`).click();
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Admin ${view} overflow at ${width}`);
    }
    await page.screenshot({path:resolve(output,`proxy-diagnostics-${width}.png`),fullPage:true});
    await page.locator('.mobile-admin-nav [data-view="releases"]').click();
    await page.screenshot({path:resolve(output,`admin-${width}.png`),fullPage:true});
  }
  await page.getByRole('button',{name:'退出登录'}).click();await page.locator('#login:not(.hidden)').waitFor();
  assert.deepEqual(errors,[]);console.log('Browser QA passed: desktop/mobile homepage, mocked OAuth, retired device UI, proxy diagnostics and logout.');
}finally{await browser.close();}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await runBrowserQA();
