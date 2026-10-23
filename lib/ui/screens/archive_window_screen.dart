import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../utils/message_history.dart';
import '../widgets/message_bubble.dart';

/// Read-only snapshot in an independent desktop process. No second bot login or
/// mutable Hive instance is created just to read the conversation.
class ArchiveWindowScreen extends StatefulWidget {
  final String title;
  final List<MessageModel> messages;
  final String? initialMessageId;
  final VoidCallback onClose;
  final bool showAppBar;
  const ArchiveWindowScreen({
    super.key,
    required this.title,
    required this.messages,
    required this.onClose,
    this.initialMessageId,
    this.showAppBar = true,
  });
  @override
  State<ArchiveWindowScreen> createState() => _ArchiveWindowScreenState();
}

class _ArchiveWindowScreenState extends State<ArchiveWindowScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  HistoryFilter _filter = HistoryFilter.all;
  int _limit = 100;
  bool _locating = true;
  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    var messages = widget.messages.reversed
        .where(
          (m) =>
              matchesHistoryFilter(m, _filter) &&
              historyMessageText(m).toLowerCase().contains(query),
        )
        .toList();
    if (_locating && widget.initialMessageId != null) {
      final i = messages.indexWhere((m) => m.id == widget.initialMessageId);
      if (i > 0) messages = messages.skip(i).toList();
    }
    return Scaffold(
      appBar: !widget.showAppBar
          ? null
          : AppBar(
              leading: IconButton(
                tooltip: '关闭聊天记录窗口',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
              title: Text(
                '${widget.title} · 聊天记录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1060),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索聊天记录',
                  ),
                  onChanged: (_) => setState(() {
                    _limit = 100;
                    _locating = false;
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  }),
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
                          label: Text(switch (filter) {
                            HistoryFilter.all => '全部',
                            HistoryFilter.images => '图片',
                            HistoryFilter.voice => '语音',
                            HistoryFilter.files => '文件',
                          }),
                          selected: _filter == filter,
                          onSelected: (_) => setState(() {
                            _filter = filter;
                            _limit = 100;
                            _locating = false;
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${messages.length} 条记录 · 打开时的只读快照',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
              Expanded(
                child: messages.isEmpty
                    ? const Center(child: Text('没有符合条件的聊天记录'))
                    : ListView.builder(
                        controller: _scroll,
                        itemCount:
                            messages.length.clamp(0, _limit) +
                            (messages.length > _limit ? 1 : 0),
                        itemBuilder: (context, i) => i == _limit
                            ? TextButton(
                                onPressed: () => setState(() => _limit += 100),
                                child: const Text('加载更早的记录'),
                              )
                            : MessageBubble(
                                message: messages[i],
                                key: ValueKey(messages[i].id),
                              ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
