import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import puppeteer from 'puppeteer-core';
import template from 'art-template';

export const escapeHtml = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function createRenderer(root) {
  let idle;
  let tail = Promise.resolve();
  const renderer = {
    browser: null,
    async browserInit() {
      if (renderer.browser?.connected) return true;
      const candidates = [process.env.QQM_CHROME, 'C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].filter(Boolean);
      let executablePath;
      for (const file of candidates) { try { await fs.access(file); executablePath = file; break; } catch {} }
      if (!executablePath) { const error = new Error('缺少图片渲染浏览器：请安装 Chrome／Chromium／Edge，或配置 QQM_CHROME。'); error.qqmSafe = true; throw error; }
      renderer.browser = await puppeteer.launch({ executablePath, headless: true, args: ['--disable-dev-shm-usage', ...(process.env.QQM_BROWSER_NO_SANDBOX === '1' ? ['--no-sandbox'] : [])] });
      return true;
    },
    async screenshot(name, params) {
      const render = async () => {
        clearTimeout(idle);
        await renderer.browserInit();
        const html = template.render(await fs.readFile(params.tplFile, 'utf8'), params, { filename: params.tplFile });
        const base = pathToFileURL(path.dirname(params.tplFile) + path.sep).href;
        return capture(`<base href="${base}">${html}`);
      };
      const work = tail.catch(() => {}).then(render);
      tail = work;
      return work;
    },
    async renderForward(parts) {
      const work = tail.catch(() => {}).then(async () => {
        await renderer.browserInit();
        const body = parts.map(p => p.media_base64 ? `<img src="data:${p.mime};base64,${p.media_base64}">` : `<div>${escapeHtml(p.content)}</div>`).join('');
        return capture(`<meta charset="utf-8"><style>body{margin:0;background:#f4f7fb;font:20px sans-serif;color:#18243b}#container{width:820px;padding:28px;box-sizing:border-box}div{white-space:pre-wrap;overflow-wrap:anywhere;margin:12px 0}img{max-width:100%;display:block;margin:16px 0}</style><main id="container">${body}</main>`);
      });
      tail = work; return work;
    },
    async close() { clearTimeout(idle); await renderer.browser?.close(); renderer.browser = null; },
  };
  async function capture(html) {
    const dir = path.join(root, 'temp');
    await fs.mkdir(dir, { recursive: true });
    const file = path.join(dir, `qqm-render-${crypto.randomUUID()}.html`);
    await fs.writeFile(file, html);
    const page = await renderer.browser.newPage();
    try {
      await page.setViewport({ width: 1800, height: 1000, deviceScaleFactor: 1 });
      await page.goto(pathToFileURL(file).href, { waitUntil: 'load', timeout: 25000 });
      await page.evaluate(() => Promise.race([Promise.all([document.fonts.ready, ...Array.from(document.images).map(img => img.complete ? null : new Promise(r => { img.onload = r; img.onerror = r; }))]), new Promise(r => setTimeout(r, 4000))]));
      const element = await page.$('#container') || await page.$('body');
      const box = await element.boundingBox();
      if (!box || box.height > 8192 || box.width > 4000 || box.width * box.height > 16000000) throw new Error('渲染图片尺寸过大，请减少查询数量。');
      const bytes = Buffer.from(await element.screenshot({ type: 'jpeg', quality: 85 }));
      if (bytes.length > 5 * 1024 * 1024) throw new Error('渲染图片超过 5 MB，请减少查询数量。');
      return { type: 'image', file: bytes };
    } finally {
      await page.close();
      await fs.unlink(file).catch(() => {});
      idle = setTimeout(() => renderer.close().catch(() => {}), 120000).unref();
    }
  }
  return renderer;
}
