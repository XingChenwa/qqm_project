import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../models/received_message.dart';
import '../../services/video_thumbnail_service.dart';
import '../../utils/media_link.dart';
import '../screens/browser_screen.dart';
import 'file_download_dialog.dart';

class VideoAttachment extends StatefulWidget {
  final ReceivedAttachment attachment;
  final VideoThumbnailService? thumbnails;
  const VideoAttachment({super.key, required this.attachment, this.thumbnails});
  @override
  State<VideoAttachment> createState() => _VideoAttachmentState();
}

class _VideoAttachmentState extends State<VideoAttachment> {
  late Future<Uint8List?> _cover;
  void _loadCover() {
    _cover = (widget.thumbnails ?? VideoThumbnailService.shared).load(
      widget.attachment.url,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant VideoAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.url != widget.attachment.url ||
        oldWidget.thumbnails != widget.thumbnails) {
      _loadCover();
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    final valid = mediaHttpUri(attachment.url) != null;
    return Container(
      key: const ValueKey('video-attachment'),
      constraints: const BoxConstraints(maxWidth: 360),
      margin: const EdgeInsets.only(top: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xff17233b),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: attachment.width > 0 && attachment.height > 0
                ? (attachment.width / attachment.height).clamp(.7, 2.0)
                : 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<Uint8List?>(
                  key: ObjectKey(_cover),
                  future: _cover,
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    if (bytes != null) {
                      return Image.memory(
                        bytes,
                        key: const ValueKey('video-preview-cover'),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox(),
                      );
                    }
                    return Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          snapshot.connectionState == ConnectionState.done
                              ? '点击播放视频'
                              : '正在加载封面…',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Center(
                  child: IconButton.filled(
                    tooltip: '播放视频',
                    iconSize: 40,
                    onPressed: valid
                        ? () => openInAppBrowser(
                            context,
                            attachment.url,
                            video: true,
                            filename: attachment.filename,
                          )
                        : null,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: .5),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    attachment.filename.isEmpty ? '视频消息' : attachment.filename,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                IconButton(
                  tooltip: '下载原视频',
                  color: Colors.white,
                  onPressed: valid
                      ? () => showFileDownload(
                          context,
                          attachment.url,
                          filename: attachment.filename,
                        )
                      : null,
                  icon: const Icon(Icons.download_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
