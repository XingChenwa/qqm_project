import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'models.dart';

/// An imported package is data, not an archive extracted into the app directory.
/// Original source bytes are retained; entry modules run only inside QuickJS.
class AgentPackageBundle {
  final Json manifest;
  final Map<String, String> files;
  final String kind, manifestFile;
  AgentPackageBundle(this.manifest, this.files, this.kind, this.manifestFile);

  static AgentPackageBundle decode(List<int> bytes) {
    if (bytes.length > 16 * 1024 * 1024) {
      throw const AgentException('ZIP 安装包不能超过 16 MB。');
    }
    try {
      _preflightZip(bytes);
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      if (zip.length > 300) throw const AgentException('安装包文件数不能超过 300 个。');
      var size = 0;
      final names = <String>{};
      for (final f in zip) {
        final n = f.name;
        size += f.size;
        if (size > 24 * 1024 * 1024 || f.size > 8 * 1024 * 1024) {
          throw const AgentException('安装包解压后过大。');
        }
        if (n.length > 256 ||
            n.contains('\\') ||
            n.contains('\u0000') ||
            n.startsWith('/') ||
            n.contains(':') ||
            n.split('/').contains('..') ||
            f.isSymbolicLink ||
            !names.add(n.toLowerCase())) {
          throw const AgentException('安装包包含不安全或重复的路径。');
        }
      }
      final manifests = zip.files
          .where(
            (f) =>
                f.isFile &&
                {
                  'skill.json',
                  'plugin.json',
                }.contains(path.posix.basename(f.name)),
          )
          .toList();
      if (manifests.length != 1) {
        throw const AgentException('ZIP 需要且只能包含一个 skill.json 或 plugin.json。');
      }
      final m = manifests.single;
      final json = object(jsonDecode(utf8.decode(m.content as List<int>)));
      if (!safeId(text(json['id'])) ||
          json['apiVersion'] != 1 ||
          text(json['name']).isEmpty) {
        throw const AgentException(
          '需要 apiVersion: 1、有效 id 和 name 的 QQ Agent 安装包。',
        );
      }
      final root = path.posix.dirname(m.name);
      final prefix = root == '.' ? '' : '$root/';
      final files = <String, String>{};
      for (final f in zip.files.where(
        (f) => f.isFile && f.name.startsWith(prefix),
      )) {
        final n = f.name.substring(prefix.length);
        if (n.split('/').contains('node_modules') ||
            RegExp(
              r'\.(node|dll|exe|so|dylib)$',
              caseSensitive: false,
            ).hasMatch(n)) {
          throw const AgentException(
            '手机端不支持原生二进制依赖或 node_modules，请提供自包含的 JavaScript 包。',
          );
        }
        files[n] = base64Encode(f.content as List<int>);
      }
      final entry = text(json['entry']).isEmpty
          ? 'index.js'
          : text(json['entry']);
      if (!files.containsKey(entry) || !entry.endsWith('.js')) {
        throw const AgentException('安装包缺少 JavaScript 入口。');
      }
      final npm = files['package.json'];
      if (npm != null) {
        final value = object(jsonDecode(utf8.decode(base64Decode(npm))));
        if (object(value['dependencies']).isNotEmpty) {
          throw const AgentException('当前兼容层不在线安装 npm 依赖，请将依赖打包为独立 ESM 源码。');
        }
      }
      return AgentPackageBundle(
        json,
        files,
        path.posix.basename(m.name) == 'skill.json' ? 'skill' : 'plugin',
        path.posix.basename(m.name),
      );
    } on AgentException {
      rethrow;
    } catch (_) {
      throw const AgentException('ZIP 格式无效，或文件无法安全读取。');
    }
  }

  Json normalized() => {
    'schema': 1,
    'runtime': 'qq-agent-js',
    'id': manifest['id'],
    'name': manifest['name'],
    'kind': kind,
    'description': manifest['description'] ?? '',
    'version': manifest['version'] ?? '',
    'entry': manifest['entry'] ?? 'index.js',
    'packageManifest': manifest,
    'manifestFile': manifestFile,
    'files': files,
    'tools': <Json>[],
  };

  static Uint8List encode(Json normalized, Json settings) {
    final files = object(normalized['files']);
    final archive = Archive();
    final filename = text(normalized['manifestFile']);
    for (final e in files.entries) {
      final bytes = e.key == filename
          ? utf8.encode(
              const JsonEncoder.withIndent('  ').convert({
                ...object(normalized['packageManifest']),
                'settings': settings,
              }),
            )
          : base64Decode(text(e.value));
      archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}

// Inspect the central directory BEFORE ZipDecoder's CRC verification inflates
// entries. ZIP64/encryption/multi-volume archives are intentionally unsupported.
void _preflightZip(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);
  var end = -1;
  for (
    var at = bytes.length - 22;
    at >= 0 && at >= bytes.length - 65557;
    at--
  ) {
    if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == bytes.length) {
      end = at;
      break;
    }
  }
  if (end < 0 ||
      u16(end + 4) != 0 ||
      u16(end + 6) != 0 ||
      u16(end + 8) != u16(end + 10) ||
      u16(end + 10) > 300) {
    throw const AgentException('ZIP 目录无效或文件过多。');
  }
  final count = u16(end + 10),
      directorySize = u32(end + 12),
      offset = u32(end + 16);
  if (count == 65535 || offset + directorySize != end) {
    throw const AgentException('不支持 ZIP64 或分卷压缩包。');
  }
  var at = offset, total = 0;
  for (var i = 0; i < count; i++) {
    if (at + 46 > end || u32(at) != 0x02014b50 || u16(at + 8) & 1 != 0) {
      throw const AgentException('ZIP 目录无效或包含加密文件。');
    }
    final size = u32(at + 24), compressed = u32(at + 20);
    total += size;
    if (size > 8 * 1024 * 1024 ||
        total > 24 * 1024 * 1024 ||
        compressed == 0xffffffff ||
        u32(at + 42) >= offset) {
      throw const AgentException('安装包解压后过大或文件目录无效。');
    }
    at += 46 + u16(at + 28) + u16(at + 30) + u16(at + 32);
  }
  if (at != end) throw const AgentException('ZIP 目录长度不匹配。');
}
