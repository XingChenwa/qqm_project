// Isolated native updater test. Never initializes Hive, preferences or QQ.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/desktop_window_controller.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/widgets/desktop_window_frame.dart';

class _SmokeStorage extends StorageService {
  @override
  BotConfig getBotConfig() => BotConfig(skipCloseConfirmation: true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) exit(64);
  final install = p.dirname(Platform.resolvedExecutable);
  final marker = File(p.join(install, '.qqm-smoke.json'));
  if (p.basename(install) != 'current' ||
      !install.contains('update-smoke-') ||
      !await marker.exists()) {
    exit(64);
  }
  final data = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
  final result = File(data['result'] as String);
  final window = DesktopWindowController(_SmokeStorage());
  await window.initialize();
  runApp(
    MaterialApp(
      builder: (_, child) =>
          DesktopWindowFrame(controller: window, child: child!),
      home: const Scaffold(body: Center(child: Text('本地更新自测：临时测试目录，不连接 QQ。'))),
    ),
  );
  Future<void> finish(bool passed, String detail) async {
    await result.writeAsString(
      jsonEncode({'passed': passed, 'detail': detail}),
      flush: true,
    );
    await window.exitApp();
  }

  if (data['phase'] == 'after-update') {
    final updated = File(p.join(install, 'updated-payload.txt'));
    final kept = File(p.join(install, 'keep-me.txt'));
    await finish(
      await updated.exists() &&
          await updated.readAsString() == 'updated payload' &&
          await kept.exists() &&
          await kept.readAsString() == 'preserve unrelated fixture',
      'Native process exited, helper replaced files, relaunched and preserved unrelated files',
    );
    return;
  }
  final deadline = Timer(
    const Duration(seconds: 70),
    () => finish(false, 'Updater smoke deadline'),
  );
  try {
    data['phase'] = 'after-update';
    await marker.writeAsString(jsonEncode(data), flush: true);
    final cache = data['cache'] as String;
    final package = File(data['package'] as String);
    final script = File(p.join(cache, 'windows-update.ps1'));
    await script.writeAsString(
      '\ufeff${await rootBundle.loadString('assets/updater/windows-update.ps1')}',
      flush: true,
    );
    final ready = File(p.join(cache, 'ready.json'));
    final request = File(p.join(cache, 'request.json'));
    await request.writeAsString(
      jsonEncode({
        'schema': 1,
        'pid': pid,
        'executable': Platform.resolvedExecutable,
        'installDir': install,
        'package': package.path,
        'sha256': (await sha256.bind(package.openRead()).first).toString(),
        'format': data['format'] ?? 'zip',
        'cacheDir': cache,
        'readyFile': ready.path,
      }),
      flush: true,
    );
    final helper = await Process.start(
      p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      ),
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-RequestPath',
        request.path,
      ],
      mode: ProcessStartMode.normal,
      environment: {
        'PSModulePath': p.join(
          Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'Modules',
        ),
      },
    );
    await helper.stdin.close();
    unawaited(helper.stdout.drain<void>());
    unawaited(
      helper.stderr.pipe(File(p.join(cache, 'helper.log')).openWrite()),
    );
    final until = DateTime.now().add(const Duration(seconds: 45));
    while (!await ready.exists() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!await ready.exists()) throw StateError('No helper ready response');
    final response =
        jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
    if (response['ready'] != true) {
      throw StateError(response['error'].toString());
    }
    deadline.cancel();
    await window.exitApp();
  } catch (error) {
    deadline.cancel();
    await finish(false, error.toString());
  }
}
