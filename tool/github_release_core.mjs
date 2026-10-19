import {createHash, createPrivateKey, createPublicKey, sign, verify} from 'node:crypto';

export const repository = 'XingChenwa/qqm_project';
export const pagesUrl = 'https://xingchenwa.github.io/qqm_project';
export const websiteBranch = 'docs';
export const manifestName = 'update-manifest.json';
export const versionPattern = /^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/;
export const releaseChannel = release => release.prerelease === true ? 'beta' : 'stable';
export const manifestChannel = data => data.channel ?? 'stable';
const seedPrefix = Buffer.from('302e020100300506032b657004220420', 'hex');
const publicPrefix = Buffer.from('302a300506032b6570032100', 'hex');
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
function requireThat(value, message) { if (!value) throw new Error(message); }
export function base64(value, lengths) {
  requireThat(typeof value === 'string' && /^[A-Za-z0-9+/]+={0,2}$/.test(value), '密钥或清单不是标准 Base64');
  const bytes = Buffer.from(value, 'base64');
  requireThat(bytes.toString('base64') === value && lengths.includes(bytes.length), '密钥或签名长度无效');
  return bytes;
}
export function signingKeys(secret, expectedPublicKey) {
  const bytes = base64(secret, [32, 64]);
  const privateKey = createPrivateKey({key: Buffer.concat([seedPrefix, bytes.subarray(0, 32)]), format: 'der', type: 'pkcs8'});
  const publicBytes = createPublicKey(privateKey).export({format: 'der', type: 'spki'}).subarray(-32);
  requireThat(bytes.length === 32 || bytes.subarray(32).equals(publicBytes), '64 字节私钥的公钥部分不匹配');
  requireThat(publicBytes.equals(base64(expectedPublicKey, [32])), 'UPDATE_SIGNING_PRIVATE_KEY 与 UPDATE_PUBLIC_KEY 不匹配；请勿随意换钥');
  return {privateKey, publicBytes};
}
export function readVersion(pubspec, constants) {
  const match = /^version:\s*(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)\+([1-9]\d*)\s*$/m.exec(pubspec);
  requireThat(match && Number.isSafeInteger(Number(match[2])) && Number(match[2]) <= 2147483647, 'pubspec.yaml 必须包含 版本+递增构建号');
  const version = match[1], build = Number(match[2]);
  requireThat(constants.includes(`appVersion = '${version}'`) && new RegExp(`appBuild\\s*=\\s*${build}\\s*;`).test(constants), 'AppConstants 与 pubspec.yaml 的版本不一致');
  return {version, build, tag: `v${version}`};
}
export function trustedAsset(value, tag) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.host === 'github.com' && !url.username && !url.password && !url.search && !url.hash &&
      url.pathname.startsWith(`/${repository}/releases/download/${tag}/`) &&
      /^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$/.test(url.pathname.slice(`/${repository}/releases/download/${tag}/`.length));
  } catch { return false; }
}
export function validateManifest(data, minimumBuild = 0, now = Date.now(), channel) {
  requireThat(data?.schema === 2 && data.repository === repository && versionPattern.test(data.version) && data.tag === `v${data.version}`, '清单版本或仓库不匹配');
  requireThat(['stable', 'beta'].includes(manifestChannel(data)) && (!channel || manifestChannel(data) === channel) &&
    (data.channel != null || !data.version.includes('-')), '更新渠道不匹配');
  requireThat(Number.isSafeInteger(data.build) && data.build > 0 && data.build <= 2147483647 && data.build >= minimumBuild, '构建号无效或回退');
  requireThat(Number.isSafeInteger(data.published_at) && data.published_at >= 1735689600 && data.published_at <= Math.floor(now / 1000) + 86400, '发布时间无效');
  requireThat(Array.isArray(data.releases) && data.releases.length === 4, '必须齐备四个平台的安装包');
  const targets = new Map([['windows/x64', 'exe'], ['android/universal', 'apk'], ['ios/arm64', 'ipa'], ['macos/universal', 'dmg']]);
  for (const release of data.releases) {
    const target = `${release.platform}/${release.arch}`;
    requireThat(targets.has(target) && targets.get(target) === release.format, '平台、架构或安装包格式重复/无效');
    targets.delete(target);
    requireThat(release.version === data.version && release.build === data.build && release.package_id === 'cn.uuze.botmanager', '安装包身份或版本不一致');
    requireThat(Number.isSafeInteger(release.size) && release.size > 0 && release.size <= 1073741824 && /^[a-f0-9]{64}$/.test(release.sha256), '安装包大小或哈希无效');
    requireThat(trustedAsset(release.url, data.tag) && new URL(release.url).pathname.endsWith(`.${release.format}`), '不是当前仓库正式版本的下载地址');
    requireThat(typeof release.notes === 'string' && release.notes.length <= 4000 && typeof release.force_update === 'boolean', '更新说明或更新选项无效');
  }
  return data;
}
export function signManifest(data, secret, publicKey) {
  validateManifest(data);
  const {privateKey} = signingKeys(secret, publicKey);
  const bytes = Buffer.from(JSON.stringify(data));
  const envelope = {payload: bytes.toString('base64'), signature: sign(null, bytes, privateKey).toString('base64')};
  requireThat(JSON.stringify(envelope).length <= 65536, '清单过大');
  return envelope;
}
export function verifyManifest(envelope, publicKey, minimumBuild = 0, channel) {
  requireThat(envelope && JSON.stringify(envelope).length <= 65536, '清单过大或为空');
  const bytes = base64(envelope.payload, [Buffer.from(envelope.payload ?? '', 'base64').length]);
  const key = createPublicKey({key: Buffer.concat([publicPrefix, base64(publicKey, [32])]), type: 'spki', format: 'der'});
  requireThat(verify(null, bytes, key, base64(envelope.signature, [64])), '更新清单签名校验失败');
  return validateManifest(JSON.parse(bytes.toString('utf8')), minimumBuild, Date.now(), channel);
}
export function assetDefinitions(version, build) {
  return [
    {platform: 'windows', arch: 'x64', format: 'exe', name: `qqbotmanager-windows-v${version}-build${build}-setup.exe`, directory: 'windows-x64-packages'},
    {platform: 'android', arch: 'universal', format: 'apk', name: 'app-release.apk', directory: 'android-release-apk'},
    {platform: 'ios', arch: 'arm64', format: 'ipa', name: 'qq_bot_manager-unsigned.ipa', directory: 'ios-unsigned-ipa'},
    {platform: 'macos', arch: 'universal', format: 'dmg', name: 'qqbotmanager-macos-universal.dmg', directory: 'macos-universal-packages'},
  ];
}
