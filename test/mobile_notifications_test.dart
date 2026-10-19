import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/services/mobile_notifications.dart';
import 'support/fakes.dart';
import 'group_management_test.dart' show GroupFixtureApi, joinBody;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryStorage storage;
  late BotClient bot;
  late TestGateway gateway;
  late MobileNotifications notifications;
  late List<MethodCall> calls;
  late List<String> opened;
  bool permission = true;
  setUp(() {
    storage = MemoryStorage(config: validConfig());
    gateway = TestGateway();
    bot = BotClient(
      storage,
      apiService: GroupFixtureApi(),
      webSocketService: gateway,
    );
    calls = [];
    opened = [];
    permission = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileNotifications.channel, (call) async {
          calls.add(call);
          if (call.method == 'isAllowed' ||
              call.method == 'requestPermission') {
            return permission;
          }
          return null;
        });
    notifications = MobileNotifications(
      bot: bot,
      storage: storage,
      supported: true,
      visibleSession: () => null,
      onOpen: (app, session, notice) async {
        opened.add('$app/$session/$notice');
      },
    );
  });
  tearDown(() {
    notifications.dispose();
    bot.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileNotifications.channel, null);
  });
  test('不自动请求通知权限；用户启用后才调用原生通知栏', () async {
    await notifications.start();
    expect(calls.any((c) => c.method == 'requestPermission'), isFalse);
    bot.groups.ingest('GROUP_JOIN_REQUEST', joinBody());
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((c) => c.method == 'show'), isFalse);
    await notifications.setEnabled(true);
    bot.groups.ingest('GROUP_JOIN_REQUEST', joinBody(request: 'new-request'));
    await Future<void>.delayed(Duration.zero);
    final shown =
        calls.where((c) => c.method == 'show').single.arguments as Map;
    expect(shown['title'], '入群申请');
    final payload = jsonDecode(shown['payload']);
    expect(payload['appId'], bot.config.appId);
    expect(payload['sessionId'], 'g');
    expect(storage.mobileNotifications, isTrue);
  });
  test('拒绝系统权限不伪装已开启；禁用后清除已送达通知', () async {
    await notifications.start();
    permission = false;
    await expectLater(notifications.setEnabled(true), throwsStateError);
    expect(notifications.enabled, isFalse);
    expect(storage.mobileNotifications, isFalse);
    permission = true;
    await notifications.setEnabled(true);
    await notifications.setEnabled(false);
    expect(calls.any((c) => c.method == 'cancelAll'), isTrue);
  });
  test('已屏蔽会话不发系统通知，机器人切换清除旧通知', () async {
    await bot.addSession('g', isGroup: true);
    await bot.setSessionMuted('g', true);
    await notifications.start();
    await notifications.setEnabled(true);
    bot.groups.ingest('GROUP_JOIN_REQUEST', joinBody());
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((c) => c.method == 'show'), isFalse);
    await bot.updateConfig(validConfig()..appId = 'another-app');
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((c) => c.method == 'cancelAll'), isTrue);
  });
  test('桌面平台完全不调用手机通知通道，通知ID稳定', () async {
    notifications.dispose();
    notifications = MobileNotifications(
      bot: bot,
      storage: storage,
      supported: false,
      visibleSession: () => null,
      onOpen: (_, _, _) async {},
    );
    await notifications.start();
    await notifications.setEnabled(true);
    expect(calls, isEmpty);
    expect(
      MobileNotifications.notificationId('app/group'),
      MobileNotifications.notificationId('app/group'),
    );
    expect(
      MobileNotifications.notificationId('app/group'),
      isNot(MobileNotifications.notificationId('other/group')),
    );
  });
  testWidgets('原生通道无响应时销毁可取消计时器，不导致白屏或悬挂', (tester) async {
    final never = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MobileNotifications.channel,
          (_) => never.future,
        );
    unawaited(notifications.start());
    await tester.pump(const Duration(milliseconds: 1));
    notifications.dispose();
    never.complete(null);
    await tester.pump();
    notifications = MobileNotifications(
      bot: bot,
      storage: storage,
      supported: false,
      visibleSession: () => null,
      onOpen: (_, _, _) async {},
    );
    expect(tester.takeException(), isNull);
  });
}
