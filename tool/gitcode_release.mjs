// GitCode official Release API. Only the original, signed GitHub packages are
// mirrored: never rebuild, re-sign, replace an existing attachment, or expose a
// publisher token in the client. URLs returned by the service are allowlisted.
import {readFile} from 'node:fs/promises';
import {manifestName, verifyManifest, sha256} from './github_release_core.mjs';

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

export async function mirrorRelease({token, envelope, publicKey, files, request = fetch}) {
  requireThat(typeof token === 'string' && token.trim(), '缺少 GITCODE_TOKEN');
  const data = verifyManifest(envelope, publicKey);
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
  // Manifest is last; promote to latest only AFTER public read-back succeeds.
  prepared.push({name: manifestName, content: Buffer.from(JSON.stringify(envelope))});

  async function api(path, {method = 'GET', body, missing = false} = {}) {
    const url = new URL(apiBase + path);
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
    requireThat(response.ok, `GitCode API 请求失败（HTTP ${response.status}），请检查令牌权限`);
    return json;
  }
  async function publicAsset(name, maximum, tag = data.tag) {
    requireThat(/^v\d+\.\d+\.\d+$/.test(tag), 'GitCode 标签无效');
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
  if (latest) {
    const previous = verifyManifest(JSON.parse((await publicAsset(manifestName, 65536, latest.tag_name)).toString('utf8')), publicKey);
    requireThat(previous.tag === latest.tag_name && data.build >= previous.build, '拒绝将 GitCode 最新版本回退');
    requireThat(previous.build !== data.build || previous.tag === data.tag,
      '同一构建号不可发布到不同版本标签');
  }
  let release = await api('/tags/' + data.tag, {missing: true});
  const body = `与 GitHub ${data.repository} ${data.tag} 相同的四端安装包。\n\nhttps://github.com/${data.repository}/releases/tag/${data.tag}`;
  if (!release) release = await api('', {method: 'POST', body: {
    tag_name: data.tag, name: `QQ机器人管理器 ${data.tag}`, body, release_status: 'pre',
  }});
  requireThat(release.tag_name === data.tag && Array.isArray(release.assets), 'GitCode 版本标签不匹配');
  for (const file of prepared) {
    if (!release.assets.some(asset => asset.type === 'attach' && asset.name === file.name)) {
      const upload = await api(`/${data.tag}/upload_url?file_name=${encodeURIComponent(file.name)}`);
      requireThat(trustedMirrorUrl(upload.url, {upload: true}), 'GitCode 上传地址不可信');
      requireThat(upload.headers && Object.keys(upload.headers).every(header =>
        /^x-obs-/i.test(header) || header.toLowerCase() === 'content-type'), 'GitCode 上传请求头不可信');
      const uploaded = await request(upload.url, {method: 'PUT', headers: upload.headers,
        body: file.content, redirect: 'manual', signal: AbortSignal.timeout(600000)});
      requireThat(uploaded.ok, `GitCode 附件上传失败（HTTP ${uploaded.status}）`);
      await uploaded.body?.cancel();
    }
    const remote = await publicAsset(file.name, file.content.length);
    requireThat(remote.length === file.content.length && sha256(remote) === sha256(file.content),
      'GitCode 已有附件内容不同或上传校验失败；不会覆盖，请使用新版本');
  }
  await api('/' + data.tag, {method: 'PATCH', body: {
    name: `QQ机器人管理器 ${data.tag}`, body, release_status: 'latest',
  }});
  return data.tag;
}
