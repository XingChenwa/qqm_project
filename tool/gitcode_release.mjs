// GitCode official Release API. Only the original, signed GitHub packages are
// mirrored: never rebuild, re-sign, replace an existing attachment, or expose a
// publisher token in the client. URLs returned by the service are allowlisted.
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {manifestName, verifyManifest, sha256, manifestChannel, versionPattern} from './github_release_core.mjs';

export const gitCodeRepository = 'xiaoshutiaoya/QQm_project';
const apiBase = `https://api.gitcode.com/api/v5/repos/${gitCodeRepository}/releases`;
const requireThat = (ok, message) => { if (!ok) throw new Error(message); };

export function trustedMirrorUrl(value, {upload = false} = {}) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password &&
      !url.port && !url.hash && (upload
        ? url.hostname === 'file.gitcode.com'
        : (url.hostname === 'file-cdn.gitcode.com' ||
          (url.origin === 'https://api.gitcode.com' && url.pathname.startsWith(`/api/v5/repos/${gitCodeRepository}/releases/`))));
  } catch { return false; }
}

async function bytes(response, maximum) {
  const chunks = []; let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    requireThat(size <= maximum, 'GitCode 资源超过预期大小');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export async function uploadGitCodeFile(upload, content) {
  requireThat(trustedMirrorUrl(upload.url, {upload: true}), 'GitCode 上传地址不可信');
  await new Promise((resolve, reject) => {
    const child = spawn(process.platform === 'win32' ? 'python' : 'python3',
      [fileURLToPath(new URL('./gitcode_upload.py', import.meta.url))],
      {stdio: ['pipe','pipe','pipe'], windowsHide: true});
    let diagnostic = '';
    child.stdout.resume();
    child.stderr.on('data', chunk => { if (diagnostic.length < 500) diagnostic += chunk; });
    child.on('error', () => reject(new Error('GitCode 上传辅助程序无法启动')));
    child.stdin.on('error', () => {});
    child.on('exit', code => code === 0 ? resolve() : reject(new Error(
      'GitCode 附件上传失败：' + (diagnostic.match(/Upload (?:HTTP \d+|transport: [A-Za-z]+Error)/)?.[0] ?? '传输中断'))));
    child.stdin.write(JSON.stringify({url:upload.url,headers:upload.headers,size:content.length})+'\n');
    child.stdin.end(content);
  });
}

export function gitCodeReleaseStatus(sourceRelease, data) {
  requireThat(sourceRelease?.tagName === data.tag && sourceRelease.isDraft === false &&
    typeof sourceRelease.isPrerelease === 'boolean', '只能同步当前标签已发布的 GitHub Release');
  const beta = sourceRelease.isPrerelease;
  requireThat(manifestChannel(data) === (beta ? 'beta' : 'stable'), 'GitHub Release 与签名清单的渠道不一致');
  return beta ? 'pre' : 'latest';
}

export async function mirrorRelease({token, envelope, publicKey, files, sourceRelease, refreshSource,
  request = fetch, uploader, onProgress = () => {}}) {
  requireThat(typeof token === 'string' && token.trim(), '缺少 GITCODE_TOKEN');
  const data = verifyManifest(envelope, publicKey);
  const releaseStatus = gitCodeReleaseStatus(sourceRelease, data);
  const expected = new Map(data.releases.map(release => [
    new URL(release.url).pathname.split('/').at(-1), release,
  ]));
  const prepared = [];
  for (const file of files.filter(file => file.name !== manifestName)) {
    const release = expected.get(file.name);
    requireThat(release && !prepared.some(item => item.name === file.name), '镜像安装包名称不匹配');
    const content = await readFile(file.file);
    requireThat(content.length === release.size && sha256(content) === release.sha256, '镜像源文件校验失败');
    prepared.push({name: file.name, content});
  }
  requireThat(prepared.length === 4, '镜像必须齐备四端安装包');
  // GitCode only documents pre/latest, NOT a draft state. Never use PRE as a
  // staging state for a stable release. Channel and transfer state are separate:
  // the manifest is uploaded LAST, after all four installers pass read-back.
  prepared.push({name: manifestName, content: Buffer.from(JSON.stringify(envelope))});

  async function api(path, {method = 'GET', body, missing = false, repositoryPath = false} = {}) {
    const url = new URL((repositoryPath ? apiBase.slice(0, -'/releases'.length) : apiBase) + path);
    url.searchParams.set('access_token', token);
    let response;
    try {
      response = await request(url, {method, redirect: 'manual', signal: AbortSignal.timeout(30000),
        headers: {'Content-Type': 'application/json'}, ...(body ? {body: JSON.stringify(body)} : {})});
    } catch { throw new Error('GitCode API 网络请求失败'); }
    const content = await bytes(response, 2 * 1024 * 1024);
    let json;
    try { json = JSON.parse(content.toString('utf8')); } catch { throw new Error('GitCode API 返回格式无效'); }
    if (missing && (response.status === 404 ||
      (response.status === 400 && /未找到 release/i.test(json.error_message ?? '')))) return null;
    const message = String(json.error_message ?? json.message ?? '').replaceAll(token, '[redacted]')
      .replace(/https?:\/\/\S+/g, '[url]').replace(/[\r\n\u0000-\u001f]/g, ' ').slice(0, 180);
    requireThat(response.ok, `GitCode ${method} ${path.split('?')[0] || '/'} 请求失败（HTTP ${response.status}）：${message || '请检查令牌权限和仓库状态'}`);
    return json;
  }
  async function publicAsset(name, maximum, tag = data.tag) {
    requireThat(tag.startsWith('v') && versionPattern.test(tag.slice(1)), 'GitCode 标签无效');
    let url = new URL(`${apiBase}/${tag}/attach_files/${name}/download`);
    for (let hop = 0; hop < 6; hop++) {
      requireThat(trustedMirrorUrl(url), 'GitCode 下载跳转不可信');
      const response = await request(url, {redirect: 'manual', signal: AbortSignal.timeout(120000)});
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get('location'); await response.body?.cancel();
        requireThat(location, 'GitCode 缺少跳转地址'); url = new URL(location, url); continue;
      }
      requireThat(response.ok, `GitCode 公共资源读取失败（HTTP ${response.status}）`);
      return bytes(response, maximum);
    }
    throw new Error('GitCode 跳转次数过多');
  }

  const latest = await api('/latest', {missing: true});
  // latest may be Beta or an incomplete upload. Do not let such an entry hide
  // the previous signed stable version from the anti-rollback check.
  const sameChannel = release =>
    (release.prerelease === true || release.release_status === 'pre') === (manifestChannel(data) === 'beta');
  const hasManifest = release => release.assets?.some(asset => asset.type === 'attach' && asset.name === manifestName);
  const previousReleases = !latest ? [] : sameChannel(latest) && hasManifest(latest) ? [latest] :
    await api('?per_page=100&direction=desc');
  requireThat(Array.isArray(previousReleases), 'GitCode 版本列表格式无效');
  for (const entry of previousReleases.filter(hasManifest)) {
    // A legacy failed staging release may have the wrong UI label. The signed
    // manifest, not that label, determines its channel for rollback protection.
    const previous = verifyManifest(JSON.parse((await publicAsset(manifestName, 65536, entry.tag_name)).toString('utf8')), publicKey);
    if (manifestChannel(previous) !== manifestChannel(data)) continue;
    requireThat(previous.tag === entry.tag_name && data.build >= previous.build, '拒绝将 GitCode 最新版本回退');
    requireThat(previous.build !== data.build || previous.tag === data.tag,
      '同一构建号不可发布到不同版本标签');
  }
  if (!latest) {
    const branches = await api('/branches', {repositoryPath: true});
    requireThat(Array.isArray(branches), 'GitCode 分支列表格式无效');
    if (branches.length === 0) {
      // Release creation needs a commit. Bootstrap ONLY a verified empty repo;
      // the create-file API cannot overwrite an existing README or branch.
      await api('/contents/README.md', {repositoryPath: true, method: 'POST', body: {
        branch: 'main', message: 'docs: initialize QQ bot manager download mirror',
        'author[name]': 'xiaoshutiaoya', 'author[email]': 'xiaoshutiaoya@noreply.gitcode.com',
        content: Buffer.from('# QQ机器人管理器 · 国内下载镜像\n\n此仓库的 Release 提供与 GitHub 正式版相同的安装包和更新签名清单。\n\n- 项目源码：https://github.com/XingChenwa/qqm_project\n- 项目首页：https://xingchenwa.github.io/qqm_project/\n- 开源许可：GPL-2.0-only，以原项目 LICENSE 为准。\n').toString('base64'),
      }});
      onProgress('已初始化空的 GitCode 下载镜像仓库。');
    }
  }
  let release = await api('/tags/' + data.tag, {missing: true});
  const body = `与 GitHub ${data.repository} ${data.tag} 相同的四端安装包。\n\nhttps://github.com/${data.repository}/releases/tag/${data.tag}`;
  const name = `QQ机器人管理器 ${data.tag}`;
  const markerPrefix = `<!-- qqm-mirror-v2:${data.tag}:${sha256(prepared.at(-1).content)}:`;
  const marker = `${markerPrefix}${randomUUID()} -->`;
  const pending = `${marker}\n\n> 国内镜像同步／校验未完成，请暂时使用下方 GitHub 下载地址。全部文件校验通过后移除此提示。\n\n${body}`;
  const unfinishedName = `${name}（国内镜像未完成）`;
  let managed = false;
  let identity;
  const releaseIdentity = value => JSON.stringify([value.tag_name, value.target_commitish, value.created_at]);
  const channelMatches = value => value.release_status === releaseStatus &&
    value.prerelease === (releaseStatus === 'pre');
  const validateRelease = value => requireThat(value?.tag_name === data.tag && Array.isArray(value.assets), 'GitCode 版本标签不匹配');
  const metadata = (value, overrides = {}) => ({name: value.name, body: value.body, release_status: releaseStatus, ...overrides});
  try {
    if (!release) {
      release = await api('', {method: 'POST', body: {
        tag_name: data.tag, name: unfinishedName, body: pending, release_status: releaseStatus,
      }});
      managed = true;
    }
    validateRelease(release);
    identity = releaseIdentity(release);
    if (hasManifest(release)) {
      // A manually completed release is read-only unless its verified channel
      // needs correction. Never replace its packages, title or release notes.
      const existing = await publicAsset(manifestName, 65536);
      requireThat(sha256(existing) === sha256(prepared.at(-1).content), 'GitCode 已有签名清单不同；不会修改已有发布');
    }
    if (!managed && release.body?.startsWith(markerPrefix)) {
      release = await api('/' + data.tag, {method: 'PATCH', body: metadata(release, {name: unfinishedName, body: pending})});
      managed = true;
    } else if (!channelMatches(release)) {
      // Repair an old mislabeled placeholder before uploading. A later timeout
      // must not leave a stable release labeled PRE again.
      release = await api('/' + data.tag, {method: 'PATCH', body: metadata(release)});
    }
    validateRelease(release);
    requireThat(channelMatches(release), 'GitCode 未采用与 GitHub 一致的发布类型');
    for (const file of prepared) {
      if (!release.assets.some(asset => asset.type === 'attach' && asset.name === file.name)) {
        onProgress(`上传 GitCode 附件：${file.name}（${file.content.length} 字节）`);
        const upload = await api(`/${data.tag}/upload_url?file_name=${encodeURIComponent(file.name)}`);
        requireThat(trustedMirrorUrl(upload.url, {upload: true}), 'GitCode 上传地址不可信');
        requireThat(upload.headers && Object.keys(upload.headers).every(header =>
          /^x-obs-/i.test(header) || header.toLowerCase() === 'content-type'), 'GitCode 上传请求头不可信');
        if (uploader) await uploader(upload, file.content);
        else {
          const uploaded = await request(upload.url, {method: 'PUT', headers: upload.headers,
            body: file.content, redirect: 'manual', signal: AbortSignal.timeout(600000)});
          requireThat(uploaded.ok, `GitCode 附件上传失败（HTTP ${uploaded.status}）`);
          await uploaded.body?.cancel();
        }
      }
      onProgress(`读回校验 GitCode 附件：${file.name}`);
      const remote = await publicAsset(file.name, file.content.length);
      requireThat(remote.length === file.content.length && sha256(remote) === sha256(file.content),
        'GitCode 已有附件内容不同或上传校验失败；不会覆盖，请使用新版本');
    }
    if (refreshSource) gitCodeReleaseStatus(await refreshSource(), data);
    let live = await api('/tags/' + data.tag);
    validateRelease(live);
    requireThat(releaseIdentity(live) === identity, 'GitCode 发布已被替换；停止修改，保留用户操作');
    if (managed) {
      requireThat(live.body?.startsWith(marker), 'GitCode 发布说明已被修改；保留用户操作');
      live = await api('/' + data.tag, {method: 'PATCH', body: {name, body, release_status: releaseStatus}});
    } else if (!channelMatches(live)) {
      live = await api('/' + data.tag, {method: 'PATCH', body: metadata(live)});
    }
    requireThat(channelMatches(live), 'GitCode 发布类型与 GitHub 不一致，尚未同步完成');
    return data.tag;
  } catch (error) {
    let markingFailed = false;
    if (managed && identity) {
      try {
        const live = await api('/tags/' + data.tag);
        // Only annotate this exact attempt. Do not delete a release/tag or
        // overwrite a replacement/manual edit made while the upload ran.
        if (releaseIdentity(live) === identity && live.body?.startsWith(marker)) {
          await api('/' + data.tag, {method: 'PATCH', body: metadata(live, {
            name: unfinishedName,
            body: `${marker}\n\n> 国内镜像同步失败或校验未完成，请先使用 GitHub 下载。可重试同步，已校验文件不会覆盖。\n\n${body}`,
          })});
        }
      } catch { markingFailed = true; }
    }
    const message = String(error instanceof Error ? error.message : '镜像同步未完成')
      .replaceAll(token, '[redacted]').replace(/https?:\/\/\S+/g, '[url]')
      .replace(/[\r\n\u0000-\u001f]/g, ' ').slice(0, 500);
    throw new Error(message + (markingFailed ? '；失败提示写入失败，保留原有“未完成”状态，请重试同步' : ''));
  }
}
