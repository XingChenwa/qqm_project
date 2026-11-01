import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../runtime/assets.dart';
import '../runtime/notifier.dart';
import 'node_runtime_installer.dart';

/// A managed, reusable host for original Node plugin packages. No plugin names,
/// commands or API keys are known to the client or to this service manager.
class NodePluginService extends ChangeNotifier {
  static const assetFiles = [
    'package.json',
    'package-lock.json',
    'packages.mjs',
    'server.mjs',
    'worker.mjs',
    'loader.mjs',
    'redis.mjs',
    'renderer.mjs',
    'common.mjs',
    'shim-plugin.mjs',
    'shim-common.mjs',
    'shim-puppeteer.mjs',
    'shim-yunzai.mjs',
    'shim-segment.mjs',
  ];
  final Directory root;
  NodePluginService(this.root);
  Process? _process;
  Future<void>? _starting;
  String _endpoint = '', _token = '', _remoteEndpoint = '', _remoteToken = '';
  bool _loaded = false, _paused = false, _closed = false;
  int _busy = 0;
  String phase = '', nodeVersion = '';
  bool get paused => _paused || _closed;
  bool get busy => _busy > 0;
  bool get isRemote => _remoteEndpoint.isNotEmpty;
  String get endpoint => isRemote ? _remoteEndpoint : _endpoint;
  String get token => isRemote ? _remoteToken : _token;
  void _status(String text) {
    phase = text;
    if (!_closed) notifyListeners();
  }

  Future<void> loadSettings() async {
    if (_loaded) return;
    await root.create(recursive: true);
    try {
      final value = jsonDecode(
        await File(p.join(root.path, 'connection.json')).readAsString(),
      );
      _remoteEndpoint = value['endpoint']?.toString() ?? '';
      _remoteToken = value['token']?.toString() ?? '';
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 2) rethrow;
    }
    _loaded = true;
  }

  Future<void> configureRemote(String url, String token) async {
    url = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.scheme != 'https' &&
              !(uri.scheme == 'http' &&
                  [
                    'localhost',
                    '127.0.0.1',
                    '::1',
                    '[::1]',
                  ].contains(uri.host))) {
        throw const FormatException('运行器地址须为 HTTPS，本机可用回环 HTTP；不能含账号、查询参数或片段。');
      }
      if (token.trim().length < 32) {
        throw const FormatException('请填写运行器生成的连接令牌。');
      }
    }
    if (busy) throw const FormatException('插件安装尚未结束，请稍后切换运行环境。');
    await stopLocal();
    _remoteEndpoint = url;
    _remoteToken = url.isEmpty ? '' : token.trim();
    _loaded = true;
    await root.create(recursive: true);
    await File(p.join(root.path, 'connection.json')).writeAsString(
      jsonEncode({'endpoint': url, 'token': _remoteToken}),
      flush: true,
    );
    _status(url.isEmpty ? '应用管理的本机运行器' : '已选择远程运行器');
  }

  Future<void> ensureStarted() async {
    if (paused) throw const FormatException('插件运行环境已暂停，完成数据迁移后可恢复。');
    await loadSettings();
    if (isRemote) return;
    if (_process != null && _endpoint.isNotEmpty) return;
    final previous = _starting;
    if (previous != null) return previous;
    final work = _start();
    _starting = work;
    try {
      await work;
    } finally {
      if (identical(_starting, work)) _starting = null;
    }
  }

  Future<void> _start() async {
    _status('准备 Node 运行环境');
    final runtime = await NodeRuntimeInstaller.ensure(root, _status);
    nodeVersion = runtime.version;
    if (paused) return;
    final host = Directory(p.join(root.path, 'host'));
    await host.create(recursive: true);
    final assets = <String, String>{};
    for (final name in assetFiles) {
      assets[name] = await rootBundle.loadString('assets/node_plugins/$name');
    }
    for (final e in assets.entries) {
      await File(p.join(host.path, e.key)).writeAsString(e.value);
    }
    final dependencyRevision = sha256
        .convert(utf8.encode(assets['package-lock.json']!))
        .toString();
    final marker = File(p.join(host.path, '.dependencies-ready'));
    var installed = '';
    if (await marker.exists()) installed = await marker.readAsString();
    if (installed != dependencyRevision ||
        !await Directory(p.join(host.path, 'node_modules')).exists()) {
      _status('安装通用运行器依赖');
      final npm = await _npmCli(runtime);
      final child = await Process.start(
        runtime.executable,
        [npm, 'ci', '--omit=dev', '--no-audit', '--no-fund'],
        workingDirectory: host.path,
        environment: _environment(runtime),
        includeParentEnvironment: false,
      );
      final out = child.stdout.drain<void>(), err = child.stderr.drain<void>();
      final code = await child.exitCode.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          child.kill();
          return -1;
        },
      );
      await Future.wait([out, err]);
      if (code != 0) {
        throw const FormatException('通用 Node 依赖安装失败，请检查网络或使用系统 Node.js。');
      }
      await marker.writeAsString(dependencyRevision);
    }
    if (paused) return;
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    _token = base64UrlEncode(bytes);
    final process = await Process.start(
      runtime.executable,
      [
        p.join(host.path, 'server.mjs'),
        '--root',
        root.absolute.path,
        '--port',
        '0',
        '--managed-stdio',
        '--npm',
        await _npmCli(runtime),
      ],
      workingDirectory: host.path,
      environment: {..._environment(runtime), 'QQM_NODE_HOST_TOKEN': _token},
      includeParentEnvironment: false,
    );
    _process = process;
    final ready = Completer<void>();
    final errors = process.stderr.drain<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.length > 8192) return;
          try {
            final data = jsonDecode(line);
            if (data is Map &&
                data['type'] == 'ready' &&
                data['service'] == 'qqm-node-plugin-host' &&
                data['port'] is int) {
              _endpoint = 'http://127.0.0.1:${data['port']}';
              if (!ready.isCompleted) ready.complete();
            }
          } catch (_) {}
        });
    unawaited(
      process.exitCode.then((_) async {
        await errors;
        if (identical(_process, process)) {
          _process = null;
          _endpoint = '';
        }
        if (!ready.isCompleted) {
          ready.completeError(const FormatException('Node 运行器未能启动，请检查系统运行环境。'));
        }
      }),
    );
    await ready.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill();
        throw const FormatException('Node 运行器启动超时。');
      },
    );
    _status('Node $nodeVersion · 本机运行器已就绪');
  }

  Future<String> _npmCli(NodeRuntime runtime) async {
    for (final file in [
      runtime.npmCli,
      '/usr/share/nodejs/npm/bin/npm-cli.js',
    ]) {
      if (await File(file).exists()) return file;
    }
    throw const FormatException('未找到 npm，请安装包含 npm 的 Node.js。');
  }

  Map<String, String> _environment(NodeRuntime runtime) => {
    for (final key in [
      'PATH',
      'SYSTEMROOT',
      'WINDIR',
      'TEMP',
      'TMP',
      'HOME',
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'PROGRAMFILES',
      'QQM_CHROME',
      'QQM_BROWSER_NO_SANDBOX',
    ])
      if (Platform.environment[key] != null) key: Platform.environment[key]!,
    'PATH':
        '${p.dirname(runtime.executable)}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
    'PUPPETEER_SKIP_DOWNLOAD': 'true',
    'PUPPETEER_SKIP_CHROMIUM_DOWNLOAD': 'true',
  };

  Dio _client([Duration? timeout]) => Dio(
    BaseOptions(
      baseUrl: endpoint,
      headers: {'Authorization': 'Bearer $token'},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: timeout ?? const Duration(minutes: 3),
      sendTimeout: const Duration(minutes: 3),
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  );

  Future<Map<String, dynamic>> request(
    String route,
    Map<String, dynamic> data, {
    bool start = true,
  }) async {
    if (start) await ensureStarted();
    final dio = _client();
    try {
      final response = await dio.post<Object>(route, data: data);
      final value = response.data;
      if (value is! Map) throw const FormatException('原版插件运行器返回格式无效。');
      final result = Map<String, dynamic>.from(value);
      if ((response.statusCode ?? 500) >= 300) {
        final error = result['error'];
        throw FormatException(
          error is String && error.length < 300 ? error : '原版插件操作失败，请检查运行环境。',
        );
      }
      return result;
    } on DioException {
      throw const FormatException('原版插件运行器暂时无法连接，请检查地址、网络或运行环境。');
    } finally {
      dio.close(force: true);
    }
  }

  Future<Map<String, dynamic>> inspectFile(
    File file, {
    String? filename,
  }) async {
    if (busy) throw const FormatException('另一个插件任务尚未结束。');
    _busy++;
    _status('检查插件原包');
    try {
      if (await file.length() > 128 * 1024 * 1024) {
        throw const FormatException('原包不能超过 128 MB。');
      }
      await ensureStarted();
      final dio = _client();
      try {
        final response = await dio.post<Object>(
          '/packages/inspect',
          queryParameters: {
            'filename': p.basename(filename ?? file.path),
            'kind':
                RegExp(r'\.[cm]?js$', caseSensitive: false).hasMatch(file.path)
                ? 'js'
                : 'zip',
          },
          data: file.openRead(),
          options: Options(
            contentType: 'application/octet-stream',
            headers: {Headers.contentLengthHeader: await file.length()},
          ),
        );
        if (response.data is! Map || (response.statusCode ?? 500) >= 300) {
          final error = response.data is Map
              ? (response.data as Map)['error']
              : null;
          throw FormatException(error is String ? error : '无法读取插件原包。');
        }
        return Map<String, dynamic>.from(response.data as Map);
      } finally {
        dio.close(force: true);
      }
    } finally {
      _busy--;
      _status('原包检查结束');
    }
  }

  Future<Map<String, dynamic>> inspectRepository(String url) async {
    if (busy) throw const FormatException('另一个插件任务尚未结束。');
    _busy++;
    _status('下载并检查 GitHub 原包');
    try {
      return await request('/packages/repository', {'url': url});
    } finally {
      _busy--;
      _status('原包检查结束');
    }
  }

  Future<Map<String, dynamic>> install(
    String stage, {
    bool replace = false,
  }) async {
    if (busy) throw const FormatException('另一个插件任务尚未结束。');
    _busy++;
    try {
      final job = await request('/packages/install', {
        'stage_id': stage,
        'replace': replace,
        'approved': true,
      });
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      while (DateTime.now().isBefore(deadline)) {
        final state = await request('/packages/job', {'id': job['id']});
        _status(state['phase']?.toString() ?? '安装原包依赖');
        if (state['status'] == 'done') {
          return Map<String, dynamic>.from(state['package'] as Map);
        }
        if (state['status'] == 'failed') {
          throw FormatException(state['error']?.toString() ?? '原包安装失败。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      throw const FormatException('依赖安装耗时过长，请稍后在运行器中检查安装任务。');
    } finally {
      _busy--;
    }
  }

  Future<void> installDependencies(String id) async {
    if (busy) throw const FormatException('另一个插件安装尚未结束。');
    _busy++;
    try {
      final job = await request('/packages/dependencies', {'id': id});
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      while (DateTime.now().isBefore(deadline)) {
        final state = await request('/packages/job', {'id': job['id']});
        _status(state['phase']?.toString() ?? '安装原包依赖');
        if (state['status'] == 'done') return;
        if (state['status'] == 'failed') {
          throw FormatException(state['error']?.toString() ?? '原包依赖安装失败。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      throw const FormatException('原包依赖安装超时。');
    } finally {
      _busy--;
    }
  }

  Future<void> stopLocal() async {
    final process = _process;
    if (process == null) return;
    try {
      await request('/shutdown', {}, start: false);
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    }
    _process = null;
    _endpoint = '';
  }

  Future<void> pause() async {
    if (busy) throw const FormatException('原包依赖正在安装，请完成后再迁移或备份。');
    if (endpoint.isNotEmpty &&
        (await request('/packages/activity', {}, start: false))['busy'] ==
            true) {
      throw const FormatException('原包运行器仍在安装依赖，请结束后再迁移或备份。');
    }
    _paused = true;
    await _starting;
    await stopLocal();
  }

  void resume() {
    _paused = false;
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(stopLocal());
    super.dispose();
  }
}
