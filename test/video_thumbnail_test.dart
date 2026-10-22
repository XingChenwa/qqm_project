import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/auxiliary_windows.dart';
import 'package:qq_bot_manager/services/video_thumbnail_service.dart';
import 'package:qq_bot_manager/ui/widgets/video_attachment.dart';

final _image = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY1UAAAAASUVORK5CYII=',
);

class _VideoWindows extends AuxiliaryWindows {
  final requests = <Map<String, dynamic>>[];
  _VideoWindows() : super(supported: true);
  @override
  Future<void> open(String kind, Map<String, dynamic> data) async {
    requests.add({'kind': kind, ...data});
  }
}

void main() {
  test('重复视频共享封面任务；串行生成，不为每条气泡常驻播放器', () async {
    final firstFrame = Completer<Uint8List?>();
    final requests = <String>[];
    var active = 0, maximum = 0;
    final thumbnails = VideoThumbnailService(
      extract: (uri) async {
        requests.add(uri.path);
        active++;
        if (active > maximum) maximum = active;
        final result = uri.path == '/one' ? await firstFrame.future : _image;
        active--;
        return result;
      },
    );
    final first = thumbnails.load('https://example.com/one');
    final duplicate = thumbnails.load('https://example.com/one');
    final second = thumbnails.load('https://example.com/two');
    expect(identical(first, duplicate), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(requests, ['/one']);
    firstFrame.complete(_image);
    expect(await first, _image);
    expect(await second, _image);
    expect(maximum, 1);
    await thumbnails.load('https://example.com/one');
    expect(requests, ['/one', '/two']);
  });

  test('封面LRU有限；异常、空结果或超大截图均不影响后续任务', () async {
    final requests = <String>[];
    final thumbnails = VideoThumbnailService(
      cacheSize: 2,
      extract: (uri) async {
        requests.add(uri.path);
        if (uri.path == '/error') throw StateError('private signed URL');
        if (uri.path == '/empty') return Uint8List(0);
        if (uri.path == '/large') {
          return Uint8List(VideoThumbnailService.maximumThumbnailBytes + 1);
        }
        return _image;
      },
    );
    for (final path in ['error', 'empty', 'large']) {
      expect(await thumbnails.load('https://example.com/$path'), isNull);
    }
    await thumbnails.load('https://example.com/a');
    await thumbnails.load('https://example.com/b');
    await thumbnails.load('https://example.com/a');
    await thumbnails.load('https://example.com/c');
    await thumbnails.load('https://example.com/b');
    expect(requests, ['/error', '/empty', '/large', '/a', '/b', '/c', '/b']);
  });

  test('来自聊天的地址只能为无凭据HTTP(S)，HTML不注入聊天内容', () async {
    var calls = 0;
    final thumbnails = VideoThumbnailService(
      extract: (_) async {
        calls++;
        return _image;
      },
    );
    for (final source in [
      'file:///C:/private/video.mp4',
      'content://private/video',
      'javascript:alert(1)',
      'https://secret:token@example.com/file',
      'not a url',
    ]) {
      expect(await thumbnails.load(source), isNull);
    }
    expect(calls, 0);
    final html = VideoThumbnailService.thumbnailHtml(
      Uri.parse('https://example.com/video?a=1&b=%22%3E%3Cscript%3E'),
    );
    expect(html, contains('&amp;'));
    expect(html, contains('<video muted playsinline'));
    expect(html, isNot(contains('autoplay')));
    expect(html, isNot(contains('<script>bad')));
    expect(html, contains('v.pause()'));
  });

  testWidgets('聊天里显示真实封面与叠加播放按钮，播放仍打开原视频独立窗口', (tester) async {
    final frame = Completer<Uint8List?>();
    final thumbnails = VideoThumbnailService(extract: (_) => frame.future);
    final windows = _VideoWindows();
    await tester.pumpWidget(
      Provider<AuxiliaryWindows>.value(
        value: windows,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: VideoAttachment(
                  thumbnails: thumbnails,
                  attachment: const ReceivedAttachment(
                    url: 'https://example.com/video',
                    filename: 'movie.mp4',
                    contentType: 'video/mp4',
                    width: 1920,
                    height: 1080,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('正在加载封面…'), findsOneWidget);
    expect(find.byTooltip('播放视频'), findsOneWidget);
    frame.complete(_image);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-preview-cover')), findsOneWidget);
    expect(find.text('正在加载封面…'), findsNothing);
    await tester.tap(find.byTooltip('播放视频'));
    await tester.pumpAndSettle();
    expect(windows.requests.single['kind'], 'browser');
    expect(windows.requests.single['url'], 'https://example.com/video');
    expect(windows.requests.single['video'], isTrue);
    expect(windows.requests.single['filename'], 'movie.mp4');
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面失败仍可播放或下载，手机竖屏尺寸不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: VideoAttachment(
                thumbnails: VideoThumbnailService(extract: (_) async => null),
                attachment: const ReceivedAttachment(
                  url: 'https://example.com/video',
                  contentType: 'video/mp4',
                  width: 1080,
                  height: 1920,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('点击播放视频'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton).first).onPressed,
      isNotNull,
    );
    expect(find.byTooltip('下载原视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会话列表复用气泡时不会把上一段视频的封面显示给新视频', (tester) async {
    final second = Completer<Uint8List?>();
    final thumbnails = VideoThumbnailService(
      extract: (uri) async {
        return uri.path == '/first' ? _image : await second.future;
      },
    );
    Widget bubble(String name) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: VideoAttachment(
              thumbnails: thumbnails,
              attachment: ReceivedAttachment(
                url: 'https://example.com/$name',
                contentType: 'video/mp4',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(bubble('first'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-preview-cover')), findsOneWidget);
    await tester.pumpWidget(bubble('second'));
    await tester.pump();
    expect(find.byKey(const ValueKey('video-preview-cover')), findsNothing);
    expect(find.text('正在加载封面…'), findsOneWidget);
    second.complete(_image);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-preview-cover')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
