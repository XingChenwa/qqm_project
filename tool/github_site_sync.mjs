import {readdir, readFile, cp, realpath} from 'node:fs/promises';
import {resolve, join, extname} from 'node:path';
import {execFileSync, spawnSync} from 'node:child_process';
import {repository, sourceRepository, verifyManifest} from './github_release_core.mjs';

const assert = (value,message) => {if (!value) throw new Error(message);};
const git = (directory,...args) => execFileSync('git',['-C',directory,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();

export async function assertPublicTree(directory) {
  for (const entry of await readdir(directory,{withFileTypes:true})) {
    assert(!entry.isSymbolicLink(), '公开网站不能包含符号链接');
    if (entry.isDirectory()) {
      assert(['assets','updates'].includes(entry.name), '公开网站出现未允许的目录');
      await assertPublicTree(join(directory,entry.name));
    } else {
      assert(entry.isFile() && (entry.name === '.nojekyll' ||
        ['.html','.css','.js','.png','.ico','.svg','.json'].includes(extname(entry.name))), '公开网站出现非网页文件');
      assert(!/(?:secret|private|config|credential|token)/i.test(entry.name), '禁止将私密配置同步到公开仓库');
      if (['.html','.css','.js','.json'].includes(extname(entry.name))) {
        const text = await readFile(join(directory,entry.name),'utf8');
        assert(!text.includes(sourceRepository), '公开网页不能包含私有源码仓库路径');
        assert(!/-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b/.test(text), '公开网页包含疑似私钥或令牌');
      }
    }
  }
}

export async function syncPublicSite({directory,pagesDirectory,publicKey,selected,push=true}) {
  const target = await realpath(resolve(directory));
  assert(await realpath(git(target,'rev-parse','--show-toplevel')) === target, '下载仓库目录不是独立 checkout');
  const remote = git(target,'remote','get-url','origin');
  assert([`git@github.com:${repository}.git`,`https://github.com/${repository}.git`].includes(remote), '拒绝向非公开下载仓库同步');
  assert(git(target,'status','--porcelain') === '', '下载仓库有本地改动，请使用干净 checkout');
  assert(git(target,'branch','--show-current') === 'main', '公开下载仓库必须位于 main 分支');
  await assertPublicTree(pagesDirectory);
  const existing = join(target,'site','updates','stable.json');
  try {
    const previous = verifyManifest(JSON.parse(await readFile(existing,'utf8')),publicKey);
    assert(selected && selected.build >= previous.build, '拒绝将已发布清单变为空或回退版本');
  } catch(error) {if(error.code !== 'ENOENT') throw error;}
  await cp(pagesDirectory,join(target,'site'),{recursive:true,dereference:false});
  git(target,'add','--','site');
  const changed = spawnSync('git',['-C',target,'diff','--cached','--quiet'],{stdio:'ignore'});
  assert([0,1].includes(changed.status), '无法检查公开网页改动');
  if (changed.status === 0) return false;
  git(target,'-c','user.name=qqm-release-bot','-c','user.email=41898282+github-actions[bot]@users.noreply.github.com',
    'commit','-m',`site: sync ${selected?.tag ?? 'download homepage'}`);
  if (push) git(target,'push','origin','HEAD:main');
  return true;
}
