import 'package:flutter/material.dart';
import '../screens/browser_screen.dart';
import '../screens/forwarded_record_screen.dart';
import 'linkified_text.dart';
import 'message_image.dart';
import 'voice_attachment.dart';
import 'video_attachment.dart';
import 'file_download_dialog.dart';

import '../../models/received_message.dart';
import '../../services/qface_service.dart';
import '../../utils/helpers.dart';

/// 接收消息中的正文、附件、卡片和递归消息元素；不把群文件当成图片。
class ReceivedMessageView extends StatefulWidget {
  final ReceivedMessageBody body;
  final int depth;
  final String storageKey;
  final QFaceService? faceService;
  final bool inRecord;
  const ReceivedMessageView({
    super.key,
    required this.body,
    this.depth = 0,
    this.storageKey = '',
    this.faceService,
    this.inRecord = false,
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
    if (body.isRecord && (!widget.inRecord || body.elements.isNotEmpty)) {
      return _recordCard(context, body);
    }
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
    if (attachment.isVideo) return VideoAttachment(attachment: attachment);
    if (attachment.isVoice) {
      return VoiceAttachment(
        key: ValueKey(attachment.openUrl),
        attachment: attachment,
      );
    }
    if (attachment.isImage && _webUri(attachment.url) != null) {
      final ratio = attachment.width > 0 && attachment.height > 0
          ? attachment.width / attachment.height
          : 1.4;
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.clamp(
            80.0,
            widget.inRecord ? 720.0 : 340.0,
          );
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: MessageImage(
              source: attachment.url,
              maxWidth: width,
              maxHeight: (width / ratio).clamp(
                64.0,
                widget.inRecord ? 1000.0 : 420.0,
              ),
            ),
          );
        },
      );
    }
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
              IconButton(
                tooltip: '下载原文件',
                onPressed: _webUri(attachment.openUrl) == null
                    ? null
                    : () => showFileDownload(
                        context,
                        attachment.openUrl,
                        filename: attachment.filename,
                      ),
                icon: const Icon(Icons.download_rounded, size: 18),
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

  Widget _recordCard(BuildContext context, ReceivedMessageBody body) {
    var record = body;
    while (record.elements.length == 1 && record.elements.single.isRecord) {
      record = record.elements.single;
    }
    return InkWell(
      key: const ValueKey('forwarded-record-card'),
      onTap: () => openForwardedRecord(context, body),
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, minWidth: 160),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                record.recordTitle.isNotEmpty ? record.recordTitle : '聊天记录',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 9),
              for (final item in record.elements.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${item.authorName.isEmpty ? '' : '${item.authorName}：'}${item.preview}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              const Divider(height: 18),
              Row(
                children: [
                  Text(
                    '聊天记录',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  const Spacer(),
                  const Text('点击查看', style: TextStyle(fontSize: 11)),
                  const Icon(Icons.chevron_right_rounded, size: 16),
                ],
              ),
            ],
          ),
        ),
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
