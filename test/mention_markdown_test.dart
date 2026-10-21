import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/ui/widgets/markdown_workbench.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'api_service_test.dart' show RecordingAdapter;
import 'support/ui_actions.dart';

void main() {
  test('全体标签走 Markdown，平台拒绝时保留明确的无权限说明', () async {
    final adapter = RecordingAdapter()
      ..status = 403
      ..response = {'message': 'permission denied'};
    final api = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );
    final result = await api.sendQQMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture',
      targetId: 'group',
      isGroup: true,
      content: '<qqbot-at-everyone />',
    );
    expect(adapter.requests.single.data['msg_type'], 2);
    expect(
      adapter.requests.single.data['markdown']['content'],
      '<qqbot-at-everyone />',
    );
    expect(result.isSuccess, isFalse);
    expect(result.error, contains('无权限'));
  });
  testWidgets('小屏长昵称和长 OpenID 预览可换行，不越出编辑器', (tester) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final id = 'A' * 32;
    const name = '这是一个比较长的群成员昵称';
    final controller = TextEditingController(
      text: '<qqbot-at-user id="$id" />',
    );
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownWorkbench(
            controller: controller,
            focusNode: focus,
            sending: false,
            mentionNames: {id: name},
            onSend: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    final label = find.text('@$name（$id）');
    expect(label, findsOneWidget);
    expect(tester.getRect(label).right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('实时预览显示 @ 昵称和 OpenID，代码和发送源码不变 $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const tag = '<qqbot-at-user id="member-1" />';
      const source = '你好 $tag\n\n`$tag`\n\n```text\n$tag\n```';
      final controller = TextEditingController(text: source);
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      String? sent;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MarkdownWorkbench(
                controller: controller,
                focusNode: focus,
                mentionNames: const {'member-1': '小明'},
                sending: false,
                onSend: () => sent = controller.text,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 620) {
        await tester.tap(find.text('预览'));
        await tester.pumpAndSettle();
      }
      expect(find.text('@小明（member-1）'), findsOneWidget);
      expect(
        tester
            .widget<Markdown>(
              find.byKey(const ValueKey('markdown-live-preview')),
            )
            .data,
        source,
      );
      expect(controller.text, source);
      await tester.tap(find.text('发送 Markdown'));
      await tester.pumpAndSettle();
      expect(sent, source);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('昵称不作为 Markdown 解析，未知成员回退且名称更新会刷新预览', (tester) async {
    final controller = TextEditingController(
      text: '<qqbot-at-user id="member-1" /> <qqbot-at-user id="unknown" />',
    );
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    Future<void> show(String name) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownWorkbench(
              controller: controller,
              focusNode: focus,
              sending: false,
              mentionNames: {'member-1': name},
              onSend: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('[链接](https://evil.invalid)');
    expect(find.text('@[链接](https://evil.invalid)（member-1）'), findsOneWidget);
    expect(find.text('@群成员（unknown）'), findsOneWidget);
    await show('新昵称');
    expect(find.text('@新昵称（member-1）'), findsOneWidget);
    expect(
      controller.text,
      '<qqbot-at-user id="member-1" /> <qqbot-at-user id="unknown" />',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('选择 @ 自动转 Markdown，实际发送标签而不是预览昵称', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            isGroup: true,
            mentionCandidates: const {'member-1': '小明'},
            onSendText: (_) async => throw StateError('@ 不应发文本'),
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
    await tester.enterText(find.byType(TextField), '你好 ');
    await revealComposerTools(tester);
    await tester.tap(find.byTooltip('@ 群成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownWorkbench), findsOneWidget);
    expect(find.byKey(const ValueKey('markdown-editor')), findsOneWidget);
    await tester.tap(find.text('发送 Markdown'));
    await tester.pumpAndSettle();
    expect(sent, '你好 <qqbot-at-user id="member-1" /> ');
    expect(sent, isNot(contains('小明')));
    expect(tester.takeException(), isNull);
  });

  test('纯文本 API 和配置消息都将官方 @ 标签转为 Markdown，不发送 type 0', () async {
    final adapter = RecordingAdapter();
    final api = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );
    const tag = '<qqbot-at-user id="member-1" />';
    await api.sendQQMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture',
      targetId: 'g',
      content: tag,
      isGroup: true,
      msgId: 'source',
      msgSeq: 2,
    );
    await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture',
      targetId: 'g',
      message: const OutgoingMessage(content: tag),
      isGroup: true,
      msgId: 'source',
      msgSeq: 3,
    );
    for (final request in adapter.requests) {
      expect(request.data['msg_type'], 2);
      expect(request.data['markdown']['content'], tag);
      expect((request.data as Map).containsKey('content'), false);
    }
    expect(adapter.requests.length, 2);
    expect(adapter.requests.first.data['msg_seq'], 2);
    expect(adapter.requests.last.data['msg_seq'], 3);
    expect(
      const OutgoingMessage(
        type: 7,
        content: tag,
        mediaSource: 'https://example.com/image.png',
      ).validate(isGroup: true),
      contains('Markdown'),
    );
  });
}
