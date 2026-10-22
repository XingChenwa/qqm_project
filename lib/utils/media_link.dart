import 'dart:convert';

Uri? mediaHttpUri(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

bool isVideoLink(String value, {String mime = '', String filename = ''}) {
  final uri = mediaHttpUri(value);
  if (uri == null) return false;
  if (mime.toLowerCase().startsWith('video/')) return true;
  if (RegExp(
    r'\.(mp4|m4v|mov|webm|mkv|avi|ts)(?:$|\?)',
    caseSensitive: false,
  ).hasMatch(filename.isEmpty ? uri.path : filename)) {
    return true;
  }
  return uri.host == 'multimedia.nt.qq.com.cn' &&
      {
        't264',
        'h264',
        't265',
        'h265',
        'hevc',
        'mp4',
      }.contains(uri.queryParameters['orgfmt']);
}

String safeDownloadName(
  String? suggested,
  Uri uri, {
  String mime = '',
  String disposition = '',
}) {
  var name = suggested ?? '';
  final encoded = RegExp(
    r"filename\*\s*=\s*(?:UTF-8'')([^;]+)",
    caseSensitive: false,
  ).firstMatch(disposition)?.group(1);
  if (encoded != null) {
    try {
      name = Uri.decodeComponent(encoded.trim().replaceAll('"', ''));
    } catch (_) {}
  } else {
    final quoted = RegExp(
      r'''filename\s*=\s*(?:"([^"\r\n]*)"|([^;\r\n]+))''',
      caseSensitive: false,
    ).firstMatch(disposition);
    if (quoted != null) {
      name = (quoted.group(1) ?? quoted.group(2) ?? '').trim();
    }
  }
  if (name.isEmpty) {
    name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  }
  name = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'^\.+|[. ]+$'), '')
      .trim();
  if (name.isEmpty || name == 'download') name = 'QQ文件';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  name = name.substring(0, name.length.clamp(0, 160));
  if (!RegExp(r'\.[a-zA-Z0-9]{1,8}$').hasMatch(name)) {
    name += switch (mime.toLowerCase().split(';').first.trim()) {
      'video/mp4' => '.mp4',
      'video/webm' => '.webm',
      'video/quicktime' => '.mov',
      'image/png' => '.png',
      'image/jpeg' => '.jpg',
      'image/gif' => '.gif',
      'application/pdf' => '.pdf',
      'audio/wav' => '.wav',
      _ => '.bin',
    };
  }
  return name;
}

/// A local, script-free external page cannot embed arbitrary HTML from a chat.
/// Only the escaped HTTP(S) media URL is placed into the native HTML5 player.
String videoPlayerHtml(Uri uri) {
  if (mediaHttpUri(uri.toString()) == null) {
    throw const FormatException('视频链接无效');
  }
  final source = const HtmlEscape(
    HtmlEscapeMode.attribute,
  ).convert(uri.toString());
  return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src https: http:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>html,body{margin:0;width:100%;height:100%;background:#101827;color:white}
video{display:block;width:100%;height:100%;object-fit:contain}</style></head>
<body><video controls playsinline webkit-playsinline preload="metadata" src="$source">
当前系统不支持此视频，请下载原文件播放。</video><script>
function reportVideoError(){
 if(window.flutter_inappwebview)window.flutter_inappwebview.callHandler('qqmVideoError');
}
document.querySelector('video').addEventListener('error',reportVideoError);
window.addEventListener('flutterInAppWebViewPlatformReady',function(){
 if(document.querySelector('video').error)reportVideoError();
});</script></body></html>''';
}
