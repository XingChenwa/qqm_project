// Uses only fake bot APIs and memory storage; never connects to QQ.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/widgets/emoji_picker.dart';

import 'support/fakes.dart';

class DelayedSendApi extends RecordingApi {
  Completer<void>? gate;

  @override
  Future<ApiResult<String>> sendQQMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String content,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async {
    await gate?.future;
    return record({'target': targetId, 'content': content, 'type': 0});
  }

  @override
  Future<ApiResult<String>> sendQQImage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String imageUrl,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async {
    await gate?.future;
    return record({'target': targetId, 'imageUrl': imageUrl, 'type': 7});
  }
}

Future<BotClient> host(WidgetTester tester, DelayedSendApi api) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final storage = MemoryStorage(
    config: validConfig()
      ..appId = ''
      ..clientSecret = '',
  );
  for (final id in ['A', 'B']) {
    storage.storedSessions[id] = ChatSession(
      id: id,
      name: '测试群$id',
      sessionType: 1,
      lastMessageTime: DateTime(2026, 10, id == 'A' ? 16 : 15),
    );
    for (var i = 0; i < 60; i++) {
      storage.storedMessages['$id-$i'] = MessageModel(
        id: '$id-$i',
        sessionId: id,
        senderId: 'member',
        senderName: '测试成员',
        content: '$id 历史消息 $i\n第二行',
        messageType: 0,
        timestamp: DateTime.now().subtract(Duration(seconds: 60 - i)),
      );
    }
  }
  final bot = BotClient(
    storage,
    apiService: api,
    webSocketService: TestGateway(),
  );
  final plugins = TestPluginManager(storage);
  addTearDown(bot.dispose);
  addTearDown(plugins.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider<BotClient>.value(value: bot),
        ChangeNotifierProvider<PluginManager>.value(value: plugins),
      ],
      child: MaterialApp(
        home: MainScreen(toggleTheme: () {}, themeMode: ThemeMode.light),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bot;
}

ScrollController timeline(WidgetTester tester, String id) => tester
    .widget<CustomScrollView>(find.byKey(ValueKey('messages-$id')))
    .controller!;

void main() {
  testWidgets('发送中切换到另一会话，迟到的成功响应不移动新会话或其草稿', (tester) async {
    final api = DelayedSendApi()..gate = Completer<void>();
    final bot = await host(tester, api);
    await tester.enterText(find.byType(TextField).last, 'A 会话正在发送');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.calls, isEmpty);
    await tester.tap(find.text('测试群B').first);
    await tester.pump(const Duration(milliseconds: 300));
    final controller = timeline(tester, 'B');
    controller.jumpTo(-300);
    await tester.enterText(find.byType(TextField).last, 'B 会话的新草稿');
    await tester.pump();
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(api.calls.single['target'], 'A');
    expect(controller.offset, closeTo(-300, .01));
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'B 会话的新草稿',
    );
    bot.addLocalBotMessage('B', '自动插件回复不会拉动阅读位置', 0);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(-300, .01));
    expect(find.text('有 1 条新消息，点击查看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表情面板发送成功定位最新，失败不定位（已移除重复侧栏入口）', (tester) async {
    final api = DelayedSendApi();
    await host(tester, api);
    final controller = timeline(tester, 'A');
    for (final fail in [false, true]) {
      controller.jumpTo(-300);
      await tester.pumpAndSettle();
      api.failSend = fail;
      await tester.tap(find.byTooltip('选择表情'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final widget = tester.widget<EmojiPicker>(find.byType(EmojiPicker).last);
      widget.onEmojiSelected!(
        EmojiItem(
          id: 'test',
          name: '测试表情',
          url: 'https://example.com/test.png',
          localPath: '${Directory.systemTemp.path}/qqm-missing-emoji.png',
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, fail ? closeTo(-300, .01) : 0);
      expect(find.byType(AlertDialog), fail ? findsOneWidget : findsNothing);
      if (fail) {
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }
    expect(api.calls, hasLength(2));
  });
}
