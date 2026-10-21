import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/ui/screens/chat_history_screen.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/markdown_workbench.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/utils/message_history.dart';
import 'package:qq_bot_manager/utils/voice_file.dart';
import 'package:qq_bot_manager/utils/release_notes.dart';
import '../server/src/voice_export.dart';
import 'connection_ui_test.dart' show captureUi;
import 'mobile_and_group_commands_test.dart' show appShell;
import 'group_management_test.dart' show GroupFixtureApi;
import 'support/fakes.dart';

Uint8List pcmFixture({int rate = 16000, int channels = 1, int frames = 160}) {
  final bytes = Uint8List(44 + frames * channels * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int at, String text) =>
      bytes.setRange(at, at + text.length, text.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * channels * 2, Endian.little);
  for (var i = 0; i < frames * channels; i++) {
    data.setInt16(44 + i * 2, i.isEven ? 8000 : -8000, Endian.little);
  }
  return bytes;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (Platform.environment['QQM_CAPTURE_UI'] == '1' && Platform.isWindows) {
      for (final family in [
        'Microsoft YaHei',
        'Ahem',
        'Roboto',
        'CupertinoSystemDisplay',
        'CupertinoSystemText',
        'Consolas',
      ]) {
        await (FontLoader(family)..addFont(
              File(
                'C:/Windows/Fonts/msyh.ttc',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  test('按真实音频头识别 WAV 和原文件，不把 SILK 或错误页改成 WAV', () {
    for (final rate in [8000, 16000, 24000, 32000, 44100, 48000]) {
      expect(voiceFileExtension(pcmFixture(rate: rate)), 'wav');
    }
    expect(
      voiceFileExtension(Uint8List.fromList('#!SILK_V3'.codeUnits)),
      'silk',
    );
    expect(
      voiceFileExtension(Uint8List.fromList('<html>failed'.codeUnits)),
      'bin',
    );
  });

  test('Linux 下载严格限制官方媒体域名，不允许跨站凭据或任意端口', () {
    expect(
      allowedVoiceUri(Uri.parse('https://multimedia.nt.qq.com.cn/file')),
      isTrue,
    );
    for (final url in [
      'http://multimedia.nt.qq.com.cn/file',
      'https://qq.com.evil.invalid/file',
      'https://127.0.0.1/file',
      'https://qq.com:8443/file',
      'https://secret@qq.com/file',
    ]) {
      expect(allowedVoiceUri(Uri.parse(url)), isFalse);
    }
  });

  test('应用内说明最多三条短摘要，下载链接和技术清单不占据弹窗', () {
    final notes = conciseReleaseNotes(
      '# 1.4.0\n\n- 修复一些 bug～\n- 添加新功能\n- 优化界面间距\n- 第四条不会显示\n下载：https://example.com/long.apk\nSHA256: 012345',
    );
    expect(notes, ['修复一些 bug～', '添加新功能', '优化界面间距']);
    expect(conciseReleaseNotes(''), ['修复一些问题，优化使用体验。']);
    expect(
      conciseReleaseNotes('很长' * 200).single.runes.length,
      lessThanOrEqualTo(82),
    );
  });

  test('搜索能覆盖嵌套引用、卡片和语音转写，撤回不泄露旧正文', () {
    final message = incoming('quoted').copyWith(
      extra: {
        'message_type': 103,
        'msg_elements': [
          {
            'content': '嵌套消息关键字',
            'attachments': [
              {
                'content_type': 'voice',
                'voice_wav_url': 'https://qq.com/test.wav',
                'asr_refer_text': '语音识别正文',
              },
            ],
          },
          {
            'ark_data': {
              'ark_name': '小程序',
              'fields': {'title': '卡片标题'},
            },
          },
        ],
      },
    );
    expect(historyMessageText(message), contains('嵌套消息关键字'));
    expect(historyMessageText(message), contains('语音识别正文'));
    expect(historyMessageText(message), contains('卡片标题'));
    expect(matchesHistoryFilter(message, HistoryFilter.voice), isTrue);
    expect(
      historyMessageText(message.copyWith(isRecalled: true)),
      isNot(contains('关键字')),
    );
    expect(
      matchesHistoryFilter(
        message.copyWith(isRecalled: true),
        HistoryFilter.voice,
      ),
      isFalse,
    );
  });

  test('机器人名称缓存跟随 AppID，切换及修改凭据不串号或丢失名称', () async {
    final storage = MemoryStorage(config: validConfig());
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: RecordingApi(),
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    final firstId = bot.config.appId;
    gateway.onReady?.call({
      'user': {'id': 'bot-one', 'username': '第一个机器人'},
    });
    await bot.updateConfig(validConfig()..appId = 'second');
    gateway.onReady?.call({
      'user': {'id': 'bot-two', 'username': '第二个机器人'},
    });
    await bot.updateConfig(validConfig()..appId = 'second');
    await bot.switchBot(firstId);
    expect(bot.botDisplayName, '第一个机器人');
    expect(
      bot.botProfiles.firstWhere((p) => p.appId == 'second').displayName,
      '第二个机器人',
    );
    await bot.updateConfig(validConfig()..clientSecret = 'changed-fixture');
    expect(bot.botDisplayName, '第一个机器人');
  });

  testWidgets('@全体只能经 Markdown 发送，取消确认保留草稿，不伪造权限通过', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            isGroup: true,
            onSendText: (_) async =>
                throw StateError('must not use plain text'),
            onSendMarkdown:
                (text, {useTemplate, templateId, templateParams}) async {
                  sent = text;
                  return true;
                },
            onSendImage: (_) async => true,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('@ 全体成员'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownWorkbench), findsOneWidget);
    await tester.tap(find.text('发送 Markdown'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdown-editor')))
          .controller!
          .text,
      contains('<qqbot-at-everyone />'),
    );
    await tester.tap(find.text('发送 Markdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(sent, '<qqbot-at-everyone /> ');
    expect(
      const OutgoingMessage(
        content: '<qqbot-at-everyone />',
      ).withMarkdownMentions().type,
      2,
    );
  });

  for (final width in [320.0, 390.0, 800.0, 1024.0, 1280.0]) {
    testWidgets('独立聊天记录、长按 @、切换机器人和窄屏布局 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final api = GroupFixtureApi()..botRole = 'member';
      final bot = BotClient(storage, apiService: api);
      final plugins = TestPluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await bot.addSession('g', name: '测试群', isGroup: true);
      for (var i = 0; i < 75; i++) {
        await storage.saveMessage(
          MessageModel(
            id: 'm$i',
            sessionId: 'g',
            senderId: 'm1',
            senderName: '小明',
            content: i == 0 ? '更早的完整记录' : '测试消息 $i',
            messageType: 0,
            timestamp: DateTime(2026, 10, 20, 10, i),
          ),
        );
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture-ui'),
          child: appShell(storage, bot, plugins),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 700) {
        await tester.tap(find.text('测试群'));
        await tester.pumpAndSettle();
      }
      expect(find.text('机器人详情'), findsNothing);
      expect(find.byTooltip('插件与工具'), findsNothing);
      await tester.tap(find.byTooltip('聊天记录'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryScreen), findsOneWidget);
      await tester.enterText(find.byType(TextField), '更早的完整记录');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(MessageBubble),
          matching: find.text('更早的完整记录'),
        ),
        findsOneWidget,
      );
      await captureUi(tester, 'client140-$width-history');
      await tester.tap(find.byTooltip('返回原聊天'));
      await tester.pumpAndSettle();
      final bubble = find.byType(MessageBubble).first;
      await tester.longPress(
        find.descendant(of: bubble, matching: find.byTooltip('长按管理此群成员')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('@ 此成员'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownWorkbench), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('markdown-editor')))
            .controller!
            .text,
        '<qqbot-at-user id="m1" /> ',
      );
      await captureUi(tester, 'client140-$width-mention');
      expect(api.removals, isEmpty);
      expect(api.mutes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
