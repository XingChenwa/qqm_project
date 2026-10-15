'use strict';
const platformNames = {windows:'Windows',android:'Android',ios:'iOS'};
const sizeText = bytes => bytes >= 1048576 ? `${(bytes/1048576).toFixed(1)} MB` : `${bytes} B`;
const dateText = seconds => new Date(seconds*1000).toLocaleDateString('zh-CN',{timeZone:'Asia/Shanghai'});
async function loadReleases() {
  try {
    const response = await fetch('/api/v1/releases',{cache:'no-store'});
    if (!response.ok) throw new Error('暂时无法读取版本，请稍后重试。');
    const {releases,preview} = await response.json();
    if(preview){const notice=document.querySelector('#release-error');notice.textContent='本地预览环境；如有演示安装包，仅供测试，不可正式安装。';notice.classList.remove('hidden');}
    if (!Array.isArray(releases)) throw new Error('版本数据格式无效。');
    for (const card of document.querySelectorAll('[data-platform]')) {
      const release = releases.find(r=>r.platform===card.dataset.platform);
      const meta = card.querySelector('.release-meta');
      if (!release) {meta.textContent='暂未发布，敬请期待';continue;}
      const url = new URL(release.url);
      if (url.origin!==location.origin || !url.pathname.startsWith('/packages/')) throw new Error('下载域名未正确配置，请联系管理员。');
      meta.textContent=`v${release.version} · 构建 ${release.build} · ${sizeText(release.size)}`;
      const link = card.querySelector('.download-link');
      link.href=url.href; link.textContent=`下载 ${release.format.toUpperCase()} ↓`;
      link.classList.remove('disabled');link.removeAttribute('aria-disabled');link.setAttribute('download','');
      card.querySelector('.checksum').textContent=release.sha256;
      if (release.platform==='windows' && release.format==='exe') card.querySelector('.download-help').textContent='运行安装程序，按提示完成安装。';
    }
    const history = document.querySelector('#release-history'); history.replaceChildren();
    if (!releases.length) {const empty=document.createElement('p');empty.className='empty';empty.textContent='还没有已发布版本。管理员发布后会自动出现在这里。';history.append(empty);}
    for (const release of releases.slice(0,9)) {
      const item=document.createElement('article');item.className='history-item';
      const info=document.createElement('div'),title=document.createElement('h3'),date=document.createElement('small'),notes=document.createElement('p');
      title.textContent=`${platformNames[release.platform]||release.platform} · ${release.version}`;
      date.textContent=dateText(release.created_at);notes.textContent=release.notes||'本次发布暂无补充说明。';
      info.append(title,date);item.append(info,notes);history.append(item);
    }
  } catch(error) {
    const notice=document.querySelector('#release-error');notice.textContent=error.message||'读取版本失败。';notice.classList.remove('hidden');
    document.querySelectorAll('.release-meta').forEach(el=>el.textContent='暂时无法读取版本');
    document.querySelector('#release-history').textContent='暂时无法读取更新记录。';
  }
}
loadReleases();
