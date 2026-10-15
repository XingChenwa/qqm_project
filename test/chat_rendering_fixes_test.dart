import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/widgets/chat_timeline.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/ui/widgets/message_image.dart';

import 'full_group_message_test.dart' show groupEvent, received;
import 'support/fakes.dart';

class ImageRecordingApi extends RecordingApi {
  @override
  Future<ApiResult<String>> sendQQImage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String imageUrl,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async => record({'target': targetId, 'imageUrl': imageUrl, 'type': 7});
}

MessageModel timelineMessage(int index) => MessageModel(
  id: 'message-$index',
  sessionId: 'timeline',
  senderId: 'user',
  senderName: '测试用户',
  content: '消息 $index',
  messageType: 0,
  timestamp: DateTime(2026, 10, 15).add(Duration(seconds: index)),
);

Future<void> decodeTestImages(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final images = tester.widgetList<RawImage>(find.byType(RawImage));
    if (images.isNotEmpty && images.every((image) => image.image != null)) {
      return;
    }
  }
}

void main() {
  testWidgets('引用消息反复收起展开及移出后重建不会损坏展开状态', (tester) async {
    final bucket = PageStorageBucket();
    final message = received(
      groupEvent(
        'expand-regression',
        type: 103,
        fields: {
          'msg_elements': [
            {
              'message_type': 103,
              'content': '引用正文\n第二行',
              'msg_elements': [
                {'content': '嵌套引用内容'},
              ],
            },
          ],
        },
      ),
    );
    Widget host({bool show = true}) => MaterialApp(
      home: Scaffold(
        body: PageStorage(
          bucket: bucket,
          child: SingleChildScrollView(
            child: show ? MessageBubble(message: message) : const Text('其他消息'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('引用消息 · 1 个元素').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('引用消息 · 1 个元素').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('引用消息 · 1 个元素').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(host(show: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('引用正文\n第二行'), findsOneWidget);
  });

  for (final position in [0.0, -480.0]) {
    testWidgets('新消息不移动阅读锚点，原位置为 $position，提示可手动查看且重开定位最新', (tester) async {
      final controller = ScrollController(keepScrollOffset: false);
      addTearDown(controller.dispose);
      var messages = List.generate(80, timelineMessage);
      var revision = 0;
      Widget host() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 450,
            child: ChatTimeline(
              sessionId: 'timeline',
              messages: messages,
              openRevision: revision,
              controller: controller,
              itemBuilder: (_, index) => SizedBox(
                height: 65 + index % 5 * 23,
                child: Text(
                  messages[index].content,
                  key: ValueKey('text-${messages[index].id}'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      controller.jumpTo(position);
      await tester.pumpAndSettle();
      final anchor = find.byKey(
        ValueKey('text-message-${position == 0 ? 79 : 75}'),
      );
      expect(anchor, findsOneWidget);
      final before = tester.getTopLeft(anchor);
      messages = [...messages, timelineMessage(80), timelineMessage(81)];
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(position, .01));
      expect(tester.getTopLeft(anchor).dy, closeTo(before.dy, .01));
      expect(find.text('有 2 条新消息，点击查看'), findsOneWidget);
      expect(find.byKey(const ValueKey('text-message-81')), findsNothing);
      // Profile/read-status refreshes must not duplicate the new-message count.
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.text('有 2 条新消息，点击查看'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new-messages-indicator')));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(find.byKey(const ValueKey('text-message-81')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('new-messages-indicator')),
        findsNothing,
      );
      messages = [...messages, timelineMessage(82)];
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.text('有 1 条新消息，点击查看'), findsOneWidget);
      revision++;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(find.byKey(const ValueKey('text-message-82')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('new-messages-indicator')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('真实会话接收不滚动，手动发送成功才定位最新，失败保持原位置', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage(
      config: validConfig()
        ..appId = ''
        ..clientSecret = '',
    );
    storage.storedSessions['group-openid'] = ChatSession(
      id: 'group-openid',
      name: '测试群聊',
      sessionType: 1,
      lastMessageTime: DateTime.now(),
    );
    for (var i = 0; i < 60; i++) {
      final message = timelineMessage(i);
      storage.storedMessages[message.id] = MessageModel(
        id: message.id,
        sessionId: 'group-openid',
        senderId: 'member-openid',
        senderName: '群成员',
        content: '已有消息 $i\n第二行',
        messageType: 0,
        timestamp: DateTime.now().subtract(Duration(minutes: 60 - i)),
      );
    }
    final gateway = TestGateway();
    final api = RecordingApi();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    final plugins = PluginManager(storage);
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
    final list = find.byKey(const ValueKey('messages-group-openid'));
    final controller = tester.widget<CustomScrollView>(list).controller!;
    controller.jumpTo(-400);
    await tester.pumpAndSettle();
    final latestOld = find.text('已有消息 56\n第二行');
    final before = tester.getTopLeft(latestOld);
    gateway.events.add({
      'id': 'new-arrival',
      'sessionId': 'group-openid',
      'senderId': 'member-openid',
      'senderName': '群成员',
      'content': '刚刚收到的新消息',
      'timestamp': DateTime.now(),
      'isGroup': true,
      'eventType': 'GROUP_MESSAGE_CREATE',
    });
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(-400, .01));
    expect(tester.getTopLeft(latestOld).dy, closeTo(before.dy, .01));
    expect(find.text('有 1 条新消息，点击查看'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '手动回复后应看到这一条');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    expect(controller.offset, 0);
    expect(find.byKey(const ValueKey('new-messages-indicator')), findsNothing);
    final sentMessage = find.text('手动回复后应看到这一条');
    expect(sentMessage, findsWidgets);
    final sentY = tester.getTopLeft(sentMessage.last).dy;
    gateway.events.add({
      'id': 'arrival-after-send',
      'sessionId': 'group-openid',
      'senderId': 'member-openid',
      'senderName': '群成员',
      'content': '发送后再次收到的新消息',
      'timestamp': DateTime.now(),
      'isGroup': true,
      'eventType': 'GROUP_MESSAGE_CREATE',
    });
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(tester.getTopLeft(sentMessage.last).dy, closeTo(sentY, .01));
    expect(find.text('有 1 条新消息，点击查看'), findsOneWidget);
    controller.jumpTo(-300);
    await tester.pumpAndSettle();
    api.failSend = true;
    await tester.enterText(find.byType(TextField).last, '失败时保留的草稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(-300, .01));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      '失败时保留的草稿',
    );
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日志').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('聊天会话').first);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.byKey(const ValueKey('new-messages-indicator')), findsNothing);
    expect(find.text('发送后再次收到的新消息'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final configured in [false, true]) {
    testWidgets('${configured ? '配置发送' : '普通发送'}的本地图片可预览，历史重载和文件 URI 仍支持', (
      tester,
    ) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('qqm-image-preview-'),
      );
      final file = File('${directory!.path}/发送测试.png');
      await tester.runAsync(
        () =>
            file.writeAsBytes(img.encodePng(img.Image(width: 40, height: 20))),
      );
      addTearDown(() async {
        imageCache.clear();
        imageCache.clearLiveImages();
        try {
          if (await file.exists()) await file.delete();
          await directory.delete();
        } on FileSystemException {
          // Windows can retain the native decoder's file mapping until the
          // tester exits. Never delete a wider directory to force cleanup.
        }
      });
      final storage = MemoryStorage(config: validConfig());
      final api = ImageRecordingApi();
      final bot = BotClient(storage, apiService: api);
      addTearDown(bot.dispose);
      final sent = configured
          ? await bot.sendConfiguredMessage(
              'user',
              OutgoingMessage(type: 7, mediaSource: file.path),
            )
          : await bot.sendImageMessage('user', file.path);
      expect(sent, isTrue);
      expect(api.calls, hasLength(1));
      final message = MessageModel.fromMap(bot.messages.single.toMap());
      expect(message.imageUrl, file.path);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageBubble(message: message)),
        ),
      );
      await decodeTestImages(tester);
      await tester.pumpAndSettle();
      final raw = tester.widget<RawImage>(find.byType(RawImage).first);
      expect(raw.image, isNotNull);
      expect(find.byType(CachedNetworkImage), findsNothing);
      await tester.tap(find.byType(MessageImage));
      await tester.pumpAndSettle();
      await decodeTestImages(tester);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('图片预览'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭图片预览'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageImage(
              source: file.uri.toString(),
              allowLocalFile: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await decodeTestImages(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('缺失本地图片显示原因，接收消息不能借图片地址读取本地文件', (tester) async {
    final missing = '${Directory.systemTemp.path}/qqm-no-such-sent-image.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MessageImage(source: missing, allowLocalFile: true),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('本地图片无法读取，可能已移动或删除'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 320, child: MessageImage(source: missing)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('没有可用的图片预览地址'), findsOneWidget);
    expect(
      MessageImage.localFile('file://remote-server/share/image.png'),
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
