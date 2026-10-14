import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/outgoing_message.dart';
import '../../utils/helpers.dart';

class MessageSettingsDialog extends StatefulWidget {
  final MessageComposerSettings initial;
  final bool isGroup;
  final String body;
  final MessageModel? replyTo;
  final String latestEventId;
  final Map<String, dynamic> Function(OutgoingMessage)? preview;
  final String? markdownTemplateId;
  final List<Map<String, String>>? templateParams;

  const MessageSettingsDialog({
    super.key,
    required this.initial,
    required this.isGroup,
    required this.body,
    this.replyTo,
    this.latestEventId = '',
    this.preview,
    this.markdownTemplateId,
    this.templateParams,
  });

  @override
  State<MessageSettingsDialog> createState() => _MessageSettingsDialogState();
}

class _MessageSettingsDialogState extends State<MessageSettingsDialog> {
  late int _type;
  late int _mediaType;
  late ReplyMode _replyMode;
  late bool _verifyImages;
  late bool _quoteSelected;
  int _keyboardMode = 0;
  final _controllers = <TextEditingController>[];
  late TextEditingController _source,
      _fileInfo,
      _msgId,
      _eventId,
      _sequence,
      _referenceId,
      _keyboardId;
  late List<List<MessageButton>> _rows;
  String _previewText = '输入正文并配置参数后，点击“刷新预览”查看实际请求。';
  String _validationError = '';

  TextEditingController _controller(String text) {
    final controller = TextEditingController(text: text);
    _controllers.add(controller);
    return controller;
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final options = initial.options;
    _type = initial.type;
    _mediaType = initial.mediaFileType;
    _replyMode = options.replyMode;
    _verifyImages = options.forceVerifyImage;
    _quoteSelected = options.quoteSelectedMessage;
    _source = _controller(initial.mediaSource);
    _fileInfo = _controller(initial.fileInfo);
    _msgId = _controller(options.messageId);
    _eventId = _controller(options.eventId);
    _sequence = _controller(options.sequence?.toString() ?? '');
    _referenceId = _controller(options.referenceId);
    _keyboardId = _controller(options.keyboard?.templateId ?? '');
    _rows =
        options.keyboard?.rows
            .map((row) => List<MessageButton>.from(row))
            .toList() ??
        [];
    _keyboardMode = options.keyboard == null
        ? 0
        : (options.keyboard!.templateId.isNotEmpty ? 1 : 2);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  MessageComposerSettings _settings() {
    final rawSequence = _sequence.text.trim();
    final sequence = rawSequence.isEmpty ? null : int.tryParse(rawSequence);
    if (rawSequence.isNotEmpty && sequence == null) {
      throw const FormatException('回复序号必须是整数');
    }
    return MessageComposerSettings(
      explicitType: true,
      type: _type,
      mediaFileType: _mediaType,
      mediaSource: _source.text.trim(),
      fileInfo: _fileInfo.text.trim(),
      options: MessageSendOptions(
        replyMode: _replyMode,
        messageId: _replyMode == ReplyMode.message ? _msgId.text.trim() : '',
        eventId: _replyMode == ReplyMode.event ? _eventId.text.trim() : '',
        sequence: _replyMode == ReplyMode.active ? null : sequence,
        referenceId: _referenceId.text.trim(),
        quoteSelectedMessage: _quoteSelected,
        forceVerifyImage: _type == 2 && _verifyImages,
        keyboard: _keyboardMode == 1
            ? MessageKeyboard(templateId: _keyboardId.text.trim())
            : (_keyboardMode == 2
                  ? MessageKeyboard(
                      rows: _rows
                          .map((row) => List<MessageButton>.from(row))
                          .toList(),
                    )
                  : null),
      ),
    );
  }

  void _error(String message) => setState(() => _validationError = message);

  void _apply() {
    try {
      final settings = _settings();
      if (_keyboardMode == 1 && _keyboardId.text.trim().isEmpty) {
        throw const FormatException('请填写按钮模板 ID');
      }
      final error = settings.options.validate(isGroup: widget.isGroup);
      if (error != null) throw FormatException(error);
      Navigator.pop(context, settings);
    } on FormatException catch (e) {
      _error(e.message.toString());
    }
  }

  void _refreshPreview() {
    try {
      final settings = _settings();
      final request = OutgoingMessage(
        type: settings.type,
        content: widget.body,
        mediaFileType: settings.mediaFileType,
        mediaSource: settings.mediaSource,
        fileInfo: settings.fileInfo,
        options: settings.options,
        markdownTemplateId: settings.type == 2
            ? widget.markdownTemplateId
            : null,
        templateParams: settings.type == 2 ? widget.templateParams : null,
      );
      final body = widget.preview?.call(request) ?? request.toPayload();
      setState(
        () => _previewText = const JsonEncoder.withIndent('  ').convert(body),
      );
    } catch (e) {
      setState(
        () => _previewText = '暂不能发送：${e is FormatException ? e.message : e}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height - 64).clamp(300.0, 720.0);
    return Dialog(
      child: SizedBox(
        width: 800,
        height: height,
        child: DefaultTabController(
          length: 4,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '消息设置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(widget.isGroup ? '当前：群聊' : '当前：单聊'),
                    IconButton(
                      tooltip: '关闭消息设置',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              TabBar(
                isScrollable: MediaQuery.sizeOf(context).width < 700,
                tabs: const [
                  Tab(text: '消息类型'),
                  Tab(text: '按钮键盘'),
                  Tab(text: '回复与引用'),
                  Tab(text: '请求预览'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _page(_messagePage()),
                    _page(_keyboardPage()),
                    _page(_replyPage()),
                    _page(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _refreshPreview,
                            icon: const Icon(Icons.refresh),
                            label: const Text('刷新预览'),
                          ),
                          const SizedBox(height: 12),
                          const Text('预览不会上传文件或发送消息，也不会占用回复序号。'),
                          const SizedBox(height: 12),
                          SelectableText(
                            _previewText,
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_validationError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    _validationError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '设置用于当前会话的后续发送，切换会话不会串用。',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        const MessageComposerSettings(),
                      ),
                      child: const Text('恢复默认'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _apply, child: const Text('应用设置')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(Widget child) =>
      SingleChildScrollView(padding: const EdgeInsets.all(20), child: child);

  Widget _messagePage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<int>(
        key: ValueKey('message-type-$_type'),
        isExpanded: true,
        initialValue: _type,
        decoration: const InputDecoration(labelText: '消息类型'),
        items: const [
          DropdownMenuItem(value: 0, child: Text('普通文本')),
          DropdownMenuItem(value: 2, child: Text('Markdown 富文本')),
          DropdownMenuItem(value: 7, child: Text('富媒体：图片 / 视频 / 语音 / 文件')),
        ],
        onChanged: (value) => setState(() {
          _type = value!;
          if (_type != 2) {
            _keyboardMode = 0;
            _verifyImages = false;
          }
        }),
      ),
      const SizedBox(height: 16),
      if (_type == 2)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('校验 Markdown 图片转存结果'),
          subtitle: const Text('图片转存失败时不发送消息（force_verify_image_resource）'),
          value: _verifyImages,
          onChanged: (value) => setState(() => _verifyImages = value),
        ),
      if (_type == 7) ...[
        DropdownButtonFormField<int>(
          initialValue: _mediaType,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '媒体类型'),
          items: const [
            DropdownMenuItem(value: 1, child: Text('图片')),
            DropdownMenuItem(value: 2, child: Text('视频')),
            DropdownMenuItem(value: 3, child: Text('语音')),
            DropdownMenuItem(value: 4, child: Text('文件')),
          ],
          onChanged: (value) => setState(() => _mediaType = value!),
        ),
        const SizedBox(height: 16),
        _field('公网文件 URL 或本地文件路径', _source, hint: 'https://...'),
        OutlinedButton.icon(
          onPressed: () async {
            final result = await FilePicker.pickFiles(type: FileType.any);
            if (!mounted) return;
            final path = result?.files.single.path;
            if (path != null) {
              setState(() {
                _source.text = path;
                _fileInfo.clear();
              });
            }
          },
          icon: const Icon(Icons.folder_open),
          label: const Text('选择本地媒体文件'),
        ),
        const SizedBox(height: 12),
        _field('已有 file_info（可选，填写后跳过上传）', _fileInfo, lines: 2),
        const Text('file_info 不能跨群聊/单聊使用，过期后需重新上传。本地直传最大 5 MB；较大的文件请使用公网 URL。'),
      ],
      if (_type != 7) const Text('正文在聊天输入框填写。按钮键盘会随 Markdown 一起发送。'),
      const SizedBox(height: 16),
      const Text('群聊不支持流式消息；已废弃的 Markdown 模板保留在输入框原有兼容入口。'),
    ],
  );

  Widget _keyboardPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<int>(
        key: ValueKey('keyboard-mode-$_keyboardMode'),
        isExpanded: true,
        initialValue: _keyboardMode,
        decoration: const InputDecoration(labelText: '按钮键盘'),
        items: const [
          DropdownMenuItem(value: 0, child: Text('不附带按钮')),
          DropdownMenuItem(value: 1, child: Text('使用按钮模板')),
          DropdownMenuItem(value: 2, child: Text('自定义按钮')),
        ],
        onChanged: (value) => setState(() {
          _keyboardMode = value!;
          if (_keyboardMode != 0) _type = 2;
        }),
      ),
      const SizedBox(height: 16),
      if (_keyboardMode == 1) _field('按钮模板 ID', _keyboardId),
      if (_keyboardMode == 2) ...[
        const Text('最多 5 行，每行 5 个按钮。点击按钮可编辑动作、权限和二次确认。'),
        const SizedBox(height: 12),
        for (var row = 0; row < _rows.length; row++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('第 ${row + 1} 行'),
                      const Spacer(),
                      IconButton(
                        tooltip: '删除此行',
                        onPressed: () => setState(() => _rows.removeAt(row)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var column = 0; column < _rows[row].length; column++)
                        InputChip(
                          label: Text(_rows[row][column].label),
                          onPressed: () => _editButton(row, column),
                          onDeleted: () =>
                              setState(() => _rows[row].removeAt(column)),
                        ),
                      if (_rows[row].length < 5)
                        ActionChip(
                          avatar: const Icon(Icons.add, size: 16),
                          label: const Text('添加按钮'),
                          onPressed: () => _editButton(row, null),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: _rows.length >= 5
              ? null
              : () => setState(() => _rows.add([])),
          icon: const Icon(Icons.add),
          label: const Text('添加一行按钮'),
        ),
      ],
      const SizedBox(height: 16),
      const Text('按钮能力由 QQ 开放平台权限决定。回调按钮会接收互动事件并自动确认，回调数据可在日志中查看。'),
      if (widget.isGroup) const Text('群聊按钮不支持单聊专用的自动发送、指令引用和唤起选图。'),
    ],
  );

  Future<void> _editButton(int row, int? column) async {
    final button = await showDialog<MessageButton>(
      context: context,
      builder: (_) => _ButtonEditor(
        isGroup: widget.isGroup,
        initial: column == null
            ? MessageButton(id: 'btn_${generateId()}', label: '新按钮')
            : _rows[row][column],
      ),
    );
    if (button == null || !mounted) return;
    setState(() {
      if (column == null) {
        _rows[row].add(button);
      } else {
        _rows[row][column] = button;
      }
    });
  }

  Widget _replyPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<ReplyMode>(
        initialValue: _replyMode,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '发送方式'),
        items: const [
          DropdownMenuItem(
            value: ReplyMode.automatic,
            child: Text('自动：优先回复最近有效消息'),
          ),
          DropdownMenuItem(
            value: ReplyMode.active,
            child: Text('主动发送：不携带回复 ID'),
          ),
          DropdownMenuItem(value: ReplyMode.message, child: Text('指定消息 ID 回复')),
          DropdownMenuItem(value: ReplyMode.event, child: Text('指定事件 ID 回复')),
        ],
        onChanged: (value) => setState(() => _replyMode = value!),
      ),
      const SizedBox(height: 16),
      if (_replyMode == ReplyMode.message) ...[
        _field('被动回复消息 ID（msg_id）', _msgId),
        if (widget.replyTo != null && !widget.replyTo!.isFromBot)
          TextButton(
            onPressed: () => setState(() => _msgId.text = widget.replyTo!.id),
            child: const Text('填入当前选中的消息 ID'),
          ),
      ],
      if (_replyMode == ReplyMode.event) ...[
        _field('可回复的事件 ID（event_id）', _eventId),
        OutlinedButton(
          onPressed: widget.latestEventId.isEmpty
              ? null
              : () => setState(() => _eventId.text = widget.latestEventId),
          child: const Text('填入最近可回复事件'),
        ),
        const Text('支持按钮互动、入群等可回复事件；事件 ID 与消息 ID 二选一。'),
      ],
      if (_replyMode != ReplyMode.active)
        _field('回复序号（留空则自动递增）', _sequence, hint: 'msg_seq，例如 1'),
      const Divider(height: 28),
      _field('引用索引（可选）', _referenceId, hint: 'REFIDX_... 或消息事件中的 msg_idx'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('引用聊天区当前选中的消息'),
        subtitle: Text(
          widget.replyTo == null
              ? '先在聊天区点击消息的“回复”'
              : (widget.replyTo!.referenceIndex.isEmpty
                    ? '这条历史消息没有引用索引，只能关联回复来源'
                    : '已取得引用索引，可在 QQ 中显示引用'),
        ),
        value: _quoteSelected,
        onChanged: (value) => setState(() => _quoteSelected = value),
      ),
      const Text(
        '引用索引和被动回复 ID 是两个字段。普通消息 ID 不能代替 REFIDX / msg_idx；机器人自己的消息使用发送响应的 ref_idx。',
      ),
    ],
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      maxLines: lines,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

class _ButtonEditor extends StatefulWidget {
  final MessageButton initial;
  final bool isGroup;
  const _ButtonEditor({required this.initial, required this.isGroup});
  @override
  State<_ButtonEditor> createState() => _ButtonEditorState();
}

class _ButtonEditorState extends State<_ButtonEditor> {
  String _validationError = '';
  final _controllers = <TextEditingController>[];
  late TextEditingController _id,
      _label,
      _visited,
      _data,
      _users,
      _group,
      _tips,
      _modal,
      _confirm,
      _cancel;
  late int _style, _action, _permission;
  late bool _enter, _reply, _imagePicker;

  TextEditingController _controller(String text) {
    final c = TextEditingController(text: text);
    _controllers.add(c);
    return c;
  }

  @override
  void initState() {
    super.initState();
    final b = widget.initial;
    _id = _controller(b.id);
    _label = _controller(b.label);
    _visited = _controller(b.visitedLabel);
    _data = _controller(b.data);
    _users = _controller(b.userIds.join('\n'));
    _group = _controller(b.groupId);
    _tips = _controller(b.unsupportedTips);
    _modal = _controller(b.confirmContent);
    _confirm = _controller(b.confirmText);
    _cancel = _controller(b.cancelText);
    _style = b.style;
    _action = b.actionType;
    _permission = b.permissionType;
    _enter = b.enter;
    _reply = b.reply;
    _imagePicker = b.openImagePicker;
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final b = MessageButton(
      id: _id.text.trim(),
      label: _label.text,
      visitedLabel: _visited.text,
      style: _style,
      actionType: _action,
      data: _data.text,
      permissionType: _permission,
      userIds: _users.text
          .split(RegExp(r'[\s,，]+'))
          .where((id) => id.isNotEmpty)
          .toList(),
      groupId: _action == 1 ? _group.text.trim() : '',
      unsupportedTips: _tips.text,
      enter: !widget.isGroup && _action == 2 && _enter,
      reply: !widget.isGroup && _action == 2 && _reply,
      openImagePicker: !widget.isGroup && _action == 2 && _imagePicker,
      confirmContent: _modal.text,
      confirmText: _confirm.text,
      cancelText: _cancel.text,
    );
    final error = b.validate(isGroup: widget.isGroup);
    if (error != null) {
      setState(() => _validationError = error);
      return;
    }
    Navigator.pop(context, b);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('编辑消息按钮'),
        if (_validationError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _validationError,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    ),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field('按钮 ID（键盘内唯一）', _id),
            _field('按钮文字（最多 10 字）', _label),
            _field('点击后文字（可选）', _visited),
            _dropdown('按钮样式', _style, const {
              0: '灰色线框',
              1: '蓝色线框',
              3: '白底红字',
              4: '蓝底白字',
            }, (v) => setState(() => _style = v)),
            _dropdown('按钮动作', _action, const {
              0: '跳转：网址 / 小程序',
              1: '回调：发送数据到机器人',
              2: '指令：填入聊天输入框',
            }, (v) => setState(() => _action = v)),
            _field(
              _action == 0 ? '跳转地址' : (_action == 1 ? '回调数据' : '指令内容'),
              _data,
              lines: 2,
            ),
            _dropdown('可操作用户', _permission, const {
              2: '所有人',
              1: '仅管理员',
              0: '指定用户',
            }, (v) => setState(() => _permission = v)),
            if (_permission == 0)
              _field('用户 OpenID（换行或逗号分隔）', _users, lines: 2),
            if (_action == 1) _field('互斥按钮分组 ID（可选）', _group),
            if (_action == 2) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('点击后自动发送（仅单聊）'),
                value: !widget.isGroup && _enter,
                onChanged: widget.isGroup
                    ? null
                    : (v) => setState(() => _enter = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('指令带引用回复（仅单聊）'),
                value: !widget.isGroup && _reply,
                onChanged: widget.isGroup
                    ? null
                    : (v) => setState(() => _reply = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('唤起 QQ 手机端选图（仅单聊）'),
                subtitle: const Text('启用后自动发送选项不生效；桌面 QQ 不支持'),
                value: !widget.isGroup && _imagePicker,
                onChanged: widget.isGroup
                    ? null
                    : (v) => setState(() => _imagePicker = v),
              ),
            ],
            _field('低版本客户端提示', _tips),
            const Divider(),
            _field('二次确认提示（可选，最多 40 字，不能含 URL）', _modal, lines: 2),
            _field('确认按钮文字（最多 4 字）', _confirm),
            _field('取消按钮文字（最多 4 字）', _cancel),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存按钮')),
    ],
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      maxLines: lines,
      decoration: InputDecoration(labelText: label),
    ),
  );
  Widget _dropdown(
    String label,
    int value,
    Map<int, String> values,
    ValueChanged<int> changed,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final e in values.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) => changed(v!),
    ),
  );
}
