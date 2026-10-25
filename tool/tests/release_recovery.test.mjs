import test from 'node:test';
import assert from 'node:assert/strict';
import {validateRecovery} from '../recover_release.mjs';
import {assetDefinitions, repository} from '../github_release_core.mjs';
import {packageNames} from '../package_names.mjs';

function fixture() {
  const info={version:'1.4.1-beta.1',build:35,tag:'v1.4.1-beta.1'}, tag=info.tag;
  const run={repository:{full_name:repository},head_repository:{full_name:repository},path:'.github/workflows/mobile-build.yml',status:'completed'};
  return {info,tag,head:'b'.repeat(40),tagSha:'a'.repeat(40),changes:['scripts/build_linux_agent.sh'],
    release:{tag_name:tag,draft:false,prerelease:true,published_at:'2026-10-25T00:00:00Z',assets:[{name:'skills-yy-tts.zip'}]},
    sourceRun:{...run,id:123,event:'release',head_branch:tag,head_sha:'a'.repeat(40),conclusion:'failure'},
    linuxRun:{...run,id:124,event:'workflow_dispatch',head_branch:'main',head_sha:'b'.repeat(40),conclusion:'success'},
    sourceJobs:['windows','android','ios','macos'].map(name=>({name,status:'completed',conclusion:'success'})),
    linuxJobs:[{name:'linux',status:'completed',conclusion:'success'}],
    sourceArtifacts:assetDefinitions(info.version,info.build).map(a=>({name:a.directory,expired:false,size_in_bytes:100})),
    linuxArtifacts:[{name:packageNames(info.version,info.build).linux_artifact,expired:false,size_in_bytes:100}]};
}
test('只修包装时可复用同一发布提交已通过的四端产物，允许额外Skill附件',()=>{
  assert.deepEqual(validateRecovery(fixture()),{source_run:123,linux_run:124,tag:'v1.4.1-beta.1'});
});
test('已有完整清单、渠道变化及应用源码变化均拒绝',()=>{
  for(const change of [f=>f.release.assets.push({name:'update-manifest.json'}),f=>{f.release.prerelease=false;},f=>f.changes.push('lib/main.dart'),f=>{f.info.tag='v1.4.0';}]){
    const f=fixture();change(f);assert.throws(()=>validateRecovery(f));
  }
});
test('不能复用其他标签、仓库、工作流或未完成构建',()=>{
  for(const change of [f=>{f.sourceRun.head_sha='c'.repeat(40);},f=>{f.sourceRun.head_branch='v1.4.0';},f=>{f.sourceRun.head_repository={full_name:'example/fork'};},f=>{f.linuxRun.path='other.yml';},f=>{f.linuxRun.status='in_progress';},f=>{f.linuxRun.head_sha='c'.repeat(40);}]){
    const f=fixture();change(f);assert.throws(()=>validateRecovery(f));
  }
});
test('客户端失败、缺失或过期以及Linux检查失败均拒绝签名发布',()=>{
  for(const change of [f=>{f.sourceJobs[0].conclusion='failure';},f=>f.sourceArtifacts.pop(),f=>{f.sourceArtifacts[0].expired=true;},f=>{f.linuxJobs[0].conclusion='failure';},f=>f.linuxArtifacts.pop()]){
    const f=fixture();change(f);assert.throws(()=>validateRecovery(f));
  }
});
