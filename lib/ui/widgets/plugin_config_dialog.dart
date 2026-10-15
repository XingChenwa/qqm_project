import 'package:flutter/material.dart';
import '../../models/plugin.dart';
import '../../models/plugin_manifest.dart';

class PluginConfigDialog extends StatefulWidget {
  final PluginInfo info;
  final PluginManifest definition;
  const PluginConfigDialog({
    super.key,
    required this.info,
    required this.definition,
  });
  @override
  State<PluginConfigDialog> createState() => _PluginConfigDialogState();
}

class _PluginConfigDialogState extends State<PluginConfigDialog> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _booleans = <String, bool>{};
  final _visible = <String>{};
  @override
  void initState() {
    super.initState();
    for (final field in widget.definition.fields) {
      final value = widget.info.config[field.key] ?? field.defaultValue;
      if (field.type == 'boolean') {
        _booleans[field.key] = value == true;
      } else {
        _controllers[field.key] = TextEditingController(
          text: value?.toString() ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.all(16),
    title: Text('${widget.info.name}配置'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in widget.definition.fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: field.type == 'boolean'
                      ? SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(field.label),
                          value: _booleans[field.key]!,
                          onChanged: (v) =>
                              setState(() => _booleans[field.key] = v),
                        )
                      : TextFormField(
                          controller: _controllers[field.key],
                          obscureText:
                              field.type == 'secret' &&
                              !_visible.contains(field.key),
                          keyboardType: field.type == 'integer'
                              ? const TextInputType.numberWithOptions(
                                  signed: true,
                                )
                              : TextInputType.text,
                          decoration: InputDecoration(
                            helperMaxLines: 2,
                            labelText: field.label,
                            helperText: field.type == 'secret'
                                ? '仅保存在本机配置中，请妥善保管配置备份。'
                                : null,
                            suffixIcon: field.type != 'secret'
                                ? null
                                : IconButton(
                                    tooltip: '显示或隐藏密钥',
                                    onPressed: () => setState(
                                      () => _visible.contains(field.key)
                                          ? _visible.remove(field.key)
                                          : _visible.add(field.key),
                                    ),
                                    icon: Icon(
                                      _visible.contains(field.key)
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                    ),
                                  ),
                          ),
                          validator: (value) {
                            if (field.required &&
                                (value == null || value.trim().isEmpty)) {
                              return '请填写${field.label}';
                            }
                            if (field.type == 'integer' &&
                                int.tryParse(value ?? '') == null) {
                              return '请输入整数';
                            }
                            if ((value?.length ?? 0) > 8192) return '配置文本过长';
                            return null;
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(context, <String, dynamic>{
            ...widget.info.config,
            for (final field in widget.definition.fields)
              field.key: field.type == 'boolean'
                  ? _booleans[field.key]
                  : field.type == 'integer'
                  ? int.parse(_controllers[field.key]!.text)
                  : _controllers[field.key]!.text.trim(),
          });
        },
        child: const Text('保存'),
      ),
    ],
  );
}
