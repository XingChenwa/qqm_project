// Isolated localhost integration tests. No QQ credentials or production data.
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {spawn,spawnSync} from 'node:child_process';
import {generateKeyPairSync,randomBytes,verify,createHash} from 'node:crypto';
import assert from 'node:assert/strict';

const php=process.env.QQM_PHP||'php';
const phpArgs=process.env.QQM_PHP_EXT_DIR?['-d',`extension_dir=${process.env.QQM_PHP_EXT_DIR}`,'-d','extension=pdo_mysql','-d','extension=sodium','-d','extension=zip','-d','extension=curl']:[];
const root=resolve(import.meta.dirname,'..');
assert.ok(process.env.QQM_TEST_DATABASE_CONFIG,'Use the isolated MySQL test runner; never point tests at production.');
const testConfig=JSON.parse(await readFile(process.env.QQM_TEST_DATABASE_CONFIG,'utf8'));
const database={...testConfig.connection,name:testConfig.databases.http};
assert.ok(database.host==='127.0.0.1'&&database.port>=1024&&![3306,33060].includes(database.port)&&database.username==='qqm_test'&&/^qqm_test_http_[a-f0-9]{12}$/.test(database.name),'Refusing non-isolated test database.');
const directory=await mkdtemp(join(tmpdir(),'qqm-http-test-'));
const listener=createServer();await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve));const port=listener.address().port;await new Promise(resolve=>listener.close(resolve));
const origin=`http://127.0.0.1:${port}`;
const {privateKey,publicKey}=generateKeyPairSync('ed25519');
const rawPublic=publicKey.export({type:'spki',format:'der'}).subarray(-32),seed=privateKey.export({type:'pkcs8',format:'der'}).subarray(-32);
const settings={database,environment:'development',app_url:origin,uuze_client_id:'fixture-client',uuze_client_secret:'fixture-secret',signing_secret:Buffer.concat([seed,rawPublic]).toString('base64'),origin_token:'http-fixture-token',trusted_proxy_cidrs:[]};
await writeFile(join(directory,'config.json'),JSON.stringify(settings));
const initialize=spawnSync(php,[...phpArgs,join(root,'bin','manage.php'),'db-init'],{env:{...process.env,QQM_DATA_DIR:directory},encoding:'utf8'});assert.equal(initialize.status,0,initialize.stderr);
const fixture=join(directory,'fixture.zip');
const makeZip=spawnSync(php,[...phpArgs,'-r','$z=new ZipArchive();$z->open($argv[1],ZipArchive::CREATE);foreach(["qq_bot_manager.exe","flutter_windows.dll","data/app.so"] as $n){$z->addFromString($n,"MZfixture-only");}$z->close();',fixture],{encoding:'utf8'});assert.equal(makeZip.status,0,makeZip.stderr);
const server=spawn(php,[...phpArgs,'-S',`127.0.0.1:${port}`,'-t',join(root,'public'),join(root,'tests','router.php')],{env:{...process.env,QQM_DATA_DIR:directory},stdio:['ignore','pipe','pipe']});
let logs='';server.stderr.on('data',chunk=>logs+=chunk);let cookie='',csrf='',checks=0,proxyHeaders={};
async function request(path,options={}){const headers={...(cookie?{cookie}:{}),...proxyHeaders,...(options.headers||{})};if(options.json!==undefined){headers['content-type']='application/json';options.body=JSON.stringify(options.json);delete options.json;}const response=await fetch(origin+path,{...options,headers});const set=response.headers.get('set-cookie');if(set)cookie=set.split(';')[0];return response;}
function check(value,expected){assert.equal(value,expected);checks++;}
try{
  for(let attempt=0;attempt<80;attempt++){try{const response=await request('/');if(response.status===200)break;}catch{}await new Promise(resolve=>setTimeout(resolve,100));}
  const home=await request('/');check(home.status,200);assert.match(await home.text(),/选择你的平台/);checks++;
  check((await request('/assets/admin-v1.3.2.js')).status,200);
  check((await request('/privacy')).status,200);
  check((await request('/data/config.json')).status,404);
  check((await request('/api/admin/stats')).status,401);
  check((await request('/api/admin/proxy')).status,401);
  const session=await (await request('/api/admin/session')).json();csrf=session.csrf;
  check((await request('/api/admin/oauth/start',{method:'POST',json:{}})).status,403);
  async function start(){const result=await request('/api/admin/oauth/start',{method:'POST',headers:{'x-csrf-token':csrf},json:{}});check(result.status,200);return new URL((await result.json()).url);}
  let authorization=await start();check(authorization.origin,'https://account.uuze.cn');check(authorization.searchParams.has('client_secret'),false);
  let callback=await request('/api/admin/oauth/callback?code=test-admin-code&state=wrong-state',{redirect:'manual'});check(callback.status,303);check(callback.headers.get('location'),'/admin?login=denied');
  check((await request('/api/admin/stats')).status,401);
  authorization=await start();callback=await request('/api/admin/oauth/callback?code=test-other-code&state='+authorization.searchParams.get('state')+'&email=2377130783%40qq.com',{redirect:'manual'});check(callback.headers.get('location'),'/admin?login=denied');check((await request('/api/admin/stats')).status,401);
  authorization=await start();callback=await request('/api/admin/oauth/callback?code=test-no-email-code&state='+authorization.searchParams.get('state'),{redirect:'manual'});check(callback.headers.get('location'),'/admin?login=denied');
  authorization=await start();callback=await request('/api/admin/oauth/callback?code=test-admin-code&state='+authorization.searchParams.get('state'),{redirect:'manual'});check(callback.status,303);check(callback.headers.get('location'),'/admin?login=success');
  const authenticated=await(await request('/api/admin/session')).json();check(authenticated.authenticated,true);check(authenticated.admin.email,'2377130783@qq.com');check('oauth_access_token' in authenticated,false);csrf=authenticated.csrf;
  callback=await request('/api/admin/oauth/callback?code=test-admin-code&state='+authorization.searchParams.get('state'),{redirect:'manual'});check(callback.headers.get('location'),'/admin?login=denied');check((await(await request('/api/admin/session')).json()).authenticated,true);
  const empty=await (await request('/api/admin/stats')).json();check(empty.installations,0);
  const malformed=await request('/api/v1/telemetry/register',{method:'POST',json:{}});check(malformed.status,422);
  const fields={platform:'windows',version:'1.3.1',build:12,installation_id:'22222222-3333-4444-8555-666666666666',consent_version:'2',device_name:'HTTP测试电脑 🤖',device_model:'Test Laptop',system_version:'Windows 11',system_arch:'x64'};
  const registration=await request('/api/v1/telemetry/register',{method:'POST',headers:{'EO-Connecting-IP':'203.0.113.42'},json:fields});check(registration.status,201);const token=(await registration.json()).token;
  check((await request('/api/v1/telemetry/heartbeat',{method:'POST',headers:{authorization:'Bearer '+token},json:fields})).status,200);
  const stats=await (await request('/api/admin/stats')).json();check(stats.installations,1);check(stats.today,1);check(stats.devices[0].last_ip,'127.0.0.1');
  check(stats.devices[0].device_name,fields.device_name);check(stats.devices[0].system_version,fields.system_version);
  const form=new FormData();for(const [key,value]of Object.entries({platform:'windows',arch:'x64',format:'zip',version:'1.3.0',build:'12',notes:'HTTP integration fixture'}))form.append(key,value);form.append('package',new Blob([await readFile(fixture)]),'fixture.zip');
  const upload=await request('/api/admin/releases',{method:'POST',headers:{'x-csrf-token':csrf},body:form});check(upload.status,201);const release=await upload.json();check((await(await request('/api/v1/releases')).json()).releases.length,0);
  check((await request('/api/admin/releases/'+release.id,{method:'PATCH',headers:{'x-csrf-token':csrf,origin:'https://evil.invalid'},json:{published:true}})).status,403);
  check((await request('/api/admin/releases/'+release.id,{method:'PATCH',headers:{'x-csrf-token':csrf},json:{published:true}})).status,200);
  const nonce=randomBytes(16).toString('hex'),envelope=await(await request('/api/v1/update?platform=windows&arch=x64&nonce='+nonce)).json();
  check(verify(null,Buffer.from(envelope.payload,'base64'),publicKey,Buffer.from(envelope.signature,'base64')),true);check(JSON.parse(Buffer.from(envelope.payload,'base64')).nonce,nonce);
  const download=await fetch(release.url);check(download.status,200);check(createHash('sha256').update(Buffer.from(await download.arrayBuffer())).digest('hex'),release.sha256);
  const range=await fetch(release.url,{headers:{range:'bytes=0-3'}});check(range.status,206);check((await range.arrayBuffer()).byteLength,4);
  const invalidRange=await fetch(release.url,{headers:{range:'bytes=9999999999-'}});check(invalidRange.status,416);check(invalidRange.headers.get('cache-control'),'no-store');
  check((await request('/api/admin/releases/'+release.id,{method:'PATCH',headers:{'x-csrf-token':csrf},json:{published:false}})).status,200);
  check((await request('/api/v1/telemetry/installation',{method:'DELETE',headers:{authorization:'Bearer '+token}})).status,200);
  check((await(await request('/api/admin/stats')).json()).installations,0);
  const strictDiagnostic=await(await request('/api/admin/proxy',{headers:{'X-QQM-Origin-Token':settings.origin_token,'EO-Connecting-IP':'203.0.113.42'}})).json();
  check(strictDiagnostic.trust_mode,'cidr_and_token');check(strictDiagnostic.reason,'proxy_not_in_trusted_cidrs');
  // Reconfigure only the isolated fixture. Production files and signing identity are untouched.
  await writeFile(join(directory,'config.json'),JSON.stringify({...settings,proxy_trust_mode:'edgeone_token',require_origin_token:true}));
  check((await request('/api/v1/releases',{headers:{'EO-Connecting-IP':'203.0.113.42'}})).status,403);
  check((await request('/api/v1/releases',{headers:{'X-QQM-Origin-Token':'wrong','EO-Connecting-IP':'203.0.113.42'}})).status,403);
  proxyHeaders={'X-QQM-Origin-Token':settings.origin_token,'EO-Connecting-IP':'203.0.113.42'};
  const diagnosticResponse=await request('/api/admin/proxy');check(diagnosticResponse.status,200);
  const diagnosticText=await diagnosticResponse.text(),diagnostic=JSON.parse(diagnosticText);
  check(diagnostic.trust_mode,'edgeone_token');check(diagnostic.reason,'accepted');check(diagnostic.detected.ip,'203.0.113.42');
  check(diagnostic.origin_token_matches,true);check(diagnostic.trusted_cidrs_count,0);check(diagnostic.proxy_peer_trusted,false);
  check(diagnosticText.includes(settings.origin_token),false);check(diagnosticText.includes(settings.signing_secret),false);
  const freeRegistration=await request('/api/v1/telemetry/register',{method:'POST',json:fields});check(freeRegistration.status,201);
  const freeToken=(await freeRegistration.json()).token;
  let freeStats=await(await request('/api/admin/stats')).json();check(freeStats.devices[0].last_ip,'203.0.113.42');check(freeStats.devices[0].ip_source,'EO-Connecting-IP');
  check((await request('/api/v1/telemetry/heartbeat',{method:'POST',headers:{authorization:'Bearer '+freeToken,'EO-Connecting-IP':'2001:db8::42'},json:fields})).status,200);
  freeStats=await(await request('/api/admin/stats')).json();check(freeStats.devices[0].last_ip,'2001:db8::42');
  check((await request('/api/v1/telemetry/heartbeat',{method:'POST',headers:{authorization:'Bearer '+freeToken,'EO-Connecting-IP':'203.0.113.42, 1.1.1.1'},json:fields})).status,200);
  freeStats=await(await request('/api/admin/stats')).json();check(freeStats.devices[0].last_ip,'127.0.0.1');
  const stillSigned=await(await request('/api/v1/update?platform=windows&arch=x64&nonce='+randomBytes(16).toString('hex'))).json();
  check(verify(null,Buffer.from(stillSigned.payload,'base64'),publicKey,Buffer.from(stillSigned.signature,'base64')),true);
  check((await request('/api/v1/telemetry/installation',{method:'DELETE',headers:{authorization:'Bearer '+freeToken}})).status,200);
  check((await request('/api/admin/logout',{method:'POST',headers:{'x-csrf-token':csrf},json:{confirm:true}})).status,200);
  check((await request('/api/admin/stats')).status,401);
  await writeFile(join(directory,'config.json'),JSON.stringify(settings));proxyHeaders={};
  console.log(`HTTP integration: ${checks} checks passed.`);
  if(process.env.QQM_BROWSER_TEST==='1'){const {runBrowserQA}=await import('./browser.mjs');await runBrowserQA(origin,true);}
}finally{
  server.kill();await new Promise(resolve=>server.once('exit',resolve));
  // mkdtemp returned a task-owned temporary directory; never clean a computed broad path.
  assert.ok(directory.startsWith(join(tmpdir(),'qqm-http-test-')));await rm(directory,{recursive:true,force:false});
}
