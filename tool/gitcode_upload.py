"""Publisher-only PUT transport; credentials and signed URLs are never logged."""
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    descriptor = json.loads(sys.stdin.buffer.readline(65537))
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
    opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    with opener.open(request, timeout=300) as response:
        if not 200 <= response.status < 300:
            raise ValueError('Upload rejected')
    print('uploaded')


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        print('Upload HTTP ' + str(error.code), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # Never render exception messages: urllib may include the signed URL.
        print('Upload transport: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
