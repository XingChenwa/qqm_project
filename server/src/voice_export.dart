import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:qq_bot_manager/services/ip_whitelist_service.dart';

bool allowedVoiceUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    [
      'qq.com',
      'qq.com.cn',
      'qpic.cn',
      'myqcloud.com',
    ].any((host) => uri.host == host || uri.host.endsWith('.$host'));

/// Receives only URLs looked up from an authenticated, scoped saved message.
/// Pin public DNS addresses, validate every redirect, and never attach bot auth.
class VoiceExport {
  static const maxBytes = 20 * 1024 * 1024;
  int _active = 0;
  Future<Uint8List> read(String source) async {
    if (_active >= 2) throw const FormatException('语音正在处理，请稍后重试');
    _active++;
    try {
      return await _download(Uri.parse(source));
    } finally {
      _active--;
    }
  }

  Future<Uint8List> _download(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, _, _) async {
      final addresses = await InternetAddress.lookup(uri.host);
      if (addresses.isEmpty ||
          addresses.any((a) => validPublicIp(a.address) == null)) {
        throw const FormatException('语音地址不能指向本机或内网');
      }
      return Socket.startConnect(addresses.first, uri.port);
    };
    try {
      for (var hop = 0; hop < 4; hop++) {
        if (!allowedVoiceUri(uri)) {
          throw const FormatException('仅可下载 QQ 官方媒体域名中的语音');
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) throw const FormatException('语音链接重定向无效');
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw const FormatException('语音链接可能已过期，暂时无法下载');
        }
        if (response.contentLength > maxBytes) {
          throw const FormatException('语音超过 20 MB');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 10),
        )) {
          if (builder.length + chunk.length > maxBytes) {
            throw const FormatException('语音超过 20 MB');
          }
          builder.add(chunk);
        }
        return builder.takeBytes();
      }
      throw const FormatException('语音链接重定向过多');
    } finally {
      client.close(force: true);
    }
  }
}
