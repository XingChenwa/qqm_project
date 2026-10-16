'use strict';
const repository = 'XingChenwa/qqm-releases';
const releasesPage = `https://github.com/${repository}/releases`;
const $ = selector => document.querySelector(selector);
const text = (tag, value) => { const node = document.createElement(tag); node.textContent = value; return node; };
function trustedRelease(release, data) {
  const url = new URL(release.url);
  const prefix = `/${repository}/releases/download/${data.tag}/`;
  if (url.protocol !== 'https:' || url.host !== 'github.com' || url.username || url.password || url.search || url.hash ||
      !url.pathname.startsWith(prefix) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$/.test(url.pathname.slice(prefix.length)) ||
      !/^[a-f0-9]{64}$/.test(release.sha256) || !Number.isSafeInteger(release.size) || release.size <= 0 || release.size > 1073741824 ||
      release.build !== data.build || release.version !== data.version) throw new Error('下载信息无效，请前往 GitHub Releases 核实。');
  return url.href;
}
function fallback(message) {
  $('#release-error').textContent = message;
  $('#release-error').classList.remove('hidden');
  document.querySelectorAll('[data-platform]').forEach(card => {
    card.querySelector('.release-meta').textContent = '等待首个完整的 GitHub 正式版本';
    const link = card.querySelector('.download-link');
    link.href = releasesPage; link.textContent = '前往 GitHub Releases ↗';
    link.classList.remove('disabled'); link.removeAttribute('aria-disabled');
  });
  const link = text('a', '查看 GitHub 全部发布记录 ↗'); link.href = releasesPage;
  $('#release-history').replaceChildren(link);
}
async function load() {
  try {
    const response = await fetch('releases.json', {cache: 'no-store'});
    if (!response.ok) throw new Error('暂时无法读取版本，可前往 GitHub Releases 下载。');
    const data = await response.json();
    if (Array.isArray(data.releases) && data.releases.length === 0) { fallback('尚未发布完整的 GitHub 签名版本。四端构建完成后，这里会自动显示下载。'); return; }
    if (data.repository !== repository || !/^\d+\.\d+\.\d+$/.test(data.version) || data.tag !== `v${data.version}` ||
        !Number.isSafeInteger(data.build) || data.build < 1 || !Array.isArray(data.releases) || data.releases.length !== 4) throw new Error('版本数据不完整，请前往 GitHub Releases 核实。');
    const checked = new Map();
    const targets = {windows: ['x64', 'exe'], macos: ['universal', 'dmg'], android: ['universal', 'apk'], ios: ['arm64', 'ipa']};
    for (const release of data.releases) {
      if (checked.has(release.platform) || release.arch !== targets[release.platform]?.[0] || release.format !== targets[release.platform]?.[1]) throw new Error('安装包平台不匹配。');
      checked.set(release.platform, {release, url: trustedRelease(release, data)});
    }
    for (const card of document.querySelectorAll('[data-platform]')) {
      const {release, url} = checked.get(card.dataset.platform);
      card.querySelector('.release-meta').textContent = `v${release.version} · 构建 ${release.build} · ${(release.size / 1048576).toFixed(1)} MB`;
      const link = card.querySelector('.download-link');
      link.href = url; link.textContent = `下载 ${release.format.toUpperCase()} ↓`;
      link.classList.remove('disabled'); link.removeAttribute('aria-disabled');
      card.querySelector('.checksum').textContent = release.sha256;
    }
    const item = document.createElement('article'); item.className = 'history-item';
    const info = document.createElement('div');
    const link = text('a', `v${data.version} · 四端正式版 ↗`); link.href = `${releasesPage}/tag/${data.tag}`;
    info.append(link, text('small', new Date(data.published_at * 1000).toLocaleDateString('zh-CN')));
    item.append(info, text('p', data.releases[0].notes || '本次发布暂无补充说明。'));
    const historyLink = text('a', '查看全部更新记录 ↗'); historyLink.href = releasesPage;
    $('#release-history').replaceChildren(item, historyLink);
  } catch (error) { fallback(error.message || '读取版本失败，请稍后重试。'); }
}
load();
