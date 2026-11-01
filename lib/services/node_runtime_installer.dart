import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

class NodeRuntime {
  final String executable, version;
  NodeRuntime(this.executable, this.version);
  String get npmCli => Platform.isWindows
      ? p.join(p.dirname(executable), 'node_modules/npm/bin/npm-cli.js')
      : p.normalize(
          p.join(
            p.dirname(executable),
            '../lib/node_modules/npm/bin/npm-cli.js',
          ),
        );
}

/// Original Node plugins need a real Node runtime, not a JS syntax shim.
class NodeRuntimeInstaller {
  static Future<NodeRuntime?> probe(String executable) async {
    try {
      final result = await Process.run(executable, [
        '-p',
        'JSON.stringify({version:process.versions.node,exe:process.execPath})',
      ]).timeout(const Duration(seconds: 5));
      final data = jsonDecode(result.stdout.toString());
      if (result.exitCode == 0 &&
          data is Map &&
          (int.tryParse(data['version'].toString().split('.').first) ?? 0) >=
              22) {
        return NodeRuntime(data['exe'].toString(), data['version'].toString());
      }
    } catch (_) {}
    return null;
  }

  static Future<NodeRuntime> ensure(
    Directory root,
    void Function(String) status,
  ) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      throw const FormatException(
        '手机端请在“Node 运行环境”连接远程运行器。原包中的 SQLite、Canvas 等原生模块需要桌面或服务器环境。',
      );
    }
    final system = await probe(Platform.isWindows ? 'node.exe' : 'node');
    if (system != null) return system;
    final runtime = Directory(p.join(root.path, 'runtime'));
    final binary = p.join(
      runtime.path,
      Platform.isWindows ? 'node.exe' : 'bin/node',
    );
    final installed = await probe(binary);
    if (installed != null) return installed;
    status('下载 Node.js 运行环境');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 3),
        followRedirects: false,
      ),
    );
    try {
      final index = (await dio.get<List<dynamic>>(
        'https://nodejs.org/dist/index.json',
      )).data;
      final release = index
          ?.whereType<Map>()
          .where(
            (r) =>
                r['version'].toString().startsWith('v22.') && r['lts'] != false,
          )
          .firstOrNull;
      if (release == null) {
        throw const FormatException('Node 官方下载列表暂不可用，请安装 Node.js 22 或更新版本后重试。');
      }
      final version = release['version'].toString();
      final platform = Platform.isWindows
          ? 'win'
          : Platform.isMacOS
          ? 'darwin'
          : 'linux';
      final arch = Abi.current().toString().toLowerCase().contains('arm64')
          ? 'arm64'
          : 'x64';
      final filename =
          'node-$version-$platform-$arch.${Platform.isWindows ? 'zip' : 'tar.gz'}';
      final sums =
          (await dio.get<String>(
            'https://nodejs.org/dist/$version/SHASUMS256.txt',
          )).data ??
          '';
      final line = sums
          .split('\n')
          .where((s) => s.trim().endsWith(' $filename'))
          .firstOrNull;
      final expected = line?.trim().split(RegExp(r'\s+')).first;
      if (expected == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) {
        throw const FormatException('未找到当前平台的 Node 下载校验值。');
      }
      final response = await dio.get<List<int>>(
        'https://nodejs.org/dist/$version/$filename',
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (received > 128 * 1024 * 1024) {
            throw const FormatException('Node 运行环境下载过大。');
          }
          if (total > 0) {
            status(
              '下载 Node.js ${(received * 100 / total).clamp(0, 100).floor()}%',
            );
          }
        },
      );
      final bytes = Uint8List.fromList(response.data ?? []);
      if (sha256.convert(bytes).toString() != expected) {
        throw const FormatException('Node 下载校验失败，请重试。');
      }
      status('安装 Node.js 运行环境');
      await Isolate.run(
        () => _extract(bytes, runtime.path, Platform.isWindows),
      );
      if (!Platform.isWindows) await Process.run('chmod', ['u+x', binary]);
      final result = await probe(binary);
      if (result == null) {
        throw const FormatException('Node 运行环境无法启动，请检查操作系统架构或使用系统 Node.js。');
      }
      return result;
    } finally {
      dio.close(force: true);
    }
  }

  static Future<void> _extract(Uint8List bytes, String root, bool zip) async {
    final archive = zip
        ? ZipDecoder().decodeBytes(bytes)
        : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    for (final entry in archive) {
      if (!entry.isFile || entry.isSymbolicLink) continue;
      final parts = entry.name.split('/');
      if (parts.length < 2) continue;
      final relative = parts.skip(1).join('/');
      if (relative != (zip ? 'node.exe' : 'bin/node') &&
          !relative.startsWith(
            zip ? 'node_modules/npm/' : 'lib/node_modules/npm/',
          )) {
        continue;
      }
      if (parts.any((s) => s == '..' || s.isEmpty) ||
          relative.contains('\\') ||
          relative.contains(':')) {
        throw const FormatException('Node 压缩包路径无效。');
      }
      final file = File(p.joinAll([root, ...relative.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.content);
    }
  }
}
