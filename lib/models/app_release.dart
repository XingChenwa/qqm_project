import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import '../services/update_channel.dart';

class AppRelease {
  static const repository = 'XingChenwa/qqm_project';
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
    final data = await _verifiedPayload(envelope, publicKey);
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
    return _parseRelease(
      data['release'],
      platform,
      arch,
      (url) => url.origin == server.origin && url.path.startsWith('/packages/'),
    );
  }

  /// Static Pages cannot sign a fresh nonce. The pinned key authenticates the
  /// publisher; highest observed build prevents downgrade, not stale hosting.
  static Future<AppRelease?> verifyGitHubEnvelope(
    Map<String, dynamic> envelope, {
    required String publicKey,
    required String platform,
    required String arch,
    int minimumBuild = 0,
    UpdateChannel channel = UpdateChannel.stable,
    DateTime? now,
  }) async {
    final data = await _verifiedPayload(envelope, publicKey);
    final tag = data['tag'];
    final build = data['build'];
    final version = data['version'];
    final published = data['published_at'];
    final entries = data['releases'];
    final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (data['schema'] != 2 ||
        data['repository'] != repository ||
        (data['channel'] ?? 'stable') != channel.name ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$').hasMatch(version) ||
        (data['channel'] == null && version.contains('-')) ||
        tag != 'v$version' ||
        build is! int ||
        build < 1 ||
        build > 2147483647 ||
        build < minimumBuild ||
        published is! int ||
        published < 1735689600 ||
        published > seconds + 86400 ||
        entries is! List ||
        entries.length != 4) {
      throw const FormatException('GitHub 更新清单不匹配或版本回退，已阻止安装');
    }
    final targets = <String>{};
    AppRelease? selected;
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> ||
          entry['build'] != build ||
          entry['version'] != version ||
          entry['platform'] is! String ||
          entry['arch'] is! String) {
        throw const FormatException('GitHub 安装包版本不一致');
      }
      final target = '${entry['platform']}/${entry['arch']}';
      if (const {
                'windows/x64': 'exe',
                'android/universal': 'apk',
                'ios/arm64': 'ipa',
                'macos/universal': 'dmg',
              }[target] !=
              entry['format'] ||
          !targets.add(target)) {
        throw const FormatException('GitHub 安装包平台重复或无效');
      }
      final release = _parseRelease(
        entry,
        entry['platform'],
        entry['arch'],
        (url) =>
            isGitHubAsset(url, tag: tag) &&
            url.path.endsWith('.${entry['format']}'),
      );
      if (target == '$platform/$arch') selected = release;
    }
    return selected;
  }

  static bool isGitHubAsset(Uri url, {required String tag}) =>
      url.scheme == 'https' &&
      url.host == 'github.com' &&
      url.port == 443 &&
      url.userInfo.isEmpty &&
      !url.hasQuery &&
      !url.hasFragment &&
      url.pathSegments.length == 6 &&
      url.pathSegments.take(5).join('/') ==
          '$repository/releases/download/$tag' &&
      RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$',
      ).hasMatch(url.pathSegments.last);

  static Future<Map<String, dynamic>> _verifiedPayload(
    Map<String, dynamic> envelope,
    String publicKey,
  ) async {
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
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) throw const FormatException('更新清单格式无效');
    return data;
  }

  static AppRelease _parseRelease(
    dynamic value,
    String platform,
    String arch,
    bool Function(Uri) trustedUrl,
  ) {
    if (value is! Map<String, dynamic>) throw const FormatException('更新包格式无效');
    final release = value;
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
        !trustedUrl(url) ||
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
