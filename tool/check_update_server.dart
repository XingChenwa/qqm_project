// Read-only release signature check. Does not initialize the app, QQ, storage or telemetry.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:qq_bot_manager/models/app_release.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('用法：dart run tool/check_update_server.dart HTTPS更新地址 公开公钥');
    exitCode = 64;
    return;
  }
  final server = Uri.parse(args[0]);
  final githubPages =
      server.scheme == 'https' &&
      server.host == 'xingchenwa.github.io' &&
      server.port == 443 &&
      {'/qqm-releases', '/qqm-releases/'}.contains(server.path);
  if (server.scheme != 'https' ||
      server.host.isEmpty ||
      server.userInfo.isNotEmpty ||
      (!githubPages && server.path.replaceAll('/', '').isNotEmpty) ||
      server.hasQuery ||
      server.hasFragment ||
      base64Decode(args[1]).length != 32) {
    stderr.writeln('需要项目 Pages 地址或旧 HTTPS 源站，以及 32 字节公开公钥；不要提供私钥。');
    exitCode = 64;
    return;
  }
  final random = Random.secure();
  final nonce = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(
      githubPages
          ? server.resolve('/qqm-releases/updates/stable.json')
          : server
                .resolve('/api/v1/update')
                .replace(
                  queryParameters: {
                    'platform': 'windows',
                    'arch': 'x64',
                    'nonce': nonce,
                  },
                ),
    );
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException(
        'Update endpoint returned HTTP ${response.statusCode}',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > 100000) {
        throw const FormatException('Update response is too large');
      }
    }
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final release = githubPages
        ? await AppRelease.verifyGitHubEnvelope(
            envelope,
            publicKey: args[1],
            platform: 'windows',
            arch: 'x64',
          )
        : await AppRelease.verifyEnvelope(
            envelope,
            publicKey: args[1],
            nonce: nonce,
            platform: 'windows',
            arch: 'x64',
            server: server,
          );
    stdout.writeln(
      release == null
          ? '签名有效：公钥匹配，尚无已发布的 Windows 安装包。'
          : '签名有效：${release.version}+${release.build}，${release.format}。没有下载或执行安装包。',
    );
  } catch (error) {
    stderr.writeln('更新签名检查失败：$error');
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}
