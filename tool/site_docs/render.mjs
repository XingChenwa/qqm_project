// Build a static, script-independent reading page from the canonical plugin guide.
// No Markdown parser or third-party script is downloaded by visitors' browsers.
import {Marked} from 'marked';
import {readFile, writeFile, copyFile, realpath} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const repository = 'XingChenwa/qqm_project';
const sourceUrl = `https://github.com/${repository}/blob/main/docs/plugin-development.md`;
const sourceRoot = fileURLToPath(new URL('../../', import.meta.url));
const escape = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));

export function documentationLink(href) {
  if (typeof href !== 'string' || /[\u0000-\u0020\\]/.test(href)) throw new Error('文档链接包含非法字符');
  if (href.startsWith('#')) return href;
  const url = new URL(href, sourceUrl);
  if (url.protocol !== 'https:' || url.username || url.password) throw new Error('文档只允许无凭据的 HTTPS 链接');
  return url.href;
}

export function renderPluginGuide(markdown) {
  const toc = [];
  let section = 0, heading = 0;
  const parser = new Marked({gfm: true, breaks: false, async: false, renderer: {
    html({text}) {return escape(text);},
    image({text}) {return escape(text);},
    link({href, title, tokens}) {
      return `<a href="${escape(documentationLink(href))}"${title ? ` title="${escape(title)}"` : ''}>${this.parser.parseInline(tokens)}</a>`;
    },
    heading({depth, text, tokens}) {
      if (depth === 1) return ''; // The page has its own single, accessible h1.
      const id = depth === 2 ? `section-${++section}` : `heading-${++heading}`;
      if (depth === 2) toc.push({id, title: text});
      return `<h${depth} id="${id}" tabindex="-1">${this.parser.parseInline(tokens)}<a class="heading-anchor" href="#${id}" aria-label="本节链接">#</a></h${depth}>\n`;
    },
    code({text, lang}) {
      const language = (lang || 'text').split(/\s/)[0];
      return `<div class="code-example"><div class="code-heading"><span>${escape(language)}</span></div><pre tabindex="0"><code>${escape(text)}</code></pre></div>\n`;
    },
    table(token) {
      const html = this.constructor.prototype.table.call(this, token);
      return `<div class="table-scroll" role="region" aria-label="文档表格" tabindex="0">${html}</div>\n`;
    }
  }});
  const article = parser.parse(markdown);
  const links = toc.map(item => `<a href="#${item.id}">${escape(item.title)}</a>`).join('\n');
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="QQ机器人管理器插件开发手册：JSON/YAML 规则、HTTP 插件、Markdown 与按钮、权限、Dart SDK 和文件工作区。含完整示例与命令说明。">
  <meta name="theme-color" content="#f5f8ff">
  <title>插件开发手册 · QQ机器人管理器</title>
  <link rel="icon" href="assets/logo.png">
  <link rel="stylesheet" href="assets/site.css">
  <script src="assets/docs.js" defer></script>
</head>
<body class="docs-page">
<a class="skip-link" href="#guide">跳到文档正文</a>
<header class="site-header wrap">
  <a class="brand" href="./"><img src="assets/logo.png" width="38" height="38" alt=""><span>QQ机器人管理器<small>BOT MANAGER</small></span></a>
  <nav aria-label="主导航"><a href="./#demo">项目演示</a><a href="plugins.html" aria-current="page">开发文档</a><a href="./#downloads">下载</a><a class="nav-github" href="https://github.com/${repository}">GitHub ↗</a></nav>
</header>
<div class="docs-heading wrap">
  <p class="eyebrow">PLUGIN WORKSHOP / SDK v2</p>
  <h1>把想法，写成一个插件。</h1>
  <p>从第一条问候命令，到你自己的服务。这里是完整的插件开发手册。</p>
  <div class="doc-meta"><a href="#section-2">开始第一个插件 ↓</a><a href="https://github.com/${repository}/tree/main/plugins/examples">示例源码 ↗</a><a href="${sourceUrl}">查看 Markdown 源文档 ↗</a></div>
</div>
<div class="docs-layout wrap">
  <aside class="docs-sidebar">
    <details class="docs-toc" open>
      <summary>文档目录</summary>
      <nav aria-label="文档目录">${links}</nav>
    </details>
    <div class="docs-help"><strong>需要先试一试？</strong><p>安装客户端，打开「插件 → 写插件」，导入清单后先校验和试运行。</p><a href="./#downloads">下载客户端 →</a></div>
  </aside>
  <main id="guide" class="docs-article">${article}
    <div class="doc-end"><strong>写出新玩法，也欢迎分享。</strong><p>提交示例、完善文档，或带上脱敏信息反馈问题。</p><a href="https://github.com/${repository}/issues">问题与建议 ↗</a><a href="./">返回项目首页 →</a></div>
  </main>
</div>
<p id="copy-status" class="sr-only" aria-live="polite"></p>
<footer class="wrap"><span>QQ机器人管理器 · 学习交流项目<br><small>基于 QQ 官方开放平台开发，非腾讯官方客户端。</small></span><span><a href="https://github.com/${repository}/blob/main/LICENSE">GPL-2.0-only</a> · 作者 QQ：2377130783<br><a href="https://github.com/${repository}">如果喜欢，给项目点个 Star ↗</a></span></footer>
</body>
</html>
`;
}

export async function generateDocumentation(directory, {check = false} = {}) {
  if (!directory) throw new Error('请通过 WEBSITE_DIRECTORY 指定网站 docs 分支');
  const target = await realpath(resolve(directory));
  const git = (...args) => execFileSync('git', ['-C', target, ...args], {encoding:'utf8', stdio:['ignore','pipe','pipe']}).trim();
  if (await realpath(git('rev-parse','--show-toplevel')) !== target || git('branch','--show-current') !== 'docs' ||
      ![`https://github.com/${repository}.git`, `https://github.com/${repository}`, `git@github.com:${repository}.git`].includes(git('remote','get-url','origin'))) {
    throw new Error('只允许生成到本项目独立的 docs 分支 checkout');
  }
  const html = renderPluginGuide(await readFile(join(sourceRoot, 'docs/plugin-development.md'), 'utf8'));
  const destination = join(target, 'plugins.html');
  const screenshot = join(sourceRoot, 'docs/screenshots/client-chat.png');
  const imageDestination = join(target, 'assets/client-chat.png');
  if (check) {
    if ((await readFile(destination, 'utf8')).replace(/\r\n/g, '\n') !== html || !(await readFile(imageDestination)).equals(await readFile(screenshot))) {
      throw new Error('站内插件手册或真实演示图尚未与源码同步');
    }
  } else {
    // Exact public artifacts only: never copy the app workspace, preferences or credentials.
    await writeFile(destination, html);
    await copyFile(screenshot, imageDestination);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await generateDocumentation(process.env.WEBSITE_DIRECTORY, {check: process.argv.includes('--check')});
  console.log(process.argv.includes('--check') ? '站内插件手册和真实演示图校验通过。' : '已生成站内插件手册并同步真实演示图。');
}
