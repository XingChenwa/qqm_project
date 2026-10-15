import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/plugin_manager.dart';
import '../../models/plugin_manifest.dart';
import '../../services/plugin_workspace.dart';
import 'app_dialogs.dart';

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
  List<String> _projects = [];
  List<String> _files = [];
  String? _project;
  String? _file;
  final _editor = TextEditingController();
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _description = TextEditingController(text: '用命令回复消息');
  final _trigger = TextEditingController();
  final _reply = TextEditingController();
  String _matchType = 'command';
  String _scope = 'all';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload(select: widget.initialId);
  }

  @override
  void dispose() {
    _editor.dispose();
    _id.dispose();
    _name.dispose();
    _description.dispose();
    _trigger.dispose();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _reload({String? select}) async {
    await _workspace.ensureRoot();
    final projects = await _workspace.projects();
    if (!mounted) return;
    setState(() => _projects = projects);
    final chosen = select != null && projects.contains(select)
        ? select
        : _project;
    if (chosen != null) await _openProject(chosen);
  }

  Future<void> _openProject(String id) async {
    final files = await _workspace.files(id);
    final name = files.contains('plugin.json')
        ? 'plugin.json'
        : files.isEmpty
        ? null
        : files.first;
    final content = name == null ? '' : await _workspace.read(id, name);
    if (!mounted) return;
    setState(() {
      _project = id;
      _files = files;
      _file = name;
      _editor.text = content;
      _error = null;
    });
  }

  Future<void> _openFile(String name) async {
    final content = await _workspace.read(_project!, name);
    if (!mounted) return;
    setState(() {
      _file = name;
      _editor.text = content;
    });
  }

  Future<void> _save() async {
    final project = _project;
    final file = _file;
    if (project == null || file == null) return;
    setState(() => _busy = true);
    try {
      await _workspace.write(project, file, _editor.text);
      if (mounted) AppDialogs.show(context, '已保存 $file');
    } on PluginManifestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final project = _project;
    if (project == null) return;
    await _save();
    final manifestName = _files.contains('plugin.json')
        ? 'plugin.json'
        : _files.contains('plugin.yaml')
        ? 'plugin.yaml'
        : _file;
    if (manifestName == null) return;
    setState(() => _busy = true);
    try {
      final source = manifestName == _file
          ? _editor.text
          : await _workspace.read(project, manifestName);
      await widget.manager.installPlugin(source, replaceExisting: true);
      if (mounted) {
        AppDialogs.show(context, '插件已安装并停用，确认规则后可启用。');
      }
    } on PluginManifestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final source = PluginWorkspace.rulesManifest(
        id: _id.text.trim(),
        name: _name.text.trim(),
        description: _description.text.trim(),
        commands: [
          PluginCommandDraft(
            type: _matchType,
            value: _trigger.text,
            reply: _reply.text,
            scope: _scope,
          ),
        ],
      );
      final id = _id.text.trim();
      await _workspace.write(id, 'plugin.json', source);
      await _workspace.write(
        id,
        'readme.md',
        '# ${_name.text.trim()}\n\n在群聊中 @ 机器人后发送命令。命令插件与云崽的 rule 一样，一条触发对应一条回复。\n',
      );
      _id.clear();
      _name.clear();
      _trigger.clear();
      _reply.clear();
      await _reload(select: id);
    } on PluginManifestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFile() async {
    final project = _project;
    if (project == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) {
        final controller = TextEditingController(text: 'notes.md');
        return AlertDialog(
          title: const Text('新建文本文件'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: '例如 replies.md'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, controller.text.trim()),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    try {
      await _workspace.write(project, name, '');
      await _openProject(project);
      await _openFile(name);
    } on PluginManifestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final files = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('插件文件', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            for (final name in _projects)
              ChoiceChip(
                label: Text(name),
                selected: _project == name,
                onSelected: (_) => _openProject(name),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_project != null)
          Wrap(
            spacing: 6,
            children: [
              for (final name in _files)
                ChoiceChip(
                  label: Text(name),
                  selected: _file == name,
                  onSelected: (_) => _openFile(name),
                ),
              ActionChip(label: const Text('新建文件'), onPressed: _addFile),
              if (_file != null)
                ActionChip(
                  label: const Text('删除当前文件'),
                  onPressed: () async {
                    await _workspace.deleteFile(_project!, _file!);
                    await _openProject(_project!);
                  },
                ),
            ],
          ),
      ],
    );
    final creator = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('新建命令插件', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _id,
          decoration: const InputDecoration(labelText: '插件 ID，如 my_hello'),
        ),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '显示名称'),
        ),
        TextField(
          controller: _description,
          decoration: const InputDecoration(labelText: '说明'),
        ),
        DropdownButtonFormField<String>(
          initialValue: _matchType,
          decoration: const InputDecoration(labelText: '触发方式'),
          items: const [
            DropdownMenuItem(value: 'command', child: Text('命令 /hello')),
            DropdownMenuItem(value: 'exact', child: Text('整句完全相同')),
            DropdownMenuItem(value: 'prefix', child: Text('以前缀开头')),
            DropdownMenuItem(value: 'contains', child: Text('包含关键词')),
          ],
          onChanged: (value) => setState(() => _matchType = value ?? 'command'),
        ),
        TextField(
          controller: _trigger,
          decoration: const InputDecoration(
            labelText: '触发内容',
            hintText: '命令不要带空格和斜杠，例如 hello',
          ),
        ),
        TextField(
          controller: _reply,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '回复',
            hintText: '可用 {{sender_name}} 和 {{args}}',
          ),
        ),
        DropdownButtonFormField<String>(
          initialValue: _scope,
          decoration: const InputDecoration(labelText: '会话范围'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('群聊和单聊')),
            DropdownMenuItem(value: 'group', child: Text('仅群聊')),
            DropdownMenuItem(value: 'private', child: Text('仅单聊')),
          ],
          onChanged: (value) => setState(() => _scope = value ?? 'all'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: const Text('生成清单和说明文件'),
        ),
      ],
    );
    final editor = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _file == null ? '选择一个文件开始编辑' : '正在编辑 $_file',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            controller: _editor,
            expands: true,
            maxLines: null,
            minLines: null,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 980,
        height: MediaQuery.sizeOf(context).height * .86,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '插件工作台',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭工作台',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text('像云崽写一条命令一条回复。文件保存在本机工作区，安装后仍可回来改。'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 320,
                            child: ListView(
                              children: [files, const Divider(), creator],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: editor),
                        ],
                      )
                    : ListView(
                        children: [
                          files,
                          const Divider(),
                          creator,
                          const SizedBox(height: 12),
                          SizedBox(height: 280, child: editor),
                        ],
                      ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy || _file == null ? null : _save,
                    child: const Text('保存文件'),
                  ),
                  FilledButton(
                    onPressed: _busy || _project == null ? null : _install,
                    child: const Text('安装到插件中心'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
