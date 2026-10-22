import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../utils/platforms.dart';

typedef AuxiliaryLauncher =
    Future<void> Function(String executable, Map<String, String> environment);

/// A separate process gives every desktop window its own Flutter engine and
/// WebView. It never opens Hive, bot credentials, the gateway or a second tray.
/// Only a one-use, display-only snapshot is shared in the user's app directory.
class AuxiliaryWindows {
  static const requestVariable = 'QQM_AUXILIARY_WINDOW';
  static const maximumBytes = 32 * 1024 * 1024;
  final Future<Directory> Function() supportDirectory;
  final AuxiliaryLauncher launcher;
  final bool supported;
  final String executable;

  AuxiliaryWindows({
    Future<Directory> Function()? supportDirectory,
    AuxiliaryLauncher? launcher,
    bool? supported,
    String? executable,
  }) : supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       launcher = launcher ?? _launch,
       supported = supported ?? isDesktopPlatform,
       executable = executable ?? Platform.resolvedExecutable;

  static Future<void> _launch(
    String executable,
    Map<String, String> env,
  ) async {
    await Process.start(
      executable,
      const [],
      mode: ProcessStartMode.detached,
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: p.dirname(executable),
      runInShell: false,
    );
  }

  static String? get pendingRequest => Platform.environment[requestVariable];

  Future<void> open(String kind, Map<String, dynamic> data) async {
    if (!supported) throw StateError('当前平台不支持桌面独立窗口');
    if (!{'browser', 'record', 'history'}.contains(kind)) {
      throw const FormatException('独立窗口类型无效');
    }
    final bytes = utf8.encode(jsonEncode({...data, 'schema': 1, 'kind': kind}));
    if (bytes.length > maximumBytes) {
      throw const FormatException('记录过大，无法在独立窗口中打开');
    }
    final root = await supportDirectory();
    final directory = Directory(p.join(root.path, 'auxiliary-windows'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '${const Uuid().v4()}.json'));
    await file.create(exclusive: true);
    try {
      await file.writeAsBytes(bytes, flush: true);
      // No publisher keys, bot tokens or arbitrary environment secrets are
      // forwarded. Keep only OS paths/locales needed by the native runtime.
      const allowed = {
        'PATH',
        'SystemRoot',
        'SYSTEMROOT',
        'WINDIR',
        'TEMP',
        'TMP',
        'TMPDIR',
        'APPDATA',
        'LOCALAPPDATA',
        'USERPROFILE',
        'PROGRAMDATA',
        'HOME',
        'LANG',
        'LC_ALL',
        'USER',
        'LOGNAME',
        'DISPLAY',
        'WAYLAND_DISPLAY',
        'XDG_RUNTIME_DIR',
        'DBUS_SESSION_BUS_ADDRESS',
        'XDG_SESSION_TYPE',
      };
      final environment = <String, String>{
        for (final name in allowed) name: ?Platform.environment[name],
        requestVariable: file.path,
      };
      await launcher(executable, environment);
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> consume(String fileName) async {
    final root = await supportDirectory();
    final directory = Directory(p.join(root.path, 'auxiliary-windows'));
    final file = File(fileName);
    final canonical = await file.resolveSymbolicLinks();
    final parent = await directory.resolveSymbolicLinks();
    if (!p.isWithin(parent, canonical) ||
        !RegExp(r'^[a-f0-9-]{36}\.json$').hasMatch(p.basename(canonical))) {
      throw const FormatException('独立窗口资料路径无效');
    }
    if (await file.length() > maximumBytes) {
      throw const FormatException('独立窗口资料过大');
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic> ||
        data['schema'] != 1 ||
        !{'browser', 'record', 'history'}.contains(data['kind'])) {
      throw const FormatException('独立窗口资料格式无效');
    }
    // The child now owns an in-memory snapshot. Do not retain another copy of
    // the chat on disk after opening, and never delete an unrelated file.
    await file.delete();
    return data;
  }
}
