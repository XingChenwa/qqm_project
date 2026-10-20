import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/models/app_release.dart';
import 'package:qq_bot_manager/services/app_update_service.dart';
import 'package:qq_bot_manager/services/update_preferences.dart';
import 'package:yaml/yaml.dart';

import 'app_update_test.dart' show UpdateAdapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SimpleKeyPair keys;
  late String publicKey;
  late UpdatePreferences preferences;
  final package = utf8.encode('synthetic GitHub package; never execute');
  final server = Uri.parse('https://xingchenwa.github.io/qqm_project/');

  Map<String, dynamic> manifest({int build = 18}) => {
    'schema': 2,
    'repository': AppRelease.repository,
    'version': '1.3.7',
    'tag': 'v1.3.7',
    'build': build,
    'published_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'releases': [
      for (final target in [
        ['windows', 'x64', 'exe'],
        ['android', 'universal', 'apk'],
        ['ios', 'arm64', 'ipa'],
        ['macos', 'universal', 'dmg'],
      ])
        {
          'platform': target[0],
          'arch': target[1],
          'format': target[2],
          'package_id': 'cn.uuze.botmanager',
          'version': '1.3.7',
          'build': build,
          'size': package.length,
          'sha256': sha256.convert(package).toString(),
          'url':
              'https://github.com/${AppRelease.repository}/releases/download/v1.3.7/package.${target[2]}',
          'notes': '测试清单',
          'force_update': false,
        },
    ],
  };
  Future<Map<String, dynamic>> sign(Map<String, dynamic> data) async {
    final bytes = utf8.encode(jsonEncode(data));
    final signature = await Ed25519().sign(bytes, keyPair: keys);
    return {
      'payload': base64Encode(bytes),
      'signature': base64Encode(signature.bytes),
    };
  }

  Future<AppRelease?> verify(
    Map<String, dynamic> envelope, {
    int minimum = 0,
  }) => AppRelease.verifyGitHubEnvelope(
    envelope,
    publicKey: publicKey,
    platform: 'windows',
    arch: 'x64',
    minimumBuild: minimum,
  );
  AppUpdateService service(UpdateAdapter adapter, {Directory? directory}) {
    final result = AppUpdateService(
      preferences,
      http: Dio()..httpClientAdapter = adapter,
      server: server,
      publicKey: publicKey,
      currentBuild: 17,
      platform: 'windows',
      arch: 'x64',
      supportDirectory: () async => directory!,
    );
    addTearDown(result.dispose);
    return result;
  }

  setUp(() async {
    keys = await Ed25519().newKeyPair();
    publicKey = base64Encode((await keys.extractPublicKey()).bytes);
    SharedPreferences.setMockInitialValues({});
    preferences = UpdatePreferences(await SharedPreferences.getInstance());
    await preferences.setAutoDownload(false);
  });

  test('GitHub 静态清单验证签名和四端身份，不需要伪造动态 nonce', () async {
    final envelope = await sign(manifest());
    expect((await verify(envelope))!.format, 'exe');
    for (final target in [
      ['android', 'universal', 'apk'],
      ['ios', 'arm64', 'ipa'],
      ['macos', 'universal', 'dmg'],
    ]) {
      final result = await AppRelease.verifyGitHubEnvelope(
        envelope,
        publicKey: publicKey,
        platform: target[0],
        arch: target[1],
      );
      expect(result!.format, target[2]);
    }
    await expectLater(
      verify({...envelope, 'signature': base64Encode(List.filled(64, 0))}),
      throwsFormatException,
    );
    await expectLater(verify(envelope, minimum: 19), throwsFormatException);
  });
  test('拒绝跨仓库、错误标签、缺平台、重复平台和不匹配版本', () async {
    final changes = <void Function(Map<String, dynamic>)>[
      (data) => data['repository'] = 'someone/else',
      (data) => data['tag'] = 'v9.0.0',
      (data) => (data['releases'] as List).removeLast(),
      (data) => data['releases'][1] = data['releases'][0],
      (data) => data['releases'][0]['build'] = 19,
      (data) => data['releases'][0]['url'] =
          'https://github.com/evil/repo/releases/download/v1.3.7/setup.exe',
      (data) => data['releases'][0]['url'] += '?redirect=evil',
      (data) => data['published_at'] =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 172800,
    ];
    for (final change in changes) {
      final data = manifest();
      change(data);
      await expectLater(verify(await sign(data)), throwsFormatException);
    }
  });
  test('检查 Pages 子路径，仅 GET 公共清单且记住最高签名构建', () async {
    final envelope = await sign(manifest());
    final adapter = UpdateAdapter(
      (request) async => ResponseBody.fromString(jsonEncode(envelope), 200),
    );
    final updates = service(adapter);
    expect(updates.configured, isTrue);
    expect(updates.usesGitHubPages, isTrue);
    await updates.check();
    expect(updates.phase, UpdatePhase.available, reason: updates.error);
    expect(preferences.highestGitHubBuild, 18);
    final request = adapter.requests.singleWhere(
      (request) => request.uri.host == 'xingchenwa.github.io',
    );
    expect(
      request.uri.toString(),
      'https://xingchenwa.github.io/qqm_project/updates/stable.json',
    );
    expect(request.method, 'GET');
    expect(request.data, isNull);
    expect(request.headers.containsKey('Authorization'), isFalse);
    final stale = await sign(manifest(build: 17));
    final staleUpdates = service(
      UpdateAdapter(
        (_) async => ResponseBody.fromString(jsonEncode(stale), 200),
      ),
    );
    await staleUpdates.check();
    expect(staleUpdates.phase, UpdatePhase.failed);
  });
  for (final location in [
    'https://release-assets.githubusercontent.com/test?signature=synthetic',
    'https://objects.githubusercontent.com/test?signature=synthetic',
    'http://release-assets.githubusercontent.com/test',
    'https://evil.invalid/setup.exe',
    'https://release-assets.githubusercontent.com.evil.invalid/file',
    'https://user:pass@objects.githubusercontent.com/file',
    'https://127.0.0.1/file',
  ]) {
    test('GitHub 下载跳转校验：$location', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qqm-github-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final envelope = await sign(manifest());
      final adapter = UpdateAdapter((request) async {
        if (request.uri.path.endsWith('stable.json')) {
          return ResponseBody.fromString(jsonEncode(envelope), 200);
        }
        if (request.uri.host == 'github.com') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [location],
            },
          );
        }
        return ResponseBody.fromBytes(package, 200);
      });
      final updates = service(adapter, directory: directory);
      await updates.check();
      await updates.download();
      final allowed =
          location.startsWith(
            'https://release-assets.githubusercontent.com/',
          ) ||
          location.startsWith('https://objects.githubusercontent.com/');
      expect(
        updates.phase,
        allowed ? UpdatePhase.ready : UpdatePhase.failed,
        reason: updates.error,
      );
      expect(
        adapter.requests.where((r) => r.uri.host != 'api.gitcode.com').length,
        allowed ? 3 : 2,
      );
      if (allowed) {
        expect(
          await AppUpdateService.validFile(
            updates.downloadedFile!,
            updates.release!,
          ),
          isTrue,
        );
      }
    });
  }
  test('GitHub 下载内容被篡改时清理临时文件，不进入安装', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-github-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final envelope = await sign(manifest());
    final adapter = UpdateAdapter(
      (request) async => request.uri.path.endsWith('stable.json')
          ? ResponseBody.fromString(jsonEncode(envelope), 200)
          : ResponseBody.fromBytes(List.filled(package.length, 0), 200),
    );
    final updates = service(adapter, directory: directory);
    await updates.check();
    await updates.download();
    expect(updates.phase, UpdatePhase.failed);
    expect(updates.downloadedFile, isNull);
    expect(
      (await directory.list(recursive: true).toList()).whereType<File>(),
      isEmpty,
    );
  });
  testWidgets('旧统计偏好不会触发本机信息获取、注册或一分钟心跳', (tester) async {
    await preferences.preferences.setBool('updates_usage_consent', true);
    await preferences.preferences.setString(
      'updates_installation_id',
      'old-synthetic-id',
    );
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('cn.uuze.botmanager/updates'),
          (_) async {
            nativeCalls++;
            return {};
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('cn.uuze.botmanager/updates'),
            null,
          ),
    );
    final envelope = await sign(manifest());
    final adapter = UpdateAdapter(
      (_) async => ResponseBody.fromString(jsonEncode(envelope), 200),
    );
    final updates = service(adapter);
    await tester.runAsync(() async {
      // Ed25519 verification can exceed 50 ms on a busy macOS runner. Wait
      // for the real update operation, not a machine-speed-dependent delay.
      final completed = Completer<void>();
      void observe() {
        if (!updates.busy && !completed.isCompleted) completed.complete();
      }

      updates.addListener(observe);
      try {
        updates.start();
        await completed.future.timeout(const Duration(seconds: 10));
      } finally {
        updates.removeListener(observe);
      }
    });
    await tester.pump(const Duration(seconds: 61));
    expect(nativeCalls, 0);
    expect(adapter.requests, isNotEmpty);
    expect(
      adapter.requests.every(
        (request) =>
            request.method == 'GET' &&
            request.data == null &&
            (request.uri.path.endsWith('/updates/stable.json') ||
                request.uri ==
                    Uri.parse('${AppUpdateService.gitCodeApi}/latest') ||
                request.uri.path.endsWith('/releases')),
      ),
      isTrue,
    );
    expect(adapter.requests.length, 3);
  });

  for (final mode in [UpdateNode.auto, UpdateNode.github, UpdateNode.gitcode]) {
    test('双线路测速和持久化选择 ${mode.name}', () async {
      final envelope = await sign(manifest());
      await preferences.setNode(mode);
      final adapter = UpdateAdapter((request) async {
        if (request.uri.host == 'xingchenwa.github.io') {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        return ResponseBody.fromString(
          jsonEncode(
            request.uri.path.endsWith('/latest')
                ? {'tag_name': 'v1.3.7', 'prerelease': false}
                : envelope,
          ),
          200,
        );
      });
      final updates = service(adapter);
      await updates.check();
      expect(updates.phase, UpdatePhase.available, reason: updates.error);
      expect(
        updates.nodeStatuses.values.every((node) => node.available),
        isTrue,
      );
      expect(
        updates.activeNode,
        mode == UpdateNode.auto ? UpdateNode.gitcode : mode,
      );
      expect(UpdatePreferences(preferences.preferences).node, mode);
      expect(
        adapter.requests.every(
          (request) =>
              !request.headers.containsKey('Authorization') &&
              request.data == null,
        ),
        isTrue,
      );
      expect(preferences.highestGitHubBuild, 18);
    });
  }

  test('自动模式优先版本完整度，不为了快选择旧版国内镜像', () async {
    final newest = await sign(manifest(build: 20));
    final older = await sign(manifest(build: 19));
    final updates = service(
      UpdateAdapter((request) async {
        if (request.uri.host == 'xingchenwa.github.io') {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return ResponseBody.fromString(jsonEncode(newest), 200);
        }
        return ResponseBody.fromString(
          jsonEncode(
            request.uri.path.endsWith('/latest')
                ? {'tag_name': 'v1.3.7', 'prerelease': false}
                : older,
          ),
          200,
        );
      }),
    );
    await updates.check();
    expect(updates.activeNode, UpdateNode.github);
    expect(updates.release!.build, 20);
  });

  test('GitHub 不可达时，GitCode 的原签名清单仍可更新；跨节点拒绝回退', () async {
    var envelope = await sign(manifest(build: 20));
    final updates = service(
      UpdateAdapter((request) async {
        if (request.uri.host == 'xingchenwa.github.io') {
          return ResponseBody.fromString('', 503);
        }
        return ResponseBody.fromString(
          jsonEncode(
            request.uri.path.endsWith('/latest')
                ? {'tag_name': 'v1.3.7'}
                : envelope,
          ),
          200,
        );
      }),
    );
    await updates.check();
    expect(updates.activeNode, UpdateNode.gitcode);
    expect(updates.release!.build, 20);
    envelope = await sign(manifest(build: 19));
    await updates.check();
    expect(updates.phase, UpdatePhase.failed);
    expect(preferences.highestGitHubBuild, 20);
  });

  test('同构建签名内容冲突时拒绝选择任一节点', () async {
    final first = manifest();
    final second = manifest();
    second['releases'][0]['sha256'] = 'a' * 64;
    final github = await sign(first), gitcode = await sign(second);
    final updates = service(
      UpdateAdapter(
        (request) async => ResponseBody.fromString(
          jsonEncode(
            request.uri.host == 'xingchenwa.github.io'
                ? github
                : request.uri.path.endsWith('/latest')
                ? {'tag_name': 'v1.3.7'}
                : gitcode,
          ),
          200,
        ),
      ),
    );
    await updates.check();
    expect(updates.phase, UpdatePhase.failed);
    expect(updates.error, contains('内容不一致'));
  });

  test('自动下载失败才切到同版同 SHA 的备用线路，手动不擅自切换', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-route-download-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final envelope = await sign(manifest());
    final adapter = UpdateAdapter((request) async {
      if (request.uri.host == 'xingchenwa.github.io') {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return ResponseBody.fromString(jsonEncode(envelope), 200);
      }
      if (request.uri.path.endsWith('/latest')) {
        return ResponseBody.fromString('{"tag_name":"v1.3.7"}', 200);
      }
      if (request.uri.path.contains('update-manifest.json')) {
        return ResponseBody.fromString(jsonEncode(envelope), 200);
      }
      if (request.uri.host == 'api.gitcode.com') {
        return ResponseBody.fromString('', 503);
      }
      return ResponseBody.fromBytes(package, 200);
    });
    final updates = service(adapter, directory: directory);
    await updates.check();
    expect(updates.activeNode, UpdateNode.gitcode);
    await updates.download();
    expect(updates.phase, UpdatePhase.ready, reason: updates.error);
    expect(updates.activeNode, UpdateNode.github);
    await updates.setNode(UpdateNode.gitcode);
    await updates.download();
    expect(
      adapter.requests.where((r) => r.uri.host == 'github.com'),
      hasLength(1),
    );
  });

  test('GitCode 跳转到本地地址被拒绝，且从不携带发布令牌', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-route-reject-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await preferences.setNode(UpdateNode.gitcode);
    final envelope = await sign(manifest());
    final adapter = UpdateAdapter((request) async {
      if (request.uri.path.endsWith('/latest')) {
        return ResponseBody.fromString('{"tag_name":"v1.3.7"}', 200);
      }
      if (request.uri.path.endsWith('stable.json') ||
          request.uri.path.contains('update-manifest.json')) {
        return ResponseBody.fromString(jsonEncode(envelope), 200);
      }
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://127.0.0.1/evil.exe'],
        },
      );
    });
    final updates = service(adapter, directory: directory);
    await updates.check();
    await updates.download();
    expect(updates.phase, UpdatePhase.failed);
    expect(updates.error, contains('不受信任'));
    expect(
      adapter.requests.any(
        (r) => r.uri.host == '127.0.0.1' || r.uri.host == 'github.com',
      ),
      isFalse,
    );
    expect(
      adapter.requests.every((r) => !r.headers.containsKey('Authorization')),
      isTrue,
    );
  });

  test('Beta 与正式签名互斥；旧版没有 channel 的清单只属于正式', () async {
    final beta = manifest(build: 20)..['channel'] = 'beta';
    final envelope = await sign(beta);
    await expectLater(verify(envelope), throwsFormatException);
    expect(
      (await AppRelease.verifyGitHubEnvelope(
        envelope,
        publicKey: publicKey,
        platform: 'windows',
        arch: 'x64',
        channel: UpdateChannel.beta,
      ))!.build,
      20,
    );
    await expectLater(
      AppRelease.verifyGitHubEnvelope(
        await sign(manifest()),
        publicKey: publicKey,
        platform: 'windows',
        arch: 'x64',
        channel: UpdateChannel.beta,
      ),
      throwsFormatException,
    );
  });

  test('安装包决定渠道，忽略上版保存的切换偏好；版本记录相互独立', () async {
    await preferences.preferences.setString('updates_channel', 'beta');
    expect(preferences.channel, UpdateChannel.stable);
    await preferences.rememberGitHubBuild(19);
    final beta = UpdatePreferences(
      preferences.preferences,
      channel: UpdateChannel.beta,
    );
    expect(beta.channel, UpdateChannel.beta);
    expect(beta.highestGitHubBuild, 0);
    await beta.rememberGitHubBuild(25);
    await preferences.preferences.setString('updates_channel', 'stable');
    expect(beta.channel, UpdateChannel.beta);
    expect(beta.highestGitHubBuild, 25);
    expect(preferences.highestGitHubBuild, 19);
  });
  for (final channel in UpdateChannel.values) {
    test('安装的 ${channel.name} 只读取对应清单并拒绝另一渠道', () async {
      final beta = await sign(manifest(build: 25)..['channel'] = 'beta');
      final stable = await sign(manifest(build: 19));
      preferences = UpdatePreferences(
        preferences.preferences,
        channel: channel,
      );
      var wrongChannel = false;
      final adapter = UpdateAdapter((request) async {
        if (request.uri.host == 'api.gitcode.com') {
          return ResponseBody.fromString('', 503);
        }
        final expected = channel == UpdateChannel.beta ? beta : stable;
        final wrong = channel == UpdateChannel.beta ? stable : beta;
        return ResponseBody.fromString(
          jsonEncode(wrongChannel ? wrong : expected),
          200,
        );
      });
      final updates = service(adapter);
      await updates.check();
      expect(updates.release!.build, channel == UpdateChannel.beta ? 25 : 19);
      expect(
        adapter.requests.any(
          (r) => r.uri.path.endsWith('/updates/${channel.name}.json'),
        ),
        isTrue,
      );
      wrongChannel = true;
      await updates.check();
      expect(updates.phase, UpdatePhase.failed);
    });
  }
  test('GitCode latest 指向 Beta 时，正式渠道从列表选择完整正式清单', () async {
    final envelope = await sign(manifest());
    final adapter = UpdateAdapter((request) async {
      if (request.uri.host == 'xingchenwa.github.io') {
        return ResponseBody.fromString('', 503);
      }
      if (request.uri.path.endsWith('/latest')) {
        return ResponseBody.fromString(
          '{"tag_name":"v1.3.8-beta.1","prerelease":true}',
          200,
        );
      }
      if (request.uri.path.endsWith('/releases')) {
        return ResponseBody.fromString(
          '[{"tag_name":"v1.3.8-beta.1","prerelease":true},{"tag_name":"v1.3.7","prerelease":false}]',
          200,
        );
      }
      return ResponseBody.fromString(jsonEncode(envelope), 200);
    });
    final updates = service(adapter);
    await updates.check();
    expect(updates.activeNode, UpdateNode.gitcode);
    expect(updates.release!.build, 18);
    expect(
      adapter.requests.any(
        (r) => r.uri.path.contains('v1.3.8-beta.1/attach_files'),
      ),
      isFalse,
    );
  });
  test('GitHub Actions YAML 可解析，发布任务受四端依赖与 Pages 权限保护', () {
    final yaml = loadYaml(
      File('.github/workflows/mobile-build.yml').readAsStringSync(),
    );
    expect(yaml['on']['release']['types'], ['published']);
    expect(yaml['jobs']['publish']['needs'], [
      'preflight',
      'android',
      'ios',
      'macos',
      'windows',
      'linux',
    ]);
    expect(yaml['jobs']['publish']['permissions']['contents'], 'write');
    expect(yaml['jobs']['publish']['permissions']['pages'], 'write');
    expect(yaml['jobs']['publish']['permissions']['id-token'], isNull);
    final websiteWorkflow = loadYaml(
      File('.github/workflows/github-pages.yml').readAsStringSync(),
    );
    expect(websiteWorkflow['permissions']['pages'], 'write');
    expect(websiteWorkflow['permissions']['contents'], 'write');
    expect(websiteWorkflow['jobs']['sync']['steps'][1]['with']['ref'], 'docs');
  });
}
