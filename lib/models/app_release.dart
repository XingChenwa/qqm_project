import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class AppRelease {
  final String platform, arch, version, format, sha256, notes;
  final int build, size;
  final Uri url;
  final bool forceUpdate;

  const AppRelease({
    required this.platform,
    required this.arch,
    required this.version,
    required this.format,
    required this.sha256,
    required this.build,
    required this.size,
    required this.url,
    this.notes = '',
    this.forceUpdate = false,
  });

  static Future<AppRelease?> verifyEnvelope(
    Map<String, dynamic> envelope, {
    required String publicKey,
    required String nonce,
    required String platform,
    required String arch,
    required Uri server,
    DateTime? now,
  }) async {
    final payload = envelope['payload'];
    final signature = envelope['signature'];
    if (payload is! String || signature is! String || payload.length > 65536) {
      throw const FormatException('更新清单格式无效');
    }
    final key = base64Decode(publicKey);
    final bytes = base64Decode(payload);
    final sig = base64Decode(signature);
    if (key.length != 32 ||
        sig.length != 64 ||
        !await Ed25519().verify(
          bytes,
          signature: Signature(
            sig,
            publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
          ),
        )) {
      throw const FormatException('更新签名校验失败，已阻止下载和安装');
    }
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final expires = data['expires_at'];
    final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (data['schema'] != 1 ||
        data['nonce'] != nonce ||
        data['platform'] != platform ||
        data['arch'] != arch ||
        expires is! int ||
        expires < seconds ||
        expires > seconds + 1800) {
      throw const FormatException('更新清单过期或不匹配，请检查系统时间后重试');
    }
    if (data['release'] == null) return null;
    final release = data['release'] as Map<String, dynamic>;
    final url = Uri.tryParse(release['url']?.toString() ?? '');
    final build = release['build'];
    final size = release['size'];
    final hash = release['sha256'];
    final format = release['format'];
    final allowed = switch (platform) {
      'windows' => {'zip', 'exe'},
      'android' => {'apk'},
      'ios' => {'ipa'},
      'macos' => {'dmg'},
      _ => <String>{},
    };
    if (release['platform'] != platform ||
        release['arch'] != arch ||
        release['package_id'] != 'cn.uuze.botmanager' ||
        build is! int ||
        build < 1 ||
        size is! int ||
        size < 1 ||
        size > 1073741824 ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !allowed.contains(format) ||
        url == null ||
        url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.origin != server.origin ||
        !url.path.startsWith('/packages/') ||
        release['version'] is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[\w.-]+)?$').hasMatch(release['version'])) {
      throw const FormatException('更新包参数不可信，已阻止安装');
    }
    return AppRelease(
      platform: platform,
      arch: arch,
      version: release['version'],
      format: format,
      sha256: hash,
      build: build,
      size: size,
      url: url,
      notes: release['notes'] is String ? release['notes'] : '',
      forceUpdate: release['force_update'] == true,
    );
  }
}
