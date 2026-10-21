import '../../utils/platforms.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/message.dart';
import '../../models/outgoing_message.dart';
import '../../utils/helpers.dart';
import '../../utils/qq_mentions.dart';
import '../themes/app_theme.dart';
import 'message_settings_dialog.dart';
import 'markdown_workbench.dart';
import 'app_dialogs.dart';
import 'composer_keyboard.dart';

/// Sends draft actions to the currently mounted conversation, never a message.
class ChatInputController extends ChangeNotifier {
  String _memberId = '';
  void mention(String memberId) {
    _memberId = memberId;
    notifyListeners();
  }
}

class ChatInput extends StatefulWidget {
  final ChatInputController? controller;
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
  final VoidCallback? onMessageSent;
  final Future<bool> Function(OutgoingMessage)? onSendConfigured;
  final Map<String, dynamic> Function(OutgoingMessage)? previewConfigured;
  final bool isGroup;
  final Map<String, String> mentionCandidates;
  final String latestEventId;
  final String defaultMarkdownTemplateId;
  final List<Map<String, String>> defaultTemplateParams;

  const ChatInput({
    super.key,
    this.controller,
    required this.onSendText,
    required this.onSendMarkdown,
    required this.onSendImage,
    this.onSlashCommand,
    this.sendError,
    this.replyTo,
    this.onCancelReply,
    this.onEmojiTap,
    this.onMessageSent,
    this.onSendConfigured,
    this.previewConfigured,
    this.isGroup = false,
    this.mentionCandidates = const {},
    this.latestEventId = '',
    this.defaultMarkdownTemplateId = '',
    this.defaultTemplateParams = const [],
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _markdownController = TextEditingController();
  final TextEditingController _templateIdController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final List<Map<String, String>> _templateVars = [];

  bool _isMarkdownMode = false;
  bool _isTemplateMode = false;
  bool _showTemplateEditor = false;
  bool _isSending = false;
  bool _isConfirming = false;
  bool _moreTools = false;
  MessageComposerSettings _sendSettings = const MessageComposerSettings();

  TextEditingController get _activeController =>
      _isMarkdownMode ? _markdownController : _textController;

  bool get _useConfigured =>
      widget.onSendConfigured != null &&
      (_sendSettings.isConfigured ||
          widget.replyTo?.referenceIndex.isNotEmpty == true ||
          widget.replyTo?.isFromBot == true);

  OutgoingMessage _request(String text) {
    final type = containsQqMention(text)
        ? 2
        : _sendSettings.explicitType
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
                : (_isMarkdownMode || containsMarkdown(_activeController.text)
                      ? 2
                      : 0)),
    );
    final result = await showDialog<MessageComposerSettings>(
      context: context,
      builder: (_) => MessageSettingsDialog(
        initial: initial,
        isGroup: widget.isGroup,
        body: _activeController.text,
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
    if (_isMarkdownMode &&
        containsQqMention(_markdownController.text) &&
        result.type != 2) {
      _showSendError('@ 群成员只能用 Markdown 发送，请先移除 @ 标签再更改消息类型。');
      return;
    }
    setState(() {
      if (!_isMarkdownMode &&
          result.type == 2 &&
          _markdownController.text.isEmpty) {
        _markdownController.text = _textController.text;
      }
      _sendSettings = result;
      _isMarkdownMode = result.type == 2;
      if (!_isMarkdownMode) {
        _isTemplateMode = false;
        _showTemplateEditor = false;
      }
    });
  }

  Future<void> _mentionUser() async {
    if (_isSending || !widget.isGroup) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _MentionPicker(members: widget.mentionCandidates),
    );
    if (!mounted || selected == null) return;
    _insertMention(selected);
  }

  void _onMentionRequested() => _insertMention(widget.controller!._memberId);

  void _insertMention(String selected, {bool everyone = false}) {
    if (!widget.isGroup || !mounted) return;
    if (_isSending) {
      _showSendError('当前消息正在发送，请稍后再插入 @。');
      return;
    }
    if (!everyone && !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(selected)) {
      _showSendError('请输入有效的成员 OpenID，不能包含空格、引号或标签。');
      return;
    }
    if (!_isMarkdownMode) {
      if (_markdownController.text.isEmpty) {
        _markdownController.value = _textController.value;
      }
    }
    setState(() {
      _isMarkdownMode = true;
      _isTemplateMode = false;
      _showTemplateEditor = false;
      _sendSettings = _sendSettings.withType(2);
    });
    final draft = _markdownController;
    final selection = draft.selection;
    final start = selection.isValid ? selection.start : draft.text.length;
    final end = selection.isValid ? selection.end : start;
    final mention = everyone
        ? '<qqbot-at-everyone /> '
        : '<qqbot-at-user id="$selected" /> ';
    draft.value = TextEditingValue(
      text: draft.text.replaceRange(start, end, mention),
      selection: TextSelection.collapsed(offset: start + mention.length),
    );
    _focusNode.requestFocus();
  }

  bool get _isSlashCommand => _activeController.text.trimLeft().startsWith('/');

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));
    _markdownController.addListener(() => setState(() {}));
    widget.controller?.addListener(_onMentionRequested);
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onMentionRequested);
      widget.controller?.addListener(_onMentionRequested);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onMentionRequested);
    _textController.dispose();
    _markdownController.dispose();
    _templateIdController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final controller = _activeController;
    final text = controller.text;
    if (!_isMarkdownMode && containsQqMention(text)) {
      _showSendError('@ 群成员只能用 Markdown 发送，请先切换到 Markdown 工作区。');
      return;
    }
    if ((text.trim().isEmpty && !_isTemplateMode && _sendSettings.type != 7) ||
        _isSending ||
        _isConfirming) {
      return;
    }

    _isConfirming = containsQqEveryoneMention(text);
    var sent = true;

    try {
      if (containsQqEveryoneMention(text)) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('发送 @ 全体成员？'),
            content: const Text('这条 Markdown 将提醒全体成员，QQ 平台会校验机器人的发送权限。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('确认发送'),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      }
      setState(() => _isSending = true);
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
        if (controller.text == text) controller.clear();
        widget.onCancelReply?.call();
        _focusNode.requestFocus();
        widget.onMessageSent?.call();
      } else {
        _showSendError();
      }
    } catch (e) {
      if (mounted) {
        _showSendError(e is FormatException ? e.message : '发送失败: $e');
      }
    } finally {
      _isConfirming = false;
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showSendError([String? error]) {
    if (!mounted) return;
    final detail = error ?? widget.sendError?.call();
    AppDialogs.show(
      context,
      detail == null || detail.isEmpty ? '发送失败，请查看日志中的详细原因' : detail,
      title:
          RegExp(
            r'无.{0,8}权限|没有.{0,8}权限|permission|forbidden',
            caseSensitive: false,
          ).hasMatch(detail ?? '')
          ? '无权限发送'
          : '发送失败',
      error: true,
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
        widget.onMessageSent?.call();
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
    final mobile = usePhoneLayout(context);

    return SingleChildScrollView(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
          boxShadow: mobile
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.05),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
        ),
        padding: mobile
            ? const EdgeInsets.fromLTRB(8, 8, 12, 10)
            : const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyTo != null) _replyPreview(widget.replyTo!),
            if (_sendSettings.isConfigured) _settingsSummary(),
            if (_isTemplateMode && _showTemplateEditor) _templateEditor(),
            if (!mobile || _moreTools || _isMarkdownMode)
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
                          if (widget.isGroup) ...[
                            _toolButton(
                              icon: Icons.alternate_email_rounded,
                              selected: false,
                              tooltip: '@ 群成员',
                              onPressed: _mentionUser,
                            ),
                            _toolButton(
                              icon: Icons.groups_outlined,
                              selected: false,
                              tooltip: '@ 全体成员',
                              onPressed: () =>
                                  _insertMention('', everyone: true),
                            ),
                          ],
                          _toolButton(
                            icon: Icons.code_rounded,
                            selected: _isMarkdownMode && !_isTemplateMode,
                            tooltip: '自定义 Markdown',
                            onPressed: () {
                              if (_isMarkdownMode &&
                                  containsQqMention(_markdownController.text)) {
                                _showSendError(
                                  '@ 群成员只能用 Markdown 发送，请先移除 @ 标签再切换为普通文本。',
                                );
                                return;
                              }
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
                        ],
                      ),
                    ),
                  ),
                  if (!mobile) const SizedBox(width: 6),
                  if (!mobile)
                    const Tooltip(
                      message: '回车发送 · Ctrl+回车换行',
                      child: Icon(Icons.keyboard_return_rounded, size: 18),
                    ),
                ],
              ),
            if (!mobile || _moreTools || _isMarkdownMode)
              const SizedBox(height: 8),
            if (_isMarkdownMode)
              MarkdownWorkbench(
                mentionNames: widget.mentionCandidates,
                controller: _markdownController,
                focusNode: _focusNode,
                sending: _isSending,
                onSend: _sendMessage,
                templateMode: _isTemplateMode,
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (mobile)
                    IconButton(
                      tooltip: _moreTools ? '收起消息功能' : '更多消息功能',
                      onPressed: () => setState(() => _moreTools = !_moreTools),
                      icon: Icon(
                        _moreTools
                            ? Icons.close_rounded
                            : Icons.add_circle_outline_rounded,
                        color: AppTheme.qqBlue,
                      ),
                    ),

                  Expanded(
                    child: ComposerKeyboard(
                      controller: _textController,
                      focusNode: _focusNode,
                      onSend: _sendMessage,
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: 5,
                        minLines: 1,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.send,
                        onEditingComplete: () {},
                        onSubmitted: (_) => _sendMessage(),
                        decoration: InputDecoration(
                          hintText: _hintText,
                          contentPadding: mobile
                              ? const EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 12,
                                )
                              : null,
                          filled: mobile ? true : null,
                          fillColor: mobile
                              ? Theme.of(context).scaffoldBackgroundColor
                              : null,
                          border: mobile
                              ? OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(22),
                                  borderSide: BorderSide.none,
                                )
                              : null,
                          enabledBorder: mobile
                              ? OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(22),
                                  borderSide: BorderSide.none,
                                )
                              : null,
                          suffixIcon: mobile
                              ? null
                              : Padding(
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
                                        : const Icon(
                                            Icons.send_rounded,
                                            size: 18,
                                          ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  if (mobile) ...[
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: '发送',
                      onPressed: _isSending ? null : _sendMessage,
                      style: IconButton.styleFrom(
                        backgroundColor: AppTheme.qqBlue,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.square(46),
                        shape: const CircleBorder(),
                      ),
                      icon: _isSending
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward_rounded, size: 23),
                    ),
                  ],
                ],
              ),
          ],
        ),
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

class _MentionPicker extends StatefulWidget {
  final Map<String, String> members;
  const _MentionPicker({required this.members});
  @override
  State<_MentionPicker> createState() => _MentionPickerState();
}

class _MentionPickerState extends State<_MentionPicker> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('@ 群成员'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '选择成员，或输入当前 AppID 下的成员 OpenID。@ 标签将通过 Markdown 发送。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: '成员 OpenID',
              hintText: '不是 QQ 号，也不能使用其他机器人的 OpenID',
            ),
          ),
          if (widget.members.isNotEmpty)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final member in widget.members.entries)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.alternate_email),
                        title: Text(
                          member.value.isEmpty ? '群成员' : member.value,
                        ),
                        subtitle: Text(
                          member.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, member.key),
                      ),
                  ],
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
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('插入 @'),
      ),
    ],
  );
}
