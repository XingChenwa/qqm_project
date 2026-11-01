import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/ui/editor.dart';

void main() {
  testWidgets('模型编辑测试持续等待时可以手动停止并返回编辑', (tester) async {
    final result = Completer<String>();
    var cancels = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => editAgent(
                context,
                title: '模型配置',
                initial: {},
                fields: [],
                save: (_) async {},
                actionLabel: '测试模型',
                action: (_) => result.future,
                cancelAction: () {
                  cancels++;
                  result.completeError(const AgentException('任务已停止。'));
                },
              ),
              child: const Text('配置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试模型'));
    await tester.pump();
    expect(find.text('停止测试'), findsOneWidget);
    await tester.tap(find.text('停止测试'));
    await tester.pumpAndSettle();
    expect(cancels, 1);
    expect(find.text('任务已停止。'), findsOneWidget);
    expect(find.text('停止测试'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('模型配置'), findsNothing);
  });
}
