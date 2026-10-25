// Resume an incomplete release using the original four clients and a packaging-
// only Linux repair. Never move a tag, replace an asset, or re-sign a full release.
import {execFileSync} from 'node:child_process';
import {readFile, writeFile, appendFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {assetDefinitions, manifestName, readVersion, repository, versionPattern} from './github_release_core.mjs';
import {packageNames} from './package_names.mjs';

const packagingFiles = new Set([
  'tool/native_agent/CMakeLists.txt', 'scripts/build_linux_agent.sh',
  'scripts/build_linux_server.sh', 'scripts/test_linux_distros.sh',
  'tool/github_release.mjs', 'tool/recover_release.mjs',
  'tool/tests/release_recovery.test.mjs', '.github/workflows/release-recovery.yml',
]);
const check = (value, message) => { if (!value) throw new Error(message); };
const success = (jobs, name) => jobs.some(j => j.name === name && j.status === 'completed' && j.conclusion === 'success');

export function validateRecovery({tag, release, sourceRun, linuxRun, sourceJobs, linuxJobs, sourceArtifacts, linuxArtifacts, info, tagSha, head, changes}) {
  check(typeof tag === 'string' && tag.startsWith('v') && versionPattern.test(tag.slice(1)) && info.tag === tag, '恢复标签与源码版本不一致');
  check(release?.tag_name === tag && release.draft === false && release.prerelease === tag.includes('-') && release.published_at, 'Release 状态或渠道不符合恢复条件');
  check(!release.assets.some(a => a.name === manifestName), '版本已有完整签名清单，拒绝重建或覆盖');
  for (const run of [sourceRun, linuxRun]) {
    check(run?.repository?.full_name === repository && run.head_repository?.full_name === repository && run.path === '.github/workflows/mobile-build.yml' && run.status === 'completed', '构建不属于本仓库已完成的安装包流程');
    check(Number.isSafeInteger(run.id) && run.id > 0, '构建 ID 无效');
  }
  check(sourceRun.id !== linuxRun.id && sourceRun.event === 'release' && sourceRun.head_branch === tag && sourceRun.head_sha === tagSha, '原构建不属于此发布标签');
  check(linuxRun.event === 'workflow_dispatch' && linuxRun.head_branch === 'main' && linuxRun.head_sha === head && linuxRun.conclusion === 'success', 'Linux 修复构建与当前工具提交不一致');
  check(changes.length > 0 && changes.every(file => packagingFiles.has(file)), '修复包含应用源码改动，不能复用原客户端或发布标签');
  const definitions = assetDefinitions(info.version, info.build);
  for (const asset of definitions) {
    check(success(sourceJobs, asset.platform), `${asset.platform} 原构建没有成功`);
    check(sourceArtifacts.some(a => a.name === asset.directory && !a.expired && a.size_in_bytes > 0), `${asset.platform} 原产物缺失或已过期`);
  }
  const linuxName = packageNames(info.version, info.build).linux_artifact;
  check(success(linuxJobs, 'linux') && linuxArtifacts.some(a => a.name === linuxName && !a.expired && a.size_in_bytes > 0), 'Linux 修复产物未通过检查');
  return {source_run: sourceRun.id, linux_run: linuxRun.id, tag};
}

async function main() {
  check(process.env.GITHUB_REPOSITORY === repository, '恢复只能在原仓库 Actions 运行');
  const tag = process.env.RELEASE_TAG;
  const ids = [process.env.SOURCE_RUN_ID, process.env.LINUX_RUN_ID];
  check(typeof tag === 'string' && tag.startsWith('v') && versionPattern.test(tag.slice(1)) && ids.every(x => /^[1-9]\d*$/.test(x ?? '') && Number.isSafeInteger(Number(x))), '标签或构建 ID 无效');
  const gh = (...args) => execFileSync('gh', args, {encoding:'utf8', maxBuffer:4*1024*1024, stdio:['ignore','pipe','pipe']});
  const api = path => JSON.parse(gh('api', `repos/${repository}/${path}`));
  const [sourceId, linuxId] = ids;
  const release = api(`releases/tags/${tag}`);
  const sourceRun = api(`actions/runs/${sourceId}`), linuxRun = api(`actions/runs/${linuxId}`);
  const tagSha = api(`commits/${tag}`).sha;
  const git = (...args) => execFileSync('git', args, {encoding:'utf8', stdio:['ignore','pipe','pipe']}).trim();
  git('merge-base', '--is-ancestor', tagSha, 'HEAD');
  const head = git('rev-parse', 'HEAD');
  const changes = git('diff', '--name-only', `${tagSha}..HEAD`).split('\n').filter(Boolean);
  const info = readVersion(await readFile('pubspec.yaml','utf8'), await readFile('lib/utils/constants.dart','utf8'));
  const output = validateRecovery({tag, release, sourceRun, linuxRun, tagSha, head, changes, info,
    sourceJobs:api(`actions/runs/${sourceId}/jobs?per_page=100`).jobs,
    linuxJobs:api(`actions/runs/${linuxId}/jobs?per_page=100`).jobs,
    sourceArtifacts:api(`actions/runs/${sourceId}/artifacts?per_page=100`).artifacts,
    linuxArtifacts:api(`actions/runs/${linuxId}/artifacts?per_page=100`).artifacts});
  check(process.env.RELEASE_EVENT_PATH && process.env.GITHUB_OUTPUT, '缺少 Actions 输出路径');
  await writeFile(process.env.RELEASE_EVENT_PATH, JSON.stringify({release})+'\n');
  await appendFile(process.env.GITHUB_OUTPUT, Object.entries(output).map(([k,v]) => `${k}=${v}`).join('\n')+'\n');
  console.log(JSON.stringify({validated:true, ...output, source_sha:tagSha, packaging_sha:head, packaging_files:changes}));
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message.split('\n')[0]); process.exitCode=1; });
}
