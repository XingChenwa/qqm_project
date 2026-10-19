import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/plugin_manager.dart';
import '../../models/plugin.dart';
import '../../models/plugin_manifest.dart';
import '../../services/plugin_workspace.dart';
import 'app_dialogs.dart';
import 'plugin_import_dialog.dart';

class PluginWorkshop extends StatefulWidget {
  final PluginManager manager;
  final Directory root;
  final String? initialId;
  const PluginWorkshop({
    super.key,
    required this.manager,
    required this.root,
    this.initialId,
  });
  @override
  State<PluginWorkshop> createState() => _PluginWorkshopState();
}

class _PluginWorkshopState extends State<PluginWorkshop> {
  late final PluginWorkspace _workspace = PluginWorkspace(widget.root);
  final _editor = TextEditingController();
  List<String> _projects = [], _files = [], _folders = [];
  String _folder = '';
  String? _project, _file, _error;
  String _saved = '';
  bool _busy = true;
  bool _showFiles = false;
  int _revision = 0;
  bool get _dirty => _file != null && _editor.text != _saved;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_changed);
    _guard(() => _reload(select: widget.initialId));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _revision++;
    _editor.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PluginManifestException
              ? e.message
              : '文件操作失败，请检查权限、编码与磁盘空间。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _leave() async {
    if (!_dirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('文件尚未保存'),
        content: const Text('离开前如何处理当前草稿？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'cancel'),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'discard'),
            child: const Text('放弃草稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, 'save'),
            child: const Text('保存后继续'),
          ),
        ],
      ),
    );
    if (choice == 'discard') return true;
    return choice == 'save' && await _save();
  }

  Future<void> _reload({String? select}) async {
    final projects = await _workspace.projects();
    if (!mounted) return;
    setState(() => _projects = projects);
    if (projects.isEmpty) {
      setState(() => _showFiles = true);
    }
    final chosen =
        select ?? _project ?? (projects.isEmpty ? null : projects.first);
    if (chosen != null && projects.contains(chosen)) await _loadProject(chosen);
  }

  Future<void> _loadProject(String id, {String? select}) async {
    final token = ++_revision;
    final files = await _workspace.files(id);
    final folders = await _workspace.folders(id);
    final name = select != null && files.contains(select)
        ? select
        : files.contains('plugin.json')
        ? 'plugin.json'
        : files.firstOrNull;
    final content = name == null ? '' : await _workspace.read(id, name);
    if (!mounted || token != _revision) return;
    setState(() {
      if (_project != id || !folders.contains(_folder)) _folder = '';
      _project = id;
      _files = files;
      _folders = folders;
      _file = name;
      _saved = content;
      _editor.text = content;
    });
  }

  Future<void> _selectProject(String id) async {
    if (_busy || id == _project || !await _leave()) return;
    await _guard(() => _loadProject(id));
  }

  Future<void> _selectFile(String name) async {
    if (_busy) return;
    if (name == _file) {
      setState(() => _showFiles = false);
      return;
    }
    if (!await _leave()) return;
    await _guard(() async {
      final token = ++_revision;
      final project = _project!;
      final content = await _workspace.read(project, name);
      if (!mounted || token != _revision) return;
      setState(() {
        _file = name;
        _saved = content;
        _editor.text = content;
        _showFiles = false;
      });
    });
  }

  Future<bool> _save() async {
    final project = _project, file = _file;
    if (project == null || file == null) return false;
    final content = _editor.text;
    var saved = false;
    await _guard(() async {
      await _workspace.write(project, file, content, expected: _saved);
      if (mounted) setState(() => _saved = content);
      saved = true;
    });
    return saved;
  }

  Future<void> _install() async {
    if (_dirty && !await _save()) return;
    await _guard(() async {
      final source = await _workspace.assembleProject(_project!);
      if (!mounted) return;
      final installed = await showDialog<bool>(
        context: context,
        builder: (_) =>
            PluginImportDialog(manager: widget.manager, initialSource: source),
      );
      if (mounted && installed == true) {
        AppDialogs.show(context, '已安装并停用，请检查配置后手动启用。');
      }
    });
  }

  Future<String?> _ask(String title, String initial, String hint) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) =>
          _WorkspaceNameDialog(title: title, initial: initial, hint: hint),
    );
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _create({bool script = false}) async {
    if (!await _leave() || !mounted) return;
    final id = await _ask('新建插件项目', 'my_hello', '小写字母、数字、下划线，不能覆盖已有项目');
    if (id == null) return;
    await _guard(() async {
      final source = script
          ? PluginWorkspace.scriptManifest(id)
          : PluginWorkspace.rulesManifest(
              id: id,
              name: '我的命令插件',
              description: '可以编辑规则、消息格式和权限',
              commands: [
                PluginCommandDraft(
                  value: 'hello',
                  reply: '你好，{{sender_name}}！\n你说的是：{{args}}',
                ),
              ],
            );
      await _workspace.createProject(id);
      await _workspace.write(id, 'plugin.json', source, createOnly: true);
      if (script) {
        await _workspace.write(
          id,
          'main.ht',
          PluginWorkspace.helloScript,
          createOnly: true,
        );
      }
      await _workspace.write(
        id,
        'readme.md',
        '# 我的命令插件\n\n发送 /hello 内容 或 #hello 内容。\n\n在 main.ht 编写脚本逻辑，或使用 JSON/YAML 规则与 HTTP 插件。保存后点击「应用到插件中心」，检查配置后启用。导出完整插件请使用插件中心的清单导出。JS/Python/Dart 文件仅作为参考文本。\n',
        createOnly: true,
      );
      await _reload(select: id);
      if (mounted) setState(() => _showFiles = false);
    });
  }

  Future<void> _newFile({bool folder = false}) async {
    if (!await _leave() || !mounted) return;
    final name = await _ask(
      folder ? '新建文件夹' : '新建文本文件',
      '${_folder.isEmpty ? '' : '$_folder/'}${folder ? 'assets' : 'notes.md'}',
      '支持相对路径，例如 docs/readme.md',
    );
    if (name == null) return;
    await _guard(() async {
      if (folder) {
        await _workspace.createFolder(_project!, name);
      } else {
        await _workspace.write(_project!, name, '', createOnly: true);
      }
      await _loadProject(_project!, select: folder ? _file : name);
      if (folder && mounted) setState(() => _folder = name);
      if (!folder && mounted) setState(() => _showFiles = false);
    });
  }

  Future<void> _rename() async {
    if (!await _leave() || !mounted) return;
    final name = await _ask('重命名 / 移动文件', _file!, '支持 docs/readme.md；不会覆盖同名文件');
    if (name == null || name == _file) return;
    await _guard(() async {
      await _workspace.renameFile(_project!, _file!, name);
      await _loadProject(_project!, select: name);
    });
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移入本地历史？'),
        content: Text('${_file!}\n未保存的草稿将被放弃。磁盘文件会保留在历史中，可以恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移入历史'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await _guard(() async {
      await _workspace.deleteFile(_project!, _file!);
      await _loadProject(_project!);
    });
  }

  Future<void> _history() async {
    await _guard(() async {
      final entries = (await _workspace.history())
          .where((name) => name.contains('__${_project!}__'))
          .toList();
      if (!mounted) return;
      final archived = await showDialog<String>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: const Text('本地历史（恢复为新文件）'),
          children: entries.isEmpty
              ? [
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('暂无历史。保存和移除文件都会保留一份。'),
                  ),
                ]
              : [
                  for (final name in entries.take(100))
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialog, name),
                      child: Text(name),
                    ),
                ],
        ),
      );
      if (archived == null || !mounted) return;
      if (!await _leave() || !mounted) return;
      final name = await _ask('恢复为新文件', 'restored.txt', '同名文件不会被覆盖');
      if (name == null) return;
      await _workspace.restore(archived, _project!, name);
      await _loadProject(_project!, select: name);
    });
  }

  Future<void> _importFile() async {
    if (!await _leave()) return;
    await _guard(() async {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'ht',
          'json',
          'yaml',
          'yml',
          'md',
          'txt',
          'js',
          'mjs',
          'py',
          'dart',
        ],
        withData: true,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      if (file.size > PluginWorkspace.maxBytes) {
        throw const PluginManifestException('导入文件不能超过 256 KB。');
      }
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null || bytes.length > PluginWorkspace.maxBytes) {
        throw const PluginManifestException('文件无法读取或超过 256 KB。');
      }
      final name = await _ask('导入到项目', file.name, '相对路径；不会覆盖已有文件');
      if (name == null) return;
      await _workspace.write(
        _project!,
        name,
        utf8.decode(bytes),
        createOnly: true,
      );
      await _loadProject(_project!, select: name);
    });
  }

  Future<void> _exportFile() async {
    await _guard(() async {
      await FilePicker.saveFile(
        fileName: _file!.split('/').last,
        bytes: utf8.encode(_editor.text),
      );
    });
  }

  Future<void> _preview() async {
    await _guard(() async {
      if (_dirty && !await _save()) return;
      final source = await _workspace.assembleProject(_project!);
      if (!mounted) return;
      final text = await _ask('本地试运行（不发送 QQ）', '/hello 测试', '测试命令');
      if (text == null) return;
      final result = await widget.manager.previewPlugin(
        source,
        PluginMessage(
          messageId: 'test',
          sessionId: 'test-group',
          senderId: 'test-member',
          senderName: '测试用户',
          senderRole: 'owner',
          isMentioned: true,
          content: text,
          messageType: 0,
          isGroup: true,
          timestamp: DateTime.now(),
        ),
      );
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('本地试运行结果'),
            content: SingleChildScrollView(
              child: SelectableText(
                result == null
                    ? '没有规则匹配。'
                    : const JsonEncoder.withIndent(
                        '  ',
                      ).convert(result.toMap()),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final explorer = ListView(
      key: const ValueKey('plugin-explorer'),
      children: [
        Text('项目', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _projects.contains(_project) ? _project : null,
          isExpanded: true,
          items: [
            for (final id in _projects)
              DropdownMenuItem(
                value: id,
                child: Text(id, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _busy
              ? null
              : (id) {
                  if (id != null) _selectProject(id);
                },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _create(),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('新建插件项目'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _create(script: true),
          icon: const Icon(Icons.code),
          label: const Text('新建脚本插件'),
        ),
        if (_project != null) ...[
          const Divider(),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: _busy ? null : _newFile,
                child: const Text('新建文件'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _newFile(folder: true),
                child: const Text('新建文件夹'),
              ),
              TextButton(
                onPressed: _busy ? null : _importFile,
                child: const Text('导入文件'),
              ),
              TextButton(
                onPressed: _busy ? null : _history,
                child: const Text('本地历史'),
              ),
            ],
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_open_outlined, size: 18),
            title: const Text('项目根目录'),
            selected: _folder.isEmpty,
            onTap: _busy ? null : () => setState(() => _folder = ''),
          ),
          for (final folder in _folders)
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_outlined, size: 18),
              title: Text('$folder/'),
              selected: _folder == folder,
              onTap: _busy ? null : () => setState(() => _folder = folder),
            ),
          for (final name in _files)
            ListTile(
              dense: true,
              selected: _file == name,
              leading: const Icon(Icons.description_outlined, size: 18),
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: _busy ? null : () => _selectFile(name),
            ),
        ],
      ],
    );
    final editor = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${_file ?? '选择文件开始编辑'}${_dirty ? ' · 未保存' : ''}'),
            if (_file != null)
              Wrap(
                children: [
                  IconButton(
                    tooltip: '复制全部代码',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _editor.text),
                      );
                      if (context.mounted) AppDialogs.show(context, '代码已复制。');
                    },
                    icon: const Icon(Icons.copy, size: 18),
                  ),
                  IconButton(
                    tooltip: '导出当前文件',
                    onPressed: _busy ? null : _exportFile,
                    icon: const Icon(Icons.download, size: 18),
                  ),
                  IconButton(
                    tooltip: '重命名或移动文件',
                    onPressed: _busy ? null : _rename,
                    icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                  ),
                  IconButton(
                    tooltip: '移入本地历史',
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: TextField(
            key: const ValueKey('plugin-file-editor'),
            controller: _editor,
            readOnly: _busy || _file == null,
            expands: true,
            maxLines: null,
            minLines: null,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: ['Microsoft YaHei'],
              fontSize: 13,
            ),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '编辑 .ht 脚本或 JSON/YAML 清单；保存后应用到插件中心。',
            ),
          ),
        ),
        Text(
          '${_editor.text.split('\n').length} 行 · ${utf8.encode(_editor.text).length} 字节 / 256 KB',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
    return PopScope(
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && !_busy && await _leave() && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 1080,
          height: MediaQuery.sizeOf(context).height * .9,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '插件文件管理器',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭工作台',
                      onPressed: _busy
                          ? null
                          : () async {
                              if (await _leave() && context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Text('脚本、规则与 HTTP 插件共用一套接口。保存 → 应用 → 启用，无需重新编译应用。'),
                if (_busy && ModalRoute.of(context)?.isCurrent == true)
                  const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: SelectableText(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            SizedBox(width: 270, child: explorer),
                            const VerticalDivider(),
                            Expanded(child: editor),
                          ],
                        )
                      : Column(
                          children: [
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(
                                  value: true,
                                  label: Text('文件'),
                                  icon: Icon(Icons.folder_outlined),
                                ),
                                ButtonSegment(
                                  value: false,
                                  label: Text('编辑器'),
                                  icon: Icon(Icons.code),
                                ),
                              ],
                              selected: {_showFiles},
                              onSelectionChanged: (value) =>
                                  setState(() => _showFiles = value.single),
                            ),
                            const SizedBox(height: 8),
                            Expanded(child: _showFiles ? explorer : editor),
                          ],
                        ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton(
                      onPressed: _busy || _file == null ? null : _preview,
                      child: const Text('校验 / 试运行'),
                    ),
                    OutlinedButton(
                      onPressed: _busy || !_dirty ? null : _save,
                      child: const Text('保存文件'),
                    ),
                    FilledButton(
                      onPressed: _busy || _project == null ? null : _install,
                      child: const Text('应用到插件中心'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceNameDialog extends StatefulWidget {
  final String title, initial, hint;
  const _WorkspaceNameDialog({
    required this.title,
    required this.initial,
    required this.hint,
  });
  @override
  State<_WorkspaceNameDialog> createState() => _WorkspaceNameDialogState();
}

class _WorkspaceNameDialogState extends State<_WorkspaceNameDialog> {
  late final _input = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _input,
      autofocus: true,
      decoration: InputDecoration(hintText: widget.hint),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _input.text.trim()),
        child: const Text('确定'),
      ),
    ],
  );
}
