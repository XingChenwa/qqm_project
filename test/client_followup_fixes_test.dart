import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/auxiliary_windows.dart';
import 'package:qq_bot_manager/ui/screens/forwarded_record_screen.dart';
import 'package:qq_bot_manager/ui/screens/browser_screen.dart';
import 'package:qq_bot_manager/ui/themes/app_theme.dart';
import 'package:qq_bot_manager/ui/widgets/chat_timeline.dart';
import 'package:qq_bot_manager/ui/widgets/linkified_text.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/ui/widgets/received_message_view.dart';
import 'package:qq_bot_manager/ui/widgets/message_image.dart';
import 'package:qq_bot_manager/utils/forwarded_text.dart';

const exportedRecord = '''[测试用户的聊天记录]
=== 消息 1 ===
[消息内容] 周末的旅行照片
第二行说明
[发送者] 小明
[时间] 2026-10-21T09:00:00+08:00
[附件1] 类型:图片 文件名:photo-one.png 尺寸:1200x800 大小:128KB URL:https://example.com/photo-one.png?key=one==
[附件2] 类型:图片 文件名:photo-two.png 尺寸:800x1000 大小:256KB URL:https://example.com/photo-two.png
=== 消息 2 ===
[消息内容] 风景真不错！
[发送者] 小红
''';

class FixtureImageHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..idleTimeout = Duration.zero;
}

class RecordingWindows extends AuxiliaryWindows {
  final requests = <({String kind, Map<String, dynamic> data})>[];
  RecordingWindows() : super(supported: true, executable: 'fixture.exe');
  @override
  Future<void> open(String kind, Map<String, dynamic> data) async {
    requests.add((kind: kind, data: data));
  }
}

Future<void> capture(WidgetTester tester, String name) async {
  if (Platform.environment['QQM_CAPTURE_UI'] != '1') return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture-followup')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = await Directory(
      'build/ui-previews-1.4-followup',
    ).create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  HttpServer? fixtureServer;
  HttpOverrides? originalHttp;
  Directory? imageCacheDirectory;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    originalHttp = HttpOverrides.current;
    HttpOverrides.global = FixtureImageHttp();
    // Native image decoders may retain mapped cache files until the test engine
    // exits on Windows. Keep these non-sensitive fixtures under ignored build/.
    imageCacheDirectory = await Directory(
      'build/test-record-images',
    ).absolute.create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => imageCacheDirectory!.path,
        );
    // macOS/iOS widget tests have no registered sqflite native plugin. Use the
    // same explicit JSON fixture repository on every host, without changing the
    // application's platform-native cache or weakening image-rendering checks.
    CachedNetworkImageProvider.defaultCacheManager = CacheManager(
      Config(
        'record-fixtures',
        repo: JsonCacheInfoRepository.withFile(
          File('${imageCacheDirectory!.path}/record-fixtures.json'),
        ),
      ),
    );
    fixtureServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final photo = img.Image(width: 640, height: 400);
    img.fill(photo, color: img.ColorRgb8(214, 231, 246));
    img.drawString(
      photo,
      'PHOTO',
      font: img.arial48,
      x: 230,
      y: 175,
      color: img.ColorRgb8(49, 91, 141),
    );
    final png = img.encodePng(photo);
    fixtureServer!.listen((request) async {
      // Deliberately slower than the old 600ms polling budget, so this test
      // proves that it awaits real decoding rather than depending on host speed.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.persistentConnection = false;
      request.response.add(png);
      await request.response.close();
    });
    if (Platform.environment['QQM_CAPTURE_UI'] == '1' && Platform.isWindows) {
      for (final family in [
        'Microsoft YaHei',
        'Ahem',
        'Roboto',
        'CupertinoSystemDisplay',
        'CupertinoSystemText',
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
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => imageCacheDirectory!.path,
        );
  });
  tearDownAll(() async {
    await fixtureServer?.close(force: true);
    imageCache.clear();
    imageCache.clearLiveImages();
    await CachedNetworkImageProvider.defaultCacheManager.dispose();
    HttpOverrides.global = originalHttp;
  });

  test('QQ 文本化转发记录恢复发送者、正文、图片和原始 URL 参数', () {
    final parsed = parseForwardedRecordText(exportedRecord)!;
    final body = ReceivedMessageBody.fromMap({
      'message_type': 103,
      'msg_elements': [
        {'content': exportedRecord},
      ],
    });
    expect(body.isRecord, isTrue);
    final record = body.elements.single;
    expect(record.recordTitle, '测试用户的聊天记录');
    expect(record.elements.length, 2);
    expect(record.elements.first.text, '周末的旅行照片\n第二行说明');
    expect(record.elements.first.authorName, '小明');
    expect(record.elements.first.attachments.length, 2);
    expect(record.elements.first.attachments.first.url, endsWith('?key=one=='));
    expect(record.elements.first.attachments.first.size, 128 * 1024);
    expect(record.elements.first.attachments.first.width, 1200);
    expect(record.elements.first.timestamp, isNotNull);
    expect(parsed['message_type'], 102);
    expect(
      ReceivedMessageBody.fromMap(record.toDisplayMap()).elements.length,
      2,
    );
    for (final text in [
      '普通 URL: https://example.com/image.png',
      '=== 消息 1 ===\n随便聊聊',
      '普通的聊天消息',
    ]) {
      expect(parseForwardedRecordText(text), isNull);
    }
  });

  for (final source in [
    '<qqbot-at-user id="member" />',
    '<qqbot-at-everyone />',
  ]) {
    testWidgets('已发送 $source 可见且与蓝色气泡保持对比', (tester) async {
      final message = MessageModel(
        id: 'sent',
        sessionId: 'g',
        senderId: 'bot',
        senderName: '机器人',
        content: '[Markdown]',
        messageType: 2,
        timestamp: DateTime.now(),
        isFromBot: true,
        markdownContent: source,
        extra: {
          'mentions': [
            {'id': 'member', 'username': '小明'},
          ],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(body: MessageBubble(message: message)),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.text(source.contains('everyone') ? '@全体成员' : '@小明');
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).style!.color, Colors.white);
      expect(find.byType(EditableText), findsNothing);
      expect(message.markdownContent, source);
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('长按并复制消息不会移动聊天阅读位置 ${platform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final scroll = ScrollController(keepScrollOffset: false);
      addTearDown(scroll.dispose);
      final messages = List.generate(
        60,
        (i) => MessageModel(
          id: 'm$i',
          sessionId: 'g',
          senderId: 'u',
          senderName: '用户',
          content: '消息 $i 这是可复制的文字',
          messageType: 0,
          timestamp: DateTime.now(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 600,
              child: ChatTimeline(
                sessionId: 'g',
                messages: messages,
                controller: scroll,
                openRevision: 0,
                itemBuilder: (_, i) => SizedBox(
                  height: 100,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: LinkifiedText(
                      messages[i].content,
                      key: ValueKey('copy-$i'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(-300);
      await tester.pumpAndSettle();
      final before = scroll.offset;
      final visible = find.byType(LinkifiedText).hitTestable().last;
      final text = find.byKey(tester.widget<LinkifiedText>(visible).key!);
      final location = tester.getTopLeft(text);
      await tester.longPress(text);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(before, .01));
      expect(tester.getTopLeft(text).dy, closeTo(location.dy, .01));
      if (find.text('Copy').evaluate().isNotEmpty) {
        await tester.tap(find.text('Copy').first);
        await tester.pumpAndSettle();
      }
      expect(scroll.offset, closeTo(before, .01));
      expect(find.byType(EditableText), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final width in [320.0, 390.0, 1100.0]) {
    testWidgets('转发记录以卡片打开独立页面，正文和图片不展示原始附件清单 $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final body = ReceivedMessageBody.fromMap({
        'content': exportedRecord.replaceAll(
          'https://example.com',
          'http://127.0.0.1:${fixtureServer!.port}',
        ),
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture-followup'),
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: ReceivedMessageView(body: body),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('forwarded-record-card')),
        findsOneWidget,
      );
      expect(find.textContaining('URL:'), findsNothing);
      // Real HTTP/file/codec work must finish on the real event loop before
      // the record starts loading under the widget test's fake clock. Otherwise
      // an image request started in fake async can deadlock a real-async wait.
      final imageErrors = <Object>[];
      final recordContext = tester.element(find.byType(Scaffold));
      final imageSources = <String>{};
      final pendingBodies = [body];
      while (pendingBodies.isNotEmpty) {
        final entry = pendingBodies.removeLast();
        imageSources.addAll(
          entry.attachments.where((a) => a.isImage).map((a) => a.url),
        );
        pendingBodies.addAll(entry.elements);
      }
      await tester.runAsync(
        () => Future.wait([
          for (final source in imageSources)
            precacheImage(
              ResizeImage.resizeIfNeeded(
                960,
                null,
                CachedNetworkImageProvider(source),
              ),
              recordContext,
              onError: (error, stack) => imageErrors.add(error.runtimeType),
            ),
        ]).timeout(const Duration(seconds: 20)),
      );
      expect(imageSources, hasLength(2));
      expect(imageErrors, isEmpty);
      await tester.tap(find.byKey(const ValueKey('forwarded-record-card')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .every((image) => image.image != null),
        isTrue,
      );
      expect(find.byType(ForwardedRecordScreen), findsOneWidget);
      expect(find.text('周末的旅行照片\n第二行说明'), findsOneWidget);
      expect(find.byType(MessageImage), findsWidgets);
      expect(find.textContaining('URL:'), findsNothing);
      expect(find.textContaining('文件名:'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, 'forwarded-record-${width.toInt()}');
      await tester.tap(find.byTooltip('返回原聊天'));
      await tester.pumpAndSettle();
      expect(find.byType(ForwardedRecordScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
      // Let the cache's documented one-shot maintenance/index-write timers
      // finish before the fake-clock widget test is torn down.
      await tester.pump(const Duration(seconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(seconds: 5));
    });
  }

  test('桌面独立窗口通过一次性快照启动，不继承令牌，读取后删除快照', () async {
    final directory = await Directory.systemTemp.createTemp('qqm-aux-test-');
    addTearDown(() => directory.delete(recursive: true));
    Map<String, String>? env;
    final service = AuxiliaryWindows(
      supported: true,
      supportDirectory: () async => directory,
      launcher: (exe, environment) async {
        env = environment;
      },
      executable: 'fixture.exe',
    );
    await service.open('record', {
      'body': ReceivedMessageBody.fromMap({
        'content': exportedRecord,
      }).toDisplayMap(),
    });
    expect(
      env!.keys.any(
        (key) => RegExp(r'TOKEN|SECRET|PASSWORD|PRIVATE_KEY').hasMatch(key),
      ),
      isFalse,
    );
    final file = File(env![AuxiliaryWindows.requestVariable]!);
    expect(await file.exists(), isTrue);
    final data = await service.consume(file.path);
    expect(data['kind'], 'record');
    expect(await file.exists(), isFalse);
    final outsider = File('${directory.path}/outside.json');
    await outsider.writeAsString(jsonEncode({'schema': 1, 'kind': 'record'}));
    await expectLater(service.consume(outsider.path), throwsFormatException);
    expect(await outsider.exists(), isTrue);
    await expectLater(service.open('shell', {}), throwsFormatException);
  });

  testWidgets('桌面聊天记录和网页交给独立窗口，不替换主窗口页面', (tester) async {
    final windows = RecordingWindows();
    await tester.pumpWidget(
      Provider<AuxiliaryWindows>.value(
        value: windows,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  const Text('主聊天窗口'),
                  TextButton(
                    onPressed: () => openForwardedRecord(
                      context,
                      ReceivedMessageBody.fromMap({'content': exportedRecord}),
                    ),
                    child: const Text('记录'),
                  ),
                  TextButton(
                    onPressed: () =>
                        openInAppBrowser(context, 'https://example.com'),
                    child: const Text('网页'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('网页'));
    await tester.pumpAndSettle();
    expect(windows.requests.map((r) => r.kind), ['record', 'browser']);
    expect(find.text('主聊天窗口'), findsOneWidget);
    expect(find.byType(BrowserScreen), findsNothing);
    expect(find.byType(ForwardedRecordScreen), findsNothing);
    expect(windows.requests.last.data['url'], 'https://example.com');
  });
}
