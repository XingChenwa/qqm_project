import 'dart:async';
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/runtime/assets_server.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import '../src/admin_auth.dart';
import '../src/manager_server.dart';
import 'package:qq_bot_manager/agent/engine_check.dart';

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
  if (args.contains('--check-agent-engine')) {
    await verifyAgentEngine();
    stdout.writeln('PASS: offline embedded QuickJS / ESM / isolated storage');
    return;
  }
  if (args.contains('--help')) {
    stdout.writeln(
      'QQ机器人管理器 Linux 网页服务\n'
      '--host 127.0.0.1 --port 23336 --data ./data --assets .\n'
      '--public-url https://bot.example.com （HTTPS 反向代理时设置）\n'
      '--no-auto-connect （不自动连接已保存的机器人）\n'
      '--access-link http://服务器IP:23336 （仅在本地终端显示私有访问链接，不启动服务）\n'
      '首次打开网页设置管理密码和安全入口；一次性设置链接请勿分享。\n'
      '正常启动日志不会输出初始化码、密码、入口、机器人密钥或 Token。',
    );
    return;
  }
  String option(String name, String fallback) {
    // start.sh supplies defaults first. Explicit trailing CLI options win.
    final index = args.lastIndexOf('--$name');
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
  if (args.contains('--access-link')) {
    final auth = await AdminAuth.open(data);
    final link = await auth.accessLink(Uri.parse(option('access-link', '')));
    stdout.writeln('私有访问链接（仅供管理员使用，请勿公开）：\n$link');
    return;
  }
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
    autoConnect: !args.contains('--no-auto-connect'),
  );
  stdout.writeln(
    'QQ机器人管理器已启动：${server.address}\n'
    '${server.needsSetup
        ? '首次使用请在网页设置管理密码和安全入口。初始化码文件：${server.setupTokenPath}'
        : server.needsEntrance
        ? '请使用原密码登录，并补设安全入口；原有数据保留。'
        : '请使用安全入口和自己的管理密码登录。'}\n'
    '公网访问请使用 HTTPS 反向代理，不要将 data 目录设为网站根目录。',
  );
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
