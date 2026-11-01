// Build the same QuickJS dependency for host-side tests before Flutter compiles
// the platform application. No app data or configuration is read by this step.
import {execFileSync} from 'node:child_process';
import {readFile, appendFile, access} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const configuration = resolve('.dart_tool/package_config.json');
const packages = JSON.parse(await readFile(configuration, 'utf8')).packages;
const qjs = packages.find(p => p.name === 'flutter_qjs_next');
if (!qjs) throw Error('Run flutter pub get before preparing the test engine');
const packagePath = fileURLToPath(new URL(qjs.rootUri, pathToFileURL(configuration)));
const output = resolve('build/agent-ci-native');
const run = (...args) => execFileSync('cmake', args, {stdio:'inherit', windowsHide:true});
run('-S', 'tool/native_agent', '-B', output, '-DCMAKE_BUILD_TYPE=Release', '-DQJS_PACKAGE='+packagePath);
run('--build', output, '--config', 'Release', '--parallel', '2');
const library = process.platform === 'win32' ? join(output, 'Release', 'qqm_agent_js.dll') :
  join(output, process.platform === 'darwin' ? 'libqqm_agent_js.dylib' : 'libqqm_agent_js.so');
await access(library);
if (process.env.GITHUB_ENV) await appendFile(process.env.GITHUB_ENV, 'FLUTTER_QJS_NEXT_LIBRARY='+library+'\n');
console.log('Host test engine ready: '+library);
