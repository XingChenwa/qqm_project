import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/models/app_release.dart';
import 'package:qq_bot_manager/services/app_update_service.dart';
import 'package:qq_bot_manager/services/update_preferences.dart';
import 'package:qq_bot_manager/ui/widgets/update_panel.dart';
import 'package:qq_bot_manager/utils/constants.dart';
import 'package:yaml/yaml.dart';

class UpdateAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  UpdateAdapter(this.handler);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class InterruptedDownloadDio extends DioForNative {
  final File Function(String) realFile;
  InterruptedDownloadDio(this.realFile);

  @override
  Future<Response> downloadUri(
    Uri uri,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) async {
    await realFile(savePath as String).writeAsString('incomplete download');
    throw DioException(
      requestOptions: RequestOptions(path: uri.toString()),
      type: DioExceptionType.cancel,
    );
  }
}

class RemovedPartialFile extends Fake implements File {
  final File realFile;
  final VoidCallback onRemoved;
  RemovedPartialFile(this.realFile, this.onRemoved);

  @override
  String get path => realFile.path;

  @override
  Future<bool> exists() async {
    final existed = await realFile.exists();
    if (existed) {
      await realFile.delete();
      onRemoved();
    }
    return existed;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      realFile.delete(recursive: recursive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final algorithm = Ed25519();
  late SimpleKeyPair keys;
  late String publicKey;
  final server = Uri.parse('https://botmanager.uuze.cn');
  const nonce = '12345678-1234-4567-8901-123456789012';
  final package = utf8.encode('synthetic update package; never executed');
  late UpdatePreferences preferences;

  Map<String, dynamic> release({String platform = 'windows', String? arch}) => {
    'platform': platform,
    'arch':
        arch ??
        (platform == 'windows'
            ? 'x64'
            : platform == 'ios'
            ? 'arm64'
            : 'universal'),
    'package_id': 'cn.uuze.botmanager',
    'version': '1.3.2',
    'build': 13,
    'format': platform == 'windows'
        ? 'zip'
        : platform == 'ios'
        ? 'ipa'
        : 'apk',
    'size': package.length,
    'sha256': sha256.convert(package).toString(),
    'url':
        'https://botmanager.uuze.cn/packages/${sha256.convert(package)}/package.zip',
    'notes': '模拟更新',
  };
  Future<Map<String, dynamic>> envelope(
    Map<String, dynamic>? selected, {
    String requestNonce = nonce,
    Map<String, dynamic> overrides = const {},
  }) async {
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'nonce': requestNonce,
        'platform': selected?['platform'] ?? 'windows',
        'arch': selected?['arch'] ?? 'x64',
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
        'release': selected,
        ...overrides,
      }),
    );
    final signature = await algorithm.sign(payload, keyPair: keys);
    return {
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    };
  }

  Future<AppRelease?> verify(
    Map<String, dynamic> data, {
    String expectedNonce = nonce,
  }) => AppRelease.verifyEnvelope(
    data,
    publicKey: publicKey,
    nonce: expectedNonce,
    platform: 'windows',
    arch: 'x64',
    server: server,
  );
  ResponseBody jsonResponse(Object data, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(data),
        status,
        headers: {
          'content-type': ['application/json'],
        },
      );
  AppUpdateService service(
    UpdateAdapter adapter, {
    Dio? http,
    Directory? directory,
    String platform = 'windows',
    String? key,
  }) {
    final updates = AppUpdateService(
      preferences,
      http: http ?? (Dio()..httpClientAdapter = adapter),
      publicKey: key ?? publicKey,
      currentBuild: 12,
      currentVersion: '1.3.1',
      server: server,
      platform: platform,
      arch: platform == 'windows'
          ? 'x64'
          : platform == 'ios'
          ? 'arm64'
          : 'universal',
      supportDirectory: directory == null ? null : () async => directory,
    );
    addTearDown(updates.dispose);
    return updates;
  }

  setUpAll(() async {
    // Fixed test seed is not a release key. Production keys are generated by PHP CLI.
    keys = await algorithm.newKeyPairFromSeed(List.filled(32, 42));
    publicKey = base64Encode((await keys.extractPublicKey()).bytes);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = UpdatePreferences(await SharedPreferences.getInstance());
    await preferences.setAutoDownload(false);
  });

  test('默认更新地址使用 GitHub Pages，旧 PHP 地址仅保留兼容', () {
    expect(
      AppUpdateService.defaultServer,
      'https://xingchenwa.github.io/qqm_project',
    );
  });

  test('当前版本与 pubspec 的版本号、构建号一致', () {
    final yaml = loadYaml(File('pubspec.yaml').readAsStringSync());
    expect(
      yaml['version'],
      '${AppConstants.appVersion}+${AppConstants.appBuild}',
    );
  });
  test('Ed25519 清单验证平台、来源、随机数与包参数', () async {
    final data = await envelope(release());
    expect((await verify(data))!.build, 13);
    expect(await verify(await envelope(null)), isNull);
    final tampered = Map<String, dynamic>.from(data)
      ..['payload'] = base64Encode(utf8.encode('{}'));
    await expectLater(verify(tampered), throwsFormatException);
    await expectLater(
      verify(data, expectedNonce: 'different'),
      throwsFormatException,
    );
    for (final change in [
      {'url': 'http://botmanager.uuze.cn/packages/file.zip'},
      {'url': 'https://evil.invalid/packages/file.zip'},
      {'url': 'https://user:pass@botmanager.uuze.cn/packages/file.zip'},
      {'url': 'https://botmanager.uuze.cn/private/file.zip'},
      {'package_id': 'other.package'},
      {'sha256': 'invalid'},
      {'size': -1},
      {'size': 1073741825},
      {'build': '12'},
      {'format': 'apk'},
    ]) {
      await expectLater(
        verify(await envelope({...release(), ...change})),
        throwsFormatException,
      );
    }
    for (final change in [
      {'expires_at': 1},
      {'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400},
      {'platform': 'ios'},
      {'arch': 'arm64'},
    ]) {
      await expectLater(
        verify(await envelope(release(), overrides: change)),
        throwsFormatException,
      );
    }
  });
  test('Windows 安装版 EXE 与 ZIP 共用签名清单验证和下载校验', () async {
    final selected = release()
      ..['format'] = 'exe'
      ..['url'] =
          'https://botmanager.uuze.cn/packages/${sha256.convert(package)}/setup.exe';
    final verified = await verify(await envelope(selected));
    expect(verified!.format, 'exe');
    final directory = await Directory.systemTemp.createTemp(
      'qqm-exe-download-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final adapter = UpdateAdapter((options) async {
      if (options.uri.path == '/api/v1/update') {
        return jsonResponse(
          await envelope(
            selected,
            requestNonce: options.uri.queryParameters['nonce']!,
          ),
        );
      }
      return ResponseBody.fromBytes(
        package,
        200,
        headers: {
          'content-length': ['${package.length}'],
        },
      );
    });
    final updates = service(adapter, directory: directory);
    await updates.check();
    expect(updates.phase, UpdatePhase.available, reason: updates.error);
    await updates.download();
    expect(updates.phase, UpdatePhase.ready);
    expect(
      updates.downloadedFile!.path,
      endsWith(updates.release!.installerFileName),
    );
    expect(
      await AppUpdateService.validFile(
        updates.downloadedFile!,
        updates.release!,
      ),
      isTrue,
    );
  });

  test('未内置公钥不会联系服务器或执行自动更新', () async {
    final adapter = UpdateAdapter(
      (_) async => throw StateError('must not request'),
    );
    final updates = service(adapter, key: '');
    updates.start();
    await updates.check();
    expect(updates.configured, isFalse);
    expect(adapter.requests, isEmpty);
  });
  test('macOS 仅接受同源签名 DMG，拒绝跨平台格式', () async {
    final selected = release(platform: 'macos')..['format'] = 'dmg';
    Future<AppRelease?> verifyMac(Map<String, dynamic> data) =>
        AppRelease.verifyEnvelope(
          data,
          publicKey: publicKey,
          nonce: nonce,
          platform: 'macos',
          arch: 'universal',
          server: server,
        );
    expect((await verifyMac(await envelope(selected)))!.format, 'dmg');
    for (final format in ['exe', 'ipa', 'zip']) {
      await expectLater(
        verifyMac(await envelope({...selected, 'format': format})),
        throwsFormatException,
      );
    }
  });
  test('更新检查独立于 QQ 鉴权，旧构建号不能降级', () async {
    final adapter = UpdateAdapter(
      (options) async => jsonResponse(
        await envelope({
          ...release(),
          'build': 10,
        }, requestNonce: options.uri.queryParameters['nonce']!),
      ),
    );
    final updates = service(adapter);
    await updates.check();
    expect(updates.hasUpdate, isFalse);
    expect(updates.phase, UpdatePhase.idle);
    expect(adapter.requests.single.headers['Authorization'], isNull);
    expect(adapter.requests.single.uri.path, '/api/v1/update');
  });
  test('强制更新写入清单，且不能被稍后关掉', () async {
    final optional = await verify(await envelope(release()));
    expect(optional?.forceUpdate, isFalse);
    final forced = await verify(
      await envelope({...release(), 'force_update': true}),
    );
    expect(forced?.forceUpdate, isTrue);
    final updates = service(UpdateAdapter((_) async => jsonResponse({})));
    updates.release = forced;
    updates.dismiss();
    expect(updates.dismissedBuild, 0);
    updates.release = optional;
    updates.dismiss();
    expect(updates.dismissedBuild, optional?.build);
  });
  test('完整下载校验后才就绪，缓存按 SHA 复用且不重复请求', () async {
    final directory = await Directory.systemTemp.createTemp('qqm-update-test-');
    addTearDown(() => directory.delete(recursive: true));
    final adapter = UpdateAdapter(
      (options) async => options.uri.path.startsWith('/packages/')
          ? ResponseBody.fromBytes(
              package,
              200,
              headers: {
                'content-length': ['${package.length}'],
              },
            )
          : jsonResponse(
              await envelope(
                release(),
                requestNonce: options.uri.queryParameters['nonce']!,
              ),
            ),
    );
    final updates = service(adapter, directory: directory);
    await preferences.setAutoDownload(true);
    await updates.check();
    expect(updates.phase, UpdatePhase.ready);
    expect(await updates.downloadedFile!.readAsBytes(), package);
    await updates.check();
    expect(
      adapter.requests
          .where((request) => request.uri.path.startsWith('/packages/'))
          .length,
      1,
    );
  });
  test('旧 package 缓存校验后改为版本文件名，不重新下载或改写包内容', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-cache-name-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final selected = (await verify(await envelope(release())))!;
    final cache = await Directory(
      '${directory.path}/updates/${selected.build}-${selected.sha256.substring(0, 12)}',
    ).create(recursive: true);
    final legacy = File('${cache.path}/package.${selected.format}');
    await legacy.writeAsBytes(package);
    final adapter = UpdateAdapter(
      (options) async => jsonResponse(
        await envelope(
          release(),
          requestNonce: options.uri.queryParameters['nonce']!,
        ),
      ),
    );
    final updates = service(adapter, directory: directory);
    await updates.check();
    await updates.download();
    expect(updates.phase, UpdatePhase.ready);
    expect(
      updates.downloadedFile!.path,
      endsWith('qqbotmanager-windows-v1.3.2-build13.zip'),
    );
    expect(await updates.downloadedFile!.readAsBytes(), package);
    expect(await legacy.exists(), false);
    expect(
      adapter.requests.where((r) => r.uri.path.startsWith('/packages/')),
      isEmpty,
    );
  });
  test('下载篡改、过大或 HTTP 重定向均不能进入安装就绪', () async {
    for (final mode in ['hash', 'size', 'redirect']) {
      final directory = await Directory.systemTemp.createTemp(
        'qqm-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = UpdateAdapter((options) async {
        if (!options.uri.path.startsWith('/packages/')) {
          return jsonResponse(
            await envelope(
              release(),
              requestNonce: options.uri.queryParameters['nonce']!,
            ),
          );
        }
        if (mode == 'redirect') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://evil.invalid'],
            },
          );
        }
        return ResponseBody.fromBytes(
          mode == 'hash' ? List.filled(package.length, 0) : [...package, 0],
          200,
        );
      });
      final updates = service(adapter, directory: directory);
      await updates.check();
      await updates.download();
      expect(updates.phase, UpdatePhase.failed, reason: mode);
      expect(updates.downloadedFile, isNull);
      expect(
        adapter.requests.any((request) => request.uri.host == 'evil.invalid'),
        isFalse,
      );
      expect(
        await directory
            .list(recursive: true)
            .where((file) => file.path.endsWith('.part'))
            .length,
        0,
      );
    }
  });
  test('下载库抢先删除临时文件时清理幂等，不抛出异常或进入安装就绪', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-cleanup-race-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final adapter = UpdateAdapter(
      (options) async => jsonResponse(
        await envelope(
          release(),
          requestNonce: options.uri.queryParameters['nonce']!,
        ),
      ),
    );
    final parentZone = Zone.current;
    File realFile(String path) => parentZone.run(() => File(path));
    final http = InterruptedDownloadDio(realFile)..httpClientAdapter = adapter;
    final updates = service(adapter, directory: directory, http: http);
    await updates.check();
    var removedBeforeDelete = false;
    await IOOverrides.runZoned(
      updates.download,
      createFile: (path) => path.endsWith('.part')
          ? RemovedPartialFile(realFile(path), () => removedBeforeDelete = true)
          : realFile(path),
    );
    expect(removedBeforeDelete, isTrue);
    expect(updates.phase, UpdatePhase.failed);
    expect(updates.downloadedFile, isNull);
    expect(
      await directory
          .list(recursive: true)
          .where((file) => file.path.endsWith('.part'))
          .length,
      0,
    );
  });

  test('超限 JSON 清单被流式截断，不接受无界响应', () async {
    final adapter = UpdateAdapter(
      (_) async => ResponseBody.fromString('x' * 70000, 200),
    );
    final updates = service(adapter);
    await updates.check();
    expect(updates.phase, UpdatePhase.failed);
  });
  for (final width in [320.0, 390.0, 1280.0]) {
    for (final mode in ['latest', 'error', 'new']) {
      testWidgets('手动更新弹窗 $mode 在 $width 宽显示结果且不会叠加自动提醒', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final updates = service(
          UpdateAdapter(
            (request) async => mode == 'error'
                ? jsonResponse({}, 503)
                : jsonResponse(
                    await envelope(
                      mode == 'new' ? release() : null,
                      requestNonce: request.uri.queryParameters['nonce']!,
                    ),
                  ),
          ),
        );
        await tester.pumpWidget(
          ChangeNotifierProvider<AppUpdateService>.value(
            value: updates,
            child: MaterialApp(
              home: const UpdateNotice(child: Scaffold(body: UpdatePanel())),
            ),
          ),
        );
        // Ed25519 uses real asynchronous work, not the widget fake clock.
        await tester.runAsync(() async {
          await tester.tap(find.text('检查更新'));
          for (var attempt = 0; attempt < 200 && updates.busy; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(updates.busy, isFalse);
        });
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.text(
            mode == 'latest'
                ? '当前已是最新版本。'
                : mode == 'error'
                ? updates.error
                : '下载新版',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('关闭更新'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('更新通知与面板在 $width 宽可用，不丢失 Navigator/Overlay', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final updates = service(UpdateAdapter((_) async => jsonResponse({})));
      updates.release = await verify(await envelope(release()));
      updates.phase = UpdatePhase.available;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppUpdateService>.value(
          value: updates,
          child: MaterialApp(
            navigatorKey: navigator,
            builder: (_, child) => UpdateNotice(
              child: child!,
              dialogContext: () => navigator.currentState!.overlay!.context,
            ),
            home: const Scaffold(body: Text('原聊天保持在这里')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('下载新版'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.text('原聊天保持在这里'), findsOneWidget);
      expect(find.text('查看更新'), findsNothing);
    });
  }
  testWidgets('稍后只影响本次运行，重新打开仍提醒同一新版；无新版不弹窗', (tester) async {
    Future<void> open(AppUpdateService updates) => tester.pumpWidget(
      ChangeNotifierProvider<AppUpdateService>.value(
        key: UniqueKey(),
        value: updates,
        child: MaterialApp(
          home: UpdateNotice(child: const Scaffold(body: Text('聊天'))),
        ),
      ),
    );
    final first = service(UpdateAdapter((_) async => jsonResponse({})));
    first.release = await verify(await envelope(release()));
    first.phase = UpdatePhase.available;
    await open(first);
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    await first.setAutoDownload(false);
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    final second = service(UpdateAdapter((_) async => jsonResponse({})));
    second.release = first.release;
    second.phase = UpdatePhase.available;
    await open(second);
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    final latest = service(UpdateAdapter((_) async => jsonResponse({})));
    await open(latest);
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
  });
}
