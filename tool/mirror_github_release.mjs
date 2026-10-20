// Synchronize an ALREADY published, signed release without rebuilding or
// changing its GitHub tag/assets. Runs only in the owner's Actions environment.
import {mkdtemp, readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {repository, manifestName, verifyManifest, versionPattern, manifestChannel} from './github_release_core.mjs';
import {mirrorRelease, uploadGitCodeFile} from './gitcode_release.mjs';
import {packageNames} from './package_names.mjs';

try {
  if (process.env.GITHUB_REPOSITORY !== repository) throw new Error('只能在原项目运行镜像同步');
  const tag = process.env.RELEASE_TAG;
  if (!tag?.startsWith('v') || !versionPattern.test(tag.slice(1))) throw new Error('版本标签格式无效');
  if (!process.env.GITCODE_TOKEN) throw new Error('请配置 Actions Secret GITCODE_TOKEN');
  const gh = (...args) => execFileSync('gh', args, {encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'], env: {...process.env, GH_HOST: 'github.com'}});
  const readSourceRelease = () => {
    const source=JSON.parse(gh('api',`repos/${repository}/releases/tags/${tag}`));
    return {tagName:source.tag_name,isDraft:source.draft,isPrerelease:source.prerelease,assets:source.assets};
  };
  const release = readSourceRelease();
  if (release.isDraft || release.tagName !== tag) throw new Error('只能同步已发布的版本');
  const directory = await mkdtemp(join(tmpdir(), 'qqm-gitcode-mirror-'));
  gh('release', 'download', tag, '--repo', repository, '--pattern', manifestName, '--dir', directory);
  const envelope = JSON.parse(await readFile(join(directory, manifestName), 'utf8'));
  const publicKey = process.env.UPDATE_PUBLIC_KEY ?? '';
  const data = verifyManifest(envelope, publicKey);
  if (manifestChannel(data) !== (release.isPrerelease ? 'beta' : 'stable')) throw new Error('Release 与签名清单的渠道不一致');
  if (data.tag !== tag) throw new Error('Release 标签与签名清单不一致');
  const files = [];
  for (const release of data.releases) {
    const name = new URL(release.url).pathname.split('/').at(-1);
    gh('release', 'download', tag, '--repo', repository, '--pattern', name, '--dir', directory);
    files.push({name, file: join(directory, name)});
  }
  const names=packageNames(data.version,data.build),extraFiles=[];
  const linuxNames=[names.linux_file,names.linux_checksum];
  if(linuxNames.some(name=>release.assets.some(asset=>asset.name===name))){
    if(!linuxNames.every(name=>release.assets.some(asset=>asset.name===name)))throw new Error('GitHub Linux 附件不齐，停止镜像');
    for(const name of linuxNames){
      gh('release','download',tag,'--repo',repository,'--pattern',name,'--dir',directory);
      extraFiles.push({name,file:join(directory,name)});
    }
  }
  await mirrorRelease({token: process.env.GITCODE_TOKEN, envelope, publicKey, files,extraFiles,
    sourceRelease: release, refreshSource: readSourceRelease,
    uploader: uploadGitCodeFile, onProgress: message => console.log(message)});
  console.log('GitCode 国内更新节点已同步 ' + data.tag + `，${extraFiles.length?'五':'四'}端文件和签名清单均已读回校验。`);
} catch (error) {
  console.error('GitCode 同步失败：' + (error instanceof Error ? error.message.split('\n')[0] : '未知错误'));
  process.exitCode = 1;
}
