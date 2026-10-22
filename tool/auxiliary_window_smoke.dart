// Native desktop regression: display-only fixture windows, no Hive, bot login,
// publisher keys or external websites. Build this target only for local QA.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/auxiliary_windows.dart';
import 'package:qq_bot_manager/ui/auxiliary_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final pending = AuxiliaryWindows.pendingRequest;
  if (pending != null) {
    await child(pending);
    return;
  }
  final output = await Directory(
    'build/native-auxiliary-smoke',
  ).absolute.create(recursive: true);
  final result = File(p.join(output.path, 'result.json'));
  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final image = await File('assets/branding/logo.png').readAsBytes();
    server.listen((request) async {
      if (request.uri.path == '/image.png') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(image);
      } else {
        await File(p.join(output.path, 'browser-request.json')).writeAsString(
          jsonEncode({'agent': request.headers.value('user-agent') ?? ''}),
          flush: true,
        );
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><meta charset="utf-8"><title>独立浏览器测试页</title>'
          '<h1>桌面网页</h1><p>本地测试，无机器人登录或聊天数据。</p>',
        );
      }
      await request.response.close();
    });
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(640, 420),
        title: '独立窗口验证 · 不连接机器人',
        center: true,
      ),
    );
    await windowManager.show();
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('正在验证独立窗口，主窗口保持不变'))),
      ),
    );
    final windows = AuxiliaryWindows();
    final message = MessageModel(
      id: 'fixture-message',
      sessionId: 'fixture-group',
      senderId: 'bot',
      senderName: '测试机器人',
      content: '[Markdown]',
      markdownContent:
          '你好 <qqbot-at-user id="fixture-member" />\n\n<qqbot-at-everyone />',
      messageType: 2,
      timestamp: DateTime(2026, 10, 22),
      isFromBot: true,
      extra: {
        'mentions': [
          {'id': 'fixture-member', 'username': '小明'},
        ],
      },
    );
    final origin = 'http://127.0.0.1:${server.port}';
    for (final kind in ['record', 'history', 'browser']) {
      final marker = File(p.join(output.path, '$kind.json'));
      if (await marker.exists()) await marker.delete();
      await windows.open(kind, {
        'title': kind == 'browser' ? '独立浏览器测试页' : '独立聊天记录测试页',
        'dark': false,
        'fixtureOutput': output.path,
        if (kind == 'browser') 'url': '$origin/browser',
        if (kind == 'history') 'messages': [message.toMap()],
        if (kind == 'record')
          'body': {
            'message_type': 102,
            'record_title': '测试用户的聊天记录',
            'msg_elements': [
              {
                'author': {'username': '小明'},
                'content': '周末照片，图片直接展示。',
                'attachments': [
                  {
                    'url': '$origin/image.png',
                    'filename': 'logo.png',
                    'content_type': 'image/png',
                    'width': 512,
                    'height': 512,
                  },
                ],
              },
              {
                'author': {'username': '小红'},
                'content': '这条是独立记录页里的第二条消息。',
              },
            ],
          },
      });
    }
    final until = DateTime.now().add(const Duration(seconds: 45));
    final records = <Map<String, dynamic>>[];
    while (DateTime.now().isBefore(until)) {
      records.clear();
      for (final kind in ['record', 'history', 'browser']) {
        final file = File(p.join(output.path, '$kind.json'));
        if (await file.exists()) {
          try {
            records.add(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
            );
          } catch (_) {}
        }
      }
      if (records.length == 3) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final agentFile = File(p.join(output.path, 'browser-request.json'));
    final agent = await agentFile.exists()
        ? jsonDecode(await agentFile.readAsString())['agent'] as String
        : '';
    final preserved = await windowManager.isVisible();
    final ids = records.map((r) => r['pid']).toSet();
    final passed =
        records.length == 3 &&
        records.every((r) => r['passed'] == true) &&
        ids.length == 3 &&
        !ids.contains(pid) &&
        preserved &&
        agent.contains('Windows') &&
        !agent.contains('Mobile');
    await result.writeAsString(
      jsonEncode({
        'passed': passed,
        'parentPid': pid,
        'parentWindowPreserved': preserved,
        'desktopWebViewLoaded':
            agent.contains('Windows') && !agent.contains('Mobile'),
        'children': records,
      }),
      flush: true,
    );
    await server.close(force: true);
    await windowManager.destroy();
    exit(passed ? 0 : 1);
  } catch (error) {
    await result.writeAsString(
      jsonEncode({'passed': false, 'exception': error.runtimeType.toString()}),
      flush: true,
    );
    await server?.close(force: true);
    exit(1);
  }
}

Future<void> child(String pending) async {
  final input =
      jsonDecode(await File(pending).readAsString()) as Map<String, dynamic>;
  final output = Directory(input['fixtureOutput'] as String);
  final kind = input['kind'] as String;
  final result = File(p.join(output.path, '$kind.json'));
  final boundary = GlobalKey();
  var finished = false;
  Timer? deadline;
  Future<void> finish(bool passed, {String? failure}) async {
    if (finished) return;
    finished = true;
    deadline?.cancel();
    await result.writeAsString(
      jsonEncode({
        'passed': passed,
        'kind': kind,
        'pid': pid,
        'visible': await windowManager.isVisible(),
        'requestConsumed': !await File(pending).exists(),
        'exception': ?failure,
      }),
      flush: true,
    );
    await windowManager.destroy();
    exit(passed ? 0 : 1);
  }

  deadline = Timer(
    const Duration(seconds: 25),
    () => finish(false, failure: 'timeout'),
  );
  try {
    final app = await initializeAuxiliaryApplication((_) {});
    runApp(RepaintBoundary(key: boundary, child: app));
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    if (kind == 'browser') {
      final until = DateTime.now().add(const Duration(seconds: 12));
      while (!await File(
            p.join(output.path, 'browser-request.json'),
          ).exists() &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      p.join(output.path, '$kind.png'),
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    await finish(
      await windowManager.isVisible() && !await File(pending).exists(),
    );
  } catch (error) {
    await finish(false, failure: error.runtimeType.toString());
  }
}
