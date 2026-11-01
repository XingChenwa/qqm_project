import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {assetDefinitions,repository,manifestName,sha256,signManifest,verifyManifest,assertNotesOnlyChange} from '../github_release_core.mjs';
import {updatedNotesManifest,assertPackageAssets,replaceGitHubManifest,refreshGitCodeNotes} from '../refresh_release_notes.mjs';

const key=generateKeyPairSync('ed25519');
const secret=key.privateKey.export({type:'pkcs8',format:'der'}).subarray(-32).toString('base64');
const publicKey=key.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64');
function fixture() {
  const data={schema:2,repository,version:'1.4.1',tag:'v1.4.1',build:44,channel:'stable',published_at:Math.floor(Date.now()/1000),
    releases:assetDefinitions('1.4.1',44).map(a=>({platform:a.platform,arch:a.arch,format:a.format,package_id:'cn.uuze.botmanager',
      version:'1.4.1',build:44,size:12,sha256:sha256('original'),url:`https://github.com/${repository}/releases/download/v1.4.1/${a.name}`,notes:'旧日志',force_update:false}))};
  const envelope=signManifest(data,secret,publicKey),content=Buffer.from(JSON.stringify(envelope));
  const release={id:123,tag_name:data.tag,draft:false,prerelease:false,body:'欢迎来玩\n\n反馈群：**1134318752**。',assets:[
    ...data.releases.map((r,id)=>({id:id+1,name:new URL(r.url).pathname.split('/').at(-1),size:r.size,digest:'sha256:'+r.sha256})),
    {id:10,name:manifestName,size:content.length,digest:'sha256:'+sha256(content)},
  ]};
  return {data,envelope,content,release};
}
test('仅重新签名说明文字，保留版本、构建号、时间及全部安装元数据',()=>{
  const f=fixture(),next=updatedNotesManifest(f.envelope,f.release,publicKey,secret);
  assertNotesOnlyChange(f.data,next.data);
  assert.deepEqual(verifyManifest(next.envelope,publicKey),next.data);
  assert.ok(next.data.releases.every(r=>r.notes.includes('1134318752')));
  f.release.body=next.data.releases[0].notes;
  assert.deepEqual(updatedNotesManifest(next.envelope,f.release,publicKey,secret).envelope,next.envelope);
});
test('拒绝改变任一安装字段、未知元数据、发布时间或更新渠道',()=>{
  const f=fixture();
  for(const change of [d=>d.releases[0].sha256='b'.repeat(64),d=>d.releases[0].size++,d=>d.releases[0].force_update=true,
    d=>d.releases[0].extra='changed',d=>d.extra='changed',d=>d.published_at++,d=>d.channel='beta',d=>d.build++]) {
    const next=structuredClone(f.data);change(next);assert.throws(()=>assertNotesOnlyChange(f.data,next));
  }
  assertPackageAssets(f.data,f.release.assets);
  f.release.assets[0].digest='sha256:'+'f'.repeat(64);
  assert.throws(()=>assertPackageAssets(f.data,f.release.assets));
});
test('错误公钥、Release 标签及发布类型不得重新签名',()=>{
  const f=fixture();
  assert.throws(()=>updatedNotesManifest(f.envelope,f.release,Buffer.alloc(32).toString('base64'),secret));
  assert.throws(()=>updatedNotesManifest(f.envelope,{...f.release,prerelease:true},publicKey,secret));
  assert.throws(()=>updatedNotesManifest(f.envelope,{...f.release,tag_name:'v1.4.0'},publicKey,secret));
});
test('GitHub 先上传新清单再换名，保存旧签名，无删除或安装包写入',async()=>{
  const f=fixture(),next=updatedNotesManifest(f.envelope,f.release,publicKey,secret),calls=[];
  const content=Buffer.from(JSON.stringify(next.envelope));
  const api=async(path,options)=>calls.push({path,...options});
  const upload=async(name,bytes)=>{calls.push({upload:name});return {id:11,name,digest:'sha256:'+sha256(bytes)};};
  assert.equal(await replaceGitHubManifest({release:f.release,content,previousContent:f.content,api,upload}),true);
  assert.match(calls[0].upload,/^update-manifest-notes-[a-f0-9]{64}\.json$/);
  assert.equal(calls[1].path,'releases/assets/10');
  assert.equal(calls[2].path,'releases/assets/11');assert.equal(calls[2].body.name,manifestName);
  assert.ok(calls.slice(1).every(c=>c.method==='PATCH'));
});
test('新清单上传失败不换名；第二次改名失败自动恢复旧清单',async()=>{
  const f=fixture(),content=Buffer.from(JSON.stringify(updatedNotesManifest(f.envelope,f.release,publicKey,secret).envelope));
  let calls=[];
  await assert.rejects(replaceGitHubManifest({release:f.release,content,previousContent:f.content,api:async(...a)=>calls.push(a),upload:async()=>{throw Error('offline');}}));
  assert.equal(calls.length,0);
  await assert.rejects(replaceGitHubManifest({release:f.release,content,previousContent:f.content,
    upload:async(name,bytes)=>({id:11,name,digest:'sha256:'+sha256(bytes)}),api:async(path,opts)=>{calls.push([path,opts]);if(path.endsWith('/11'))throw Error('offline');}}));
  assert.equal(calls.length,3);assert.equal(calls[2][0],'releases/assets/10');assert.equal(calls[2][1].body.name,manifestName);
});
function mirrorFixture() {
  const f=fixture(),updated=updatedNotesManifest(f.envelope,f.release,publicKey,secret);
  let remote=f.content;const writes=[];
  const release={tag_name:'v1.4.1',release_status:'latest',prerelease:false,assets:f.release.assets.map(a=>({...a,type:'attach'}))};
  const request=async(url,options={})=>{
    assert.equal(new URL(url).host,'api.gitcode.com');assert.equal(new URL(url).searchParams.get('access_token'),'fixture-publisher');
    assert.equal(options.method,'GET');
    return new Response(JSON.stringify(new URL(url).pathname.endsWith('/upload_url')?{
      url:'https://file.gitcode.com/fixture',headers:{'Content-Type':'application/json','x-obs-acl':'public-read'},
    }:release));
  };
  const readPublic=async(url)=>{assert.equal(new URL(url).searchParams.has('access_token'),false);return remote;};
  return {...f,updated,release,request,readPublic,writes,uploader:async(d,bytes)=>{writes.push(bytes);remote=bytes;}};
}
test('GitCode 同名小清单更新后读回签名，不重新上传或删除安装包；重试幂等',async()=>{
  const f=mirrorFixture(),options={...f,envelope:f.updated.envelope,publicKey,token:'fixture-publisher'};
  await refreshGitCodeNotes(options);assert.equal(f.writes.length,1);assert.ok(f.writes[0].length<65536);
  await refreshGitCodeNotes(options);assert.equal(f.writes.length,1);
});
test('GitCode 已签名安装元数据不同或渠道错误时不执行上传',async()=>{
  const f=mirrorFixture(),altered=structuredClone(f.data);altered.releases[0].force_update=true;
  await assert.rejects(refreshGitCodeNotes({...f,envelope:signManifest(altered,secret,publicKey),publicKey,token:'fixture-publisher'}));
  assert.equal(f.writes.length,0);
  f.release.prerelease=true;f.release.release_status='pre';
  await assert.rejects(refreshGitCodeNotes({...f,envelope:f.updated.envelope,publicKey,token:'fixture-publisher'}));
  assert.equal(f.writes.length,0);
});
test('更新日志流程只触发说明编辑，不执行 Flutter 构建，也不读取客户端数据',async()=>{
  const yaml=await readFile('.github/workflows/release-notes.yml','utf8');
  assert.match(yaml,/types: \[edited\]/);assert.match(yaml,/UPDATE_SIGNING_PRIVATE_KEY/);
  assert.match(yaml,/refresh_release_notes\.mjs gitcode/);assert.doesNotMatch(yaml,/flutter build|build_windows|build_unsigned_ipa/);
});
