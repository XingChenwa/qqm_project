import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/services/app_update_service.dart';
import 'package:qq_bot_manager/services/update_preferences.dart';
import 'app_update_test.dart' show UpdateAdapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('自动线路选择依据安装包真实吞吐，不被清单低延迟误导，完整下载仍验证摘要', () async {
    final root = await Directory.systemTemp.createTemp('qqm-bandwidth-');
    addTearDown(() => root.delete(recursive: true));
    final package = Uint8List.fromList(
      List.generate(1536 * 1024, (i) => i % 251),
    );
    final key = await Ed25519().newKeyPair();
    final data = {
      'schema': 2,
      'repository': 'XingChenwa/qqm_project',
      'version': '1.4.0',
      'tag': 'v1.4.0',
      'build': 40,
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
            'version': '1.4.0',
            'build': 40,
            'size': package.length,
            'sha256': sha256.convert(package).toString(),
            'url':
                'https://github.com/XingChenwa/qqm_project/releases/download/v1.4.0/test.${target[2]}',
            'notes': '',
            'force_update': false,
          },
      ],
    };
    final bytes = utf8.encode(jsonEncode(data));
    final envelope = {
      'payload': base64Encode(bytes),
      'signature': base64Encode(
        (await Ed25519().sign(bytes, keyPair: key)).bytes,
      ),
    };
    var slowGithub = false;
    final adapter = UpdateAdapter((request) async {
      final domestic = request.uri.host == 'api.gitcode.com';
      if (request.uri.path.endsWith('.json') ||
          request.uri.path.endsWith('/latest') ||
          request.uri.path.endsWith('json/download')) {
        if (domestic) {
          await Future<void>.delayed(const Duration(milliseconds: 35));
        }
        return ResponseBody.fromString(
          jsonEncode(
            request.uri.path.endsWith('/latest')
                ? {'tag_name': 'v1.4.0', 'prerelease': false}
                : envelope,
          ),
          200,
        );
      }
      final range = request.headers.entries
          .where((e) => e.key.toLowerCase() == 'range')
          .firstOrNull
          ?.value
          ?.toString();
      if (range == null) {
        if (slowGithub && !domestic) {
          Stream<Uint8List> slow() async* {
            for (var i = 0; i < package.length; i += 4096) {
              await Future<void>.delayed(const Duration(seconds: 1));
              yield Uint8List.sublistView(package, i, i + 4096);
            }
          }

          return ResponseBody(slow(), 200);
        }
        return ResponseBody.fromBytes(package, 200);
      }
      expect(range, 'bytes=0-1048575');
      Stream<Uint8List> chunks() async* {
        for (var i = 0; i < 1024 * 1024; i += 16384) {
          await Future<void>.delayed(
            Duration(
              milliseconds: (slowGithub ? !domestic : domestic) ? 1 : 10,
            ),
          );
          yield Uint8List.sublistView(package, i, i + 16384);
        }
      }

      return ResponseBody(
        chunks(),
        206,
        headers: {
          'content-range': ['bytes 0-1048575/${package.length}'],
        },
      );
    });
    SharedPreferences.setMockInitialValues({});
    final preferences = UpdatePreferences(
      await SharedPreferences.getInstance(),
    );
    await preferences.setAutoDownload(false);
    final service = AppUpdateService(
      preferences,
      http: Dio()..httpClientAdapter = adapter,
      publicKey: base64Encode((await key.extractPublicKey()).bytes),
      platform: 'android',
      arch: 'universal',
      currentBuild: 31,
      supportDirectory: () async => root,
    );
    addTearDown(service.dispose);
    await service.check();
    expect(service.phase, UpdatePhase.available, reason: service.error);
    expect(
      service.nodeStatuses[UpdateNode.github]!.milliseconds!,
      lessThan(service.nodeStatuses[UpdateNode.gitcode]!.milliseconds!),
    );
    expect(
      service.nodeStatuses[UpdateNode.gitcode]!.bytesPerSecond!,
      greaterThan(service.nodeStatuses[UpdateNode.github]!.bytesPerSecond!),
    );
    expect(service.activeNode, UpdateNode.gitcode);
    expect(await root.list().isEmpty, isTrue, reason: '测速不保存或执行安装包');
    await service.download();
    expect(service.phase, UpdatePhase.ready, reason: service.error);
    expect(await service.downloadedFile!.readAsBytes(), package);
    expect(service.downloadBytesPerSecond, greaterThan(0));

    // A CDN can become slow AFTER a good sample. Auto mode then moves to the
    // other verified copy; partial bytes must never be treated as an installer.
    slowGithub = true;
    final secondRoot = await Directory('${root.path}/slow-fallback').create();
    final fallback = AppUpdateService(
      preferences,
      http: Dio()..httpClientAdapter = adapter,
      publicKey: base64Encode((await key.extractPublicKey()).bytes),
      platform: 'android',
      arch: 'universal',
      currentBuild: 31,
      supportDirectory: () async => secondRoot,
    );
    addTearDown(fallback.dispose);
    await fallback.check();
    expect(fallback.activeNode, UpdateNode.github);
    await fallback.download();
    expect(fallback.phase, UpdatePhase.ready, reason: fallback.error);
    expect(fallback.activeNode, UpdateNode.gitcode);
    expect(fallback.transferNotice, contains('持续下载较慢'));
    expect(await fallback.downloadedFile!.readAsBytes(), package);
  });
}
