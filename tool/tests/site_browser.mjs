// Synthetic local-only website QA. Never launches the manager or contacts QQ.
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import {assetDefinitions, repository, sha256} from '../github_release_core.mjs';
const require = createRequire(import.meta.url);
const {chromium} = require(process.env.QQM_PLAYWRIGHT || 'playwright');
const site = resolve('site');
const screenshots = resolve('build/github-pages-previews');
await mkdir(screenshots,{recursive:true});
let mode = 'empty';
const data = {schema:2,repository,tag:'v1.3.7',version:'1.3.7',build:18,published_at:Math.floor(Date.now()/1000),
  releases:assetDefinitions('1.3.7',18).map(a => ({platform:a.platform,arch:a.arch,format:a.format,version:'1.3.7',build:18,size:42,sha256:sha256('fixture'),
    url:`https://github.com/${repository}/releases/download/v1.3.7/${a.name}`,notes:'本地界面测试，不是真实发布。<img src=x onerror=alert(1)>\n多行说明保持文本。'}))};
const server = createServer(async (request,response) => {
  try {
    const url = new URL(request.url,'http://127.0.0.1');
    if (url.pathname === '/qqm-releases/releases.json') {
      const payload = structuredClone(data);
      if (mode === 'invalid') payload.releases[0].url = 'https://evil.invalid/setup.exe';
      response.setHeader('content-type','application/json');
      response.end(JSON.stringify(mode === 'empty' ? {releases:[]} : payload)); return;
    }
    const relative = decodeURIComponent(url.pathname).replace(/^\/qqm-releases\//,'');
    const path = resolve(site,relative || 'index.html');
    assert.ok(path.startsWith(site + (process.platform === 'win32' ? '\\' : '/')));
    const bytes = await readFile(path);
    response.setHeader('content-type',({'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png'})[extname(path)] || 'application/octet-stream');
    response.end(bytes);
  } catch {response.statusCode=404;response.end('not found');}
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const origin = `http://127.0.0.1:${server.address().port}/qqm-releases/`;
const browser = await chromium.launch({headless:true,...(process.env.QQM_CHROME ? {executablePath:process.env.QQM_CHROME} : {})});
try {
  const page = await browser.newPage();
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
    }
  }
  assert.deepEqual(errors,[]); assert.deepEqual(external,[]);
  console.log('GitHub Pages UI：9 个桌面/手机场景通过；相对路径、Star、空版本、下载链接及恶意文本均通过。');
} finally {await browser.close();await new Promise(resolve => server.close(resolve));}
