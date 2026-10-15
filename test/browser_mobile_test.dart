import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/ui/screens/browser_screen.dart';
import 'package:qq_bot_manager/utils/browser_policy.dart';

void main() {
  const desktopAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0';

  test('Windows 手机标识保留实际引擎版本，不篡改网页地址', () {
    final agent = windowsMobileUserAgent(desktopAgent);
    expect(agent, contains('Android'));
    expect(agent, contains('Mobile Safari/'));
    expect(agent, contains('Chrome/142.0.0.0'));
    expect(agent, isNot(contains('Windows NT')));
    expect(agent, isNot(contains('Edg/')));
    expect(windowsMobileUserAgent(''), contains('Mobile Safari/'));
    const url = 'https://example.com/p?a=1&signature=a%2Bb#section';
    expect(browserUri(url).toString(), url);
  });

  test('默认移动内容模式覆盖所有平台，切换电脑版保留安全限制', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      final mobile = browserSettings(
        platform: platform,
        desktopUserAgent: desktopAgent,
      );
      final desktop = browserSettings(
        platform: platform,
        mobile: false,
        desktopUserAgent: desktopAgent,
      );
      expect(mobile.preferredContentMode, UserPreferredContentMode.MOBILE);
      expect(desktop.preferredContentMode, UserPreferredContentMode.DESKTOP);
      expect(mobile.useWideViewPort, isFalse);
      expect(desktop.useWideViewPort, isTrue);
      expect(
        mobile.userAgent,
        platform == TargetPlatform.windows
            ? windowsMobileUserAgent(desktopAgent)
            : isNull,
      );
      expect(
        desktop.userAgent,
        platform == TargetPlatform.windows ? desktopAgent : isNull,
      );
      for (final settings in [mobile, desktop]) {
        expect(settings.allowFileAccess, isFalse);
        expect(settings.allowContentAccess, isFalse);
        expect(settings.allowFileAccessFromFileURLs, isFalse);
        expect(settings.allowUniversalAccessFromFileURLs, isFalse);
        expect(settings.javaScriptCanOpenWindowsAutomatically, isFalse);
        expect(settings.useShouldOverrideUrlLoading, isTrue);
        expect(settings.supportMultipleWindows, isTrue);
      }
    }
  });

  for (final (platform, width) in [
    (TargetPlatform.android, 320.0),
    (TargetPlatform.android, 390.0),
    (TargetPlatform.iOS, 390.0),
    (TargetPlatform.windows, 1280.0),
    (TargetPlatform.macOS, 1280.0),
  ]) {
    testWidgets('${platform.name} $width 浏览页默认手机版，切换不新开路由', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserScreen(uri: Uri.parse('https://example.com/page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('手机版'), findsOneWidget);
      final viewport = find.byKey(const ValueKey('browser-viewport'));
      expect(tester.getSize(viewport).width, width > 430 ? 430 : width);
      await tester.tap(find.byTooltip('切换为电脑版'));
      await tester.pumpAndSettle();
      expect(find.text('电脑版'), findsOneWidget);
      expect(tester.getSize(viewport).width, width);
      expect(find.byType(BrowserScreen), findsOneWidget);
      await tester.tap(find.byTooltip('切换为手机版'));
      await tester.pumpAndSettle();
      expect(find.text('手机版'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
