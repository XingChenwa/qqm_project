import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {repository, readVersion, signingKeys, assetDefinitions, sha256, signManifest, verifyManifest, validateManifest, trustedAsset} from '../github_release_core.mjs';

const keys = generateKeyPairSync('ed25519');
const seed = keys.privateKey.export({type: 'pkcs8', format: 'der'}).subarray(-32);
const pub = keys.publicKey.export({type: 'spki', format: 'der'}).subarray(-32);
const publicKey = pub.toString('base64');
const secret = seed.toString('base64');
function fixture() {
  return {schema: 2, repository, tag: 'v1.3.7', version: '1.3.7', build: 18, published_at: Math.floor(Date.now()/1000),
    releases: assetDefinitions('1.3.7', 18).map(a => ({platform: a.platform, arch: a.arch, format: a.format, package_id: 'cn.uuze.botmanager', version: '1.3.7', build: 18,
      size: 12, sha256: sha256('fixture-only'), url: `https://github.com/${repository}/releases/download/v1.3.7/${a.name}`, notes: '测试：不是可执行安装包', force_update: false}))};
}
test('支持原 PHP/libsodium 私钥和 32 字节种子，公钥必须匹配', () => {
  assert.ok(signingKeys(secret, publicKey));
  assert.ok(signingKeys(Buffer.concat([seed, pub]).toString('base64'), publicKey));
  assert.throws(() => signingKeys(Buffer.concat([seed, Buffer.alloc(32)]).toString('base64'), publicKey));
  assert.throws(() => signingKeys(secret, Buffer.alloc(32).toString('base64')));
  assert.throws(() => signingKeys('not a key', publicKey));
});
test('签名清单校验、篡改和回退防护', () => {
  const data = fixture(); const envelope = signManifest(data, secret, publicKey);
  assert.deepEqual(verifyManifest(envelope, publicKey, 18), data);
  assert.throws(() => verifyManifest(envelope, publicKey, 19));
  assert.throws(() => verifyManifest({...envelope, payload: Buffer.from('{}').toString('base64')}, publicKey));
  assert.throws(() => verifyManifest({...envelope, signature: Buffer.alloc(64).toString('base64')}, publicKey));
  assert.throws(() => verifyManifest(envelope, Buffer.alloc(32).toString('base64')));
});
test('拒绝缺平台、重复平台、跨仓库、恶意跳转、无效包身份及未来时间', () => {
  for (const change of [d => d.releases.pop(), d => d.releases[1] = d.releases[0], d => d.repository = 'someone/else', d => d.build = 0,
    d => d.published_at += 172800, d => d.tag = 'v1.3.8', d => d.releases[0].build++, d => d.releases[0].size = 1073741825,
    d => d.releases[0].package_id = 'evil', d => d.releases[0].url = 'https://github.com.evil.invalid/setup.exe',
    d => d.releases[0].url = `https://github.com/${repository}/releases/download/v1.3.8/setup.exe`,
    d => d.releases[0].url += '?target=evil', d => d.releases[0].url += '#fragment']) {
    const data = fixture(); change(data); assert.throws(() => validateManifest(data));
  }
  assert.equal(trustedAsset('https://user:pass@github.com/XingChenwa/qqm_project/releases/download/v1.3.7/setup.exe', 'v1.3.7'), false);
});
test('清单体积限制及源码版本一致性', async () => {
  const data = fixture(); data.releases[0].notes = 'x'.repeat(4001); assert.throws(() => signManifest(data, secret, publicKey));
  const info = readVersion(await readFile('pubspec.yaml', 'utf8'), await readFile('lib/utils/constants.dart', 'utf8'));
  assert.match(info.tag, /^v\d+\.\d+\.\d+$/);
  assert.throws(() => readVersion('version: 1.3.7+18', "appVersion = '1.3.7'; appBuild = 17;"));
});
test('GitHub 发布需要四端完成、签名并部署 Pages；手动构建不直接发布', async () => {
  const workflow = await readFile('.github/workflows/mobile-build.yml', 'utf8');
  assert.match(workflow, /release:\s+types: \[published\]/);
  assert.match(workflow, /needs: \[preflight, android, ios, macos, windows\]/);
  assert.match(workflow, /publish:\s+needs:[^\n]+\s+if: github.event_name == 'release'/);
  assert.match(workflow, /UPDATE_SIGNING_PRIVATE_KEY/);
  assert.ok(!workflow.includes('PUBLIC_RELEASE_TOKEN') && !workflow.includes('DISTRIBUTION_DEPLOY_KEY'));
  assert.match(workflow, /contents: write\s+pages: write/);
  assert.match(workflow, /ref: docs/);
  const websiteWorkflow = await readFile('.github/workflows/github-pages.yml', 'utf8');
  assert.match(websiteWorkflow, /ref: docs/);
  assert.match(websiteWorkflow, /WEBSITE_DIRECTORY: build\/website/);
  const publish = await readFile('tool/github_release.mjs', 'utf8');
  assert.ok(!publish.includes("'--clobber'"));
  assert.match(publish, /files\.push\(\{file:manifestPath/);
  assert.ok(!publish.includes("'release','create'") && !publish.includes('PUBLIC_RELEASE_TOKEN'));
  assert.match(publish, /\/pages\/builds/);
  assert.match(publish, /!release.immutable/);
});
test('静态首页有原项目链接、Star、插件和四平台下载，无管理后台或统计 API', {skip:!process.env.WEBSITE_DIRECTORY}, async () => {
  const html = await readFile(join(process.env.WEBSITE_DIRECTORY,'index.html'), 'utf8');
  const js = await readFile(join(process.env.WEBSITE_DIRECTORY,'assets/site.js'), 'utf8');
  assert.match(html, /如果喜欢这个项目/); assert.match(html, /给项目点个 Star/);
  assert.equal((html.match(/data-platform=/g) ?? []).length, 4);
  assert.equal((html.match(/class="plugin-card"/g) ?? []).length, 6);
  assert.ok(html.includes('https://github.com/'+repository));
  assert.ok(!html.includes('qqm-releases') && !js.includes('qqm-releases'));
  assert.ok(!html.includes('/admin') && !html.includes('使用统计'));
  assert.ok(!js.includes('/api/') && !js.includes('innerHTML'));
  assert.ok(!html.includes('src="/assets/') && !html.includes('href="/assets/'));
});
