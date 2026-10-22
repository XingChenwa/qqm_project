import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/ui/widgets/app_logo.dart';
import 'package:qq_bot_manager/ui/widgets/startup_gate.dart';

const _readyApp = MaterialApp(home: Text('测试工作台'));

Future<void> _loadBranding(WidgetTester tester) async {
  await tester.pumpWidget(StartupGate(initialize: (_) async => _readyApp));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('真实加载完成后再展示5秒，加载时间不占用动画时间', (tester) async {
    final result = Completer<Widget>();
    await tester.pumpWidget(
      StartupGate(
        initialize: (report) {
          report('读取本地配置');
          return result.future;
        },
      ),
    );
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('读取本地配置'), findsOneWidget);
    expect(find.byType(AppLogo), findsNothing);
    expect(find.byKey(const ValueKey('startup-skip')), findsNothing);

    result.complete(_readyApp);
    await tester.pump();
    await tester.pump();
    expect(find.byType(AppLogo), findsOneWidget);
    expect(find.text('5s'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4900));
    expect(find.byKey(const ValueKey('startup-branding')), findsOneWidget);
    expect(find.text('测试工作台'), findsNothing);
    expect(find.text('1s'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 110));
    expect(find.text('测试工作台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三组文字分别从左右两侧淡入，到中心后保持清晰显示', (tester) async {
    await _loadBranding(tester);
    await tester.pump(const Duration(milliseconds: 700));

    const groups = [
      'startup-description',
      'startup-star',
      'startup-repository',
    ];
    for (final group in groups) {
      final left = tester.widget<Transform>(
        find.byKey(ValueKey('$group-left-slide')),
      );
      final right = tester.widget<Transform>(
        find.byKey(ValueKey('$group-right-slide')),
      );
      expect(left.transform.storage[12], lessThan(0));
      expect(right.transform.storage[12], greaterThan(0));
      expect(
        left.transform.storage[12],
        closeTo(-right.transform.storage[12], .001),
      );
      expect(
        tester
            .widget<Opacity>(find.byKey(ValueKey('$group-left-opacity')))
            .opacity,
        lessThan(1),
      );
    }

    await tester.pump(const Duration(milliseconds: 1500));
    for (final group in groups) {
      for (final side in ['left', 'right']) {
        expect(
          tester
              .widget<Transform>(find.byKey(ValueKey('$group-$side-slide')))
              .transform
              .storage[12],
          0,
        );
        expect(
          tester
              .widget<Opacity>(find.byKey(ValueKey('$group-$side-opacity')))
              .opacity,
          1,
        );
      }
    }
    final starText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('startup-star-right-slide')),
        matching: find.byType(Text),
      ),
    );
    final star = (starText.textSpan as TextSpan).children!.last as TextSpan;
    expect(star.text, 'Star 谢谢喵。');
    expect(star.style!.fontWeight, FontWeight.w700);
    expect(find.text('进入应用'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
  });

  for (final size in [
    const Size(320, 700),
    const Size(390, 844),
    const Size(1100, 760),
  ]) {
    testWidgets('${size.width.toInt()}宽屏：右上角跳过、文案居中且不溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _loadBranding(tester);
      await tester.pump(const Duration(milliseconds: 2300));
      final skip = tester.getRect(find.byKey(const ValueKey('startup-skip')));
      expect(skip.right, closeTo(size.width - 16, .1));
      expect(skip.top, 12);
      expect(skip.height, greaterThanOrEqualTo(48));

      for (final name in [
        'startup-description',
        'startup-star',
        'startup-repository',
      ]) {
        final left = tester.getRect(find.byKey(ValueKey('$name-left-slide')));
        final right = tester.getRect(find.byKey(ValueKey('$name-right-slide')));
        expect(left.left, greaterThanOrEqualTo(24));
        expect(right.right, lessThanOrEqualTo(size.width - 24));
        expect(
          left.expandToInclude(right).center.dx,
          closeTo(size.width / 2, .1),
        );
        expect(left.top, greaterThan(skip.bottom));
        expect(right.bottom, lessThan(size.height));
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('startup-skip')));
      await tester.pumpAndSettle();
      expect(find.text('测试工作台'), findsOneWidget);
      expect(find.byType(AppLogo), findsNothing);
    });
  }

  testWidgets('小屏放大字体仍可读，跳过按钮始终可点击', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _loadBranding(tester);
    await tester.pump(const Duration(milliseconds: 2300));
    expect(find.text('跨平台中文机器人管理客户端'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pump();
    final skip = tester.getRect(find.byKey(const ValueKey('startup-skip')));
    expect(skip.top, 12);
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(find.text('测试工作台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立子窗口仍然直接进入，不重复等待启动动画', (tester) async {
    await tester.pumpWidget(
      StartupGate(showBranding: false, initialize: (_) async => _readyApp),
    );
    await tester.pump();
    expect(find.text('测试工作台'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-branding')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统减少动态效果时文字直接呈现，仍可跳过或展示满5秒', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _loadBranding(tester);
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('startup-description-left-slide')),
          )
          .transform
          .storage[12],
      0,
    );
    await tester.pump(const Duration(milliseconds: 4900));
    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('测试工作台'), findsNothing);
    await tester.pump(const Duration(milliseconds: 110));
    expect(find.text('测试工作台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
