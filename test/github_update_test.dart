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
    final request = adapter.requests.single;
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
      expect(adapter.requests.length, allowed ? 3 : 2);
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
      updates.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(seconds: 61));
    expect(nativeCalls, 0);
    expect(adapter.requests, isNotEmpty);
    expect(
      adapter.requests.every(
        (request) =>
            request.method == 'GET' &&
            request.data == null &&
            request.uri.path.endsWith('/updates/stable.json'),
      ),
      isTrue,
    );
    expect(adapter.requests.length, 1);
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
