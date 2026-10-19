import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/websocket_service.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/ui/widgets/received_message_view.dart';

import 'support/fakes.dart';
import 'websocket_service_test.dart' show LocalGateway, until;

const records =
    '=== 消息 1 ===\n[消息内容] 今天的学习计划已完成\n\n=== 消息 2 ===\n[消息内容] 很棒！继续保持，明天继续加油';

Map<String, dynamic> groupEvent(
  String id, {
  int type = 0,
  String content = '大家早上好呀',
  bool bot = false,
  Map<String, dynamic> fields = const {},
}) => {
  'id': id,
  'group_openid': 'group-openid',
  'author': {
    'id': 'legacy-id',
    'member_openid': 'member-openid',
    'username': '小明',
    'member_role': 'admin',
    'bot': bot,
  },
  'content': content,
  'message_type': type,
  'timestamp': DateTime.now().toIso8601String(),
  'message_scene': {
    'source': 'default',
    'ext': [
      'msg_idx=REFIDX_$id==',
      'auth_token=test-secret',
      if (type == 103) 'ref_msg_idx=TMP_source==',
    ],
  },
  ...fields,
};

Map<String, dynamic> normalized(
  Map<String, dynamic> raw, {
  String eventType = 'GROUP_MESSAGE_CREATE',
}) => {
  'id': raw['id'],
  'sessionId': raw['group_openid'],
  'senderId': raw['author']['member_openid'],
  'senderName': raw['author']['username'],
  'senderRole': raw['author']['member_role'],
  'senderIsBot': raw['author']['bot'],
  'content': raw['content'],
  'sourceMessageType': raw['message_type'],
  'timestamp': DateTime.parse(raw['timestamp']),
  'isGroup': true,
  'eventType': eventType,
  'extra': raw,
};

MessageModel received(Map<String, dynamic> raw) => MessageModel(
  id: raw['id'],
  sessionId: raw['group_openid'],
  senderId: raw['author']['member_openid'],
  senderName: raw['author']['username'],
  senderRole: raw['author']['member_role'],
  content: raw['content'],
  messageType: 0,
  timestamp: DateTime.parse(raw['timestamp']),
  extra: normalized(raw),
);

void main() {
  test('旧配置默认处理全量消息但不自动回复，新开关可保存和恢复', () {
    final legacy = BotConfig.fromMap({});
    expect(legacy.receiveAllGroupMessages, isTrue);
    expect(legacy.autoReplyToAllGroupMessages, isFalse);
    final changed = BotConfig(
      receiveAllGroupMessages: false,
      autoReplyToAllGroupMessages: true,
    );
    final restored = BotConfig.fromMap(jsonDecode(jsonEncode(changed.toMap())));
    expect(restored.receiveAllGroupMessages, isFalse);
    expect(restored.autoReplyToAllGroupMessages, isTrue);
  });

  test('官方三类示例经真实本地网关接收，引用记录保留且摘要不再误报图片', () async {
    final local = await LocalGateway.start();
    final service = WebSocketService();
    final storage = MemoryStorage(config: validConfig());
    final bot = BotClient(
      storage,
      apiService: RecordingApi(),
      webSocketService: service,
    );
    addTearDown(() async {
      bot.dispose();
      await local.close();
    });
    var autoReplies = 0;
    bot.onMessageReceived = (_) => autoReplies++;
    expect(
      await service.connect(
        wsUrl: local.url,
        accessToken: 'test-token',
        autoReconnect: false,
      ),
      isTrue,
    );
    local.event('GROUP_MESSAGE_CREATE', groupEvent('text'));
    local.event(
      'GROUP_MESSAGE_CREATE',
      groupEvent(
        'photo',
        content: '分享一张今天的风景照',
        fields: {
          'attachments': [
            {
              'url': '//example.com/photo.jpg',
              'content_type': 'image/jpeg',
              'filename': 'photo.jpg',
              'width': 1920,
              'height': 1080,
              'size': 256000,
            },
          ],
        },
      ),
    );
    local.event(
      'GROUP_MESSAGE_CREATE',
      groupEvent(
        'quote',
        type: 103,
        content: ' ',
        fields: {
          'msg_elements': [
            {'content': records},
          ],
        },
      ),
    );
    await until(() => bot.messages.length == 3);
    expect(bot.fullGroupMessageCount, 3);
    // Delivery to the plugin dispatcher is not itself a QQ reply.
    expect(autoReplies, 3);
    expect(bot.messages.first.senderId, 'member-openid');
    expect(bot.messages.first.senderRole, 'admin');
    expect(bot.messages[1].imageUrl, 'https://example.com/photo.jpg');
    expect(bot.messages[1].receivedBody.attachments.single.size, 256000);
    final quote = bot.messages.last;
    expect(quote.sourceMessageType, 103);
    expect(quote.messageType, 0);
    expect(quote.receivedBody.elements.single.text, records);
    expect(quote.referenceIndex, 'REFIDX_quote==');
    expect(quote.receivedBody.scene['ref_msg_idx'], 'TMP_source==');
    expect(bot.sessions.single.lastMessage, startsWith('[引用消息] === 消息 1 ==='));
    expect(bot.sessions.single.lastMessage, isNot(contains('图片')));
    final restored = MessageModel.fromMap(
      jsonDecode(jsonEncode(quote.toMap())),
    );
    expect(restored.receivedBody.elements.single.text, records);
    expect(restored.referenceIndex, 'REFIDX_quote==');
    expect(
      restored.rawEvent['message_scene']['ext'][1],
      'auth_token=test-secret',
    );
    // 全量消息同样可作为正常的手动被动回复来源。
    expect(
      await bot.sendTextMessage('group-openid', '收到', isGroup: true),
      isTrue,
    );
  });

  test('全量与 @ 重复推送只保存一次，不漏掉后到的 @ 且不重复触发自动回复', () async {
    final gateway = TestGateway();
    final bot = BotClient(
      MemoryStorage(config: validConfig()),
      apiService: RecordingApi(),
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    final dispatched = <MessageModel>[];
    bot.onMessageReceived = dispatched.add;
    final raw = groupEvent('same-id');
    gateway.events.add(normalized(raw));
    await Future<void>.delayed(Duration.zero);
    expect(bot.messages, hasLength(1));
    expect(dispatched.single.isFullGroupMessage, isTrue);
    gateway.events.add(normalized(raw, eventType: 'GROUP_AT_MESSAGE_CREATE'));
    gateway.events.add(normalized(raw, eventType: 'GROUP_AT_MESSAGE_CREATE'));
    gateway.events.add(normalized(raw));
    await Future<void>.delayed(Duration.zero);
    expect(bot.messages, hasLength(1));
    expect(dispatched, hasLength(1));
    bot.config.autoReplyToAllGroupMessages = true;
    final second = groupEvent('second');
    gateway.events.add(normalized(second));
    gateway.events.add(
      normalized(second, eventType: 'GROUP_AT_MESSAGE_CREATE'),
    );
    gateway.events.add(normalized(groupEvent('another-bot', bot: true)));
    await Future<void>.delayed(Duration.zero);
    expect(bot.messages, hasLength(3));
    expect(dispatched.map((m) => m.id), ['same-id', 'second']);
    expect(bot.messages.last.isBotAuthor, isTrue);
    expect(bot.shouldAutoRespondTo(bot.messages.last), isFalse);
  });

  test('关闭本地全量处理不影响 @ 事件，自动回复来源跳过其他机器人', () async {
    final gateway = TestGateway();
    final api = RecordingApi();
    final bot = BotClient(
      MemoryStorage(config: validConfig()),
      apiService: api,
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    bot.config.receiveAllGroupMessages = false;
    gateway.events.add(normalized(groupEvent('ignored')));
    gateway.events.add(
      normalized(
        groupEvent('at-message'),
        eventType: 'GROUP_AT_MESSAGE_CREATE',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(bot.messages.single.id, 'at-message');
    expect(bot.fullGroupMessageCount, 0);
    bot.config.receiveAllGroupMessages = true;
    gateway.events.add(normalized(groupEvent('bot-message', bot: true)));
    await Future<void>.delayed(Duration.zero);
    expect(
      await bot.sendTextMessage('group-openid', '测试回复', isGroup: true),
      isTrue,
    );
    expect(api.calls.last['msgId'], 'at-message');
  });

  test('旧自动回复开关不再参与全量消息回复，普通聊天不会兜底', () async {
    final config = validConfig()
      ..enableAutoReply = true
      ..defaultAutoReply = '收到';
    final storage = MemoryStorage(config: config);
    final manager = TestPluginManager(storage);
    addTearDown(manager.dispose);
    await manager.init();
    PluginMessage message() => PluginMessage(
      messageId: 'full',
      sessionId: 'g',
      senderId: 'u',
      senderName: '用户',
      content: '大家早上好呀',
      messageType: 0,
      isGroup: true,
      isFullGroupMessage: true,
      timestamp: DateTime.now(),
    );
    expect(await manager.processMessage(message()), isEmpty);
    config.autoReplyToAllGroupMessages = true;
    await storage.saveBotConfig(config);
    expect(await manager.processMessage(message()), isEmpty);
  });

  test('多种附件、卡片和递归元素完整解析，@ 用户别名在嵌套消息中也生效', () {
    final body = ReceivedMessageBody.fromMap(
      groupEvent(
        'rich',
        type: 102,
        content: '',
        fields: {
          'mentions': [
            {
              'id': 'old-id',
              'member_openid': 'member-id',
              'user_openid': 'user-id',
              'username': '小红',
            },
          ],
          'attachments': [
            {
              'content_type': 'image/png',
              'url': '//example.com/photo.png',
              'filename': '图片.png',
            },
            {
              'content_type': 'voice',
              'url': 'https://example.com/silk',
              'voice_wav_url': '//example.com/voice.wav',
              'asr_refer_text': '大家好',
            },
            {
              'content_type': 'video/mp4',
              'url': 'https://example.com/video.mp4',
            },
            {
              'content_type': 'file',
              'url': 'https://example.com/file.zip',
              'size': 1024,
            },
          ],
          'ark_data': {
            'ark_type': 'miniapp',
            'ark_name': '小程序',
            'prompt': '点击查看',
            'fields': {
              'title': '示例小程序',
              'desc': '介绍',
              'jump_url': 'https://example.com/app',
              'preview': '//example.com/preview.jpg',
            },
          },
          'msg_elements': [
            {
              'message_type': 103,
              'msg_idx': 'element==',
              'author': {'username': '小红', 'member_role': 'owner'},
              'content': '<@!member-id> <qqbot-at-user id="user-id"/>',
              'msg_elements': [
                {
                  'message_type': 3,
                  'ark_data': {
                    'ark_name': '位置',
                    'fields': {'address': '公园'},
                  },
                },
              ],
            },
          ],
        },
      ),
    );
    expect(body.attachments.map((a) => a.kindLabel), ['图片', '语音', '视频', '文件']);
    expect(body.attachments[1].openUrl, 'https://example.com/voice.wav');
    expect(body.attachments[1].transcript, '大家好');
    expect(body.attachments[3].isImage, isFalse);
    expect(body.card?.type, 'miniapp');
    expect(body.card?.title, '示例小程序');
    expect(body.card?.previewUrl, 'https://example.com/preview.jpg');
    expect(body.elements.single.displayText, '@小红 @小红');
    expect(body.elements.single.authorRole, 'owner');
    expect(body.elements.single.elementIndex, 'element==');
    expect(body.elements.single.elements.single.card?.description, '公园');
  });

  test('递归展示有深度与总元素数上限，原始事件不被截断', () {
    final wide = groupEvent(
      'wide',
      fields: {
        'msg_elements': List.generate(220, (i) => {'content': '消息 $i'}),
      },
    );
    final body = ReceivedMessageBody.fromMap(wide);
    expect(body.elements, hasLength(200));
    expect(body.hasMoreElements, isTrue);
    expect(wide['msg_elements'], hasLength(220));
    Map<String, dynamic> deep = {'content': '最深消息'};
    for (var i = 0; i < 15; i++) {
      deep = {
        'msg_elements': [deep],
      };
    }
    var parsed = ReceivedMessageBody.fromMap(deep);
    var depth = 0;
    while (parsed.elements.isNotEmpty) {
      parsed = parsed.elements.single;
      depth++;
    }
    expect(depth, 8);
    expect(parsed.hasMoreElements, isTrue);
  });

  test('消息详情隐藏令牌但不修改原始事件或损坏带等号的引用索引', () {
    final raw = groupEvent(
      'secure',
      fields: {
        'authorization': 'Bearer value',
        'nested': {'access_token': 'another-secret'},
      },
    );
    final safe = redactMessageDetails(raw);
    final json = jsonEncode(safe);
    expect(json, isNot(contains('test-secret')));
    expect(json, isNot(contains('another-secret')));
    expect(json, isNot(contains('Bearer value')));
    expect(json, contains('REFIDX_secure=='));
    expect(raw['message_scene']['ext'][1], 'auth_token=test-secret');
    expect(raw['nested']['access_token'], 'another-secret');
  });

  testWidgets('空正文引用消息直接显示聊天记录，群角色和全量标签正确', (tester) async {
    final message = received(
      groupEvent(
        'quote-ui',
        type: 103,
        content: ' ',
        fields: {
          'msg_elements': [
            {'content': records},
          ],
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MessageBubble(message: message)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('引用消息 · 1 个元素'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SelectableText &&
            (w.data ?? w.textSpan?.toPlainText()) == records,
      ),
      findsOneWidget,
    );
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('全量'), findsOneWidget);
    expect(find.text('[图片消息]'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('消息详情'), findsOneWidget);
    final displayed = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(displayed, contains('REFIDX_quote-ui=='));
    expect(displayed, isNot(contains('test-secret')));
  });

  testWidgets('窄窗口可展示多附件、语音转写、卡片和嵌套消息；不自动播放或打开链接', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final message = received(
      groupEvent(
        'media-ui',
        content: '正文',
        fields: {
          'attachments': [
            {
              'filename': '风景.png',
              'content_type': 'image/png',
              'width': 1920,
              'height': 1080,
            },
            {
              'filename': '录音.silk',
              'content_type': 'voice',
              'asr_refer_text': '今天的学习计划',
            },
            {'filename': '视频.mp4', 'content_type': 'video/mp4'},
            {'filename': '资料.zip', 'content_type': 'file', 'size': 2048},
          ],
          'ark_data': {
            'ark_name': '小程序',
            'fields': {'title': '示例小程序', 'desc': '卡片介绍', 'source': 'QQ'},
          },
          'msg_elements': [
            {
              'content': '嵌套正文',
              'author': {'username': '小红', 'member_role': 'owner'},
            },
          ],
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MessageBubble(message: message)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final title in [
      '风景.png',
      '录音.silk',
      '视频.mp4',
      '资料.zip',
      '示例小程序',
      '语音转写：今天的学习计划',
      '嵌套正文',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('小红 · 群主'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤回后的结构化消息不再显示原始正文和附件', (tester) async {
    final message = received(
      groupEvent(
        'recall',
        fields: {
          'attachments': [
            {'filename': '文件.zip', 'content_type': 'file'},
          ],
        },
      ),
    ).copyWith(isRecalled: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageBubble(message: message)),
      ),
    );
    expect(find.text('这条消息已撤回'), findsOneWidget);
    expect(find.byType(ReceivedMessageView), findsNothing);
    expect(find.text('详情'), findsNothing);
  });
}
