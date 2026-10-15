import 'package:flutter/material.dart';

import '../../models/message.dart';

/// The last message on opening is a fixed viewport anchor. New messages grow
/// below it, history grows above it. Only an explicit open/send action resets it.
class ChatTimeline extends StatefulWidget {
  final String sessionId;
  final List<MessageModel> messages;
  final ScrollController controller;
  final int openRevision;
  final int sentRevision;
  final IndexedWidgetBuilder itemBuilder;

  const ChatTimeline({
    super.key,
    required this.sessionId,
    required this.messages,
    required this.controller,
    required this.openRevision,
    this.sentRevision = 0,
    required this.itemBuilder,
  });

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  static const _center = ValueKey('timeline-new-messages');
  String? _anchorId;
  final _pendingIds = <String>{};
  Set<String> _knownIds = {};

  @override
  void initState() {
    super.initState();
    _resetAnchor();
  }

  void _resetAnchor() {
    _anchorId = widget.messages.lastOrNull?.id;
    _knownIds = widget.messages.map((m) => m.id).toSet();
    _pendingIds.clear();
  }

  void _showLatest() {
    setState(_resetAnchor);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.hasClients) widget.controller.jumpTo(0);
    });
  }

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openRevision != widget.openRevision ||
        oldWidget.sentRevision != widget.sentRevision) {
      _resetAnchor();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.hasClients) {
          widget.controller.jumpTo(0);
        }
      });
      return;
    }
    final currentIds = widget.messages.map((m) => m.id).toSet();
    _pendingIds.retainAll(currentIds);
    _pendingIds.addAll(currentIds.difference(_knownIds));
    _knownIds = currentIds;
  }

  Widget _sliver(List<int> indices) {
    final positions = <String, int>{
      for (var i = 0; i < indices.length; i++)
        widget.messages[indices[i]].id: i,
    };
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => KeyedSubtree(
          key: ValueKey(widget.messages[indices[index]].id),
          child: widget.itemBuilder(context, indices[index]),
        ),
        childCount: indices.length,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? positions[key.value] : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var anchor = widget.messages.indexWhere((m) => m.id == _anchorId);
    if (anchor < 0) anchor = widget.messages.length - 1;
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollEndNotification &&
                notification.metrics.extentAfter < 2 &&
                _pendingIds.isNotEmpty) {
              setState(_pendingIds.clear);
            }
            return false;
          },
          child: CustomScrollView(
            key: ValueKey('messages-${widget.sessionId}'),
            controller: widget.controller,
            center: _center,
            anchor: 1,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 16),
                sliver: _sliver([for (var i = anchor; i >= 0; i--) i]),
              ),
              SliverPadding(
                key: _center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                sliver: _sliver([
                  for (var i = anchor + 1; i < widget.messages.length; i++) i,
                ]),
              ),
            ],
          ),
        ),
        if (_pendingIds.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Center(
              child: FilledButton.tonalIcon(
                key: const ValueKey('new-messages-indicator'),
                onPressed: _showLatest,
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                label: Text(
                  '有 ${_pendingIds.length} 条新消息，点击查看',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
