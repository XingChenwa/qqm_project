// Source, Releases and the docs website branch all belong to one repository.
import {readFile, writeFile, mkdir, stat, mkdtemp} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {repository, pagesUrl, websiteBranch, manifestName, base64, signingKeys, readVersion, sha256, assetDefinitions, signManifest, verifyManifest} from './github_release_core.mjs';
import {syncWebsiteMetadata} from './github_site_sync.mjs';

const command = process.argv[2];
const publicKey = process.env.UPDATE_PUBLIC_KEY ?? '';
const secret = process.env.UPDATE_SIGNING_PRIVATE_KEY ?? '';
const assert = (condition,message) => {if (!condition) throw new Error(message);};
const gh = (...args) => execFileSync('gh',args,{
  env:{...process.env,GH_HOST:'github.com'},encoding:'utf8',maxBuffer:4*1024*1024,stdio:['ignore','pipe','pipe']});
const api = path => JSON.parse(gh('api','repos/'+repository+(path?'/'+path:'')));
const json = file => readFile(file,'utf8').then(JSON.parse);

async function publicFetch(url,maximum=65536) {
  let current = new URL(url);
  for(let hop=0;hop<6;hop++) {
    assert(current.protocol === 'https:' && !current.username && !current.password && !current.port &&
      ['api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com'].includes(current.hostname), '资源跳转无效');
    const headers = {'User-Agent':'qqm-release-site',Accept:'application/vnd.github+json'};
    // Credentials are only used on this repository's API, never on redirects/CDN.
    if (process.env.GH_TOKEN && current.origin === 'https://api.github.com' && current.pathname.startsWith('/repos/'+repository+'/')) {
      headers.Authorization = 'Bearer ' + process.env.GH_TOKEN;
    }
    const response = await fetch(current,{redirect:'manual',signal:AbortSignal.timeout(20000),headers});
    if ([301,302,303,307,308].includes(response.status)) {
      const location = response.headers.get('location');await response.body?.cancel();
      assert(location,'资源缺少跳转地址');current = new URL(location,current);continue;
    }
    assert(response.ok,'读取版本失败（HTTP '+response.status+'），请稍后重试');
    const chunks=[];let length=0;
    for await(const chunk of response.body) {
      length+=chunk.length;assert(length<=maximum,'清单响应过大');chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }
  throw new Error('资源跳转次数过多');
}

async function newestSignedRelease() {
  const releases = await publicFetch('https://api.github.com/repos/'+repository+'/releases?per_page=100',4*1024*1024);
  assert(Array.isArray(releases),'版本列表格式无效');
  let newest=null;
  for (const release of releases.filter(r=>!r.draft&&!r.prerelease&&Array.isArray(r.assets)&&r.assets.some(a=>a.name===manifestName))) {
    assert(/^v\d+\.\d+\.\d+$/.test(release.tag_name),'版本标签无效');
    const envelope = await publicFetch('https://github.com/'+repository+'/releases/download/'+release.tag_name+'/'+manifestName);
    const data = verifyManifest(envelope,publicKey);
    assert(data.tag === release.tag_name,'Release 标签与签名清单不匹配');
    assert(data.releases.every(r=>release.assets.some(a=>a.name===new URL(r.url).pathname.split('/').at(-1)&&a.size===r.size)),'已签名 Release 的安装包缺失或大小变化');
    if (newest?.data.build===data.build) assert(newest.envelope.payload===envelope.payload,'同一构建号存在不同清单');
    if(!newest||data.build>newest.data.build) newest={data,envelope};
  }
  return newest;
}

async function syncAndBuildWebsite(selected) {
  assert(process.env.WEBSITE_DIRECTORY,'缺少 docs 分支 checkout');
  await syncWebsiteMetadata({directory:process.env.WEBSITE_DIRECTORY,publicKey,selected});
  // GITHUB_TOKEN pushes do not trigger Pages. Explicitly request a branch build.
  const pages = api('pages');
  assert(pages.build_type==='legacy' && pages.source?.branch===websiteBranch && pages.source?.path==='/',
    '请先在 Settings → Pages 选择 Deploy from a branch → docs → / (root)');
  gh('api','--method','POST','repos/'+repository+'/pages/builds');
  console.log('docs 下载资料已同步，已请求 GitHub Pages 构建。');
}

function releaseMatches(release,info) {
  assert(release && !release.draft && !release.prerelease && release.tag_name===info.tag,'正式 Release 标签必须与源码版本一致');
  assert(!release.immutable,'此流程需在构建后上传附件；请勿对该版本启用 Release 不可变锁定');
}

try {
  assert(process.env.GITHUB_REPOSITORY===repository,'此流程必须从项目原仓库运行');
  base64(publicKey,[32]);
  if(command==='preflight') {
    const info=readVersion(await readFile('pubspec.yaml','utf8'),await readFile('lib/utils/constants.dart','utf8'));
    assert((process.env.UPDATE_BASE_URL??pagesUrl).replace(/\/$/,'')===pagesUrl,'更新地址必须使用项目原仓库的 Pages');
    if(process.env.GITHUB_EVENT_NAME==='release') {
      const {release}=await json(process.env.GITHUB_EVENT_PATH);releaseMatches(release,info);
      assert(!api('').private,'公开下载需要先由仓库所有者将项目设为公开；流程不会自动改变可见性');
      releaseMatches(api('releases/'+release.id),info);
      assert(secret,'请先配置 UPDATE_SIGNING_PRIVATE_KEY，不要把私钥发到聊天');signingKeys(secret,publicKey);
      const pages=api('pages');
      assert(pages.build_type==='legacy'&&pages.source?.branch===websiteBranch&&pages.source?.path==='/', '请先配置 Pages 从 docs 分支根目录发布');
      const previous=await newestSignedRelease();
      assert(!previous||info.build>previous.data.build||(info.build===previous.data.build&&info.tag===previous.data.tag),'构建号必须递增');
    }
    console.log('版本 '+info.version+' ('+info.build+') 校验通过，未输出私钥或令牌。');
  } else if(command==='publish') {
    assert(process.env.WEBSITE_DIRECTORY,'缺少 docs 分支 checkout，拒绝半配置发布');
    const info=readVersion(await readFile('pubspec.yaml','utf8'),await readFile('lib/utils/constants.dart','utf8'));
    const {release:eventRelease}=await json(process.env.GITHUB_EVENT_PATH);releaseMatches(eventRelease,info);
    const release=api('releases/'+eventRelease.id);releaseMatches(release,info);
    signingKeys(secret,publicKey);
    const previous=await newestSignedRelease();
    assert(!previous||info.build>previous.data.build||(info.build===previous.data.build&&info.tag===previous.data.tag),'拒绝发布更低版本或重复构建号');
    const packages=resolve('build/release-packages');await mkdir(packages,{recursive:true});
    const definitions=assetDefinitions(info.version,info.build);
    gh('run','download',process.env.GITHUB_RUN_ID,'--repo',repository,'--dir',packages,...definitions.flatMap(a=>['--name',a.directory]));
    const notes=(eventRelease.body??'').slice(0,2000);
    const data={schema:2,repository,tag:info.tag,version:info.version,build:info.build,
      published_at:Math.floor(Date.parse(eventRelease.published_at)/1000),releases:[]};
    const files=[];
    for(const asset of definitions) {
      const file=join(packages,asset.directory,asset.name),size=(await stat(file)).size;
      assert(size>0&&size<=1073741824,'安装包大小无效');const hash=sha256(await readFile(file));
      data.releases.push({platform:asset.platform,arch:asset.arch,format:asset.format,version:info.version,build:info.build,
        package_id:'cn.uuze.botmanager',size,sha256:hash,url:'https://github.com/'+repository+'/releases/download/'+info.tag+'/'+asset.name,notes,force_update:false});
      files.push({file,name:asset.name,hash});
    }
    const windows=await json(join(packages,'windows-x64-packages','qqbotmanager-windows-v'+info.version+'-build'+info.build+'-build-info.json'));
    assert(windows.build===info.build&&windows.version===info.version&&windows.update_public_key===publicKey&&windows.update_server===pagesUrl,'Windows 包版本或更新配置不一致');
    let envelope=signManifest(data,secret,publicKey);
    const existingManifest=release.assets.find(a=>a.name===manifestName);
    if(existingManifest) {
      const directory=await mkdtemp(join(tmpdir(),'qqm-existing-manifest-'));
      gh('release','download',info.tag,'--repo',repository,'--pattern',manifestName,'--dir',directory);
      const existing=await json(join(directory,manifestName));
      assert(JSON.stringify(verifyManifest(existing,publicKey))===JSON.stringify(data),'已经签名的版本不能改写');envelope=existing;
    }
    const manifestPath=join(packages,manifestName);await writeFile(manifestPath,JSON.stringify(envelope));
    files.push({file:manifestPath,name:manifestName,hash:sha256(await readFile(manifestPath))});
    // No clobber, no moving tags. The signed manifest is uploaded LAST, only
    // after all four package hashes have been checked.
    for(const file of files) {
      const existing=release.assets.find(a=>a.name===file.name);
      if(existing) {
        const directory=await mkdtemp(join(tmpdir(),'qqm-existing-asset-'));
        gh('release','download',info.tag,'--repo',repository,'--pattern',file.name,'--dir',directory);
        assert(sha256(await readFile(join(directory,file.name)))===file.hash,'已有附件内容不同，请发布更高版本');
      } else gh('release','upload',info.tag,file.file,'--repo',repository);
    }
    await syncAndBuildWebsite({data,envelope});
    console.log('四端安装包与签名清单已发布到 '+repository+' '+info.tag+'。');
  } else if(command==='pages') {
    await syncAndBuildWebsite(await newestSignedRelease());
  } else throw new Error('用法：node tool/github_release.mjs preflight|publish|pages');
} catch(error) {
  console.error('GitHub 发布未完成：'+(error instanceof Error?error.message.split('\n')[0]:'未知错误'));
  process.exitCode=1;
}
