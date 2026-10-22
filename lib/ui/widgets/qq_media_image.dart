import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../models/media_image.dart';
import 'message_image.dart';
import 'material_library_sheet.dart';

Widget qqMarkdownImage(MarkdownImageConfig config) {
  final uri = config.uri;
  if (uri.scheme == 'qqbot-media') {
    return QqMediaImage(reference: uri.toString());
  }
  return MessageImage(source: uri.toString());
}

/// Resolve qqbot-media locally for the preview only. Outbound Markdown always
/// keeps the original bot-bound reference, never a temporary COS preview URL.
class QqMediaImage extends StatefulWidget {
  final String reference;
  const QqMediaImage({super.key, required this.reference});
  @override
  State<QqMediaImage> createState() => _QqMediaImageState();
}

class _QqMediaImageState extends State<QqMediaImage> {
  String _scope = '';
  Future<BotMediaImage?>? _request;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bot = context.watch<BotClient?>();
    final scope =
        '${bot?.config.appId}:${bot?.accountEpoch}:${widget.reference}';
    if (_scope == scope) return;
    _scope = scope;
    // Never start a notifier mutation during a widget build.
    _request = bot == null
        ? Future.value(null)
        : Future.microtask(
            () => bot.materials.resolveReference(widget.reference),
          );
  }

  @override
  void didUpdateWidget(QqMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) {
      final bot = context.read<BotClient?>();
      _scope = '${bot?.config.appId}:${bot?.accountEpoch}:${widget.reference}';
      _request = bot == null
          ? Future.value(null)
          : Future.microtask(
              () => bot.materials.resolveReference(widget.reference),
            );
    }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 360, maxHeight: 250),
    child: FutureBuilder<BotMediaImage?>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snapshot.data case final image? when image.previewUrl.isNotEmpty) {
          return SizedBox(
            height: 220,
            child: MaterialPreview(image: image, onRefresh: _refresh),
          );
        }
        final bot = context.read<BotClient?>();
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_library_outlined),
              const SizedBox(height: 6),
              Text(
                bot == null ? '平台素材图片，请在主窗口素材库查看' : '素材未找到、已过期或暂时无法预览',
                style: const TextStyle(fontSize: 12),
              ),
              if (bot != null)
                TextButton(onPressed: _refresh, child: const Text('刷新预览')),
            ],
          ),
        );
      },
    ),
  );

  void _refresh() {
    final bot = context.read<BotClient?>();
    if (bot == null) return;
    setState(
      () => _request = Future.microtask(
        () => bot.materials.resolveReference(widget.reference, force: true),
      ),
    );
  }
}
