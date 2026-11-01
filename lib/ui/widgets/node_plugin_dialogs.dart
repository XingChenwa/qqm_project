import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/plugin_manager.dart';
import '../../models/plugin.dart';
import '../../services/desktop_file_location.dart';
import '../../services/node_plugin_service.dart';
import 'app_dialogs.dart';
import 'plugin_config_dialog.dart';
import '../../models/plugin_manifest.dart';
import 'dart:convert';

String _error(Object error) => error is FormatException
    ? error.message.toString()
    : error is PluginManifestException
    ? error.message
    : '原包操作失败，请检查运行环境、网络和文件权限。';

class NodePackageImportDialog extends StatefulWidget {
  final PluginManager manager;
  const NodePackageImportDialog({super.key, required this.manager});
  @override
  State<NodePackageImportDialog> createState() => _NodePackageImportState();
}

class _NodePackageImportState extends State<NodePackageImportDialog> {
  final _url = TextEditingController();
  Map<String, dynamic>? _preview;
  bool _busy = false, _trusted = false, _replace = false;
  String? _errorText;
  NodePluginService? get _service => widget.manager.nodePackages;
  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _inspect({bool repository = false}) async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      final service = _service;
      if (service == null) throw const FormatException('当前界面尚未初始化原版插件运行环境。');
      Map<String, dynamic> result;
      if (repository) {
        result = await service.inspectRepository(_url.text.trim());
      } else {
        final selection = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['zip', 'js', 'mjs', 'cjs'],
          allowMultiple: false,
        );
        final file = selection?.files.single.path;
        if (file == null) return;
        result = await service.inspectFile(File(file));
      }
      if (widget.manager.plugins.any(
        (plugin) => plugin.info.id == result['id'],
      )) {
        result['exists'] = true;
      }
      if (mounted) {
        setState(() {
          _preview = result;
          _trusted = false;
          _replace = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _errorText = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      await widget.manager.installNodePackage(
        _preview!['stage_id'] as String,
        replaceExisting: _replace,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _errorText = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final service = _service;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        insetPadding: const EdgeInsets.all(12),
        title: const Text('导入原版插件'),
        content: SizedBox(
          width: 660,
          height: MediaQuery.sizeOf(context).height * .62,
          child: ListenableBuilder(
            listenable: service ?? widget.manager,
            builder: (_, _) => ListView(
              children: [
                if (preview == null) ...[
                  const Text(
                    '直接选择插件作者提供的 ZIP、JavaScript 文件，或填写公开 GitHub 仓库地址。软件识别原包入口并安装依赖，无需另外编写连接 JSON。',
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _inspect(),
                    icon: const Icon(Icons.archive_outlined),
                    label: const Text('选择原版 ZIP / JS'),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('node-repository-url'),
                    controller: _url,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'GitHub 仓库地址',
                      hintText: 'https://github.com/作者/插件仓库',
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _inspect(repository: true),
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('下载并检查原包'),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _busy || service == null
                        ? null
                        : () => showDialog(
                            context: context,
                            builder: (_) => NodeRuntimeDialog(service: service),
                          ),
                    icon: const Icon(Icons.settings_ethernet),
                    label: const Text('Node 运行环境'),
                  ),
                ] else ...[
                  Text(
                    preview['name'].toString(),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text('v${preview['version']} · ${preview['files']} 个原包文件'),
                  const SizedBox(height: 12),
                  Text(preview['description'].toString()),
                  const Divider(height: 28),
                  Text('入口：${(preview['entries'] as List).join('、')}'),
                  if (preview['license'].toString().isNotEmpty)
                    Text('原包许可：${preview['license']}'),
                  const SizedBox(height: 10),
                  const Text('依赖来自原包 package.json'),
                  if ((preview['dependencies'] as List).isEmpty)
                    const Text('无额外 npm 依赖'),
                  for (final dependency in preview['dependencies'] as List)
                    Text('• ${dependency['name']}  ${dependency['version']}'),
                  const SizedBox(height: 18),
                  const Text(
                    '原版 Node 插件及其依赖脚本具有当前系统用户的文件和网络权限，安装时可能编译原生模块。宿主通过消息接口提供 QQ 收发；这不是手机内的 JavaScript 沙箱。只安装你信任的源码。',
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _trusted,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _trusted = value == true),
                    title: const Text('我信任此原包，允许安装其依赖和运行原版代码'),
                  ),
                  if (preview['exists'] == true)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _replace,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _replace = value == true),
                      title: const Text('更新已有原包，保留各机器人配置与数据'),
                    ),
                  const Text('安装完成默认停用。在插件卡片编辑原生配置文件，然后手动启用。'),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(service?.phase ?? '正在处理原包'),
                ],
                if (_errorText != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    _errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (preview != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _preview = null;
                      _trusted = false;
                    }),
              child: const Text('重新选择'),
            ),
          if (preview != null)
            FilledButton(
              onPressed:
                  !_busy && _trusted && (preview['exists'] != true || _replace)
                  ? _install
                  : null,
              child: const Text('安装原包及依赖'),
            ),
        ],
      ),
    );
  }
}

class NodeRuntimeDialog extends StatefulWidget {
  final NodePluginService service;
  const NodeRuntimeDialog({super.key, required this.service});
  @override
  State<NodeRuntimeDialog> createState() => _NodeRuntimeState();
}

class _NodeRuntimeState extends State<NodeRuntimeDialog> {
  final _url = TextEditingController(), _token = TextEditingController();
  bool _remote = false, _busy = false;
  String? _errorText;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.service.loadSettings();
    if (mounted) {
      setState(() {
        _remote = widget.service.isRemote;
        _url.text = widget.service.isRemote ? widget.service.endpoint : '';
        _token.text = widget.service.isRemote ? widget.service.token : '';
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      await widget.service.configureRemote(
        _remote ? _url.text : '',
        _remote ? _token.text : '',
      );
      await widget.service.ensureStarted();
      final health = await widget.service.request('/packages/list', {});
      if (health['packages'] is! List) {
        throw const FormatException('此地址不是通用 Node 插件运行器。');
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _errorText = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Node 运行环境'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用远程运行器'),
              value: _remote,
              onChanged: _busy ? null : (v) => setState(() => _remote = v),
            ),
            if (_remote) ...[
              TextField(
                controller: _url,
                decoration: const InputDecoration(labelText: 'HTTPS 运行器地址'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(labelText: '运行器连接令牌'),
              ),
            ] else
              const Text(
                'Windows、macOS 和 Linux 由应用管理本机 Node 进程；缺少 Node 时自动下载官方运行环境。手机端可连接同一套远程运行器。',
              ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              ListenableBuilder(
                listenable: widget.service,
                builder: (_, _) => Text(widget.service.phase),
              ),
            ],
            if (_errorText != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('保存并检查')),
    ],
  );
}

class NodePackageFilesDialog extends StatefulWidget {
  final NodePluginService service;
  final String id, appId, scope;
  const NodePackageFilesDialog({
    super.key,
    required this.service,
    required this.id,
    required this.appId,
    this.scope = 'account',
  });
  @override
  State<NodePackageFilesDialog> createState() => _NodePackageFilesState();
}

class _NodePackageFilesState extends State<NodePackageFilesDialog> {
  final _content = TextEditingController();
  List<String> _files = [];
  String? _selected, _errorText;
  String _directory = '', _saved = '';
  bool _busy = true;
  bool get _dirty => _content.text != _saved;
  Map<String, dynamic> get _args => {
    'id': widget.id,
    'app_id': widget.appId,
    'scope': widget.scope,
  };
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (widget.appId.isEmpty && widget.scope != 'source') {
        throw const FormatException('请先选择机器人，再编辑该机器人的原生配置。');
      }
      final data = await widget.service.request('/packages/files', _args);
      _files = (data['files'] as List).cast<String>();
      _directory = data['directory'].toString();
      final selected = widget.scope == 'source'
          ? (_files.contains('README.md') ? 'README.md' : _files.firstOrNull)
          : _files
                    .where(
                      (f) =>
                          f.startsWith('config/config/') &&
                          RegExp(r'\.ya?ml$').hasMatch(f),
                    )
                    .firstOrNull ??
                _files
                    .where(
                      (f) =>
                          f.contains('config') &&
                          RegExp(r'\.ya?ml$').hasMatch(f),
                    )
                    .firstOrNull ??
                _files.firstOrNull;
      if (selected != null) await _read(selected);
    } catch (error) {
      _errorText = _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _discard() async =>
      !_dirty ||
      await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('保留未保存的编辑？'),
              content: const Text('当前文件有修改，可以返回保存后再离开。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('返回编辑'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('放弃修改'),
                ),
              ],
            ),
          ) ==
          true;
  Future<void> _read(String file) async {
    if (!await _discard()) return;
    if (mounted) setState(() => _busy = true);
    try {
      final data = await widget.service.request('/packages/file', {
        ..._args,
        'file': file,
      });
      _selected = file;
      _saved = data['content'].toString();
      _content.text = _saved;
      _errorText = null;
    } catch (error) {
      _errorText = _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.service.request('/packages/file', {
        ..._args,
        'file': _selected,
        'content': _content.text,
      });
      _saved = _content.text;
      if (mounted) {
        await AppDialogs.show(context, '文件已保存。原生配置由插件读取；修改源码后可在卡片菜单重新加载。');
      }
    } catch (error) {
      _errorText = _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_busy,
    child: AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      title: Text(widget.scope == 'source' ? '原包源码' : '当前机器人 · 原生配置文件'),
      content: SizedBox(
        width: 900,
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_files.isNotEmpty)
              DropdownButton<String>(
                value: _selected,
                isExpanded: true,
                hint: const Text('选择原包文件'),
                items: _files
                    .map(
                      (f) => DropdownMenuItem(
                        value: f,
                        child: Text(f, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v != null) _read(v);
                      },
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_errorText != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _content,
                expands: true,
                minLines: null,
                maxLines: null,
                enabled: !_busy && _selected != null,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!widget.service.isRemote &&
            DesktopFileLocation.supported &&
            _directory.isNotEmpty)
          TextButton.icon(
            onPressed: () => DesktopFileLocation.open(_directory),
            icon: const Icon(Icons.folder_open),
            label: const Text('打开所在文件夹'),
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  if (await _discard() && context.mounted) {
                    Navigator.pop(context);
                  }
                },
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: !_busy && _selected != null ? _save : null,
          child: const Text('保存原文件'),
        ),
      ],
    ),
  );
}

Future<void> configureNodePlugin(
  BuildContext context,
  PluginManager manager,
  PluginInfo info,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('原插件配置文件'),
            subtitle: const Text('编辑该机器人下原包使用的 YAML / JSON 配置'),
            onTap: () => Navigator.pop(context, 'files'),
          ),
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('主人与发送权限'),
            onTap: () => Navigator.pop(context, 'host'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null || manager.nodePackages == null) {
    return;
  }
  if (action == 'files') {
    await showDialog(
      context: context,
      builder: (_) => NodePackageFilesDialog(
        service: manager.nodePackages!,
        id: info.id,
        appId: manager.activeBotAppId,
      ),
    );
  } else {
    final config = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => PluginConfigDialog(
        info: info,
        definition: PluginManifest.parse(jsonEncode(info.manifest)),
      ),
    );
    if (config != null) await manager.updatePluginConfig(info.id, config);
  }
}
