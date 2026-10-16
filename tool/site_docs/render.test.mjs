import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {renderPluginGuide, documentationLink} from './render.mjs';

test('完整指南生成九节正文、静态目录、可复制代码和可用的仓库链接', async () => {
  const markdown = await readFile(new URL('../../docs/plugin-development.md', import.meta.url), 'utf8');
  const html = renderPluginGuide(markdown);
  assert.equal((html.match(/<h1>/g) || []).length, 1);
  assert.equal((html.match(/<h2 id="section-/g) || []).length, 9);
  for (let i = 1; i <= 9; i++) assert.ok(html.includes(`href="#section-${i}"`));
  assert.ok(html.includes('host!.store.update'));
  assert.ok(html.includes('class="table-scroll"'));
  assert.ok(html.includes('https://github.com/XingChenwa/qqm_project/blob/main/plugins/examples/http_echo/server.mjs'));
  assert.ok(!html.includes('href="../'));
});

test('不执行 Markdown 原始 HTML，代码只作为文本，不允许危险链接', () => {
  const html = renderPluginGuide('## 示例\n\n<script>alert(1)</script>\n\n```html\n<img onerror=alert(1)>\n```\n');
  assert.ok(!html.includes('<script>alert(1)</script>'));
  assert.ok(!html.includes('<img onerror'));
  assert.ok(html.includes('&lt;img onerror=alert(1)&gt;'));
  for (const url of ['javascript:alert(1)', 'data:text/html,x', 'http://example.com', 'https://user:pass@example.com', 'https://example.com/\n']) {
    assert.throws(() => documentationLink(url));
  }
  assert.throws(() => renderPluginGuide('[点击](javascript:alert(1))'));
  assert.equal(documentationLink('../plugins/schema/plugin.schema.json'), 'https://github.com/XingChenwa/qqm_project/blob/main/plugins/schema/plugin.schema.json');
  assert.equal(documentationLink('#section-1'), '#section-1');
});
