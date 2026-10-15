import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/app_release.dart';
import '../utils/constants.dart';
import 'update_preferences.dart';

enum UpdatePhase {
  idle,
  checking,
  available,
  downloading,
  ready,
  installing,
  failed,
}

class AppUpdateService extends ChangeNotifier {
  static const defaultServer = String.fromEnvironment(
    'UPDATE_BASE_URL',
    defaultValue: 'https://botmanager.uuze.cn',
  );
  static const defaultKey = String.fromEnvironment('UPDATE_PUBLIC_KEY');
  static const _native = MethodChannel('cn.uuze.botmanager/updates');
  final UpdatePreferences preferences;
  final Dio _http;
  final Uri server;
  final String publicKey, platform, arch;
  final int currentBuild;
  final String currentVersion;
  final Future<Directory> Function() _supportDirectory;
  final Future<Map<String, String>> Function() _deviceInfoProvider;
  Future<Map<String, String>>? _deviceInfo;
  Timer? _updateTimer, _usageTimer;
  CancelToken? _downloadCancel;
  bool _disposed = false, _started = false, _usageBusy = false;
  AppRelease? release;
  UpdatePhase phase = UpdatePhase.idle;
  String error = '', usageStatus = '';
  double progress = 0;
  File? downloadedFile;
  int dismissedBuild = 0;

  AppUpdateService(
    this.preferences, {
    Dio? http,
    Uri? server,
    this.publicKey = defaultKey,
    String? platform,
    String? arch,
    this.currentBuild = AppConstants.appBuild,
    this.currentVersion = AppConstants.appVersion,
    Future<Directory> Function()? supportDirectory,
    Future<Map<String, String>> Function()? deviceInfoProvider,
  }) : _http =
           http ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 5),
               receiveTimeout: const Duration(seconds: 10),
               followRedirects: false,
             ),
           ),
       server = server ?? Uri.parse(defaultServer),
       platform =
           platform ??
           (Platform.isWindows
               ? 'windows'
               : Platform.isAndroid
               ? 'android'
               : Platform.isIOS
               ? 'ios'
               : Platform.isMacOS
               ? 'macos'
               : 'unsupported'),
       arch =
           arch ??
           (Platform.isWindows
               ? 'x64'
               : Platform.isIOS
               ? 'arm64'
               : 'universal'),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _deviceInfoProvider = deviceInfoProvider ?? _readDeviceInfo;

  bool get configured {
    try {
      return server.scheme == 'https' &&
          server.host.isNotEmpty &&
          server.userInfo.isEmpty &&
          server.path.replaceAll('/', '').isEmpty &&
          base64Decode(publicKey).length == 32 &&
          platform != 'unsupported';
    } catch (_) {
      return false;
    }
  }

  bool get busy => {
    UpdatePhase.checking,
    UpdatePhase.downloading,
    UpdatePhase.installing,
  }.contains(phase);
  bool get hasUpdate => release != null && release!.build > currentBuild;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    if (!configured) return;
    unawaited(check());
    unawaited(sendHeartbeat());
    _updateTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(check()),
    );
    _usageTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(sendHeartbeat()),
    );
  }

  Uri _url(String path, [Map<String, String>? query]) =>
      server.replace(path: path, queryParameters: query);

  Future<Map<String, dynamic>> _json(
    String path, {
    String method = 'GET',
    Map<String, String>? query,
    Map<String, dynamic>? data,
    String? token,
  }) async {
    final response = await _http.requestUri<ResponseBody>(
      _url(path, query),
      data: data,
      options: Options(
        method: method,
        responseType: ResponseType.stream,
        followRedirects: false,
        headers: token == null ? {} : {'Authorization': 'Bearer $token'},
        receiveTimeout: const Duration(seconds: 10),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final bytes = BytesBuilder(copy: false);
    final body = response.data;
    if (body == null) throw const FormatException('接口响应为空');
    await for (final chunk in body.stream.timeout(
      const Duration(seconds: 10),
    )) {
      if (bytes.length + chunk.length > 65536) {
        throw const FormatException('接口响应过大');
      }
      bytes.add(chunk);
    }
    return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
  }

  Future<void> check() async {
    if (!configured || busy || _disposed) return;
    final previous = phase;
    phase = UpdatePhase.checking;
    error = '';
    _changed();
    try {
      final nonce = const Uuid().v4();
      final envelope = await _json(
        '/api/v1/update',
        query: {'platform': platform, 'arch': arch, 'nonce': nonce},
      );
      final found = await AppRelease.verifyEnvelope(
        envelope,
        publicKey: publicKey,
        nonce: nonce,
        platform: platform,
        arch: arch,
        server: server,
      );
      if (_disposed) return;
      if (found == null || found.build <= currentBuild) {
        release = null;
        downloadedFile = null;
        phase = UpdatePhase.idle;
      } else {
        final same =
            found.build == release?.build && found.sha256 == release?.sha256;
        release = found;
        if (!same) downloadedFile = null;
        phase = downloadedFile == null
            ? UpdatePhase.available
            : UpdatePhase.ready;
      }
      _changed();
      if (hasUpdate &&
          phase == UpdatePhase.available &&
          ((platform == 'windows' && preferences.autoDownload) ||
              release?.forceUpdate == true)) {
        await download();
      }
    } catch (exception) {
      if (_disposed) return;
      phase = previous == UpdatePhase.ready
          ? UpdatePhase.ready
          : UpdatePhase.failed;
      error = exception is FormatException
          ? exception.message
          : '检查更新失败，请检查网站部署、网络和系统时间后重试';
      _changed();
    }
  }

  Future<void> setAutoDownload(bool value) async {
    await preferences.setAutoDownload(value);
    _changed();
  }

  void dismiss() {
    if (release?.forceUpdate == true) return;
    dismissedBuild = release?.build ?? 0;
    _changed();
  }

  Future<File> _target(AppRelease selected) async {
    final root = await _supportDirectory();
    final directory = Directory(
      p.join(
        root.path,
        'updates',
        '${selected.build}-${selected.sha256.substring(0, 12)}',
      ),
    );
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'package.${selected.format}'));
  }

  static Future<bool> validFile(File file, AppRelease selected) async {
    if (!await file.exists() || await file.length() != selected.size) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() ==
        selected.sha256;
  }

  Future<void> download() async {
    final selected = release;
    if (!configured || selected == null || !hasUpdate || busy || _disposed) {
      return;
    }
    phase = UpdatePhase.downloading;
    progress = 0;
    error = '';
    _changed();
    final cancel = CancelToken();
    _downloadCancel = cancel;
    File? part;
    try {
      final target = await _target(selected);
      if (!await validFile(target, selected)) {
        part = File('${target.path}.part');
        await _http
            .downloadUri(
              selected.url,
              part.path,
              cancelToken: cancel,
              options: Options(
                followRedirects: false,
                receiveTimeout: const Duration(seconds: 30),
                validateStatus: (status) => status == 200,
              ),
              onReceiveProgress: (received, _) {
                if (received > selected.size) {
                  cancel.cancel('size limit');
                  return;
                }
                progress = received / selected.size;
                _changed();
              },
            )
            .timeout(
              const Duration(minutes: 15),
              onTimeout: () {
                cancel.cancel('timeout');
                throw TimeoutException('下载超时');
              },
            );
        if (!await validFile(part, selected)) {
          throw const FormatException('安装包大小或 SHA-256 校验失败，已阻止安装');
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        part = null;
      }
      if (!_disposed) {
        downloadedFile = target;
        progress = 1;
        phase = UpdatePhase.ready;
        _changed();
      }
    } catch (exception) {
      if (!_disposed) {
        phase = UpdatePhase.failed;
        error = exception is FormatException
            ? exception.message
            : '下载未完成，请重试；不会执行未通过校验的文件';
        _changed();
      }
    } finally {
      try {
        if (part != null && await part.exists()) await part.delete();
      } on PathNotFoundException {
        // Dio can remove a cancelled download between exists() and delete().
      } finally {
        _downloadCancel = null;
      }
    }
  }

  Future<void> install({Future<void> Function()? exitForUpdate}) async {
    final selected = release;
    final file = downloadedFile;
    if (selected == null ||
        file == null ||
        phase != UpdatePhase.ready ||
        !configured) {
      return;
    }
    if (!await validFile(file, selected)) {
      phase = UpdatePhase.failed;
      error = '安装包已变化，需重新下载';
      downloadedFile = null;
      _changed();
      return;
    }
    phase = UpdatePhase.installing;
    error = '';
    _changed();
    try {
      if (platform == 'windows') {
        if (exitForUpdate == null) throw const FormatException('当前窗口不支持重启更新');
        final cache = p.dirname(file.path);
        final script = File(p.join(cache, 'windows-update.ps1'));
        await script.writeAsString(
          '\ufeff${await rootBundle.loadString('assets/updater/windows-update.ps1')}',
          flush: true,
        );
        final request = File(p.join(cache, 'request.json'));
        final ready = File(p.join(cache, 'ready-${const Uuid().v4()}.json'));
        final executable = Platform.resolvedExecutable;
        await request.writeAsString(
          jsonEncode({
            'schema': 1,
            'pid': pid,
            'executable': executable,
            'installDir': p.dirname(executable),
            'package': file.path,
            'sha256': selected.sha256,
            'format': selected.format,
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
          // Windows PowerShell can exit immediately under Dart's DETACHED_PROCESS
          // flags. A normal child with hidden window/stdio survives parent exit
          // on Windows and supports the ready handshake and diagnostics.
          mode: ProcessStartMode.normal,
          runInShell: false,
          // A PowerShell 7 terminal can export an incompatible PSModulePath.
          // This child only needs the trusted, built-in Windows PowerShell modules.
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
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!await ready.exists()) {
          if (DateTime.now().isAfter(deadline)) {
            throw const FormatException('更新准备超时，原程序保持运行；请查看更新缓存日志');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        final result =
            jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
        if (result['ready'] != true) {
          throw FormatException(result['error']?.toString() ?? '更新准备失败');
        }
        await exitForUpdate();
        // If the window could not close, never leave the update UI stuck.
        if (!_disposed) {
          phase = UpdatePhase.ready;
          _changed();
        }
      } else if (platform == 'macos') {
        // The validated DMG is handed to Finder, not a shell or auto installer.
        final opened = await Process.run('/usr/bin/open', [
          file.path,
        ], runInShell: false);
        if (opened.exitCode != 0) {
          throw const FormatException('系统未能打开 DMG，请稍后重试');
        }
        if (!_disposed) {
          phase = UpdatePhase.ready;
          _changed();
        }
      } else {
        await _native.invokeMethod<void>(
          platform == 'android' ? 'installApk' : 'shareIpa',
          {'path': file.path, 'build': selected.build},
        );
        if (!_disposed) {
          phase = UpdatePhase.ready;
          _changed();
        }
      }
    } catch (exception) {
      if (!_disposed) {
        phase = UpdatePhase.ready;
        error = exception is FormatException
            ? exception.message
            : exception is PlatformException
            ? (exception.message ?? '系统未能打开安装界面')
            : '无法开始更新，请确认目录可写或重新下载';
        _changed();
      }
    }
  }

  static const deviceFieldLimits = {
    'device_name': 128,
    'device_model': 128,
    'system_version': 255,
    'system_arch': 64,
  };

  static Future<Map<String, String>> _readDeviceInfo() async {
    final result = <String, String>{
      'system_version': Platform.operatingSystemVersion,
      'system_arch': Abi.current().toString(),
    };
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final mobile = await _native.invokeMapMethod<String, String>(
          'deviceInfo',
        );
        if (mobile != null) result.addAll(mobile);
      } on PlatformException {
        // Basic statistics still work when a platform cannot supply a name.
      } on MissingPluginException {
        // Older native shells do not implement deviceInfo.
      }
    } else {
      try {
        result['device_name'] = Platform.localHostname;
      } on OSError {
        // Do not request elevated permissions just to obtain a computer name.
      }
    }
    return result;
  }

  Future<Map<String, String>> _safeDeviceInfo() async {
    try {
      final supplied = await _deviceInfoProvider();
      return {
        for (final entry in deviceFieldLimits.entries)
          if (supplied[entry.key] case final String value)
            entry.key: String.fromCharCodes(
              value
                  .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '')
                  .trim()
                  .runes
                  .take(entry.value),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> _usageFields() async => {
    'platform': platform,
    'version': currentVersion,
    'build': currentBuild,
    ...await (_deviceInfo ??= _safeDeviceInfo()),
  };

  Future<void> setUsageConsent(bool value) async {
    // Persist opt-out before any network work; an in-flight heartbeat cannot re-enable it.
    await preferences.setUsageConsent(value);
    if (!value) {
      final token = preferences.token;
      if (token.isNotEmpty) await preferences.setPendingDeletion(token);
      await preferences.clearInstallation();
    }
    _changed();
    await sendHeartbeat();
  }

  Future<void> sendHeartbeat() async {
    if (!configured || _disposed || _usageBusy) return;
    _usageBusy = true;
    var attemptedDeletion = false;
    try {
      if (preferences.pendingDeletion.isNotEmpty) {
        attemptedDeletion = true;
        try {
          await _json(
            '/api/v1/telemetry/installation',
            method: 'DELETE',
            token: preferences.pendingDeletion,
          );
        } on DioException catch (error) {
          if (error.response?.statusCode != 401) rethrow;
        }
        await preferences.setPendingDeletion('');
      }
      if (preferences.usageConsent != true) {
        usageStatus = '使用统计未开启';
        return;
      }
      final fields = await _usageFields();
      // Opt-out may happen while the native device-info call is in flight.
      if (!preferences.usageConsent || _disposed) return;
      if (preferences.token.isEmpty) {
        final id = const Uuid().v4();
        final result = await _json(
          '/api/v1/telemetry/register',
          method: 'POST',
          data: {...fields, 'installation_id': id, 'consent_version': '2'},
        );
        final token = result['token'];
        if (token is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
          throw const FormatException('统计令牌格式无效');
        }
        if (preferences.usageConsent != true || _disposed) {
          await preferences.setPendingDeletion(token);
          return;
        }
        await preferences.setInstallation(id, token);
        if (!preferences.usageConsent || _disposed) {
          await preferences.setPendingDeletion(token);
          await preferences.clearInstallation();
          return;
        }
      }
      if (preferences.usageConsent == true) {
        await _json(
          '/api/v1/telemetry/heartbeat',
          method: 'POST',
          data: fields,
          token: preferences.token,
        );
        usageStatus = preferences.usageConsent == true
            ? '已上报设备名称／型号、系统与软件版本'
            : '已停止上报，正在删除旧统计';
      }
    } on DioException catch (exception) {
      if (exception.response?.statusCode == 401 &&
          preferences.usageConsent == true) {
        await preferences.clearInstallation();
      }
      usageStatus = preferences.usageConsent == true
          ? '统计暂不可用，不影响聊天与更新'
          : '已停止上报；删除请求将在网络恢复后重试';
    } catch (_) {
      usageStatus = '统计暂不可用，不影响聊天与更新';
    } finally {
      _usageBusy = false;
      _changed();
      if (!_disposed &&
          !attemptedDeletion &&
          preferences.usageConsent != true &&
          preferences.pendingDeletion.isNotEmpty) {
        unawaited(sendHeartbeat());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _updateTimer?.cancel();
    _usageTimer?.cancel();
    _downloadCancel?.cancel('disposed');
    _http.close(force: true);
    super.dispose();
  }
}
