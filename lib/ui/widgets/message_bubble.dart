import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/message.dart';
import '../../utils/helpers.dart';
import '../themes/app_theme.dart';
import 'message_details_dialog.dart';
import 'received_message_view.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool showSender;
  final bool canRecall;
  final VoidCallback? onRecall;
  final VoidCallback? onReply;

  const MessageBubble({
    super.key,
    required this.message,
    this.showSender = true,
    this.canRecall = false,
    this.onRecall,
    this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final isBot = message.isFromBot;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isBot
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isBot) ...[_avatar(context), const SizedBox(width: 10)],
          Flexible(
            child: Column(
              crossAxisAlignment: isBot
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (showSender) ...[
                  _senderLine(context),
                  const SizedBox(height: 5),
                ],
                _content(context, isBot),
                const SizedBox(height: 5),
                _metaLine(context, isBot),
              ],
            ),
          ),
          if (isBot) ...[const SizedBox(width: 10), _avatar(context)],
        ],
      ),
    );
  }

  Widget _avatar(BuildContext context) {
    final avatarUrl = message.senderAvatarUrl;
    if (avatarUrl.isNotEmpty && isValidUrl(avatarUrl)) {
      return CircleAvatar(
        radius: 17,
        backgroundColor: Colors.transparent,
        backgroundImage: CachedNetworkImageProvider(avatarUrl),
      );
    }

    return CircleAvatar(
      radius: 17,
      backgroundColor: message.isFromBot ? AppTheme.qqBlue : AppTheme.qqGreen,
      child: Text(
        _avatarText,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }

  String get _avatarText {
    final name = message.senderName.trim();
    if (name.isEmpty) return message.isFromBot ? 'B' : '?';
    return name.characters.first.toUpperCase();
  }

  Widget _senderLine(BuildContext context) {
    final color = message.isFromBot ? AppTheme.qqBlue : AppTheme.qqGreen;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            message.senderName.isEmpty
                ? (message.isFromBot ? '机器人' : '用户')
                : message.senderName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
        if (message.senderLevel.isNotEmpty) ...[
          const SizedBox(width: 5),
          _badge(_levelLabel(message.senderLevel), AppTheme.amber),
        ],
        if (message.senderTitle.isNotEmpty) ...[
          const SizedBox(width: 5),
          _badge(message.senderTitle, AppTheme.qqBlue),
        ],
        if (message.senderRole.isNotEmpty) ...[
          const SizedBox(width: 5),
          _badge(_roleLabel(message.senderRole), AppTheme.muted),
        ],
        if (message.isBotAuthor && !message.isFromBot) ...[
          const SizedBox(width: 5),
          _badge('机器人', AppTheme.qqBlue),
        ],
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _content(BuildContext context, bool isBot) {
    if (message.isRecalled) return _textBubble(context, isBot);
    if (message.hasReceivedPayload && message.markdownContent == null) {
      return Container(
        constraints: BoxConstraints(maxWidth: _maxWidth(context, 0.52)),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: _bubbleDecoration(context, isBot),
        child: Material(
          color: Colors.transparent,
          child: ReceivedMessageView(
            body: message.receivedBody,
            storageKey: message.id,
          ),
        ),
      );
    }
    if ((message.extra?['mediaFileType'] as int? ?? 1) > 1) {
      return _textBubble(context, isBot);
    }
    if (message.imageUrl != null && message.imageUrl!.isNotEmpty) {
      return Column(
        crossAxisAlignment: isBot
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _imageBubble(context),
          if (message.content.isNotEmpty && !isValidUrl(message.content)) ...[
            const SizedBox(height: 6),
            _textBubble(context, isBot),
          ],
        ],
      );
    }

    return switch (message.messageType) {
      2 => Column(
        crossAxisAlignment: isBot
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _markdownBubble(context, isBot),
          if (message.extra?['keyboard'] is Map) _keyboardBubble(context),
        ],
      ),
      7 => _imageBubble(context),
      _ => _textBubble(context, isBot),
    };
  }

  Widget _keyboardBubble(BuildContext context) {
    final keyboard = message.extra!['keyboard'] as Map;
    final content = keyboard['content'];
    final rows = content is Map ? content['rows'] : null;
    return Container(
      constraints: BoxConstraints(maxWidth: _maxWidth(context, 0.52)),
      padding: const EdgeInsets.only(top: 6),
      child: Tooltip(
        message: '按钮在 QQ 消息中可操作，此处显示发送结果',
        child: rows is! List
            ? Text(
                '按钮模板：${keyboard['id'] ?? ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).hintColor,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in rows)
                    if (row is Map && row['buttons'] is List)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final button in row['buttons'])
                              if (button is Map && button['render_data'] is Map)
                                _buttonLabel(button['render_data'] as Map),
                          ],
                        ),
                      ),
                ],
              ),
      ),
    );
  }

  Widget _buttonLabel(Map render) {
    final style = render['style'];
    final color = style == 3
        ? AppTheme.qqRed
        : (style == 0 ? AppTheme.muted : AppTheme.qqBlue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: style == 4 ? AppTheme.qqBlue : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Text(
        render['label']?.toString() ?? '',
        style: TextStyle(
          fontSize: 12,
          color: style == 4 ? Colors.white : color,
        ),
      ),
    );
  }

  Widget _textBubble(BuildContext context, bool isBot) {
    final content = message.isRecalled
        ? '这条消息已撤回'
        : formatQqMessageContent(
            message.content,
            mentions: message.extra?['mentions'] as List?,
          );

    return Container(
      constraints: BoxConstraints(maxWidth: _maxWidth(context, 0.46)),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: _bubbleDecoration(context, isBot),
      child: SelectableText(
        content,
        style: TextStyle(
          fontSize: 14,
          height: 1.45,
          color: isBot ? Colors.white : Theme.of(context).colorScheme.onSurface,
          fontStyle: message.isRecalled ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }

  Widget _markdownBubble(BuildContext context, bool isBot) {
    final content = message.markdownContent ?? message.content;
    return Container(
      constraints: BoxConstraints(maxWidth: _maxWidth(context, 0.52)),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: _bubbleDecoration(context, isBot),
      child: MarkdownBody(
        data: content,
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: isBot ? Colors.white : null,
          ),
          h1: TextStyle(fontSize: 18, color: isBot ? Colors.white : null),
          h2: TextStyle(fontSize: 16, color: isBot ? Colors.white : null),
          code: TextStyle(
            fontSize: 12,
            color: isBot ? Colors.white : AppTheme.qqRed,
            backgroundColor: Colors.black.withValues(
              alpha: isBot ? 0.18 : 0.06,
            ),
          ),
          codeblockDecoration: BoxDecoration(
            color: Colors.black.withValues(alpha: isBot ? 0.18 : 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  Widget _imageBubble(BuildContext context) {
    final url = message.imageUrl ?? message.content;
    return Container(
      constraints: BoxConstraints(
        maxWidth: _maxWidth(context, 0.34),
        maxHeight: 300,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: isValidUrl(url)
          ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox(
                height: 130,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (_, _, _) => const SizedBox(
                height: 130,
                child: Center(
                  child: Icon(Icons.broken_image_rounded, size: 34),
                ),
              ),
            )
          : const SizedBox(
              height: 130,
              child: Center(
                child: Icon(Icons.image_not_supported_rounded, size: 34),
              ),
            ),
    );
  }

  BoxDecoration _bubbleDecoration(BuildContext context, bool isBot) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: isBot
          ? AppTheme.qqBlue
          : isDark
          ? const Color(0xFF202A36)
          : Colors.white,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(8),
        topRight: const Radius.circular(8),
        bottomLeft: Radius.circular(isBot ? 8 : 3),
        bottomRight: Radius.circular(isBot ? 3 : 8),
      ),
      border: isBot ? null : Border.all(color: Theme.of(context).dividerColor),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.16 : 0.05),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }

  Widget _metaLine(BuildContext context, bool isBot) {
    final actionColor = Theme.of(context).colorScheme.primary;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          formatTimestamp(message.timestamp),
          style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
        ),
        if (message.isFullGroupMessage)
          Text(
            '全量',
            style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
          ),
        if (message.hasReceivedPayload && !message.isRecalled)
          _miniAction(
            '详情',
            actionColor,
            () => showMessageDetails(context, message),
          ),
        if (!message.isRecalled && onReply != null) ...[
          _miniAction('回复', actionColor, onReply),
        ],
        if (message.isRecalled) ...[
          Text(
            '已撤回',
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
        if (canRecall && onRecall != null) ...[
          _miniAction('撤回', actionColor, onRecall),
        ],
      ],
    );
  }

  Widget _miniAction(String label, Color color, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String _levelLabel(String level) {
    final text = level.trim();
    if (text.toUpperCase().startsWith('LV')) return text;
    return 'LV$text';
  }

  double _maxWidth(BuildContext context, double fraction) {
    final width = MediaQuery.sizeOf(context).width;
    return width < 700 ? width - 96 : width * fraction;
  }

  String _roleLabel(String role) {
    return switch (role) {
      'owner' => '群主',
      'admin' => '管理员',
      'member' => '成员',
      _ => role,
    };
  }
}
