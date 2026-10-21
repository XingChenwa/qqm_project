// Keep signed in-app notes brief; the full GitHub Release body remains intact.
export function releaseNotesSummary(source = '') {
  const rows = [];
  for (let line of String(source).split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#') || line.startsWith('```') ||
        /https?:\/\/|sha-?256|checksum|构建编号|签名公钥|安装说明|安装包|下载链接|GitCode|GitHub|unsigned|\.(apk|exe|dmg|ipa)/i.test(line)) continue;
    line = line.replace(/^(?:[-*+•]\s+|\d+[.)、]\s*)/, '').replace(/[*`_]/g, '').trim();
    if (!line || /^[-:|\s]+$/.test(line)) continue;
    const chars = Array.from(line);
    const brief = chars.length > 82 ? chars.slice(0, 81).join('') + '…' : line;
    if (!rows.includes(brief)) rows.push(brief);
    if (rows.length === 3) break;
  }
  return (rows.length ? rows : ['修复一些问题，优化使用体验。']).map(line => '• ' + line).join('\n');
}
