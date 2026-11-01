import { pathToFileURL } from 'node:url';
let fallback;
export function initialize(data) { fallback = data.fallback; }
export async function resolve(specifier, context, nextResolve) {
  try { return await nextResolve(specifier, context); }
  catch (error) {
    if (!['ERR_MODULE_NOT_FOUND', 'MODULE_NOT_FOUND', 'ERR_PACKAGE_IMPORT_NOT_DEFINED'].includes(error.code)) throw error;
    if (['#yunzai', 'icqq', 'oicq'].includes(specifier)) {
      return { url: new URL(specifier === '#yunzai' ? './shim-yunzai.mjs' : './shim-segment.mjs', import.meta.url).href, shortCircuit: true };
    }
    if (specifier.startsWith('.') && /\/lib\/(plugins\/plugin|puppeteer\/puppeteer|common\/common)\.js$/.test(specifier.replaceAll('\\', '/'))) {
      const name = /plugins\/plugin/.test(specifier) ? 'plugin' : /puppeteer/.test(specifier) ? 'puppeteer' : 'common';
      return { url: new URL(`shim-${name}.mjs`, import.meta.url).href, shortCircuit: true };
    }
    if (!specifier.startsWith('.') && !specifier.startsWith('#') && !specifier.includes(':') && context.parentURL !== fallback) {
      return nextResolve(specifier, { ...context, parentURL: fallback });
    }
    throw error;
  }
}
