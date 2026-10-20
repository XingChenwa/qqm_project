"""Publisher-only PUT transport; credentials and signed URLs are never logged."""
import json
import http.client
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

socket_timeout = 300
diagnostic = False
phase = 'input'
sent = 0
started = time.monotonic()


def progress(stage):
    global phase
    phase = stage
    if diagnostic:
        print('Upload phase=' + stage + ' sent=' + str(sent)
              + ' elapsed_ms=' + str(round((time.monotonic() - started) * 1000)), flush=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UploadConnection(http.client.HTTPSConnection):
    def connect(self):
        # Distinguish unreachable runner networks from a slow large-file PUT.
        progress('connect_tls')
        self.timeout = 15
        super().connect()
        self.sock.settimeout(socket_timeout)
        progress('connected')

    def send(self, data):
        global sent
        if self.sock is None:
            self.connect()
        progress('sending')
        super().send(data)
        sent += len(data)
        progress('sent')

    def getresponse(self):
        progress('await_response')
        response = super().getresponse()
        progress('response_headers')
        return response


class UploadHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(UploadConnection, req, context=self._context)


def main():
    global socket_timeout, diagnostic
    descriptor = json.loads(sys.stdin.buffer.readline(65537))
    socket_timeout = descriptor.get('timeout_seconds', 300)
    if not isinstance(socket_timeout, int) or not 15 <= socket_timeout <= 300:
        raise ValueError('Invalid timeout')
    diagnostic = descriptor.get('diagnostic') is True
    url = urllib.parse.urlsplit(descriptor['url'])
    if (url.scheme != 'https' or url.hostname != 'file.gitcode.com'
            or url.port not in (None, 443) or url.username or url.password or url.fragment):
        raise ValueError('Invalid upload target')
    headers = descriptor['headers']
    if not all(key.lower().startswith('x-obs-') or key.lower() == 'content-type' for key in headers):
        raise ValueError('Invalid upload headers')
    size = descriptor['size']
    if not isinstance(size, int) or not 0 < size <= 1073741824:
        raise ValueError('Invalid upload size')
    content = sys.stdin.buffer.read(size + 1)
    if len(content) != size:
        raise ValueError('Upload size mismatch')
    request = urllib.request.Request(descriptor['url'], data=content, headers=headers, method='PUT')
    opener = urllib.request.build_opener(NoRedirect, UploadHTTPSHandler(context=ssl.create_default_context()))
    progress('request')
    with opener.open(request, timeout=socket_timeout) as response:
        if not 200 <= response.status < 300:
            raise ValueError('Upload rejected')
    print('uploaded', flush=True)


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        print('Upload HTTP ' + str(error.code), file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as error:
        print('Upload transport: ' + type(error.reason).__name__ + ' phase=' + phase + ' sent=' + str(sent), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # Never render exception messages: urllib may include the signed URL.
        print('Upload transport: ' + type(error).__name__ + ' phase=' + phase + ' sent=' + str(sent), file=sys.stderr)
        sys.exit(1)
