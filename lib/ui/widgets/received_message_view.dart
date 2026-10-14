import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/received_message.dart';
import '../../utils/helpers.dart';

/// 接收消息中的正文、附件、卡片和递归消息元素；不把群文件当成图片。
class ReceivedMessageView extends StatelessWidget {
  final ReceivedMessageBody body;
  final int depth;
  final String storageKey;
  const ReceivedMessageView({
    super.key,
    required this.body,
    this.depth = 0,
    this.storageKey = '',
  });

  @override
  Widget build(BuildContext context) {
    final role = switch (body.authorRole) {
      'owner' => '群主',
      'admin' => '管理员',
      'member' => '成员',
      _ => '',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (depth > 0 &&
            (body.authorName.isNotEmpty || body.authorId.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Text(
              '${body.authorName.isNotEmpty ? body.authorName : body.authorId}${role.isEmpty ? '' : ' · $role'}${body.isBotAuthor ? ' · 机器人' : ''}',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        if (body.displayText.isNotEmpty)
          SelectableText(
            body.displayText,
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
        if (body.card != null) _card(context, body.card!),
        for (final attachment in body.attachments)
          _attachment(context, attachment),
        if (body.elements.isNotEmpty)
          ExpansionTile(
            key: storageKey.isEmpty
                ? null
                : PageStorageKey('elements-$storageKey'),
            initiallyExpanded: depth == 0,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 8),
            title: Text(
              '${body.kindLabel} · ${body.elements.length} 个元素',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            children: [
              for (var i = 0; i < body.elements.length; i++)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: Theme.of(context).dividerColor,
                        width: 2,
                      ),
                    ),
                  ),
                  child: ReceivedMessageView(
                    body: body.elements[i],
                    depth: depth + 1,
                    storageKey: '$storageKey/$i',
                  ),
                ),
            ],
          ),
        if (body.hasMoreElements)
          const Text('嵌套内容较多，剩余内容请在消息详情中查看。', style: TextStyle(fontSize: 11)),
        if (body.displayText.isEmpty &&
            body.card == null &&
            body.attachments.isEmpty &&
            body.elements.isEmpty &&
            !body.hasMoreElements)
          Text('[${body.kindLabel}]', style: const TextStyle(fontSize: 13)),
      ],
    );
  }

  Widget _attachment(BuildContext context, ReceivedAttachment attachment) {
    final details = [
      attachment.kindLabel,
      if (attachment.size > 0) formatFileSize(attachment.size),
      if (attachment.width > 0 && attachment.height > 0)
        '${attachment.width} × ${attachment.height}',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachment.isImage && _webUri(attachment.url) != null)
            _image(context, attachment.url),
          Row(
            children: [
              Icon(
                attachment.isImage
                    ? Icons.image_outlined
                    : attachment.isVoice
                    ? Icons.mic_outlined
                    : attachment.isVideo
                    ? Icons.movie_outlined
                    : Icons.insert_drive_file_outlined,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      details,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '打开${attachment.kindLabel}（系统默认应用）',
                onPressed: _webUri(attachment.openUrl) == null
                    ? null
                    : () => _open(context, attachment.openUrl),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
              ),
            ],
          ),
          if (attachment.transcript.isNotEmpty)
            SelectableText(
              '语音转写：${attachment.transcript}',
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, ReceivedCard card) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 340),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            card.name.isEmpty ? '分享卡片' : card.name,
            style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 5),
          if (_webUri(card.previewUrl) != null)
            _image(context, card.previewUrl),
          SelectableText(
            card.title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          if (card.description.isNotEmpty)
            SelectableText(
              card.description,
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          if (card.source.isNotEmpty)
            Text('来源：${card.source}', style: const TextStyle(fontSize: 10)),
          if (card.prompt.isNotEmpty)
            Text(card.prompt, style: const TextStyle(fontSize: 11)),
          if (_webUri(card.jumpUrl) != null)
            TextButton.icon(
              onPressed: () => _open(context, card.jumpUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('打开卡片链接'),
            ),
        ],
      ),
    );
  }

  Widget _image(BuildContext context, String url) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 220),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.contain,
          placeholder: (_, _) => const SizedBox(
            width: 220,
            height: 100,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          errorWidget: (_, _, _) => const SizedBox(
            width: 220,
            height: 100,
            child: Center(child: Text('图片暂时无法加载，可点击打开')),
          ),
        ),
      ),
    ),
  );
}

Uri? _webUri(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty
      ? uri
      : null;
}

Future<void> _open(BuildContext context, String url) async {
  final uri = _webUri(url);
  if (uri == null) return;
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    /* 下载地址可能已过期或本机没有关联应用。 */
  }
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接，附件地址可能已过期。')));
  }
}
