import 'support/ui_actions.dart';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/app_update_service.dart';
import 'package:qq_bot_manager/services/update_preferences.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/log_panel.dart';
import 'package:qq_bot_manager/ui/widgets/update_panel.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'app_update_test.dart' show UpdateAdapter;
import 'connection_ui_test.dart' show captureUi;
import 'mobile_and_group_commands_test.dart' show appShell;
import 'support/fakes.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (Platform.environment['QQM_CAPTURE_UI'] == '1' && Platform.isWindows) {
      await (FontLoader('Microsoft YaHei')..addFont(
            File(
              'C:/Windows/Fonts/msyh.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('@ 群成员在 $width 宽插入新官方标签，不误发且没有 @ 全体入口', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? sent;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: Center(
              child: ChatInput(
                isGroup: true,
                mentionCandidates: const {'member-1': '离线测试用户'},
                onSendText: (text) async {
                  sent = text;
                  return true;
                },
                onSendMarkdown:
                    (_, {useTemplate, templateId, templateParams}) async =>
                        true,
                onSendImage: (_) async => true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealComposerTools(tester);
      await tester.tap(find.byTooltip('@ 群成员'));
      await tester.pumpAndSettle();
      expect(find.text('离线测试用户'), findsOneWidget);
      expect(sent, isNull);
      await tester.tap(find.text('离线测试用户'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '<qqbot-at-user id="member-1" /> ');
      expect(sent, isNull);
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(sent, '<qqbot-at-user id="member-1" /> ');
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机去重复导航，切换 AppID 清理草稿和会话，$width 宽', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final config = validConfig()
        ..appId = '10001'
        ..clientSecret = '';
      final storage = MemoryStorage(config: config);
      storage.profiles['10002'] = validConfig()
        ..appId = '10002'
        ..clientSecret = '';
      final bot = BotClient(
        storage,
        apiService: RecordingApi(),
        webSocketService: TestGateway(),
      );
      final plugins = PluginManager(storage);
      addTearDown(bot.dispose);
      addTearDown(plugins.dispose);
      await bot.addSession('same-openid', isGroup: true, name: '离线测试群');
      await storage.saveMessage(
        MessageModel(
          id: 'fixture',
          sessionId: 'same-openid',
          senderId: 'bot',
          senderName: '离线测试机器人',
          content: '离线测试数据，没有连接真实机器人',
          messageType: 0,
          timestamp: DateTime.now(),
          isFromBot: true,
          extra: {'localOnly': true},
        ),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture-ui'),
          child: appShell(storage, bot, plugins),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 700) {
        await tester.tap(find.text('离线测试群'));
        await tester.pumpAndSettle();
        expect(find.text('离线测试群'), findsOneWidget);
        expect(find.byType(Drawer), findsNothing);
      }
      await tester.enterText(
        find
            .descendant(
              of: find.byType(ChatInput),
              matching: find.byType(TextField),
            )
            .first,
        'A 机器人未发草稿',
      );
      await captureUi(tester, 'chat-revision-${width.toInt()}');
      await tester.tap(find.byTooltip('切换机器人'));
      await tester.pumpAndSettle();
      await captureUi(tester, 'bot-switch-${width.toInt()}');
      await tester.tap(find.text('AppID · 10002'));
      await tester.pumpAndSettle();
      expect(bot.config.appId, '10002');
      expect(bot.sessions, isEmpty);
      expect(find.text('A 机器人未发草稿'), findsNothing);
      await bot.switchBot('10001');
      await tester.pumpAndSettle();
      if (width < 700) {
        await tester.tap(find.text('离线测试群'));
        await tester.pumpAndSettle();
      }
      final input = tester.widget<TextField>(
        find
            .descendant(
              of: find.byType(ChatInput),
              matching: find.byType(TextField),
            )
            .first,
      );
      expect(input.controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('双线路设置和日志配色 $width 宽正常布局', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final updates = AppUpdateService(
        UpdatePreferences(await SharedPreferences.getInstance()),
        publicKey: 'EmpeSLtZms6Uz7D61o6E3gQzBytIPqsNU+dSq47M9ko=',
        http: Dio()
          ..httpClientAdapter = UpdateAdapter(
            (_) async => ResponseBody.fromString('', 503),
          ),
      );
      addTearDown(updates.dispose);
      updates.nodeStatuses[UpdateNode.github] = const UpdateNodeStatus(
        UpdateNode.github,
        milliseconds: 180,
        build: 19,
        detail: '离线界面测试 · v1.3.8',
      );
      updates.nodeStatuses[UpdateNode.gitcode] = const UpdateNodeStatus(
        UpdateNode.gitcode,
        milliseconds: 45,
        build: 19,
        detail: '离线界面测试 · v1.3.8',
      );
      updates.activeNode = UpdateNode.gitcode;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture-ui'),
          child: ChangeNotifierProvider<AppUpdateService>.value(
            value: updates,
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              debugShowCheckedModeBanner: false,
              home: const Scaffold(body: UpdatePanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自动优选'), findsOneWidget);
      expect(find.text('更新渠道'), findsNothing);
      expect(find.text('正式版'), findsNothing);
      expect(find.text('Beta 测试版'), findsNothing);
      expect(find.text('45 ms'), findsOneWidget);
      await captureUi(tester, 'updates-revision-${width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(
            body: LogPanel(
              logs: [
                '[离线测试] 正在获取网关地址',
                '[离线测试] 连接成功',
                '[离线测试] 警告：正在重连',
                '[离线测试] 发送失败',
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(logSeverity('失败：未能连接成功'), LogSeverity.error);
      expect(logSeverity('警告：重连中'), LogSeverity.warning);
      expect(logSeverity('连接成功'), LogSeverity.success);
      expect(logSeverity('正在连接'), LogSeverity.info);
      expect(tester.takeException(), isNull);
    });
  }
}
