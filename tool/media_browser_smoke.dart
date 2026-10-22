// Local native verification only. No Hive, QQ login, tokens or remote traffic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/video_thumbnail_service.dart';
import 'package:qq_bot_manager/ui/screens/browser_screen.dart';
import 'package:qq_bot_manager/ui/widgets/startup_gate.dart';
import 'package:qq_bot_manager/ui/widgets/video_attachment.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await Directory(
    'build/media-browser-smoke',
  ).absolute.create(recursive: true);
  final result = File('${directory.path}/result.json');
  HttpServer? server;
  try {
    final bytes = await File(
      '${directory.path}/fixture-h264.mp4',
    ).readAsBytes();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var videoRequests = 0;
    server.listen((request) async {
      try {
        videoRequests++;
        final range = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = int.tryParse(range?.group(1) ?? '') ?? 0;
        final end = (int.tryParse(range?.group(2) ?? '') ?? bytes.length - 1)
            .clamp(start, bytes.length - 1);
        request.response.headers.set('content-type', 'video/mp4');
        request.response.headers.set(
          'content-disposition',
          'attachment; filename="fixture.mp4"',
        );
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.contentLength = end - start + 1;
        if (range != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        if (request.method != 'HEAD') {
          request.response.add(bytes.sublist(start, end + 1));
        }
        await request.response.close();
      } catch (_) {
        await request.response.close();
      }
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/attachment.mp4');
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(900, 720),
        title: '本地启动与视频验证 · 不连接机器人',
        center: true,
      ),
    );
    await windowManager.show();
    final controller = Completer<InAppWebViewController>();
    final capture = GlobalKey();
    runApp(
      RepaintBoundary(
        key: capture,
        child: StartupGate(
          initialize: (report) async {
            report('本地验证：加载中');
            await Future<void>.delayed(const Duration(milliseconds: 650));
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              home: BrowserScreen(
                uri: uri,
                initialVideo: true,
                filename: '本地 H.264 播放测试.mp4',
                onControllerCreated: (value) {
                  if (!controller.isCompleted) controller.complete(value);
                },
              ),
            );
          },
        ),
      ),
    );
    Future<void> screenshot(String name) async {
      final render =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    }

    await Future<void>.delayed(const Duration(milliseconds: 350));
    await screenshot('loading');
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    await screenshot('branding');
    final cover = await VideoThumbnailService.shared.load(uri.toString());
    final coverImage = cover == null ? null : img.decodeImage(cover);
    final colors = <int>{};
    if (coverImage != null) {
      for (var y = 20; y < coverImage.height; y += 20) {
        for (var x = 20; x < coverImage.width; x += 20) {
          final pixel = coverImage.getPixel(x, y);
          colors.add(
            (pixel.r.toInt() ~/ 16) * 256 +
                (pixel.g.toInt() ~/ 16) * 16 +
                pixel.b.toInt() ~/ 16,
          );
        }
      }
      await File('${directory.path}/video-cover.jpg').writeAsBytes(cover!);
    }
    final coverPassed = coverImage != null && colors.length > 16;
    final view = await controller.future.timeout(const Duration(seconds: 15));
    var state = <String, dynamic>{};
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final raw = await view.evaluateJavascript(
        source: '''JSON.stringify((function(){
        var v=document.querySelector('video'); if(!v)return {missing:true};
        if(v.readyState>=2){v.muted=true;v.play().catch(function(){});}
        return {ready:v.readyState,width:v.videoWidth,height:v.videoHeight,
          time:v.currentTime,paused:v.paused,error:v.error?v.error.code:null};
      })())''',
      );
      if (raw is String) state = Map<String, dynamic>.from(jsonDecode(raw));
      if ((state['time'] as num? ?? 0) > .1 || state['error'] != null) break;
    }
    final passed =
        coverPassed &&
        videoRequests > 0 &&
        (state['ready'] as num? ?? 0) >= 2 &&
        state['width'] == 320 &&
        state['height'] == 180 &&
        state['paused'] == false &&
        (state['time'] as num? ?? 0) > .1 &&
        state['error'] == null;
    await result.writeAsString(
      jsonEncode({
        'passed': passed,
        'cover': {
          'passed': coverPassed,
          'width': coverImage?.width,
          'height': coverImage?.height,
          'distinctColors': colors.length,
        },
        'videoRequests': videoRequests,
        'video': state,
      }),
    );
    final chatCapture = GlobalKey();
    runApp(
      RepaintBoundary(
        key: chatCapture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: VideoAttachment(
                  attachment: ReceivedAttachment(
                    url: uri.toString(),
                    filename: '聊天中的视频封面.mp4',
                    contentType: 'video/mp4',
                    width: 320,
                    height: 180,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final chatRender =
        chatCapture.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final chatImage = await chatRender.toImage(pixelRatio: 1);
    final chatPng = await chatImage.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${directory.path}/chat-video-cover.png',
    ).writeAsBytes(chatPng!.buffer.asUint8List());
    chatImage.dispose();
    await server.close(force: true);
    await windowManager.destroy();
    exit(passed ? 0 : 1);
  } catch (error) {
    await result.writeAsString(
      jsonEncode({'passed': false, 'exception': error.runtimeType.toString()}),
    );
    await server?.close(force: true);
    await windowManager.destroy();
    exit(1);
  }
}
