import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import yauzl from 'yauzl';

export const packageIdPattern = /^node_[a-z0-9_]{1,50}$/;
export const appIdPattern = /^[A-Za-z0-9_-]{1,128}$/;
const maxZip = 128 * 1024 * 1024, maxExpanded = 512 * 1024 * 1024;
export const digest = value => createHash('sha256').update(value).digest('hex');
async function fileDigest(file) { const hash = createHash('sha256'); for await (const bytes of createReadStream(file)) hash.update(bytes); return hash.digest('hex'); }
const excluded = new Set(['.git', 'node_modules', '.npm', '.cache', '.qqm-backups']);
export const cleanEnvironment = () => {
  const result = {};
  for (const key of ['PATH', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'HOME', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMFILES', 'QQM_CHROME', 'QQM_BROWSER_NO_SANDBOX']) if (process.env[key]) result[key] = process.env[key];
  return { ...result, PUPPETEER_SKIP_DOWNLOAD: 'true', PUPPETEER_SKIP_CHROMIUM_DOWNLOAD: 'true', CHOKIDAR_USEPOLLING: 'false' };
};
export function safeRelative(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 500 && !value.includes('\\') && !/[\x00-\x1f:<>"|?*]/.test(value) && value.split('/').every(s => s && s !== '.' && s !== '..' && !/[. ]$/.test(s) && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(s));
}
export async function checked(root, relative = '') {
  if (relative && !safeRelative(relative)) throw new Error('文件路径无效。');
  const absolute = path.resolve(root, relative);
  const realRoot = await fs.realpath(root);
  let current = path.resolve(root);
  for (const part of relative.split('/').filter(Boolean)) {
    current = path.join(current, part);
    try {
      const stat = await fs.lstat(current);
      if (stat.isSymbolicLink()) throw new Error('不允许通过链接访问插件文件。');
      const real = await fs.realpath(current);
      if (real !== realRoot && !real.startsWith(realRoot + path.sep)) throw new Error('文件超出插件目录。');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return absolute;
}
async function walk(root, base = '', result = []) {
  for (const entry of await fs.readdir(path.join(root, base), { withFileTypes: true })) {
    if (excluded.has(entry.name)) continue;
    const relative = [base, entry.name].filter(Boolean).join('/');
    if (!safeRelative(relative)) throw new Error('插件包含不支持的文件路径。');
    if (entry.isSymbolicLink()) throw new Error('插件原包不能包含符号链接。');
    if (entry.isDirectory()) await walk(root, relative, result);
    else if (entry.isFile()) result.push(relative);
    if (result.length > 10000) throw new Error('插件文件数量超过 10000。');
  }
  return result;
}

async function unzip(file, root) {
  const zip = await new Promise((resolve, reject) => yauzl.open(file, { lazyEntries: true, autoClose: true, validateEntrySizes: true }, (error, value) => error ? reject(error) : resolve(value)));
  let expanded = 0, count = 0;
  const names = new Set();
  return new Promise((resolve, reject) => {
    const fail = error => { zip.close(); reject(error); };
    zip.on('error', fail); zip.on('end', resolve);
    zip.on('entry', entry => {
      (async () => {
        const name = entry.fileName.replace(/\/$/, '');
        if (!safeRelative(name) || names.has(name.toLowerCase()) || ((entry.externalFileAttributes >>> 16) & 0xf000) === 0xa000) throw new Error('ZIP 包含越界路径、重复文件或链接。');
        names.add(name.toLowerCase());
        if (++count > 10000 || (expanded += entry.uncompressedSize) > maxExpanded || entry.uncompressedSize > 128 * 1024 * 1024) throw new Error('插件 ZIP 解压后过大。');
        if (name.split('/').some(part => excluded.has(part))) { zip.readEntry(); return; }
        const target = path.join(root, ...name.split('/'));
        if (entry.fileName.endsWith('/')) await fs.mkdir(target, { recursive: true });
        else {
          await fs.mkdir(path.dirname(target), { recursive: true });
          const stream = await new Promise((r, j) => zip.openReadStream(entry, (e, v) => e ? j(e) : r(v)));
          const handle = await fs.open(target, 'wx', 0o600);
          let actual = 0;
          try { for await (const chunk of stream) { actual += chunk.length; if (actual > entry.uncompressedSize || actual > 128 * 1024 * 1024) throw new Error('ZIP 文件长度不符。'); await handle.write(chunk); } }
          finally { await handle.close(); }
          if (actual !== entry.uncompressedSize) throw new Error('ZIP 文件不完整。');
        }
        zip.readEntry();
      })().catch(fail);
    });
    zip.readEntry();
  });
}

export class Packages {
  constructor(root, npmPath) { this.root = root; this.npmPath = npmPath; this.jobs = new Map(); this.stages = new Map(); this.active = new Set(); this.children = new Set(); }
  async init() { for (const folder of ['packages', 'staging', 'removed']) await fs.mkdir(path.join(this.root, folder), { recursive: true }); }
  directory(id) { if (!packageIdPattern.test(id || '')) throw new Error('插件 ID 无效。'); return path.join(this.root, 'packages', id); }
  async info(id) { return JSON.parse(await fs.readFile(path.join(this.directory(id), 'metadata.json'), 'utf8')); }
  async list() {
    const result = [];
    for (const entry of await fs.readdir(path.join(this.root, 'packages'), { withFileTypes: true })) {
      if (entry.isDirectory() && packageIdPattern.test(entry.name)) { try { result.push(await this.info(entry.name)); } catch {} }
    }
    return result;
  }
  async upload(stream, filename, kind = 'zip') {
    const stage = randomUUID();
    const directory = path.join(this.root, 'staging', stage);
    const source = path.join(directory, 'unpacked');
    await fs.mkdir(source, { recursive: true });
    const archive = path.join(directory, 'original');
    const handle = await fs.open(archive, 'wx', 0o600);
    const hash = createHash('sha256'); let size = 0;
    try { for await (const chunk of stream) { size += chunk.length; if (size > (kind === 'js' ? 4 * 1024 * 1024 : maxZip)) throw new Error('原包超过大小限制。'); hash.update(chunk); await handle.write(chunk); } }
    finally { await handle.close(); }
    if (!size) throw new Error('文件为空。');
    let packageRoot = source;
    if (kind === 'js') {
      await fs.mkdir(path.join(source, 'apps'));
      const cjs = /\.cjs$/i.test(filename), main = `apps/main.${cjs ? 'cjs' : 'js'}`;
      await fs.copyFile(archive, path.join(source, main));
      await fs.writeFile(path.join(source, 'package.json'), JSON.stringify({ name: path.basename(filename).replace(/\.[cm]?js$/i, ''), version: '1.0.0', type: cjs ? 'commonjs' : 'module', main }));
    } else {
      await unzip(archive, source);
      for (let depth = 0; depth < 6; depth++) {
        try { await fs.access(path.join(packageRoot, 'package.json')); break; } catch {}
        const entries = (await fs.readdir(packageRoot, { withFileTypes: true })).filter(e => !['__MACOSX', '.DS_Store'].includes(e.name));
        if (entries.length !== 1 || !entries[0].isDirectory()) break;
        packageRoot = path.join(packageRoot, entries[0].name);
      }
    }
    const files = await walk(packageRoot);
    let pkg;
    try {
      const packageFile = path.join(packageRoot, 'package.json');
      if ((await fs.stat(packageFile)).size > 1024 * 1024) throw new Error('package.json 过大。');
      pkg = JSON.parse(await fs.readFile(packageFile, 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw new Error('package.json 格式无效。');
      const js = files.filter(f => /\.[cm]?js$/i.test(f));
      if (!js.length) throw new Error('没有找到 JavaScript 插件入口。');
      pkg = { name: path.basename(filename).replace(/\.zip$/i, ''), type: 'module', version: '1.0.0' };
      await fs.writeFile(path.join(packageRoot, 'package.json'), JSON.stringify(pkg));
    }
    const name = String(pkg.name || path.basename(filename).replace(/\.zip$/i, '')).slice(0, 80);
    const stem = name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 34) || 'plugin';
    const id = `node_${stem}_${digest(name).slice(0, 8)}`;
    let entry = typeof pkg.main === 'string' ? pkg.main.replace(/^\.\//, '') : '';
    if (!files.includes(entry)) entry = ['index.js', 'index.mjs', 'main.js'].find(f => files.includes(f)) || '';
    const entries = entry ? [entry] : files.filter(f => /^apps\/[^/]+\.[cm]?js$/.test(f));
    if (!entries.length) throw new Error('未找到入口，请在原包 package.json 中声明 main，或提供 index.js／apps/*.js。');
    for (const file of entries) if (!safeRelative(file)) throw new Error('插件入口路径无效。');
    const dependencies = Object.entries(pkg.dependencies || {}).map(([name, version]) => ({ name, version: String(version) }));
    const metadata = { id, name, version: String(pkg.version || '1.0.0').slice(0, 80), description: String(pkg.description || '原版 Node.js 插件').slice(0, 1000), author: String(typeof pkg.author === 'object' ? pkg.author?.name || '' : pkg.author || '').slice(0, 120), entries, folder: stem.replaceAll('_', '-') || 'plugin', revision: hash.digest('hex'), dependencies, files: files.length, bytes: size, license: String(pkg.license || '').slice(0, 80), scripts: Object.keys(pkg.scripts || {}).filter(s => /^(preinstall|install|postinstall|prepare)$/.test(s)), status: 'inspected', installedAt: '' };
    this.stages.set(stage, { source: packageRoot, metadata, created: Date.now() });
    await fs.unlink(archive);
    return { stage_id: stage, ...metadata, exists: (await this.list()).some(p => p.id === id) };
  }
  async repository(url) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || parsed.hostname !== 'github.com' || parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error('请使用公开 GitHub 仓库 HTTPS 地址。');
    const parts = parsed.pathname.replace(/\.git\/?$/, '').split('/').filter(Boolean);
    if (parts.length !== 2 || parts.some(p => !/^[A-Za-z0-9_.-]+$/.test(p))) throw new Error('请填写 GitHub 仓库首页地址；指定版本可上传其 ZIP。');
    const response = await fetch(`https://codeload.github.com/${parts[0]}/${parts[1]}/zip/HEAD`, { redirect: 'error', signal: AbortSignal.timeout(120000), headers: { 'User-Agent': 'QQBotManager-Plugin-Importer' } });
    if (!response.ok) throw new Error(`GitHub 下载失败（HTTP ${response.status}），可以改用本地 ZIP。`);
    return this.upload(response.body, `${parts[1]}.zip`);
  }
  async install(stage, replace, stopPackage) {
    const item = this.stages.get(stage);
    if (!item || Date.now() - item.created > 86400000) throw new Error('导入预览已过期，请重新选择原包。');
    const id = item.metadata.id;
    if (this.active.has(id)) throw new Error('此插件正在安装依赖，请稍后再试。');
    const directory = this.directory(id);
    let previous;
    try { previous = await this.info(id); } catch {}
    if (previous && !replace) throw new Error('插件已存在，请先选择替换。');
    const jobId = randomUUID();
    const job = { id: jobId, package_id: id, kind: 'install', phase: '安装依赖', status: 'running' };
    this.jobs.set(jobId, job); this.active.add(id); this.stages.delete(stage);
    (async () => {
      try {
        await this.npm(item.source);
        await stopPackage(id);
        await fs.mkdir(directory, { recursive: true });
        const source = path.join(directory, 'source');
        if (previous) await fs.rename(source, path.join(this.root, 'removed', `${id}-source-${randomUUID()}`));
        await fs.rename(item.source, source);
        const metadata = { ...item.metadata, status: 'installed', installedAt: new Date().toISOString() };
        await fs.writeFile(path.join(directory, 'metadata.json'), JSON.stringify(metadata), { mode: 0o600 });
        job.status = 'done'; job.phase = '已安装，等待手动启用'; job.package = metadata;
      } catch (error) { job.status = 'failed'; job.phase = '安装失败'; job.error = error.qqmSafe ? error.message : '依赖安装或文件保存失败；原包已保留，请检查 Node 版本、网络和磁盘权限。'; }
      finally { this.active.delete(id); }
    })();
    return job;
  }
  async npm(source) {
    let cli = this.npmPath || path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js');
    try { await fs.access(cli); }
    catch {
      const candidates = [path.resolve(path.dirname(process.execPath), '../lib/node_modules/npm/bin/npm-cli.js'), '/usr/share/nodejs/npm/bin/npm-cli.js'];
      cli = '';
      for (const candidate of candidates) { try { await fs.access(candidate); cli = candidate; break; } catch {} }
      if (!cli) { const error = new Error('未找到 npm，请安装包含 npm 的 Node.js 22 或更新版本。'); error.qqmSafe = true; throw error; }
    }
    const child = spawn(process.execPath, [cli, 'install', '--omit=dev', '--no-audit', '--no-fund'], { cwd: source, env: cleanEnvironment(), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    this.children.add(child);
    let code = ''; let size = 0;
    const read = data => { size += data.length; if (size <= 1024 * 1024) { const match = data.toString().match(/npm (?:ERR!|error) code ([A-Z0-9_]+)/); if (match) code = match[1]; } };
    child.stdout.on('data', read); child.stderr.on('data', read);
    const timer = setTimeout(() => child.kill(), 600000).unref();
    const exit = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
    clearTimeout(timer); this.children.delete(child);
    if (exit !== 0) { const error = new Error(`npm 依赖安装失败${code ? `（${code}）` : ''}；请检查网络，原生模块还需要对应平台的编译依赖。`); error.qqmSafe = true; throw error; }
  }
  async dependencies(id, stopPackage) {
    if (this.active.has(id)) throw new Error('此插件依赖正在安装。');
    const metadata = await this.info(id);
    await stopPackage(id);
    const job = { id: randomUUID(), package_id: id, kind: 'dependencies', phase: '安装原包依赖', status: 'running' };
    this.jobs.set(job.id, job); this.active.add(id);
    (async () => {
      try { await this.npm(path.join(this.directory(id), 'source')); job.status = 'done'; job.phase = '依赖已安装'; job.package = metadata; }
      catch (error) { job.status = 'failed'; job.phase = '安装失败'; job.error = error.qqmSafe ? error.message : '插件依赖安装失败。'; }
      finally { this.active.delete(id); }
    })();
    return job;
  }
  cancel() { for (const child of this.children) child.kill(); }
  async prepare(id, appId) {
    if (!appIdPattern.test(appId || '')) throw new Error('当前 AppID 无效。');
    const metadata = await this.info(id);
    const directory = this.directory(id);
    const source = path.join(directory, 'source');
    if (metadata.dependencies.length && !await fs.stat(path.join(source, 'node_modules')).then(s => s.isDirectory()).catch(() => false)) {
      throw new Error('插件依赖尚未安装，请在插件卡片选择“安装依赖”。');
    }
    const account = path.join(directory, 'accounts', digest(appId));
    const plugin = path.join(account, 'plugins', metadata.folder);
    await fs.mkdir(plugin, { recursive: true });
    const files = await walk(source);
    const stamps = [];
    for (const file of files) { const stat = await fs.stat(path.join(source, file)); stamps.push(`${file}:${stat.size}:${stat.mtimeMs}`); }
    const revision = digest(stamps.sort().join('\n'));
    let previous = ''; try { previous = await fs.readFile(path.join(account, '.prepared'), 'utf8'); } catch {}
    let previousFiles = {}; try { previousFiles = JSON.parse(await fs.readFile(path.join(account, '.prepared-files.json'), 'utf8')); } catch {}
    if (previous !== revision) {
      const hashes = {};
      for (const file of files) {
        hashes[file] = await fileDigest(path.join(source, file));
        const target = await checked(plugin, file);
        const exists = await fs.stat(target).then(s => s.isFile()).catch(() => false);
        // Retain restored sparse overrides and locally edited native configs,
        // regardless of the author's particular config filename or layout.
        if (exists && (!previous || /^(data|temp|config\/config)\//.test(file) || !previousFiles[file] || await fileDigest(target) !== previousFiles[file])) continue;
        await fs.mkdir(path.dirname(target), { recursive: true });
        await fs.copyFile(path.join(source, file), target);
      }
      for (const file of Object.keys(previousFiles)) {
        if (hashes[file] || !safeRelative(file) || /^(data|temp|config\/config)\//.test(file)) continue;
        const target = await checked(plugin, file);
        if (await fs.stat(target).then(s => s.isFile()).catch(() => false) && await fileDigest(target) === previousFiles[file]) await fs.unlink(target);
      }
      await fs.writeFile(path.join(account, '.prepared-files.json'), JSON.stringify(hashes));
      await fs.writeFile(path.join(account, '.prepared'), revision);
    }
    // Copy original default YAML files as editable per-bot overrides, without
    // knowing any plugin's feature names or config keys.
    const defaults = path.join(plugin, 'config/default_config');
    try {
      await fs.mkdir(path.join(plugin, 'config/config'), { recursive: true });
      for (const file of await fs.readdir(defaults)) if (/\.ya?ml$/i.test(file)) {
        try { await fs.copyFile(path.join(defaults, file), path.join(plugin, 'config/config', file), 1); }
        catch (error) { if (error.code !== 'EEXIST') throw error; }
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const dependencies = path.join(plugin, 'node_modules');
    await fs.mkdir(path.join(source, 'node_modules'), { recursive: true });
    try { await fs.symlink(path.join(source, 'node_modules'), dependencies, process.platform === 'win32' ? 'junction' : 'dir'); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    await fs.writeFile(path.join(account, 'package.json'), JSON.stringify({ name: 'qqm-plugin-account', version: '1.0.0', type: 'module', dependencies: {} }));
    return { metadata, account, plugin };
  }
  async files(id, appId, scope) {
    const base = scope === 'source' ? path.join(this.directory(id), 'source') : (await this.prepare(id, appId)).plugin;
    const names = (await walk(base)).filter(f => /\.(?:[cm]?js|json|ya?ml|ht|md|txt|css|html)$/i.test(f));
    return { directory: base, files: names };
  }
  async file(id, appId, scope, name, content) {
    const listing = await this.files(id, appId, scope);
    const file = await checked(listing.directory, name);
    if (content !== undefined) {
      if (typeof content !== 'string' || Buffer.byteLength(content) > 2 * 1024 * 1024) throw new Error('文件超过 2 MB，请使用系统编辑器。');
      await fs.mkdir(path.dirname(file), { recursive: true });
      await fs.writeFile(file, content, { mode: 0o600 });
      return { ok: true };
    }
    if ((await fs.stat(file)).size > 2 * 1024 * 1024) throw new Error('文件超过 2 MB，请使用系统编辑器。');
    return { content: await fs.readFile(file, 'utf8') };
  }
}
