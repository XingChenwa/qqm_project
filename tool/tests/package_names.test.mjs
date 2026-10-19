import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, mkdtemp, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {assetDefinitions, readVersion} from '../github_release_core.mjs';
import {packageNames} from '../package_names.mjs';

test('四端安装包和 Actions 下载 ZIP 都包含完整版本与构建号', () => {
  const names = packageNames('1.3.8-beta.3', 22);
  assert.equal(names.android_file, 'qqbotmanager-android-v1.3.8-beta.3-build22.apk');
  assert.equal(names.ios_file, 'qqbotmanager-ios-v1.3.8-beta.3-build22-unsigned.ipa');
  assert.equal(names.macos_file, 'qqbotmanager-macos-v1.3.8-beta.3-build22-universal.dmg');
  assert.equal(names.windows_file, 'qqbotmanager-windows-v1.3.8-beta.3-build22-setup.exe');
  for (const value of Object.values(names)) {
    assert.match(value, /v1\.3\.8-beta\.3-build22/);
    assert.match(value, /^[A-Za-z0-9._-]+$/);
  }
  assert.equal(new Set(Object.values(names)).size, Object.keys(names).length);
});

test('拒绝路径和异常构建号；构建步骤使用同一命名源', async () => {
  for (const version of ['../../evil','1.3.8/evil','1.3.8;cmd','1.3.8\nvalue'])
    assert.throws(()=>assetDefinitions(version,22));
  for (const build of [0,-1,1.2,2147483648]) assert.throws(()=>assetDefinitions('1.3.8',build));
  const workflow = await readFile('.github/workflows/mobile-build.yml','utf8');
  assert.equal((workflow.match(/node tool\/package_names\.mjs github-output/g)||[]).length,4);
  for (const platform of ['windows','android','ios','macos'])
    assert.ok(workflow.includes('name: ${{ steps.packages.outputs.'+platform+'_artifact }}'));
  const info=readVersion(await readFile('pubspec.yaml','utf8'),await readFile('lib/utils/constants.dart','utf8'));
  for (const asset of assetDefinitions(info.version,info.build))
    assert.ok(asset.name.includes('v'+info.version+'-build'+info.build));
});

test('CLI 写入的每个 GitHub output 独占一行，不输出字面量反斜线', async t => {
  const root = await mkdtemp(join(tmpdir(),'qqm-package-names-test-'));
  t.after(async()=>{
    assert.ok(root.startsWith(join(tmpdir(),'qqm-package-names-test-')));
    await rm(root,{recursive:true});
  });
  const output = join(root,'output.txt');
  execFileSync(process.execPath,['tool/package_names.mjs','github-output'],{
    env:{...process.env,GITHUB_OUTPUT:output},stdio:['ignore','pipe','pipe'],
  });
  const lines=(await readFile(output,'utf8')).trim().split('\n');
  assert.equal(lines.length,9);
  assert.ok(lines.every(line=>/^[a-z_]+=[A-Za-z0-9._-]+$/.test(line)));
  assert.ok(!lines.some(line=>line.includes('\\')));
});
