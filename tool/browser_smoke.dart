// Native Windows-only smoke test. It never initializes bot storage or connects QQ.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qq_bot_manager/ui/screens/browser_screen.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/services/desktop_window_controller.dart';
import 'package:qq_bot_manager/ui/widgets/desktop_window_frame.dart';

class BrowserSmokeStorage extends StorageService {
  @override
  BotConfig getBotConfig() => BotConfig();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) exit(64);
  final window = DesktopWindowController(BrowserSmokeStorage());
  await window.initialize();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <String>[];
  final agents = <String>[];
  var mobileViewport = false;
  final result = File('build/browser-smoke-result.json');
  var finished = false;
  Future<void> finish(bool passed, String detail) async {
    if (finished) return;
    finished = true;
    await result.parent.create(recursive: true);
    await result.writeAsString(
      jsonEncode({
        'passed': passed,
        'detail': detail,
        'requests': seen,
        'userAgents': agents,
        'mobileViewport': mobileViewport,
      }),
    );
    await server.close(force: true);
    await window.exitApp();
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(passed ? 2 : 1); // Native close should have exited already.
  }

  final deadline = Timer(
    const Duration(seconds: 30),
    () => finish(false, 'Native WebView did not complete navigation'),
  );
  server.listen((request) async {
    seen.add(request.uri.path);
    agents.add(request.headers.value(HttpHeaders.userAgentHeader) ?? '');
    if (request.uri.path == '/ready') {
      final width = int.tryParse(request.uri.queryParameters['width'] ?? '');
      mobileViewport = width != null && width > 0 && width <= 430;
    }
    request.response.headers.contentType = ContentType.html;
    if (request.uri.path == '/start') {
      request.response.write(
        '<!doctype html><html><title>内置浏览器测试</title><body>仅本机页面，未连接 QQ。'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<script>fetch("/ready?width="+innerWidth).then(()=>{location.href="/next";});</script></body></html>',
      );
    } else if (request.uri.path == '/next') {
      request.response.write(
        '<!doctype html><html><title>导航测试完成</title><body>测试完成'
        '<script>setTimeout(()=>fetch("/complete"),300);</script></body></html>',
      );
    } else if (request.uri.path == '/complete') {
      request.response.write('ok');
      await request.response.close();
      deadline.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await finish(
        seen.contains('/ready') &&
            seen.contains('/next') &&
            mobileViewport &&
            agents.every(
              (agent) =>
                  agent.contains('Mobile Safari/') && agent.contains('Chrome/'),
            ),
        'Native WebView loaded mobile HTML/UA, checked viewport and navigated in-app',
      );
      return;
    } else {
      request.response.write('ok');
    }
    await request.response.close();
  });
  runApp(
    MaterialApp(
      builder: (_, child) =>
          DesktopWindowFrame(controller: window, child: child!),
      home: BrowserScreen(
        uri: Uri.parse('http://127.0.0.1:${server.port}/start'),
      ),
    ),
  );
}
