// Node.js HTTP 插件示例：无依赖、只监听回环，不记录消息/令牌，不调用 QQ API。
import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export function createEchoServer(token) {
  if (!token || !/^[\x21-\x7e]+$/.test(token)) throw new Error('请设置 QQM_PLUGIN_TOKEN（可见 ASCII，无空格）。');
  const expected = Buffer.from(`Bearer ${token}`);
  const server = createServer(async (request, response) => {
    const send = (status, body) => {
      if (response.destroyed || response.writableEnded) return;
      const bytes = Buffer.from(JSON.stringify(body));
      response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': bytes.length });
      response.end(bytes);
    };
    if (request.method !== 'POST' || request.url !== '/qqbot') return send(404, { error: 'not_found' });
    const supplied = Buffer.from(request.headers.authorization ?? '');
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return send(401, { error: 'unauthorized' });
    const length = Number(request.headers['content-length']);
    if (!Number.isSafeInteger(length) || length <= 0 || length > 65536) return send(413, { error: 'body_too_large' });
    try {
      const chunks = [];
      let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        if (size > 65536) { send(413, { error: 'body_too_large' }); return; }
        chunks.push(chunk);
      }
      const event = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!event || event.schema_version !== 1 || event.plugin_id !== 'custom_http_echo' || typeof event.text !== 'string') return send(400, { error: 'invalid_request' });
      if (!['echo', '复读'].includes(event.command)) return send(200, { reply: null });
      if (event.text.length > 12000) return send(200, { message: { format: 'text', content: '复读最多 12000 字符。' } });
      return send(200, { message: { format: 'text', content: event.text || '用法：/echo 想复读的内容' } });
    } catch { send(400, { error: 'invalid_request' }); }
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  server.timeout = 10000;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = createEchoServer(process.env.QQM_PLUGIN_TOKEN?.trim());
  server.listen(8787, '127.0.0.1', () => process.stdout.write('HTTP 插件示例：http://127.0.0.1:8787/qqbot（仅本地开发）\n'));
}
