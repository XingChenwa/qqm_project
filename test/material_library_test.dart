import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/media_library.dart';
import 'package:qq_bot_manager/models/media_image.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/material_image_upload.dart';
import 'package:qq_bot_manager/ui/widgets/chat_input.dart';
import 'package:qq_bot_manager/ui/widgets/material_library_sheet.dart';
import 'package:qq_bot_manager/ui/widgets/qq_media_image.dart';

import 'support/fakes.dart';
import 'support/ui_actions.dart';

BotMediaImage fixture(String id, {String preview = ''}) => BotMediaImage(
  id: id,
  reference: 'qqbot-media://image/v1/$id',
  filename: '$id.png',
  previewUrl: preview,
  expiresAt: DateTime(2030),
);

class LibraryApi extends RecordingApi {
  final materialCalls = <String>[];
  List<BotMediaImage> first = [fixture('first')], second = [];
  Completer<ApiResult<BotMediaPage>>? pending;
  String? failure;
  bool repeatCursor = false;
  @override
  Future<ApiResult<BotMediaPage>> listMediaImages({
    required String baseUrl,
    required String accessToken,
    String cursor = '',
  }) async {
    materialCalls.add('list:$accessToken:$cursor');
    if (pending case final deferred?) {
      return deferred.future;
    }
    if (failure case final error?) {
      return ApiResult.failure(error);
    }
    return ApiResult.success(
      BotMediaPage(
        cursor.isEmpty ? first : second,
        repeatCursor || (cursor.isEmpty && second.isNotEmpty) ? 'second' : '',
        first.length + second.length,
      ),
    );
  }

  @override
  Future<ApiResult<BotMediaImage>> uploadMediaImage({
    required String baseUrl,
    required String accessToken,
    required MaterialUploadImage image,
    bool Function()? isCurrent,
    void Function(String stage, double progress)? onProgress,
  }) async {
    materialCalls.add('upload:$accessToken:${image.contentType}');
    onProgress?.call('上传完成', 1);
    return ApiResult.success(fixture('uploaded'));
  }

  @override
  Future<ApiResult<bool>> deleteMediaImage({
    required String baseUrl,
    required String accessToken,
    required String imageId,
  }) async {
    materialCalls.add('delete:$accessToken:$imageId');
    first.removeWhere((i) => i.id == imageId);
    return ApiResult.success(true);
  }
}

void main() {
  test('素材分页、预览解析合并请求；删除后不再存在，原引用不被改写', () async {
    final api = LibraryApi()..second = [fixture('second')];
    final library = MediaLibrary(
      api: api,
      request: <T>(target, action) =>
          action(target.appId, 'https://api.bot.qq.com'),
      appId: () => 'bot-A',
      epoch: () => 0,
      changed: () {},
    );
    final found = await Future.wait([
      library.resolveReference('qqbot-media://image/v1/second'),
      library.resolveReference('qqbot-media://image/v1/first'),
    ]);
    expect(found[0]!.id, 'second');
    expect(found[1]!.id, 'first');
    expect(api.materialCalls, ['list:bot-A:', 'list:bot-A:second']);
    expect(library.total, 2);
    expect(
      await library.resolveReference('qqbot-media://image/v1/missing'),
      isNull,
    );
    expect(api.materialCalls.length, 2);
    expect(await library.delete(found[1]!), isTrue);
    expect(library.images.map((i) => i.id), ['second']);
    expect(found[1]!.markdown, '![图片 #320px #320px](qqbot-media://image/v1/first)');
    library.dispose();
  });

  test('AppID或凭证代次切换，旧列表异步响应不会串进新素材库', () async {
    var appId = 'A', epoch = 0;
    final api = LibraryApi()..pending = Completer();
    final library = MediaLibrary(
      api: api,
      request: <T>(target, action) =>
          action(target.appId, 'https://api.bot.qq.com'),
      appId: () => appId,
      epoch: () => epoch,
      changed: () {},
    );
    final old = library.refresh();
    final deferred = api.pending!;
    appId = 'B';
    epoch++;
    expect(library.images, isEmpty);
    api.pending = null;
    api.first = [fixture('B')];
    await library.refresh();
    deferred.complete(ApiResult.success(BotMediaPage([fixture('A')], '', 1)));
    await old;
    expect(library.images.single.id, 'B');
    expect(await library.delete(fixture('A')), isFalse);
    expect(api.materialCalls.where((c) => c.startsWith('delete:')), isEmpty);
    epoch++;
    expect(library.images, isEmpty);
    library.dispose();
  });

  test('加载失败保留明确错误，重复游标停止，不无限翻页', () async {
    final api = LibraryApi()..failure = '无素材权限';
    final library = MediaLibrary(
      api: api,
      request: <T>(target, action) => action('token', 'https://api.bot.qq.com'),
      appId: () => 'A',
      epoch: () => 0,
      changed: () {},
    );
    await library.refresh();
    expect(library.loading, isFalse);
    expect(library.error, '无素材权限');
    api.failure = null;
    await library.refresh();
    expect(library.images.single.id, 'first');
    api.repeatCursor = true;
    await library.refresh();
    await library.loadAll();
    expect(library.cursor, isEmpty);
    expect(library.error, contains('游标重复'));
    library.dispose();
  });

  test('上传加入当前素材库，切换账户时停止处理旧文件；搜索加载所有分页', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-material-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture.png');
    await file.writeAsBytes(img.encodePng(img.Image(width: 4, height: 3)));
    var app = 'A', epoch = 0;
    final api = LibraryApi()..second = [fixture('second')];
    final library = MediaLibrary(
      api: api,
      request: <T>(target, action) =>
          action(target.appId, 'https://api.bot.qq.com'),
      appId: () => app,
      epoch: () => epoch,
      changed: () {},
    );
    await library.refresh();
    await library.loadAll();
    expect(library.images.map((i) => i.id), ['first', 'second']);
    expect((await library.upload(file))!.id, 'uploaded');
    expect(library.images.first.id, 'uploaded');
    expect(library.progress, 1);
    expect(library.uploading, isFalse);
    final old = library.upload(file);
    app = 'B';
    epoch++;
    expect(library.images, isEmpty);
    expect(await old, isNull);
    expect(api.materialCalls.where((c) => c.startsWith('upload:')).length, 1);
    library.dispose();
  });

  for (final width in [320.0, 390.0, 1100.0]) {
    testWidgets('素材界面小屏/桌面：搜索、选择、删除确认，不自动发送 $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = LibraryApi()..first = [fixture('first'), fixture('another')];
      final bot = BotClient(
        MemoryStorage(config: validConfig()),
        apiService: api,
      );
      BotMediaImage? selected;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    selected = await showMaterialLibrary(context, bot),
                child: const Text('打开素材'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开素材'));
      await tester.pumpAndSettle();
      expect(find.text('图片素材 · 2/100'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(selected, isNull);
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pumpAndSettle();
      expect(find.text('another.png'), findsNothing);
      await tester.tap(find.byTooltip('素材操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除素材'));
      await tester.pumpAndSettle();
      expect(find.textContaining('草稿中的引用'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.materialCalls.any((c) => c.startsWith('delete:')), isFalse);
      await tester.tap(find.text('插入 Markdown'));
      await tester.pumpAndSettle();
      expect(selected!.id, 'first');
      expect(find.byKey(const ValueKey('material-library')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      bot.dispose();
    });
  }

  testWidgets('聊天选素材保留原草稿，自动转Markdown，预览不改源码且发送一次', (tester) async {
    final sent = <OutgoingMessage>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            onPickMaterial: () async => fixture('first'),
            onSendText: (_) async => throw StateError('不应发送文本'),
            onSendImage: (_) async => throw StateError('不应发送富媒体'),
            onSendMarkdown:
                (text, {useTemplate, templateId, templateParams}) async {
                  sent.add(OutgoingMessage(type: 2, content: text));
                  return true;
                },
            onSendConfigured: (message) async {
              sent.add(message);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '原有草稿');
    await revealComposerTools(tester);
    await tester.tap(find.byTooltip('图片素材'));
    await tester.pumpAndSettle();
    final editor = tester.widget<TextField>(
      find.byKey(const ValueKey('markdown-editor')),
    );
    final source = editor.controller!.text;
    expect(source, '原有草稿\n![图片 #320px #320px](qqbot-media://image/v1/first)\n');
    expect(sent, isEmpty);
    expect(find.byType(QqMediaImage), findsOneWidget);
    expect(
      tester
          .widget<Markdown>(find.byKey(const ValueKey('markdown-live-preview')))
          .data,
      source,
    );
    await tester.tap(find.text('发送 Markdown'));
    await tester.pumpAndSettle();
    expect(sent.single.type, 2);
    expect(sent.single.content, source);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('素材预览只在内存解析；切机器人清空旧预览，缺少机器人上下文也不崩溃', (tester) async {
    final api = LibraryApi()
      ..first = [
        fixture(
          'first',
          preview: 'https://fixture-1.cos.ap-guangzhou.myqcloud.com/x',
        ),
      ];
    final bot = BotClient(
      MemoryStorage(config: validConfig()),
      apiService: api,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<BotClient>.value(
        value: bot,
        child: const MaterialApp(
          home: Scaffold(
            body: QqMediaImage(reference: 'qqbot-media://image/v1/first'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MaterialPreview), findsOneWidget);
    final request = tester.widget<Image>(find.byType(Image));
    final provider = request.image as ResizeImage;
    expect(
      (provider.imageProvider as NetworkImage).url,
      contains('cos.ap-guangzhou'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: QqMediaImage(reference: 'qqbot-media://image/v1/first'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('请在主窗口素材库查看'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    bot.dispose();
  });
}
