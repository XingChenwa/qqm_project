// Exercise the actual production bootstrap, without any database or external OAuth calls.
import {mkdtemp,mkdir,copyFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';

const root=resolve(import.meta.dirname,'..'),php=process.env.QQM_PHP||'php';
const fixture=await mkdtemp(join(tmpdir(),'qqm-startup-test-')),data=join(fixture,'data');
let checks=0;
function checkStartup(expected){
  const result=spawnSync(php,['-d','display_errors=1','-r','register_shutdown_function(function(){fwrite(STDERR,"status=".http_response_code());}); require $argv[1];',join(fixture,'public','index.php')],{env:{...process.env,QQM_DATA_DIR:data},encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  const body=JSON.parse(result.stdout);
  assert.match(body.error,expected);assert.match(result.stderr,/status=503/);
  assert.doesNotMatch(result.stdout,/fixture-password-marker|Warning|Fatal error|Parse error/);checks++;
}
try{
  await mkdir(data,{recursive:true});
  for(const relative of ['src/Core.php','src/Configuration.php','src/AccountLogin.php','src/Http.php','public/index.php']){
    await mkdir(dirname(join(fixture,relative)),{recursive:true});await copyFile(join(root,relative),join(fixture,relative));
  }
  checkStartup(/尚未安装/);
  await writeFile(join(data,'config.json'),'{"password": fixture-password-marker}');checkStartup(/JSON 格式错误/);
  await writeFile(join(data,'config.json'),'[]');checkStartup(/顶层/);
  await writeFile(join(data,'config.json'),'{}');
  await writeFile(join(fixture,'config.php'),'<?php return ["database" => fixture-password-marker];');checkStartup(/PHP 格式错误/);
  await writeFile(join(fixture,'config.php'),'<?php return "invalid";');checkStartup(/返回配置数组/);
  await writeFile(join(fixture,'config.php'),'<?php return ["database" => null];');checkStartup(/database 配置必须/);
  await rm(join(data,'config.json'));
  await writeFile(join(fixture,'config.php'),'<?php return ["database" => ["name" => "fixture", "username" => "fixture", "password" => "fixture-password-marker"]];');
  checkStartup(/安装尚未完成/);
  console.log(`Production startup: ${checks} safe configuration error cases passed.`);
}finally{
  assert.ok(dirname(fixture)===tmpdir()&&fixture.startsWith(join(tmpdir(),'qqm-startup-test-')));
  await rm(fixture,{recursive:true,force:false});
}
