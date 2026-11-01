import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'extensions.dart';
import 'models.dart';
import 'package_bundle.dart';

/// Source files are a package-scoped virtual workspace. Browsing never runs
/// modules or exposes the application's filesystem; saving validates one full
/// revision so renames and changed imports can be applied together.
class AgentExtensionFiles {
  static const maxTextBytes = 1024 * 1024;
  final String id, kind, manifestName;
  final bool javascript;
  final Map<String, Uint8List> files;
  AgentExtensionFiles._(
    this.id,
    this.kind,
    this.manifestName,
    this.javascript,
    this.files,
  );
  factory AgentExtensionFiles.read(AgentExtension extension) =>
      AgentExtensionFiles._(
        extension.id,
        extension.kind,
        extension.isJavaScript
            ? text(extension.manifest['manifestFile'])
            : '${extension.kind}.json',
        extension.isJavaScript,
        extension.isJavaScript
            ? {
                for (final e in object(extension.manifest['files']).entries)
                  e.key: base64Decode(text(e.value)),
              }
            : {
                '${extension.kind}.json': Uint8List.fromList(
                  utf8.encode(
                    const JsonEncoder.withIndent(
                      '  ',
                    ).convert(extension.manifest),
                  ),
                ),
              },
      );
  String get revision {
    return revisionOf(files);
  }

  static String revisionOf(Map<String, Uint8List> files) {
    final names = files.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              for (final name in names)
                name: sha256.convert(files[name]!).toString(),
            }),
          ),
        )
        .toString();
  }

  static void validatePath(String name) {
    if (name.isEmpty ||
        name.length > 256 ||
        name.contains('\\') ||
        name.contains(RegExp(r'[\x00-\x1f:<>"|?*]')) ||
        name.startsWith('/') ||
        name
            .split('/')
            .any(
              (part) =>
                  part.isEmpty ||
                  part == '.' ||
                  part == '..' ||
                  part.endsWith('.') ||
                  part.endsWith(' ') ||
                  part.toLowerCase() == 'node_modules' ||
                  RegExp(
                    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                    caseSensitive: false,
                  ).hasMatch(part),
            ) ||
        RegExp(
          r'\.(node|dll|exe|so|dylib)$',
          caseSensitive: false,
        ).hasMatch(name)) {
      throw const AgentException('文件路径无效；不能使用绝对路径、..、node_modules或本机二进制文件。');
    }
  }

  String readText(String name) {
    final bytes = files[name];
    if (bytes == null) throw const AgentException('文件不存在。');
    if (bytes.length > maxTextBytes) {
      throw const AgentException('文本超过1MB，请导出后用外部编辑器修改。');
    }
    if (bytes.contains(0)) throw const AgentException('这是二进制文件，只能导出查看。');
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw const AgentException('这是二进制文件，只能导出查看。');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'javascript': javascript,
    'manifestFile': manifestName,
    'revision': revision,
    'files': {for (final e in files.entries) e.key: base64Encode(e.value)},
  };
  AgentExtension updated(
    AgentExtension current,
    Map<String, Uint8List> changed,
  ) {
    if (current.id != id ||
        current.kind != kind ||
        current.isJavaScript != javascript) {
      throw const AgentException('扩展身份已改变，请重新打开文件管理器。');
    }
    if (changed.isEmpty ||
        changed.length > 300 ||
        !changed.containsKey(manifestName)) {
      throw const AgentException('请保留扩展清单，最多支持300个文件。');
    }
    final names = <String>{};
    var total = 0;
    for (final e in changed.entries) {
      validatePath(e.key);
      if (!names.add(e.key.toLowerCase()) ||
          e.value.length > 8 * 1024 * 1024 ||
          (total += e.value.length) > 24 * 1024 * 1024) {
        throw const AgentException('文件重名或超过包大小限制（单文件8MB，合计24MB）。');
      }
      if (e.key != manifestName &&
          {'plugin.json', 'skill.json'}.contains(p.posix.basename(e.key))) {
        throw const AgentException('一个扩展只能保留自己的一个plugin.json或skill.json清单。');
      }
    }
    for (final name in names) {
      final segments = name.split('/');
      for (var i = 1; i < segments.length; i++) {
        if (names.contains(segments.take(i).join('/'))) {
          throw const AgentException('文件与目录路径不能重名。');
        }
      }
    }
    final source = utf8.decode(changed[manifestName]!);
    if (!javascript) {
      if (changed.length != 1) {
        throw const AgentException(
          'JSON/HTTP/Hetu扩展的逻辑保存在清单中；多文件JavaScript请导入原包。',
        );
      }
      final parsed = AgentExtension.parse(source, filename: manifestName);
      if (parsed.id != id || parsed.kind != kind) {
        throw const AgentException('修改源码时请保留当前扩展ID和类型。');
      }
      return current.copyWith(manifest: parsed.manifest);
    }
    final raw = jsonDecode(source);
    if (raw is! Map) throw const AgentException('包清单必须是JSON对象。');
    final manifest = object(raw);
    if (manifest['id'] != id ||
        manifest['apiVersion'] != 1 ||
        text(manifest['name']).isEmpty) {
      throw const AgentException('清单需要apiVersion:1、原始ID和名称。');
    }
    final entry = text(manifest['entry']).isEmpty
        ? 'index.js'
        : text(manifest['entry']);
    if (!entry.endsWith('.js') || !changed.containsKey(entry)) {
      throw const AgentException('JavaScript入口文件不存在。');
    }
    if (changed['package.json'] != null &&
        object(
          object(
            jsonDecode(utf8.decode(changed['package.json']!)),
          )['dependencies'],
        ).isNotEmpty) {
      throw const AgentException('请使用自包含源码；宿主不会安装npm或本机二进制依赖。');
    }
    final normalized = AgentPackageBundle(
      manifest,
      {for (final e in changed.entries) e.key: base64Encode(e.value)},
      kind,
      manifestName,
    ).normalized();
    return current.copyWith(manifest: normalized);
  }
}
