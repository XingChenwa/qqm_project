import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/ui/widgets/app_dialogs.dart';

void main() {
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('操作提示在 $width 宽使用弹窗并合并重复提示', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late BuildContext target;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                target = context;
                return const Text('聊天保持原位');
              },
            ),
          ),
        ),
      );
      final first = AppDialogs.show(target, '配置已保存');
      final duplicate = AppDialogs.show(target, '配置已保存');
      final second = AppDialogs.show(target, '文件已导出');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('配置已保存'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await first;
      await duplicate;
      expect(find.text('文件已导出'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await second;
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('聊天保持原位'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('离开原页面后队列仍由应用 Navigator 安全显示', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    final temporary = MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () {
            AppDialogs.show(context, '第一条');
            AppDialogs.show(context, '第二条');
            Navigator.pop(context);
          },
          child: const Text('返回'),
        ),
      ),
    );
    navigator.currentState!.push(temporary);
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('第一条'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('第二条'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
