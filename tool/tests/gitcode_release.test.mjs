import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {mkdtemp, writeFile, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {assetDefinitions, repository, sha256, signManifest} from '../github_release_core.mjs';
import {mirrorRelease, trustedMirrorUrl} from '../gitcode_release.mjs';

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

async function fixture(t, {corrupt = false, redirect = false, badUpload = false} = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'qqm-gitcode-unit-'));
  t.after(() => rm(directory, {recursive: true}));
  const files = [];
  for (const asset of assetDefinitions('1.3.8', 19)) {
    const file = join(directory, asset.name);
    await writeFile(file, content); files.push({file, name: asset.name});
  }
  const uploaded = new Map(), calls = [];
  const json = (value, status = 200) => new Response(JSON.stringify(value), {status});
  const request = async (input, options = {}) => {
    const url = new URL(input); calls.push({url, options});
    if (url.hostname === 'api.gitcode.com' && !url.pathname.endsWith('/download')) {
      assert.equal(url.searchParams.get('access_token'), 'test-publisher-token');
    } else {
      assert.equal(url.searchParams.has('access_token'), false);
      assert.equal(Object.keys(options.headers ?? {}).some(key => /authorization/i.test(key)), false);
    }
    if (url.pathname.endsWith('/latest') || url.pathname.includes('/tags/')) {
      return json({error_message: '未找到 release'}, 400);
    }
    if (url.pathname.endsWith('/branches')) return json([]);
    if (url.pathname.endsWith('/contents/README.md')) {
      const body = JSON.parse(options.body);
      assert.equal(body.branch, 'main');
      assert.ok(Buffer.from(body.content, 'base64').toString().includes('国内下载镜像'));
      return json({commit: {sha: 'fixture-only'}});
    }
    if (options.method === 'PATCH') {
      assert.equal(uploaded.size, 5);
      assert.equal(JSON.parse(options.body).release_status, 'latest');
      return json({});
    }
    if (options.method === 'POST') {
      assert.equal(JSON.parse(options.body).release_status, 'pre');
      return json({tag_name: 'v1.3.8', assets: []});
    }
    if (url.pathname.endsWith('/upload_url')) {
      return json({url: `https://${badUpload ? 'evil.invalid' : 'file.gitcode.com'}/${url.searchParams.get('file_name')}`,
        headers: {'Content-Type': 'application/octet-stream', 'x-obs-acl': 'private'}});
    }
    if (options.method === 'PUT') {
      uploaded.set(url.pathname.slice(1), Buffer.from(options.body));
      return new Response('', {status: 200});
    }
    if (url.pathname.endsWith('/download')) {
      if (redirect) return new Response('', {status: 302, headers: {location: 'https://127.0.0.1/evil'}});
      const name = url.pathname.split('/').at(-2);
      return new Response(corrupt ? 'tampered file' : uploaded.get(name));
    }
    throw new Error('Unexpected fixture request');
  };
  return {files, request, uploaded, calls};
}

test('镜像复用原签名和四端文件，清单最后上传，读回后才标为最新版', async t => {
  const state = await fixture(t);
  await mirrorRelease({token: 'test-publisher-token', envelope, publicKey, ...state});
  assert.equal([...state.uploaded.keys()].at(-1), 'update-manifest.json');
  assert.deepEqual(JSON.parse(state.uploaded.get('update-manifest.json')), envelope);
  assert.equal(state.calls.at(-1).options.method, 'PATCH');
  assert.equal(state.calls.filter(call => call.options.method === 'PUT').length, 5);
});

for (const options of [{corrupt: true}, {redirect: true}, {badUpload: true}]) {
  test('镜像校验失败不推进 latest：' + JSON.stringify(options), async t => {
    const state = await fixture(t, options);
    await assert.rejects(mirrorRelease({token: 'test-publisher-token', envelope, publicKey, ...state}));
    assert.equal(state.calls.some(call => call.options.method === 'PATCH'), false);
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
