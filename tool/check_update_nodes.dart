// Read-only public-node verification, using the real client signature verifier.
// Does not initialize Flutter, QQ, local chat storage, or download installers.
import 'dart:convert';
import 'dart:io';
import 'package:qq_bot_manager/models/app_release.dart';
import 'package:qq_bot_manager/services/update_channel.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      args.length > 2 ||
      base64Decode(args.first).length != 32 ||
      (args.length == 2 && !{'stable', 'beta'}.contains(args.last))) {
    stderr.writeln(
      '用法：dart run tool/check_update_nodes.dart 公开公钥（不是私钥） [stable|beta]',
    );
    exitCode = 64;
    return;
  }
  final channel = args.length == 2 && args.last == 'beta'
      ? UpdateChannel.beta
      : UpdateChannel.stable;
  const mirror =
      'https://api.gitcode.com/api/v5/repos/xiaoshutiaoya/QQm_project/releases';
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  Future<dynamic> json(Uri url, {int maximum = 65536}) async {
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
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > maximum) throw const FormatException('清单超过大小限制');
      }
      return jsonDecode(utf8.decode(bytes));
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
                'https://xingchenwa.github.io/qqm_project/updates/${channel.name}.json',
              ),
            );
          } else {
            final list = await json(
              Uri.parse('$mirror?per_page=10&direction=desc'),
              maximum: 262144,
            );
            if (list is! List) throw const FormatException('国内节点版本列表无效');
            Map<String, dynamic>? selected;
            var highest = 0;
            for (final entry in list.whereType<Map<String, dynamic>>()) {
              final candidateTag = entry['tag_name'];
              if (candidateTag is! String ||
                  !RegExp(
                    r'^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$',
                  ).hasMatch(candidateTag) ||
                  (entry['prerelease'] == true ||
                          entry['release_status'] == 'pre') !=
                      (channel == UpdateChannel.beta)) {
                continue;
              }
              try {
                final signed = await json(
                  Uri.parse(
                    '$mirror/$candidateTag/attach_files/update-manifest.json/download',
                  ),
                );
                final release = await AppRelease.verifyGitHubEnvelope(
                  signed,
                  publicKey: args.first,
                  platform: 'windows',
                  arch: 'x64',
                  channel: channel,
                );
                if (release != null &&
                    candidateTag == 'v${release.version}' &&
                    release.build > highest) {
                  highest = release.build;
                  selected = signed;
                  tag = candidateTag;
                }
              } catch (_) {
                // Ignore incomplete or wrong-channel mirrors; never execute a package.
              }
            }
            if (selected == null) throw const FormatException('尚无此渠道的完整签名版本');
            envelope = selected;
          }
          final release = await AppRelease.verifyGitHubEnvelope(
            envelope,
            publicKey: args.first,
            channel: channel,
            platform: 'windows',
            arch: 'x64',
          );
          if (release == null || tag != null && tag != 'v${release.version}') {
            throw const FormatException('版本不匹配');
          }
          stdout.writeln(
            '$node / ${channel.label}：签名有效 ${release.version}+${release.build}，${clock.elapsedMilliseconds} ms；未下载或执行安装包。',
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
