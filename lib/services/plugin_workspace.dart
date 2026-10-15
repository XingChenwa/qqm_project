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

/// Local text files for a plugin project. Paths stay inside [root].
class PluginWorkspace {
  final Directory root;
  static final idPattern = RegExp(r'^[a-z][a-z0-9_]{2,63}$');
  static final filePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.(json|ya?ml|md|txt)$',
  );
  PluginWorkspace(this.root);

  Future<void> ensureRoot() => root.create(recursive: true);

  Future<List<String>> projects() async {
    if (!await root.exists()) return [];
    final names = <String>[];
    await for (final entity in root.list()) {
      if (entity is Directory && idPattern.hasMatch(p.basename(entity.path))) {
        names.add(p.basename(entity.path));
      }
    }
    names.sort();
    return names;
  }

  Directory _project(String id) {
    if (!idPattern.hasMatch(id)) {
      throw const PluginManifestException('插件 ID 需为小写字母开头，可含数字和下划线。');
    }
    final directory = Directory(p.join(root.path, id));
    final rootPath = p.normalize(root.absolute.path);
    final projectPath = p.normalize(directory.absolute.path);
    if (!p.isWithin(rootPath, projectPath)) {
      throw const PluginManifestException('插件目录超出工作区。');
    }
    return directory;
  }

  File _file(String id, String name) {
    if (!filePattern.hasMatch(name)) {
      throw const PluginManifestException('只能编辑 json、yaml、md、txt 文本文件。');
    }
    final file = File(p.join(_project(id).path, name));
    final projectPath = p.normalize(_project(id).absolute.path);
    final filePath = p.normalize(file.absolute.path);
    if (!p.isWithin(projectPath, filePath)) {
      throw const PluginManifestException('文件路径无效。');
    }
    return file;
  }

  Future<List<String>> files(String id) async {
    final directory = _project(id);
    if (!await directory.exists()) return [];
    final names = <String>[];
    await for (final entity in directory.list()) {
      if (entity is File && filePattern.hasMatch(p.basename(entity.path))) {
        names.add(p.basename(entity.path));
      }
    }
    names.sort();
    return names;
  }

  Future<String> read(String id, String name) async {
    final file = _file(id, name);
    if (!await file.exists()) return '';
    if (await file.length() > 262144) {
      throw const PluginManifestException('文件超过 256 KB，不能在内置编辑器打开。');
    }
    return file.readAsString();
  }

  Future<void> write(String id, String name, String content) async {
    if (utf8.encode(content).length > 262144) {
      throw const PluginManifestException('文件超过 256 KB。');
    }
    final directory = _project(id);
    await directory.create(recursive: true);
    final existing = await files(id);
    final file = _file(id, name);
    if (!existing.contains(name) && existing.length >= 32) {
      throw const PluginManifestException('每个插件最多 32 个文本文件。');
    }
    await file.writeAsString(content);
  }

  Future<void> deleteFile(String id, String name) async {
    final file = _file(id, name);
    if (await file.exists()) await file.delete();
  }

  static String rulesManifest({
    required String id,
    required String name,
    required String description,
    String author = '',
    required List<PluginCommandDraft> commands,
  }) {
    if (commands.isEmpty) {
      throw const PluginManifestException('至少写一条命令。');
    }
    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
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
  }
}
