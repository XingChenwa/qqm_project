"""标准库 HTTP 插件示例，只监听本机，不记录消息正文或令牌。"""

import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class EchoHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, status, data):
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path != "/qqbot":
            return self.send_json(404, {"error": "not_found"})
        expected = "Bearer " + self.server.plugin_token
        if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            return self.send_json(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                return self.send_json(413, {"error": "body_too_large"})
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict) or data.get("schema_version") != 1:
                return self.send_json(400, {"error": "invalid_request"})
            if data.get("command") not in ("echo", "复读"):
                return self.send_json(200, {"reply": None})
            text = data.get("text", "")
            if not isinstance(text, str):
                return self.send_json(400, {"error": "invalid_text"})
            return self.send_json(200, {"reply": text or "用法：/echo 想复读的内容"})
        except (ValueError, UnicodeError):
            return self.send_json(400, {"error": "invalid_json"})


def main():
    token = os.environ.get("QQM_PLUGIN_TOKEN", "").strip()
    if not token:
        raise SystemExit("请先设置环境变量 QQM_PLUGIN_TOKEN，并在插件配置填写相同令牌。")
    server = ThreadingHTTPServer(("127.0.0.1", 8787), EchoHandler)
    server.plugin_token = token
    print("HTTP 示例监听 http://127.0.0.1:8787/qqbot（仅本机开发，请勿直接暴露到公网）。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
