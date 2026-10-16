// Only CI commands `publish` and `pages` access GitHub; import core for pure tests.
import {readFile, writeFile, mkdir, cp, stat, mkdtemp} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join, resolve, dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {repository, pagesUrl, manifestName, base64, signingKeys, readVersion, sha256, assetDefinitions, signManifest, verifyManifest} from './github_release_core.mjs';

const command = process.argv[2];
const publicKey = process.env.UPDATE_PUBLIC_KEY ?? '';
const secret = process.env.UPDATE_SIGNING_PRIVATE_KEY ?? '';
const gh = (...args) => execFileSync('gh', args, {encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe']});
const api = path => JSON.parse(gh('api', `repos/${repository}/${path}`));
const json = file => readFile(file, 'utf8').then(JSON.parse);
const assert = (condition, message) => { if (!condition) throw new Error(message); };

async function newestSignedRelease() {
  const releases = api('releases?per_page=100');
  let newest = null;
  // Newest GitHub release may still be building. Keep the last COMPLETE signed
  // release, never replace live updates with an empty or partially built one.
  for (const release of releases.filter(r => !r.draft && !r.prerelease && r.assets.some(a => a.name === manifestName))) {
    const directory = await mkdtemp(join(tmpdir(), 'qqm-manifest-'));
    gh('release', 'download', release.tag_name, '--repo', repository, '--pattern', manifestName, '--dir', directory);
    const envelope = await json(join(directory, manifestName));
    const data = verifyManifest(envelope, publicKey);
    assert(data.tag === release.tag_name, 'Release 标签与签名清单不匹配');
    assert(data.releases.every(r => release.assets.some(a => a.name === new URL(r.url).pathname.split('/').at(-1) && a.size === r.size)), '已签名 Release 的安装包缺失或大小变化');
    if (newest?.data.build === data.build) assert(newest.envelope.payload === envelope.payload, '同一构建号存在不同清单，请发布更高构建号');
    if (!newest || data.build > newest.data.build) newest = {data, envelope};
  }
  return newest;
}

async function buildSite(selected, destination) {
  // Copy only the static site. Never package management/config.php or any data/.
  await mkdir(dirname(destination), {recursive: true});
  await mkdir(destination); // A stale output must not leak an older stable.json.
  await cp('site', destination, {recursive: true, dereference: false});
  await mkdir(join(destination, 'updates'), {recursive: true});
  await writeFile(join(destination, 'releases.json'), JSON.stringify(selected?.data ?? {releases: []}));
  if (selected) await writeFile(join(destination, 'updates', 'stable.json'), JSON.stringify(selected.envelope));
}

try {
  assert(process.env.GITHUB_REPOSITORY === repository, `此流程仅用于 ${repository}；fork 请先配置自己的仓库和客户端信任边界`);
  base64(publicKey, [32]);
  if (command === 'preflight') {
    const info = readVersion(await readFile('pubspec.yaml', 'utf8'), await readFile('lib/utils/constants.dart', 'utf8'));
    assert((process.env.UPDATE_BASE_URL ?? pagesUrl).replace(/\/$/, '') === pagesUrl, 'GitHub 自动发布须使用项目 Pages 更新地址');
    if (process.env.GITHUB_EVENT_NAME === 'release') {
      const {release} = await json(process.env.GITHUB_EVENT_PATH);
      assert(release && !release.draft && !release.prerelease && release.tag_name === info.tag, '正式 Release 标签必须与 pubspec 版本完全一致，如 v1.3.7');
      assert(!release.immutable, '该 Release 已不可变，无法追加安装包；本流程需要在上传完成前保持 Release 可追加附件');
      signingKeys(secret, publicKey);
      const previous = await newestSignedRelease();
      if (previous) assert(info.build > previous.data.build || (info.build === previous.data.build && info.tag === previous.data.tag), '构建号必须递增，不能发布旧版本');
    }
    console.log(`已校验版本 ${info.version} (${info.build})；未输出私钥。`);
  } else if (command === 'publish') {
    const info = readVersion(await readFile('pubspec.yaml', 'utf8'), await readFile('lib/utils/constants.dart', 'utf8'));
    const {release: eventRelease} = await json(process.env.GITHUB_EVENT_PATH);
    assert(eventRelease?.tag_name === info.tag, '发布事件标签不匹配');
    const release = api(`releases/tags/${info.tag}`);
    assert(!release.draft && !release.prerelease && !release.immutable, '只允许可追加附件的正式已发布版本');
    signingKeys(secret, publicKey);
    const previous = await newestSignedRelease();
    assert(!previous || info.build >= previous.data.build, '更高构建已发布，拒绝回退首页或清单');
    const packages = resolve('build/release-packages');
    await mkdir(packages, {recursive: true});
    const definitions = assetDefinitions(info.version, info.build);
    gh('run', 'download', process.env.GITHUB_RUN_ID, '--repo', repository, '--dir', packages, ...definitions.flatMap(a => ['--name', a.directory]));
    const data = {schema: 2, repository, tag: info.tag, ...info, published_at: Math.floor(Date.parse(release.published_at) / 1000), releases: []};
    const files = [];
    for (const asset of definitions) {
      const file = join(packages, asset.directory, asset.name);
      const size = (await stat(file)).size;
      assert(size > 0 && size <= 1073741824, '安装包大小无效');
      const hash = sha256(await readFile(file));
      data.releases.push({platform: asset.platform, arch: asset.arch, format: asset.format, version: info.version, build: info.build, package_id: 'cn.uuze.botmanager', size, sha256: hash,
        url: `https://github.com/${repository}/releases/download/${info.tag}/${asset.name}`, notes: (release.body ?? '').slice(0, 2000), force_update: false});
      files.push({file, name: asset.name, hash});
    }
    const windows = await json(join(packages, 'windows-x64-packages', `qqbotmanager-windows-v${info.version}-build${info.build}-build-info.json`));
    assert(windows.build === info.build && windows.version === info.version && windows.update_public_key === publicKey && windows.update_server === pagesUrl, 'Windows 构建身份或更新公钥不一致');
    const existingManifest = release.assets.find(a => a.name === manifestName);
    let envelope = signManifest(data, secret, publicKey);
    if (existingManifest) {
      const same = previous?.data.tag === info.tag ? previous : null;
      assert(same && JSON.stringify(same.data) === JSON.stringify(data), '此版本已经签名发布，不能覆盖；请增加版本号与构建号');
      envelope = same.envelope;
    }
    const manifestPath = join(packages, manifestName);
    await writeFile(manifestPath, JSON.stringify(envelope));
    files.push({file: manifestPath, name: manifestName, hash: sha256(await readFile(manifestPath))});
    // Manifest uploads LAST, acting as a commit marker. Never --clobber a live
    // package. A partial failed upload can safely resume only with identical bits.
    for (const file of files) {
      const existing = release.assets.find(a => a.name === file.name);
      if (existing) {
        const directory = await mkdtemp(join(tmpdir(), 'qqm-asset-'));
        gh('release', 'download', info.tag, '--repo', repository, '--pattern', file.name, '--dir', directory);
        assert(sha256(await readFile(join(directory, file.name))) === file.hash, `Release 已有不同内容的 ${file.name}；请使用新版本号，不覆盖`);
      } else {
        gh('release', 'upload', info.tag, file.file, '--repo', repository);
      }
    }
    await buildSite({data, envelope}, resolve('build/github-pages'));
    console.log(`四端安装包及签名清单已上传 ${info.tag}；静态首页已生成。`);
  } else if (command === 'pages') {
    const newest = await newestSignedRelease();
    await buildSite(newest, resolve('build/github-pages'));
    console.log(newest ? `首页使用 ${newest.data.tag} 的已验证清单。` : '尚无 GitHub 签名版本；首页提供 Releases 入口，不生成虚假的更新包。');
  } else { throw new Error('用法: node tool/github_release.mjs preflight|publish|pages'); }
} catch (error) {
  // Do not dump command environment or subprocess output: it can contain tokens.
  console.error(`GitHub 发布未完成：${error instanceof Error ? error.message.split('\n')[0] : '未知错误'}`);
  process.exitCode = 1;
}
