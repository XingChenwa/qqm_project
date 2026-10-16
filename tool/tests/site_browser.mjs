// Synthetic local-only website QA. Never launches the manager or contacts QQ.
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import {assetDefinitions, repository, sha256} from '../github_release_core.mjs';
const require = createRequire(import.meta.url);
const {chromium} = require(process.env.QQM_PLAYWRIGHT || 'playwright');
assert.ok(process.env.WEBSITE_DIRECTORY, '请用 WEBSITE_DIRECTORY 指定 docs 分支 checkout');
const site = resolve(process.env.WEBSITE_DIRECTORY);
const screenshots = resolve('build/github-pages-previews');
await mkdir(screenshots,{recursive:true});
let mode = 'empty';
const data = {schema:2,repository,tag:'v1.3.7',version:'1.3.7',build:18,published_at:Math.floor(Date.now()/1000),
  releases:assetDefinitions('1.3.7',18).map(a => ({platform:a.platform,arch:a.arch,format:a.format,package_id:'cn.uuze.botmanager',version:'1.3.7',build:18,size:42,sha256:sha256('fixture'),
    url:`https://github.com/${repository}/releases/download/v1.3.7/${a.name}`,notes:'本地界面测试，不是真实发布。<img src=x onerror=alert(1)>\n多行说明保持文本。'}))};
const server = createServer(async (request,response) => {
  try {
    const url = new URL(request.url,'http://127.0.0.1');
    if (url.pathname === '/qqm_project/releases.json') {
      const payload = structuredClone(data);
      if (mode === 'invalid') payload.releases[0].url = 'https://evil.invalid/setup.exe';
      response.setHeader('content-type','application/json');
      response.end(JSON.stringify(mode === 'empty' ? {releases:[]} : payload)); return;
    }
    const relative = decodeURIComponent(url.pathname).replace(/^\/qqm_project\//,'');
    const path = resolve(site,relative || 'index.html');
    assert.ok(path.startsWith(site + (process.platform === 'win32' ? '\\' : '/')));
    const bytes = await readFile(path);
    response.setHeader('content-type',({'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png'})[extname(path)] || 'application/octet-stream');
    response.end(bytes);
  } catch {response.statusCode=404;response.end('not found');}
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const origin = `http://127.0.0.1:${server.address().port}/qqm_project/`;
const browser = await chromium.launch({headless:true,...(process.env.QQM_CHROME ? {executablePath:process.env.QQM_CHROME} : {})});
try {
  const page = await browser.newPage();
  await page.emulateMedia({reducedMotion:'reduce'});
  const errors = [], external = [];
  page.on('pageerror',error => errors.push(error.message));
  await page.route('**/*', route => {
    if (route.request().url().startsWith(origin)) return route.continue();
    external.push(route.request().url()); return route.abort();
  });
  for (mode of ['empty','ready','invalid']) {
    for (const width of [1280,390,320]) {
      await page.setViewportSize({width,height:900});
      await page.goto(origin,{waitUntil:'networkidle'});
      await page.getByRole('heading',{name:'选择你的平台'}).waitFor();
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `水平溢出 ${mode}/${width}`);
      assert.equal(await page.locator('.download-link').count(),4);
      assert.ok(await page.locator('.preview-link img').evaluate(image => image.complete && image.naturalWidth === 1920 && image.naturalHeight === 1200));
      assert.ok(await page.getByRole('navigation',{name:'主导航'}).getByRole('link',{name:'开发文档'}).isVisible());
      assert.equal(await page.locator('a[href*="/admin"]').count(),0);
      assert.ok(await page.locator('#star').innerText().then(s => s.includes('如果喜欢这个项目')));
      const links = await page.locator('.download-link').evaluateAll(nodes => nodes.map(a => a.href));
      assert.ok(links.every(url => url.startsWith(`https://github.com/${repository}/releases`)));
      if (mode === 'ready') {
        assert.equal(await page.locator('.download-link.disabled').count(),0);
        assert.equal(await page.locator('.history-item img').count(),0);
        assert.ok((await page.locator('#release-history').innerText()).includes('<img src=x'));
      } else {assert.ok(await page.locator('#release-error').isVisible());}
      if (mode === 'ready' || (mode === 'empty' && width === 390)) await page.screenshot({path:resolve(screenshots,`home-${mode}-${width}.png`),fullPage:true});
      if (mode === 'ready') await page.screenshot({path:resolve(screenshots,`home-top-${width}.png`)});
    }
  }
  mode = 'ready';
  await page.context().grantPermissions(['clipboard-read','clipboard-write'], {origin:new URL(origin).origin});
  for (const width of [1280,390,320]) {
    await page.setViewportSize({width,height:900});
    await page.goto(origin,{waitUntil:'networkidle'});
    const preview = page.locator('[data-image-preview]');
    await preview.click();
    assert.ok(await page.getByRole('dialog').isVisible());
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `大图页面溢出 ${width}`);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('dialog[open]').count(),0);
    assert.ok(await preview.evaluate(node => document.activeElement === node));
    await page.getByRole('navigation',{name:'主导航'}).getByRole('link',{name:'开发文档'}).click();
    await page.getByRole('heading',{level:1,name:'把想法，写成一个插件。'}).waitFor();
    assert.ok(page.url().endsWith('/plugins.html'));
    assert.equal(await page.locator('.docs-article h2').count(),9);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `文档页面溢出 ${width}`);
    assert.ok(await page.locator('.docs-article').innerText().then(value => value.includes('Dart SDK v2') && value.includes('文件管理、数据与测试')));
    if (width < 820) await page.locator('.docs-toc summary').click();
    await page.getByRole('navigation',{name:'文档目录'}).getByRole('link',{name:'6. 用 JavaScript / Python 编写 HTTP 插件'}).click();
    assert.ok(page.url().endsWith('#section-6'));
    const firstExample = page.locator('.docs-article .code-example').first();
    const code = await firstExample.locator('code').textContent();
    assert.equal(JSON.parse(code).id,'my_hello');
    await firstExample.getByRole('button',{name:'复制代码'}).click();
    assert.equal((await page.evaluate(() => navigator.clipboard.readText())).replace(/\r\n/g,'\n'),code);
    await page.evaluate(() => {navigator.clipboard.writeText = async () => {throw new Error('fixture clipboard denied');};});
    const nextExample = page.locator('.docs-article .code-example').nth(1);
    await nextExample.getByRole('button',{name:'复制代码'}).click();
    assert.equal(await page.evaluate(() => getSelection().toString()), await nextExample.locator('code').textContent());
    await page.goto(origin+'plugins.html',{waitUntil:'networkidle'});
    await page.screenshot({path:resolve(screenshots,`plugins-top-${width}.png`)});
    await page.screenshot({path:resolve(screenshots,`plugins-${width}.png`),fullPage:true});
    // Validate every internal section anchor without navigating away to third parties.
    assert.ok(await page.evaluate(() => [...document.querySelectorAll('a[href^="#"]')].every(a => document.getElementById(a.hash.slice(1)))));
  }
  const staticContext = await browser.newContext({javaScriptEnabled:false,viewport:{width:390,height:900}});
  const staticPage = await staticContext.newPage();
  await staticPage.route('**/*', route => route.request().url().startsWith(origin) ? route.continue() : route.abort());
  await staticPage.goto(origin+'plugins.html',{waitUntil:'networkidle'});
  assert.equal(await staticPage.locator('.docs-article h2').count(),9);
  assert.ok(await staticPage.getByRole('navigation',{name:'文档目录'}).isVisible());
  assert.equal(await staticPage.locator('.copy-code').count(),0);
  assert.ok(await staticPage.locator('.docs-article .code-example code').first().innerText().then(value => value.includes('my_hello')));
  await staticPage.goto(origin,{waitUntil:'networkidle'});
  assert.ok(await staticPage.locator('noscript').isVisible());
  await staticContext.close();
  assert.deepEqual(errors,[]); assert.deepEqual(external,[]);
  console.log('GitHub Pages UI：9 个首页场景、3 个文档/大图场景及无 JS 阅读通过；真实截图、手机目录、代码复制/失败回退、下载与恶意文本均通过。');
} finally {await browser.close();await new Promise(resolve => server.close(resolve));}
