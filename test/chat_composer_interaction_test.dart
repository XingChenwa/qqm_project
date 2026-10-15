import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';

Future<void> pumpComposer(
  WidgetTester tester, {
  required Future<bool> Function(String) send,
  bool markdown = false,
  bool configured = false,
  VoidCallback? onMessageSent,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ChatInput(
            onSendText: send,
            onSendMarkdown: (text, {useTemplate, templateId, templateParams}) =>
                send(text),
            onSendImage: send,
            onSlashCommand: (command, args) => send('command:$command'),
            onSendConfigured: configured
                ? (message) => send('configured:${message.content}')
                : null,
            replyTo: configured
                ? MessageModel(
                    id: 'reply',
                    sessionId: 'test',
                    senderId: 'bot',
                    senderName: '机器人',
                    content: '被引用的消息',
                    messageType: 0,
                    timestamp: DateTime.now(),
                    isFromBot: true,
                  )
                : null,
            onMessageSent: onMessageSent,
          ),
        ),
      ),
    ),
  );
  if (markdown) {
    await tester.tap(find.byTooltip('自定义 Markdown'));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final markdown in [false, true]) {
    final mode = markdown ? 'Markdown' : '普通文本';

    testWidgets('$mode：Ctrl+回车在光标或选区换行，回车原样发送', (tester) async {
      final sent = <String>[];
      var success = 0;
      await pumpComposer(
        tester,
        markdown: markdown,
        send: (text) async {
          sent.add(text);
          return true;
        },
        onMessageSent: () => success++,
      );
      final editor = find.byType(TextField);
      await tester.enterText(editor, '第一行第二行');
      final controller = tester.widget<TextField>(editor).controller!;
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, '第一行\n第二行');
      expect(controller.selection.baseOffset, 4);
      expect(sent, isEmpty);
      controller.selection = const TextSelection(
        baseOffset: 7,
        extentOffset: 4,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, '第一行\n\n');
      expect(controller.selection.baseOffset, 5);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sent, ['第一行\n\n']);
      expect(success, 1);
      expect(controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode：中文选词回车不误发，小键盘回车可发送', (tester) async {
      final sent = <String>[];
      await pumpComposer(
        tester,
        markdown: markdown,
        send: (text) async {
          sent.add(text);
          return true;
        },
      );
      final editor = find.byType(TextField);
      await tester.showKeyboard(editor);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'nihao',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isEmpty);
      expect(tester.widget<TextField>(editor).controller!.text, 'nihao');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '你好',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pumpAndSettle();
      expect(sent, ['你好']);
    });

    testWidgets('$mode：长按回车和发送中按回车不会重复发送，新草稿不被清空', (tester) async {
      final completion = Completer<bool>();
      var calls = 0;
      var success = 0;
      await pumpComposer(
        tester,
        markdown: markdown,
        send: (_) {
          calls++;
          return completion.future;
        },
        onMessageSent: () => success++,
      );
      final editor = find.byType(TextField);
      await tester.enterText(editor, '正在发送');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 1);
      await tester.enterText(editor, '接着编辑的新草稿');
      completion.complete(true);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '接着编辑的新草稿');
      expect(success, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 2);
      await tester.enterText(editor, '按住期间的新草稿');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 2);
      expect(tester.widget<TextField>(editor).controller!.text, '按住期间的新草稿');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    });

    testWidgets('$mode：手机键盘发送按钮发送后保持编辑焦点', (tester) async {
      var calls = 0;
      await pumpComposer(
        tester,
        markdown: markdown,
        send: (_) async {
          calls++;
          return true;
        },
      );
      final editor = find.byType(TextField);
      await tester.enterText(editor, '手机键盘发送');
      expect(
        tester.widget<TextField>(editor).textInputAction,
        TextInputAction.send,
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
    });

    testWidgets('$mode：发送失败保留草稿，不触发成功定位', (tester) async {
      var success = 0;
      await pumpComposer(
        tester,
        markdown: markdown,
        send: (_) async => false,
        onMessageSent: () => success++,
      );
      final editor = find.byType(TextField);
      await tester.enterText(editor, '不要丢失的草稿');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '不要丢失的草稿');
      expect(success, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final route in ['slash', 'configured', 'image']) {
    testWidgets('$route 发送成功也发出定位信号', (tester) async {
      final sent = <String>[];
      var success = 0;
      await pumpComposer(
        tester,
        configured: route == 'configured',
        send: (text) async {
          sent.add(text);
          return true;
        },
        onMessageSent: () => success++,
      );
      if (route == 'image') {
        await tester.tap(find.byTooltip('发送图片'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('输入图片 URL'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          'https://example.com/test.png',
        );
        await tester.tap(find.widgetWithText(ElevatedButton, '发送'));
      } else {
        await tester.enterText(
          find.byType(TextField),
          route == 'slash' ? '/ping' : '配置正文',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      }
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(success, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
