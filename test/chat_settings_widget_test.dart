import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/message_settings_dialog.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> tab(WidgetTester tester, String title) async {
  await tester.tap(find.widgetWithText(Tab, title));
  await tester.pumpAndSettle();
}

Future<void> composer(
  WidgetTester tester,
  Future<bool> Function(OutgoingMessage) send,
) async {
  tester.view.physicalSize = const Size(960, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ChatInput(
            isGroup: true,
            onSendText: (_) async => true,
            onSendMarkdown:
                (_, {useTemplate, templateId, templateParams}) async => true,
            onSendImage: (_) async => true,
            onSendConfigured: send,
            previewConfigured: (request) => request.toPayload(),
            latestEventId: 'recent-event',
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('手动指定普通文本后，Markdown 代码也按文本原样发送', (tester) async {
    OutgoingMessage? sent;
    await composer(tester, (request) async {
      sent = request;
      return true;
    });
    const code = '```dart\nvoid main() {}\n```';
    await tester.enterText(find.byType(TextField), code);
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通文本').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(sent?.type, 0);
    expect(sent?.content, code);
  });

  testWidgets('空按钮模板在设置面板内显示中文错误并保留草稿', (tester) async {
    await composer(tester, (_) async => true);
    await tester.enterText(find.byType(TextField), '草稿正文');
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tab(tester, '按钮键盘');
    await tester.tap(find.byKey(const ValueKey('keyboard-mode-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用按钮模板').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用设置'));
    await tester.pump();
    expect(find.text('请填写按钮模板 ID'), findsOneWidget);
    expect(find.byType(MessageSettingsDialog), findsOneWidget);
    await tester.tap(find.byTooltip('关闭消息设置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '草稿正文',
    );
  });

  testWidgets('聊天框设置按钮模板后直接发送 Markdown，应用和预览都不发送', (tester) async {
    OutgoingMessage? sent;
    await composer(tester, (request) async {
      sent = request;
      return true;
    });
    await tester.enterText(find.byType(TextField), '今日签到成功');
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tab(tester, '按钮键盘');
    await tester.tap(find.byKey(const ValueKey('keyboard-mode-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用按钮模板').last);
    await tester.pumpAndSettle();
    await tester.enterText(field('按钮模板 ID'), 'keyboard-123');
    await tab(tester, '请求预览');
    await tester.tap(find.text('刷新预览'));
    await tester.pump();
    expect(find.textContaining('"keyboard"'), findsOneWidget);
    expect(sent, isNull);
    await tester.tap(find.text('应用设置'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageSettingsDialog), findsNothing);
    expect(sent, isNull);
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(sent?.type, 2);
    expect(sent?.content, '今日签到成功');
    expect(sent?.options.keyboard?.templateId, 'keyboard-123');
  });

  testWidgets('可视化自定义按钮，群聊专用限制清晰，保存后直接随正文发送', (tester) async {
    OutgoingMessage? sent;
    await composer(tester, (request) async {
      sent = request;
      return true;
    });
    await tester.enterText(find.byType(TextField), '选择一个操作');
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tab(tester, '按钮键盘');
    await tester.tap(find.byKey(const ValueKey('keyboard-mode-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义按钮').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加一行按钮'));
    await tester.pump();
    await tester.tap(find.text('添加按钮'));
    await tester.pumpAndSettle();
    await tester.enterText(field('按钮文字（最多 10 字）'), '签到');
    await tester.enterText(field('指令内容'), '/签到');
    final singleChatSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '点击后自动发送（仅单聊）'),
    );
    expect(singleChatSwitch.onChanged, isNull);
    await tester.tap(find.text('保存按钮'));
    await tester.pumpAndSettle();
    expect(find.text('签到'), findsOneWidget);
    await tester.tap(find.text('应用设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    final button = sent!.options.keyboard!.rows.single.single;
    expect(button.label, '签到');
    expect(button.data, '/签到');
    expect(button.enter, isFalse);
    expect(sent!.type, 2);
  });

  testWidgets('富媒体填写 file_info 后无需正文即可从聊天框直接发送', (tester) async {
    OutgoingMessage? sent;
    await composer(tester, (request) async {
      sent = request;
      return true;
    });
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('message-type-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('富媒体：图片 / 视频 / 语音 / 文件').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件').last);
    await tester.pumpAndSettle();
    final info = field('已有 file_info（可选，填写后跳过上传）');
    await tester.ensureVisible(info);
    await tester.enterText(info, 'existing-file-info');
    await tester.tap(find.text('应用设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(sent?.type, 7);
    expect(sent?.mediaFileType, 4);
    expect(sent?.fileInfo, 'existing-file-info');
    expect(sent?.content, isEmpty);
  });

  testWidgets('事件回复可填入最近事件，恢复默认清除配置且不自动发送', (tester) async {
    OutgoingMessage? sent;
    await composer(tester, (request) async {
      sent = request;
      return true;
    });
    await tester.enterText(find.byType(TextField), '响应事件');
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tab(tester, '回复与引用');
    await tester.tap(find.byType(DropdownButtonFormField<ReplyMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('指定事件 ID 回复').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('填入最近可回复事件'));
    await tester.pump();
    expect(
      tester.widget<TextField>(field('可回复的事件 ID（event_id）')).controller!.text,
      'recent-event',
    );
    await tester.tap(find.text('应用设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(sent?.options.eventId, 'recent-event');
    expect(sent?.options.replyMode, ReplyMode.event);
    await tester.tap(find.byTooltip('消息设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送设置：'), findsNothing);
  });
}
