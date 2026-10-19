import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/ui/screens/notifications_screen.dart';
import 'package:qq_bot_manager/ui/screens/group_settings_screen.dart';
import 'group_management_test.dart' show GroupFixtureApi, joinBody;
import 'support/fakes.dart';

void main() {
  late MemoryStorage storage;
  late GroupFixtureApi api;
  late BotClient bot;
  setUp(() {
    storage = MemoryStorage(config: validConfig());
    api = GroupFixtureApi();
    storage.storedSessions['g'] = ChatSession(
      id: 'g',
      name: '测试群',
      sessionType: 1,
      lastMessageTime: DateTime.now(),
    );
    bot = BotClient(storage, apiService: api);
    bot.refresh();
  });
  // No disk IO here; persistence is verified by the ordinary asynchronous core
  // tests. Waiting on a fake-async future from tearDown's real zone deadlocks.
  tearDown(() => bot.dispose());
  Widget shell(Widget child) => ChangeNotifierProvider<BotClient>.value(
    value: bot,
    child: MaterialApp(
      home: child,
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: widget!,
      ),
    ),
  );
  testWidgets('320像素群通知支持待审核筛选，确认前不审批，不默认拉黑', (tester) async {
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bot.groups.ingest('GROUP_JOIN_REQUEST', joinBody());
    await tester.pumpWidget(shell(const NotificationsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '待审核'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '同意'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '同意'));
    await tester.pumpAndSettle();
    expect(api.approvals, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.approvals, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '同意'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认同意'));
    await tester.pumpAndSettle();
    expect(api.approvals.single['approve'], isTrue);
    expect(api.approvals.single['blacklist'], isFalse);
    expect(bot.groups.notices.single.status, 'approved');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('群设置展示真实人数/机器人状态，成员分页和禁言，免打扰可保存', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      shell(GroupSettingsScreen(session: bot.sessions.single)),
    );
    await tester.pumpAndSettle();
    expect(find.text('123 人'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('已允许'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(bot.sessions.single.isMuted, isTrue);
    await tester.tap(find.text('群成员'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('加载更多成员'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('加载更多成员'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已加载 2 位成员'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '群成员').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置禁言'));
    await tester.pumpAndSettle();
    expect(api.mutes, isEmpty);
    await tester.tap(find.text('确认禁言'));
    await tester.pumpAndSettle();
    expect(api.mutes.single['op'], 'add');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('仅有群事件还没有聊天时，也能直接进入群聊设置', (tester) async {
    storage.storedSessions.clear();
    bot.refresh();
    bot.groups.ingest('GROUP_JOIN_REQUEST', joinBody());
    await tester.pumpWidget(shell(const NotificationsScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(TextButton, '群聊设置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(TextButton, '群聊设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '群聊设置'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupSettingsScreen), findsOneWidget);
    expect(bot.sessions.single.id, 'g');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
