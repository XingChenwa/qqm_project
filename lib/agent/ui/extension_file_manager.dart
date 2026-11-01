import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../ui/widgets/app_dialogs.dart';
import '../../services/desktop_file_location.dart';
import 'package:path/path.dart' as p;
import '../controller.dart';
import '../extension_files.dart';
import '../models.dart';

/// Edits a complete package revision, so a renamed module and its imports can
/// be validated and hot-reloaded together. Nothing is written until Save.
class AgentExtensionFileManager extends StatefulWidget {
  final AgentController controller;
  final String extensionId;
  const AgentExtensionFileManager({
    super.key,
    required this.controller,
    required this.extensionId,
  });
  @override
  State<AgentExtensionFileManager> createState() =>
      _AgentExtensionFileManagerState();
}

class _AgentExtensionFileManagerState extends State<AgentExtensionFileManager> {
  late AgentExtensionFiles _base;
  late Map<String, Uint8List> _files;
  final _folders = <String>{};
  final _editor = TextEditingController();
  String _directory = '', _selected = '', _error = '';
  bool _saving = false, _dirty = false, _allowLeave = false, _textFile = true;
  @override
  void initState() {
    super.initState();
    _base = widget.controller.extensionFiles(widget.extensionId);
    _files = Map.of(_base.files);
    _select(_files.containsKey('index.js') ? 'index.js' : _base.manifestName);
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _select(String path) {
    _selected = path;
    _error = '';
    _textFile = false;
    try {
      final bytes = _files[path]!;
      if (bytes.length > AgentExtensionFiles.maxTextBytes) {
        throw const AgentException('文件超过1MB，请导出后编辑。');
      }
      if (bytes.contains(0)) throw const AgentException('二进制文件，可导出或替换文件。');
      _editor.text = utf8.decode(bytes);
      _textFile = true;
    } catch (error) {
      _editor.clear();
      _error = widget.controller.describeError(error);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          widget.controller.describeError(error),
          title: '文件管理',
          error: true,
        );
      }
    }
  }

  Future<String?> _pathDialog(String title, String initial) async {
    var draft = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: TextFormField(
            initialValue: initial,
            onChanged: (value) => draft = value,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '包内路径',
              helperText: '用 / 分隔目录，例如 src/tools.js',
            ),
            onFieldSubmitted: (value) => Navigator.pop(dialog, value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, draft.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _leave() async {
    if (_saving) return;
    if (_dirty &&
        !await _confirm('放弃未保存的修改？', '可以先返回并点击“保存并应用”，或导出源码ZIP保留草稿。')) {
      return;
    }
    if (!mounted) return;
    setState(() => _allowLeave = true);
    Navigator.pop(context);
  }

  String get _prefix => _directory.isEmpty ? '' : '$_directory/';
  Future<void> _new(bool folder) async {
    final name = await _pathDialog(
      folder ? '新建目录' : '新建文件',
      '$_prefix${folder ? 'src' : 'new.js'}',
    );
    if (name == null) return;
    AgentExtensionFiles.validatePath(name);
    if (_files.keys.any((key) => key.toLowerCase() == name.toLowerCase()) ||
        _folders.contains(name)) {
      throw const AgentException('这个名称已经存在。');
    }
    setState(() {
      if (folder) {
        _folders.add(name);
        _directory = name;
      } else {
        _files[name] = Uint8List(0);
        _select(name);
        _dirty = true;
      }
    });
  }

  Future<void> _rename(String name, bool folder) async {
    if (name == _base.manifestName ||
        (folder && _base.manifestName.startsWith('$name/'))) {
      throw const AgentException('请保留清单文件的名称和位置。');
    }
    final next = await _pathDialog('重命名 / 移动', name);
    if (next == null || next == name) return;
    AgentExtensionFiles.validatePath(next);
    if (folder && next.startsWith('$name/')) {
      throw const AgentException('不能移到目录自身内部。');
    }
    final updates = <String, Uint8List>{};
    for (final entry in _files.entries) {
      final target =
          entry.key == name || (folder && entry.key.startsWith('$name/'))
          ? '$next${entry.key.substring(name.length)}'
          : entry.key;
      if (updates.keys.any(
        (key) => key.toLowerCase() == target.toLowerCase(),
      )) {
        throw const AgentException('目标位置存在同名文件。');
      }
      AgentExtensionFiles.validatePath(target);
      updates[target] = entry.value;
    }
    setState(() {
      _files = updates;
      if (_selected == name || (folder && _selected.startsWith('$name/'))) {
        _selected = '$next${_selected.substring(name.length)}';
      }
      final moved = _folders
          .map(
            (path) => path == name || (folder && path.startsWith('$name/'))
                ? '$next${path.substring(name.length)}'
                : path,
          )
          .toSet();
      _folders
        ..clear()
        ..addAll(moved);
      if (_directory == name || (folder && _directory.startsWith('$name/'))) {
        _directory = '$next${_directory.substring(name.length)}';
      }
      _dirty = true;
    });
  }

  Future<void> _delete(String name, bool folder) async {
    if (name == _base.manifestName ||
        (folder && _base.manifestName.startsWith('$name/'))) {
      throw const AgentException('不能删除扩展清单。');
    }
    if (!await _confirm('删除${folder ? '目录及其中的文件' : '文件'}？', name)) return;
    setState(() {
      _files.removeWhere(
        (key, _) => key == name || (folder && key.startsWith('$name/')),
      );
      _folders.removeWhere(
        (path) => path == name || (folder && path.startsWith('$name/')),
      );
      if (!_files.containsKey(_selected)) _select(_base.manifestName);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      await widget.controller.saveExtensionFiles(
        widget.extensionId,
        _files,
        expectedRevision: _base.revision,
      );
      if (!mounted) return;
      setState(() {
        _base = widget.controller.extensionFiles(widget.extensionId);
        _files = Map.of(_base.files);
        _dirty = false;
      });
      await AppDialogs.show(context, '所有文件已保存并应用。后续消息使用新源码。', title: '保存成功');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _download(Uint8List bytes, String name) async {
    final destination = await FilePicker.saveFile(
      dialogTitle: '导出源码',
      fileName: name,
      bytes: bytes,
    );
    if (destination != null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(destination).writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> _export() async {
    final archive = Archive();
    for (final entry in _files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    await _download(
      Uint8List.fromList(ZipEncoder().encode(archive)),
      '${widget.extensionId}-source.zip',
    );
  }

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final next = Map<String, Uint8List>.of(_files);
    for (final file in result.files) {
      final path = '$_prefix${file.name}';
      AgentExtensionFiles.validatePath(path);
      if (file.bytes == null || file.size > 8 * 1024 * 1024) {
        throw const AgentException('单个文件不能超过8MB。');
      }
      if (next.containsKey(path) && !await _confirm('替换文件？', path)) continue;
      next[path] = file.bytes!;
    }
    if (next.length > 300 ||
        next.values.fold<int>(0, (sum, value) => sum + value.length) >
            24 * 1024 * 1024) {
      throw const AgentException('源码包最多300个文件、24MB。');
    }
    if (mounted) {
      setState(() {
        _files = next;
        _dirty = true;
        _select(_selected);
      });
    }
  }

  Widget _fileList({bool closeOnSelect = false}) {
    final dirs = <String>{};
    final files = <String>[];
    for (final path in {..._files.keys, ..._folders}) {
      if (!path.startsWith(_prefix) || path == _directory) continue;
      final rest = path.substring(_prefix.length), slash = rest.indexOf('/');
      if (slash >= 0) {
        dirs.add('$_prefix${rest.substring(0, slash)}');
      } else if (_folders.contains(path)) {
        dirs.add(path);
      } else {
        files.add(path);
      }
    }
    final directories = dirs.toList()..sort();
    files.sort();
    Widget tile(String path, bool folder) => ListTile(
      dense: true,
      selected: !folder && path == _selected,
      leading: Icon(
        folder
            ? Icons.folder_outlined
            : path == _base.manifestName
            ? Icons.settings_outlined
            : Icons.description_outlined,
      ),
      title: Text(
        path.substring(_prefix.length),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: folder
          ? null
          : Text(
              '${_files[path]!.length} B',
              style: const TextStyle(fontSize: 11),
            ),
      onTap: _saving
          ? null
          : () {
              setState(() {
                if (folder) {
                  _directory = path;
                } else {
                  _select(path);
                }
              });
              if (!folder && closeOnSelect) Navigator.pop(context);
            },
      trailing: PopupMenuButton<String>(
        enabled: !_saving,
        tooltip: '文件操作',
        onSelected: (value) => _run(
          () => value == 'rename'
              ? _rename(path, folder)
              : value == 'delete'
              ? _delete(path, folder)
              : _download(_files[path]!, path.split('/').last),
        ),
        itemBuilder: (_) => [
          if (_base.javascript)
            const PopupMenuItem(value: 'rename', child: Text('重命名 / 移动')),
          if (!folder)
            const PopupMenuItem(value: 'export', child: Text('导出文件')),
          if (_base.javascript)
            const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: IconButton(
            tooltip: '上一级',
            icon: const Icon(Icons.arrow_upward),
            onPressed: _directory.isEmpty
                ? null
                : () => setState(() {
                    final at = _directory.lastIndexOf('/');
                    _directory = at < 0 ? '' : _directory.substring(0, at);
                  }),
          ),
          title: Text(
            _directory.isEmpty ? '全部文件' : _directory,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final path in directories) tile(path, true),
              for (final path in files) tile(path, false),
              if (directories.isEmpty && files.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('空目录：可以新建或导入文件。'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _editorPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Text(
          '$_selected${_dirty ? ' · 未保存' : ''}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      if (_selected == _base.manifestName)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '清单可编辑；请保留扩展ID与类型，设置和密钥会继续保留。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      Expanded(
        child: _textFile
            ? TextField(
                key: const Key('agent-source-editor'),
                controller: _editor,
                enabled: !_saving,
                expands: true,
                maxLines: null,
                minLines: null,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.6,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(16),
                ),
                onChanged: (value) {
                  _files[_selected] = Uint8List.fromList(utf8.encode(value));
                  if (!_dirty) setState(() => _dirty = true);
                },
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.insert_drive_file_outlined, size: 48),
                      const SizedBox(height: 16),
                      Text(_error),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () => _run(
                          () => _download(
                            _files[_selected]!,
                            _selected.split('/').last,
                          ),
                        ),
                        icon: const Icon(Icons.download),
                        label: const Text('导出文件'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowLeave || (!_dirty && !_saving),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _SaveSourceIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true):
            _SaveSourceIntent(),
      },
      child: Actions(
        actions: {
          _SaveSourceIntent: CallbackAction<_SaveSourceIntent>(
            onInvoke: (_) {
              _run(_save);
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            return Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: '返回',
                  onPressed: _leave,
                  icon: const Icon(Icons.arrow_back),
                ),
                title: const Text('文件管理'),
                actions: [
                  if (DesktopFileLocation.supported)
                    IconButton(
                      tooltip: '打开文件所在位置',
                      onPressed: _saving
                          ? null
                          : () => _run(() async {
                              final directory = await widget.controller
                                  .extensionSourceDirectory(widget.extensionId);
                              final file = File(
                                p.joinAll([
                                  directory.path,
                                  ..._selected.split('/'),
                                ]),
                              );
                              await DesktopFileLocation.open(
                                await file.exists()
                                    ? file.path
                                    : directory.path,
                                selectFile: await file.exists(),
                              );
                            }),
                      icon: const Icon(Icons.folder_open_outlined),
                    ),
                  if (!wide)
                    Builder(
                      builder: (context) => IconButton(
                        tooltip: '浏览文件',
                        icon: const Icon(Icons.folder_open),
                        onPressed: () => Scaffold.of(context).openEndDrawer(),
                      ),
                    ),
                  IconButton(
                    key: const Key('agent-source-save'),
                    tooltip: '保存并应用',
                    onPressed: _saving || !_dirty ? null : () => _run(_save),
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                  ),
                  PopupMenuButton<String>(
                    enabled: !_saving,
                    tooltip: '更多文件操作',
                    onSelected: (value) => _run(
                      () => switch (value) {
                        'new' => _new(false),
                        'folder' => _new(true),
                        'import' => _import(),
                        _ => _export(),
                      },
                    ),
                    itemBuilder: (_) => [
                      if (_base.javascript) ...[
                        const PopupMenuItem(value: 'new', child: Text('新建文件')),
                        const PopupMenuItem(
                          value: 'folder',
                          child: Text('新建目录'),
                        ),
                        const PopupMenuItem(
                          value: 'import',
                          child: Text('导入 / 替换文件'),
                        ),
                      ],
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('导出源码 ZIP'),
                      ),
                    ],
                  ),
                ],
              ),
              endDrawer: wide
                  ? null
                  : Drawer(
                      child: SafeArea(child: _fileList(closeOnSelect: true)),
                    ),
              body: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${widget.extensionId} · ${_files.length}个文件',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _dirty ? '有未保存的修改' : '已保存',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: wide
                        ? Row(
                            children: [
                              SizedBox(width: 270, child: _fileList()),
                              const VerticalDivider(width: 1),
                              Expanded(child: _editorPane()),
                            ],
                          )
                        : _editorPane(),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _base.javascript
                                  ? '保存时校验全部源码，并重新加载扩展。'
                                  : '此类扩展的全部逻辑保存在JSON清单中。',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: _saving || !_dirty
                                ? null
                                : () => _run(_save),
                            child: const Text('保存并应用'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _SaveSourceIntent extends Intent {
  const _SaveSourceIntent();
}
