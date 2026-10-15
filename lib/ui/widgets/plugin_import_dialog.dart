import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/plugin_manager.dart';
import '../../models/plugin_manifest.dart';
import '../themes/app_theme.dart';

class PluginImportDialog extends StatefulWidget {
  final PluginManager manager;
  final String initialSource;
  const PluginImportDialog({
    super.key,
    required this.manager,
    this.initialSource = '',
  });
  @override
  State<PluginImportDialog> createState() => _PluginImportDialogState();
}

class _PluginImportDialogState extends State<PluginImportDialog> {
  late final TextEditingController _source = TextEditingController(
    text: widget.initialSource,
  );
  PluginManifest? _definition;
  String? _error;
  bool _approved = false;
  bool _replace = false;
  bool _busy = false;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'yaml', 'yml'],
        allowMultiple: false,
        withData: false,
      );
      if (result == null || !mounted) return;
      final file = result.files.single;
      if (file.size > PluginManifest.maxBytes) {
        throw const PluginManifestException('插件清单不能超过 256 KB。');
      }
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) {
        throw const PluginManifestException('无法读取文件，请复制清单粘贴到下方。');
      }
      _source.text = utf8.decode(bytes);
      _check();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PluginManifestException
              ? e.message
              : '读取失败，请选择 UTF-8 编码的 JSON/YAML 文件。',
        );
      }
    }
  }

  void _check() {
    try {
      final definition = PluginManifest.parse(_source.text);
      if (widget.manager.isBundled(definition.id)) {
        throw const PluginManifestException('此 ID 属于内置插件，不能覆盖。');
      }
      setState(() {
        _definition = definition;
        _error = null;
        _approved = false;
        _replace = false;
      });
    } catch (e) {
      setState(
        () => _error = e is PluginManifestException ? e.message : '清单格式无效。',
      );
    }
  }

  Future<void> _install() async {
    setState(() => _busy = true);
    try {
      await widget.manager.installPlugin(
        _source.text,
        replaceExisting: _replace,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PluginManifestException
              ? e.message
              : '保存插件失败，请稍后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final definition = _definition;
    final exists =
        definition != null &&
        widget.manager.plugins.any((p) => p.info.id == definition.id);
    return AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      title: Row(
        children: [
          const Expanded(child: Text('导入自定义插件')),
          IconButton(
            tooltip: '关闭插件导入',
            onPressed: _busy ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: MediaQuery.sizeOf(context).height * .58,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (definition == null) ...[
              const Text(
                '选择 JSON/YAML 文件，或直接粘贴清单。只检查数据，不执行代码。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('选择清单文件'),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('plugin-manifest-source'),
                  controller: _source,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: '在这里粘贴 plugin.json 或 plugin.yaml',
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ] else
              Expanded(
                child: ListView(
                  children: [
                    Text(
                      definition.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${definition.id} · v${definition.data['version']} · ${definition.runtime == 'http' ? 'HTTP 服务插件' : '规则插件'}',
                    ),
                    const SizedBox(height: 12),
                    Text(definition.data['description']),
                    const Divider(height: 28),
                    const Text(
                      '申请权限',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    for (final permission in definition.permissions)
                      Text('• $permission'),
                    if (definition.runtime == 'http') ...[
                      const SizedBox(height: 16),
                      const Text(
                        '数据将发送至',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        definition.http['url'],
                        style: const TextStyle(color: AppTheme.qqBlue),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '启用后，命中规则的消息正文、发送者及会话 OpenID 会传给此服务。QQ 机器人密钥和 access_token 不会传入。只安装不会请求服务。',
                        style: TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ],
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      key: const ValueKey('plugin-import-consent'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _approved,
                      onChanged: (v) => setState(() => _approved = v!),
                      title: const Text(
                        '我已了解权限及数据用途，允许安装此插件。',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    if (exists)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _replace,
                        onChanged: (v) => setState(() => _replace = v!),
                        title: const Text(
                          '替换同 ID 插件，保留兼容配置并重新停用。',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    const Text(
                      '安装后默认为停用状态，请先检查配置，再手动启用。',
                      style: TextStyle(fontSize: 12, color: AppTheme.muted),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.qqRed, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => definition == null
                    ? Navigator.pop(context)
                    : setState(() {
                        _definition = null;
                        _error = null;
                      }),
          child: Text(definition == null ? '取消' : '返回编辑'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : definition == null
              ? _check
              : _approved && (!exists || _replace)
              ? _install
              : null,
          child: Text(
            _busy
                ? '正在安装…'
                : definition == null
                ? '检查清单'
                : '确认导入',
          ),
        ),
      ],
    );
  }
}
