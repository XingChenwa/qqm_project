import {readdir, readFile, writeFile, mkdir, realpath} from 'node:fs/promises';
import {resolve, join, extname} from 'node:path';
import {execFileSync, spawnSync} from 'node:child_process';
import {repository, websiteBranch, verifyManifest} from './github_release_core.mjs';

const assert = (value,message) => {if (!value) throw new Error(message);};
const git = (directory,...args) => execFileSync('git',['-C',directory,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();

export async function assertPublicTree(directory, root = true) {
  for (const entry of await readdir(directory,{withFileTypes:true})) {
    if (root && entry.name === '.git') continue;
    assert(!entry.isSymbolicLink(), '网站不能包含符号链接');
    if (entry.isDirectory()) {
      assert(root && ['assets','updates'].includes(entry.name), '网站出现未允许的目录');
      await assertPublicTree(join(directory,entry.name),false);
    } else {
      assert(entry.isFile() && (entry.name === '.nojekyll' || (root && entry.name === 'README.md') ||
        ['.html','.css','.js','.png','.ico','.svg','.json'].includes(extname(entry.name))), '网站出现非网页文件');
      assert(!/(?:secret|private|config|credential|token)/i.test(entry.name), '禁止发布私密配置');
      if (['.html','.css','.js','.json','.md'].includes(extname(entry.name))) {
        const text = await readFile(join(directory,entry.name),'utf8');
        assert(!/-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b/.test(text), '网页包含疑似私钥或令牌');
      }
    }
  }
}

// Only generated metadata is changed. Hand-written HTML/CSS on docs stays intact.
export async function syncWebsiteMetadata({directory,publicKey,selected,push=true}) {
  const target = await realpath(resolve(directory));
  assert(await realpath(git(target,'rev-parse','--show-toplevel')) === target, '网站目录不是独立 checkout');
  const remote = git(target,'remote','get-url','origin');
  assert(['git@github.com:'+repository+'.git','https://github.com/'+repository+'.git','https://github.com/'+repository].includes(remote), '拒绝向其他仓库同步');
  assert(git(target,'status','--porcelain') === '', '网站有本地改动，请使用干净 checkout');
  assert(git(target,'branch','--show-current') === websiteBranch, '网站必须位于 docs 分支');
  await assertPublicTree(target);
  const data = selected ? verifyManifest(selected.envelope,publicKey) : null;
  if (selected) assert(JSON.stringify(data) === JSON.stringify(selected.data), '首页资料与签名清单不一致');
  const stablePath = join(target,'updates','stable.json');
  try {
    const envelope = JSON.parse(await readFile(stablePath,'utf8'));
    const previous = verifyManifest(envelope,publicKey);
    assert(data && data.build >= previous.build, '拒绝将已发布清单变为空或回退版本');
    if (data.build === previous.build) assert(selected.envelope.payload === envelope.payload, '同一构建号不能改写');
  } catch(error) {if(error.code !== 'ENOENT') throw error;}
  if (!data) {
    try {
      const previous = JSON.parse(await readFile(join(target,'releases.json'),'utf8'));
      assert(Array.isArray(previous.releases) && previous.releases.length === 0, '拒绝清空已有下载信息');
    } catch(error) {if(error.code !== 'ENOENT') throw error;}
  }
  await writeFile(join(target,'releases.json'),JSON.stringify(data ?? {releases:[]}) + '\n');
  const paths = ['releases.json'];
  if (selected) {
    await mkdir(join(target,'updates'),{recursive:true});
    await writeFile(stablePath,JSON.stringify(selected.envelope) + '\n');
    paths.push('updates/stable.json');
  }
  git(target,'add','--',...paths);
  const changed = spawnSync('git',['-C',target,'diff','--cached','--quiet'],{stdio:'ignore'});
  assert([0,1].includes(changed.status), '无法检查网页改动');
  if (changed.status === 0) return false;
  git(target,'-c','user.name=qqm-release-bot','-c','user.email=41898282+github-actions[bot]@users.noreply.github.com',
    'commit','-m','site: sync '+(data?.tag ?? 'download metadata'));
  if (push) git(target,'push','origin','HEAD:'+websiteBranch);
  return true;
}
