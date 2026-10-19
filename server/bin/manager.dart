import 'dart:async';
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/runtime/assets_server.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import '../src/manager_server.dart';

Future<void> main(List<String> args) async {
  try {
    await _run(args);
  } catch (error) {
    // A corrupted saved JSON value may contain credentials in its exception
    // source. Never render exception messages or that source in service logs.
    stderr.writeln(
      '网页服务启动失败（${error.runtimeType}）。请检查参数、资源目录和私有数据目录权限；不会覆盖原有数据。',
    );
    await Hive.close();
    exitCode = 1;
  }
}

Future<void> _run(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'QQ机器人管理器 Linux 网页服务\n'
      '--host 127.0.0.1 --port 23336 --data ./data --assets .\n'
      '--public-url https://bot.example.com （HTTPS 反向代理时设置）\n'
      '--no-auto-connect （不自动连接已保存的机器人）\n'
      '首次启动生成 data/admin-password.txt；不会输出密码、机器人密钥或 Token。',
    );
    return;
  }
  String option(String name, String fallback) {
    final index = args.indexOf('--$name');
    if (index < 0) return fallback;
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      throw FormatException('--$name 缺少参数');
    }
    return args[index + 1];
  }

  final port = int.tryParse(option('port', '23336'));
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('端口必须为 1–65535。');
    exitCode = 64;
    return;
  }
  final data = Directory(p.absolute(option('data', 'data')));
  await data.create(recursive: true);
  if (!Platform.isWindows) await Process.run('chmod', ['700', data.path]);
  rootBundle.root = Directory(p.absolute(option('assets', '.')));
  if (!await File(
    p.join(rootBundle.root.path, 'server/web/index.html'),
  ).exists()) {
    throw const FormatException('网页资源不完整');
  }
  Hive.init(data.path);
  final storage = StorageService();
  await storage.init();
  final plugins = PluginManager(storage);
  await plugins.init();
  final bot = BotClient(storage);
  final server = await ManagerServer.start(
    bot: bot,
    plugins: plugins,
    storage: storage,
    data: data,
    assets: rootBundle.root,
    host: option('host', '127.0.0.1'),
    port: port,
    publicUrl: option('public-url', ''),
  );
  stdout.writeln(
    'QQ机器人管理器已启动：${server.address}\n'
    '登录密码文件：${p.join(data.path, 'admin-password.txt')}\n'
    '公网访问请使用 HTTPS 反向代理，不要将 data 目录设为网站根目录。',
  );
  if (!args.contains('--no-auto-connect') &&
      bot.config.appId.isNotEmpty &&
      bot.config.clientSecret.isNotEmpty) {
    unawaited(bot.connect());
  }
  final stopped = Completer<void>();
  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    try {
      await server.close();
      await Hive.close();
    } finally {
      stopped.complete();
    }
  }

  final interrupt = ProcessSignal.sigint.watch().listen(shutdown);
  StreamSubscription<ProcessSignal>? terminate;
  if (!Platform.isWindows) {
    terminate = ProcessSignal.sigterm.watch().listen(shutdown);
  }
  await stopped.future;
  await interrupt.cancel();
  await terminate?.cancel();
}
