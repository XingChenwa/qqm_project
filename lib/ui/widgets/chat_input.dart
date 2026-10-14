import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/message.dart';
import '../../models/outgoing_message.dart';
import '../../utils/helpers.dart';
import '../themes/app_theme.dart';
import 'message_settings_dialog.dart';

class ChatInput extends StatefulWidget {
  final Future<bool> Function(String text) onSendText;
  final Future<bool> Function(
    String markdown, {
    bool? useTemplate,
    String? templateId,
    List<Map<String, String>>? templateParams,
  })
  onSendMarkdown;
  final Future<bool> Function(String imageUrl) onSendImage;
  final Future<bool> Function(String command, List<String> args)?
  onSlashCommand;
  final String Function()? sendError;
  final MessageModel? replyTo;
  final VoidCallback? onCancelReply;
  final VoidCallback? onEmojiTap;
  final Future<bool> Function(OutgoingMessage)? onSendConfigured;
  final Map<String, dynamic> Function(OutgoingMessage)? previewConfigured;
  final bool isGroup;
  final String latestEventId;
  final String defaultMarkdownTemplateId;
  final List<Map<String, String>> defaultTemplateParams;

  const ChatInput({
    super.key,
    required this.onSendText,
    required this.onSendMarkdown,
    required this.onSendImage,
    this.onSlashCommand,
    this.sendError,
    this.replyTo,
    this.onCancelReply,
    this.onEmojiTap,
    this.onSendConfigured,
    this.previewConfigured,
    this.isGroup = false,
    this.latestEventId = '',
    this.defaultMarkdownTemplateId = '',
    this.defaultTemplateParams = const [],
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _templateIdController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final List<Map<String, String>> _templateVars = [];

  bool _isMarkdownMode = false;
  bool _isTemplateMode = false;
  bool _showTemplateEditor = false;
  bool _isSending = false;
  MessageComposerSettings _sendSettings = const MessageComposerSettings();

  bool get _useConfigured =>
      widget.onSendConfigured != null &&
      (_sendSettings.isConfigured ||
          widget.replyTo?.referenceIndex.isNotEmpty == true ||
          widget.replyTo?.isFromBot == true);

  OutgoingMessage _request(String text) {
    final type = _sendSettings.explicitType
        ? _sendSettings.type
        : (_sendSettings.type == 7
              ? 7
              : (_isMarkdownMode || containsMarkdown(text) ? 2 : 0));
    return OutgoingMessage(
      type: type,
      content: text,
      mediaFileType: _sendSettings.mediaFileType,
      mediaSource: _sendSettings.mediaSource,
      fileInfo: _sendSettings.fileInfo,
      options: _sendSettings.options,
      markdownTemplateId: type == 2 && _isTemplateMode
          ? (_templateIdController.text.trim().isNotEmpty
                ? _templateIdController.text.trim()
                : widget.defaultMarkdownTemplateId)
          : null,
      templateParams: _isTemplateMode
          ? (_templateVars.isEmpty
                ? widget.defaultTemplateParams
                : _templateVars
                      .map((param) => Map<String, String>.from(param))
                      .toList())
          : null,
    );
  }

  Future<void> _openSettings() async {
    final initial = _sendSettings.withType(
      _sendSettings.explicitType
          ? _sendSettings.type
          : (_sendSettings.type == 7
                ? 7
                : (_isMarkdownMode || containsMarkdown(_textController.text)
                      ? 2
                      : 0)),
    );
    final result = await showDialog<MessageComposerSettings>(
      context: context,
      builder: (_) => MessageSettingsDialog(
        initial: initial,
        isGroup: widget.isGroup,
        body: _textController.text,
        replyTo: widget.replyTo,
        latestEventId: widget.latestEventId,
        preview: widget.previewConfigured,
        markdownTemplateId: _isTemplateMode
            ? (_templateIdController.text.trim().isNotEmpty
                  ? _templateIdController.text.trim()
                  : widget.defaultMarkdownTemplateId)
            : null,
        templateParams: _isTemplateMode
            ? (_templateVars.isEmpty
                  ? widget.defaultTemplateParams
                  : _templateVars
                        .map((param) => Map<String, String>.from(param))
                        .toList())
            : null,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _sendSettings = result;
      _isMarkdownMode = result.type == 2;
      if (!_isMarkdownMode) {
        _isTemplateMode = false;
        _showTemplateEditor = false;
      }
    });
  }

  bool get _isSlashCommand => _textController.text.trimLeft().startsWith('/');

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _textController.dispose();
    _templateIdController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _textController.text;
    if ((text.trim().isEmpty && !_isTemplateMode && _sendSettings.type != 7) ||
        _isSending) {
      return;
    }

    setState(() => _isSending = true);
    var sent = true;

    try {
      final command = parseSlashCommand(text);
      if (_useConfigured) {
        sent = await widget.onSendConfigured!(_request(text));
      } else if (!_isMarkdownMode &&
          command != null &&
          widget.onSlashCommand != null) {
        sent = await widget.onSlashCommand!(command.command, command.args);
      } else if (_isMarkdownMode || containsMarkdown(text)) {
        sent = await widget.onSendMarkdown(
          text,
          useTemplate: _isTemplateMode,
          templateId:
              _isTemplateMode && _templateIdController.text.trim().isNotEmpty
              ? _templateIdController.text.trim()
              : null,
          templateParams: _isTemplateMode && _templateVars.isNotEmpty
              ? _templateVars
                    .map((param) => Map<String, String>.from(param))
                    .toList()
              : null,
        );
      } else {
        sent = await widget.onSendText(text);
      }

      if (!mounted) return;
      if (sent) {
        if (_textController.text == text) _textController.clear();
        widget.onCancelReply?.call();
        _focusNode.requestFocus();
      } else {
        _showSendError();
      }
    } catch (e) {
      if (mounted) _showSendError('发送失败: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showSendError([String? error]) {
    if (!mounted) return;
    final detail = error ?? widget.sendError?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          detail == null || detail.isEmpty ? '发送失败，请查看日志中的详细原因' : detail,
        ),
        backgroundColor: AppTheme.qqRed,
      ),
    );
  }

  Future<void> _sendImage(String path) async {
    if (_isSending || !mounted) return;
    setState(() => _isSending = true);
    try {
      final sent = _useConfigured
          ? await widget.onSendConfigured!(
              OutgoingMessage(
                type: 7,
                mediaSource: path,
                options: _sendSettings.options,
              ),
            )
          : await widget.onSendImage(path);
      if (!mounted) return;
      if (sent) {
        widget.onCancelReply?.call();
      } else {
        _showSendError();
      }
    } catch (e) {
      _showSendError('图片发送失败: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _pickImage() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final file = await _imagePicker.pickImage(
                    source: ImageSource.gallery,
                  );
                  if (file == null) return;
                  await _sendImage(file.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('输入图片 URL'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final url = await _askImageUrl();
                  if (url == null || url.trim().isEmpty) return;
                  await _sendImage(url.trim());
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('选择本地图片文件'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final result = await FilePicker.pickFiles(
                    type: FileType.image,
                  );
                  final path = result?.files.single.path;
                  if (path == null) return;
                  await _sendImage(File(path).path);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _askImageUrl() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入图片 URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.replyTo != null) _replyPreview(widget.replyTo!),
          if (_sendSettings.isConfigured) _settingsSummary(),
          if (_isTemplateMode && _showTemplateEditor) _templateEditor(),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (widget.onSendConfigured != null)
                        _toolButton(
                          icon: Icons.tune_rounded,
                          selected: _sendSettings.isConfigured,
                          tooltip: '消息设置',
                          onPressed: _openSettings,
                        ),
                      _toolButton(
                        icon: Icons.code_rounded,
                        selected: _isMarkdownMode && !_isTemplateMode,
                        tooltip: '自定义 Markdown',
                        onPressed: () {
                          if (_isMarkdownMode &&
                              (_sendSettings.options.keyboard != null ||
                                  _sendSettings.options.forceVerifyImage)) {
                            _showSendError(
                              '当前设置需要 Markdown，请先在“消息设置”停用按钮键盘或图片校验',
                            );
                            return;
                          }
                          setState(() {
                            _isMarkdownMode = !_isMarkdownMode;
                            _sendSettings = _sendSettings.withType(
                              _isMarkdownMode ? 2 : 0,
                            );
                            if (!_isMarkdownMode) {
                              _isTemplateMode = false;
                              _showTemplateEditor = false;
                            }
                          });
                        },
                      ),
                      if (_isMarkdownMode)
                        _toolButton(
                          icon: Icons.view_column_rounded,
                          selected: _isTemplateMode,
                          tooltip: 'Markdown 模板',
                          onPressed: () => setState(() {
                            _isTemplateMode = !_isTemplateMode;
                            _showTemplateEditor = _isTemplateMode;
                          }),
                        ),
                      _toolButton(
                        icon: Icons.image_outlined,
                        selected: false,
                        tooltip: '发送图片',
                        onPressed: _pickImage,
                      ),
                      _toolButton(
                        icon: Icons.emoji_emotions_outlined,
                        selected: false,
                        tooltip: '选择表情',
                        onPressed: widget.onEmojiTap ?? () {},
                      ),
                      const SizedBox(width: 8),
                      if (_isSlashCommand &&
                          !_isMarkdownMode &&
                          !_useConfigured)
                        _modeChip('命令模式', AppTheme.amber),
                      if (_isMarkdownMode)
                        _modeChip(
                          _isTemplateMode ? '模板消息' : 'Markdown',
                          AppTheme.qqBlue,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Tooltip(
                message: '回车换行 · Ctrl+回车发送',
                child: Icon(Icons.keyboard_return_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): _sendMessage,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _sendMessage,
                  },
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    maxLines: 5,
                    minLines: 1,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: _hintText,
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: IconButton.filled(
                          tooltip: '发送',
                          onPressed: _isSending ? null : _sendMessage,
                          icon: _isSending
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded, size: 18),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _hintText {
    if (_sendSettings.type == 7) return '富媒体已配置，点击发送即可（文件来源在消息设置中填写）';
    if (_isTemplateMode) return '输入 Markdown 模板内容';
    if (_isMarkdownMode) return '输入 Markdown 内容';
    if (_isSlashCommand) {
      return '输入命令，例如 /help、/天气 北京、/ip 114.114.114.114、/dice 2d6';
    }
    return '输入消息...';
  }

  Widget _replyPreview(MessageModel message) {
    final content = message.content.isNotEmpty ? message.content : '[消息]';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.qqBlue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: AppTheme.qqBlue, width: 3),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.reply_rounded, size: 16, color: AppTheme.qqBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${message.referenceIndex.isEmpty ? '回复' : '引用'} ${message.senderName}: $content',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '取消引用',
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: widget.onCancelReply,
              ),
            ],
          ),
          if (message.referenceIndex.isNotEmpty &&
              widget.onSendConfigured != null)
            Row(
              children: [
                Checkbox(
                  value: _sendSettings.options.quoteSelectedMessage,
                  onChanged: (value) => setState(
                    () => _sendSettings = _sendSettings.withOptions(
                      _sendSettings.options.withQuote(value!),
                    ),
                  ),
                ),
                const Flexible(
                  child: Text('在 QQ 中显示引用消息', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _settingsSummary() {
    final options = _sendSettings.options;
    final labels = <String>[
      if (_sendSettings.explicitType && _sendSettings.type != 7)
        _sendSettings.type == 2 ? 'Markdown' : '普通文本',
      if (_sendSettings.type == 7)
        const {
          1: '图片',
          2: '视频',
          3: '语音',
          4: '文件',
        }[_sendSettings.mediaFileType]!,
      if (options.keyboard != null)
        options.keyboard!.templateId.isNotEmpty
            ? '按钮模板'
            : '自定义按钮 ${options.keyboard!.rows.fold<int>(0, (count, row) => count + row.length)} 个',
      if (options.forceVerifyImage) '校验图片',
      if (options.replyMode != ReplyMode.automatic)
        const {
          ReplyMode.active: '主动发送',
          ReplyMode.message: '指定消息回复',
          ReplyMode.event: '事件回复',
        }[options.replyMode]!,
      if (options.sequence != null) '序号 ${options.sequence}',
      if (options.referenceId.isNotEmpty) '指定引用',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '发送设置：${labels.join(' · ')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: '清除发送设置',
            icon: const Icon(Icons.close, size: 16),
            onPressed: _isSending
                ? null
                : () => setState(() {
                    _sendSettings = const MessageComposerSettings();
                    _isMarkdownMode = false;
                    _isTemplateMode = false;
                    _showTemplateEditor = false;
                  }),
          ),
        ],
      ),
    );
  }

  Widget _templateEditor() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.qqGreen.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.qqGreen.withValues(alpha: 0.18)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.view_column_rounded,
                size: 16,
                color: AppTheme.qqGreen,
              ),
              const SizedBox(width: 6),
              const Text(
                '模板参数',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: '添加参数',
                onPressed: () =>
                    setState(() => _templateVars.add({'key': '', 'value': ''})),
                icon: const Icon(
                  Icons.add_circle_outline,
                  size: 18,
                  color: AppTheme.qqGreen,
                ),
              ),
            ],
          ),
          TextField(
            controller: _templateIdController,
            decoration: const InputDecoration(hintText: '模板 ID，留空则使用设置里的默认模板'),
            style: const TextStyle(fontSize: 12),
          ),
          if (_templateVars.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...List.generate(_templateVars.length, (index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        decoration: const InputDecoration(hintText: '变量名'),
                        style: const TextStyle(fontSize: 12),
                        onChanged: (value) =>
                            _templateVars[index]['key'] = value,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(hintText: '值'),
                        style: const TextStyle(fontSize: 12),
                        onChanged: (value) =>
                            _templateVars[index]['value'] = value,
                      ),
                    ),
                    IconButton(
                      tooltip: '删除参数',
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        size: 18,
                        color: AppTheme.qqRed,
                      ),
                      onPressed: () =>
                          setState(() => _templateVars.removeAt(index)),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required bool selected,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 19),
        color: selected ? AppTheme.qqBlue : Theme.of(context).hintColor,
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? AppTheme.qqBlue.withValues(alpha: 0.11)
              : Colors.transparent,
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _modeChip(String label, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
