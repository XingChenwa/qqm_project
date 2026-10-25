import 'dart:convert';
import '../audio.dart';
import '../../ui/widgets/voice_attachment.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../ui/widgets/app_dialogs.dart';
import '../../ui/screens/browser_screen.dart';
import '../controller.dart';
import '../models.dart';
import 'editor.dart';
import '../../models/received_message.dart';
import '../../ui/widgets/received_message_view.dart';

class AgentChat extends StatefulWidget {
  final AgentController agent;
  final String sessionKey;
  final VoidCallback? onBack;
  const AgentChat({
    super.key,
    required this.agent,
    required this.sessionKey,
    this.onBack,
  });
  @override
  State<AgentChat> createState() => _AgentChatState();
}

class _AgentChatState extends State<AgentChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _sending = false;
  int _new = 0;
  String? _lastId;
  int _historyRevision = -1;
  List<AgentMessage> _messages = const [];
  String? _replyId, _mentionId;
  AgentController get agent => widget.agent;
  AgentSession get session => agent.session(widget.sessionKey)!;
  @override
  void initState() {
    super.initState();
    _messages = agent.store.messages(widget.sessionKey);
    _lastId = _messages.lastOrNull?.id;
    _historyRevision = agent.store.keyVersion('history:${widget.sessionKey}');
    agent.addListener(_updated);
    _bottom();
  }

  void _updated() {
    if (!mounted) return;
    final revision = agent.store.keyVersion('history:${widget.sessionKey}');
    if (revision == _historyRevision) return;
    _historyRevision = revision;
    final messages = agent.store.messages(widget.sessionKey);
    setState(() => _messages = messages);
    if (messages.isNotEmpty && messages.last.id != _lastId) {
      final previous = messages.indexWhere((m) => m.id == _lastId);
      final incoming = messages
          .skip(previous + 1)
          .where((m) => !m.outgoing)
          .length;
      if (incoming > 0) setState(() => _new += incoming);
      if (messages.lastOrNull?.outgoing == true) _bottom();
    }
    _lastId = messages.lastOrNull?.id;
  }

  @override
  void didUpdateWidget(covariant AgentChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent != widget.agent ||
        oldWidget.sessionKey != widget.sessionKey) {
      oldWidget.agent.removeListener(_updated);
      agent.addListener(_updated);
      _messages = agent.store.messages(widget.sessionKey);
      _historyRevision = agent.store.keyVersion('history:${widget.sessionKey}');
      _lastId = _messages.lastOrNull?.id;
      _new = 0;
      _replyId = null;
      _mentionId = null;
      _input.clear();
      _bottom();
    }
  }

  void _bottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        setState(() => _new = 0);
      }
    });
  }

  @override
  void dispose() {
    agent.removeListener(_updated);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _operation(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        await AppDialogs.show(
          context,
          agent.describeError(e),
          title: 'QQ Agent',
          error: true,
        );
      }
    }
  }

  Future<void> _send({List<Json>? attachments}) async {
    if (_sending || attachments == null && _input.text.trim().isEmpty) return;
    final draft = _input.text;
    setState(() => _sending = true);
    try {
      await agent.send(
        widget.sessionKey,
        draft,
        segments: [
          if (_replyId != null)
            {
              'type': 'reply',
              'data': {'id': _replyId},
            },
          if (_mentionId != null)
            {
              'type': 'at',
              'data': {'qq': _mentionId},
            },
          if (draft.isNotEmpty) textSegment(draft),
          ...?attachments,
        ],
      );
      if (!mounted) return;
      if (_input.text == draft) _input.clear();
      setState(() {
        _replyId = null;
        _mentionId = null;
      });
      _bottom();
      await agent.markRead(widget.sessionKey);
    } catch (e) {
      if (mounted) {
        await AppDialogs.show(context, agent.describeError(e), error: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _image() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null) return;
    final file = result.files.single;
    if (file.bytes == null || file.size > 5 * 1024 * 1024) {
      throw const AgentException('请选择不超过 5 MB 的图片。');
    }
    await _send(
      attachments: [
        {
          'type': 'image',
          'data': {'file': 'base64://${base64Encode(file.bytes!)}'},
        },
      ],
    );
  }

  Future<void> _settings() => editAgent(
    context,
    title: 'Agent 会话设置',
    initial: session.toJson(),
    fields: [
      const AgentField('name', '会话名称'),
      const AgentField(
        'paused',
        '暂停本会话自动回复',
        type: 'bool',
        hint: '暂停 AI 和命令插件，仍可手动发送。',
      ),
      AgentField(
        'presetId',
        '此会话的 AI 预设',
        type: 'choice',
        choices: {'': '使用连接默认预设', for (final p in agent.presets) p.id: p.name},
      ),
      const AgentField(
        'memory',
        '长期备注 / 会话记忆',
        lines: 6,
        hint: '仅用于这个 OneBot 账号下的当前会话，可随时编辑或清空。',
      ),
    ],
    save: (j) => agent.configureSession(AgentSession.fromJson(j)),
  ).then((_) {});
  Future<void> _menu(AgentMessage message) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('复制消息'),
            onTap: () => Navigator.pop(ctx, 'copy'),
          ),
          ListTile(
            leading: const Icon(Icons.reply),
            title: const Text('引用回复'),
            onTap: () => Navigator.pop(ctx, 'reply'),
          ),
          if (session.kind == 'group' && !message.outgoing)
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: Text('@${message.senderName}'),
              onTap: () => Navigator.pop(ctx, 'at'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.plain));
    }
    if (action == 'reply') {
      setState(() => _replyId = message.id.replaceFirst('ob:', ''));
    }
    if (action == 'at') setState(() => _mentionId = message.senderId);
  }

  @override
  Widget build(BuildContext context) {
    final s = session, theme = Theme.of(context), messages = _messages;
    final busy = agent.busySessions.contains(s.key);
    final replyState = agent.replyState(s.key);
    final connection = agent.connection(s.connectionId);
    final presetId = s.presetId.isEmpty ? connection?.presetId : s.presetId;
    final showReasoning =
        agent.presets
            .where((p) => p.id == presetId)
            .firstOrNull
            ?.showReasoning ==
        true;
    return Column(
      children: [
        Material(
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                if (widget.onBack != null)
                  IconButton(
                    tooltip: '返回 Agent 会话',
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          '${s.kind == 'group' ? '群' : 'QQ'} ${s.peerId} · ${s.paused ? '已暂停自动回复' : agent.status(s.connectionId)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Agent 会话设置',
                  onPressed: _settings,
                  icon: const Icon(Icons.tune),
                ),
                PopupMenuButton<String>(
                  tooltip: '会话操作',
                  onSelected: (action) => _operation(() async {
                    if (action == 'context') await agent.clearContext(s.key);
                    if (action == 'reply') await agent.regenerate(s.key);
                    if (action == 'profile') {
                      await agent.refreshOfficialProfile(s.key);
                    }
                    if (action == 'clear') {
                      if (!context.mounted) return;
                      final sure = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('清空当前聊天记录？'),
                          content: const Text('仅清空这个 Agent 会话的本地记录，此操作无法撤销。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                      );
                      if (sure == true) await agent.clearHistory(s.key);
                    }
                  }),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'reply',
                      child: Text('让 AI 回复最后一条消息'),
                    ),
                    if (s.protocol == 'qqbot')
                      const PopupMenuItem(
                        value: 'profile',
                        child: Text('刷新官机会话资料'),
                      ),
                    const PopupMenuItem(
                      value: 'context',
                      child: Text('开始新 AI 上下文'),
                    ),
                    const PopupMenuItem(value: 'clear', child: Text('清空本地记录')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: messages.isEmpty
                    ? const Center(child: Text('发送消息，开始独立的 OneBot 对话'))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (_, i) {
                          final message = messages[i];
                          return Align(
                            alignment: message.outgoing
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  crossAxisAlignment: message.outgoing
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${message.senderName} · ${message.time.hour.toString().padLeft(2, '0')}:${message.time.minute.toString().padLeft(2, '0')}'
                                      '${message.source == 'ai'
                                          ? ' · AI'
                                          : message.source == 'plugin'
                                          ? ' · 插件'
                                          : ''}',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    const SizedBox(height: 6),
                                    GestureDetector(
                                      onLongPress: () => _menu(message),
                                      onSecondaryTap: () => _menu(message),
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: message.outgoing
                                              ? theme
                                                    .colorScheme
                                                    .primaryContainer
                                              : theme
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        child: AgentSegments(
                                          segments: message.segments,
                                          storageKey: '${s.key}:${message.id}',
                                          agent: agent,
                                          connectionId: s.connectionId,
                                          markdown: message.source == 'ai',
                                        ),
                                      ),
                                    ),
                                    if (showReasoning &&
                                        message.source == 'ai' &&
                                        message.reasoning.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: AgentReasoning(
                                          key: ValueKey(
                                            'reasoning:${message.id}',
                                          ),
                                          content: message.reasoning,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_new > 0)
                Positioned(
                  bottom: 10,
                  right: 16,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      _bottom();
                      _operation(() => agent.markRead(s.key));
                    },
                    icon: const Icon(Icons.arrow_downward),
                    label: Text('$_new 条新消息'),
                  ),
                ),
            ],
          ),
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text(replyState['message']).isEmpty
                        ? 'AI 正在处理…'
                        : text(replyState['message']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => agent.stopReply(s.key),
                  child: const Text('停止'),
                ),
              ],
            ),
          ),
        if (!busy && replyState.isNotEmpty && replyState['phase'] != 'done')
          Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
            decoration: BoxDecoration(
              color: replyState['error'] == true
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  replyState['error'] == true
                      ? Icons.error_outline
                      : Icons.info_outline,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () => AppDialogs.show(
                      context,
                      text(replyState['message']),
                      title: 'AI 回复状态',
                      error: replyState['error'] == true,
                    ),
                    child: Text(
                      text(replyState['message']),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '隐藏回复状态',
                  onPressed: () => agent.dismissReplyState(s.key),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
        if (_replyId != null || _mentionId != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_replyId == null ? '' : '引用 $_replyId  '}${_mentionId == null ? '' : '@$_mentionId'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '取消引用和 @',
                  onPressed: () => setState(() {
                    _replyId = null;
                    _mentionId = null;
                  }),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '发送图片',
                  onPressed: _sending ? null : () => _operation(_image),
                  icon: const Icon(Icons.image_outlined),
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isControlPressed &&
                          !_input.value.composing.isValid) {
                        _send();
                        return KeyEventResult.handled;
                      }
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          HardwareKeyboard.instance.isControlPressed) {
                        final selection = _input.selection;
                        final start = selection.start < 0
                            ? _input.text.length
                            : selection.start;
                        final end = selection.end < 0 ? start : selection.end;
                        _input.value = TextEditingValue(
                          text: _input.text.replaceRange(start, end, '\n'),
                          selection: TextSelection.collapsed(offset: start + 1),
                        );
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        hintText: '输入 Agent 消息…',
                      ),
                      keyboardType: TextInputType.multiline,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: _sending ? null : _send,
                  icon: Icon(
                    _sending ? Icons.hourglass_empty : Icons.arrow_upward,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class AgentReasoning extends StatelessWidget {
  final String content;
  const AgentReasoning({super.key, required this.content});
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      leading: const Icon(Icons.psychology_outlined, size: 18),
      title: const Text('思考内容', style: TextStyle(fontSize: 13)),
      subtitle: const Text('模型接口返回 · 仅本地可见', style: TextStyle(fontSize: 11)),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(child: SelectableText(content)),
        ),
      ],
    ),
  );
}

class AgentSegments extends StatelessWidget {
  final List<Json> segments;
  final AgentController agent;
  final String connectionId;
  final bool markdown;
  final int depth;
  final String storageKey;
  const AgentSegments({
    super.key,
    required this.segments,
    required this.agent,
    required this.connectionId,
    this.markdown = false,
    this.depth = 0,
    this.storageKey = '',
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [for (final s in segments) _segment(context, s)],
  );
  Widget _segment(BuildContext context, Json s) {
    final data = object(s['data']);
    final type = text(s['type']);
    if (type == 'text') {
      return markdown
          ? MarkdownBody(
              data: text(data['text']),
              onTapLink: (_, url, _) {
                if (url != null) openInAppBrowser(context, url);
              },
            )
          : Text(text(data['text']));
    }
    if (type == 'qq_body') {
      return ReceivedMessageView(
        key: ValueKey('agent-body:$storageKey:$depth'),
        body: ReceivedMessageBody.fromMap(object(data['body'])),
        storageKey: 'agent:$connectionId:$storageKey:$depth',
      );
    }
    if (type == 'at') {
      return Text(
        data['qq'] == 'all'
            ? '@全体成员'
            : '@${text(data['name']).isNotEmpty
                  ? data['name']
                  : data['qq'] == agent.connection(connectionId)?.selfId && agent.nickname(connectionId).isNotEmpty
                  ? agent.nickname(connectionId)
                  : data['qq']}',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (type == 'image') {
      final url = text(data['url']), file = text(data['file']);
      Widget failure() =>
          const Padding(padding: EdgeInsets.all(12), child: Text('图片暂不可用'));
      if (file.startsWith('base64://') && file.length < 8 * 1024 * 1024) {
        try {
          return Image.memory(
            base64Decode(file.substring(9)),
            width: 240,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => failure(),
          );
        } catch (_) {
          return failure();
        }
      }
      final address = browserUri(url.isEmpty ? file : url);
      if (address != null) {
        return InkWell(
          onTap: () => openInAppBrowser(context, address.toString()),
          child: Image.network(
            address.toString(),
            width: 240,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => failure(),
          ),
        );
      }
      return failure();
    }
    if (type == 'forward' && depth < 4) {
      return TextButton.icon(
        icon: const Icon(Icons.forum_outlined),
        label: const Text('打开聊天记录'),
        onPressed: () async {
          try {
            final response = object(
              await agent.readForward(connectionId, text(data['id'])),
            );
            if (!context.mounted) return;
            final nodes = response['messages'] as List? ?? [];
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (ctx) => Scaffold(
                  appBar: AppBar(title: const Text('OneBot 聊天记录')),
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final raw in nodes.take(200))
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  text(
                                    object(object(raw)['sender'])['nickname'],
                                  ),
                                  style: Theme.of(ctx).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 8),
                                AgentSegments(
                                  segments: parseSegments(
                                    object(raw)['content'] ??
                                        object(raw)['message'],
                                  ),
                                  agent: agent,
                                  connectionId: connectionId,
                                  depth: depth + 1,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          } catch (e) {
            if (context.mounted) {
              await AppDialogs.show(
                context,
                agent.describeError(e),
                error: true,
              );
            }
          }
        },
      );
    }
    if (type == 'record' && text(data['file']).startsWith('base64://')) {
      try {
        final file = text(data['file']);
        if (file.length > 7 * 1024 * 1024) throw const AgentException('语音过大');
        final audio = AgentAudio(base64Decode(file.substring(9)));
        return VoiceAttachment(
          attachment: ReceivedAttachment(
            url: '',
            filename: audio.name,
            contentType: 'voice',
          ),
          inlineBytes: audio.bytes,
        );
      } catch (_) {
        return const Text('语音数据不可用');
      }
    }
    if (type == 'record' || type == 'video' || type == 'file') {
      final url = text(data['url']);
      return TextButton.icon(
        onPressed: browserUri(url) == null
            ? null
            : () => openInAppBrowser(context, url, video: type == 'video'),
        icon: Icon(
          type == 'video'
              ? Icons.play_circle_outline
              : type == 'record'
              ? Icons.volume_up_outlined
              : Icons.attach_file,
        ),
        label: Text(
          type == 'video'
              ? '播放视频'
              : type == 'record'
              ? '播放 / 下载语音'
              : text(data['name']).isEmpty
              ? '文件'
              : text(data['name']),
        ),
      );
    }
    return Text(segmentText(s), style: Theme.of(context).textTheme.bodySmall);
  }
}
