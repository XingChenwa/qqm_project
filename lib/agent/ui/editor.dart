import 'package:flutter/material.dart';
import '../models.dart';

class AgentField {
  final String keyName, label, hint, type;
  final Map<String, String> choices;
  final int lines;
  final Map<String, Object> when;
  final Future<List<String>> Function(Json)? loadOptions;
  final bool advanced;
  const AgentField(
    this.keyName,
    this.label, {
    this.hint = '',
    this.type = 'text',
    this.choices = const {},
    this.lines = 1,
    this.when = const {},
    this.loadOptions,
    this.advanced = false,
  });
  bool visible(Json value) =>
      when.entries.every((e) => value[e.key] == e.value);
}

Future<bool?> editAgent(
  BuildContext context, {
  required String title,
  required Json initial,
  required List<AgentField> fields,
  required Future<void> Function(Json value) save,
  String? description,
  String actionLabel = '',
  Future<String> Function(Json)? action,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _AgentEditor(
    title: title,
    initial: initial,
    fields: fields,
    save: save,
    description: description,
    action: action,
    actionLabel: actionLabel,
  ),
);

class _AgentEditor extends StatefulWidget {
  final String title, actionLabel;
  final String? description;
  final Json initial;
  final List<AgentField> fields;
  final Future<void> Function(Json) save;
  final Future<String> Function(Json)? action;
  const _AgentEditor({
    required this.title,
    required this.initial,
    required this.fields,
    required this.save,
    this.description,
    this.action,
    required this.actionLabel,
  });
  @override
  State<_AgentEditor> createState() => _AgentEditorState();
}

class _AgentEditorState extends State<_AgentEditor> {
  final _controllers = <String, TextEditingController>{};
  late final Json _value = {...widget.initial};
  String _notice = '';
  bool _busy = false, _error = false;
  bool _advanced = false;
  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      if (field.type == 'choice' &&
          !field.choices.containsKey(text(_value[field.keyName]))) {
        _value[field.keyName] = field.choices.keys.firstOrNull;
      }
      if (!{'bool', 'choice', 'multi'}.contains(field.type)) {
        final v = _value[field.keyName];
        _controllers[field.keyName] = TextEditingController(
          text: {'ids', 'list'}.contains(field.type) && v is List
              ? v.join(field.type == 'list' ? '\n' : ', ')
              : text(v),
        );
      }
    }
  }

  Json _collect() {
    final result = {..._value};
    for (final field in widget.fields) {
      if (!field.visible(_value)) continue;
      final c = _controllers[field.keyName];
      if (c == null) continue;
      result[field.keyName] = switch (field.type) {
        'int' => int.tryParse(c.text.trim()) ?? -1,
        'double' => double.tryParse(c.text.trim()) ?? -1.0,
        'optionalDouble' =>
          c.text.trim().isEmpty ? null : double.tryParse(c.text.trim()) ?? -1.0,
        'ids' =>
          c.text.split(RegExp(r'[,，\s]+')).where((v) => v.isNotEmpty).toList(),
        'list' =>
          c.text
              .split(RegExp(r'[,，\r\n]+'))
              .map((v) => v.trim())
              .where((v) => v.isNotEmpty)
              .toSet()
              .toList(),
        'code' => c.text,
        _ => c.text.trim(),
      };
    }
    return result;
  }

  Future<void> _submit({bool action = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = '';
    });
    try {
      final value = _collect();
      if (action) {
        final response = await widget.action!(value);
        if (mounted) {
          setState(() {
            _notice = response;
            _error = false;
          });
        }
      } else {
        await widget.save(value);
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _notice = e is AgentException ? e.message : '未能保存，请检查输入格式和存储权限。';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 680,
        maxHeight: MediaQuery.sizeOf(context).height * .88,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.description != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Text(
                        widget.description!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  for (final f in widget.fields)
                    if (f.visible(_value) && !f.advanced)
                      Padding(
                        key: ValueKey(f.keyName),
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _field(f),
                      ),
                  if (widget.fields.any((f) => f.advanced))
                    ExpansionTile(
                      title: const Text('高级设置'),
                      subtitle: const Text('可选能力、参数与访问范围'),
                      initiallyExpanded: _advanced,
                      onExpansionChanged: (v) => _advanced = v,
                      children: [
                        for (final f in widget.fields)
                          if (f.advanced && f.visible(_value))
                            Padding(
                              key: ValueKey(f.keyName),
                              padding: const EdgeInsets.only(bottom: 16),
                              child: _field(f),
                            ),
                      ],
                    ),
                  if (_notice.isNotEmpty)
                    SelectableText(
                      _notice,
                      style: TextStyle(
                        color: _error
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (widget.action != null)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _submit(action: true),
                    child: Text(widget.actionLabel),
                  ),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? '处理中…' : '保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget _field(AgentField field) {
    final name = field.keyName;
    if (field.loadOptions != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controllers[name],
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: field.label,
              helperText: field.hint,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _loadOptions(field),
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: const Text('获取并选择模型'),
            ),
          ),
        ],
      );
    }
    if (field.type == 'bool') {
      return SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: field.hint.isEmpty ? null : Text(field.hint),
        value: _value[name] == true,
        onChanged: _busy ? null : (v) => setState(() => _value[name] = v),
      );
    }
    if (field.type == 'choice') {
      if (field.choices.length > 20) {
        return InputDecorator(
          decoration: InputDecoration(
            labelText: field.label,
            helperText: field.hint.isEmpty ? null : field.hint,
            helperMaxLines: 4,
          ),
          child: InkWell(
            onTap: _busy
                ? null
                : () async {
                    final selected = await showDialog<String>(
                      context: context,
                      builder: (_) => _ModelPicker(
                        field.choices.keys.toList(),
                        title: '选择${field.label}',
                        searchHint: '搜索${field.label}',
                        labels: field.choices,
                      ),
                    );
                    if (mounted && selected != null) {
                      setState(() => _value[name] = selected);
                    }
                  },
            child: Row(
              children: [
                Expanded(
                  child: Text(field.choices[text(_value[name])] ?? '请选择'),
                ),
                const Icon(Icons.search),
              ],
            ),
          ),
        );
      }
      return DropdownButtonFormField<String>(
        key: ValueKey('${name}_${_value[name]}'),
        initialValue: field.choices.containsKey(text(_value[name]))
            ? text(_value[name])
            : field.choices.keys.first,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: field.label,
          helperText: field.hint.isEmpty ? null : field.hint,
          helperMaxLines: 4,
        ),
        items: field.choices.entries
            .map(
              (e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: _busy ? null : (v) => setState(() => _value[name] = v),
      );
    }
    if (field.type == 'multi') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(field.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (field.choices.isEmpty) const Text('暂无可选扩展，先在插件 / Skill 页面添加。'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: field.choices.entries
                .map(
                  (e) => FilterChip(
                    label: Text(e.value),
                    selected: strings(_value[name]).contains(e.key),
                    onSelected: _busy
                        ? null
                        : (v) => setState(() {
                            final ids = strings(_value[name]).toSet();
                            v ? ids.add(e.key) : ids.remove(e.key);
                            _value[name] = ids.toList();
                          }),
                  ),
                )
                .toList(),
          ),
        ],
      );
    }
    return TextField(
      controller: _controllers[name],
      enabled: !_busy,
      obscureText: field.type == 'secret',
      minLines: field.lines,
      maxLines: field.type == 'secret'
          ? 1
          : field.lines > 1
          ? field.lines + 5
          : 1,
      autocorrect: false,
      enableSuggestions: field.type != 'secret',
      keyboardType: {'int', 'double', 'optionalDouble'}.contains(field.type)
          ? const TextInputType.numberWithOptions(decimal: true)
          : field.lines > 1
          ? TextInputType.multiline
          : TextInputType.text,
      style: field.type == 'code'
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5)
          : null,
      decoration: InputDecoration(
        labelText: field.label,
        alignLabelWithHint: field.lines > 1,
        helperText: field.hint.isEmpty ? null : field.hint,
        helperMaxLines: 5,
      ),
    );
  }

  Future<void> _loadOptions(AgentField field) async {
    setState(() {
      _busy = true;
      _notice = '';
    });
    try {
      final choices = await field.loadOptions!(_collect());
      if (!mounted) return;
      if (choices.isEmpty) throw const AgentException('服务未提供模型列表，可手动填写模型 ID。');
      final selected = await showDialog<String>(
        context: context,
        builder: (_) => _ModelPicker(choices),
      );
      if (mounted && selected != null) {
        _controllers[field.keyName]!.text = selected;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _notice = e is AgentException
              ? e.message
              : '获取失败，请检查接口地址、API Key 和网络。';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ModelPicker extends StatefulWidget {
  final List<String> models;
  final String title, searchHint;
  final Map<String, String> labels;
  const _ModelPicker(
    this.models, {
    this.title = '选择模型',
    this.searchHint = '搜索模型 ID',
    this.labels = const {},
  });
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final models = widget.models
        .where(
          (m) =>
              m.toLowerCase().contains(query.toLowerCase()) ||
              (widget.labels[m] ?? '').toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 500,
        height: MediaQuery.sizeOf(context).height * .5,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: widget.searchHint,
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: models.length,
                itemBuilder: (_, i) => ListTile(
                  title: Text(widget.labels[models[i]] ?? models[i]),
                  onTap: () => Navigator.pop(context, models[i]),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
