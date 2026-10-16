// The private source repository builds; the public repository only distributes.
import {readFile, writeFile, mkdir, cp, stat, mkdtemp} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join, resolve, dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {sourceRepository, repository, pagesUrl, manifestName, base64, signingKeys, readVersion, sha256, assetDefinitions, signManifest, verifyManifest} from './github_release_core.mjs';
import {assertPublicTree, syncPublicSite} from './github_site_sync.mjs';

const command = process.argv[2];
const publicKey = process.env.UPDATE_PUBLIC_KEY ?? '';
const secret = process.env.UPDATE_SIGNING_PRIVATE_KEY ?? '';
const publicToken = process.env.PUBLIC_RELEASE_TOKEN ?? '';
const assert = (condition, message) => {if (!condition) throw new Error(message);};
const gh = (args, token = process.env.GH_TOKEN) => execFileSync('gh', args, {
  env: {...process.env, GH_TOKEN: token, GH_HOST: 'github.com'}, encoding: 'utf8',
  maxBuffer: 4 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe']});
const publicGh = (...args) => {
  assert(publicToken, '请在私有仓库配置 PUBLIC_RELEASE_TOKEN（仅公开下载仓库 Contents: write）');
  return gh(args, publicToken);
};
const json = file => readFile(file, 'utf8').then(JSON.parse);

async function publicFetch(url, maximum = 65536, missing = false) {
  // Authenticate only fixed GitHub API metadata reads to avoid shared-IP limits.
  // Never send a token to github.com release downloads or a redirected CDN.
  let current = new URL(url);
  for (let hop = 0; hop < 6; hop++) {
    assert(current.protocol === 'https:' && !current.username && !current.password && !current.port &&
      ['api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'].includes(current.hostname), '公开资源跳转无效');
    const headers = {'User-Agent':'qqm-release-site',Accept:'application/vnd.github+json'};
    const metadataToken = publicToken || process.env.GH_TOKEN;
    if (metadataToken && current.origin === 'https://api.github.com' && current.pathname.startsWith('/repos/' + repository + '/')) {
      headers.Authorization = 'Bearer ' + metadataToken;
    }
    const response = await fetch(current, {redirect: 'manual', signal: AbortSignal.timeout(20000),headers});
    if (missing && response.status === 404) {await response.body?.cancel(); return null;}
    if ([301,302,303,307,308].includes(response.status)) {
      const location = response.headers.get('location'); await response.body?.cancel();
      assert(location, '公开资源缺少跳转地址'); current = new URL(location,current); continue;
    }
    assert(response.ok, '读取公开版本失败（HTTP ' + response.status + '），请稍后重试');
    const chunks = []; let length = 0;
    for await (const chunk of response.body) {
      length += chunk.length;
      if (length > maximum) {await response.body.cancel().catch(() => {}); throw new Error('公开清单响应过大');}
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }
  throw new Error('公开资源跳转次数过多');
}

async function newestSignedRelease() {
  const releases = await publicFetch('https://api.github.com/repos/' + repository + '/releases?per_page=100', 4 * 1024 * 1024);
  assert(Array.isArray(releases), '公开版本列表格式无效');
  let newest = null;
  for (const release of releases.filter(r => !r.draft && !r.prerelease && Array.isArray(r.assets) && r.assets.some(a => a.name === manifestName))) {
    assert(/^v\d+\.\d+\.\d+$/.test(release.tag_name), '公开版本标签无效');
    const envelope = await publicFetch('https://github.com/' + repository + '/releases/download/' + release.tag_name + '/' + manifestName);
    const data = verifyManifest(envelope, publicKey);
    assert(data.tag === release.tag_name, 'Release 标签与签名清单不匹配');
    assert(data.releases.every(r => release.assets.some(a => a.name === new URL(r.url).pathname.split('/').at(-1) && a.size === r.size)), '已签名 Release 的安装包缺失或大小变化');
    if (newest?.data.build === data.build) assert(newest.envelope.payload === envelope.payload, '同一构建号存在不同清单');
    if (!newest || data.build > newest.data.build) newest = {data, envelope};
  }
  return newest;
}

async function buildAndSyncSite(selected) {
  const destination = resolve('build/github-pages');
  await assertPublicTree('site');
  await mkdir(dirname(destination), {recursive: true});
  await mkdir(destination); // Never merge stale generated stable.json.
  await cp('site', destination, {recursive: true, dereference: false});
  await mkdir(join(destination,'updates'), {recursive: true});
  await writeFile(join(destination,'releases.json'), JSON.stringify(selected?.data ?? {releases: []}));
  if (selected) await writeFile(join(destination,'updates','stable.json'), JSON.stringify(selected.envelope));
  const checkout = process.env.DISTRIBUTION_DIRECTORY;
  if (checkout) {
    await syncPublicSite({directory:checkout, pagesDirectory:destination, publicKey, selected:selected?.data});
    console.log('仅静态首页与公开更新清单已同步；公开仓库会自行部署 Pages。');
  } else {console.log('已生成静态首页；未指定公开 checkout，因此没有推送。');}
}

try {
  assert(process.env.GITHUB_REPOSITORY === sourceRepository, '此流程必须从私有源码仓库运行');
  base64(publicKey, [32]);
  if (command === 'preflight') {
    const info = readVersion(await readFile('pubspec.yaml','utf8'), await readFile('lib/utils/constants.dart','utf8'));
    assert((process.env.UPDATE_BASE_URL ?? pagesUrl).replace(/\/$/, '') === pagesUrl, '更新地址必须使用公开下载仓库的 Pages');
    if (process.env.GITHUB_EVENT_NAME === 'release') {
      const {release} = await json(process.env.GITHUB_EVENT_PATH);
      assert(release && !release.draft && !release.prerelease && release.tag_name === info.tag, '正式 Release 标签必须与源码版本一致');
      assert(secret, '请先在私有仓库配置 UPDATE_SIGNING_PRIVATE_KEY，不要把私钥发到聊天');
      assert(publicToken, '请先在私有仓库配置 PUBLIC_RELEASE_TOKEN（仅公开下载仓库 Contents: write）');
      signingKeys(secret, publicKey);
      const access = JSON.parse(publicGh('api','repos/' + repository));
      assert(access.full_name === repository && access.private === false && access.permissions?.push, 'PUBLIC_RELEASE_TOKEN 无权写入指定公开下载仓库');
      const previous = await newestSignedRelease();
      if (previous) assert(info.build > previous.data.build || (info.build === previous.data.build && info.tag === previous.data.tag), '构建号必须递增');
    }
    console.log('版本 ' + info.version + ' (' + info.build + ') 校验通过，未输出私钥或令牌。');
  } else if (command === 'publish') {
    assert(process.env.DISTRIBUTION_DIRECTORY, '缺少公开首页 checkout，拒绝半配置发布');
    const info = readVersion(await readFile('pubspec.yaml','utf8'), await readFile('lib/utils/constants.dart','utf8'));
    const {release: eventRelease} = await json(process.env.GITHUB_EVENT_PATH);
    assert(eventRelease?.tag_name === info.tag && !eventRelease.draft && !eventRelease.prerelease, '发布事件不匹配');
    signingKeys(secret, publicKey);
    const previous = await newestSignedRelease();
    assert(!previous || info.build > previous.data.build || (info.build === previous.data.build && info.tag === previous.data.tag), '拒绝发布更低版本或重复构建号');
    const packages = resolve('build/release-packages');
    await mkdir(packages, {recursive: true});
    const definitions = assetDefinitions(info.version,info.build);
    gh(['run','download',process.env.GITHUB_RUN_ID,'--repo',sourceRepository,'--dir',packages,
      ...definitions.flatMap(a => ['--name',a.directory])]);
    const notes = (eventRelease.body ?? '').slice(0,2000);
    const data = {schema:2,repository,tag:info.tag,version:info.version,build:info.build,
      published_at:Math.floor(Date.parse(eventRelease.published_at)/1000),releases:[]};
    const files = [];
    for (const asset of definitions) {
      const file = join(packages,asset.directory,asset.name);
      const size = (await stat(file)).size; assert(size > 0 && size <= 1073741824, '安装包大小无效');
      const hash = sha256(await readFile(file));
      data.releases.push({platform:asset.platform,arch:asset.arch,format:asset.format,version:info.version,build:info.build,
        package_id:'cn.uuze.botmanager',size,sha256:hash,
        url:'https://github.com/' + repository + '/releases/download/' + info.tag + '/' + asset.name,notes,force_update:false});
      files.push({file,name:asset.name,hash});
    }
    const windows = await json(join(packages,'windows-x64-packages','qqbotmanager-windows-v' + info.version + '-build' + info.build + '-build-info.json'));
    assert(windows.build === info.build && windows.version === info.version && windows.update_public_key === publicKey && windows.update_server === pagesUrl, 'Windows 包版本或更新配置不一致');
    let envelope = signManifest(data,secret,publicKey);
    let release;
    try {release = JSON.parse(publicGh('api','repos/' + repository + '/releases/tags/' + info.tag));}
    catch(error) {if (!error.stderr?.toString().includes('HTTP 404')) throw error;}
    if (!release) {
      const notesPath = join(packages,'public-release-notes.txt'); await writeFile(notesPath,notes);
      publicGh('release','create',info.tag,'--repo',repository,'--target','main','--draft',
        '--title','QQ机器人管理器 ' + info.tag,'--notes-file',notesPath);
      release = JSON.parse(publicGh('api','repos/' + repository + '/releases/tags/' + info.tag));
    }
    assert(!release.prerelease, '公开版本不能是预发布');
    const existingManifest = release.assets.find(a => a.name === manifestName);
    assert(release.draft || existingManifest, '已有正式公开版本缺少签名清单，请使用新版本号');
    if (existingManifest) {
      const directory = await mkdtemp(join(tmpdir(),'qqm-public-manifest-'));
      publicGh('release','download',info.tag,'--repo',repository,'--pattern',manifestName,'--dir',directory);
      const existing = await json(join(directory,manifestName));
      assert(JSON.stringify(verifyManifest(existing,publicKey)) === JSON.stringify(data), '已经签名的版本不能改写');
      envelope = existing;
    }
    const manifestPath = join(packages,manifestName); await writeFile(manifestPath,JSON.stringify(envelope));
    files.push({file:manifestPath,name:manifestName,hash:sha256(await readFile(manifestPath))});
    // Upload to a PUBLIC-REPOSITORY DRAFT, never upload sources or overwrite bits.
    // Manifest is last; publishing the draft only follows all successful uploads.
    for (const file of files) {
      const existing = release.assets.find(a => a.name === file.name);
      if (existing) {
        const directory = await mkdtemp(join(tmpdir(),'qqm-public-asset-'));
        publicGh('release','download',info.tag,'--repo',repository,'--pattern',file.name,'--dir',directory);
        assert(sha256(await readFile(join(directory,file.name))) === file.hash, '已有附件内容不同，请发布更高版本');
      } else {assert(release.draft, '禁止向正式公开版本追加文件'); publicGh('release','upload',info.tag,file.file,'--repo',repository);}
    }
    if (release.draft) publicGh('release','edit',info.tag,'--repo',repository,'--draft=false','--latest=true');
    await buildAndSyncSite({data,envelope});
    console.log('四端安装包与签名清单已发布到公开下载仓库 ' + info.tag + '。');
  } else if (command === 'pages') {
    await buildAndSyncSite(await newestSignedRelease());
  } else {throw new Error('用法：node tool/github_release.mjs preflight|publish|pages');}
} catch(error) {
  console.error('GitHub 发布未完成：' + (error instanceof Error ? error.message.split('\n')[0] : '未知错误'));
  process.exitCode = 1;
}
