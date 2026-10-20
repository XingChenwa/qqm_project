import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {assetDefinitions, repository, sha256, signManifest} from '../github_release_core.mjs';
import {mirrorRelease, trustedMirrorUrl, gitCodeReleaseStatus} from '../gitcode_release.mjs';

const keys = generateKeyPairSync('ed25519');
const secret = keys.privateKey.export({type: 'pkcs8', format: 'der'}).subarray(-32).toString('base64');
const publicKey = keys.publicKey.export({type: 'spki', format: 'der'}).subarray(-32).toString('base64');
const content = Buffer.from('offline fixture, never execute');
const data = {schema: 2, repository, tag: 'v1.3.8', version: '1.3.8', build: 19,
  published_at: Math.floor(Date.now()/1000), releases: assetDefinitions('1.3.8', 19).map(asset => ({
    ...asset, version: '1.3.8', build: 19, package_id: 'cn.uuze.botmanager',
    size: content.length, sha256: sha256(content), notes: '', force_update: false,
    url: `https://github.com/${repository}/releases/download/v1.3.8/${asset.name}`,
  }))};
const envelope = signManifest(data, secret, publicKey);

test('GitCode 上传和公共下载分别限定主机，拒绝 HTTP / 私网 / 用户信息', () => {
  assert.ok(trustedMirrorUrl('https://file.gitcode.com/project/file?signature=fixture', {upload: true}));
  assert.ok(trustedMirrorUrl('https://file-cdn.gitcode.com/file'));
  for (const url of ['http://file.gitcode.com/file', 'https://evil.invalid/file',
    'https://file.gitcode.com.evil.invalid/file', 'https://127.0.0.1/file',
    'https://user:pass@file.gitcode.com/file', 'https://file.gitcode.com:8443/file']) {
    assert.equal(trustedMirrorUrl(url, {upload: true}), false);
  }
});

async function fixture(t, {corrupt = false, redirect = false, badUpload = false, releaseData = data} = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'qqm-gitcode-unit-'));
  t.after(() => rm(directory, {recursive: true}));
  const files = [];
  for (const asset of assetDefinitions(releaseData.version, releaseData.build)) {
    const file = join(directory, asset.name);
    await writeFile(file, content); files.push({file, name: asset.name});
  }
  const uploaded = new Map(), calls = [];
  const signed = signManifest(releaseData, secret, publicKey);
  const state = {files, uploaded, calls, release: null, latest: null, previous: [],
    sourceRelease: {tagName: releaseData.tag, isDraft: false, isPrerelease: releaseData.channel === 'beta'},
    failUploadAt: 0, uploadAttempts: 0, failFailureNotice: false, failReadName: '', onDownload: null};
  const record = metadata => ({tag_name: releaseData.tag, target_commitish: 'offline-commit',
    created_at: '2026-10-21T00:00:00Z', assets: [], ...metadata});
  state.seedComplete = (metadata = {}) => {
    for (const file of files) uploaded.set(file.name, content);
    uploaded.set('update-manifest.json', Buffer.from(JSON.stringify(signed)));
    state.release = record({name: '手动维护的名称', body: '手动维护的说明，不得覆盖',
      release_status: releaseData.channel === 'beta' ? 'pre' : 'latest',
      prerelease: releaseData.channel === 'beta',
      assets: [...uploaded.keys()].map(name => ({type: 'attach', name})), ...metadata});
  };
  const json = (value, status = 200) => new Response(JSON.stringify(value), {status});
  const request = async (input, options = {}) => {
    const url = new URL(input); calls.push({url, options});
    if (url.hostname === 'api.gitcode.com' && !url.pathname.endsWith('/download')) {
      assert.equal(url.searchParams.get('access_token'), 'test-publisher-token');
    } else {
      assert.equal(url.searchParams.has('access_token'), false);
      assert.equal(Object.keys(options.headers ?? {}).some(key => /authorization/i.test(key)), false);
    }
    if (url.pathname.endsWith('/latest')) return state.latest || state.release
      ? json(state.latest ?? state.release) : json({error_message: '未找到 release'}, 400);
    if (url.pathname.includes('/tags/')) return state.release
      ? json(state.release) : json({error_message: '未找到 release'}, 400);
    if (url.pathname.endsWith('/releases') && (!options.method || options.method === 'GET')) {
      return json(state.previous.length ? state.previous : [state.release].filter(Boolean));
    }
    if (url.pathname.endsWith('/branches')) return json([]);
    if (url.pathname.endsWith('/contents/README.md')) {
      const body = JSON.parse(options.body);
      assert.equal(body.branch, 'main');
      assert.ok(Buffer.from(body.content, 'base64').toString().includes('国内下载镜像'));
      return json({commit: {sha: 'fixture-only'}});
    }
    if (options.method === 'PATCH') {
      const update = JSON.parse(options.body);
      assert.equal(update.release_status, releaseData.channel === 'beta' ? 'pre' : 'latest');
      if (state.failFailureNotice && update.body.includes('同步失败')) throw new Error('fixture failure-note transport');
      state.release = {...state.release, ...update, prerelease: update.release_status === 'pre'};
      return json(state.release);
    }
    if (options.method === 'POST') {
      const created = JSON.parse(options.body);
      assert.equal(created.release_status, releaseData.channel === 'beta' ? 'pre' : 'latest');
      state.release = record({...created, prerelease: created.release_status === 'pre'});
      return json(state.release);
    }
    if (url.pathname.endsWith('/upload_url')) {
      return json({url: `https://${badUpload ? 'evil.invalid' : 'file.gitcode.com'}/${url.searchParams.get('file_name')}`,
        headers: {'Content-Type': 'application/octet-stream', 'x-obs-acl': 'private'}});
    }
    if (options.method === 'PUT') {
      if (++state.uploadAttempts === state.failUploadAt) return new Response('', {status: 503});
      uploaded.set(url.pathname.slice(1), Buffer.from(options.body));
      state.release.assets.push({type: 'attach', name: url.pathname.slice(1)});
      return new Response('', {status: 200});
    }
    if (url.pathname.endsWith('/download')) {
      if (redirect) return new Response('', {status: 302, headers: {location: 'https://127.0.0.1/evil'}});
      const name = url.pathname.split('/').at(-2);
      state.onDownload?.(name);
      if (state.failReadName === name) return new Response('', {status: 503});
      return new Response(corrupt ? 'tampered file' : uploaded.get(name));
    }
    throw new Error('Unexpected fixture request');
  };
  state.request = request;
  return state;
}

test('正式版从创建起就是 latest，清单最后上传，读回后才清除未完成提示', async t => {
  const state = await fixture(t);
  await mirrorRelease({token: 'test-publisher-token', envelope, publicKey, ...state});
  assert.equal([...state.uploaded.keys()].at(-1), 'update-manifest.json');
  assert.deepEqual(JSON.parse(state.uploaded.get('update-manifest.json')), envelope);
  assert.equal(state.calls.at(-1).options.method, 'PATCH');
  assert.equal(state.calls.filter(call => call.options.method === 'PUT').length, 5);
  const create = state.calls.find(call => call.options.method === 'POST' && call.url.pathname.endsWith('/releases'));
  assert.equal(JSON.parse(create.options.body).release_status, 'latest');
  assert.match(JSON.parse(create.options.body).body, /未完成/);
  assert.equal(state.release.release_status, 'latest');
  assert.equal(state.release.prerelease, false);
  assert.doesNotMatch(state.release.body, /qqm-mirror-v2|未完成/);
  const finish = state.calls.findIndex(call => call.options.method === 'PATCH' && !JSON.parse(call.options.body).body.includes('qqm-mirror-v2'));
  const manifestRead = state.calls.findIndex(call => call.url.pathname.endsWith('/update-manifest.json/download'));
  assert.ok(finish > manifestRead);
});

for (const options of [{corrupt: true}, {redirect: true}, {badUpload: true}]) {
  test('镜像校验失败保留正确正式类型和失败说明，不公开签名清单：' + JSON.stringify(options), async t => {
    const state = await fixture(t, options);
    await assert.rejects(mirrorRelease({token: 'test-publisher-token', envelope, publicKey, ...state}));
    assert.equal(state.release.release_status, 'latest');
    assert.equal(state.release.prerelease, false);
    assert.match(state.release.body, /同步失败或校验未完成/);
    assert.equal(state.uploaded.has('update-manifest.json'), false);
    assert.equal(state.calls.some(call => call.options.method === 'DELETE'), false);
    assert.equal(state.calls.some(call => call.url.hostname === '127.0.0.1' || call.url.hostname === 'evil.invalid'), false);
  });
}

test('缺令牌、源包不匹配或签名错误时不会开始网络发布', async t => {
  const state = await fixture(t);
  await assert.rejects(mirrorRelease({token: '', envelope, publicKey, ...state}));
  await assert.rejects(mirrorRelease({token: 'test-publisher-token', envelope: {...envelope, signature: Buffer.alloc(64).toString('base64')}, publicKey, ...state}));
  await writeFile(state.files[0].file, 'tampered local package');
  await assert.rejects(mirrorRelease({token: 'test-publisher-token', envelope, publicKey, ...state}));
  assert.equal(state.calls.length, 0);
});
test('完整 Beta 镜像读回后仍为 PRE，不占用正式 latest',async t=>{
  const beta=structuredClone(data);beta.channel='beta';
  const state=await fixture(t,{releaseData:beta});
  await mirrorRelease({token:'test-publisher-token',envelope:signManifest(beta,secret,publicKey),publicKey,...state});
  assert.equal(state.uploaded.size,5);
  assert.equal(JSON.parse(state.calls.at(-1).options.body).release_status,'pre');
  const writes=state.calls.filter(call=>['POST','PATCH'].includes(call.options.method)&&call.url.pathname.includes('/releases'));
  assert.ok(writes.every(call=>JSON.parse(call.options.body).release_status==='pre'));
});

test('渠道以 GitHub Pre-release 开关为准，不按标签名称推断', () => {
  assert.equal(gitCodeReleaseStatus({tagName: data.tag, isDraft: false, isPrerelease: false}, data), 'latest');
  assert.equal(gitCodeReleaseStatus({tagName: data.tag, isDraft: false, isPrerelease: true}, {...data, channel: 'beta'}), 'pre');
  assert.throws(() => gitCodeReleaseStatus({tagName: data.tag, isDraft: false, isPrerelease: true}, data), /渠道不一致/);
});

for (const sourceRelease of [undefined, {tagName: 'v9.9.9', isDraft: false, isPrerelease: false},
  {tagName: data.tag, isDraft: true, isPrerelease: false}, {tagName: data.tag, isDraft: false},
  {tagName: data.tag, isDraft: false, isPrerelease: true}]) {
  test('GitHub 元数据缺失、草稿或与签名渠道不一致时不写入 GitCode：'+JSON.stringify(sourceRelease), async t => {
    const state=await fixture(t);
    await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state,sourceRelease}));
    assert.equal(state.calls.length,0);
  });
}

for (const beta of [false,true]) {
  test(`上传失败不把 ${beta?'Beta':'正式版'} 转成另一渠道，可恢复重试且不重复上传已有附件`, async t => {
    const releaseData={...data,channel:beta?'beta':'stable'};
    const signed=signManifest(releaseData,secret,publicKey);
    const state=await fixture(t,{releaseData});state.failUploadAt=2;
    await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope:signed,publicKey,...state}),/HTTP 503/);
    assert.equal(state.release.release_status,beta?'pre':'latest');
    assert.equal(state.release.prerelease,beta);
    assert.match(state.release.body,/同步失败/);
    assert.equal(state.uploaded.size,1);
    assert.equal(state.uploaded.has('update-manifest.json'),false);
    const firstFile=[...state.uploaded.keys()][0];
    await mirrorRelease({token:'test-publisher-token',envelope:signed,publicKey,...state});
    assert.equal(state.uploaded.size,5);
    assert.equal(state.calls.filter(call=>call.options.method==='PUT'&&call.url.pathname===`/${firstFile}`).length,1);
    assert.equal(state.calls.filter(call=>call.options.method==='POST'&&call.url.pathname.endsWith('/releases')).length,1);
    assert.doesNotMatch(state.release.body,/未完成|同步失败/);
  });
}

test('失败说明也写入失败时仍保留正确类型和创建时的未完成提示',async t=>{
  const state=await fixture(t);state.failUploadAt=1;state.failFailureNotice=true;
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/失败提示写入失败/);
  assert.equal(state.release.release_status,'latest');
  assert.equal(state.release.prerelease,false);
  assert.match(state.release.body,/未完成/);
  assert.equal(state.uploaded.size,0);
});

test('签名清单读回失败不报告完成，保留正式类型和失败提示',async t=>{
  const state=await fixture(t);state.failReadName='update-manifest.json';
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/公共资源读取失败/);
  assert.equal(state.uploaded.size,5);
  assert.equal(state.release.release_status,'latest');
  assert.match(state.release.body,/同步失败或校验未完成/);
});

test('已手动完成且渠道正确的发布只校验，不修改名称、说明、类型或附件',async t=>{
  const state=await fixture(t);state.seedComplete();
  const original=structuredClone(state.release);
  await mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state});
  assert.deepEqual(state.release,original);
  assert.equal(state.calls.some(call=>['POST','PATCH','PUT','DELETE'].includes(call.options.method)),false);
});

test('修复旧正式版 PRE 占位后上传失败也不会再次留下错误的 PRE',async t=>{
  const state=await fixture(t);
  state.release={tag_name:data.tag,name:'原名称',body:'原说明',target_commitish:'offline-commit',
    created_at:'2026-10-21T00:00:00Z',assets:[],release_status:'pre',prerelease:true};
  state.failUploadAt=1;
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/HTTP 503/);
  assert.equal(state.release.release_status,'latest');
  assert.equal(state.release.prerelease,false);
  assert.equal(state.release.name,'原名称');assert.equal(state.release.body,'原说明');
});

test('已有清单不同不改标签、发布类型或文件',async t=>{
  const state=await fixture(t);state.seedComplete();
  state.uploaded.set('update-manifest.json',Buffer.from(JSON.stringify(signManifest({...data,build:20,releases:data.releases.map(r=>({...r,build:20}))},secret,publicKey))));
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}));
  assert.equal(state.calls.some(call=>['POST','PATCH','PUT','DELETE'].includes(call.options.method)),false);
});

test('未完成的 latest 不能遮住同渠道较新的签名版本，仍拒绝回退',async t=>{
  const state=await fixture(t);
  state.latest={tag_name:'v1.3.9',release_status:'latest',prerelease:false,assets:[]};
  const newer={...data,build:20,releases:data.releases.map(r=>({...r,build:20}))};
  state.previous=[{tag_name:data.tag,release_status:'latest',prerelease:false,
    assets:[{name:'update-manifest.json',type:'attach'}]}];
  state.uploaded.set('update-manifest.json',Buffer.from(JSON.stringify(signManifest(newer,secret,publicKey))));
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/拒绝将 GitCode 最新版本回退/);
  assert.equal(state.calls.some(call=>['POST','PATCH','PUT','DELETE'].includes(call.options.method)),false);
});

test('旧正式版即使被错标 PRE，其签名构建号仍参与正式渠道回滚保护',async t=>{
  const state=await fixture(t);
  state.latest={tag_name:data.tag,release_status:'pre',prerelease:true,
    assets:[{name:'update-manifest.json',type:'attach'}]};
  state.previous=[state.latest];
  const newer={...data,build:20,releases:data.releases.map(r=>({...r,build:20}))};
  state.uploaded.set('update-manifest.json',Buffer.from(JSON.stringify(signManifest(newer,secret,publicKey))));
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/拒绝将 GitCode 最新版本回退/);
  assert.equal(state.calls.some(call=>['POST','PATCH','PUT','DELETE'].includes(call.options.method)),false);
});

test('已有文件内容不一致时只报错，不覆盖或删除原附件',async t=>{
  const state=await fixture(t);state.seedComplete();
  state.uploaded.set(state.files[0].name,Buffer.from('tampered remote file'));
  const original=structuredClone(state.release);
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/内容不同或上传校验失败/);
  assert.deepEqual(state.release,original);
  assert.equal(state.calls.some(call=>['POST','PATCH','PUT','DELETE'].includes(call.options.method)),false);
});

test('运行中用户手动更改发布说明时，失败处理不覆盖用户修改或删除发布',async t=>{
  const state=await fixture(t);
  state.onDownload=()=>{state.release.body='用户已接管，请勿修改';state.failReadName=state.files[0].name;};
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}));
  assert.equal(state.release.body,'用户已接管，请勿修改');
  assert.equal(state.calls.some(call=>['PATCH','DELETE'].includes(call.options.method)),false);
});

test('运行中发布被用户删除重建后不改动替代发布',async t=>{
  const state=await fixture(t);
  state.onDownload=()=>{state.release.created_at='2026-10-21T01:00:00Z';state.release.body='用户重建的发布';};
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state}),/已被替换/);
  assert.equal(state.release.body,'用户重建的发布');
  assert.equal(state.calls.some(call=>['PATCH','DELETE'].includes(call.options.method)),false);
});

test('完成前重新核对 GitHub，渠道切换后不报告同步成功',async t=>{
  const state=await fixture(t);
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state,
    refreshSource:()=>({...state.sourceRelease,isPrerelease:true})}),/渠道不一致/);
  assert.match(state.release.body,/同步失败/);
  assert.equal(state.release.prerelease,false);
});

test('上传异常和失败说明不泄露令牌或临时上传地址',async t=>{
  const state=await fixture(t);
  await assert.rejects(mirrorRelease({token:'test-publisher-token',envelope,publicKey,...state,
    uploader:()=>{throw new Error('test-publisher-token https://file.gitcode.com/private?signature=private-value');}}),error=>{
      assert.doesNotMatch(error.message,/test-publisher-token|signature=|private-value/);return true;
    });
  assert.doesNotMatch(state.release.body,/test-publisher-token|private-value/);
});

test('自动发布与手动镜像共用不取消运行的 GitCode 并发锁',async()=>{
  for(const path of ['.github/workflows/mobile-build.yml','.github/workflows/gitcode-mirror.yml']) {
    const workflow=await readFile(new URL('../../'+path,import.meta.url),'utf8');
    assert.match(workflow,/concurrency:\s*\n\s+group: project-gitcode-sync\s*\n\s+cancel-in-progress: false/);
  }
});
