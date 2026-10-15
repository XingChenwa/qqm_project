import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/models/qq_face.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/qface_service.dart';
import 'package:qq_bot_manager/ui/widgets/linkified_text.dart';
import 'package:qq_bot_manager/ui/widgets/received_message_view.dart';

import 'api_service_test.dart' show RecordingAdapter;
import 'chat_rendering_fixes_test.dart' show decodeTestImages;

class FaceImageClient extends Fake implements HttpClient {
  final Uint8List bytes;
  final uris = <Uri>[];
  FaceImageClient(this.bytes);
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    return FaceImageRequest(bytes);
  }
}

class FaceImageRequest extends Fake implements HttpClientRequest {
  final Uint8List bytes;
  FaceImageRequest(this.bytes);
  @override
  Future<HttpClientResponse> close() async => FaceImageResponse(bytes);
}

class FaceImageResponse extends Fake implements HttpClientResponse {
  final Uint8List bytes;
  FaceImageResponse(this.bytes);
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

List<Map<String, dynamic>> faceIndex() => [
  {
    'emojiId': '277',
    'describe': '/汪汪',
    'assets': [
      {'type': 2, 'path': 'assets/qq_emoji/277/apng/277.png'},
      {'type': 0, 'path': 'assets/qq_emoji/277/png/277.png'},
    ],
  },
  {
    'emojiId': '0',
    'describe': '/惊讶',
    'assets': [
      {'type': 0, 'path': 'assets/qq_emoji/0/png/0.png'},
    ],
  },
];

String faceTag({String id = '277', String name = '汪汪', int type = 1}) =>
    '<faceType=$type,faceId="$id",ext="${base64Encode(utf8.encode(jsonEncode({'text': name})))}">';

class MemoryQFace extends QFaceService {
  final QFaceCatalog catalog;
  int calls = 0;
  MemoryQFace(this.catalog);
  @override
  Future<QFaceCatalog> getCatalog() async {
    calls++;
    return catalog;
  }
}

void main() {
  test('读取用户指定 v1 索引，并发请求合并且不携带 QQ 身份或聊天信息', () async {
    final adapter = RecordingAdapter()..response = faceIndex();
    final service = QFaceService(adapter: adapter);
    addTearDown(service.dispose);
    final results = await Future.wait(
      List.generate(10, (_) => service.getCatalog()),
    );
    final catalog = results.first;
    expect(
      catalog.byId['277']?.url,
      'https://koishi.js.org/QFace/assets/qq_emoji/277/png/277.png',
    );
    expect(catalog.byName['汪汪']?.id, '277');
    expect(catalog.byId['0']?.label, '惊讶');
    await service.getCatalog();
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.uri.toString(), QFaceService.endpoint);
    expect(request.queryParameters, isEmpty);
    expect(request.data, isNull);
    expect(request.followRedirects, isFalse);
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains(anyOf('authorization', 'cookie', 'x-union-appid'))),
    );
  });

  test('HTTP 失败、重定向和超大索引使用文字兜底并负缓存，不反复请求', () async {
    for (final status in [302, 403, 500, 200]) {
      final adapter = RecordingAdapter()
        ..status = status
        ..response = status == 200
            ? {'large': 'x' * (QFaceService.maxBytes + 1)}
            : faceIndex();
      final service = QFaceService(adapter: adapter);
      addTearDown(service.dispose);
      expect((await service.getCatalog()).isEmpty, isTrue);
      expect((await service.getCatalog()).isEmpty, isTrue);
      expect(adapter.requests, hasLength(1));
    }
  });

  test('索引仅接受同源表情目录中的 PNG/APNG，不接受任意链接、穿越路径和 Lottie', () {
    for (final resourcePath in [
      'https://malicious.example/277.png',
      '//malicious.example/277.png',
      'assets/qq_emoji/277/png/../../secret.png',
      'assets/qq_emoji/277/png/%2e%2e.png',
      'assets/qq_emoji/277/png/277.png?token=secret',
      'assets/qq_emoji/0/png/0.png',
      'assets/qq_emoji/277/lottie/277.json',
    ]) {
      final catalog = QFaceCatalog.fromJson([
        {
          'emojiId': '277',
          'describe': '/汪汪',
          'assets': [
            {'path': resourcePath},
          ],
        },
      ]);
      expect(catalog.isEmpty, isTrue, reason: resourcePath);
    }
    final apng = QFaceCatalog.fromJson([
      {
        'emojiId': '277',
        'describe': '/汪汪',
        'assets': [
          {'path': 'assets/qq_emoji/277/apng/277.png'},
        ],
      },
    ]);
    expect(apng.byId['277']?.url, endsWith('/apng/277.png'));
    expect(QFaceCatalog.fromJson({'emojis': {}}).isEmpty, isTrue);
  });

  test('原始 face 标签、旧占位与 emoji 标记可识别，正文空格、链接和 @ 保留', () {
    final text = '1我鸭 ${faceTag()} 你好 <@u> https://example.com/page';
    final parts = QqTextPart.parse(
      text,
      mentions: [
        {'id': 'u', 'username': '小明'},
      ],
    );
    expect(parts.where((p) => p.isFace).single.faceId, '277');
    expect(parts.first.text, '1我鸭 ');
    expect(parts.last.text, ' 你好 @小明 https://example.com/page');
    final catalog = QFaceCatalog.fromJson(faceIndex());
    for (final source in [
      '[QQ表情: 汪汪]',
      '[QQ表情#277]',
      '<emoji:277>',
      faceTag(id: '', name: '[汪汪]'),
    ]) {
      expect(catalog.resolve(QqTextPart.parse(source).single)?.id, '277');
    }
    expect(
      catalog
          .resolve(QqTextPart.parse(faceTag(id: '0', name: '惊讶')).single)
          ?.id,
      '0',
    );
    expect(catalog.resolve(QqTextPart.parse(faceTag(type: 6)).single), isNull);
    expect(
      catalog.resolve(QqTextPart.parse(faceTag(id: '99999')).single),
      isNull,
    );
    expect(
      QqTextPart.parse(faceTag() * 240).where((p) => p.isFace),
      hasLength(200),
    );
  });

  testWidgets('混排文字和 QFace 使用可选择的 WidgetSpan，图片加载失败保留文字且不报错', (tester) async {
    final service = MemoryQFace(QFaceCatalog.fromJson(faceIndex()));
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: LinkifiedText(
              '1我鸭 ${faceTag()} 链接 https://example.com/page',
              qqFaces: true,
              faceService: service,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('qface-277')), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    final image = tester.widget<Image>(find.byKey(const ValueKey('qface-277')));
    expect((image.image as NetworkImage).url, endsWith('/277/png/277.png'));
    final text = tester.widget<Text>(
      find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
    );
    final spans = text.textSpan! as TextSpan;
    expect(spans.children!.whereType<WidgetSpan>(), hasLength(1));
    expect(
      spans.children!.whereType<TextSpan>().any((span) => span.text == '1我鸭 '),
      isTrue,
    );
    expect(
      spans.children!.whereType<TextSpan>().any(
        (span) => span.recognizer != null,
      ),
      isTrue,
    );
    // Flutter's mock HTTP client rejects image downloads: errorBuilder must be safe.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('[QQ表情: 汪汪]'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(service.calls, 1);
  });

  testWidgets('空索引保留原文字，普通文本和自定义大表情不会请求索引', (tester) async {
    final service = MemoryQFace(const QFaceCatalog.empty());
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkifiedText(
            '1我鸭[QQ表情: 汪汪]',
            qqFaces: true,
            faceService: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1我鸭[QQ表情: 汪汪]'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(service.calls, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkifiedText(
            '普通文字 ${faceTag(type: 6)}',
            qqFaces: true,
            faceService: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QFace 图片成功解码并在正文中显示，图片请求仅含公共表情 ID', (tester) async {
    final client = FaceImageClient(
      Uint8List.fromList(img.encodePng(img.Image(width: 24, height: 24))),
    );
    debugNetworkImageHttpClientProvider = () => client;
    imageCache.clear();
    addTearDown(() => debugNetworkImageHttpClientProvider = null);
    final service = MemoryQFace(QFaceCatalog.fromJson(faceIndex()));
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkifiedText(
            '1我鸭 ${faceTag()}',
            qqFaces: true,
            faceService: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await decodeTestImages(tester);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(
      client.uris.single.toString(),
      'https://koishi.js.org/QFace/assets/qq_emoji/277/png/277.png',
    );
    expect(client.uris.single.queryParameters, isEmpty);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    imageCache.clear();
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('引用消息中的表情可显示，反复展开不出现 WidgetSpan 或缓存类型异常', (tester) async {
    final service = MemoryQFace(QFaceCatalog.fromJson(faceIndex()));
    addTearDown(service.dispose);
    final body = ReceivedMessageBody.fromMap({
      'message_type': 103,
      'msg_elements': [
        {'content': '被引用的消息 ${faceTag()}'},
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ReceivedMessageView(
              body: body,
              storageKey: 'qface-quote',
              faceService: service,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('qface-277')), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('引用消息 · 1 个元素'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
