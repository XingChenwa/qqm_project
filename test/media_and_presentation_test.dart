import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/media_image.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/media_download_service.dart';
import 'package:qq_bot_manager/ui/widgets/app_logo.dart';
import 'package:qq_bot_manager/ui/widgets/linkified_text.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/ui/widgets/startup_gate.dart';
import 'package:qq_bot_manager/ui/widgets/video_attachment.dart';
import 'package:qq_bot_manager/utils/media_link.dart';

import 'material_api_test.dart' show MaterialAdapter, client, jsonBody;

void main() {
  test('素材插入使用图片尺寸而不是文件名；直发与配置发送均开启平台转存校验', () async {
    const image = BotMediaImage(
      id: 'id',
      reference: 'qqbot-media://image/v1/token',
      filename: 'hash.gif',
      width: 800,
      height: 600,
    );
    expect(image.markdown, '![图片 #800px #600px](qqbot-media://image/v1/token)');
    final qq = MaterialAdapter((_) => jsonBody({'id': 'sent'}));
    final api = ApiService(dio: client(qq));
    await api.sendQQMarkdown(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture',
      targetId: 'group',
      isGroup: true,
      markdownContent: image.markdown,
    );
    await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'fixture',
      targetId: 'user',
      message: OutgoingMessage(type: 2, content: image.markdown),
    );
    for (final request in qq.requests) {
      expect(request.data['markdown']['content'], image.markdown);
      expect(request.data['markdown']['force_verify_image_resource'], isTrue);
      expect(request.data['msg_type'], 2);
    }
    expect(qq.requests.first.data.toString(), isNot(contains('hash.gif')));
    expect(qq.requests.first.data.toString(), isNot(contains('preview_url')));
  });

  test('视频识别不依赖URL扩展名；HTML播放器只包含转义后的HTTP媒体链接', () {
    const url =
        'https://multimedia.nt.qq.com.cn/download?orgfmt=t264&rkey=fixture';
    expect(isVideoLink(url), isTrue);
    expect(
      isVideoLink('https://example.com/download', mime: 'video/mp4'),
      isTrue,
    );
    expect(
      isVideoLink('https://example.com/download', filename: 'record.mp4'),
      isTrue,
    );
    expect(isVideoLink('https://example.com/download'), isFalse);
    expect(isVideoLink('file:///private/file.mp4'), isFalse);
    final html = videoPlayerHtml(Uri.parse('$url&value=%22%3E%3Cscript%3Ebad'));
    expect(html, contains('<video controls playsinline'));
    expect(html, contains('&amp;'));
    expect(html, isNot(contains('<script>bad')));
    expect(
      () => videoPlayerHtml(Uri.parse('javascript:alert(1)')),
      throwsFormatException,
    );
    final name = safeDownloadName(
      null,
      Uri.parse(url),
      mime: 'video/mp4',
      disposition: "attachment; filename*=UTF-8''%E8%A7%86%E9%A2%91.mp4",
    );
    expect(name, '视频.mp4');
    expect(safeDownloadName('../../CON.mp4', Uri.parse(url)), '_CON.mp4');
  });

  test('下载逐块写入、保留原字节及文件名、跟随安全重定向但不传QQ凭证', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-download-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = List<int>.generate(8192, (i) => i % 256);
    final adapter = MaterialAdapter(
      (request) => request.uri.host == 'example.com'
          ? ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': ['https://cdn.example.com/video'],
              },
            )
          : ResponseBody.fromBytes(
              bytes,
              200,
              headers: {
                'content-length': ['${bytes.length}'],
                'content-type': ['video/mp4'],
                'content-disposition': [
                  'attachment; filename="../../movie.mp4"',
                ],
              },
            ),
    );
    final service = MediaDownloadService(
      http: client(adapter),
      temporaryDirectory: () async => directory,
    );
    final download = await service.download(
      'https://example.com/start',
      CancelToken(),
    );
    expect(await download.file.readAsBytes(), bytes);
    expect(download.filename, 'movie.mp4');
    expect(download.size, bytes.length);
    for (final request in adapter.requests) {
      expect(
        request.headers.keys.any((k) => k.toLowerCase() == 'authorization'),
        isFalse,
      );
      expect(request.followRedirects, isFalse);
    }
    await download.dispose();
    expect(await directory.list().toList(), isEmpty);
    service.dispose();
  });

  test('超限、空文件、HTTP失败、HTTPS降级与中断都不会留下残缺文件', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqm-download-errors-',
    );
    addTearDown(() => directory.delete(recursive: true));
    for (final mode in [
      'oversize',
      'empty',
      'error',
      'downgrade',
      'truncated',
      'stream-limit',
    ]) {
      final adapter = MaterialAdapter(
        (request) => switch (mode) {
          'oversize' => ResponseBody.fromBytes(
            [1],
            200,
            headers: {
              'content-length': ['999'],
            },
          ),
          'empty' => ResponseBody.fromBytes([], 200),
          'error' => ResponseBody.fromString('expired', 403),
          'downgrade' => ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['http://example.com/insecure'],
            },
          ),
          'truncated' => ResponseBody.fromBytes(
            [1, 2],
            200,
            headers: {
              'content-length': ['3'],
            },
          ),
          _ => ResponseBody.fromBytes(List.filled(11, 1), 200),
        },
      );
      final service = MediaDownloadService(
        http: client(adapter),
        maxBytes: 10,
        temporaryDirectory: () async => directory,
      );
      await expectLater(
        service.download('https://example.com/file', CancelToken()),
        throwsFormatException,
        reason: mode,
      );
      expect(await directory.list().toList(), isEmpty, reason: mode);
      service.dispose();
    }
  });

  for (final own in [true, false]) {
    testWidgets('自己发送的@白色，其他用户@蓝色，普通文本和Markdown一致 own=$own', (tester) async {
      const source = '<qqbot-at-user id="member" /> <qqbot-at-everyone />';
      for (final markdown in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MessageBubble(
                message: MessageModel(
                  id: 'fixture',
                  sessionId: 'group',
                  senderId: 'sender',
                  senderName: '测试用户',
                  content: source,
                  markdownContent: markdown ? source : null,
                  messageType: markdown ? 2 : 0,
                  isFromBot: own,
                  timestamp: DateTime(2026, 10, 22),
                  extra: {
                    'mentions': [
                      {'id': 'member', 'username': '小明'},
                    ],
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final color = own ? Colors.white : const Color(0xff3268f4);
        if (markdown) {
          expect(tester.widget<Text>(find.text('@小明')).style!.color, color);
          expect(tester.widget<Text>(find.text('@全体成员')).style!.color, color);
        } else {
          final text = tester.widget<Text>(
            find
                .descendant(
                  of: find.byType(LinkifiedText),
                  matching: find.byType(Text),
                )
                .first,
          );
          final spans = (text.textSpan as TextSpan).children!
              .whereType<TextSpan>();
          expect(spans.where((s) => s.text!.startsWith('@')).length, 2);
          expect(
            spans
                .where((s) => s.text!.startsWith('@'))
                .every((s) => s.style!.color == color),
            isTrue,
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('加载完成后才展示Logo与两侧文字，小屏可进入应用', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = Completer<Widget>();
    await tester.pumpWidget(
      StartupGate(
        initialize: (report) {
          report('读取本地配置');
          return result.future;
        },
      ),
    );
    await tester.pump();
    expect(find.byType(AppLogo), findsNothing);
    expect(find.text('读取本地配置'), findsOneWidget);
    result.complete(const MaterialApp(home: Text('应用已就绪')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AppLogo), findsOneWidget);
    expect(find.text('基于 QQ 官方开放平台的'), findsOneWidget);
    expect(find.text('跨平台中文机器人管理客户端'), findsOneWidget);
    expect(find.text('如果喜欢这个项目，可以'), findsOneWidget);
    expect(
      find.textContaining('Star 谢谢喵。', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('仓库地址：'), findsOneWidget);
    expect(find.text('设置-关于'), findsOneWidget);
    expect(find.text('应用已就绪'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(find.text('应用已就绪'), findsOneWidget);
  });

  testWidgets('视频附件提供播放与下载入口，不再只是原始文件说明', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: VideoAttachment(
              attachment: ReceivedAttachment(
                url: 'https://example.com/file',
                filename: '视频.mp4',
                contentType: 'video/mp4',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('播放视频'), findsOneWidget);
    expect(find.byTooltip('下载原视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
