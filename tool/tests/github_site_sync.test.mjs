import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {generateKeyPairSync} from 'node:crypto';
import {assertPublicTree, syncWebsiteMetadata} from '../github_site_sync.mjs';
import {repository, assetDefinitions, sha256, signManifest} from '../github_release_core.mjs';
const git = (directory,...args) => execFileSync('git',['-C',directory,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
const keys = generateKeyPairSync('ed25519');
const secret = keys.privateKey.export({type:'pkcs8',format:'der'}).subarray(-32).toString('base64');
const publicKey = keys.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64');
function selected(build=18) {
  const data = {schema:2,repository,tag:'v1.3.7',version:'1.3.7',build,published_at:Math.floor(Date.now()/1000),
    releases:assetDefinitions('1.3.7',build).map(a=>({platform:a.platform,arch:a.arch,format:a.format,package_id:'cn.uuze.botmanager',version:'1.3.7',build,
      size:12,sha256:sha256('fixture'),url:'https://github.com/'+repository+'/releases/download/v1.3.7/'+a.name,notes:'test',force_update:false}))};
  return {data,envelope:signManifest(data,secret,publicKey)};
}
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(),'qqm-docs-sync-test-'));
  t.after(async()=>{assert.ok(root.startsWith(join(tmpdir(),'qqm-docs-sync-test-')));await rm(root,{recursive:true});});
  const checkout=join(root,'checkout');await mkdir(checkout);
  git(checkout,'init','-b','docs');git(checkout,'remote','add','origin','https://github.com/'+repository+'.git');
  await writeFile(join(checkout,'README.md'),'website branch');
  await writeFile(join(checkout,'index.html'),'<h1>手工编辑的首页 '+repository+'</h1>');
  await mkdir(join(checkout,'assets'));
  await writeFile(join(checkout,'assets','site.css'),'/* 手写样式 */');
  git(checkout,'add','.');git(checkout,'-c','user.name=test','-c','user.email=test@example.invalid','commit','-m','fixture');
  return {root,checkout};
}
test('仅更新根目录版本 JSON，保留手工网页与 README；重复运行不提交',async t=>{
  const f=await fixture(t), options={directory:f.checkout,push:false};
  assert.equal(await syncWebsiteMetadata(options),true);
  assert.equal(await readFile(join(f.checkout,'releases.json'),'utf8'),'{"releases":[]}\n');
  assert.match(await readFile(join(f.checkout,'index.html'),'utf8'),/手工编辑的首页/);
  assert.equal(await readFile(join(f.checkout,'assets','site.css'),'utf8'),'/* 手写样式 */');
  assert.equal(await readFile(join(f.checkout,'README.md'),'utf8'),'website branch');
  assert.equal(await syncWebsiteMetadata(options),false);
  assert.equal(git(f.checkout,'status','--porcelain'),'');
  assert.equal(git(f.checkout,'show','--pretty=format:','--name-only','HEAD'),'releases.json');
});
test('拒绝其他仓库、源码分支、有本地改动的 checkout',async t=>{
  const f=await fixture(t),options={directory:f.checkout,push:false};
  git(f.checkout,'remote','set-url','origin','https://github.com/other/repo.git');
  await assert.rejects(syncWebsiteMetadata(options),/其他仓库/);
  git(f.checkout,'remote','set-url','origin','https://github.com/'+repository+'.git');
  git(f.checkout,'branch','-m','main');
  await assert.rejects(syncWebsiteMetadata(options),/docs 分支/);
  git(f.checkout,'branch','-m','docs');
  await writeFile(join(f.checkout,'index.html'),'未保存的网页');
  await assert.rejects(syncWebsiteMetadata(options),/本地改动/);
});
test('签名更新不可清空、回退或复用构建号篡改；校验失败前不写入',async t=>{
  const f=await fixture(t),options={directory:f.checkout,publicKey,push:false},release=selected();
  assert.equal(await syncWebsiteMetadata({...options,selected:release}),true);
  assert.deepEqual(JSON.parse(await readFile(join(f.checkout,'releases.json'),'utf8')),release.data);
  assert.deepEqual(JSON.parse(await readFile(join(f.checkout,'updates','stable.json'),'utf8')),release.envelope);
  assert.equal(await syncWebsiteMetadata({...options,selected:release}),false);
  await assert.rejects(syncWebsiteMetadata(options),/变为空/);
  await assert.rejects(syncWebsiteMetadata({...options,selected:selected(17)}),/回退/);
  const altered=structuredClone(release);altered.data.releases[0].notes='same build changed';
  altered.envelope=signManifest(altered.data,secret,publicKey);
  await assert.rejects(syncWebsiteMetadata({...options,selected:altered}),/不能改写/);
  altered.envelope=release.envelope;
  await assert.rejects(syncWebsiteMetadata({...options,selected:altered}),/不一致/);
  assert.equal(git(f.checkout,'status','--porcelain'),'');
  assert.equal(await syncWebsiteMetadata({...options,selected:selected(19)}),true);
});
test('网页允许项目源码链接，但拒绝源码文件、配置、密钥和令牌',async t=>{
  const f=await fixture(t);
  await assertPublicTree(f.checkout);
  for(const [name,value] of [['config.json','{}'],['plugin.dart','source'],['index.html','-----BEGIN OPENSSH PRIVATE KEY-----'],
    ['index.html','ghp_'+'a'.repeat(40)]]) {
    await writeFile(join(f.checkout,name),value);
    await assert.rejects(assertPublicTree(f.checkout));
    if(name!=='index.html')await rm(join(f.checkout,name));
  }
});
test('docs 分支只包含静态网页，不携带工作流、源码或私密配置',{skip:!process.env.WEBSITE_DIRECTORY},async()=>{
  await assertPublicTree(process.env.WEBSITE_DIRECTORY);
  const html=await readFile(join(process.env.WEBSITE_DIRECTORY,'index.html'),'utf8');
  assert.ok(html.includes('https://github.com/'+repository));
});
