import plugin from '../../../lib/plugins/plugin.js';
import fs from 'node:fs/promises';
import http from 'node:http';

const labelFile = new URL('../config/label.txt', import.meta.url);
const countFile = new URL('../data/count.txt', import.meta.url);
export class OriginalDemo extends plugin {
  constructor() {
    super({ name: '原版示例', event: 'message', priority: 20,
      rule: [{ reg: '^#原包测试$', fnc: 'greet' },
        { reg: '^#图片测试$', fnc: 'picture' },
        { reg: '^#原生发送$', fnc: 'nativeSend' },
        { reg: '^#上下文测试$', fnc: 'contextTest' }] });
  }
  async init() {
    if (typeof http.createServer !== 'function') throw new Error('node:http missing');
    await fs.mkdir(new URL('../data/', import.meta.url), { recursive: true });
    await fs.mkdir(new URL('../config/', import.meta.url), { recursive: true });
    try { await fs.writeFile(labelFile, '默认配置', { flag: 'wx' }); } catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  async nativeSend(e) { await Bot.pickGroup(e.group_id).sendMsg('原生接口回复'); return true; }
  async greet(e) {
    const label = await fs.readFile(labelFile, 'utf8');
    let count = 0; try { count = Number(await fs.readFile(countFile, 'utf8')); } catch {}
    await fs.writeFile(countFile, String(count + 1));
    await e.reply(`原包测试：${label} / ${count + 1}`);
    return true;
  }
  async picture(e) {
    return e.reply(segment.image(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6psYAAAAASUVORK5CYII=', 'base64')));
  }
  async contextTest(e) { this.setContext('continueTest'); await e.reply('请继续发送任意文字'); }
  async continueTest(e) { this.finish('continueTest'); await e.reply(`上下文：${e.msg}`); }
}
