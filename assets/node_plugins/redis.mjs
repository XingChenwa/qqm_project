import fs from 'node:fs/promises';

// The upstream uses a small Redis subset for expiring caches and API counters.
// Keep it local to the AppID; no external Redis installation is required.
export async function createRedis(file) {
  let data = {};
  try { data = JSON.parse(await fs.readFile(file, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  let timer;
  let writing = Promise.resolve();
  const read = key => {
    const item = data[String(key)];
    if (!item || item.until && item.until <= Date.now()) {
      delete data[String(key)];
      return null;
    }
    return item.value;
  };
  const flush = () => {
    clearTimeout(timer);
    timer = undefined;
    const json = JSON.stringify(data);
    writing = writing.catch(() => {}).then(async () => {
      await fs.writeFile(`${file}.tmp`, json, { mode: 0o600 });
      await fs.rename(`${file}.tmp`, file);
    });
    return writing;
  };
  const changed = () => { timer ??= setTimeout(() => { flush().catch(() => {}); }, 500).unref(); };
  return {
    get: async key => read(key),
    exists: async key => read(key) === null ? 0 : 1,
    set: async (key, value, options = {}) => {
      data[String(key)] = { value: String(value), until: options.EX ? Date.now() + options.EX * 1000 : 0 };
      changed(); return 'OK';
    },
    expire: async (key, seconds) => {
      if (read(key) === null) return 0;
      data[String(key)].until = Date.now() + seconds * 1000;
      changed(); return 1;
    },
    incr: async key => {
      const value = Number(read(key) || 0) + 1;
      data[String(key)] = { value: String(value), until: data[String(key)]?.until || 0 };
      changed(); return value;
    },
    mGet: async keys => keys.map(read),
    scan: async (cursor, { MATCH = '*', COUNT = 100 } = {}) => {
      const pattern = new RegExp(`^${MATCH.split('*').map(s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`);
      const keys = Object.keys(data).filter(k => read(k) !== null && pattern.test(k));
      const start = Number(cursor) || 0;
      return { cursor: start + COUNT >= keys.length ? 0 : start + COUNT, keys: keys.slice(start, start + COUNT) };
    },
    flush,
  };
}
