import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/plugin_manifest.dart';

class PluginCommandDraft {
  String type;
  String value;
  String reply;
  String scope;
  PluginCommandDraft({
    this.type = 'command',
    this.value = '',
    this.reply = '',
    this.scope = 'all',
  });
}

/// Plugin-only text workspace. Never follows a symlink/junction or executes a source file.
class PluginWorkspace {
  static final Map<String, Future<void>> _operations = {};
  final Directory root;
  static final idPattern = RegExp(r'^[a-z][a-z0-9_]{2,63}$');
  static final filePattern = RegExp(
    r'\.(json|ya?ml|md|txt|ht|js|mjs|py|dart)$',
    caseSensitive: false,
  );
  static const maxBytes = 262144;
  static const maxFiles = 128;
  PluginWorkspace(this.root);

  Future<T> _serial<T>(Future<T> Function() action) {
    final key = Platform.isWindows
        ? p.normalize(root.absolute.path).toLowerCase()
        : p.normalize(root.absolute.path);
    final result = Completer<T>();
    late final Future<void> operation;
    operation = (_operations[key] ?? Future<void>.value())
        .then((_) async {
          try {
            result.complete(await action());
          } catch (error, stack) {
            result.completeError(error, stack);
          }
        })
        .whenComplete(() {
          if (identical(_operations[key], operation)) _operations.remove(key);
        });
    _operations[key] = operation;
    return result.future;
  }

  Future<void> ensureRoot() async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory) {
      throw const PluginManifestException('插件工作区不能是链接或普通文件。');
    }
    await root.create(recursive: true);
  }

  void _validate(String id, [String? relative, bool folder = false]) {
    if (!idPattern.hasMatch(id)) {
      throw const PluginManifestException('插件 ID 需为 3–64 位小写字母、数字和下划线。');
    }
    if (relative == null) return;
    final parts = relative.split('/');
    if (parts.length > 6 ||
        relative.length > 220 ||
        parts.any(
          (part) =>
              !RegExp(
                r'^[A-Za-z0-9_\u4e00-\u9fff][A-Za-z0-9_\u4e00-\u9fff. -]{0,79}$',
              ).hasMatch(part) ||
              part.endsWith('.') ||
              part.endsWith(' ') ||
              RegExp(
                r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                caseSensitive: false,
              ).hasMatch(part),
        )) {
      throw const PluginManifestException('路径无效：最多 6 层，不能使用绝对路径、..、链接或系统保留名称。');
    }
    if (!folder && !filePattern.hasMatch(parts.last)) {
      throw const PluginManifestException(
        '支持 JSON、YAML、Markdown、TXT 和 .ht 脚本；JS/Python/Dart 仅作为文本编辑。',
      );
    }
  }

  Future<String> _checked(
    String id, [
    String? relative,
    bool folder = false,
  ]) async {
    _validate(id, relative, folder);
    await ensureRoot();
    final canonicalRoot = await root.resolveSymbolicLinks();
    var target = root.absolute.path;
    for (final part in [id, ...?relative?.split('/')]) {
      target = p.join(target, part);
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const PluginManifestException('拒绝访问符号链接或目录联接。');
      }
      if (type != FileSystemEntityType.notFound) {
        final real =
            await (type == FileSystemEntityType.directory
                    ? Directory(target)
                    : File(target))
                .resolveSymbolicLinks();
        if (!p.isWithin(canonicalRoot, real)) {
          throw const PluginManifestException('目标超出插件工作区。');
        }
      }
    }
    return target;
  }

  Future<List<String>> projects() async {
    await ensureRoot();
    final result = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory && idPattern.hasMatch(p.basename(entity.path))) {
        await _checked(p.basename(entity.path));
        result.add(p.basename(entity.path));
      }
    }
    return result..sort();
  }

  Future<void> createProject(String id) => _serial(() async {
    final target = await _checked(id);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const PluginManifestException('该项目已存在，请使用其他 ID；不会覆盖原文件。');
    }
    await Directory(target).create();
  });

  Future<List<String>> files(String id) async {
    final directory = Directory(await _checked(id));
    if (!await directory.exists()) return [];
    final result = <String>[];
    var visited = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (++visited > 512) {
        throw const PluginManifestException('项目目录过大，最多支持 512 个目录项。');
      }
      final name = p
          .relative(entity.path, from: directory.path)
          .replaceAll('\\', '/');
      if (entity is File && filePattern.hasMatch(name)) {
        await _checked(id, name);
        result.add(name);
      }
    }
    if (result.length > maxFiles) {
      throw const PluginManifestException('每个项目最多 128 个文本文件。');
    }
    return result..sort();
  }

  Future<String> read(String id, String name) async {
    final file = File(await _checked(id, name));
    if (!await file.exists()) return '';
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const PluginManifestException('文件超过 256 KB，不能在内置编辑器打开。');
      }
      bytes.addAll(chunk);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const PluginManifestException('只能编辑 UTF-8 文本文件。');
    }
  }

  Future<List<String>> folders(String id) async {
    final directory = Directory(await _checked(id));
    if (!await directory.exists()) return [];
    final result = <String>[];
    var count = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (++count > 512) {
        throw const PluginManifestException('项目最多支持 512 个目录项。');
      }
      if (entity is Directory) {
        final name = p
            .relative(entity.path, from: directory.path)
            .replaceAll('\\', '/');
        await _checked(id, name, true);
        result.add(name);
      }
    }
    return result..sort();
  }

  /// [expected] prevents overwriting another editor's later save. Previous content goes to history.
  Future<void> write(
    String id,
    String name,
    String content, {
    String? expected,
    bool createOnly = false,
  }) => _serial(() async {
    if (utf8.encode(content).length > maxBytes) {
      throw const PluginManifestException('文件超过 256 KB。');
    }
    final file = File(await _checked(id, name));
    final exists = await file.exists();
    if (exists && createOnly) {
      throw const PluginManifestException('同名文件已存在，不会覆盖。');
    }
    if (expected != null && (!exists || await read(id, name) != expected)) {
      throw const PluginManifestException('文件已被其他窗口修改，请先备份当前草稿再重新打开。');
    }
    if (!exists && (await files(id)).length >= maxFiles) {
      throw const PluginManifestException('每个插件最多 128 个文本文件。');
    }
    await file.parent.create(recursive: true);
    await _checked(id, name);
    if (exists) await _archive(id, name, move: false);
    final temporary = File(
      p.join(
        file.parent.path,
        '.save-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temporary.writeAsString(content, flush: true);
      await _checked(id, name);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });

  Future<void> createFolder(String id, String name) => _serial(() async {
    final target = await _checked(id, name, true);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const PluginManifestException('同名目录或文件已存在。');
    }
    await Directory(target).create(recursive: true);
  });

  Future<void> renameFile(String id, String from, String to) =>
      _serial(() async {
        final source = File(await _checked(id, from));
        final target = File(await _checked(id, to));
        if (!await source.exists()) {
          throw const PluginManifestException('源文件不存在。');
        }
        if (await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const PluginManifestException('目标已存在，不会覆盖。');
        }
        await target.parent.create(recursive: true);
        await _checked(id, to);
        await source.rename(target.path);
      });

  Future<String> _archive(String id, String name, {required bool move}) async {
    final source = File(await _checked(id, name));
    final history = Directory(p.join(root.path, '_history'));
    if (await FileSystemEntity.type(history.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const PluginManifestException('历史目录不能是链接。');
    }
    await history.create();
    // Automatic history is bounded. No automatic deletion of the user's backups.
    if (await history.list(followLinks: false).take(501).length >= 500) {
      throw const PluginManifestException(
        '本地历史已达 500 份，请通过系统文件管理器备份并整理 _history 后重试。',
      );
    }
    final suffix = String.fromCharCodes(
      name.replaceAll('/', '__').runes.take(100),
    );
    final target = p.join(
      history.path,
      '${DateTime.now().microsecondsSinceEpoch}__${id}__$suffix',
    );
    if (move) {
      await source.rename(target);
    } else {
      await source.copy(target);
    }
    return p.basename(target);
  }

  /// Recoverable delete: files are moved into root/_history, never recursively erased.
  Future<void> deleteFile(String id, String name) => _serial(() async {
    final file = File(await _checked(id, name));
    if (await file.exists()) await _archive(id, name, move: true);
  });

  Future<List<String>> history() async {
    await ensureRoot();
    final directory = Directory(p.join(root.path, '_history'));
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const PluginManifestException('历史目录不能是链接。');
    }
    if (!await directory.exists()) return [];
    final result = <String>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          RegExp(
            r'^\d+__[a-z][a-z0-9_]+__',
          ).hasMatch(p.basename(entity.path))) {
        result.add(p.basename(entity.path));
      }
    }
    return result..sort((a, b) => b.compareTo(a));
  }

  Future<void> restore(String archived, String id, String name) async {
    if (!(await history()).contains(archived)) {
      throw const PluginManifestException('未找到备份。');
    }
    final path = p.join(root.path, '_history', archived);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const PluginManifestException('备份不是普通文件。');
    }
    final bytes = await File(path).readAsBytes();
    if (bytes.length > maxBytes) {
      throw const PluginManifestException('备份超过 256 KB。');
    }
    await write(id, name, utf8.decode(bytes), createOnly: true);
  }

  /// Assemble a project into the same self-contained manifest used by imports.
  Future<String> assembleProject(String id) async {
    final names = await files(id);
    final name = [
      'plugin.json',
      'plugin.yaml',
      'plugin.yml',
    ].where(names.contains).firstOrNull;
    if (name == null) {
      throw const PluginManifestException('项目根目录需要 plugin.json 或 plugin.yaml。');
    }
    final definition = PluginManifest.parse(await read(id, name));
    final data =
        jsonDecode(jsonEncode(definition.data)) as Map<String, dynamic>;
    if (definition.runtime == 'script' && data['entrypoint'] is String) {
      final source = await read(id, data['entrypoint'] as String);
      if (source.trim().isEmpty) {
        throw const PluginManifestException(
          '入口脚本不存在或为空，请检查 entrypoint 和 .ht 文件。',
        );
      }
      (data['script'] as Map)['source'] = source;
    }
    final assembled = const JsonEncoder.withIndent('  ').convert(data);
    PluginManifest.parse(assembled);
    return assembled;
  }

  /// Seed only missing files; never overwrite an existing developer's draft.
  Future<void> seedProject(String id, String source) async {
    final names = await files(id);
    if (names.any(['plugin.json', 'plugin.yaml', 'plugin.yml'].contains)) {
      return;
    }
    final definition = PluginManifest.parse(source);
    final data =
        jsonDecode(jsonEncode(definition.data)) as Map<String, dynamic>;
    if (definition.runtime == 'script') {
      final script = data['script'] as Map;
      final code = script.remove('source');
      final entry = data['entrypoint'] as String? ?? 'main.ht';
      data['entrypoint'] = entry;
      if (code is String && !names.contains(entry)) {
        await write(id, entry, code, createOnly: true);
      }
    }
    await write(
      id,
      'plugin.json',
      const JsonEncoder.withIndent('  ').convert(data),
      createOnly: true,
    );
  }

  static const helloScript = '''
function main(ctx) {
  if (ctx.phase == 'enable') { return null }
  if (ctx.command == 'hello') {
    return '你好，' + clean_name(ctx.message['sender_name']) + '！\\n' + ctx.args.join(' ')
  }
  return null
}
''';

  static String scriptManifest(String id) =>
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'id': id,
        'name': '我的脚本插件',
        'version': '1.0.0',
        'description': '自由编写命令与玩法，保存后应用，无需重新编译',
        'runtime': 'script',
        'entrypoint': 'main.ht',
        'permissions': ['message:read', 'message:send'],
        'script': {
          'language': 'hetu',
          'commands': [
            {'name': 'hello', 'description': '打个招呼', 'usage': 'hello [内容]'},
          ],
        },
        'rules': [],
      });

  static String rulesManifest({
    required String id,
    required String name,
    required String description,
    String author = '',
    required List<PluginCommandDraft> commands,
  }) {
    if (commands.isEmpty) throw const PluginManifestException('至少写一条命令。');
    final source = const JsonEncoder.withIndent('  ').convert({
      'schema_version': 2,
      'id': id,
      'name': name,
      'version': '1.0.0',
      'description': description,
      if (author.trim().isNotEmpty) 'author': author.trim(),
      'runtime': 'rules',
      'permissions': ['message:read', 'message:send'],
      'rules': [
        for (final command in commands)
          {
            'match': {
              'type': command.type,
              'value': command.value.trim(),
              'scope': command.scope,
            },
            'reply': command.reply,
          },
      ],
    });
    PluginManifest.parse(source);
    return source;
  }
}
