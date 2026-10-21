import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/voice_attachment_service.dart';
import 'package:qq_bot_manager/ui/screens/chat_history_screen.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/ui/widgets/voice_attachment.dart';
import 'package:qq_bot_manager/utils/message_history.dart';
import 'client_140_features_test.dart' show pcmFixture;
import 'mobile_and_group_commands_test.dart' show appShell;
import 'support/fakes.dart';

class _VoiceAdapter implements HttpClientAdapter {
  final Uint8List bytes;
  final requests = <RequestOptions>[];
  _VoiceAdapter(this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('下载官方 WAV 保留字节与采样率，不调用本地转换或请求 SILK 地址', () async {
    final directory = await Directory.systemTemp.createTemp('qqm-wav-test-');
    addTearDown(() => directory.delete(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const conversionChannel = MethodChannel('cn.uuze.botmanager/audio');
    messenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => directory.path,
    );
    var conversions = 0;
    messenger.setMockMethodCallHandler(conversionChannel, (_) async {
      conversions++;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(conversionChannel, null);
    });
    final wav = pcmFixture(rate: 16000, frames: 160);
    final adapter = _VoiceAdapter(wav);
    final service = VoiceAttachmentService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    final voice = await service.prepare(
      const ReceivedAttachment(
        url: 'https://multimedia.nt.qq.com.cn/original.silk',
        voiceWavUrl: 'https://multimedia.nt.qq.com.cn/official.wav',
        contentType: 'voice',
      ),
      CancelToken(),
    );
    expect(adapter.requests.single.uri.path, '/official.wav');
    expect(
      adapter.requests.single.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(voice.extension, 'wav');
    expect(await voice.source.readAsBytes(), wav);
    expect(conversions, 0);
    await voice.dispose();
    final silkAdapter = _VoiceAdapter(
      Uint8List.fromList('#!SILK_V3'.codeUnits),
    );
    final original =
        await VoiceAttachmentService(
          dio: Dio()..httpClientAdapter = silkAdapter,
        ).prepare(
          const ReceivedAttachment(
            url: 'https://qq.com/original.silk',
            contentType: 'voice',
          ),
          CancelToken(),
        );
    expect(original.extension, 'silk');
    expect(await original.source.readAsBytes(), '#!SILK_V3'.codeUnits);
    await original.dispose();
  });

  testWidgets('语音界面仅提供官方 WAV 下载，不显示转码入口', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VoiceAttachment(
            attachment: ReceivedAttachment(
              url: 'https://qq.com/source.silk',
              voiceWavUrl: 'https://qq.com/source.wav',
              contentType: 'voice',
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('下载官方 WAV'), findsOneWidget);
    expect(find.textContaining('M4A'), findsNothing);
    expect(find.byTooltip('语音下载选项'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('搜索覆盖全部本地消息、嵌套引用，按会话类型筛选且不会串机器人', () async {
    final storage = MemoryStorage(config: validConfig());
    final bot = BotClient(storage, apiService: RecordingApi());
    addTearDown(bot.dispose);
    final firstApp = bot.config.appId;
    await bot.addSession('g', name: '仅会话名称', isGroup: true);
    await bot.addSession('u', name: '私聊', isGroup: false);
    for (var i = 0; i < 705; i++) {
      await storage.saveMessage(
        MessageModel(
          id: 'record-$i',
          sessionId: 'g',
          senderId: 'member',
          senderName: '成员',
          content: i == 0 ? '很早的独有内容' : '普通记录 $i',
          messageType: 0,
          timestamp: DateTime(2026, 10, 1).add(Duration(minutes: i)),
        ),
      );
    }
    final nested = MessageModel(
      id: 'nested',
      sessionId: 'g',
      senderId: 'member',
      senderName: '成员',
      content: '',
      messageType: 0,
      timestamp: DateTime(2026, 10, 21),
      extra: {
        'message_type': 103,
        'msg_elements': [
          {'content': '前文' * 100 + '需要搜索的引用内容'},
        ],
      },
    );
    await storage.saveMessage(nested);
    await storage.saveMessage(
      MessageModel(
        id: 'private',
        sessionId: 'u',
        senderId: 'u',
        senderName: '用户',
        content: '需要搜索的引用内容',
        messageType: 0,
        timestamp: DateTime(2026, 10, 21, 1),
      ),
    );
    await storage.saveMessage(
      MessageModel(
        id: 'recalled',
        sessionId: 'g',
        senderId: 'member',
        senderName: '成员',
        content: '已撤回独有正文',
        messageType: 0,
        timestamp: DateTime.now(),
        isRecalled: true,
      ),
    );
    expect(bot.searchChatHistory('很早的独有内容').single.id, 'record-0');
    expect(bot.searchChatHistory('需要搜索的引用内容').map((m) => m.id), [
      'private',
      'nested',
    ]);
    expect(
      bot.searchChatHistory('需要搜索的引用内容', sessionType: 1).single.id,
      'nested',
    );
    expect(
      bot.searchChatHistory('需要搜索的引用内容', sessionType: 0).single.id,
      'private',
    );
    expect(historyMatchSnippet(nested, '需要搜索'), contains('需要搜索'));
    expect(bot.searchChatHistory('仅会话名称'), isEmpty);
    expect(bot.searchChatHistory('已撤回独有正文'), isEmpty);
    expect(bot.searchChatHistory('  '), isEmpty);
    await bot.updateConfig(validConfig()..appId = 'other-bot');
    await bot.addSession('g', isGroup: true);
    expect(bot.searchChatHistory('很早的独有内容'), isEmpty);
    await bot.switchBot(firstApp);
    expect(bot.searchChatHistory('很早的独有内容').single.id, 'record-0');
  });

  for (final width in [320.0, 390.0, 1024.0]) {
    testWidgets('会话列表搜索消息并定位到第 75 条之前的旧记录 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage(config: validConfig());
      final bot = BotClient(storage, apiService: RecordingApi());
      final plugins = TestPluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await bot.addSession('g', name: '历史群', isGroup: true);
      for (var i = 0; i < 75; i++) {
        await storage.saveMessage(
          MessageModel(
            id: 'm$i',
            sessionId: 'g',
            senderId: 'member',
            senderName: '小明',
            content: i == 0 ? '旧消息里的唯一关键词' : '普通消息 $i',
            messageType: 0,
            timestamp: DateTime(2026, 10, 20).add(Duration(minutes: i)),
          ),
        );
      }
      await tester.pumpWidget(appShell(storage, bot, plugins));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('chat-history-search'));
      expect(find.widgetWithText(TextField, '搜索会话'), findsNothing);
      await tester.enterText(search, '唯一关键词');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('1 条本地聊天记录'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-hit-g-m0')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryScreen), findsOneWidget);
      expect(find.byType(MessageBubble), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MessageBubble),
          matching: find.text('旧消息里的唯一关键词'),
        ),
        findsOneWidget,
      );
      expect(find.text('已定位消息 · 查看更新的记录'), findsOneWidget);
      await tester.tap(find.text('已定位消息 · 查看更新的记录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('m74')), findsOneWidget);
      await tester.tap(find.byTooltip('返回原聊天'));
      await tester.pumpAndSettle();
      if (width < 700) {
        await tester.tap(find.byTooltip('返回会话列表'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('清除聊天记录搜索'));
      await tester.pumpAndSettle();
      expect(find.text('1 条本地聊天记录'), findsNothing);
      expect(find.text('历史群'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
