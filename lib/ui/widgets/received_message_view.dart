import 'package:flutter/material.dart';
import '../screens/browser_screen.dart';
import 'linkified_text.dart';
import 'message_image.dart';

import '../../models/received_message.dart';
import '../../services/qface_service.dart';
import '../../utils/helpers.dart';

/// 接收消息中的正文、附件、卡片和递归消息元素；不把群文件当成图片。
class ReceivedMessageView extends StatefulWidget {
  final ReceivedMessageBody body;
  final int depth;
  final String storageKey;
  final QFaceService? faceService;
  const ReceivedMessageView({
    super.key,
    required this.body,
    this.depth = 0,
    this.storageKey = '',
    this.faceService,
  });

  @override
  State<ReceivedMessageView> createState() => _ReceivedMessageViewState();
}

class _ReceivedMessageViewState extends State<ReceivedMessageView> {
  // ExpansionTile stores a bool; SelectableText's internal scrollable stores
  // a double. Keep descendant scroll positions out of the expansion bucket.
  final _elementsBucket = PageStorageBucket();

  @override
  Widget build(BuildContext context) {
    final body = widget.body;
    final depth = widget.depth;
    final storageKey = widget.storageKey;
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
          LinkifiedText(
            body.text,
            qqFaces: true,
            mentions: body.mentions,
            faceService: widget.faceService,
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
            maintainState: true,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 8),
            title: Text(
              '${body.kindLabel} · ${body.elements.length} 个元素',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            children: [
              PageStorage(
                bucket: _elementsBucket,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                          faceService: widget.faceService,
                        ),
                      ),
                  ],
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
                tooltip: '打开${attachment.kindLabel}（内置浏览器）',
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
    child: MessageImage(source: url),
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
  await openInAppBrowser(context, url);
}
