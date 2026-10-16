import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm, symlink} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {assertPublicTree, syncPublicSite} from '../github_site_sync.mjs';
import {repository, sourceRepository} from '../github_release_core.mjs';
const git = (directory,...args) => execFileSync('git',['-C',directory,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(),'qqm-public-sync-test-'));
  t.after(async () => {assert.ok(root.startsWith(join(tmpdir(),'qqm-public-sync-test-')));await rm(root,{recursive:true});});
  const checkout = join(root,'checkout'), pages = join(root,'pages');
  await mkdir(checkout);await mkdir(pages);
  git(checkout,'init','-b','main');git(checkout,'remote','add','origin','git@github.com:' + repository + '.git');
  await writeFile(join(checkout,'README.md'),'public repository only');
  git(checkout,'add','README.md');git(checkout,'-c','user.name=test','-c','user.email=test@example.invalid','commit','-m','fixture');
  await writeFile(join(pages,'index.html'),'<h1>Downloads</h1>');
  return {root,checkout,pages};
}
test('仅同步网页，保留 README；重复运行没有额外提交',async t => {
  const f = await fixture(t);
  assert.equal(await syncPublicSite({directory:f.checkout,pagesDirectory:f.pages,push:false}),true);
  assert.equal(await readFile(join(f.checkout,'site','index.html'),'utf8'),'<h1>Downloads</h1>');
  assert.equal(await readFile(join(f.checkout,'README.md'),'utf8'),'public repository only');
  assert.equal(await syncPublicSite({directory:f.checkout,pagesDirectory:f.pages,push:false}),false);
  assert.equal(git(f.checkout,'status','--porcelain'),'');
});
test('拒绝向私有源码仓库推送；拒绝下载仓库本地未提交内容',async t => {
  const f = await fixture(t);
  git(f.checkout,'remote','set-url','origin','https://github.com/' + sourceRepository + '.git');
  await assert.rejects(syncPublicSite({directory:f.checkout,pagesDirectory:f.pages,push:false}),/非公开下载仓库/);
  git(f.checkout,'remote','set-url','origin','https://github.com/' + repository + '.git');
  await writeFile(join(f.checkout,'unrelated.txt'),'do not commit');
  await assert.rejects(syncPublicSite({directory:f.checkout,pagesDirectory:f.pages,push:false}),/本地改动/);
});
test('公开树拒绝源码、私有仓库路径、配置文件、密钥和令牌',async t => {
  const f = await fixture(t);
  for (const [name,value] of [['config.json','{}'],['plugin.dart','source'],['index.html',sourceRepository],
    ['index.html','-----BEGIN OPENSSH PRIVATE KEY-----'],['index.html','ghp_' + 'a'.repeat(40)]]) {
    await writeFile(join(f.pages,name),value);
    await assert.rejects(assertPublicTree(f.pages));
    if(name !== 'index.html') await rm(join(f.pages,name));
  }
});
test('公开输出只来自 site；工作流模板不包含私有仓库或发布密钥',async () => {
  const workflow = await readFile('deploy/github-distribution/pages.yml','utf8');
  assert.ok(!workflow.includes(sourceRepository) && !workflow.includes('secrets.'));
  assert.match(workflow,/path: site/);
  await assertPublicTree(resolve('site'));
});
