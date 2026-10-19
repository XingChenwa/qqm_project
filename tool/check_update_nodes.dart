// Read-only public-node verification, using the real client signature verifier.
// Does not initialize Flutter, QQ, local chat storage, or download installers.
import 'dart:convert';
import 'dart:io';
import 'package:qq_bot_manager/models/app_release.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || base64Decode(args.first).length != 32) {
    stderr.writeln('用法：dart run tool/check_update_nodes.dart 公开公钥（不是私钥）');
    exitCode = 64;
    return;
  }
  const mirror =
      'https://api.gitcode.com/api/v5/repos/xiaoshutiaoya/QQm_project/releases';
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  Future<Map<String, dynamic>> json(Uri url) async {
    for (var hop = 0; hop < 6; hop++) {
      if (url.scheme != 'https' ||
          url.port != 443 ||
          url.userInfo.isNotEmpty ||
          url.hasFragment ||
          !{
            'xingchenwa.github.io',
            'api.gitcode.com',
            'file-cdn.gitcode.com',
          }.contains(url.host)) {
        throw const FormatException('清单跳转不可信');
      }
      final request = await http.getUrl(url);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.listen((_) {}).cancel();
        if (location == null) throw const FormatException('缺少跳转地址');
        url = url.resolve(location);
        continue;
      }
      if (response.statusCode != 200)
        throw HttpException('HTTP ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) throw const FormatException('清单超过大小限制');
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    throw const FormatException('跳转次数过多');
  }

  try {
    await Future.wait(
      ['GitHub', 'GitCode'].map((node) async {
        final clock = Stopwatch()..start();
        try {
          Map<String, dynamic> envelope;
          String? tag;
          if (node == 'GitHub') {
            envelope = await json(
              Uri.parse(
                'https://xingchenwa.github.io/qqm_project/updates/stable.json',
              ),
            );
          } else {
            final latest = await json(Uri.parse('$mirror/latest'));
            tag = latest['tag_name'] as String?;
            if (tag == null ||
                !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
                latest['prerelease'] == true) {
              throw const FormatException('尚无正式版本');
            }
            envelope = await json(
              Uri.parse(
                '$mirror/$tag/attach_files/update-manifest.json/download',
              ),
            );
          }
          final release = await AppRelease.verifyGitHubEnvelope(
            envelope,
            publicKey: args.single,
            platform: 'windows',
            arch: 'x64',
          );
          if (release == null || tag != null && tag != 'v${release.version}')
            throw const FormatException('版本不匹配');
          stdout.writeln(
            '$node：签名有效 ${release.version}+${release.build}，${clock.elapsedMilliseconds} ms；未下载或执行安装包。',
          );
        } catch (error) {
          stderr.writeln('$node：校验未通过（$error）');
          exitCode = 1;
        }
      }),
    );
  } finally {
    http.close(force: true);
  }
}
