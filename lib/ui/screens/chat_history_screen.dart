import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../models/group_notice.dart';
import '../../models/message.dart';
import '../../utils/message_history.dart';
import '../widgets/group_member_actions.dart';
import '../widgets/message_bubble.dart';
import '../widgets/app_dialogs.dart';

class ChatHistorySelection {
  final MessageModel? reply;
  final String? mention;
  const ChatHistorySelection({this.reply, this.mention});
}

/// A separate, responsive route over the current bot's locally saved messages.
/// Incoming messages never move the reader's scroll position.
class ChatHistoryScreen extends StatefulWidget {
  final ChatSession session;
  final String? initialMessageId;
  const ChatHistoryScreen({
    super.key,
    required this.session,
    this.initialMessageId,
  });
  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final GroupTarget _target;
  HistoryFilter _filter = HistoryFilter.all;
  DateTime? _day;
  int _limit = 60;
  late Set<String> _messageIds;
  String? _startAt;

  @override
  void initState() {
    super.initState();
    _startAt = widget.initialMessageId;
    _target = context.read<BotClient>().groups.target(widget.session.id);
    _messageIds = context
        .read<BotClient>()
        .getMessagesForSession(widget.session.id)
        .map((m) => m.id)
        .toSet();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    _limit = 60;
    _startAt = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _pickDay() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _day ?? DateTime.now(),
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date != null && mounted) {
      setState(() {
        _day = date;
        _reset();
      });
    }
  }

  Future<void> _recall(BotClient bot, MessageModel message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('撤回这条消息？'),
        content: Text(message.sessionPreview),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认撤回'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !bot.groups.isCurrent(_target)) return;
    final ok = await bot.recallMessage(message);
    if (!ok && mounted) {
      await AppDialogs.show(
        context,
        bot.lastSendError,
        title: '撤回失败',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient>();
    final current = bot.groups.isCurrent(_target);
    final messages = current
        ? bot.getMessagesForSession(widget.session.id).reversed.where((
            message,
          ) {
            final at = message.timestamp.toLocal();
            return _messageIds.contains(message.id) &&
                matchesHistoryFilter(message, _filter) &&
                (_day == null ||
                    (at.year == _day!.year &&
                        at.month == _day!.month &&
                        at.day == _day!.day)) &&
                historyMessageText(
                  message,
                ).toLowerCase().contains(_search.text.trim().toLowerCase());
          }).toList()
        : <MessageModel>[];
    final startIndex = _startAt == null
        ? 0
        : messages.indexWhere((m) => m.id == _startAt);
    final visible = messages.skip(startIndex > 0 ? startIndex : 0).toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回原聊天',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('聊天记录'),
            Text(
              widget.session.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新聊天记录',
            onPressed: current
                ? () => setState(() {
                    _messageIds = bot
                        .getMessagesForSession(widget.session.id)
                        .map((m) => m.id)
                        .toSet();
                    _reset();
                  })
                : null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '按日期筛选',
            onPressed: current ? _pickDay : null,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1060),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: TextField(
                    controller: _search,
                    enabled: current,
                    onChanged: (_) => setState(_reset),
                    decoration: InputDecoration(
                      hintText: '搜索成员、正文、引用或语音转写',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              onPressed: () => setState(() {
                                _search.clear();
                                _reset();
                              }),
                              icon: const Icon(Icons.close),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final filter in HistoryFilter.values)
                          ChoiceChip(
                            showCheckmark: false,
                            label: Text(switch (filter) {
                              HistoryFilter.all => '全部',
                              HistoryFilter.images => '图片',
                              HistoryFilter.voice => '语音',
                              HistoryFilter.files => '文件',
                            }),
                            selected: _filter == filter,
                            onSelected: current
                                ? (_) => setState(() {
                                    _filter = filter;
                                    _reset();
                                  })
                                : null,
                          ),
                        if (_day != null)
                          InputChip(
                            label: Text(
                              '${_day!.year}/${_day!.month}/${_day!.day}',
                            ),
                            onDeleted: () => setState(() {
                              _day = null;
                              _reset();
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      current
                          ? '${messages.length} 条本地记录 · 新消息在前'
                          : '机器人已切换，请返回原聊天后重新打开',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (current && _startAt != null)
                  TextButton.icon(
                    onPressed: () => setState(_reset),
                    icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                    label: Text(
                      startIndex >= 0 ? '已定位消息 · 查看更新的记录' : '该消息已不存在 · 查看其他记录',
                    ),
                  ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(
                          child: Text(
                            current ? '没有符合条件的聊天记录' : '此页面不会显示其他机器人的消息',
                          ),
                        )
                      : ListView.builder(
                          key: ValueKey(
                            'history-${_target.appId}-${_target.groupId}',
                          ),
                          controller: _scroll,
                          itemCount:
                              visible.length.clamp(0, _limit) +
                              (visible.length > _limit ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _limit) {
                              return Padding(
                                padding: const EdgeInsets.all(16),
                                child: OutlinedButton(
                                  onPressed: () => setState(() => _limit += 60),
                                  child: const Text('加载更早的记录'),
                                ),
                              );
                            }
                            final message = visible[index];
                            final day = message.timestamp.toLocal();
                            final previous = index > 0
                                ? visible[index - 1].timestamp.toLocal()
                                : null;
                            return Column(
                              children: [
                                if (previous == null ||
                                    previous.year != day.year ||
                                    previous.month != day.month ||
                                    previous.day != day.day)
                                  Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Text(
                                      '${day.year}/${day.month}/${day.day}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context).hintColor,
                                      ),
                                    ),
                                  ),
                                Container(
                                  decoration: message.id == _startAt
                                      ? BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: .06),
                                          border: Border(
                                            left: BorderSide(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              width: 3,
                                            ),
                                          ),
                                        )
                                      : null,
                                  child: MessageBubble(
                                    key: ValueKey(message.id),
                                    message: message,
                                    onReply: message.isRecalled
                                        ? null
                                        : () => Navigator.pop(
                                            context,
                                            ChatHistorySelection(
                                              reply: message,
                                            ),
                                          ),
                                    canRecall: bot.canRecallMessage(message),
                                    onRecall: () => _recall(bot, message),
                                    onSenderLongPress:
                                        widget.session.sessionType != 1 ||
                                            message.isBotAuthor ||
                                            message.senderId.isEmpty
                                        ? null
                                        : () => GroupMemberActions.show(
                                            context,
                                            bot,
                                            _target,
                                            message.senderId,
                                            name: message.senderName,
                                            avatarUrl: message.senderAvatarUrl,
                                            onMention: () {
                                              if (mounted &&
                                                  bot.groups.isCurrent(
                                                    _target,
                                                  )) {
                                                Navigator.pop(
                                                  this.context,
                                                  ChatHistorySelection(
                                                    mention: message.senderId,
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
