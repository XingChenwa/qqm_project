// Notes-only publication. Uses the configured signing key inside Actions; no
// installers are built, uploaded, replaced or deleted by this workflow.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {repository,manifestName,versionPattern,verifyManifest,signManifest,sha256,releaseChannel,manifestChannel,assertNotesOnlyChange} from './github_release_core.mjs';
import {releaseNotesSummary} from './release_notes.mjs';
import {syncWebsiteMetadata} from './github_site_sync.mjs';
import {uploadGitCodeFile,validateUploadDescriptor} from './gitcode_transport.mjs';
import {trustedMirrorUrl,gitCodeReleaseStatus,gitCodeRepository} from './gitcode_release.mjs';

const check=(ok,message)=>{if(!ok)throw Error(message);};
const assetSnapshot=assets=>assets.filter(a=>a.name!==manifestName&&!/^update-manifest-notes-[a-f0-9]+\.json$/.test(a.name))
  .map(a=>({id:a.id,name:a.name,size:a.size,digest:a.digest,type:a.type})).sort((a,b)=>a.name.localeCompare(b.name));
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);

export function updatedNotesManifest(envelope,release,publicKey,secret) {
  const previous=verifyManifest(envelope,publicKey);
  check(release.tag_name===previous.tag&&!release.draft&&releaseChannel(release)===manifestChannel(previous),'发布标签或更新渠道与签名清单不一致');
  const data=structuredClone(previous),notes=releaseNotesSummary(release.body);
  for(const item of data.releases)item.notes=notes;
  assertNotesOnlyChange(previous,data);
  return {previous,data,envelope:same(previous,data)?envelope:signManifest(data,secret,publicKey)};
}

export function assertPackageAssets(data,assets) {
  for(const entry of data.releases) {
    const name=new URL(entry.url).pathname.split('/').at(-1);
    const found=assets.find(a=>a.name===name);
    check(found&&found.size===entry.size&&found.digest==='sha256:'+entry.sha256,'原安装包缺失或摘要变化，停止刷新日志');
  }
}

// Upload the replacement under a temporary public name, then swap names.
// The previous signed file stays downloadable as a small revision backup.
// A failed swap restores the previous canonical name rather than deleting it.
export async function replaceGitHubManifest({release,content,previousContent,api,upload}) {
  const original=release.assets.find(a=>a.name===manifestName);
  check(original?.id&&original.digest==='sha256:'+sha256(previousContent),'原签名清单身份不符');
  if(content.equals(previousContent))return false;
  const nextName='update-manifest-notes-'+sha256(content)+'.json';
  const backupName='update-manifest-notes-'+sha256(previousContent)+'.json';
  let next=release.assets.find(a=>a.name===nextName);
  if(next)check(next.digest==='sha256:'+sha256(content),'已有日志修订附件不同');
  else next=await upload(nextName,content);
  check(next?.id&&next.digest==='sha256:'+sha256(content),'新清单上传摘要不符');
  check(!release.assets.some(a=>a.name===backupName),'原清单修订备份已存在，停止重命名');
  await api('releases/assets/'+original.id,{method:'PATCH',body:{name:backupName}});
  try { await api('releases/assets/'+next.id,{method:'PATCH',body:{name:manifestName}}); }
  catch(error) {
    try {await api('releases/assets/'+original.id,{method:'PATCH',body:{name:manifestName}});}
    catch {throw Error('清单名称恢复未完成；旧签名备份仍存在，请恢复 canonical 名称后重试');}
    throw error;
  }
  return true;
}

async function publicBytes(initial,{mirror=false,maximum=65536}={}) {
  let url=new URL(initial);
  for(let hop=0;hop<6;hop++) {
    check(mirror?trustedMirrorUrl(url):url.protocol==='https:'&&!url.port&&!url.username&&!url.password&&!url.hash&&
      ['github.com','release-assets.githubusercontent.com','objects.githubusercontent.com'].includes(url.hostname),'清单下载地址不可信');
    const response=await fetch(url,{redirect:'manual',signal:AbortSignal.timeout(20000)});
    if([301,302,303,307,308].includes(response.status)) {
      const location=response.headers.get('location');await response.body?.cancel();check(location,'清单缺少跳转地址');url=new URL(location,url);continue;
    }
    check(response.ok,'读取清单失败（HTTP '+response.status+'）');
    const chunks=[];let size=0;
    for await(const chunk of response.body){size+=chunk.length;check(size<=maximum,'清单响应过大');chunks.push(chunk);}
    return Buffer.concat(chunks);
  }
  throw Error('清单跳转过多');
}

export async function refreshGitCodeNotes({envelope,publicKey,token,readPublic=publicBytes,request=fetch,uploader=uploadGitCodeFile,onProgress=()=>{}}) {
  check(token,'缺少 GitCode 发布凭据');
  const data=verifyManifest(envelope,publicKey),base=`https://api.gitcode.com/api/v5/repos/${gitCodeRepository}/releases`;
  const api=async(path,{method='GET',body}={})=>{
    const url=new URL(base+path);url.searchParams.set('access_token',token);
    const response=await request(url,{method,redirect:'manual',signal:AbortSignal.timeout(30000),
      headers:{'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
    check(response.ok,'GitCode 日志接口失败（HTTP '+response.status+'）');return response.json();
  };
  const release=await api('/tags/'+data.tag),source={tagName:data.tag,isDraft:false,isPrerelease:manifestChannel(data)==='beta'};
  const status=gitCodeReleaseStatus(source,data);
  check(release.tag_name===data.tag&&release.release_status===status&&release.prerelease===source.isPrerelease,'GitCode 发布渠道不符');
  const manifestUrl=`${base}/${data.tag}/attach_files/${manifestName}/download`;
  const oldContent=await readPublic(manifestUrl,{mirror:true}),previous=verifyManifest(JSON.parse(oldContent),publicKey);
  assertNotesOnlyChange(previous,data);
  const snapshot=assetSnapshot(release.assets),content=Buffer.from(JSON.stringify(envelope));
  if(!content.equals(oldContent)) {
    const descriptor=await api(`/${data.tag}/upload_url?file_name=${manifestName}`);
    validateUploadDescriptor(descriptor);
    await uploader(descriptor,content,{onProgress});
  }
  let verified=false;
  for(let attempt=0;attempt<5;attempt++) {
    const readBack=await readPublic(manifestUrl,{mirror:true});
    if(sha256(readBack)===sha256(content)){verifyManifest(JSON.parse(readBack),publicKey);verified=true;break;}
    if(attempt<4)await new Promise(r=>setTimeout(r,1000));
  }
  check(verified,'GitCode 新签名日志未读回，不宣称同步完成');
  const after=await api('/tags/'+data.tag);
  check(same(snapshot,assetSnapshot(after.assets))&&after.release_status===status&&after.prerelease===source.isPrerelease,'GitCode 安装包或发布状态发生变化');
  return data;
}

async function main() {
  const command=process.argv[2]??'github',publicKey=process.env.UPDATE_PUBLIC_KEY??'';
  const output=resolve('build/release-notes');await mkdir(output,{recursive:true});
  if(command==='gitcode') {
    const envelope=JSON.parse(await readFile(join(output,manifestName),'utf8'));
    await refreshGitCodeNotes({envelope,publicKey,token:process.env.GITCODE_TOKEN,onProgress:console.log});
    console.log('GitCode 更新日志和新签名已读回校验，安装包未改变。');return;
  }
  check(command==='github'&&process.env.GITHUB_REPOSITORY===repository,'只能在原仓库刷新日志');
  const tag=process.env.RELEASE_TAG;
  check(tag?.startsWith('v')&&versionPattern.test(tag.slice(1)),'发布标签无效');
  const api=async(path,{method='GET',body}={})=>{
    const response=await fetch(`https://api.github.com/repos/${repository}/${path}`,{
      method,redirect:'manual',signal:AbortSignal.timeout(30000),
      headers:{Accept:'application/vnd.github+json','User-Agent':'qqm-notes-refresh',Authorization:'Bearer '+process.env.GH_TOKEN,
        ...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});
    check(response.ok,'GitHub 日志接口失败（HTTP '+response.status+'）');return response.json();
  };
  const release=await api('releases/tags/'+tag);
  check(!release.draft&&!release.immutable,'发布尚未公开或已锁定');
  const original=release.assets.find(a=>a.name===manifestName);
  if(!original){console.log('安装包尚未完整发布，后续正常发布流程会使用最新日志。');return;}
  const previousContent=await publicBytes(original.browser_download_url);
  check(original.digest==='sha256:'+sha256(previousContent),'原清单下载摘要不符');
  await writeFile(join(output,'previous-manifest.json'),previousContent);
  const selected=updatedNotesManifest(JSON.parse(previousContent),release,publicKey,process.env.UPDATE_SIGNING_PRIVATE_KEY);
  assertPackageAssets(selected.data,release.assets);
  const snapshot=assetSnapshot(release.assets),content=Buffer.from(JSON.stringify(selected.envelope));
  await writeFile(join(output,manifestName),content);
  const upload=async(name,bytes)=>{
    const url=new URL(`https://uploads.github.com/repos/${repository}/releases/${release.id}/assets`);url.searchParams.set('name',name);
    const response=await fetch(url,{method:'POST',redirect:'manual',signal:AbortSignal.timeout(30000),
      headers:{'Content-Type':'application/json','User-Agent':'qqm-notes-refresh',Authorization:'Bearer '+process.env.GH_TOKEN},body:bytes});
    check(response.ok,'GitHub 新日志清单上传失败（HTTP '+response.status+'）');return response.json();
  };
  await replaceGitHubManifest({release,content,previousContent,api,upload});
  const after=await api('releases/'+release.id);
  check(after.tag_name===tag&&releaseChannel(after)===releaseChannel(release)&&same(snapshot,assetSnapshot(after.assets)),'安装包或发布状态发生变化');
  const live=after.assets.find(a=>a.name===manifestName);
  check(live?.digest==='sha256:'+sha256(content),'已发布的新日志清单摘要不符');
  const freshUrl=new URL(live.browser_download_url);freshUrl.searchParams.set('qqm_notes_revision',sha256(content));
  const readBack=await publicBytes(freshUrl);
  check(sha256(readBack)===sha256(content),'GitHub 新日志清单未读回');verifyManifest(JSON.parse(readBack),publicKey);
  check(process.env.WEBSITE_DIRECTORY,'缺少网站 checkout');
  let previousSite;
  try {previousSite=verifyManifest(JSON.parse(await readFile(join(process.env.WEBSITE_DIRECTORY,'updates',manifestChannel(selected.data)+'.json'),'utf8')),publicKey);}
  catch(error){if(error.code!=='ENOENT')throw error;}
  if(!previousSite||selected.data.build>=previousSite.build) {
    await syncWebsiteMetadata({directory:process.env.WEBSITE_DIRECTORY,publicKey,selected,allowNotesUpdate:true});
    await api('pages/builds',{method:'POST'});
  }
  if(process.env.GITHUB_OUTPUT)await (await import('node:fs/promises')).appendFile(process.env.GITHUB_OUTPUT,'ready=true\n');
  console.log('更新日志已重新签名并同步网站；版本、构建号和安装包完整性字段均未改变。');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  main().catch(error=>{console.error('刷新日志未完成：'+String(error?.message??'未知错误').replace(/https?:\/\/\S+/g,'[url]').split('\n')[0]);process.exitCode=1;});
}
