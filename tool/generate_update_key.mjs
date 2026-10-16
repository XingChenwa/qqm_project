// Run locally only if you do not have the ORIGINAL update signing key.
import {generateKeyPairSync} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {resolve, relative, isAbsolute} from 'node:path';
const output = process.argv[2];
if (!output || !isAbsolute(output) || !output.endsWith('.ed25519.key')) throw new Error('请指定源码目录之外的绝对输出路径，后缀 .ed25519.key；现有客户端优先复用原私钥');
const target = resolve(output);
const workspace = resolve(import.meta.dirname, '..');
const within = relative(workspace, target);
if (!within || (!within.startsWith('..') && !isAbsolute(within))) throw new Error('私钥不能写进源码目录');
const {privateKey, publicKey} = generateKeyPairSync('ed25519');
writeFileSync(target, privateKey.export({format: 'der', type: 'pkcs8'}).subarray(-32).toString('base64'), {flag: 'wx', mode: 0o600});
console.log('UPDATE_PUBLIC_KEY=' + publicKey.export({format: 'der', type: 'spki'}).subarray(-32).toString('base64'));
console.log('私钥已写入指定文件，请仅保存到 GitHub Actions Secret，不要提交或发到聊天。Windows 请限制该文件 ACL。');
