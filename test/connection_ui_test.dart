import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/qq_qr_login_service.dart';
import 'package:qq_bot_manager/ui/screens/onboarding_screen.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';

import 'support/fakes.dart';

class QrConnectionApi extends RecordingApi {
  @override
  Future<ApiResult<String>> getGatewayUrl({
    required String baseUrl,
    required String accessToken,
  }) async => ApiResult.failure('fixture offline gateway');
}

class DemoQrService extends QqQrLoginService {
  final bool authorize;
  bool destroyed = false;
  DemoQrService({this.authorize = false});
  @override
  Future<void> start() async {
    phase = authorize ? QrLoginPhase.authorized : QrLoginPhase.waiting;
    message = authorize ? '授权成功，等待确认保存。' : '等待手机 QQ 扫码…';
    if (authorize) {
      credentials = const QrBotCredentials(
        '100000001',
        'fixture-only-app-secret',
      );
    } else {
      // Explicitly fake task. No network or usable authorization is generated.
      qrUri = Uri.parse(
        'https://q.qq.com/qqbot/openclaw/connect.html?task_id=offline-ui-fixture&source=&_wv=2',
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    destroyed = true;
    super.dispose();
  }
}

Future<void> captureUi(WidgetTester tester, String name) async {
  if (Platform.environment['QQM_CAPTURE_UI'] != '1') return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture-ui')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = await Directory(
      'build/ui-previews-1.3.8',
    ).create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget connectionHost(
  MemoryStorage storage,
  BotClient bot,
  PluginManager plugins,
  DemoQrService Function() factory,
) => MultiProvider(
  providers: [
    Provider<StorageService>.value(value: storage),
    ChangeNotifierProvider<BotClient>.value(value: bot),
    ChangeNotifierProvider<PluginManager>.value(value: plugins),
  ],
  child: RepaintBoundary(
    key: const ValueKey('capture-ui'),
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      debugShowCheckedModeBanner: false,
      home: SettingsScreen(qrServiceFactory: factory),
    ),
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (Platform.environment['QQM_CAPTURE_UI'] == '1' && Platform.isWindows) {
      for (final entry in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(1280, 800),
  ]) {
    testWidgets('扫码优先，切换手动停止等待且不保存，在 ${size.width.toInt()} 宽不溢出', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final bot = BotClient(storage);
      final plugins = TestPluginManager(storage);
      final service = DemoQrService();
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await tester.pumpWidget(
        connectionHost(storage, bot, plugins, () => service),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '扫码连接（推荐）'))
            .selected,
        isTrue,
      );
      expect(find.text('测试凭据'), findsNothing);
      await tester.ensureVisible(find.text('生成登录二维码'));
      await tester.tap(find.text('生成登录二维码'));
      await tester.pumpAndSettle();
      expect(find.text('扫码前请确认'), findsOneWidget);
      expect(service.phase, QrLoginPhase.idle);
      await tester.tap(find.text('我已了解，继续扫码'));
      await tester.pumpAndSettle();
      expect(find.text('等待手机 QQ 扫码…'), findsOneWidget);
      expect(storage.config.appId, isEmpty);
      await captureUi(tester, 'qr-${size.width.toInt()}');
      await tester.ensureVisible(find.text('手动配置'));
      await tester.tap(find.text('手动配置'));
      await tester.pumpAndSettle();
      expect(service.destroyed, isTrue);
      expect(service.qrUri, isNull);
      expect(find.text('AppID'), findsOneWidget);
      expect(find.text('机器人密钥'), findsOneWidget);
      expect(find.text('测试凭据'), findsOneWidget);
      expect(find.text('保存手动配置'), findsOneWidget);
      expect(storage.config.appId, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('扫码前提示重置，取消不创建；授权后自动更新对应 AppID 且保留其他机器人', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = validConfig()
      ..appId = '100000001'
      ..autoReconnect = false
      ..markdownTemplateId = 'keep-template';
    final storage = MemoryStorage(config: original);
    final bot = BotClient(
      storage,
      apiService: QrConnectionApi(),
      webSocketService: TestGateway(),
    );
    final logs = <String>[];
    bot.onLog = logs.add;
    final plugins = TestPluginManager(storage);
    final service = DemoQrService(authorize: true);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.pumpWidget(
      connectionHost(storage, bot, plugins, () => service),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('生成登录二维码'));
    await tester.tap(find.text('生成登录二维码'));
    await tester.pumpAndSettle();
    expect(storage.config.appId, '100000001');
    expect(find.text('扫码前请确认'), findsOneWidget);
    expect(service.phase, QrLoginPhase.idle);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.phase, QrLoginPhase.idle);
    expect(storage.config.clientSecret, original.clientSecret);
    await tester.tap(find.text('生成登录二维码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已了解，继续扫码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture-only-app-secret'), findsNothing);
    expect(find.text('更新当前机器人凭据？'), findsNothing);
    expect(storage.config.appId, '100000001');
    expect(storage.config.clientSecret, 'fixture-only-app-secret');
    expect(storage.config.autoReconnect, isFalse);
    expect(storage.config.markdownTemplateId, 'keep-template');
    expect(logs.join('\n'), isNot(contains('fixture-only-app-secret')));
    expect(service.credentials, isNull);
    expect(service.phase, QrLoginPhase.saved);
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('实际引导界面预览 ${width.toInt()}', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture-ui'),
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            debugShowCheckedModeBanner: false,
            home: OnboardingScreen(onFinished: (_) async {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await captureUi(tester, 'onboarding-${width.toInt()}');
      expect(tester.takeException(), isNull);
    });
  }
}
