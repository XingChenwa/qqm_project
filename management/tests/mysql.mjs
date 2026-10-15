// Starts a NEW local database instance under build. Never uses or changes installed services.
import {mkdtemp,readFile,writeFile,access,mkdir,copyFile} from 'node:fs/promises';
import {join,resolve,dirname} from 'node:path';
import {createServer,connect} from 'node:net';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';

const root=resolve(import.meta.dirname,'..'),workspace=resolve(root,'..');
assert.ok(process.env.QQM_MYSQL_BIN,'Set QQM_MYSQL_BIN to a MySQL/MariaDB bin directory. Do not supply production credentials.');
const bin=resolve(process.env.QQM_MYSQL_BIN),suffix=process.platform==='win32'?'.exe':'';
const php=process.env.QQM_PHP||'php';
const phpArgs=process.env.QQM_PHP_EXT_DIR?['-d',`extension_dir=${process.env.QQM_PHP_EXT_DIR}`,...['pdo_mysql','sodium','zip','curl'].flatMap(x=>['-d',`extension=${x}`])]:[];
// Optional task-owned scratch disk for machines with little workspace disk space.
const fixtureParent=resolve(process.env.QQM_TEST_FIXTURE_DIR||join(workspace,'build'));
await mkdir(fixtureParent,{recursive:true});
const fixture=await mkdtemp(join(fixtureParent,'qqm-mysql-test-')),datadir=join(fixture,'mysql-data');
const reservation=createServer();await new Promise(r=>reservation.listen(0,'127.0.0.1',r));const port=reservation.address().port;await new Promise(r=>reservation.close(r));
assert.ok(![3306,33060].includes(port));
const id=randomBytes(6).toString('hex'),connection={host:'127.0.0.1',port,username:'qqm_test',password:randomBytes(32).toString('hex'),socket:'',ssl_ca:''};
const databases=Object.fromEntries(['core','oauth','http','schema','cli','preview','install'].map(suite=>[suite,`qqm_test_${suite}_${id}`]));
const configFile=join(fixture,'test-database.json');await writeFile(configFile,JSON.stringify({connection,databases}),{mode:0o600});
const env={...process.env,QQM_TEST_DATABASE_CONFIG:configFile};
async function exists(path){try{await access(path);return true}catch{return false}}
async function run(command,args,extraEnv={}){
  const child=spawn(command,args,{env:{...env,...extraEnv},stdio:['ignore','pipe','pipe'],windowsHide:true});
  let output='';child.stdout.on('data',x=>output+=x);child.stderr.on('data',x=>output+=x);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve)});
  assert.equal(code,0,output);if(output.trim())console.log(output.trim());
}
const mariadbInit=join(bin,'mariadb-install-db'+suffix),mysqld=join(bin,'mysqld'+suffix);
console.log('Initializing task-owned MySQL protocol test instance (not an installed service).');
if(await exists(mariadbInit))await run(mariadbInit,[`--datadir=${datadir}`,`--port=${port}`,'--silent']);
else await run(mysqld,['--no-defaults','--initialize-insecure',`--basedir=${dirname(bin)}`,`--datadir=${datadir}`]);
const server=spawn(mysqld,['--no-defaults',`--basedir=${dirname(bin)}`,`--datadir=${datadir}`,'--bind-address=127.0.0.1',`--port=${port}`,'--max-connections=20','--innodb-buffer-pool-size=32M','--skip-log-bin',`--log-error=${join(fixture,'mysql-error.log')}`,`--pid-file=${join(fixture,'mysql.pid')}`],{env,stdio:['ignore','pipe','pipe'],windowsHide:true});
let startup='';server.stderr.on('data',x=>startup+=x);server.stdout.on('data',x=>startup+=x);server.on('error',x=>startup+=x.message);
async function listening(){return await new Promise(r=>{const socket=connect({host:'127.0.0.1',port});socket.setTimeout(500);socket.once('connect',()=>{socket.destroy();r(true)});socket.once('error',()=>r(false));socket.once('timeout',()=>{socket.destroy();r(false)})})}
try{
  let ready=false;for(let i=0;i<200;i++){if(await listening()){ready=true;break}if(server.exitCode!==null)break;await new Promise(r=>setTimeout(r,100))}
  assert.ok(ready,`Isolated server did not start: ${startup}; inspect ${fixture}`);
  await run(php,[...phpArgs,join(root,'tests','setup-mysql.php')]);
  await run(php,[...phpArgs,join(root,'tests','configuration.php')]);
  await run(process.execPath,[join(root,'tests','startup.mjs')]);
  // Fresh upload with no config.php, no config.json AND no example: installer must still recover.
  const installRoot=join(fixture,'fresh-install'),installData=join(installRoot,'data');
  for(const relative of ['src/Core.php','src/Configuration.php','bin/manage.php','database/schema.sql']){
    const target=join(installRoot,relative);await mkdir(dirname(target),{recursive:true});await copyFile(join(root,relative),target);
  }
  const firstInstall=spawn(php,[...phpArgs,join(installRoot,'bin','manage.php'),'install'],{env:{...env,QQM_DATA_DIR:installData},stdio:['ignore','pipe','pipe'],windowsHide:true});
  let firstOutput='';firstInstall.stdout.on('data',x=>firstOutput+=x);firstInstall.stderr.on('data',x=>firstOutput+=x);
  assert.equal(await new Promise((resolve,reject)=>{firstInstall.once('error',reject);firstInstall.once('exit',resolve)}),1,'First install must request real database credentials.');
  assert.match(firstOutput,/config\.php/);assert.doesNotMatch(firstOutput,/Warning|Fatal error/);
  assert.ok(await exists(join(installRoot,'config.php')));
  const firstSecrets=await readFile(join(installData,'config.json'),'utf8');
  const manualSettings={database:{...connection,name:databases.install},uuze_client_id:'fixture-client',uuze_client_secret:'fixture-oauth-secret'};
  const phpConfig='<?php return json_decode('+JSON.stringify(JSON.stringify(manualSettings))+', true, 32, JSON_THROW_ON_ERROR);\n';
  // JSON escapes are valid in a PHP double-quoted string except for interpolation; fixture values contain no dollar signs.
  await writeFile(join(installRoot,'config.php'),phpConfig,{mode:0o600});
  for(let attempt=0;attempt<2;attempt++)await run(php,[...phpArgs,join(installRoot,'bin','manage.php'),'install'],{QQM_DATA_DIR:installData});
  await run(php,[...phpArgs,join(installRoot,'bin','manage.php'),'db-check'],{QQM_DATA_DIR:installData});
  assert.equal(await readFile(join(installData,'config.json'),'utf8'),firstSecrets,'Repeated install must preserve exact private configuration.');
  assert.equal(await readFile(join(installRoot,'config.php'),'utf8'),phpConfig,'Installer must not overwrite edited PHP settings.');
  assert.ok(!firstOutput.includes(JSON.parse(firstSecrets).signing_secret),'Installer must not print private keys.');
  console.log('Fresh install without configuration/template, MySQL install and idempotence passed.');
  const cliDir=join(fixture,'cli-config');
  const sodiumOnly=process.env.QQM_PHP_EXT_DIR?['-d',`extension_dir=${process.env.QQM_PHP_EXT_DIR}`,'-d','extension=sodium']:[];
  await run(php,[...sodiumOnly,join(root,'bin','manage.php'),'init'],{QQM_DATA_DIR:cliDir});
  const generated=JSON.parse(await readFile(join(cliDir,'config.json'),'utf8'));const originalKey=generated.signing_secret;
  generated.database={...connection,name:databases.cli};await writeFile(join(cliDir,'config.json'),JSON.stringify(generated),{mode:0o600});
  await run(php,[...phpArgs,join(root,'bin','manage.php'),'db-init'],{QQM_DATA_DIR:cliDir});
  await run(php,[...phpArgs,join(root,'bin','manage.php'),'db-init'],{QQM_DATA_DIR:cliDir});
  await run(php,[...phpArgs,join(root,'bin','manage.php'),'db-check'],{QQM_DATA_DIR:cliDir});
  assert.ok(JSON.parse(await readFile(join(cliDir,'config.json'),'utf8')).signing_secret===originalKey,'Database initialization must preserve signing keys.');
  for(const file of ['mysql-check.php','run.php','oauth.php'])await run(php,[...phpArgs,join(root,'tests',file)]);
  await run(process.execPath,[join(root,'tests','http.mjs')]);
  console.log('All MySQL protocol/CLI/backend/OAuth/HTTP tests passed.');
}finally{
  if(server.exitCode===null){
    const admin=join(bin,(await exists(join(bin,'mariadb-admin'+suffix))?'mariadb-admin':'mysqladmin')+suffix);
    try{await run(admin,['--no-defaults','--protocol=tcp','--host=127.0.0.1',`--port=${port}`,'--user=root','shutdown'])}catch{server.kill()}
    if(server.exitCode===null)await new Promise(r=>server.once('exit',r));
  }
  console.log('Stopped only the task-created test database. Fixture retained for inspection: '+fixture);
}
