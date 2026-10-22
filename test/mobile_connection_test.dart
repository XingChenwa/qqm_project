import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/services/mobile_connection.dart';
import 'package:qq_bot_manager/services/websocket_service.dart' as gateway;
import 'package:qq_bot_manager/ui/widgets/mobile_connection_card.dart';
import 'support/fakes.dart';
import 'websocket_service_test.dart' show LocalGateway, until;

class ResumeGateway extends TestGateway {
  bool wanted = true;
  int recoveries = 0;
  @override
  bool get connectionRequested => wanted;
  @override
  Future<void> recoverAfterResume() async {
    recoveries++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('挂起后的假在线会立即恢复原会话；用户手动断开后不会擅自重连', () async {
    var now = DateTime(2026, 10, 22);
    final remote = await LocalGateway.start();
    final service = gateway.WebSocketService(clock: () => now);
    addTearDown(() async {
      service.dispose();
      await remote.close();
    });
    expect(
      await service.connect(wsUrl: remote.url, accessToken: 'fixture'),
      isTrue,
    );
    expect(remote.sockets.length, 1);
    now = now.add(const Duration(minutes: 3));
    await Future.wait([
      service.recoverAfterResume(),
      service.recoverAfterResume(),
    ]);
    expect(service.isConnected, isTrue);
    expect(remote.sockets.length, 2);
    expect(remote.payloads.where((e) => e['op'] == 6).length, 1);
    service.disconnect();
    await service.recoverAfterResume();
    expect(remote.sockets.length, 2);
    expect(service.connectionRequested, isFalse);
  });

  test('短暂离开只校验心跳，不重复登录或新建网关连接', () async {
    final remote = await LocalGateway.start();
    final service = gateway.WebSocketService();
    addTearDown(() async {
      service.dispose();
      await remote.close();
    });
    expect(
      await service.connect(wsUrl: remote.url, accessToken: 'fixture'),
      isTrue,
    );
    await service.recoverAfterResume();
    await until(() => remote.payloads.any((p) => p['op'] == 1));
    expect(remote.sockets.length, 1);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('${platform.name} 后台连接指引与显式保活，前台恢复不误改系统权限', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final storage = MemoryStorage(config: validConfig());
      final ws = ResumeGateway();
      final bot = BotClient(
        storage,
        apiService: RecordingApi(),
        webSocketService: ws,
      );
      final service = MobileConnection(bot: bot, storage: storage);
      addTearDown(service.dispose);
      addTearDown(bot.dispose);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MobileConnection.channel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      const notifications = MethodChannel('cn.uuze.botmanager/notifications');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        notifications,
        (_) async => true,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MobileConnection.channel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notifications,
          null,
        );
      });
      service.start();
      await tester.pumpWidget(
        ChangeNotifierProvider<MobileConnection>.value(
          value: service,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: MobileConnectionCard()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.android) {
        expect(service.enabled, isFalse);
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(service.enabled, isTrue);
        expect(service.running, isTrue);
        expect(calls, contains('start'));
      } else {
        expect(find.byType(Switch), findsNothing);
        expect(find.textContaining('iOS 会挂起'), findsOneWidget);
        expect(calls, isEmpty);
      }
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(ws.recoveries, 1);
      ws.wanted = false;
      ws.onConnectionStateChanged?.call('已断开');
      await tester.pumpAndSettle();
      expect(service.running, isFalse);
      if (platform == TargetPlatform.android) expect(calls, contains('stop'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  test('Android 保活使用显式前台服务且无开机自启，iOS 不伪造音频／定位后台模式', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('FOREGROUND_SERVICE_REMOTE_MESSAGING'));
    expect(manifest, contains('android:exported="false"'));
    expect(
      manifest,
      contains('android:foregroundServiceType="remoteMessaging"'),
    );
    expect(manifest, isNot(contains('BOOT_COMPLETED')));
    final service = File(
      'android/app/src/main/kotlin/cn/uuze/botmanager/ConnectionService.kt',
    ).readAsStringSync();
    expect(service, contains('START_NOT_STICKY'));
    final ios = File('ios/Runner/Info.plist').readAsStringSync();
    expect(ios, isNot(contains('<string>audio</string>')));
    expect(ios, isNot(contains('<string>location</string>')));
  });
}
