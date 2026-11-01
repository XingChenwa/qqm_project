import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.QQM_PLAYWRIGHT || 'playwright');
const suspended = process.argv.includes('--suspended');
const browser = await chromium.launch({ headless: true, ...(process.env.QQM_BROWSER_EXECUTABLE ? { executablePath: process.env.QQM_BROWSER_EXECUTABLE } : {}) });
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.route('**/*', route => route.abort());
  await page.evaluate(blockAnimation => {
    if (blockAnimation) window.requestAnimationFrame = () => 0;
    window.videoResults = [];
    window.flutter_inappwebview = { callHandler: async (name, value) => { window.videoResults.push({ name, value }); return null; } };
  }, suspended);
  await page.setContent(await readFile('build/agent-video-probe/frames.html', 'utf8'));
  await page.waitForFunction(() => window.videoResults.some(r => ['qqmVideoDone','qqmVideoError'].includes(r.name)), undefined, { timeout: 30000, polling: 100 });
  const result = await page.evaluate(async () => {
    const frames = window.videoResults.filter(r=>r.name === 'qqmVideoFrame').map(r=>r.value);
    const dimensions = [];
    for (const frame of frames) {
      const raw = Uint8Array.from(atob(frame.dataUrl.split(',')[1]), c => c.charCodeAt(0));
      const image = await createImageBitmap(new Blob([raw], {type:'image/jpeg'}));
      dimensions.push([image.width,image.height]); image.close();
    }
    return { frames, dimensions, done: window.videoResults.find(r=>r.name === 'qqmVideoDone')?.value, error: window.videoResults.some(r=>r.name==='qqmVideoError') };
  });
  assert.deepEqual(errors, []);
  assert.equal(result.error, false);
  assert.equal(result.frames.length, 6);
  assert.ok(result.done.duration >= 2.9 && result.done.duration <= 3.1);
  assert.equal(new Set(result.frames.map(f=>f.seconds)).size, 6);
  assert.ok(new Set(result.frames.map(f=>f.dataUrl)).size >= 4, 'Must decode different video moments, not repeat the cover');
  assert.ok(result.frames[0].seconds < .5 && result.frames[5].seconds > 2.5);
  assert.ok(result.dimensions.every(([w,h])=>w===320 && h===180));
  console.log(`PASS: real MP4 decoded into 6 distinct, timed JPEG frames; data-only page, no external requests${suspended ? ', animation callbacks suspended' : ''}.`);
} finally { await browser.close(); }
